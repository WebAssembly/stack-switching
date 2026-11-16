// An abstract effectful implementation of stateful counting.

#include <assert.h>
#include <stdint.h>
#include <stdlib.h>

#include <fiber.h>

struct cmd {
  enum { GET, PUT } op;
  uint32_t payload; // ignored for GET.
};

uint32_t state_get(struct cmd *cmd) {
  cmd->op = GET;
  return (uint32_t)(uintptr_t)fiber_yield(cmd);
}

void state_put(struct cmd *cmd, uint32_t new_state) {
  cmd->op = PUT;
  cmd->payload = new_state;
  (void)fiber_yield(cmd);
}

void* count(void* __attribute__((unused)) arg) {
  struct cmd *cmd = (struct cmd*)malloc(sizeof(struct cmd));
  for (; state_get(cmd) < 10000000u; state_put(cmd, state_get(cmd) + 1u)) {}
  free(cmd);
  return NULL;
}

uint32_t eval_state(fiber_entry_point_t fn, uint32_t st) {
  fiber_t f = fiber_alloc(fn);
  fiber_result_t status;

  void *ans = fiber_resume(f, NULL, &status);
  assert(status != FIBER_ERROR && "the stateful computation entered an error state");

  while (status != FIBER_OK) {
    struct cmd const *cmd = (struct cmd const*)ans;
    switch (cmd->op) {
    case GET: {
      ans = fiber_resume(f, (void*)(uintptr_t)st, &status);
      break;
    }
    case PUT: {
      st = cmd->payload;
      ans = fiber_resume(f, NULL, &status);
    break;
    }
    }
  }
  fiber_free(f);
  return st;
}

int main(void) {
  fiber_init();
  uint32_t const ans = eval_state(count, 0);
  assert(ans == 10000000u && "wrong result");
  fiber_finalize();
  return 0;
}
