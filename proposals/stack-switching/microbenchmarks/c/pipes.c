// Adapted from Kammar et al. (2013).

#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include <fiber.h>

typedef struct pipe {
  fiber_t fiber;
  uint32_t data;
} pipe_t;

typedef struct pipeline {
  pipe_t **pipes;
  uint32_t count;
  uint32_t capacity;
} pipeline_t;

enum {
  TAKE_COUNT = 1000,
  MAX_EXPO_DEPTH = 13,
};

static uint32_t blackhole_count;
static uint32_t blackhole_expected;

// Pipe protocol messages are tagged scalar values. Keeping them out
// of the C stack is important for nested Asyncify fibers, which share
// a linear-memory shadow stack. Odd values carry data; the nonzero
// even values are control messages. NULL is reserved for the
// initialization handshake.
static void *const MSG_AWAIT = (void *)(uintptr_t)2;
static void *const MSG_CANCEL = (void *)(uintptr_t)4;

static void *value_message(uint32_t value) {
  assert(value <= (UINT32_MAX >> 1) && "pipe value is too large");
  return (void *)(uintptr_t)((value << 1) | 1);
}

static bool is_value_message(const void *message) {
  return ((uintptr_t)message & 1) != 0;
}

static uint32_t message_value(const void *message) {
  assert(is_value_message(message) && "expected value message");
  return (uint32_t)((uintptr_t)message >> 1);
}

static pipe_t *pipe_alloc(fiber_entry_point_t fn, uint32_t data) {
  pipe_t *pipe = (pipe_t *)malloc(sizeof(pipe_t));
  assert(pipe && "failed to allocate pipe");
  pipe->fiber = fiber_alloc(fn);
  assert(pipe->fiber && "failed to allocate fiber");
  pipe->data = data;
  return pipe;
}

static void pipe_free(pipe_t *pipe) {
  fiber_free(pipe->fiber);
  free(pipe);
}

static void *await_value(void) {
  void *answer = fiber_yield(MSG_AWAIT);
  assert(answer && "null answer");
  return answer;
}

static void *yield_value(uint32_t value) {
  void *answer = fiber_yield(value_message(value));
  assert(answer && "null answer");
  return answer;
}

static void *init_protocol(void) {
  void *answer = fiber_yield(NULL);
  assert(answer && "null initialization answer");
  return answer;
}

static void cancel_pipe(pipe_t *pipe) {
  fiber_result_t status;
  void *result = fiber_resume(pipe->fiber, MSG_CANCEL, &status);
  assert(status == FIBER_OK && "cancellation failed");
  assert(result == NULL && "non-null cancellation result");
}

static void init_pipe(pipe_t *pipe) {
  fiber_result_t status;
  void *operation =
      fiber_resume(pipe->fiber, (void *)(uintptr_t)pipe->data, &status);
  assert(status == FIBER_YIELD && operation == NULL &&
         "initialization protocol violation");
}

static void *take(void *arg) {
  uint32_t const count = (uint32_t)(uintptr_t)arg;
  void *answer = init_protocol();

  for (uint32_t i = 0; i < count; ++i) {
    if (answer == MSG_CANCEL)
      return NULL;
    assert(is_value_message(answer) && "expected value");

    answer = yield_value(message_value(answer));
    if (answer == MSG_CANCEL)
      return NULL;

    if (i + 1 < count)
      answer = await_value();
  }
  return NULL;
}

static void *nats(void *arg) {
  uint32_t next = (uint32_t)(uintptr_t)arg;
  void *answer = init_protocol();
  if (answer == MSG_CANCEL)
    return NULL;
  assert(is_value_message(answer) && "expected initial value");

  for (;;) {
    answer = yield_value(next++);
    if (answer == MSG_CANCEL)
      return NULL;
    assert(is_value_message(answer) && "expected value answer");
  }
}

static void *increment(void *arg) {
  (void)arg;
  void *answer = init_protocol();
  for (;;) {
    if (answer == MSG_CANCEL)
      return NULL;
    assert(is_value_message(answer) && "expected value");

    uint32_t const value = message_value(answer);
    assert(value < (UINT32_MAX >> 1) && "incremented value is too large");
    answer = yield_value(value + 1);
    if (answer == MSG_CANCEL)
      return NULL;

    answer = await_value();
  }
}

static void *blackhole(void *arg) {
  (void)arg;
  void *answer = init_protocol();
  while (answer != MSG_CANCEL) {
    assert(is_value_message(answer) && "expected value");
    assert(message_value(answer) == blackhole_expected + blackhole_count &&
           "unexpected pipeline value");
    ++blackhole_count;
    answer = await_value();
  }
  return NULL;
}

static void pipeline_append(pipeline_t *pipeline, pipe_t *pipe) {
  assert(pipeline->count < pipeline->capacity && "pipeline is full");
  pipeline->pipes[pipeline->count++] = pipe;
}

// expoPipe 0 is one increment stage. expoPipe n composes two copies
// of expoPipe (n - 1), so the expanded pipeline contains exactly 2^n
// stages.
static void expo_pipe(pipeline_t *pipeline, uint32_t depth) {
  if (depth == 0) {
    pipeline_append(pipeline, pipe_alloc(increment, 0));
    return;
  }
  expo_pipe(pipeline, depth - 1);
  expo_pipe(pipeline, depth - 1);
}

// test7 / nested:
// blackhole <+< takePure 1000 <+< expoPipe depth <+< produceFrom 0
//
// The scheduler is deliberately outside the fibers. Asyncify uses a
// single linear-memory shadow stack and cannot safely nest
// fiber_resume calls inside fibers that are themselves rewinding. A
// flat driver preserves the expanded pipe and all its suspension
// points without corrupting that stack.
static void nested(uint32_t depth) {
  uint32_t const increment_count = (uint32_t)1 << depth;
  pipeline_t expo = {
      .pipes = malloc(increment_count * sizeof(pipe_t *)),
      .count = 0,
      .capacity = increment_count,
  };
  assert(expo.pipes && "failed to allocate expoPipe");
  expo_pipe(&expo, depth);
  assert(expo.count == increment_count && "incorrect expoPipe size");

  pipe_t *source = pipe_alloc(nats, 0);
  pipe_t *limit = pipe_alloc(take, TAKE_COUNT);
  pipe_t *sink = pipe_alloc(blackhole, 0);
  init_pipe(source);
  for (uint32_t i = 0; i < expo.count; ++i)
    init_pipe(expo.pipes[i]);
  init_pipe(limit);
  init_pipe(sink);

  fiber_result_t status;
  void *operation = fiber_resume(source->fiber, value_message(0), &status);
  assert(status == FIBER_YIELD && is_value_message(operation) &&
         "producer protocol violation");

  for (uint32_t item = 0; item < TAKE_COUNT; ++item) {
    for (uint32_t i = 0; i < expo.count; ++i) {
      operation = fiber_resume(expo.pipes[i]->fiber, operation, &status);
      assert(status == FIBER_YIELD && is_value_message(operation) &&
             "expoPipe protocol violation");
    }

    operation = fiber_resume(limit->fiber, operation, &status);
    assert(status == FIBER_YIELD && is_value_message(operation) &&
           "take protocol violation");
    operation = fiber_resume(sink->fiber, operation, &status);
    assert(status == FIBER_YIELD && operation == MSG_AWAIT &&
           "blackhole protocol violation");

    operation = fiber_resume(limit->fiber, value_message(0), &status);
    if (item + 1 == TAKE_COUNT) {
      assert(status == FIBER_OK && operation == NULL &&
             "take completion protocol violation");
    } else {
      assert(status == FIBER_YIELD && operation == MSG_AWAIT &&
             "take acknowledgement protocol violation");
    }

    for (uint32_t i = expo.count; i > 0; --i) {
      operation =
          fiber_resume(expo.pipes[i - 1]->fiber, value_message(0), &status);
      assert(status == FIBER_YIELD && operation == MSG_AWAIT &&
             "expoPipe acknowledgement protocol violation");
    }

    if (item + 1 < TAKE_COUNT) {
      operation = fiber_resume(source->fiber, value_message(0), &status);
      assert(status == FIBER_YIELD && is_value_message(operation) &&
             "producer protocol violation");
    }
  }

  cancel_pipe(source);
  for (uint32_t i = 0; i < expo.count; ++i) {
    cancel_pipe(expo.pipes[i]);
    pipe_free(expo.pipes[i]);
  }
  cancel_pipe(sink);
  pipe_free(source);
  pipe_free(limit);
  pipe_free(sink);
  free(expo.pipes);
}

int main(int argc, char *argv[]) {
  if (argc != 2) {
    puts("usage: pipes DEPTH");
    return 1;
  }

  char *end;
  unsigned long const parsed = strtoul(argv[1], &end, 10);
  if (argv[1][0] == '\0' || *end != '\0' || parsed > MAX_EXPO_DEPTH) {
    puts("invalid DEPTH");
    return 1;
  }
  uint32_t const depth = (uint32_t)parsed;

  blackhole_count = 0;
  blackhole_expected = (uint32_t)1 << depth;

  fiber_init();
  nested(depth);
  fiber_finalize();

  assert(blackhole_count == TAKE_COUNT && "unexpected blackhole input count");
  return 0;
}
