#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <fiber_switch.h>

#define export(NAME) __attribute__((export_name(NAME)))

// Global state for scheduling
uint32_t next = 0;
fiber_t fiber_1;
fiber_t fiber_2;

fiber_t runner;

export("print_get")
void print_get(int32_t n, int32_t m) {
  printf("debug_n getting continuation line number: %d, index: %d\n", n, m);
}

export("print_set")
void print_set(int32_t n, int32_t m) {
  printf("debug_m SETTING continuation line number: %d, index: %d\n", n, m);
}

export("print_return")
void print_return(int32_t n, int32_t m) {
  printf("debug_return calling print-return on line number: %d, index: %d\n", n, m);
}

void scheduler() {
  //fiber_t caller;
  next++;
  if (next == 1) {
    printf("scheduler: next = %d\n", next);
    fiber_switch(fiber_2, NULL, &fiber_1); }
  // this is the step that breaks
  else if (next == 2) {
    printf("scheduler: next = %d\n", next);
    fiber_switch(fiber_1, NULL, &fiber_2);  }
  else if (next == 3) {
    printf("scheduler: next = %d\n", next);
    fiber_switch_return(fiber_2, NULL); }
  else if (next == 4) {
    printf("scheduler: next = %d\n", next);
    fiber_switch_return(runner, NULL); }
}

void* f1(__attribute__((unused)) void *arg, fiber_t caller) {
  runner = caller;
  printf("f1 1\n");
  scheduler();

  // here
  printf("f1 2\n");
  scheduler();

  printf("f1 unreachable\n");
  return NULL;
}

void* f2(__attribute__((unused)) void *arg, __attribute__((unused)) fiber_t caller) {
  printf("f2 1\n");

  scheduler();
  // the below doesn't get called by wasmfx

  printf("f2 2\n");
  scheduler();
  printf("f2 unreachable\n");
  return NULL;
}

void *prog(int __attribute__((unused)) argc, char __attribute__((unused)) **argv) {
  // Spawn workers.
  fiber_1 = fiber_alloc(f1);
  fiber_2 = fiber_alloc(f2);

  fiber_t switched_from;

  fiber_switch(fiber_1, NULL, &switched_from);

  printf("back to prog\n");

  fiber_free(fiber_1);
  fiber_free(fiber_2);

  return NULL;
}

int main(int argc, char **argv) {
  fiber_main(prog, argc, argv);
  printf("Done in main\n");

  return 0;
}
