// Monte Carlo PI estimation

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <assert.h>

#include <fiber_switch.h>

// Values for `PRINT_RESULTS`, `NUM_TASKS`, `BATCH_SIZE`, `YIELDS`
#include "params.h"

// Array of results
static double results[NUM_TASKS];

// Array of workers
static fiber_t workers[NUM_TASKS];

// Array of statuses
static bool worker_status[NUM_TASKS];

void find_worker(bool* keep_going, uint32_t* next) { 
  // Update global variable `next` to point to the next available worker (if any).
  uint32_t i = 0;
  for (*next = (*next + 1) % NUM_TASKS; i < NUM_TASKS; ++i, *next = (*next+1) % NUM_TASKS) {
    if (!worker_status[*next]) {
      break;
    }
  }
  // Update keep_going variable too
  *keep_going = i < NUM_TASKS - 1;
}

void scheduler(bool worker_done, fiber_t caller) { 
  static bool keep_going = true;
  static uint32_t next = 0;

  if (worker_done) {
    // Mark the current worker as done.
    worker_status[next] = true;
    // Determine whether we should keep going.
    find_worker(&keep_going, &next);
    if (!keep_going) {
      // If no more available workers, return to the outer loop.     
      return;
    } else {
      // If the current worker is done, switch-return to the next available worker.
      fiber_switch_return(workers[next], &results[next]);
    }    
  }
  // Otherwise, simply switch onto the next available worker.
  find_worker(&keep_going, &next);
  fiber_switch(workers[next],&results[next],&caller); 
}

void* monte_carlo(void *arg, fiber_t caller) {
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
  scheduler(false, caller);
  }

  *pi = (4.0 * inside) / total;
  scheduler(true, caller);
  // unreachable
  return NULL;
}

void *prog(int __attribute__((unused)) argc, char __attribute__((unused)) **argv) {
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

  // Switch onto the initial worker
  fiber_switch(workers[0], &results[0], &workers[0]);
  
  return NULL;
}

int main(int argc, char **argv) {

  fiber_main(prog, argc, argv);
  
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

  return 0;
}