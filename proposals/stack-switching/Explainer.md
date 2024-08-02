# Stack switching

This proposal adds typed stack switching to WebAssembly, enabling a single WebAssembly instance to manage multiple execution stacks concurrently. The primary use-case for stack switching is to add direct support for modular compilation of advanced non-local control flow idioms, e.g. coroutines, async/await, yield-style generators, lightweight threads, and so forth. This document outlines the new instructions and validation rules to facilitate stack switching.

## Table of contents

1. [Motivation](#motivation)
1. [Examples](#examples)
   1. [Yield-style generators](#yield-style-generators)
   1. [Coroutines](#coroutines)
   1. [Modular composition](#modular-composition)
   1. [Lightweight threads](#lightweight-threads)
1. [Design considerations](#design-considerations)
   1. [Asymmetric and symmetric switching](#asymmetric-and-symmetric-switching)
   1. [Linear usage of continuations](#linear-usage-of-continuations)
1. [Specification changes](#specification-changes)
   1. [Types](#types)
   1. [Instructions](#instructions)
   1. [Binary format](#binary-format)

## Motivation

TODO

## Examples

In this section we give a series of examples illustrating possible encodings of common non-local control flow idioms.

### Yield-style generators

<!--
```c
// Producer: a stream of naturals
void nats() {
  int32_t i = 0;
  for (;; i++) yield i; // supposed control name for yielding control with payload `i` to the surrounding context
}

// Consumer: sums up some slice of the `nats` stream
int32_t sumUp(int32_t upto) {
  int32_t n = 0, // current value
          s = 0; // accumulator
  while (n < upto) {
    switch (nats()) {
       case yield(int32_t i): // pattern matching on the control name
         n = i;  // save the current value
         s += n; // update the accumulator
         continue;
       default: // `nats` returned
          return s;
    }
  }
  return s;
}

sumUp(10); // returns 55
```
-->

```wast
(module $generator
  (type $ft (func)) ;; [] -> []
  (type $ct (cont $ft)) ;; cont [] -> []

  ;; Control name declaration
  (tag $yield (param i32)) ;; i32 -> []

  ;; Producer: a stream of naturals
  (func $nats (export "nats")
    (local $i i32) ;; zero-initialised local
    (loop $produce-next
      (suspend $yield (local.get $i)) ;; yield control with payload `i` to the surrounding context
      ;; compute the next natural
      (local.set $i
        (i32.add (local.get $i)
                 (i32.const 1)))
      (br $produce-next) ;; continue to produce the next natural number
    )
  )
  (elem declare func $nats)

  ;; Consumer: sums up some slice of the `nats` stream
  (func $sumUp (export "sumUp") (param $k (ref $ct)) (param $upto i32) (result i32)
    (local $n i32) ;; current value
    (local $s i32) ;; accumulator
    (loop $consume-next
      (block $on_yield (result i32 (ref $ct))
        ;; continue the generator
        (resume $ct (on $yield $on_yield) (local.get $k))
        ;; control flows here if `$k` returns normally
        (return (local.get $s))
      ) ;; control flows here if `$k` suspends with `$yield`; stack: [i32 (ref $ct)]
      (local.set $k) ;; save the next continuation
      (local.set $n) ;; save the current value
      ;; update the accumulator
      (local.set $s (i32.add (local.get $s)
                             (local.get $n)))
      ;; decide whether to do another loop iteration
      (br_if $consume-next
             (i32.lt_u (local.get $n) (local.get $upto)))
    )
    (local.get $s)
  )

  ;; Put everything together
  (func $main (export "main") (result i32)
    ;; allocate the initial continuation, viz. execution stack, to run the generator `nats`
    (local $k (ref $ct))
    (local.set $k (cont.new $ct (ref.func $nats)))
    ;; run `sumUp`
    (call $sumUp (local.get $k) (i32.const 10)))
)
(assert_return (invoke "main") (i32.const 55))
```

### Coroutines

TODO

### Modular composition

TODO

### Lightweight threads

TODO

#### Asymmetric variation

TODO

#### Symmetric variation

TODO


## Design considerations

In this section we discuss some key design considerations.

### Asymmetric and symmetric switching

TODO

### Linear usage of continuations

Continuations in this proposal are single-shot (aka linear), meaning that they must be invoked exactly once (though this is not statically enforced). A continuation can be invoked either by resuming it (with `resume`); by aborting it (with `resume_throw`); or by switching to it (with `switch`). Some applications such as backtracking, probabilistic programming, and process duplication exploit multi-shot continuations, but none of the critical use cases require multi-shot continuations. Nevertheless, it is natural to envisage a future iteration of this proposal that includes support for multi-shot continuations by way of a continuation clone instruction.

### Memory management

The current proposal does not require a general garbage collector as the linearity of continuations guarantees that there are no cycles in continuation objects. 
In theory, we could dispense with automated memory management altogether if we took seriously the idea that failure to use a continuation constitutes a bug in the producer. In practice, for most producers enforcing such a discipline is unrealistic and not something an engine can rely on anyway. To prevent space leaks, most engines will either need some form of automated memory management for unconsumed continuations a monotonic continuation allocation scheme. 

* Automated memory management: due to the acyclicity of continuations, a reference counting scheme is sufficient.
* Monotonic continuation allocation: it is safe to use a continuation object as long as its underlying stack is alive. It is trivial to ensure a stack is alive by delaying deallocation until the program finishes. To avoid excessive use of memory, an engine can equip a stack with a revision counter, thus making it safe to repurpose the allocated stack for another continuation.

## Specification changes

This proposal is based on the [function references proposal](https://github.com/WebAssembly/function-references) and [exception handling proposal](https://github.com/WebAssembly/exception-handling).

### Types

We extend the structure of composite types and heap types as follows.

- `cont <typeidx>` is a new form of composite type
  - `(cont $ft) ok` iff `$ft ok` and `$ft = [t1*] -> [t2*]`

We add two new continuation heap types and their subtyping hierachy:
- `heaptypes ::= ... | cont | nocont`
- `nocont ok` and `cont ok` always
- `nocont` is the bottom type of continuation types, whereas `cont` is the top type, i.e. `nocont <: cont`

### Tags

We change the wellformedness condition for tag types to be more liberal, i.e.

- `(tag $t (type $ft)) ok` iff `$ft ok` and `$ft = [t1*] -> [t2*]`

In other words, the return type of tag types is allowed to be non-empty.

### Instructions

The new instructions and their validation rules are as follows. To simplify the presentation, we write this:

```
C.types[$ct] ~~ cont [t1*] -> [t2*]
```

where we really mean this:

```
C.types[$ct] ~~ cont $ft
C.types[$ft] ~~ func [t1*] -> [t2*]
```

This abbreviation will be formalized with an auxiliary function or other means in the spec.

- `cont.new <typeidx>`
  - Create a new continuation from a given typed funcref.
  - `cont.new $ct : [(ref null? $ft)] -> [(ref $ct)]`
    - iff `C.types[$ct] ~~ cont [t1*] -> [t2*]`

- `cont.bind <typeidx> <typeidx>`
  - Partially apply a continuation.
  - `cont.bind $ct $ct' : [t3* (ref null? $ct)] -> [(ref $ct')]`
    - iff `C.types[$ct'] ~~ cont [t1'*] -> [t2'*]`
    - and `C.types[$ct] ~~ cont [t1* t3*] -> [t2*]`
    - and `[t1*] -> [t2*] <: [t1'*] -> [t2'*]`
  - note - currently binding from right as discussed in https://github.com/WebAssembly/stack-switching/pull/53

- `resume <typeidx> hdl*`
  - Execute a given continuation.
    - If the executed continuation suspends with a tagged signal `$t`, the corresponding handler `(on $t H)` is executed.
  - `resume $ct hdl* : [t1* (ref null? $ct)] -> [t2*]`
    - iff `C.types[$ct] ~~ cont [t1*] -> [t2*]`
    - and `(hdl : t2*)*`

- `resume_throw <typeidx> <exnidx> hdl*`
  - Execute a given continuation, but force it to immediately throw the annotated exception.
  - Used to abort a continuation.
  - `resume_throw $ct $e hdl* : [te* (ref null? $ct)] -> [t2*]`
    - iff `C.types[$ct] ~~ cont [t1*] -> [t2*]`
    - and `C.tags[$e] : tag $ft`
    - and `C.types[$ft] ~~ func [te*] -> []`
    - and `(hdl : t2*)*`

- `hdl = (on <tagidx> <labelidx>) | (on <tagidx> switch)`
  - Handlers attached to `resume` and `resume_throw`, handling events for `suspend` and `switch`, respectively.
  - `(on $e $l) : t*`
    - iff `C.tags[$e] = tag $ft`
    - and `C.types[$ft] ~~ func [t1*] -> [t2*]`
    - and `C.labels[$l] = [t1'* (ref null? $ct)]`
    - and `t1* <: t1'*`
    - and `C.types[$ct] ~~ cont [t2'*] -> [t'*]`
    - and `[t2*] -> [t*] <: [t2'*] -> [t'*]`
  - `(on $e switch) : t*`
    - iff `C.tags[$e] = tag $ft`
    - and `C.types[$ft] ~~ func [] -> [t*]`

- `suspend <tagidx>`
  - Send a tagged signal to suspend the current computation.
  - `suspend $t : [t1*] -> [t2*]`
    - iff `C.tags[$t] = tag $ft`
    - and `C.types[$ft] ~~ func [t1*] -> [t2*]`

- `switch <typeidx> <tagidx>`
  - Switch to executing a given continuation directly, suspending the current execution.
  - The suspension and switch are performed from the perspective of a parent `(on $e switch)` handler, determined by the annotated tag.
  - `switch $ct1 $e : [t1* (ref null $ct1)] -> [t2*]`
    - iff `C.tags[$e] = tag $ft`
    - and `C.types[$ft] ~~ func [] -> [t*]`
    - and `C.types[$ct1] ~~ cont [t1* (ref null? $ct2)] -> [te1*]`
    - and `te1* <: t*`
    - and `C.types[$ct2] ~~ cont [t2*] -> [te2*]`
    - and `t* <: te2*`

### Execution

The same tag may be used simultaneously by `throw`, `suspend`, `switch`, and their associated handlers. When searching for a handler for an event, only handlers for the matching kind of event are considered, e.g. only `(on $e $l)` handlers can handle `suspend` events and only `(on $e switch)` handlers can handle `switch` events. The handler search continues past handlers for the wrong kind of event, even if they use the correct tag.

### Binary format

We extend the binary format of composite types, heap types, and instructions.

#### Composite types

| Opcode | Type            | Parameters | Note |
| ------ | --------------- | ---------- |------|
| -0x20  | `func t1* t2*`  | `t1* : vec(valtype)` `t2* : vec(valtype)` | from Wasm 1.0 |
| -0x23  | `cont $ft`      | `$ft : typeidx` | new |

#### Heap Types

The opcode for heap types is encoded as an `s33`.

| Opcode | Type            | Parameters | Note |
| ------ | --------------- | ---------- | ---- |
| i >= 0 | i               |            | from function-references |
| -0x0b  | `nocont`        |            | new  |
| -0x18  | `cont`          |            | new  |

### Instructions

| Opcode | Instruction              | Immediates |
| ------ | ------------------------ | ---------- |
| 0xe0   | `cont.new $ct`           | `$ct : u32` |
| 0xe1   | `cont.bind $ct $ct'`     | `$ct : u32`, `$ct' : u32` |
| 0xe2   | `suspend $t`             | `$t : u32` |
| 0xe3   | `resume $ct (on $t $h)*` | `$ct : u32`, `($t : u32 and $h : u32)*` |
| 0xe4   | `resume_throw $ct $e (on $t $h)` | `$ct : u32`, `$e : u32`, `($t : u32 and $h : u32)*` |
| 0xe5   | `switch $ct $e`          | `$ct : u32`, `$e : u32` |
