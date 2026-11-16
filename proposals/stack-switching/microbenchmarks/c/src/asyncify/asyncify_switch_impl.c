// An asyncify implementation of the basic fiber interface.

#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
// for printing things, remove later
#include <assert.h>

#include "fiber_switch.h"
#define import(NAME) __attribute__((import_module("asyncify"),import_name(NAME)))


/** Asyncify imports **/
// The following functions are asyncify primitives:
// * asyncify_start_unwind(iptr): initiates a continuation
//   capture. The argument `iptr` is a pointer to an asyncify stack.
// * asyncify_stop_unwind(): delimits a capture continuations.
// * asyncify_start_rewind(iptr): initiates a continuation
//   reinstatement. The argument `iptr` is a pointer to an asyncify
//   stack.
// * asyncfiy_stop_rewind(): delimits the extent of a continuation
//  reinstatement.
extern
import("start_unwind")
void asyncify_start_unwind (void*);

extern
import("stop_unwind")
void asyncify_stop_unwind(void);

extern
import("start_rewind")
void asyncify_start_rewind (void*);

extern
import("stop_rewind")
void asyncify_stop_rewind(void);

// The default stack size is 2MB.
static const size_t default_stack_size = ASYNCIFY_DEFAULT_STACK_SIZE;

// We track the currently active fiber via this global variable.
static volatile fiber_t active_fiber = NULL;

// Fiber states:
// * ACTIVE: the fiber is actively executing.
// * YIELDING: the fiber is suspended.
// * DONE: the fiber is finished (i.e. run to completion).
typedef enum { ACTIVE, YIELDING, DONE } fiber_state_t;

// A fiber stack is an asyncify stack, i.e. a reserved area of memory
// for asyncify to store the call chain and locals. Note: asyncify
// assumes `end` is at offset 4. Moreover, asyncify stacks grow
// upwards, so it must be that top <= end.
struct  __attribute__((packed)) fiber_stack {
  uint8_t *top;
  uint8_t *end;
  uint8_t *buffer;
};
static_assert(sizeof(uint8_t*) == 4, "sizeof(uint8_t*) != 4");
static_assert(sizeof(struct fiber_stack) == 12, "struct fiber_stack: No padding allowed");

// The fiber structure embeds the asyncify stack (struct fiber_stack),
// its state, an entry point, and two buffers for communicating
// payloads and managing fiber local data, respectively.
struct fiber {
  /** The underlying asyncify stack. */
  struct fiber_stack stack;
  // Fiber state.
  fiber_state_t state;
  // Initial function to run on the fiber.
  fiber_entry_point_t entry;
  // The fiber that we either switched from or will be switching to.
  fiber_t fiber_arg;
  // Payload buffer.
  void *arg;
};

// Allocates a fiber stack of size stack_size.
static struct fiber_stack fiber_stack_alloc(size_t stack_size) {
  uint8_t *buffer = malloc(sizeof(uint8_t) * stack_size);
  assert(buffer != NULL && "fiber_stack_alloc: malloc failed");
  uint8_t *top = buffer;
  uint8_t *end = buffer + stack_size;
  struct fiber_stack stack = (struct fiber_stack) { top, end, /* NULL, */ buffer };
  return stack;
}

// Frees an allocated fiber_stack.
static void fiber_stack_free(struct fiber_stack fiber_stack) {
  free(fiber_stack.buffer);
}

#if defined STACK_POOL_SIZE && STACK_POOL_SIZE > 0
// Fiber stack pool
struct stack_pool {
  int32_t next;
  struct fiber_stack stacks[STACK_POOL_SIZE];
};

static struct fiber_stack stack_pool_next(volatile struct stack_pool *pool) {
  assert(pool->next >= 0 && pool->next < STACK_POOL_SIZE);
  return pool->stacks[pool->next++];
}

static void stack_pool_reclaim(volatile struct stack_pool *pool, struct fiber_stack stack) {
  assert(pool->next > 0 && pool->next <= STACK_POOL_SIZE);
  pool->stacks[--pool->next] = stack;
  return;
}

static volatile struct stack_pool pool;
#endif

// Allocates a fiber object.
// NOTE: the entry point `fn` should be careful about uses of `printf`
// and related functions, as they can cause asyncify to corrupt its
// own state. See `wasi-io.h` for asyncify-safe printing functions.
fiber_t fiber_sized_alloc(size_t stack_size, fiber_entry_point_t entry) {
  fiber_t fiber = (fiber_t)malloc(sizeof(struct fiber));
  assert(fiber != NULL && "fiber_sized_alloc: malloc failed");
#if defined STACK_POOL_SIZE && STACK_POOL_SIZE > 0
  (void)stack_size;
  fiber->stack = stack_pool_next(&pool);
  // TODO(dhil): It may be necessary to reset the top pointer.  I'd
  // need to test on a larger example.
  fiber->stack.top = fiber->stack.buffer;
#else
  fiber->stack = fiber_stack_alloc(stack_size);
#endif
  fiber->state = ACTIVE;
  fiber->entry = entry;
  fiber->fiber_arg = NULL;
  fiber->arg = NULL;
  return fiber;
}

// Allocates a fiber object with the default stack size.
__attribute__((noinline))
fiber_t fiber_alloc(fiber_entry_point_t entry) {
  return fiber_sized_alloc(default_stack_size, entry);
}

// Frees a fiber object.
__attribute__((noinline))
void fiber_free(fiber_t fiber) {
#if defined STACK_POOL_SIZE && STACK_POOL_SIZE > 0
  stack_pool_reclaim(&pool, fiber->stack);
#else
  fiber_stack_free(fiber->stack);
#endif
  free(fiber);
}

// Some checks we do on a target fiber before switching to it
static bool target_fiber_valid(fiber_t fiber) {
  // don't switch to a done or null fiber
  return fiber != NULL || fiber->state != DONE || fiber != active_fiber;
}

__attribute__((noinline))
void* fiber_switch(fiber_t fiber, void *arg, fiber_t *switched_from) {
  assert(switched_from != NULL && "the container must be non-null");

  if (!target_fiber_valid(fiber)) abort();

  if (active_fiber->state == ACTIVE) {
    // We are switching from this fiber to `fiber`.
    // Save payload on target fiber.
    fiber->fiber_arg = active_fiber;
    fiber->arg = arg;
    // Save target
    active_fiber->fiber_arg = fiber;
    // Change fiber status.
    active_fiber->state = YIELDING;
    // Start unwinding.
    asyncify_start_unwind(&active_fiber->stack);
    return NULL;
  } else {
    // Otherwise we must be switched to
    asyncify_stop_rewind();
    active_fiber->state = ACTIVE;
    assert(switched_from != NULL);
    *switched_from = active_fiber->fiber_arg;
    return active_fiber->arg;
  }
}

/** Switches to `target` and destroys currently executing `fiber`. **/
__attribute__((noinline))
void fiber_switch_return(fiber_t fiber, void *arg) {

  if (!target_fiber_valid(fiber)) abort();

  // We are switching from this fiber to `fiber`.
  // Save payload on target fiber.
  fiber->fiber_arg = NULL;
  fiber->arg = arg;
  // Save target
  active_fiber->fiber_arg = fiber;
  // Change status
  active_fiber->state = YIELDING;
  // Start unwinding.
  asyncify_start_unwind(&active_fiber->stack);
}

// Noop when stack pooling is disabled.
void fiber_init(void) {
#if defined STACK_POOL_SIZE && STACK_POOL_SIZE > 0
  pool.next = STACK_POOL_SIZE;
  for (uint32_t i = 0; i < STACK_POOL_SIZE; i++) {
    stack_pool_reclaim(&pool, fiber_stack_alloc(default_stack_size));
  }
  assert(pool.next == 0);
#endif
}

// Noop when stack pooling is disabled.
void fiber_finalize(void) {
#if defined STACK_POOL_SIZE && STACK_POOL_SIZE > 0
  assert(pool.next == 0);
  for (uint32_t i = 0; i < STACK_POOL_SIZE; i++) {
    fiber_stack_free(stack_pool_next(&pool));
  }
  assert(pool.next == STACK_POOL_SIZE);
#endif
}

static int argc_ = 0;
static char **argv_ = NULL;
static void *(*main_)(int, char**) = NULL;
static void *main_closure(void __attribute__((unused)) *arg, fiber_t __attribute__((unused)) caller) {
  return main_(argc_, argv_);
}

void *fiber_main(void *(*main)(int, char **), int argc, char **argv) {
  // Main cannot be null
  assert(main != NULL);

  // Initialize the runtime
  fiber_init();

  // The first invocation is special as we pass it argc and argv.
  main_ = main;
  argc_ = argc;
  argv_ = argv;

  // Allocate the main fiber (running the initial function of our program)
  fiber_t main_fiber = fiber_alloc(main_closure);
  active_fiber = main_fiber;
  active_fiber->arg = NULL;
  active_fiber->fiber_arg = NULL;

  void *result = NULL;

  while (active_fiber->state != DONE) {
    // If the fiber was previously yielding then we need to rewind the
    // state.
    if (active_fiber->state == YIELDING) {
      asyncify_start_rewind(&active_fiber->stack);
    }

    // Run the fiber
    result = active_fiber->entry(active_fiber->arg, active_fiber->fiber_arg);
    asyncify_stop_unwind();

    // If the active fiber isn't yielding at this point, it should be done
    if (active_fiber->state == YIELDING){
      // Swap active fiber
      fiber_t prev = active_fiber;
      active_fiber = active_fiber->fiber_arg;
      prev->fiber_arg = NULL;
    } else {
      active_fiber->state = DONE;
    }
  }

  fiber_free(main_fiber);
  fiber_finalize();
  return result;
}


#undef import
