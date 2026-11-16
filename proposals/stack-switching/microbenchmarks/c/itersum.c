// This benchmark suspends/resumes in a tight loop modeling a generator
// pattern. The suspender generates successive numbers, 0, 1, 2, ...
// the resumer receives them and sums them up. This is more or less the
// tightest suspend/resume loop you can make in fiber-c. Adding up the
// numbers provides a convenient way to sanity-check that the work is
// really being done.
//
// Invoke with an argument, the number of iterations, conventionally
// 100,000,000.
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <fiber.h>


// Yields the natural numbers 0, 1, ... up to "arg"
void* range(void *arg) {
  int32_t max = (int32_t)(intptr_t)arg;
  for (int32_t i = 0; i < max; i++) {
    fiber_yield((void*)(intptr_t)i);
  }
  return NULL;
}

int32_t run(int32_t max) {
  fiber_result_t status;
  fiber_t gen = fiber_alloc(range);
  int32_t result = 0, i = 0;

  void* val = fiber_resume(gen, (void*)(intptr_t)max, &status);

  while (status == FIBER_YIELD && i++ < max) {
    result += (int32_t)(intptr_t)val;
    val = fiber_resume(gen, NULL, &status);
  }

  fiber_free(gen);
  return result;
}

int main(int argc, char** argv) {
  if (argc != 2) {
    fprintf(stderr, "Wrong number of arguments. Expected: 1");
    return -1;
  }
  fiber_init();

  int i = atoi(argv[1]);

  int32_t result = run(i);

  printf("%d\n", result);

  fiber_finalize();
  return 0;
}
