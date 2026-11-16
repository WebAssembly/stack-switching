// Cooperative printing of "hello world"
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <fiber.h>

void* hello(void *arg) {
  static const char s[] = "hlowrd";
  uint32_t i = (uint32_t)(uintptr_t)arg;

  while (i < strlen(s)) {
    putc(s[i], stdout);
    i = (uint32_t)(uintptr_t)fiber_yield(NULL);
  }

  return NULL;
}

void* world(void *arg) {
  static const char s[] = "el ol";
  uint32_t i = (uint32_t)(uintptr_t)arg;

  while (i < strlen(s)) {
    putc(s[i], stdout);
    i = (uint32_t)(uintptr_t)fiber_yield(NULL);
  }

  return NULL;
}

int main(void) {
  fiber_init();
  fiber_result_t status;
  fiber_t hello_fiber = fiber_alloc(hello);
  fiber_t world_fiber = fiber_alloc(world);

  bool hello_done = false;
  bool world_done = false;

  uint32_t i = 0;
  while (!hello_done && !world_done) {
    if (!hello_done) {
      (void)fiber_resume(hello_fiber, (void*)(uintptr_t)i, &status);
      assert(status != FIBER_ERROR);
      if (status == FIBER_OK) hello_done = true;
    }

    if (!world_done) {
      (void)fiber_resume(world_fiber, (void*)(uintptr_t)i, &status);
      assert(status != FIBER_ERROR);
      if (status == FIBER_OK) world_done = true;
    }
    i++;
  }

  putc('\n', stdout);
  fflush(stdout);

  fiber_free(hello_fiber);
  fiber_free(world_fiber);

  fiber_finalize();
  return 0;
}
