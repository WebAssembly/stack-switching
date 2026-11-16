// An implementation of the fiber.h interface using wasmfx continuations
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>

#include "fiber.h"

#define import(NAME) __attribute__((import_module("fiber_wasmfx_imports"),import_name(NAME)))

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
static_assert(WASMFX_CONT_TABLE_INITIAL_CAPACITY > 0, "WASMFX_CONT_TABLE_INITIAL_CAPACITY must be greater than 0");

// Index 0 is reserved for null fiber handles. Indices below
// `cont_table_next_unused` have been used at least once.
static uint32_t cont_table_next_unused = 1;

// Per-table-entry metadata. Freed table indices form an intrusive linked list,
// avoiding a separate free-list allocation. The most recently freed index is
// kept out of that list as a fast path for immediate free/allocate cycles.
struct fiber_slot {
#ifdef FIBER_WASMFX_PRESERVE_SHADOW_STACK
  void* shadow_stack_bottom;
  void* shadow_stack_current;
#endif
  uint32_t next_free;
  uint32_t reserved;
};

static struct fiber_slot* fiber_slots = NULL;
static uint32_t free_list_head = 0;
static uint32_t cached_free_index = 0;

#ifdef FIBER_WASMFX_PRESERVE_SHADOW_STACK
static const size_t cont_shadow_stack_size = WASMFX_CONT_SHADOW_STACK_SIZE;
static_assert(sizeof(void*) == 4, "fiber_slot layout requires wasm32 pointers");
static_assert(sizeof(struct fiber_slot) == 16, "fiber_slot layout must match imports.wat.pp");

static void init_shadow_stack(cont_table_index_t table_index) {
  char* shadow_stack_bottom = malloc(cont_shadow_stack_size);
  assert(shadow_stack_bottom != NULL && "init_shadow_stack: malloc failed");
  void* shadow_stack_usable_top =
    ((char*)shadow_stack_bottom) + cont_shadow_stack_size - 0x10;
  fiber_slots[table_index].shadow_stack_bottom = shadow_stack_bottom;
  fiber_slots[table_index].shadow_stack_current = shadow_stack_usable_top;
}
#endif

// Updates the Wasm-side base address used to find a fiber's shadow stack
// pointer. This must be called after allocating or moving `fiber_slots`.
extern
import("wasmfx_set_shadow_stack_slots")
void wasmfx_set_shadow_stack_slots(void* shadow_stack_slots_base);

extern
import("wasmfx_grow_cont_table")
void wasmfx_grow_cont_table(uint32_t);

extern
import("wasmfx_indexed_cont_new")
void wasmfx_indexed_cont_new(fiber_entry_point_t, cont_table_index_t);

extern
import("wasmfx_indexed_resume")
void* wasmfx_indexed_resume(uint32_t fiber_index, void *arg, fiber_result_t *result);

extern
import("wasmfx_suspend")
void* wasmfx_suspend(void *arg);

static cont_table_index_t wasmfx_acquire_table_index(void) {
  uintptr_t table_index;
  if (cached_free_index != 0) {
    table_index = cached_free_index;
    cached_free_index = 0;
  } else if (free_list_head != 0) {
    table_index = free_list_head;
    free_list_head = fiber_slots[table_index].next_free;
  } else if (cont_table_next_unused < cont_table_capacity) {
    table_index = cont_table_next_unused++;
#ifdef FIBER_WASMFX_PRESERVE_SHADOW_STACK
    init_shadow_stack(table_index);
#endif
  } else {
    // We have run out of table entries. Grow the table and its pre-sized slot
    // metadata together, then consume the first new entry.
    uint32_t const old_cont_table_capacity = cont_table_capacity;
    uint32_t const new_cont_table_capacity = 2 * old_cont_table_capacity;

    wasmfx_grow_cont_table(old_cont_table_capacity);
    struct fiber_slot* new_fiber_slots =
      realloc(fiber_slots, sizeof(struct fiber_slot) * new_cont_table_capacity);
    assert(new_fiber_slots != NULL && "wasmfx_acquire_table_index: realloc failed");
    fiber_slots = new_fiber_slots;
    cont_table_capacity = new_cont_table_capacity;
    table_index = cont_table_next_unused++;

#ifdef FIBER_WASMFX_PRESERVE_SHADOW_STACK
    wasmfx_set_shadow_stack_slots(&fiber_slots[0].shadow_stack_current);
    init_shadow_stack(table_index);
#endif
  }
  return table_index;
}

static void wasmfx_release_table_index(cont_table_index_t table_index) {
#ifdef FIBER_WASMFX_PRESERVE_SHADOW_STACK
  // Note that we do not free shadow stacks, but simply reset them for
  // subsequent re-use.
  void* shadow_stack_usable_top =
    ((char*)fiber_slots[table_index].shadow_stack_bottom) + cont_shadow_stack_size - 0x10;
  fiber_slots[table_index].shadow_stack_current = shadow_stack_usable_top;
#endif

  if (cached_free_index == 0) {
    cached_free_index = table_index;
  } else {
    fiber_slots[table_index].next_free = free_list_head;
    free_list_head = table_index;
  }
}

fiber_t fiber_alloc(fiber_entry_point_t entry) {
  cont_table_index_t table_index = wasmfx_acquire_table_index();
  wasmfx_indexed_cont_new(entry, table_index);

  return (fiber_t) table_index;
}

void fiber_free(fiber_t fiber) {
  cont_table_index_t table_index = (cont_table_index_t) fiber;

  // NOTE: Currently, fiber stacks are deallocated only when the continuation
  // returns. Thus, the only thing we can do here is releasing the table index.
  wasmfx_release_table_index(table_index);
}

void* fiber_resume(fiber_t fiber, void *arg, fiber_result_t *result) {
  cont_table_index_t table_index = (cont_table_index_t) fiber;
  return wasmfx_indexed_resume(table_index, arg, result);
}

void* fiber_yield(void *arg) {
  return wasmfx_suspend(arg);
}

void fiber_init(void) {
  cont_table_capacity = initial_table_capacity;
  cont_table_next_unused = 1;
  free_list_head = 0;
  cached_free_index = 0;
  fiber_slots = calloc(initial_table_capacity, sizeof(struct fiber_slot));
  assert(fiber_slots != NULL && "fiber_init: malloc failed");
#ifdef FIBER_WASMFX_PRESERVE_SHADOW_STACK
  wasmfx_set_shadow_stack_slots(&fiber_slots[0].shadow_stack_current);
#else
  wasmfx_set_shadow_stack_slots(NULL);
#endif
}

void fiber_finalize(void) {
#ifdef FIBER_WASMFX_PRESERVE_SHADOW_STACK
  for (size_t i = 1; i < cont_table_next_unused; i++) {
    free(fiber_slots[i].shadow_stack_bottom);
  }
#endif
  free(fiber_slots);
  fiber_slots = NULL;
}

#undef import
