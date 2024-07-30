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

```c
// Producer: a stream of naturals
void nats() {
  int32_t i = 0;
  for (;; i++) Yield(i); // supposed control name for yielding control with payload `i` to the surrounding context
}

// Consumer: sums up some slice of the `nats` stream
int32_t sumUp(int32_t upto) {
  int32_t n = 0, // current value
          s = 0; // accumulator
  while (n < upto) {
    switch (nats()) {
       case Yield(int32_t i): // pattern matching on the control name
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

TODO(dhil): Change dispatch list syntax to `(on ...)`.
```wast
(module $generator
  (type $ft (func)) ;; [] -> []
  (type $ct (cont $ft)) ;; cont [] -> []

  ;; Control name declaration
  (tag $yield (param i32)) ;; i32 -> []

  ;; Producer: a stream of naturals
  (func $nats
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
  (func (export "sumUp") (param $upto i32) (result i32)
    (local $n i32) ;; current value
    (local $s i32) ;; accumulator
    (local $k (ref $ct)) ;; the continuation of the generator
    ;; allocate the initial continuation, viz. execution stack, to run the generator `nats`
    (local.set $k (cont.new $ct (ref.func $nats)))
    (loop $consume-next
      (block $on_yield (result i32 (ref $ct))
        ;; continue the generator
        (resume $ct (tag $yield $on_yield) (local.get $k))
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
)
(assert_return (invoke "sumUp" (i32.const 10)) (i32.const 55))
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

TODO

### Asymmetric and symmetric switching

TODO

### Linear usage of continuations

TODO

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

### Instructions

The new instructions and their validation rules are as follows.

- `cont.new <typeidx>`
  - Create a new continuation from a given typed funcref.
  - `cont.new $ct : [(ref null? $ft)] -> [(ref $ct)]`
    - iff `C.types[$ct] = cont $ft`
    - and `C.types[$ft] = [t1*] -> [t2*]`

- `cont.bind <typeidx> <typeidx>`
  - Partially apply a continuation.
  - `cont.bind $ct $ct' : [t3* (ref null? $ct)] -> [(ref $ct')]`
    - iff `C.types[$ct'] = cont $ft'`
    - and `C.types[$ft'] = [t1'*] -> [t2'*]`
    - and `C.types[$ct] = cont $ft`
    - and `C.types[$ft] = [t1* t3*] -> [t2*]`
    - and `[t1*] -> [t2*] <: [t1'*] -> [t2'*]`
  - note - currently binding from right as discussed in https://github.com/WebAssembly/stack-switching/pull/53

- `suspend <tagidx>`
  - Send a tagged signal to suspend the current computation.
  - `suspend $t : [t1*] -> [t2*]`
    - iff `C.tags[$t] : tag $ft`
    - and `C.types[$ft] : [t1*] -> [t2*]`

- `resume <typeidx> (on <tagidx> <labelidx>|switch)*`
  - Execute a given continuation.
    - If the executed continuation suspends with a tagged signal `$t`, the corresponding handler `(tag $t H)` is executed.
  - `resume $ct (on $t H)* : [t1* (ref null? $ct)] -> [t2*]`
    - iff `C.types[$ct] = cont $ft`
    - and `C.types[$ft] = [t1*] -> [t2*]`
    - and for each `(tag $t H)`:
      - `C.tags[$t] : tag $ft`
      - and `C.types[$ft] : [te1*] -> [te2*]`
      - and either `H = $l`
        - and `C.labels[$l] = [te1'* (ref null? $ct')])*` 
        - and `([te1*] <: [te1'*])*`
        - and `(C.types[$ct'] = cont $ft')*`
        - and `([te2*] -> [t2*] <: C.types[$ft'])*`
      - or `H = switch`
        - and `te1* = []`
        - and `te2* <: t2*`

- `resume_throw <typeidx> <exnidx> (on <tagidx> <labelidx>|switch)*`
  - Execute a given continuation, but force it to immediately throw the annotated exception.
  - Used to abort a continuation.
  - `resume_throw $ct $e (on $t H)* : [te* (ref null? $ct)] -> [t2*]`
    - iff `C.types[$ct] = cont $ft`
    - and `C.types[$ft] = [t1*] -> [t2*]`
    - and `C.tags[$e] : tag $ft1`
    - and `C.types[$ft1] : [te*] -> []`
    - and for each `(tag $t H)`:
      - `C.tags[$t] : tag $ft`
      - and `C.types[$ft] : [te1*] -> [te2*]`
      - and either `H = $l`
        - and `C.labels[$l] = [te1'* (ref null? $ct')])*` 
        - and `([te1*] <: [te1'*])*`
        - and `(C.types[$ct'] = cont $ft')*`
        - and `([te2*] -> [t2*] <: C.types[$ft'])*`
      - or `H = switch`
        - and `te1* = []`
        - and `te2* <: t2*`

- `switch <typeidx> <tagidx>`
- Switch to executing a given continuation directly, suspending the current execution.
  - The suspension and switch are performed from the perspective of a parent `switch` handler, determined by the annotated tag.
  - `switch $ct1 $e : t1* (ref null $ct1) -> t2*`
    - iff `C.tags[$e] : tag $ft`
    - and `C.types[$ft] : [] -> [t*]`
    - and `C.types[$ct1] = cont $ft1`
    - and `C.types[$ft1] = [t1* (ref null? $ct2)] -> [te1*]`
    - and `te1* <: t*`
    - and `C.types[$ct2] = cont $ft2`
    - and `C.types[$ft2] = [t2*] -> [te2*]`
    - and `te2* <: t*`

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

