// Cooperative calculation of primes
#include <assert.h>
#include <ctype.h>
#include <errno.h>
#include <fiber.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_PRIMES_LIMIT 203280220

static bool filter(int32_t my_prime) {
  bool divisible = false;
  int32_t candidate = (int32_t)(intptr_t)fiber_yield(NULL);
  while (candidate > 0) {
    divisible = (candidate % my_prime) == 0;
    candidate = (int32_t)(intptr_t)fiber_yield((void*)(intptr_t)divisible);
  }
  return false;
}

static bool sanitise_input_number(const char *s) {
  for (; *s != '\0'; s++) {
    if (!isdigit(*s)) return false;
  }
  return true;
}

static void print_input_error_and_exit(void) {
  fprintf(stderr, "error: input must be a positive integer in the interval [1, %d]\n", MAX_PRIMES_LIMIT);
  exit(1);
}

int main(int argc, char **argv) {
  if (argc < 2 || argc > 3) {
    printf("usage: %s [-q] <n>\n", argv[0]);
    exit(1);
  }

  size_t n_idx = argc == 2 ? 1 : 2;
  bool quiet = argc == 3 && strcmp(argv[1], "-q") == 0;

  if (!sanitise_input_number(argv[n_idx])) {
    print_input_error_and_exit();
  }

  errno = 0;
  long int result = strtol(argv[n_idx], NULL, 10 /* base 10 */);
  if (result <= 0 && (errno == ERANGE || errno == EINVAL || result > MAX_PRIMES_LIMIT)) {
    print_input_error_and_exit();
  }
  uint32_t max_primes = (uint32_t)result; // maximum number of primes to compute.
  uint32_t p = 0;                         // number of primes computed so far.
  int32_t i = 2;                          // the current candidate prime number.

  fiber_init();
  fiber_t *filters = (fiber_t*)malloc(sizeof(fiber_t) * max_primes);
  fiber_result_t status;

  while (p < max_primes) {
    bool divisible = false;
    for (uint32_t j = 0; j < p; j++) {
      divisible = (bool)(intptr_t)fiber_resume(filters[j], (void*)(intptr_t)i, &status);
      assert(status == FIBER_YIELD);
      if (divisible) break;
    }
    if (!divisible) {
      if (!quiet) {
        char sbuf[11]; // 10 digits + null character.
        int32_t len = snprintf(sbuf, sizeof(sbuf), "%" PRId32 " ", i);
        if (len < 1) {
          fprintf(stderr, "error: failed to convert int32_t to a string\n");
          abort();
        }
        for (int32_t i = 0; i < len; i++) {
          putc(sbuf[i], stdout);
        }
      }
      fiber_t filter_fiber = fiber_alloc((fiber_entry_point_t)(void*)filter);
      (void)fiber_resume(filter_fiber, (void*)(intptr_t)i, &status);
      assert(status == FIBER_YIELD);
      filters[p++] = filter_fiber;
    }
    i++;
  }
  if (!quiet) {
    putc('\n', stdout);
  }

  assert(p == max_primes);
  // Clean up
  for (uint32_t i = 0; i < p; i++) {
    (void)fiber_resume(filters[i], (void*)(intptr_t)0, &status);
    assert(status == FIBER_OK);
    fiber_free(filters[i]);
  }
  free(filters);
  fiber_finalize();

  return 0;
}
