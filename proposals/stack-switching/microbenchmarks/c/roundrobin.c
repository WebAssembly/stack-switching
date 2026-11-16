// Benchmark that runs 10 fibers at the same time, each fiber increments 
// a number. Intended as an itersum-analogue that exhibits what we get 
// from using the switch instruction over resume/suspend in a green 
// threads-like setting.

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <assert.h>

#include <fiber.h>

// Values for `NUM_WORKERS` and `SWITCHES`
#include "params.h"

// Global state for scheduler
bool keep_going = true;
uint32_t next = 0;

// Array of workers
static fiber_t workers[NUM_WORKERS];

// Array of statuses
static bool worker_status[NUM_WORKERS];

// Array of results
static int32_t results[NUM_WORKERS];

void update_state() {
  // Update global variable `next` to point to the next available worker (if any).
  uint32_t i = 0;
  for (next = (next + 1) % NUM_WORKERS; i < NUM_WORKERS; ++i, next = (next+1) % NUM_WORKERS) {
    if (!worker_status[next]) {
      break;
    }
  }
  // Update keep_going variable too
  keep_going = i < NUM_WORKERS;
}

void scheduler() {
  fiber_result_t status;
  // Run next worker for one step.
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
  // Find the next available worker and determine if we should keep going.
  update_state();
  } while (keep_going);
}

void* increment(void *arg) {
  int32_t *result = (int32_t*)(intptr_t)arg;
  for (uint32_t i = 0; i < SWITCHES; ++i) {
    // Increment result
    (*result)++;
    (void)fiber_yield(NULL);
  }
  return NULL;
}

int main(void) {
  fiber_init();

  // Spawn workers.
  for (uint32_t i = 0; i < NUM_WORKERS; ++i) {
    workers[i] = fiber_alloc(increment);
  }
  // Initialize statuses
  for (uint32_t i = 0; i < NUM_WORKERS; ++i) {
    worker_status[i] = false;
  }

  // Call scheduler to start running workers.
  scheduler();

  #if PRINT_RESULTS
  for (uint32_t i = 0; i < NUM_WORKERS; ++i) {
    printf("%d\n", results[i]);
  }
  #endif
  
  // Validate results and clean up
  for (uint32_t i = 0; i < NUM_WORKERS; ++i) {
    assert(results[i] == SWITCHES);
    fiber_free(workers[i]);
  }

  fiber_finalize();
}

#undef PRINT_RESULTS
#undef NUM_WORKERS
#undef SWITCHES