(module $fiber_reified_wasmfx
  (type $fiber_func_t (func (param i32) (result i32)))
  (type $fiber_t (fiber $fiber_func_t))

  ;; We must make sure that there is only a single memory, so that our
  ;; load/store instructions act on the C heap, not a separate memory.
  (import "main" "memory" (memory $0 2))
  ;; This is created by clang to translate function pointers.
  (import "main" "__indirect_function_table" (table $indirect_function_table 0 funcref))

#ifdef FIBER_WASMFX_PRESERVE_SHADOW_STACK
  ;; The shadow stack pointer, created by clang
  (import "main" "__stack_pointer" (global $sstack_ptr (mut i32)))
#endif

  ;; The *address* where the global C variable sstack_current_ptrs is stored
  ;; in linear memory
  (global $sstack_current_ptrs_addr (mut i32) (i32.const 0))

  ;; A reference to the currently active fiber is needed by fiber.suspend
  (global $active_fiber_index (mut i32) (i32.const 1))

  ;; Keep the initial size of this table in sync with INITIAL_TABLE_CAPACITY in
  ;; .c file.
  (table $fiber_table WASMFX_CONT_TABLE_INITIAL_CAPACITY (ref null $fiber_t))

  (func $grow_cont_table (export "wasmfx_grow_cont_table") (param $capacity_delta i32)
    (table.grow $fiber_table (ref.null $fiber_t) (local.get $capacity_delta))
    (drop)
  )

  ;; One-time initialization
  (func $wasmfx_fiber_init_wat (export "wasmfx_fiber_init_wat")
        (param $sstack_current_ptrs_addr i32)
    (global.set $sstack_current_ptrs_addr (local.get $sstack_current_ptrs_addr))
  )

  ;; This function is the entry point of all of our continuations.
  ;; clang translates function pointers into indices into the
  ;; `$indirect_function_table`, and the latter contains entries of type
  ;; `funcref`. There is no way to downcast from `funcref` to a concrete function
  ;; reference type. Thus we cannot call `cont.new` on entries from
  ;; `$indirect_function_table` directly, but must use this trampoline instead.
  (func $wasmfx_entry_trampoline (param $self (ref $fiber_t)) (param $func_index i32) (param $arg i32) (result i32)
    (call_indirect $indirect_function_table (type $fiber_func_t)
      (local.get $arg)
      (local.get $func_index)
    )
  )
  (elem declare func $wasmfx_entry_trampoline)


  (func $indexed_cont_new (export "wasmfx_indexed_fiber_new")
    (param $func_index i32)
    (param $cont_index i32)
    (local $f (ref $fiber_t))

    ;; Prefix the function index arg to $wasmfx_entry_trampoline and create the fiber.
    (fiber.new $fiber_t $wasmfx_entry_trampoline (local.get $func_index))
    (local.set $f)

    (table.set $fiber_table (local.get $cont_index) (local.get $f))
  )

  (func $indexed_resume (export "wasmfx_indexed_resume")
    (param $cont_index i32)
    (param $arg i32)
    (param $result_ptr i32)
    (result i32)
    (local $f (ref $fiber_t))
    (local $old_shadow_sp i32)

#ifdef FIBER_WASMFX_PRESERVE_SHADOW_STACK
    (local.set $old_shadow_sp (global.get $sstack_ptr))
    ;; The following 5 instructions are equivalent to the following C code
    ;; (inlined here until we have wasm-opt):
    ;; __shadow_stack_ptr = sstack_current_ptrs[cont_index]

    (i32.load (global.get $sstack_current_ptrs_addr))
    (i32.mul (i32.const 4) (local.get $cont_index))
    (i32.add)
    (i32.load)
    (global.set $sstack_ptr)
#endif
    
    (block $handler (result i32)
      (block $on_error
        ;; Retrieve the fiber and test for null
        (local.set $f (br_on_null $on_error
           (table.get $fiber_table (local.get $cont_index))))
        ;; Update active fiber index
        (global.set $active_fiber_index (local.get $cont_index))
        ;; Resume fiber
        (fiber.resume $fiber_t $handler (local.get $f) (local.get $arg))
        ;; If we reach here, the fiber returned
        (i32.store (local.get $result_ptr) (i32.const 0)) ;; FIBER_OK
        ;; Nullify the corresponding fiber table entry
        (table.set $fiber_table (local.get $cont_index) (ref.null $fiber_t))

#ifdef FIBER_WASMFX_PRESERVE_SHADOW_STACK
        ;; No need to save $sstack_ptr as continuation finished
        (global.set $sstack_ptr (local.get $old_shadow_sp))
#endif

        (return) ;; TODO: returns the value put on stack by resume
      ) ;; Error case: continuation is null
      (i32.store (local.get $result_ptr) (i32.const 2)) ;; FIBER_ERROR
      (return (i32.const -1))
    )
    
    ;; If we reach here, the generator suspended.
    (i32.store (local.get $result_ptr) (i32.const 1)) ;; FIBER_YIELD

#ifdef FIBER_WASMFX_PRESERVE_SHADOW_STACK
    ;; The following 5 instructions are equivalent to the following C code
    ;; (inlined here until we have wasm-opt):
    ;; sstack_current_ptrs[cont_index] = __shadow_stack_ptr
    (i32.load (global.get $sstack_current_ptrs_addr))
    (i32.mul (i32.const 4) (local.get $cont_index))
    (i32.add)
    (global.get $sstack_ptr)
    (i32.store)

    (global.set $sstack_ptr (local.get $old_shadow_sp))
#endif

    ;; return suspend payload
    (return)
  )

  (func $suspend (export "wasmfx_suspend") (param $arg i32) (result i32) 
    (local $fiber (ref null $fiber_t))
    (block $on_error
      ;; Retrieve reference to fiber that needs to be suspended
      (table.get $fiber_table (global.get $active_fiber_index))
      (local.set $fiber)
      ;; Suspend fiber
      (fiber.suspend $fiber_t (local.get $arg) (br_on_null $on_error (local.get $fiber)))

      (return)
    )
    (unreachable)
  )
)
