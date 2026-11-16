// Monte Carlo PI estimation

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <assert.h>

#include <fiber.h>

// Values for `PRINT_RESULTS`, `NUM_TASKS`, `BATCH_SIZE`, `YIELDS`
#include "params.h"

// Global state for scheduler
bool keep_going = true;
uint32_t next = 0;

// Array of results
static double results[NUM_TASKS];

// Array of workers
static fiber_t workers[NUM_TASKS];

// Array of statuses
static bool worker_status[NUM_TASKS];

void update_state() { 
  // Update global variable `next` to point to the next available worker (if any).
  uint32_t i = 0;
  for (next = (next + 1) % NUM_TASKS; i < NUM_TASKS; ++i, next = (next+1) % NUM_TASKS) {
    if (!worker_status[next]) {
      break;
    }
  }
   // Update keep_going variable too
  keep_going = i < NUM_TASKS;
}

void scheduler() {
  fiber_result_t status;
  do {
    (void)fiber_resume(workers[next], &results[next], &status);
    switch (status) {
    case FIBER_OK:
      worker_status[next] = true;
      break;
    case FIBER_YIELD:
      break;
    case FIBER_ERROR:
      abort(); // A fiber should never enter the error state.
      break;
    }
    update_state();
  } while (keep_going);
}

void* monte_carlo(void *arg) {
  double *pi = (double*)(intptr_t)arg;

  double inside = 0;
  double total = 0;

  for (uint32_t i = 0; i < YIELDS; ++i) {
    for (uint32_t j = 0; j < BATCH_SIZE; ++j) {
      double const x = (double)rand() / ((double)RAND_MAX + 1);
      double const y = (double)rand() / ((double)RAND_MAX + 1);

      double const dist = x * x + y * y;

      if (fabs(dist - 1.0) < 0.0000000001 || dist < 1.0) {
        inside += 1.0;
      }

      total += 1.0;
    }

    (void)fiber_yield(NULL);
  }

  *pi = (4.0 * inside) / total;

  return NULL;
}

int main(void) {
  fiber_init();

  // Initialize with fixed seed for deterministic runs
  srand(0xC0FFEE);

  // Spawn workers.
  for (uint32_t i = 0; i < NUM_TASKS; ++i) {
    workers[i] = fiber_alloc(monte_carlo);
  }
  // Initialize statuses
  for (uint32_t i = 0; i < NUM_TASKS; ++i) {
    worker_status[i] = false;
  }

  // Start the scheduler loop which will run the workers
  scheduler();

  #if PRINT_RESULTS
  for (uint32_t i = 0; i < NUM_TASKS; ++i) {
    printf("%f\n", results[i]);
  }
  #endif

  // Validate results and clean up
  for (uint32_t i = 0; i < NUM_TASKS; ++i) {
      assert(results[i] <= 4.0 
        && "Result should be less than or equal to 4.0 as long as worker runs at least once.");
    fiber_free(workers[i]);
  }

  fiber_finalize();
}
#undef PRINT_RESULTS
#undef NUM_TASKS
