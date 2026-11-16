// Benchmark that runs 10 fibers at the same time, each fiber increments 
// a number. Intended as an itersum-analogue that exhibits what we get 
// from using the switch instruction over resume/suspend in a green 
// threads-like setting.

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <assert.h>

#include <fiber_switch.h>

// Values for `NUM_WORKERS` and `SWITCHES`
#include "params.h"

// Array of workers
static fiber_t workers[NUM_WORKERS];

// Array of statuses
static bool worker_status[NUM_WORKERS];

// Array of results
static int32_t results[NUM_WORKERS];

void find_worker(bool* keep_going, uint32_t* next) { 
  // Update global variable `next` to point to the next available worker (if any).
  uint32_t i = 0;
  for (*next = (*next + 1) % NUM_WORKERS; i < NUM_WORKERS; ++i, *next = (*next+1) % NUM_WORKERS) {
    if (!worker_status[*next]) {
      break;
    }
  }
  // Update keep_going variable too
  *keep_going = i < NUM_WORKERS - 1;
}

void scheduler(bool worker_done, fiber_t caller) { 
  static bool keep_going = true;
  static uint32_t next = 0;

  if (worker_done) {
    // Mark the current worker as done.
    worker_status[next] = true;
    // Find the next available worker and determine if we should keep going.
    find_worker(&keep_going, &next);
    if (!keep_going) {
      // If no more available workers, return to the outer loop.     
      return;
    } else {
      // If the current worker is done, switch-return to the next available worker.
      fiber_switch_return(workers[next], &results[next]);
    }    
  }
  // Otherwise, simply determine and switch onto the next available worker.
  find_worker(&keep_going, &next);
  fiber_switch(workers[next],&results[next],&caller); 
}

void* increment(void *arg, fiber_t caller) {
  // Pointer to final result
  assert(arg && "null argument");
  int32_t result = *((int32_t*)(intptr_t)arg);

  for (uint32_t i = 0; i < SWITCHES; ++i) {
    // Increment result
    ++result;
    // Scheduler will call switch
    scheduler(false, caller);
  }

  // Save result
  *(int32_t *)arg = result;
  // Scheduler will call switch-return
  scheduler(true, caller);
  // unreachable
  return NULL;
}

void *prog(int __attribute__((unused)) argc, char __attribute__((unused)) **argv) {
  // Spawn workers.
  for (uint32_t i = 0; i < NUM_WORKERS; ++i) {
    workers[i] = fiber_alloc(increment);
  }
  // Initialize statuses
  for (uint32_t i = 0; i < NUM_WORKERS; ++i) {
    worker_status[i] = false;
  }
  // Switch onto the initial worker
  fiber_switch(workers[0], &results[0], &workers[0]);
  return 0;
}

int main(int argc, char **argv) {
  fiber_main(prog, argc, argv);

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
  
  return 0;
}

#undef PRINT_RESULTS
#undef NUM_WORKERS
#undef SWITCHES
