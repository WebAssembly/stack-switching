(module $fiber_switch_wasmfx
  (rec
    (type $ft2 (func (param i32 (ref null $ct2)) (result i32)))
    (type $ft3 (func (param i32 i32 (ref null $ct2)) (result i32)))
    (type $ct2 (cont $ft2))
    (type $ct3 (cont $ft3)))
  (type $ft-initial (func (param i32 i32 i32) (result i32)))
  (type $ct-initial (cont $ft-initial))
  (type $ft2-generic (func (param i32 i32) (result i32)))
  (type $cancel-ft (func (result i32)))
  (type $cancel-ct (cont $cancel-ft))

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


  ;; These two globals keep track of who's who across context-switches.
  ;; Every time we switch, we need to make sure the prior fiber's index
  ;; is in $switch_from_fiber_index and the new one is in $active_fiber_index.
  ;; Also after any switch the target fiber needs to start by storing the
  ;; generated continuation reference at the index specified by
  ;; $switched_from_fiber_index in the $conts table. Both are initialized
  ;; to 1 since we reserve index 0 in the continuation table as a null value.
  ;;
  ;; Keeps track of the index, into the continuation table, of the "switched from" continuation
  (global $switched_from_fiber_index (mut i32) (i32.const 1))
  ;; Keeps track of the currently active continuation
  (global $active_fiber_index (mut i32) (i32.const 1))

  ;; Keep the initial size of this table in sync with INITIAL_TABLE_CAPACITY in
  ;; .c file.
  (table $conts WASMFX_CONT_TABLE_INITIAL_CAPACITY (ref null $ct2))

  (tag $yield (result i32))
  (tag $switch-return (param i32 i32))
  (tag $cancel (param i32 i32))

  (func $grow_cont_table (export "wasmfx_grow_cont_table") (param $capacity_delta i32)
    (table.grow $conts (ref.null $ct2) (local.get $capacity_delta))
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
  ;; `$indirect_function_table` directly, but must use this wrapper instead.
  ;;
  ;; This function is used to populate the continuation type that is stored in
  ;; the array of fibers' continuations, so it is compatible with that and must
  ;; observe the same protocol, namely updating the $conts table.
  (func $fiber_entry_frame (type $ft3)
    ;; The arguments are function_index (to call), arg to that call, and a
    ;; continuation that was captured as the that of the prior running fiber.
    ;; We must maintain the $conts table by stuffing that prior continuation somewhere.
    (table.set $conts (global.get $switched_from_fiber_index) (local.get 2))
    (call_indirect $indirect_function_table (type $ft2-generic)
      (local.get 1)
      (global.get $switched_from_fiber_index)
      (local.get 0)
    )
  )

  (func $initial_entry_trampoline
     (param $func_index i32)
     (param $argc i32)
     (param $argv i32)
     (result i32)

     (call_indirect $indirect_function_table (type $ft2-generic)
       (local.get $argc)
       (local.get $argv)
       (local.get $func_index))
  )
  (elem declare func $fiber_entry_frame $initial_entry_trampoline)

  (func $indexed_cont_new (export "wasmfx_indexed_cont_new")
    (param $func_index i32)
    (param $cont_index i32)
    (local $cont (ref $ct2))

    (local.get $func_index)
    (cont.new $ct3 (ref.func $fiber_entry_frame))
    (cont.bind $ct3 $ct2)
    (local.set $cont)

    (table.set $conts (local.get $cont_index) (local.get $cont))
  )

  (func $wasmfx_switch_trampoline (export "wasmfx_switch_trampoline")
    (param $func_index i32)
    (param $argc i32)
    (param $argv i32)
    (result i32)

    (local $arg i32)
    (local $old_shadow_sp i32)

    ;; Save shadow stack prior to invoking the initial trampoline
    (local.set $old_shadow_sp (global.get $sstack_ptr))

    ;; The initial continuation invocation is special as we pass argc
    ;; and argv to it.
    (block $done (result i32)
      (block $switch-return (result i32 i32 (ref $cancel-ct))
        (resume $ct-initial (on $yield switch) (on $switch-return $switch-return)
          (local.get $func_index)
          (local.get $argc)
          (local.get $argv)
          (cont.new $ct-initial (ref.func $initial_entry_trampoline)))
        ;; Returned
        (br $done)
      ) ;; $switch-return: [i32 i32 contref]
      (loop $keep-going (param i32 i32 (ref $cancel-ct)) (result i32)

        ;; clean-up resources
        (block $on_cancel (param i32 i32 (ref $cancel-ct)) (result i32 i32)
         (try_table (param i32 i32 (ref $cancel-ct)) (result i32 i32)
              (catch $cancel $on_cancel)
                (resume_throw $cancel-ct $cancel)
                (unreachable)
          )
        )

        ;; Prepare next fiber
        (local.set $arg)
        (global.set $active_fiber_index)

        ;; Load the next shadow stack
#ifdef FIBER_WASMFX_PRESERVE_SHADOW_STACK
        ;; The following 5 instructions are equivalent to the following C code
        ;; (inlined here until we have wasm-opt):
        ;; __shadow_stack_ptr = sstack_current_ptrs[active_fiber_index]

        (i32.load (global.get $sstack_current_ptrs_addr))
        (i32.mul (i32.const 4) (global.get $active_fiber_index))
        (i32.add)
        (i32.load)
        (global.set $sstack_ptr)
#endif
        (block $switch-return (result i32 i32 (ref $cancel-ct))
          (resume $ct2 (on $yield switch) (on $switch-return $switch-return)
            (local.get $arg)
            (ref.null $ct2) ;; In this context, the previous thread has exited (has it!?) so passing this null continuation represents that fact.
            (table.get $conts (global.get $active_fiber_index)) ;; fetches the actual continuation object
          ) ;; we returned, stack is: [i32]
          (br $done)
        ) ;; $switch-return: [i32 i32 contref]
        (br $keep-going)
      ) ;; $keep-going: [i32]
    ) ;; $done: [i32]

    ;; Restore the original shadow stack segment
#ifdef FIBER_WASMFX_PRESERVE_SHADOW_STACK
    (global.set $sstack_ptr (local.get $old_shadow_sp))
#endif
  )

  (func $switch (export "wasmfx_switch")
    ;; The ID of the target to switch to.
    (param $target_index i32)
    ;; An arbitrary argument that gets passed to the target fibre.
    (param $arg i32)
    ;; An output arg pointer that we'll use to pass the identity of the
    ;; switched-from fiber back to the C level.
    (param $switched_from_output i32)
    (result i32)

    ;; $self_fiber_index: The identity of the fiber we exist in throughout this
    ;; lexical function. It switches roles from being the "current" or
    ;; "come-from" fiber, to being the "target" or "next" fiber, at the moment
    ;; of the switch instruction.
    (local $self_fiber_index i32)
    ;; $k doesn't have a meaning, just a temporary for various continuation objects.
    (local $k (ref null $ct2))
    (local $old_shadow_sp i32)

    ;; Remember the ID of the active fiber at this point as self_fiber_index
    (local.set $self_fiber_index (global.get $active_fiber_index))

    ;; Get the target continuation object, and null-out its entry.
    (local.set $k (table.get $conts (local.get $target_index)))
    (table.set $conts (local.get $target_index) (ref.null $ct2))

    ;; Save shadow stack
#ifdef FIBER_WASMFX_PRESERVE_SHADOW_STACK
    ;; The following 5 instructions are equivalent to the following C code
    ;; (inlined here until we have wasm-opt):
    ;; sstack_current_ptrs[self_fiber_index] = __shadow_stack_ptr
    (i32.load (global.get $sstack_current_ptrs_addr))
    (i32.mul (i32.const 4) (local.get $self_fiber_index))
    (i32.add)
    (global.get $sstack_ptr)
    (i32.store)

    ;; The following 5 instructions are equivalent to the following C code
    ;; (inlined here until we have wasm-opt):
    ;; __shadow_stack_ptr = sstack_current_ptrs[target_index]
    (i32.load (global.get $sstack_current_ptrs_addr))
    (i32.mul (i32.const 4) (local.get $target_index))
    (i32.add)
    (i32.load)
    (global.set $sstack_ptr)
#endif

    ;; Switch to the target fiber by invoking its continuation object.
    ;; We also maintain the two globals
    (global.set $active_fiber_index (local.get $target_index))
    (global.set $switched_from_fiber_index (local.get $self_fiber_index))
    (switch $ct2 $yield (local.get $arg) (local.get $k))
    ;; We came back from another continuation, stack is: [i32 contref]
    ;; The continuation is that of the previous fiber.
    ;;
    ;; global values $switched_from_fiber_index and $active_fiber_index
    ;; will have been updated by the other continuations. It will have set
    ;; the "active" index to the new one that we'll continue as, and the
    ;; switched-from index to its own.

    ;; Grab the continuation that was created by the other fiber that switched
    ;; to us, and put it in the table at the $switched_from_fiber_index.
    (local.set $k)
    (table.set $conts (global.get $switched_from_fiber_index) (local.get $k))
    ;; Return the identity of the fiber that switched to us, to the C level.
    (i32.store (local.get $switched_from_output) (global.get $switched_from_fiber_index))

    ;; Restore shadow stack
#ifdef FIBER_WASMFX_PRESERVE_SHADOW_STACK
    (i32.load (global.get $sstack_current_ptrs_addr))
    (i32.mul (i32.const 4) (local.get $self_fiber_index))
    (i32.add)
    (i32.load)
    (global.set $sstack_ptr)
#endif

    (return)
  )

   (func $switch-return (export "wasmfx_switch_return")
    (param $target_index i32)
    (param $arg i32)

    ;; In the following line, active_fiber_index is the index of the fiber we're currently in. 
    ;; We need to update switched_from_fiber_index here because otherwise the handler for 
    ;; return-switch in $wasmfx_switch_trampoline will nullify the continuation table entry
    ;; for the previously active fiber, rather than the current one.
    (global.set $switched_from_fiber_index (global.get $active_fiber_index))

    (suspend $switch-return (local.get $target_index) (local.get $arg))
  )
)
