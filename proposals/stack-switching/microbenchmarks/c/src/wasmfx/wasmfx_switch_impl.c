// An implementation of the fiber_switch.h interface using wasmfx continuations
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>

#include "fiber_switch.h"

#define import(NAME) __attribute__((import_module("fiber_switch_wasmfx_imports"), import_name(NAME)))

// Type for indices into the continuation table `$conts` on the Wasm side. In
// this implementation, we consider `fiber_t` (which is a pointer to an
// incomplete type) to be equivalent to `cont_table_index_t` and freely convert
// between the two.
typedef uintptr_t cont_table_index_t;

// Initial size of the `$conts` table. Keep this value in sync with the
// corresponding (table ...) definition.
static const uint32_t initial_table_capacity = WASMFX_CONT_TABLE_INITIAL_CAPACITY;

// The current capacity of the `$conts` table.
static uint32_t cont_table_capacity = initial_table_capacity;
// Number of entries at the end of `$conts` table that we haven't used so
// far. Initialised to initial_table_capacity - 1 because we reserve index 0 
// of the table for null checks.
// Invariant:
// `cont_table_unused_size` + `free_list_size` <= `cont_table_capacity - 1`
static_assert(WASMFX_CONT_TABLE_INITIAL_CAPACITY > 0, "WASMFX_CONT_TABLE_INITIAL_CAPACITY must be greater than 0");
static uint32_t cont_table_unused_size = initial_table_capacity - 1;

// This is a stack of indices into `$conts` that we have previously used, but
// subsequently freed. Allocated as part of `fiber_init`. Invariant: Once
// allocated, the capacity of the `free_list` (i.e., the number of `size_t`
// values we allocate memory for) is the same as `cont_table_capacity`.
static uint32_t *free_list = NULL;
// Number of entries in `free_list`.
// Invariant: free_list_size <= `cont_table_capacity`.
static uint32_t free_list_size = 0;

#ifdef FIBER_WASMFX_PRESERVE_SHADOW_STACK
static const size_t cont_shadow_stack_size = WASMFX_CONT_SHADOW_STACK_SIZE;

// Given a table index i, `sstack_bottom_ptrs[i]` is the beginning of the shadow
// stack allocation of continuation i.
// Invariant: sstack_bottom_ptrs has as many entries as `cont_table_capacity`
static void **sstack_bottom_ptrs;
// Given a table index i, `sstack_current_ptrs[i]` is the current stack pointer
// value of continuation i.
// Invariant: sstack_current_ptrs has as many entries as `cont_table_capacity`
static void **sstack_current_ptrs;

static void init_shadow_stack(cont_table_index_t table_index) {
  char *shadow_stack_bottom = malloc(cont_shadow_stack_size);
  assert(shadow_stack_bottom != NULL && "init_shadow_stack: malloc failed");
  void *shadow_stack_usable_top =
    ((char *)shadow_stack_bottom) + cont_shadow_stack_size - 0x10;
  sstack_bottom_ptrs[table_index] = shadow_stack_bottom;
  sstack_current_ptrs[table_index] = shadow_stack_usable_top;
}
#endif

// Counterpart to fiber_init, doing one-time initialization required in wasm
// code. Parameter must be &sstack_current_ptrs_addr if preserving shadow stacks
// is requested, otherwise an arbitrary value may be supplied.
extern import("wasmfx_fiber_init_wat")
void wasmfx_fiber_init_wat(void *sstack_current_ptrs_addr);

extern import("wasmfx_grow_cont_table")
void wasmfx_grow_cont_table(uint32_t);

extern import("wasmfx_indexed_cont_new")
void wasmfx_indexed_cont_new(fiber_entry_point_t, cont_table_index_t);

extern import("wasmfx_switch_trampoline")
void *wasmfx_switch_trampoline(cont_table_index_t fiber_index, int argc, char **argv);

extern import("wasmfx_switch")
void *wasmfx_switch(cont_table_index_t target, void *arg, cont_table_index_t *switch_from);

extern import("wasmfx_switch_return")
void wasmfx_switch_return(cont_table_index_t target, void *arg);

static cont_table_index_t wasmfx_acquire_table_index(void) {
  uintptr_t table_index;
  // We reserve the index `0` such that we can support null-checking
  // on fiber-objects.
  if (cont_table_unused_size > 1) {
    // There is an entry in the continuation table that has not been used so far.
    table_index = cont_table_capacity - cont_table_unused_size + 1;
    cont_table_unused_size--;
#ifdef FIBER_WASMFX_PRESERVE_SHADOW_STACK
    init_shadow_stack(table_index);
#endif
  }
  else if (free_list_size > 1) {
    // We can pop an element from the free list stack.
    table_index = free_list[free_list_size - 1];
    free_list_size--;
  } else {
    // We have run out of table entries.
    uint32_t new_cont_table_capacity = 2 * cont_table_capacity;

    // Ask wasm to grow the table by the previous size, and we grow the
    // `free_list` ourselves.
    wasmfx_grow_cont_table(cont_table_capacity);
    free(free_list);
    free_list = malloc(sizeof(uint32_t) * new_cont_table_capacity);
    assert(free_list != NULL && "wasmfx_acquire_table_index: malloc failed");

    // We added `cont_table_capacity` new entries to the table, and then
    // immediately consume one for the new continuation.
    cont_table_unused_size = cont_table_capacity;
    table_index = cont_table_capacity;
    cont_table_capacity = new_cont_table_capacity;

#ifdef FIBER_WASMFX_PRESERVE_SHADOW_STACK
    sstack_bottom_ptrs = realloc(sstack_bottom_ptrs, sizeof(void *) * new_cont_table_capacity);
    sstack_current_ptrs = realloc(sstack_current_ptrs, sizeof(void *) * new_cont_table_capacity);
    init_shadow_stack(table_index);
#endif
  }
  return table_index;
}

static void wasmfx_release_table_index(cont_table_index_t table_index) {
  free_list[free_list_size] = table_index;
  free_list_size++;
#ifdef FIBER_WASMFX_PRESERVE_SHADOW_STACK
  // Note that we do not free shadow stacks, but simply reset them for
  // subsequent re-use.
  void *shadow_stack_usable_top =
    ((char *)sstack_bottom_ptrs[table_index]) + cont_shadow_stack_size - 0x10;
  sstack_current_ptrs[table_index] = shadow_stack_usable_top;
#endif
}

fiber_t fiber_alloc(fiber_entry_point_t entry) {
  cont_table_index_t table_index = wasmfx_acquire_table_index();
  wasmfx_indexed_cont_new(entry, table_index);

  return (fiber_t)table_index;
}

void fiber_free(fiber_t fiber) {
  cont_table_index_t table_index = (cont_table_index_t)fiber;

  // NOTE: Currently, fiber stacks are deallocated only when the continuation
  // returns. Thus, the only thing we can do here is releasing the table index.
  wasmfx_release_table_index(table_index);
}

void* fiber_switch(fiber_t target, void *arg, fiber_t *switched_from) {
  cont_table_index_t switched_from_index = 0;
  void *result = wasmfx_switch((cont_table_index_t)target, arg, &switched_from_index);
  *switched_from = (fiber_t)switched_from_index;
  return result;
}

void fiber_switch_return(fiber_t target, void *arg) {
  wasmfx_switch_return((cont_table_index_t)target, arg);
}

static void fiber_init(void) {
  free_list = malloc(initial_table_capacity * sizeof(uint32_t));
  assert(free_list != NULL && "fiber_init: malloc failed");
#ifdef FIBER_WASMFX_PRESERVE_SHADOW_STACK
  sstack_bottom_ptrs = malloc(initial_table_capacity * sizeof(void *));
  assert(sstack_bottom_ptrs != NULL && "fiber_init: malloc failed");
  sstack_current_ptrs = malloc(initial_table_capacity * sizeof(void *));
  assert(sstack_current_ptrs != NULL && "fiber_init: malloc failed");
  wasmfx_fiber_init_wat(&sstack_current_ptrs);
#else
  wasmfx_fiber_init_wat(NULL);
#endif
}

static void fiber_finalize(void)
{
  free(free_list);
#ifdef FIBER_WASMFX_PRESERVE_SHADOW_STACK
  for (size_t i = 0; i < cont_table_capacity - cont_table_unused_size; i++) {
    free(sstack_bottom_ptrs[i]);
  }
  free(sstack_bottom_ptrs);
  free(sstack_current_ptrs);
#endif
}

void *fiber_main(void *(*main)(int, char**), int argc, char **argv) {
  fiber_init();
  void *result = wasmfx_switch_trampoline((uint32_t)(uintptr_t)main, argc, argv);
  fiber_finalize();
  return result;
}

#undef import
