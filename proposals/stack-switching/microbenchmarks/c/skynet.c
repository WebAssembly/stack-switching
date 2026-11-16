// The Skynet benchmark

#include <assert.h>
#include <stdio.h>
#include <stdint.h>

#include <fiber.h>

#define TOTAL_NUM_LEAVES 1000000U
#define MAX_HEIGHT 6U
uint32_t const num_levels = MAX_HEIGHT;
uint64_t const children_per_level = 10;
uint64_t const reference = 499999500000;

struct skynet_data {
  uint64_t num;
  uint32_t level;
};

struct skynet_data* capture_vars(uint32_t level, uint64_t num) {
  // We need only allocate containers for the spine of the induced
  // concurrency tree.
  static struct skynet_data containers[MAX_HEIGHT];
  static uint32_t next = 0;

  assert(next < MAX_HEIGHT);
  struct skynet_data *result = &containers[next];
  result->level = level;
  result->num = num;

  next = (next + 1) % MAX_HEIGHT;
  return result; // reference to data section
}

typedef struct boxed_uint64_t {
  uint64_t val;
} boxed_u64;

boxed_u64* box_u64(uint64_t val) {
  // We need only one box per leaf in the induced concurrency tree,
  // however, only one leaf is active at a time and it fully completes
  // before another leaf is invoked, thus we need only to allocate one
  // box.
  static boxed_u64 u64;
  u64.val = val;
  return &u64; // reference to data section
}

static uint64_t result = 0;

__attribute__((noinline))
void* skynet_closure(void *args) {
  struct skynet_data *vars = (struct skynet_data*)args;
  if (vars->level == 0) {
    (void)fiber_yield(box_u64(vars->num));
    return (void*)(uintptr_t)0; // dummy value
  } else {
    uint32_t const level = vars->level - 1;
    uint64_t const lb = vars->num * children_per_level;
    uint64_t const ub = lb + children_per_level;
    fiber_result_t status;
    for (uint64_t i = lb; i < ub; i++) {
      fiber_t f = fiber_alloc(skynet_closure);
      boxed_u64 *ans = (boxed_u64*)fiber_resume(f, capture_vars(level, i), &status);
      if (level == 0) {
        assert(status == FIBER_YIELD);
        result += ans->val;
        // Finish the residual fiber computation.
        (void)fiber_resume(f, NULL, &status);
        assert(status == FIBER_OK);
      } else {
        assert(status == FIBER_OK);
      }
      fiber_free(f);
    }
    return NULL;
  }
}

__attribute__((noinline))
uint64_t skynet(uint32_t level, uint64_t num) {
  struct skynet_data vars = { .level = level, .num = num };
  assert(vars.level == level);
  // Passing this stack reference is OK because it wont be accessed
  // across context switching.
  (void)skynet_closure((void*)&vars);
  return result;
}

uint32_t ipow(uint32_t q, uint32_t p) {
  if (p == 0) return 1;
  else return q * ipow(q, p - 1);
}

int main(void) {
  fiber_init();
  assert(ipow(children_per_level, num_levels) == TOTAL_NUM_LEAVES && "parameters are out of sync");
  assert(num_levels == MAX_HEIGHT && "num_levels must be equal to MAX_HEIGHT");

  uint64_t const ans = skynet(6, 0);
  assert(ans == reference && "wrong result");

  fiber_finalize();
  return 0;
}
