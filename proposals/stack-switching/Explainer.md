# Stack switching

This proposal adds typed stack switching to WebAssembly, enabling a
single WebAssembly instance to manage multiple execution stacks
concurrently. The primary use-case for stack switching is to add
direct support for modular compilation of advanced non-local control
flow idioms, e.g. coroutines, async/await, yield-style generators,
lightweight threads, and so forth. This document outlines the new
instructions and validation rules to facilitate stack switching.

## Table of contents
1. [Motivation](#motivation)
1. [Examples](#examples)
   1. [Yield-style generators](#yield-style-generators)
   1. [Coroutines](#coroutines)
   1. [Lightweight threads](#lightweight-threads)
1. [Instruction set extension](#instruction-set-extension)
   1. [Declaring control tags](#declaring-control-tags)
   1. [Creating continuations](#creating-continuations)
   1. [Invoking continuations](#invoking-continuations)
   1. [Suspending continuations](#suspending-continuations)
   1. [Binding continuations](#binding-continuations)
   1. [Continuation lifetime](#continuation-lifetime)
1. [Design considerations](#design-considerations)
   1. [Asymmetric and symmetric switching](#asymmetric-and-symmetric-switching)
   1. [Linear usage of continuations](#linear-usage-of-continuations)
   1. [Memory management](#memory-management)
1. [Specification changes](#specification-changes)
   1. [Types](#types)
   1. [Tags](#tags)
   1. [Instructions](#instructions)
   1. [Execution](#execution)
   1. [Binary format](#binary-format)

## Motivation

Non-local control flow features provide the ability to suspend the
current execution context and later resume it. Many
industrial-strength programming languages feature a wealth of
non-local control flow features such as async/await, coroutines,
generators/iterators, effect handlers, and so forth. For some
programming languages non-local control flow is central to their
identity, meaning that they rely on non-local control flow for
efficiency, e.g. to support massively scalable concurrency.

Rather than build specific control flow mechanisms for all possible
varieties of non-local control flow, our strategy is to build a single
mechanism, *continuations*, that can be used by language providers to
construct their own language specific features.

## Continuations

A continuation represents a snapshot of execution on a particular
stack. Stack switching is realised by instructions for suspending and
resuming continuations. Continuations are composable, meaning that
when a suspended continuation is resumed it is spliced onto the
current continuation. This splicing establishes a parent-child
relationship between the current and resumed continuation. In this
respect the design provides a form of *asymmetric coroutines*.

SL: Perhaps the following paragraph belongs elsewhere

The parent-child relationship aligns with the caller-callee
relationship for standard function calls meaning that no special
plumbing is needed in order to compose the non-local control features
we define with built-in non-local control features such as traps,
exceptions, and embedder integration.

When suspending, we provide a tag and payload, much like when raising
an exception. Correspondingly, when resuming a suspended continuation
a *handler* is installed which specifies different behaviours for the
different kinds of tag with which the resumed continuation may
subsequently be suspended. Unlike for a normal exception handler the
handler is passed the suspended continuation as well as a payload.

We also offer an alternative to the interface based on suspending and
resuming continuations by way of an instruction for direct switching
between continuations. Direct switching combines suspending the
current continuation with resuming a previously suspended peer
continuation. Direct switching *does not* establish a parent-child
relationship between the current continuation and its peer. In this
respect the design provides a form of *symmetric coroutines*.

SL: Perhaps the following paragraph belongs elsewhere

Direct switching to a suspended peer continuation is semantically
equivalent to suspending the current continuation with a special
switch tag whose payload is the suspended peer continuation in the
context of a handler which resumes the peer continuation. However,
direct switching can (and should) be optimised to avoid the need to
switch control to the handler before switching control to the peer.

<!-- SL: I've done a quick polishing pass, but I think the rest of this -->
<!-- motivation section still has plenty of room for improvement. -->

<!-- A key technical design challenge is to ensure that stack switching -->
<!-- integrates smoothly with existing Wasm language features. Moreover, a -->
<!-- central concern is to ensure that stack switching remains safe, both -->
<!-- by respecting type-safety and by not breaking the sandboxing model of -->
<!-- Wasm. For these reasons the design does not allow mangling Wasm -->
<!-- stacks, that is, it preserves the abstract nature of Wasm execution -->
<!-- stacks. Instead, it provides handles to inactive execution stacks as -->
<!-- *continuations*. -->

<!-- A continuation represents the rest of a computation from a particular -->
<!-- point in its execution up to a *handler*. A continuation is akin to a -->
<!-- function in the sense that it takes a sequence of parameters and -->
<!-- returns a sequence of results, providing a typed view of a suspended -->
<!-- execution stack. The parameter types describe the data that must be -->
<!-- supplied in order for a continuation to resume executing, and the -->
<!-- result types describe the type of data that will be returned once it -->
<!-- has finished executing. -->

<!-- A continuation is created by suspending with a control tag --- control -->
<!-- tags generalise tags from the [exception handling -->
<!-- proposal](https://github.com/WebAssembly/exception-handling) with -->
<!-- result types. Each control tag is declared module-wide along with its -->
<!-- parameter types and result types. Control tags provide a means for -->
<!-- writing an interface to the possible kinds of non-local transfers (or -->
<!-- stack switches) that a computation may perform. -->

<!-- The proposal includes both asymmetric and symmetric mechanisms for -->
<!-- switching stacks. The asymmetric mechanism preserves the caller-callee -->
<!-- relationship between stacks, meaning that using the asymmetric -->
<!-- semantics to invoke a continuation installs the stack underlying the -->
<!-- callee as a child of the stack underlying the caller. Conversely, the -->
<!-- symmetric mechanism allows for swapping stacks in place, that is, -->
<!-- using the symmetric semantics to invoke a continuation replaces the -->
<!-- stack of the caller with the stack underlying the callee. -->

<!-- TODO: briefly mention and motivate direct switching -->

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
  (type $ft (func (result i32))) ;; [] -> [i32]
  (type $ct (cont $ft)) ;; cont [] -> [i32]

  ;; Control name declaration
  (tag $yield (export "yield") (param i32)) ;; i32 -> []

  ;; Producer: a stream of naturals
  (func $nats (export "nats") (result i32)
    (local $i i32) ;; zero-initialised local
    (loop $produce-next
      (suspend $yield (local.get $i)) ;; yield control with payload `i` to the surrounding context
      ;; compute the next natural
      (local.set $i
        (i32.add (local.get $i)
                 (i32.const 1)))
      (br $produce-next) ;; continue to produce the next natural number
    )
    (unreachable)
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

```wast
(module $co2
  (type $task (func (result i32))) ;; type alias task = [] -> []
  (type $ct   (cont $task)) ;; type alias   ct = $task

  (tag $interrupt (export "interrupt"))   ;; interrupt : [] -> []
  (tag $cancel (export "cancel"))   ;; cancel : [] -> []

  ;; run : [(ref $task) (ref $task)] -> []
  ;; implements a 'seesaw' (c.f. Ganz et al. (ICFP@99))
  (func $run (export "seesaw") (param $up (ref $ct)) (param $down (ref $ct)) (result i32)
    (local $result i32)
    ;; run $up
    (loop $run_next (result i32)
      (block $on_interrupt (result (ref $ct))
        (resume $ct (on $interrupt $on_interrupt)
                    (local.get $up))
        ;; $up finished, store its result
        (local.set $result)
        ;; next cancel $down
        (block $on_cancel
          (try_table (catch $cancel $on_cancel)
            ;; inject the cancel exception into $down
            (resume_throw $ct $cancel (local.get $down))
            (drop) ;; drop the return value if it handled $cancel
                   ;; itself and returned normally...
          )
        ) ;; ... otherwise catch $cancel and return $up's result.
       (return (local.get $result))
      ) ;; on_interrupt clause, stack type: [(cont $ct)]
      (local.set $up)
      ;; swap $up and $down
      (local.get $down)
      (local.set $down (local.get $up))
      (local.set $up)
      (br $run_next)
    )
  )
)
(register "co2")
```

```wast
(module $cogen
  (type $task (func (result i32)))
  (type $ct-task (cont $task))
  (type $seesaw (func (param (ref $ct-task)) (param (ref $ct-task)) (result i32)))
  (type $seesaw-ct (cont $seesaw))
  (type $gen (func (result i32))) ;; [] -> [i32]
  (type $ct-gen (cont $gen)) ;; cont [] -> [i32]
  (type $sum (func (param (ref $ct-gen)) (param i32) (result i32)))
  (type $ct-sum (cont $sum))

  (func $sumUp (import "generator" "sumUp") (param (ref $ct-gen)) (param i32) (result i32))
  (func $seesaw (import "co2" "seesaw") (param (ref $ct-task)) (param (ref $ct-task)) (result i32))

  (tag $yield (import "generator" "yield") (param i32))
  (tag $interrupt (import "co2" "interrupt"))

  (func $interruptible-nats (result i32)
    (local $i i32)
    (loop $produce-next (result i32)
      (suspend $yield (local.get $i))
      (suspend $interrupt)
      (local.set $i
        (i32.add (local.get $i)
                 (i32.const 1)))
      (br $produce-next) ;; continue to produce the next natural number
    )
  )

  (elem declare func $interruptible-nats $seesaw $sumUp)

  (func (export "sumUp-after-seesaw") (result i32)
    (local $up (ref $ct-task))
    (local $down (ref $ct-task))
    (local.set $up (cont.new $ct-task (ref.func $interruptible-nats)))
    (local.set $down (cont.new $ct-task (ref.func $interruptible-nats)))
    (call $sumUp (cont.bind $seesaw-ct $ct-gen
                      (local.get $up)
                      (local.get $down)
                      (cont.new $seesaw-ct (ref.func $seesaw)))
                 (i32.const 10)))
  (func (export "seesaw-after-sumUp") (result i32)
    (local $up (ref $ct-gen))
    (local $down (ref $ct-gen))
    (local.set $up
       (cont.bind $ct-sum $ct-gen
         (cont.new $ct-gen (ref.func $interruptible-nats))
         (i32.const 10)
         (cont.new $ct-sum (ref.func $sumUp))))
    (local.set $down
       (cont.bind $ct-sum $ct-gen
         (cont.new $ct-gen (ref.func $interruptible-nats))
         (i32.const 10)
         (cont.new $ct-sum (ref.func $sumUp))))
    (call $seesaw (local.get $up) (local.get $down)))
)

(assert_return (invoke "sumUp-after-seesaw") (i32.const 100))
(assert_return (invoke "seesaw-after-sumUp") (i32.const 55))
```

### Lightweight threads

TODO

#### Asymmetric variation

TODO

#### Symmetric variation

TODO

## Instruction set extension

In this section we give an informal overview and explanations of the
proposed instruction set extension. In Section [Specification
changes](#specification-changes) we give an overview of the validation
and execution rules as well as changes to the binary format.

The proposal adds a new reference type for continuations.

```wast
  (cont $ft)
```

A continuation type is given in terms of a function type `$ft`, whose
parameters `t1*` describes the expected stack shape prior to
resuming/starting the continuation, and whose return types `t2*`
describes the stack shape after the continuation has run to
completion.

As a shorthand, we will often write the function type inline and write
a continuation type as

```wast
  (cont [t1*] -> [t2*])
```

### Declaring control tags

A control tag is similar to an exception extended with a result type
(or list thereof). Operationally, a control tag may be thought of as a
*resumable* exception. A tag declaration provides the type signature
of a control tag.

```wast
  (tag $t (param t1*) (result t2*))
```

The `$t` is the symbolic index of the control tag in the index space
of tags. The parameter types `t1*` describe the expected stack layout
prior to invoking the tag, and the result types `t2*` describe the
stack layout following an invocation of the operation. In this
document we will sometimes write `$t : [t1*] -> [t2*]` as shorthand
for indicating that such a declaration is in scope.

### Creating continuations

The following instruction creates a continuation in *suspended state*
from a function.

```wast
  cont.new $ct : [(ref $ft)] -> [(ref $ct)]
  where:
  - $ft = func [t1*] -> [t2*]
  - $ct = cont $ft
```

The instruction takes as operand a reference to a function of type
`[t1*] -> [t2*]`. The body of this function is a computation that may
perform non-local control flow.


### Invoking continuations

There are three ways to invoke (or run) a continuation.

The first way to invoke a continuation resumes the continuation under
a *handler*, which handles subsequent control suspensions within the
continuation.

```wast
  resume $ct hdl* : [t1* (ref $ct)] -> [t2*]
  where:
  - $ct = cont [t1*] -> [t2*]
```

The `resume` instruction is parameterised by a continuation type and a
handler dispatch table `hdl`. The shape of `hdl` can be either:

1. `(on $e $l)` mapping the control tag `$e` to the label
`$l`. Intercepting `$e` causes a branch to `$l`.

1. `(on $e switch)` allowing a direct switch with control tag `$e`.


The `resume` instruction consumes its continuation argument, meaning a
continuation may be resumed only once.

The second way to invoke a continuation is to raise an exception at
the control tag invocation site. This amounts to performing "an
abortive action" which causes the stack to be unwound.


```wast
  resume_throw $ct $exn hdl* : [te* (ref $ct)])] -> [t2*]
  where:
  - $ct = cont [t1*] -> [t2*]
  - $exn : [te*] -> []
```

The instruction `resume_throw` is parameterised by a continuation
type, the exception to be raised at the control tag invocation site,
and a handler dispatch table. As with `resume`, this instruction also
fully consumes its continuation argument. Operationally, this
instruction raises the exception `$exn` with parameters of type `te*`
at the control tag invocation point in the context of the supplied
continuation. As an exception is being raised (the continuation is not
actually being supplied a value) the parameter types for the
continuation `t1*` are unconstrained.

The third way to invoke a continuation is to perform a symmetric
switch.

```wast
  switch $ct1 $e : [t1* (ref $ct1)] -> [t2*]
  where:
  - $e = tag [] -> [t*]
  - $ct1 = cont [t1* (ref $ct2)] -> [te1*]
  - te1* <: t*
  - $ct2 = cont [t2*] -> [te2*]
  - t* <: te2*
```

The instruction `switch` is parameterised by a continuation type and a
control tag. The instruction suspends the current continuation and
thereafter performs a direct switch to its continuation argument.  As
with `resume` and `resume_throw`, this instruction fully consumes its
continuation argument.

### Suspending continuations

A computation running inside a continuation can suspend itself by
invoking one of the declared control tags.


```wast
  suspend $e : [t1*] -> [t2*]
  where:
  - $e : [t1*] -> [t2*]
```

The instruction `suspend` invokes the control tag named `$e` with
arguments of types `tp*`. Operationally, the instruction transfers
control out of the continuation to the nearest enclosing handler for
`$e`. This behaviour is similar to how raising an exception transfers
control to the nearest exception handler that handles the
exception. The key difference is that the continuation at the
suspension point expects to be resumed later with arguments of types
`tr*`.

### Binding continuations

The parameter list of a continuation may be shrunk via `cont.bind`. This
instruction provides a way to partially apply a given
continuation. This facility turns out to be important in practice due
to the block and type structure of Wasm as in order to return a
continuation from a block, all branches within the block must agree on
the type of continuation. By using `cont.bind`, one can
programmatically ensure that the branches within a block each return a
continuation with compatible type (the [Examples](#examples) section
provides several example usages of `cont.bind`).


```wast
  cont.bind $ct1 $ct2 : [t1* (ref $ct1)] -> [(ref $ct2)]
  where:
  $ct1 = cont [t1* t3*] -> [t2*]
  $ct2 = cont [t3*] -> [t2*]
```

The instruction `cont.bind` binds the arguments of type `tp1*` to a
continuation of type `$ct1`, yielding a modified continuation of type
`$ct2` which expects fewer arguments. This instruction also consumes
its continuation argument, and yields a new continuation that can be
supplied to either `resume`,`resume_throw`, or `cont.bind`.

### Continuation lifetime

#### Producing continuations

There are four different ways in which continuations are produced
(`cont.new,suspend,cont.bind,switch`). A fresh continuation object is
allocated with `cont.new` and the current continuation is reused with
`suspend`, `cont.bind`, and `switch`.

The `cont.bind` instruction is directly analogous to the mildly
controversial `func.bind` instruction from the function references
proposal. However, whereas the latter necessitates the allocation of a
new closure, as continuations are single-shot no allocation is
necessary: all allocation happens when the original continuation is
created by preallocating one slot for each continuation argument.

#### Consuming continuations

There are four different ways in which continuations are consumed
(`resume,resume_throw,switch,cont.bind`). A continuation may be
resumed with a particular handler with `resume`; aborted with
`resume_throw`; symmetrically switched to via `switch`; or partially
applied with `cont.bind`.

In order to ensure that continuations are one-shot, `resume`,
`resume_throw`, `switch`, and `cont.bind` destructively modify the
continuation object such that any subsequent use of the same
continuation object will result in a trap.

## Design considerations

In this section we discuss some key design considerations.

### Asymmetric and symmetric switching

TODO

### Linear usage of continuations

Continuations in this proposal are single-shot (aka linear), meaning
that they must be invoked exactly once (though this is not statically
enforced). A continuation can be invoked either by resuming it (with
`resume`); by aborting it (with `resume_throw`); or by switching to it
(with `switch`). Some applications such as backtracking, probabilistic
programming, and process duplication exploit multi-shot continuations,
but none of the critical use cases require multi-shot
continuations. Nevertheless, it is natural to envisage a future
iteration of this proposal that includes support for multi-shot
continuations by way of a continuation clone instruction.

### Memory management

The current proposal does not require a general garbage collector as
the linearity of continuations guarantees that there are no cycles in
continuation objects.  In theory, we could dispense with automated
memory management altogether if we took seriously the idea that
failure to use a continuation constitutes a bug in the producer. In
practice, for most producers enforcing such a discipline is
unrealistic and not something an engine can rely on anyway. To prevent
space leaks, most engines will either need some form of automated
memory management for unconsumed continuations or a monotonic
continuation allocation scheme.

* Automated memory management: due to the acyclicity of continuations,
  a reference counting scheme is sufficient.
* Monotonic continuation allocation: it is safe to use a continuation
  object as long as its underlying stack is alive. It is trivial to
  ensure a stack is alive by delaying deallocation until the program
  finishes. To avoid excessive use of memory, an engine can equip a
  stack with a revision counter, thus making it safe to repurpose the
  allocated stack for another continuation.

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

This abbreviation will be formalised with an auxiliary function or other means in the spec.

- `cont.new <typeidx>`
  - Create a new continuation from a given typed funcref.
  - `cont.new $ct : [(ref null? $ft)] -> [(ref $ct)]`
    - iff `C.types[$ct] ~~ cont [t1*] -> [t2*]`

- `cont.bind <typeidx> <typeidx>`
  - Partially apply a continuation.
  - `cont.bind $ct $ct' : [t3* (ref null? $ct)] -> [(ref $ct')]`
    - iff `C.types[$ct] ~~ cont [t3* t1*] -> [t2*]`
    - and `C.types[$ct'] ~~ cont [t1'*] -> [t2'*]`
    - and `[t1*] -> [t2*] <: [t1'*] -> [t2'*]`

- `resume <typeidx> hdl*`
  - Execute a given continuation.
    - If the executed continuation suspends with a control tag `$t`, the corresponding handler `(on $t H)` is executed.
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
  - Handlers attached to `resume` and `resume_throw`, handling control tags for `suspend` and `switch`, respectively.
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
  - Use a control tag to suspend the current computation.
  - `suspend $t : [t1*] -> [t2*]`
    - iff `C.tags[$t] = tag $ft`
    - and `C.types[$ft] ~~ func [t1*] -> [t2*]`

- `switch <typeidx> <tagidx>`
  - Switch to executing a given continuation directly, suspending the current execution.
  - The suspension and switch are performed from the perspective of a parent `(on $e switch)` handler, determined by the annotated control tag.
  - `switch $ct1 $e : [t1* (ref null $ct1)] -> [t2*]`
    - iff `C.tags[$e] = tag $ft`
    - and `C.types[$ft] ~~ func [] -> [t*]`
    - and `C.types[$ct1] ~~ cont [t1* (ref null? $ct2)] -> [te1*]`
    - and `te1* <: t*`
    - and `C.types[$ct2] ~~ cont [t2*] -> [te2*]`
    - and `t* <: te2*`

### Execution

The same control tag may be used simultaneously by `throw`, `suspend`,
`switch`, and their associated handlers. When searching for a handler
for an event, only handlers for the matching kind of event are
considered, e.g. only `(on $e $l)` handlers can handle `suspend`
events and only `(on $e switch)` handlers can handle `switch`
events. The handler search continues past handlers for the wrong kind
of event, even if they use the correct tag.

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
