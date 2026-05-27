# Reified Fibers

This document outlines a simplified approach to stack-switching in WebAssembly, replacing the concept of reified continuations with **reified fibers**. This design aims to be more direct and easier to reason about, utilizing explicit fiber types and control flow through blocks.

## Core Concepts

### 1. Fiber Types
A fiber represents an independently executing coroutine. A fiber is statically typed with a resume type and a suspend type:
- **Resume Type** (`$t1*`): The types of the arguments provided to the fiber when it is resumed.
- **Suspend Type** (`$t2*`): The types of the values the fiber generates when it suspends execution and yields control.

In WebAssembly syntax, a fiber type can be defined as:
```wasm
(type $F (fiber (param $t1...) (result $t2...)))
```

### 2. Creating Fibers (`fiber.new`)
Fibers are instantiated from functions. A new instruction, `fiber.new`, creates a reified fiber.

```wasm
fiber.new $func_index
```

**Semantics:**
- The target function must have a signature that matches `[ (ref $F), $prefix_args..., $t1... ] -> []`, where `$t1...` are the resume arguments of the fiber type. *(Note: The function must not return any values. When a fiber completes by returning, control falls through to the instruction after `fiber.resume` with an empty stack contribution from the fiber.)*
- `fiber.new` consumes `$prefix_args...` from the current stack. 
- It creates the new fiber and pushes its reference `(ref $F)` onto the stack.
- The new fiber's reference `(ref $F)` is automatically prepended to the user-supplied `$prefix_args...`, binding all of them to the function. 
- When the fiber is first resumed, it will receive the `$t1...` arguments, and the underlying function will begin executing with the fiber reference, the prefix arguments, and the resume arguments.

### 3. Resuming Fibers (`fiber.resume`)
The `fiber.resume` instruction transfers control to a fiber. It is designed to integrate seamlessly with WebAssembly's structured control flow, specifically by breaking to a block if the fiber suspends.

```wasm
block $suspend_handler (result $suspend_args...)
  ;; Stack contains: [ ... $resume_args..., (ref $F) ]
  fiber.resume $suspend_handler
  
  ;; Execution continues here if the fiber RETURNS (finishes execution)
end
;; Execution continues here if the fiber SUSPENDS.
;; The stack now contains the $suspend_args... yielded by the fiber.
```

**Semantics:**
- `fiber.resume` consumes the resume arguments (`$t1...`) and a reference to the fiber (`ref $F`) from the stack.
- Control is transferred to the fiber.
- **Return:** If the fiber completes its execution (returns from its base function), control returns to the instruction *immediately following* `fiber.resume`.
- **Suspend:** If the fiber suspends, control breaks to the block specified by the label (`$suspend_handler`). The values provided by the suspend instruction (`$suspend_args...`) are pushed onto the stack. *(Note: In this stacked design, when a fiber suspends, it may be a nested fiber suspending to a distant ancestor. Control always returns to the resumer of the target fiber. Since that resumer knows which fiber it explicitly resumed, there is no ambiguity about which fiber's suspension block was triggered, even if the suspension was initiated by a deeply nested child).*

### 4. Suspending Fibers (`fiber.suspend`)
The `fiber.suspend` instruction allows a fiber to pause its execution and yield values back to its resumer.

```wasm
;; Stack contains: [ ... $suspend_args..., (ref $F) ]
fiber.suspend
```

**Semantics:**
- `fiber.suspend` takes the suspend arguments (`$suspend_args...`) and a reference to a fiber (`ref $F`).
- It pauses the current execution context.
- Control is transferred back to the resumer (breaking to the block label specified in the `fiber.resume` call).
- Only the `$suspend_args...` are passed to the resumer's block.
- When this fiber is subsequently resumed, execution will continue immediately after the `fiber.suspend` instruction, and the new resume arguments will be pushed onto the fiber's stack.

---

## Example: Generator Pattern

Here is how a simple generator (yielding integers) would look under this design.

```wasm
;; Fiber type: takes no resume args, yields only an i32
(type $GenFiber (fiber (param) (result i32)))

;; The generator function
;; $self is automatically prepended by fiber.new, followed by the prefixed $state
(func $gen_func (param $self (ref $GenFiber)) (param $state i32)
  loop $l
    ;; Calculate next value (e.g., state + 1)
    ...
    
    ;; Suspend, yielding the value
    ;; Stack: [ $value, (ref $GenFiber) ]
    local.get $self
    fiber.suspend
    
    br $l
  end
)

(func $consumer
  (local $f (ref $GenFiber))
  
  ;; Prefix the initial state (0) and create the fiber.
  ;; The new fiber's ref is automatically prepended as the first argument to $gen_func.
  i32.const 0
  fiber.new $gen_func
  local.set $f
  
  loop $consume_loop
    block $suspend_handler (result i32)
      ;; Push fiber ref and resume
      local.get $f
      fiber.resume $suspend_handler
      
      ;; If we reach here, the generator returned (finished)
      return
    end
    
    ;; If we reach here, the generator suspended.
    ;; Stack contains: [ value ]
    ;; The resumer already knows `$f` is the fiber that suspended.
    
    ;; Process the yielded i32 value...
    ...
    
    br $consume_loop
  end
)
```

## Example: Extending the Generator

In more advanced scenarios, a generator might not only yield values but also receive values from the consumer each time it is resumed. The fiber's explicit `resume_type` makes this bidirectional data flow straightforward.

```wasm
;; Fiber type: takes an f32 on resume, yields an i32
(type $EchoGenFiber (fiber (param f32) (result i32)))

;; The generator function
;; $self is automatically prepended by fiber.new, followed by the prefixed $state
;; $first_resume_val is provided by the very first fiber.resume
(func $echo_gen_func (param $self (ref $EchoGenFiber)) (param $state i32) (param $first_resume_val f32)
  (local $resume_val f32)
  (local.set $resume_val (local.get $first_resume_val))
  
  loop $l
    ;; Do something with $resume_val and $state ...
    ...
    
    ;; Suspend, yielding our state
    local.get $state
    local.get $self
    fiber.suspend
    
    ;; Upon resumption, the new resume argument (f32) is left on the stack
    local.set $resume_val
    
    br $l
  end
)
```

## Example: Task Scheduling

This example demonstrates how to implement cooperative task scheduling. The scheduler maintains a queue of tasks. When a task wishes to yield, it suspends itself, returning control to the scheduler loop.

```wasm
;; Fiber type for tasks: no resume args, yields no args when suspended.
(type $TaskFiber (fiber (param) (result)))

(module $scheduler
  ;; A simple queue for tasks
  (table $task_queue 1000 (ref null $TaskFiber))
  
  ;; Utility functions for the queue
  (func $enqueue (param $f (ref $TaskFiber)) ...)
  (func $dequeue (result (ref null $TaskFiber)) ...)

  (func $entry (param $initial_task (ref $TaskFiber))
    (local $next_task (ref null $TaskFiber))
    
    ;; Start with the initial task
    (local.get $initial_task)
    (call $enqueue)

    (loop $scheduler_loop
      (call $dequeue)
      (local.set $next_task)
      
      ;; If queue is empty, all tasks are finished
      (br_if $scheduler_loop_end (ref.is_null (local.get $next_task)))
      
      (block $on_yield
        ;; Push the fiber reference to resume
        (local.get $next_task)
        (fiber.resume $on_yield)
        
        ;; If the task returns, it has completed execution.
        ;; We loop around to pick the next task.
        (br $scheduler_loop)
      )
      
      ;; If we reach here, the task yielded (suspended). 
      ;; The resumer knows exactly which task suspended ($next_task).
      ;; Enqueue it to be run again later.
      (local.get $next_task)
      (call $enqueue)
      (br $scheduler_loop)
    )
    (label $scheduler_loop_end)
  )

  ;; Example Task
  ;; $self is automatically prepended by fiber.new
  (func $task_0 (param $self (ref $TaskFiber))
    ...
    ;; Yield execution back to the scheduler
    local.get $self
    fiber.suspend
    
    ...
  )
)
```

## Example: Heterogeneous Stacked Suspension (I/O within a Generator)

This example demonstrates the composability of stacked fibers: combining use cases can mean needing to suspend a deeper computation than the most recently active one. We have a **Scheduler** managing a **Task**, and that **Task** consumes a **Generator**. 

The **Generator** has two distinct suspension behaviors:
1. **Local Yield:** It yields a produced value to its immediate caller (the Task).
2. **Deep I/O Suspension:** It suspends the entire task back to the **Scheduler** to wait for an I/O event (e.g., a timer), bypassing the Task's internal logic.

It also demonstrates **bidirectional communication**: the Task can resume the Generator with a sentinel value to either request the next value or cancel the generator.

```wasm
;; Command constants for Generator control
;; 0: CONTINUE, 1: CANCEL

;; Fiber type for the Scheduler (handles tasks that might yield Ie /O events)
(type $TaskFiber (fiber (param i32) (result i32))) 

;; Fiber type for the Generator (yields values to the task)
;; Resume: 0 (CONTINUE) or 1 (CANCEL). Result: yielded i32 value.
(type $GenFiber (fiber (param i32) (result i32)))

(module $heterogeneous_example
  ;; ... Scheduler state (queue, event loop) ...

  ;; The Generator function
  ;; $initial_cmd is provided by the very first fiber.resume
  (func $gen_func (param $gen_self (ref $GenFiber)) (param $task_self (ref $TaskFiber)) (param $initial_cmd i32)
    (local $i i32)
    (local $cmd i32)
    (local.set $cmd (local.get $initial_cmd))

    (loop $l
      ;; Check if the driver requested cancellation (1 = CANCEL)
      (i32.eq (local.get $cmd) (i32.const 1))
      (if (then return))

      ;; 1. Standard local yield to the Task
      (local.get $i)
      (local.get $gen_self) ;; Target: the generator itself
      fiber.suspend
      (local.set $cmd)      ;; Capture the command for the next iteration

      ;; Check again after resumption (1 = CANCEL)
      (i32.eq (local.get $cmd) (i32.const 1))
      (if (then return))

      ;; 2. Deep suspension to the Scheduler for I/O
      (i32.const 100)        ;; Argument for scheduler (e.g., sleep duration)
      (local.get $task_self) ;; Target: the Scheduler's fiber
      fiber.suspend
      drop ;; Scheduler resume arguments (e.g. status) are ignored here for simplicity

      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l)
    end)
  )

  ;; The Task function
  (func $task_entry (param $task_self (ref $TaskFiber)) (param $initial_resume i32)
    (local $gen (ref $GenFiber))
    (local $val i32)
    
    ;; Create the generator
    (local.get $task_self)
    (fiber.new $gen_func)
    (local.set $gen)

    (loop $consume
      (block $on_gen_yield (result i32)
        ;; Send CONTINUE (0) sentinel to request next value
        (i32.const 0)
        (local.get $gen)
        (fiber.resume $on_gen_yield)
        
        ;; If the generator returns, the task is finished
        return
      end)
      (local.set $val)
      
      ;; If we've seen enough values, cancel the generator (1 = CANCEL)
      (i32.gt_s (local.get $val) (i32.const 10))
      (if (then
        (i32.const 1)
        (local.get $gen)
        (fiber.resume $on_gen_yield) ;; This will cause $gen_func to return
        return
      ))

      (local.get $val)
      (call $process_value) 

      br $consume
    end)
  )
)
```


### Execution Flow:

1.  **Normal Yield:**
    *   `generator` calls `fiber.suspend` with `gen_self`.
    *   The system finds `gen_self` is the current fiber.
    *   Control returns to the **Task's** `$on_gen_yield` block.
    *   The **Task** processes the value and loops to resume the generator.
2.  **I/O Suspension:**
    *   `generator` calls `fiber.suspend` with `task_self`.
    *   The system searches the stack: `[Generator -> Task -> Scheduler]`.
    *   It finds `task_self` (the Task) and suspends the **entire chain** (Generator + Task).
    *   Control returns to the **Scheduler** (the resumer of the Task).
    *   The **Scheduler** sees the sleep request, puts the task in a "waiting" queue, and runs other work.
    *   When the timer expires, the **Scheduler** resumes the **Task**.
    *   Execution resumes **inside the generator**, immediately after the I/O suspension point. The **Task's** intermediate logic is never even aware that the suspension happened.

*(Note: In the examples above, the fiber reference is explicitly plumbed through the system. By automatically prepending `(ref $F)` to the fiber's prefix arguments during `fiber.new`, the fiber receives its own reference exactly once when it starts. The fiber can then store it in a local and use it to suspend itself later, eliminating the need to pass it back and forth on every resume).*

## Specification Changes

This section provides the formal validation and execution rules for the fiber-based stack-switching extension.

### 1. Types

#### Fiber Types
A new heap type `fiber` is added to the set of heap types. A fiber type is defined by a pair of function signatures: the **resume signature** and the **suspend signature**.

```
fiber_type ::= fiber (param <valtype>*) (result <valtype>*)
```

- The `param` types (`t1*`) specify the arguments that must be provided when the fiber is resumed.
- The `result` types (`t2*`) specify the values yielded by the fiber when it suspends.

#### Reference Types
References to fibers are added as a new kind of reference type: `(ref $F)` or `(ref null $F)`, where `$F` is a fiber type.

### 2. Instructions

#### `fiber.new $F $func_idx`
Creates a new fiber of type `$F` from the function `$func_idx`.

**Validation:**
- Let `$F` be a fiber type with resume signature `[t1*] -> [t2*]`.
- Let `$func` be the function at index `$func_idx`.
- The type of `$func` must be `[(ref $F) tp* t1*] -> []`, where `tp*` are the prefix arguments.
- The instruction has type `[tp*] -> [(ref $F)]`.

**Execution:**
- Pop the prefix arguments `tp*` from the stack.
- Create a new fiber instance associated with `$func`.
- The captured prefix arguments bound to the fiber's execution context are the new fiber's own reference `(ref $F)` followed by the popped `tp*`.
- Push a reference to the new fiber onto the stack.

*Formal execution semantics:*
```
* `S; F; v^n (fiber.new $F $func)  -->  S'; F; (ref.fiber fa)`
  - iff `fa = |S.fibers|`
  - and `S' = S with fibers += E`
  - and `E = _ (ref.fiber fa) v^n (invoke $func)`
```

#### `fiber.resume $L`
Resumes a suspended fiber. If the fiber suspends, control transfers to the block labeled by `$L`.

**Validation:**
- Let `(ref $F)` be the type on top of the stack, where `$F` is a fiber type with resume signature `[t1*]` and suspend signature `[t2*]`.
- The stack below it must match the resume signature `t1*`.
- The label `$L` must have the type `[t2*]`.
- The instruction has type `[t1* (ref $F)] -> []`.

**Execution:**
- Pop the fiber reference `f` and the resume arguments `v1*`.
- If `f` is currently active (already running on some stack) or exhausted (has returned), trap.
- Transfer control to the fiber `f`.
- **On Return:** If the fiber completes its execution by returning from its entry function, control returns to the instruction immediately following the `fiber.resume`.
- **On Suspend:** If the fiber executes a `fiber.suspend`, control transfers back to the resumer by breaking to the label `$L`. The suspend values `v2*` are pushed onto the stack.

#### `fiber.resume_throw $L $tag`
Resumes a fiber by raising a specified exception at its current suspension point.

**Validation:**
- Let `$tag` be an exception tag with type `[te*] -> []`.
- Let `(ref $F)` be the type on top of the stack, where `$F` is a fiber type with suspend signature `[t2*]`.
- The stack below it must match the exception parameter types `te*`.
- The label `$L` must have the type `[t2*]`.
- The instruction has type `[te* (ref $F)] -> []`.

**Execution:**
- Pop the fiber reference `f` and the exception arguments `ve*`.
- If `f` is active or exhausted, trap.
- Resume fiber `f`, but instead of pushing resume arguments, immediately raise the exception `$tag` with values `ve*` at the fiber's current suspension point.
- **On Return/Uncaught Exception:** If the exception is not caught within the fiber and causes it to terminate, or if the fiber subsequently returns, the behavior is as if the fiber returned (control falls through `fiber.resume_throw`).
- **On Suspend:** If the fiber catches the exception and subsequently executes `fiber.suspend`, control transfers to the resumer's label `$L` as usual.

*Formal execution semantics:*
```
* `S; F; (ref.null $F) (fiber.resume_throw $L $tag)  -->  S; F; trap`

* `S; F; v^n (ref.fiber fa) (fiber.resume_throw $L $tag)  -->  S'; F; label{L} E[v^n throw $tag] end`
  - iff `S.fibers[fa] = E`
  - and `S' = S with fibers[fa] = epsilon`
```

#### `fiber.resume_throw_ref $L`
Resumes a fiber by raising an existing exception (provided as an `exnref`) at its current suspension point.

**Validation:**
- Let `(ref $F)` be the type on top of the stack, where `$F` is a fiber type.
- The type below it must be `exnref`.
- The label `$L` must have the type `[t2*]`.
- The instruction has type `[exnref (ref $F)] -> []`.

**Execution:**
- Pop the fiber reference `f` and the exception reference `e`.
- If `f` is active or exhausted, trap.
- Resume fiber `f` and raise the exception `e` at its current suspension point.
- Unwinding and suspension behavior is identical to `fiber.resume_throw`.

*Formal execution semantics:*
```
* `S; F; (ref.null exn) (ref.fiber fa) (fiber.resume_throw_ref $L)  -->  S; F; trap`

* `S; F; (ref.null $F) (fiber.resume_throw_ref $L)  -->  S; F; trap`

* `S; F; (ref.exn ea) (ref.fiber fa) (fiber.resume_throw_ref $L)  -->  S'; F; label{L} E[(ref.exn ea) throw_ref] end`
  - iff `S.fibers[fa] = E`
  - and `S' = S with fibers[fa] = epsilon`
```

---

#### `fiber.suspend`
Suspends the currently executing fiber and yields values to its resumer.

**Validation:**
- The instruction takes a fiber reference `(ref $F)` from the top of the stack.
- Let `$F` be a fiber type with resume signature `[t1*]` and suspend signature `[t2*]`.
- The stack below the fiber reference must match the suspend signature `t2*`.
- The instruction has type `[t2* (ref $F)] -> [t1*]`.
- *(Note: Statically, this instruction is only valid if it is reachable within a fiber context that can provide resume arguments of type `t1*`).*

**Execution:**
- Pop the fiber reference `f` and the suspend values `v2*`.
- Search the dynamic chain of active fibers for `f`. The search starts with the currently executing fiber. 
- If the current fiber is not `f`, the system moves to the current fiber's **resume parent** (the fiber that called `fiber.resume` to start or resume it) and continues the search.
- This process repeats until either `f` is found or the end of the chain is reached (i.e., there is no resume parent).
- **If `f` is found:**
    - The current execution context is paused.
    - All fibers in the chain between the current fiber and `f` (inclusive) are suspended.
    - Control is transferred back to the **resumer of `f`** (breaking to the label `$L` specified in the `fiber.resume $L` call that most recently activated `f`).
    - The suspend values `v2*` are pushed onto the resumer's stack.
    - When `f` is subsequently resumed, execution continues immediately after its suspension point. If `f` was the fiber that initiated the suspension via `fiber.suspend`, the resume arguments `v1*` are pushed onto its stack.
- **If `f` is not found:**
    - The instruction traps.

*Formal execution semantics:*
```
* `S; F; label{L} E[v^m (ref.fiber fa) fiber.suspend] end  -->  S'; F; v^m (br $L)`
  - iff `fa` is in the dynamic chain of active fibers.
  - and `S'` is `S` updated such that all fibers in the chain from the current one up to `fa` are suspended (their current execution states are captured).
  - and `label{L}` is the label associated with the `fiber.resume` that activated `fa`.

* `S; F; label{L} E[v^m (ref.fiber fa) fiber.suspend] end  -->  S; F; trap`
  - iff `fa` is not in the dynamic chain of active fibers.
```

---

## Design Decision: Stacked Fibers

This proposal adopts a **stacked** semantic for fibers. When a fiber executes `fiber.suspend`, it provides a reference to the target fiber it wishes to suspend. The system then searches the current dynamic chain of active fibers (starting from the currently executing fiber and following the "resume parent" links) to find a match.

If the target fiber is found in the active chain, the entire sub-stack from the current point up to that fiber is suspended, and control returns to that fiber's resumer. If the target fiber is not found in the dynamic chain, the operation traps.

This design was chosen to provide greater expressivity:

* **Composition:** Stacked fibers allow for better composition of libraries. A deeply nested component can yield directly to a distant ancestor (like a scheduler or a top-level event loop) without requiring every intermediate layer to explicitly catch and re-propagate the suspension.
* **Reduced Boilerplate:** It eliminates the need for manual "forwarding" of yield operations through intermediate fiber layers.
* **Flexibility:** It supports more complex control flow patterns, such as multi-level generators or effects that skip intermediate handlers.

While this introduces a search during suspension, the depth of the fiber stack is typically small in practice, keeping the overhead minimal while significantly improving developer ergonomics and system modularity.

## Design Consideration: Omission of `fiber.bind`

The original continuation proposal includes a `cont.bind` instruction, which allows for the partial application of resume arguments to a suspended continuation, creating a new continuation with a modified signature. 

This `reified-fibers` proposal explicitly **omits** a `fiber.bind` instruction. 

The primary reason for this omission is performance. If fibers could have their resume arguments dynamically bound and their signatures changed at runtime, it would severely limit an engine's ability to optimize `fiber.resume`. Specifically, knowing the exact resume signature statically at the `fiber.resume` call site allows the WebAssembly engine to pass resume arguments efficiently using **machine registers**. Allowing dynamic binding forces engines to fall back to slower memory-based or stack-based calling conventions, as the true calling convention of the underlying fiber would become obscured. 

Instead, partial application is supported statically only at fiber creation time via the prefix arguments in `fiber.new`.

## Trap Handling

If a fiber traps during its execution, the trap propagates transparently to its resumer. From the perspective of the WebAssembly runtime and the parent executing context, it is as though the `fiber.resume` instruction itself trapped. This ensures that trap handling and unwinding semantics remain consistent and predictable across fiber boundaries.

---

## Advantages of this Design
1. **Clear Types:** The explicit separation of `$resume_type` and `$suspend_type` makes the data flow boundary between parent and child threads statically verifiable.
2. **Structured Control Flow:** By mapping `suspend` to a structured `break` (via block labels in `resume`), this design avoids the need for complex, dynamic exception-handler-like structures (`try_table`, `cont.bind`, etc.).
3. **Simplicity:** The mental model maps directly to coroutines and generators found in higher-level languages.
4. **Stable References:** A fiber is represented by a single reference that remains stable throughout the entire lifetime of a task. This eliminates the need for user code or schedulers to constantly update records or tables of "which continuation is currently active" upon every suspension and resumption, reducing state management overhead.
