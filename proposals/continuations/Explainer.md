# Typed continuations

This document provides an informal presentation of the *typed
continuations* proposal, a minimal and compatible extension to Wasm
for structured non-local control flow. The proposal is minimal in the
sense that it leverages Wasm's existing instruction set and type
system. It extends the instruction set with instructions to suspend,
resume, and abort computations, and extends the type system with a
single new reference type for *continuations*.

## Table of contents

1. [Motivation](#motivation)
2. [Additional requirements](#additional-requirements)
3. [Instruction set](#instruction-set)
   1. [Declaring control tags](#declaring-control-tags)
   2. [Creating continuations](#creating-continuations)
   3. [Invoking continuations](#invoking-continuations)
   4. [Suspending continuations](#suspending-continuations)
   5. [Binding continuations](#binding-continuations)
   6. [Trapping continuations](#trapping-continuations)
4. [Examples](#examples)
   1. [Lightweight threads (static)](#lightweight-threads-static)
   2. [Lightweight threads (dynamic)](#lightweight-threads-dynamic)
   3. [Actors](#actors)
   4. [Async/await](#asyncawait)
   5. [Delimited continuations](#delimited-continuations)
5. [Implementation strategies](#implementation-strategies)
6. [Design considerations and extensions](#design-considerations-and-extensions)
   1.  [Memory management](#memory-management)
   2.  [Linear versus constant time dispatch](#linear-versus-constant-time-dispatch)
   3.  [Named handlers](#named-handlers)
   4.  [Direct switching](#direct-switching)
   5.  [Control/prompt as an alternative basis](#controlprompt-as-an-alternative-basis)
   6.  [Coupling of continuation capture and dispatch](#coupling-of-continuation-capture-and-dispatch)
   7.  [Tail-resumptive handlers](#tail-resumptive-handlers)
   8.  [Multi-shot continuations](#multi-shot-continuations)
   9.  [Interoperability, legacy code, and the barrier instruction](#interoperability-legacy-code-and-the-barrier-instruction)
   10. [First-class tags](#first-class-tags)
   11. [Shallow versus deep handlers](#shallow-versus-deep-handlers)

## Motivation

Non-local control flow features provide the ability to suspend the
current execution context and later resume it. Many
industrial-strength programming languages feature a wealth of
non-local control flow features such as async/await, coroutines,
generators/iterators, effect handlers, call/cc, and so forth. For some
programming languages non-local control flow is central to their
identity, meaning that they rely on non-local control flow for
efficiency, e.g. to support massively scalable concurrency.

Currently, Wasm lacks support for implementing such features directly
and efficiently without a circuitous global transformation of source
programs on the producer side. One possible strategy is to add special
support for each individual non-local control flow feature to Wasm,
but strategy does not scale to the next 700 non-local control flow
features. Instead, the goal of this proposal is to introduce a unifed
structured mechanism that is sufficiently general to cover present
use-cases as well as being forwards compatible with future use-cases,
while admitting efficient implementations.

The proposed mechanism is based on proven technology: *delimited
continuations*. An undelimited continuation represents the rest of a
computation from a certain point in its execution. A delimited
continuation is a more modular form of continuation, representing the
rest of a computation from a particular point in its execution up to a
*delimiter* or *prompt*. Operationally, one may think of undelimited
continuations as stacks and delimited continuations as segmented
stacks.

In their raw form delimited continuations do not readily fit into the
Wasm ecosystem, as the Wasm type system is not powerful enough to type
them. The gist of the problem is that the classic treatment of
delimited continuations provides only one universal control tag
(i.e. the mechanism which transforms a runtime stack into a
programmatic data object). In order to use Wasm's simple type system
to type delimited continuations, we use the idea of multiple *named*
control tags from Plotkin and Pretnar's effect handlers. Each control
tag is declared module-wide along its payload type and return
type. This declaration can be used to readily type points of non-local
transfer of control. From an operational perspective we may view
control tags as a means for writing an interface for the possible
kinds of non-local transfers (or stack switches) that a computation
may perform.

### Typed continuation primer

A *continuation* is a first-class program object that represents the
remainder of computation from a certain point in the execution of a
program --- intuitively, its current stack. The typed continuations
proposal is based on a structured notion of delimited continuations. A
*delimited continuation* is a continuation whose extent is delimited
by some *control delimiter*, meaning it represents the remainder of
computation from a certain point up to (and possibly including) its
control delimiter -- intuitively, a segment of the stack. An
alternative to delimited continuations is undelimited continuations
which represent the remainder of the *entire* program. Delimited
continuations are preferable as they are more modular and more
fine-grained in the sense that they provide a means for suspending
local execution contexts rather than the entire global execution
context. In particular, delimited continuations are more expressive,
as an undelimited continuation is merely a delimited continuation
whose control delimiter is placed at the start of the program.

The crucial feature of the typed continuations proposal that makes it
more structured than conventional delimited continuations is *control
tags*. A control tag is a typed symbolic entity that suspends the
current execution context and reifies it as a *continuation object*
(henceforth, just *continuation*) up to its control delimiter. The
type of a control tag communicates the type of its payload as well as
its expected return type, i.e. the type of data that must be supplied
to its associated continuation upon resumption. In other words,
control tags define an *interface* for constructing continuations.

A second aspect of the design that aids modularity by separating
concerns is that the construction of continuations is distinct from
*handling* of continuations. A continuation is handled at the
delimiter of a control tag rather than at the invocation site of the
control tag. Control tags are a mild extension of exception tags as in
the exception handling proposal. The key difference is that in
addition to a payload type, a control tag also declares a return
type. Roughly, control tags can be thought of as resumable exceptions.

Typed continuations may be efficiently implemented using segmented
stacks, but other implementations are also possible.

## Additional requirements

 * **No GC dependency**: We intend every language to be able to use
   typed continuations to implement non-local flow abstractions
   irrespective of whether its memory is managed by a GC. Thus this
   proposal must not depend on the presence of a full-blown GC as in
   the GC proposal, rather, reference counting or a similar technique
   must be sufficient in cases where some form of memory management is
   necessary.

 * **Debugging friendliness**: The addition of continuations must
   preserve compatibility with standard debugging formats such as
   DWARF, meaning it must be possible to obtain a sequential
   unobstructed stack trace in the presence of continuations.

 * **Exception handling compatibility**: [The exception handling
   proposal](https://github.com/WebAssembly/exception-handling) adds
   special support for one kind of non-local control flow abstraction,
   namely, exception handlers. Exceptions must continue to work in the
   presence of typed continuations and vice versa.

 * **Preserve Wasm invariants of legacy code**: The proposal must
   provide a means to protect the invariants of existing Wasm
   code. For instance, this means that in the presence of code that
   uses typed continuations it should be possible to ensure that other
   legacy code cannot suspend. The mechanism for protecting invariants
   need not be automatic (in the same vein as explicit synchronisation
   might be needed when adding threads and shared memory).

## Instruction set

The proposal adds a new reference type for continuations.

```wast
  (cont $t)
```

A continuation type is given in terms of a function type `$t`, whose parameters `tp*`
describes the expected stack shape prior to resuming/starting the
continuation, and whose return types `tr*` describes the stack
shape after the continuation has run to completion.

As a shorthand, we will often write the function type inline and write a continuation type as
```wast
  (cont [tp*] -> [tr*])
```

### Declaring control tags

A control tag is similar to an exception extended with a result type
(or list thereof). Operationally, a control tag may be thought of as a
*resumable* exception. A tag declaration provides the type signature
of a control tag.

```wast
  (tag $e (param tp*) (result tr*))
```

The `$e` is the symbolic index of the control tag in the index space
of tags. The parameter types `tp*` describe the expected stack layout
prior to invoking the tag, and the result types `tr*` describe the
stack layout following an invocation of the operation. In this
document we will sometimes write `$e : [tp*] -> [tr*]` as shorthand
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

The instruction takes as operand a reference to
a function of type `[t1*] -> [t2*]`. The body of this function is a
computation that may perform non-local control flow.


### Invoking continuations

There are two ways to invoke (or run) a continuation.

The first way to invoke a continuation resumes the continuation under
a *handler*, which handles subsequent control suspensions within the
continuation.

```wast
  resume $ct (tag $e $l)* : [tp* (ref $ct)] -> [tr*]
  where:
  - $ct = cont [tp*] -> [tr*]
```

The `resume` instruction is parameterised by a continuation type and a
handler dispatch table defined by a collection of pairs of control
tags and labels. Each pair maps a control tag to a label pointing to
its corresponding handler code. The `resume` instruction consumes its
continuation argument, meaning a continuation may be resumed only
once.

The second way to invoke a continuation is to raise an exception at
the control tag invocation site. This amounts to performing "an
abortive action" which causes the stack to be unwound.


```wast
  resume_throw $ct $exn (tag $e $l)* : [tp* (ref $ct)])] -> [tr*]
  where:
  - $ct = cont [ta*] -> [tr*]
  - $exn : [tp*] -> []
```

The instruction `resume_throw` is parameterised by a continuation
type, the exception to be raised at the control tag invocation site,
and a handler dispatch table. As with `resume`, this instruction also
fully consumes its continuation argument. Operationally, this
instruction raises the exception `$exn` with parameters of type `tp*`
at the control tag invocation point in the context of the supplied
continuation. As an exception is being raised (the continuation is not
actually being supplied a value) the parameter types for the
continuation `ta*` are unconstrained.

### Suspending continuations

A computation running inside a continuation can suspend itself by
invoking one of the declared control tags.


```wast
  suspend $e : [tp*] -> [tr*]
  where:
  - $e : [tp*] -> [tr*]
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
  cont.bind $ct1 $ct2 : [tp1* (ref $ct1)] -> [(ref $ct2)]
  where:
  $ct1 = cont [tp1* tp2*] -> [tr*]
  $ct2 = cont [tp2*] -> [tr*]
```

The instruction `cont.bind` binds the arguments of type `tp1*` to a
continuation of type `$ct1`, yielding a modified continuation of type
`$ct2` which expects fewer arguments. This instruction also consumes
its continuation argument, and yields a new continuation that can be
supplied to either `resume`,`resume_throw`, or `cont.bind`.

### Trapping continuations

In order to allow ensuring that control cannot be captured across
certain abstraction or language boundaries, we provide an instruction
for explicitly trapping attempts at reifying stacks across a certain
point.

```wast
  barrier $l bt instr* end : [t1*] -> [t2*]
  where:
  - bt = [t1*] -> [t2*]
  - instr* : [t1*] -> [t2*]
```

The `barrier` instruction is a block with label `$l`, block type
`bt = [t1*] -> [t2*]`, whose body is the instruction sequence given
by `instr*`. Operationally, `barrier` may be viewed as a "catch-all"
handler, that handles any control tag by invoking a trap.

## Continuation lifetime

### Producing continuations

There are three different ways in which continuations are produced
(`cont.new,suspend,cont.bind`). A fresh continuation object is
allocated with `cont.new` and the current continuation is reused with
`suspend` and `cont.bind`.

The `cont.bind` instruction is directly analogous to the mildly
controversial `func.bind` instruction from the function references
proposal. However, whereas the latter necessitates the allocation of a
new closure, as continuations are single-shot no allocation is
necessary: all allocation happens when the original continuation is
created by preallocating one slot for each continuation argument.

### Consuming continuations

There are three different ways in which continuations are consumed
(`resume,resume_throw,cont.bind`). A continuation is resumed with a
particular handler with `resume`. A continuation is aborted with
`resume_throw`. A continuation is partially applied with `cont.bind`.

In order to ensure that continuations are one-shot, `resume`,
`resume_throw`, and `cont.bind` destructively modify the continuation
object such that any subsequent use of the same continuation object
will result in a trap.

## Examples

### Lightweight threads (static)

(The full code for this example is [here](examples/static-lwt.wast).)

Lightweight threads are one of the primary use-cases for typed
continuations. In their most basic *static* form we assume a fixed
collection of cooperative threads with a single tag that allows a
thread to signal that it is willing to yield.

```wast
(module $lwt
  (tag $yield (export "yield"))
)
(register "lwt")
```

The `$yield` tag takes no parameter and has no result. Having
declared it, we can now write some cooperative threads as functions.

```wast
(module $example
  (tag $yield (import "lwt" "yield"))
  (func $log (import "spectest" "print_i32") (param i32))

  (func $thread1 (export "thread1")
    (call $log (i32.const 10))
    (suspend $yield)
    (call $log (i32.const 11))
    (suspend $yield)
    (call $log (i32.const 12))
  )

  (func $thread2 (export "thread2")
    (call $log (i32.const 20))
    (suspend $yield)
    (call $log (i32.const 21))
    (suspend $yield)
    (call $log (i32.const 22))
  )

  (func $thread3 (export "thread3")
    (call $log (i32.const 30))
    (suspend $yield)
    (call $log (i32.const 31))
    (suspend $yield)
    (call $log (i32.const 32))
  )
)
(register "example")
```

Our intention is to interleave the execution of `$thread1`,
`$thread2`, and `$thread3`, using `(suspend $yield)` to suspend
execution to a scheduler which will perform a context switch.

If we were to try to run any of these functions at the top-level then
they would trap as soon as they try to suspend with the `$yield$`
tag, because we have not yet specified how to handle it.

We now define a scheduler.

```wast
(module $scheduler
  (type $func (func))
  (type $cont (cont $func))

  (tag $yield (import "lwt" "yield"))

  ;; queue interface
  (func $queue-empty (import "queue" "queue-empty") (result i32))
  (func $dequeue (import "queue" "dequeue") (result (ref null $cont)))
  (func $enqueue (import "queue" "enqueue") (param $k (ref $cont)))

  (func $run (export "run")
    (loop $l
      (if (call $queue-empty) (then (return)))
      (block $on_yield (result (ref $cont))
        (resume $cont (tag $yield $on_yield)
                      (call $dequeue)
        )
        (br $l)  ;; thread terminated
      ) ;;   $on_yield (result (ref $cont))
      (call $enqueue)  ;; continuation of current thread
      (br $l)
    )
  )
)
(register "scheduler")
```

We assume a suitable interface to a queue of active threads
represented as continuations. The scheduler is a loop which repeatedly
runs the continuation (thread) at the head of the queue. It does so by
resuming the continuation with a handler for the `$yield` tag. The
handler `(tag $yield $on_yield)` specifies that the `$yield` tag
is handled by running the code immediately following the block
labelled with `$on_yield`, the `$on_yield` clause. The result of the
block `(result (ref $cont))` declares that there will be a
continuation on the stack when suspending with the `$yield` tag,
which is the continuation of the currently executing thread. The
`$on_yield` clause enqueues this continuation and proceeds to the next
iteration of the loop.

In order to interleave our three test threads together, we create a
new continuation for each, enqueue the continuations, and invoke the
scheduler. The `cont.new` operation turns a function reference into a
corresponding continuation reference.

```wast
(module
  (type $func (func))
  (type $cont (cont $func))

  (func $scheduler (import "scheduler" "run"))
  (func $enqueue (import "queue" "enqueue") (param (ref $cont)))

  (func $log (import "spectest" "print_i32") (param i32))

  (func $thread1 (import "example" "thread1"))
  (func $thread2 (import "example" "thread2"))
  (func $thread3 (import "example" "thread3"))

  (elem declare func $thread1 $thread2 $thread3)

  (func (export "run")
    (call $enqueue (cont.new $cont (ref.func $thread1)))
    (call $enqueue (cont.new $cont (ref.func $thread2)))
    (call $enqueue (cont.new $cont (ref.func $thread3)))

    (call $log (i32.const -1))
    (call $scheduler)
    (call $log (i32.const -2))
  )
)

(invoke "run")
```

The output is as follows.
```
-1 : i32
10 : i32
20 : i32
30 : i32
11 : i32
21 : i32
31 : i32
12 : i32
22 : i32
32 : i32
-2 : i32
```
The threads are interleaved as expected.

### Lightweight threads (dynamic)

(The full code for this example is [here](examples/lwt.wast).)

We can make our lightweight threads functionality considerably more
expressive by allowing new threads to be forked dynamically.

```wast
(module $lwt
  (type $func (func))
  (type $cont (cont $func))

  (tag $yield (export "yield"))
  (tag $fork (export "fork") (param (ref $cont)))
)
(register "lwt")
```

We declare a new `$fork` tag that takes a continuation as a
parameter and (like `$yield`) returns no result. Now we modify our
example to fork each of the three threads from a single main thread.

```wast
(module $example
  (type $func (func))
  (type $cont (cont $func))

  (tag $yield (import "lwt" "yield"))
  (tag $fork (import "lwt" "fork") (param (ref $cont)))

  (func $log (import "spectest" "print_i32") (param i32))

  (elem declare func $thread1 $thread2 $thread3)

  (func $main (export "main")
    (call $log (i32.const 0))
    (suspend $fork (cont.new $cont (ref.func $thread1)))
    (call $log (i32.const 1))
    (suspend $fork (cont.new $cont (ref.func $thread2)))
    (call $log (i32.const 2))
    (suspend $fork (cont.new $cont (ref.func $thread3)))
    (call $log (i32.const 3))
  )

  (func $thread1
    (call $log (i32.const 10))
    (suspend $yield)
    (call $log (i32.const 11))
    (suspend $yield)
    (call $log (i32.const 12))
  )

  (func $thread2
    (call $log (i32.const 20))
    (suspend $yield)
    (call $log (i32.const 21))
    (suspend $yield)
    (call $log (i32.const 22))
  )

  (func $thread3
    (call $log (i32.const 30))
    (suspend $yield)
    (call $log (i32.const 31))
    (suspend $yield)
    (call $log (i32.const 32))
  )
)
(register "example")
```

As with the static example we define a scheduler module.
```wast
(module $scheduler
  (type $func (func))
  (type $cont (cont $func))

  (tag $yield (import "lwt" "yield"))
  (tag $fork (import "lwt" "fork") (param (ref $cont)))

  (func $queue-empty (import "queue" "queue-empty") (result i32))
  (func $dequeue (import "queue" "dequeue") (result (ref null $cont)))
  (func $enqueue (import "queue" "enqueue") (param $k (ref null $cont)))
  ...
)
(register "scheduler")
```

In this example we illustrate five different schedulers. First, we
write a baseline synchronous scheduler which simply runs the current
thread to completion without actually yielding.

```wast
  (func $sync (export "sync") (param $nextk (ref null $cont))
    (loop $l
      (if (ref.is_null (local.get $nextk)) (then (return)))
      (block $on_yield (result (ref $cont))
        (block $on_fork (result (ref $cont) (ref $cont))
          (resume $cont (tag $yield $on_yield)
                        (tag $fork $on_fork)
                        (local.get $nextk)
          )
          (local.set $nextk (call $dequeue))
          (br $l)  ;; thread terminated
        ) ;;   $on_fork (result (ref $cont) (ref $cont))
        (local.set $nextk)                      ;; current thread
        (call $enqueue) ;; new thread
        (br $l)
      )
      ;;     $on_yield (result (ref $cont))
      (local.set $nextk)  ;; carry on with current thread
      (br $l)
    )
  )
```

The `$nextk` parameter represents the continuation of the next
thread. The loop is repeatedly executed until `$nextk` is null
(meaning that all threads have finished). The body of the loop is the
code inside the two nested blocks. It resumes the next continuation,
dequeues the next continuation, and then continues to the next
iteration of the loop. The handler passed to `resume` specifies how to
handle both `$yield` and `$fork` tags. Yielding carries on executing
the current thread (this scheduler is synchronous). Forking enqueues
the new thread and continues executing the current thread.

As with the static example, the result of the `$on_yield` block
`(result (ref $cont))` declares that there will be a continuation on
the stack when suspending with the `$yield` tag, which is the
continuation of the currently executing thread. The result of the
`$on_fork` block `(result (ref $cont) (ref $cont))` declares that
there will be two continuations on the stack when suspending with the
`$fork` tag: the first is the parameter passed to fork (the new
thread) and the second is the continuation of the currently executing
thread.

Running the synchronous scheduler on the example produces the following output.
```
0 : i32
1 : i32
2 : i32
3 : i32
10 : i32
11 : i32
12 : i32
20 : i32
21 : i32
22 : i32
30 : i32
31 : i32
32 : i32
```
First the main thread runs to completion, then each of the forked
threads in sequence.

Following a similar pattern, we define four different asynchronous
schedulers.

```wast
  ;; four asynchronous schedulers:
  ;;   * kt and tk don't yield on encountering a fork
  ;;     1) kt runs the continuation, queuing up the new thread for later
  ;;     2) tk runs the new thread first, queuing up the continuation for later
  ;;   * ykt and ytk do yield on encountering a fork
  ;;     3) ykt runs the continuation, queuing up the new thread for later
  ;;     4) ytk runs the new thread first, queuing up the continuation for later

  ;; no yield on fork, continuation first
  (func $kt (export "kt") (param $nextk (ref null $cont))
    (loop $l
      (if (ref.is_null (local.get $nextk)) (then (return)))
      (block $on_yield (result (ref $cont))
        (block $on_fork (result (ref $cont) (ref $cont))
          (resume $cont (tag $yield $on_yield)
                        (tag $fork $on_fork)
                        (local.get $nextk)
          )
          (local.set $nextk (call $dequeue))
          (br $l)  ;; thread terminated
        ) ;;   $on_fork (result (ref $cont) (ref $cont))
        (local.set $nextk)                      ;; current thread
        (call $enqueue) ;; new thread
        (br $l)
      )
      ;;     $on_yield (result (ref $cont))
      (call $enqueue)                    ;; current thread
      (local.set $nextk (call $dequeue)) ;; next thread
      (br $l)
    )
  )

  ;; no yield on fork, new thread first
  (func $tk (export "tk") (param $nextk (ref null $cont))
    (loop $l
      (if (ref.is_null (local.get $nextk)) (then (return)))
      (block $on_yield (result (ref $cont))
        (block $on_fork (result (ref $cont) (ref $cont))
          (resume $cont (tag $yield $on_yield)
                        (tag $fork $on_fork)
                        (local.get $nextk)
          )
          (local.set $nextk (call $dequeue))
          (br $l)  ;; thread terminated
        ) ;;   $on_fork (result (ref $cont) (ref $cont))
        (call $enqueue)                            ;; current thread
        (local.set $nextk) ;; new thread
        (br $l)
      )
      ;;     $on_yield (result (ref $cont))
      (call $enqueue)                    ;; current thread
      (local.set $nextk (call $dequeue)) ;; next thread
      (br $l)
    )
  )

  ;; yield on fork, continuation first
  (func $ykt (export "ykt") (param $nextk (ref null $cont))
    (loop $l
      (if (ref.is_null (local.get $nextk)) (then (return)))
      (block $on_yield (result (ref $cont))
        (block $on_fork (result (ref $cont) (ref $cont))
          (resume $cont (tag $yield $on_yield)
                        (tag $fork $on_fork)
                        (local.get $nextk)
          )
          (local.set $nextk (call $dequeue))
          (br $l)  ;; thread terminated
        ) ;;   $on_fork (result (ref $cont) (ref $cont))
        (call $enqueue)                         ;; current thread
        (call $enqueue) ;; new thread
        (local.set $nextk (call $dequeue))      ;; next thread
        (br $l)
      )
      ;;     $on_yield (result (ref $cont))
      (call $enqueue)                    ;; current thread
      (local.set $nextk (call $dequeue)) ;; next thread
      (br $l)
    )
  )

  ;; yield on fork, new thread first
  (func $ytk (export "ytk") (param $nextk (ref null $cont))
    (loop $l
      (if (ref.is_null (local.get $nextk)) (then (return)))
      (block $on_yield (result (ref $cont))
        (block $on_fork (result (ref $cont) (ref $cont))
          (resume $cont (tag $yield $on_yield)
                        (tag $fork $on_fork)
                        (local.get $nextk)
          )
          (local.set $nextk (call $dequeue))
          (br $l)  ;; thread terminated
        ) ;;   $on_fork (result (ref $cont) (ref $cont))
        (local.set $nextk)
        (call $enqueue) ;; new thread
        (call $enqueue (local.get $nextk))      ;; current thread
        (local.set $nextk (call $dequeue))      ;; next thread
        (br $l)
      )
      ;;     $on_yield (result (ref $cont))
      (call $enqueue)                    ;; current thread
      (local.set $nextk (call $dequeue)) ;; next thread
      (br $l)
    )
  )
```

Each `$on_yield` clause is identical, enqueing the continuation of the
current thread and dequeing the next continuation for the thread. The
`$on_fork` clauses implement different behaviours for scheduling the
current and newly forked threads.

We run our example using each of the five schedulers.

```wast
(module
  (type $func (func))
  (type $cont (cont $func))

  (func $scheduler1 (import "scheduler" "sync") (param $nextk (ref null $cont)))
  (func $scheduler2 (import "scheduler" "kt") (param $nextk (ref null $cont)))
  (func $scheduler3 (import "scheduler" "tk") (param $nextk (ref null $cont)))
  (func $scheduler4 (import "scheduler" "ykt") (param $nextk (ref null $cont)))
  (func $scheduler5 (import "scheduler" "ytk") (param $nextk (ref null $cont)))

  (func $log (import "spectest" "print_i32") (param i32))

  (func $main (import "example" "main"))

  (elem declare func $main)

  (func (export "run")
    (call $log (i32.const -1))
    (call $scheduler1 (cont.new $cont (ref.func $main)))
    (call $log (i32.const -2))
    (call $scheduler2 (cont.new $cont (ref.func $main)))
    (call $log (i32.const -3))
    (call $scheduler3 (cont.new $cont (ref.func $main)))
    (call $log (i32.const -4))
    (call $scheduler4 (cont.new $cont (ref.func $main)))
    (call $log (i32.const -5))
    (call $scheduler5 (cont.new $cont (ref.func $main)))
    (call $log (i32.const -6))
  )
)

(invoke "run")
```

The output is as follows, demonstrating the various different scheduling behaviours.
```
-1 : i32
0 : i32
1 : i32
2 : i32
3 : i32
10 : i32
11 : i32
12 : i32
20 : i32
21 : i32
22 : i32
30 : i32
31 : i32
32 : i32
-2 : i32
0 : i32
1 : i32
2 : i32
3 : i32
10 : i32
20 : i32
30 : i32
11 : i32
21 : i32
31 : i32
12 : i32
22 : i32
32 : i32
-3 : i32
0 : i32
10 : i32
1 : i32
20 : i32
11 : i32
2 : i32
30 : i32
21 : i32
12 : i32
3 : i32
31 : i32
22 : i32
32 : i32
-4 : i32
0 : i32
1 : i32
10 : i32
2 : i32
20 : i32
11 : i32
3 : i32
30 : i32
21 : i32
12 : i32
31 : i32
22 : i32
32 : i32
-5 : i32
0 : i32
10 : i32
1 : i32
11 : i32
20 : i32
2 : i32
12 : i32
21 : i32
30 : i32
3 : i32
22 : i32
31 : i32
32 : i32
-6 : i32
```

### Actors

TODO

### Async/await

TODO

### Delimited continuations

(The full code for this example is [here](examples/control-lwt.wast).)

Conventional unstructured delimited continuations can be directly
implemented using our typed continuations design. Here we illustrate
how to implement lightweight threads on top of the control/prompt
delimited control operators.

First we implement control/prompt.

```wast
;; interface to control/prompt
(module $control
  (type $func (func))       ;; [] -> []
  (type $cont (cont $func)) ;; cont ([] -> [])

  ;; we sometimes write contref as shorthand for a reference to a continuation

  (type $cont-func (func (param (ref $cont)))) ;; [contref ([] -> [])] -> []
  (type $cont-cont (cont $cont-func))          ;; cont ([contref ([] -> [])] -> [])

  ;; Implementation of a generic delimited control operator using
  ;; effect handlers.
  ;;
  ;; For lightweight threads we have no payload. More general types
  ;; for control and prompt are:
  ;;
  ;;   control : [([contref ([ta*] -> [tr*])] -> [tr*])] -> [ta*]
  ;;   prompt : [contref ([] -> [tr*])] -> [tr*]
  ;;
  ;; (We can also give more refined types if we want to support
  ;; answer-type modification and various flavours of answer-type
  ;; polymorphism - but these are well outside the scope of a Wasm
  ;; proposal!)
  ;;
  ;; (Technically this is control0/prompt0 rather than
  ;; control/prompt.)
  (tag $control (export "control") (param (ref $cont-func)))    ;; control : [([contref ([] -> [])] -> [])] -> []
  (func $prompt (export "prompt") (param $nextk (ref null $cont)) ;; prompt : [(contref ([] -> []))] -> []
    (block $on_control (result (ref $cont-func) (ref $cont))
       (resume $cont (tag $control $on_control)
                     (local.get $nextk))
       (return)
    ) ;;   $on_control (param (ref $cont-func) (ref $cont))
    (let (local $h (ref $cont-func)) (local $k (ref $cont))
      (call_ref (local.get $k) (local.get $h))
    )
  )
)
(register "control")
```

The `$control` tag amounts to a universal control tag, which takes a
second-order function `$h` as an argument (it's second-order in that
it's a function that itself takes a function, wrapped in a
continuation, as an argument). The implementation of prompt is the
universal handler for `$control`, which simply applies the second
order function `$h` to the captured continuation.

In the above code we have specialised `$control` and `$prompt` to the
case where the continuation has no parameters and no results, as this
suffices for implementing lightweight threads. A continuation
parameter corresponds to the result of a control tag, so in the
absence of parametric polymorphism, in order to simulate standard
control tags in general we would need one copy of `$control` for each
type of result we wanted to support.

The following example is just like the one we implemented for dynamic
lightweight threads using `$yield` and `$fork` tags decoupled from
handlers for defining different schedulers. Here instead we
parameterise the whole example by the behaviour of yielding and
forking as `$yield` and `$fork` functions.

```wast
(module $example
  (type $func (func))       ;; [] -> []
  (type $cont (cont $func)) ;; cont ([] -> [])

  (type $cont-func (func (param (ref $cont)))) ;; [cont ([] -> [])] -> []
  (type $cont-cont (cont $cont-func))          ;; cont ([cont ([] -> [])] -> [])

  (type $func-cont-func-func (func (param (ref $func)) (param (ref $cont-func)))) ;; ([] -> []) -> ([contref ([] -> [])] -> []) -> []
  (type $func-cont-func-cont (cont $func-cont-func-func))                         ;; cont (([] -> []) -> ([contref ([] -> [])] -> []) -> [])

  (func $log (import "spectest" "print_i32") (param i32))

  (elem declare func $main $thread1 $thread2 $thread3)

  (func $main (export "main") (param $yield (ref $func)) (param $fork (ref $cont-func))
    (call $log (i32.const 0))
    (call_ref
      (cont.bind $func-cont-func-cont $cont (local.get $yield) (local.get $fork)
        (cont.new $func-cont-func-cont (ref.func $thread1)))
      (local.get $fork))
    (call $log (i32.const 1))
    (call_ref
      (cont.bind $func-cont-func-cont $cont (local.get $yield) (local.get $fork)
        (cont.new $func-cont-func-cont (ref.func $thread2)))
      (local.get $fork))
    (call $log (i32.const 2))
    (call_ref
      (cont.bind $func-cont-func-cont $cont (local.get $yield) (local.get $fork)
        (cont.new $func-cont-func-cont (ref.func $thread3)))
      (local.get $fork))
    (call $log (i32.const 3))
  )

  (func $thread1 (param $yield (ref $func)) (param $fork (ref $cont-func))
    (call $log (i32.const 10))
    (call_ref (local.get $yield))
    (call $log (i32.const 11))
    (call_ref (local.get $yield))
    (call $log (i32.const 12))
  )

  (func $thread2 (param $yield (ref $func)) (param $fork (ref $cont-func))
    (call $log (i32.const 20))
    (call_ref (local.get $yield))
    (call $log (i32.const 21))
    (call_ref (local.get $yield))
    (call $log (i32.const 22))
  )

  (func $thread3 (param $yield (ref $func)) (param $fork (ref $cont-func))
    (call $log (i32.const 30))
    (call_ref (local.get $yield))
    (call $log (i32.const 31))
    (call_ref (local.get $yield))
    (call $log (i32.const 32))
  )
)
(register "example")
```

The function type `$func-cont-func-fun` is the type of a function that
takes an implementation of a `$yield` function and the implementation
as a `$fork` function as pararameters; the continuation type
`$func-cont-func-cont` is the same thing as a continuation.

We now define a scheduler module analogous to that of the previous
dynamic lightweight thread example. As before, we will implement five
different schedulers.

```wast
(module
  (type $func (func))       ;; [] -> []
  (type $cont (cont $func)) ;; cont ([] -> [])

  (type $cont-func (func (param (ref $cont)))) ;; [contref ([] -> [])] -> []
  (type $cont-cont (cont $cont-func))          ;; [(contref ([contref ([] -> [])]))] -> []

  (type $func-cont-func-func (func (param (ref $func)) (param (ref $cont-func)))) ;; ([] -> []) -> ([cont ([] -> [])] -> []) -> []
  (type $func-cont-func-cont (cont $func-cont-func-func))                         ;; cont (([] -> []) -> ([cont ([] -> [])] -> []) -> [])

  (elem declare func
     $handle-yield-sync $handle-yield
     $handle-fork-sync $handle-fork-kt $handle-fork-tk $handle-fork-ykt $handle-fork-ytk
     $yield
     $fork-sync $fork-kt $fork-tk $fork-ykt $fork-ytk)

  ;; control/prompt interface
  (tag $control (import "control" "control") (param (ref $cont-func)))     ;; control : ([cont ([] -> [])] -> []) -> []
  (func $prompt (import "control" "prompt") (param $nextk (ref null $cont))) ;; prompt : cont ([] -> []) -> []

  ;; queue interface
  (func $queue-empty (import "queue" "queue-empty") (result i32))
  (func $dequeue (import "queue" "dequeue") (result (ref null $cont)))
  (func $enqueue (import "queue" "enqueue") (param $k (ref $cont)))
  ...
(register "scheduler")
```

Unlike before, with control/prompt a generic scheduler loop must be
decoupled from the implementations of each operation (yield / fork) as
the latter are passed in as arguments to user code

```wast
  ;; generic boilerplate scheduler
  (func $scheduler (param $nextk (ref null $cont))
    (loop $loop
      (if (ref.is_null (local.get $nextk)) (then (return)))
      (call $prompt (local.get $nextk))
      (local.set $nextk (call $dequeue))
      (br $loop)
    )
  )
```

The scheduler loop simply keeps on calling prompt with the next thread
in the queue until the queue of threads is exhausted.

For each scheduler, we invoke the generic scheduler using a
continuation parameterised by suitable implementations of yield and
fork.

First, we do the baseline synchronous scheduler.

```wast
  ;; synchronous scheduler
  (func $handle-yield-sync (param $k (ref $cont))
    (call $scheduler (local.get $k))
  )
  (func $yield-sync
    (suspend $control (ref.func $handle-yield))
  )
  (func $handle-fork-sync (param $t (ref $cont)) (param $k (ref $cont))
    (call $enqueue (local.get $t))
    (call $scheduler (local.get $k))
  )
  (func $fork-sync (param $t (ref $cont))
    (suspend $control (func.bind (type $cont-func) (local.get $t) (ref.func $handle-fork-sync)))
  )
  (func $sync (export "sync") (param $k (ref $func-cont-func-cont))
    (call $scheduler
      (cont.bind $func-cont-func-cont $cont (ref.func $yield) (ref.func $fork-sync) (local.get $k)))
  )
```

The `func.bind` instruction is needed in the implementations of fork
More generally `func.bind` is needed for any operation that takes
arguments. One could use another continuation here instead, but
constructing a new continuation every time an operation is invoked
seems unnecessarily wasteful.

All of the asynchronous schedulers make use of the same implementation
of yield, which enqueues the continuation of the current thread and
dequeues the next available thread.

```wast
  ;; asynchronous yield (used by all asynchronous schedulers)
  (func $handle-yield (param $k (ref $cont))
    (call $enqueue (local.get $k))
    (call $scheduler (call $dequeue))
  )
  (func $yield
    (suspend $control (ref.func $handle-yield))
  )
```

Each asynchronous scheduler uses its own implementation of fork.

```wast
  ;; four asynchronous implementations of fork:
  ;;   * kt and tk don't yield on encountering a fork
  ;;     1) kt runs the continuation, queuing up the new thread for later
  ;;     2) tk runs the new thread first, queuing up the continuation for later
  ;;   * ykt and ytk do yield on encountering a fork
  ;;     3) ykt runs the continuation, queuing up the new thread for later
  ;;     4) ytk runs the new thread first, queuing up the continuation for later

  ;; no yield on fork, continuation first
  (func $handle-fork-kt (param $t (ref $cont)) (param $k (ref $cont))
    (call $enqueue (local.get $t))
    (call $scheduler (local.get $k))
  )
  (func $fork-kt (param $t (ref $cont))
    (suspend $control (func.bind (type $cont-func) (local.get $t) (ref.func $handle-fork-kt)))
  )
  (func $kt (export "kt") (param $k (ref $func-cont-func-cont))
    (call $scheduler
      (cont.bind $func-cont-func-cont $cont (ref.func $yield) (ref.func $fork-kt) (local.get $k)))
  )

  ;; no yield on fork, new thread first
  (func $handle-fork-tk (param $t (ref $cont)) (param $k (ref $cont))
    (call $enqueue (local.get $k))
    (call $scheduler (local.get $t))
  )
  (func $fork-tk (param $t (ref $cont))
    (suspend $control (func.bind (type $cont-func) (local.get $t) (ref.func $handle-fork-tk)))
  )
  (func $tk (export "tk") (param $k (ref $func-cont-func-cont))
    (call $scheduler
      (cont.bind $func-cont-func-cont $cont (ref.func $yield) (ref.func $fork-tk) (local.get $k)))
  )

  ;; yield on fork, continuation first
  (func $handle-fork-ykt (param $t (ref $cont)) (param $k (ref $cont))
    (call $enqueue (local.get $k))
    (call $enqueue (local.get $t))
    (call $scheduler (call $dequeue))
  )
  (func $fork-ykt (param $t (ref $cont))
    (suspend $control (func.bind (type $cont-func) (local.get $t) (ref.func $handle-fork-ykt)))
  )
  (func $ykt (export "ykt") (param $k (ref $func-cont-func-cont))
    (call $scheduler
      (cont.bind $func-cont-func-cont $cont (ref.func $yield) (ref.func $fork-ykt) (local.get $k)))
  )

  ;; yield on fork, new thread first
  (func $handle-fork-ytk (param $t (ref $cont)) (param $k (ref $cont))
    (call $enqueue (local.get $t))
    (call $enqueue (local.get $k))
    (call $scheduler (call $dequeue))
  )
  (func $fork-ytk (param $t (ref $cont))
    (suspend $control (func.bind (type $cont-func) (local.get $t) (ref.func $handle-fork-ytk)))
  )
  (func $ytk (export "ytk") (param $k (ref $func-cont-func-cont))
    (call $scheduler
      (cont.bind $func-cont-func-cont $cont (ref.func $yield) (ref.func $fork-ytk) (local.get $k)))
  )
)
(register "scheduler")
```

Invoking the schedulers is much like in our original dynamic
lightweight threads example, but the types are more complex due to the
need to index the handled computation (`$main` in this case) by the
implementations of forking and yielding.

```wast
(module
  (type $func (func))       ;; [] -> []
  (type $cont (cont $func)) ;; cont ([] -> [])

  (type $cont-func (func (param (ref $cont)))) ;; [contref ([] -> [])] -> []
  (type $cont-cont (cont $cont-func))          ;; cont ([contref ([] -> [])] -> [])

  (type $func-cont-func-func (func (param (ref $func)) (param (ref $cont-func)))) ;; ([] -> []) -> ([contref ([] -> [])] -> []) -> []
  (type $func-cont-func-cont (cont $func-cont-func-func))                         ;; contref (([] -> []) -> ([contref ([] -> [])] -> []) -> [])

  (func $scheduler-sync (import "scheduler" "sync") (param $nextk (ref $func-cont-func-cont)))
  (func $scheduler-kt (import "scheduler" "kt") (param $nextk (ref $func-cont-func-cont)))
  (func $scheduler-tk (import "scheduler" "tk") (param $nextk (ref $func-cont-func-cont)))
  (func $scheduler-ykt (import "scheduler" "ykt") (param $nextk (ref $func-cont-func-cont)))
  (func $scheduler-ytk (import "scheduler" "ytk") (param $nextk (ref $func-cont-func-cont)))

  (func $log (import "spectest" "print_i32") (param i32))

  (func $main (import "example" "main") (param $yield (ref $func)) (param $fork (ref $cont-func)))

  (elem declare func $main)

  (func $run (export "run")
    (call $log (i32.const -1))
    (call $scheduler-sync (cont.new $func-cont-func-cont (ref.func $main)))
    (call $log (i32.const -2))
    (call $scheduler-kt (cont.new $func-cont-func-cont (ref.func $main)))
    (call $log (i32.const -3))
    (call $scheduler-tk (cont.new $func-cont-func-cont (ref.func $main)))
    (call $log (i32.const -4))
    (call $scheduler-ykt (cont.new $func-cont-func-cont (ref.func $main)))
    (call $log (i32.const -5))
    (call $scheduler-ytk (cont.new $func-cont-func-cont (ref.func $main)))
    (call $log (i32.const -6))
  )
)
```

The output of running this code is just as in the direct
implementation of dynamic lightweight threads.

## Implementation strategies

### Segmented stacks

TODO

<!--
Segmented stacks is an implementation technique for
continuations (cite: Dybvig et al., Chez Scheme, Multicore OCaml). The
principal idea underpinning segmented stacks is to view each
continuation as representing a separate stack.

Initially there is one stack, which may create other stacks. Each
child stack may create further stacks. Lineage of stacks is maintained
by linking children to their parent.

```ioke
      (stack 1)
       (active)
 |-----------------------|
 |                       |
 | ...                   |
 |                       |
 | (resume $h1 $c); |
>| $c = (cont.new $f)    |
 |                       |
 .                       .
 .                       .

```

The first stack may perform some computation, before the stack pointer
`>` moves to the `cont.new` instruction. Execution of the `cont.new`
instruction creates a new suspended stack for the computation implied
by `$f`.


```ioke
      (stack 1)                         (stack 2)
       (active)
 |---------------------|
 |                     |
 | ...                 |
 |                     |                 (suspended)
 |                     |           |---------------------|
>| resume $h1 $c -------------| $f()                |
 .                     .           .                     .
 .                     .           .                     .
                                   .                     .

```

Stack 1 maintains control after the creation of stack 2, and thus
execution continues on stack 1. The next instruction, `resume`
suspends stack 1 and transfers control to new stack 2. Before
transferring control, the instruction installs a delimiter `$h1` on
stack 1. The transfer of control reverses the parent-child link, such
that stack 2 now points back to stack 1. The instruction also installs
a delimiter on the parent

```ioke
      (stack 1)                         (stack 2)
       (active)
 |---------------------|
 |                     |
 | ...                 |
 |                     |                 (suspended)
 |                     |       ----|---------------------|
>| $h1                 |<-----/    | $f()                |
 .                     .           |                     |
 .                     .           .                     .
 .                     .           .                     .
                                   .                     .
```

The stack pointer moves to the top of stack 2, and thus execution
continues on stack 2.


```ioke
      (stack 1)                         (stack 2)
       (suspended)
 |---------------------|
 |                     |
 | ...                 |
 |                     |                 (active)
 |                     |       ----|---------------------|
 | $h1                 |<-----/   >| $f()                |
 .                     .           |                     |
 .                     .           .                     .
 .                     .           .                     .
                                   .                     .
```

As execution continues on stack 2 it may eventually perform a
`suspend`, which will cause another transfer of
control. Supposing it invokes `suspend` with some `$e` handled
by `$h1`, then stack 2 will transfer control back to stack 1.


```ioke
      (stack 1)                         (stack 2)
       (suspended)
 |---------------------|
 |                     |
 | ...                 |
 |                     |                 (active)
 |                     |       ----|---------------------|
 | $h1                 |<-----/    | ...                 |
 .                     .          >| suspend $e     |
 .                     .           .                     .
 .                     .           .                     .
                                   .                     .
```

The suspension reverses the parent-child link again, and leaves behind
a "hole" on stack 2, that can be filled by an invocation of
`resume`.

```ioke
      (stack 1)                         (stack 2)
       (suspended)
 |---------------------|
 |                     |
 | ...                 |
 |                     |                 (active)
 |                     |       ----|---------------------|
>| $h1                 |------/    | ...                 |
 .                     .           | [ ]                 |
 .                     .           .                     .
 .                     .           .                     .
                                   .                     .
```

-->


### Continuation-passing style

TODO

### Virtual memory

TODO

### Stack cut'n'paste

TODO

### OS threads

TODO

## Design considerations and extensions

### Memory management

The current proposal does not require a general garbage collector as
the linearity of continuations guarantees that there are no cycles in
continuation objects. In theory, we could dispense with automated
memory management altogether if we took seriously the idea that
failure to use a continuation constitutes a bug in the producer. In
practice, for most producers enforcing such a discipline is
unrealistic and not something an engine can rely on anyway. To prevent
space leaks, most engines will need some form of automated memory
meanagement for unconsumed continuations. Due to the acyclicity of
continuations, a reference counting scheme is sufficient.

### Linear versus constant time dispatch

The `suspend` instruction relies on traversing a stack of
handlers in order to find the appropriate handler, similarly to
exception handling. A potential problem is that this can incur a
linear runtime cost, especially if we think in terms of segmented
stacks, where `suspend` must search the active stack chain for a
suitable handler for its argument. Practical experience from Multicore
OCaml suggests that for critical use cases (async/await, lightweight
threads, actors, etc.) the depth of the handler stack tends to be
small so the cost of this linear traversal is negligible. Nonetheless,
future applications may benefit from constant-time dispatch. To enable
constant-time dispatch we would need to know the target stack a
priori, which might be acheived either by maintaining a shadow stack
or by extending `suspend` to explicitly target a named handler.

### Named handlers

We can accommodate named handlers by introducing a new reference type
`handler t*`, which essentially is a unique prompt created by
executing a variant of the `resume` instruction and is passed to the
continuation:

```wast
  resume_with $ht $ct (tag $e $l)* : [ t1* (ref $ht) (ref $ct) ] -> [ t2* ]
  where:
  - $ht = handler t2*
  - $ct = cont ([ (ref $ht) t1* ] -> [ t2* ])
```

The handler reference is similar to a prompt in a system of
multi-prompt continuations. However, since it is created fresh for
each handler, multiple activations of the same prompt cannot exist by
construction.

This instruction is complemented by an instruction for suspending to a
specific handler:

```wast
  suspend_to $ht $e : [ s* (ref $ht) ] -> [ t* ]
  where:
  - $ht = handler tr*
  - $e : [ s* ] -> [ t* ]
```

If the handler is not currently active, e.g., because an outer handler
has been suspended, then this instruction would trap.

### Direct switching

The current proposal uses the asymmetric suspend/resume pair of
primitives that is characteristic of effect handlers. It does not
include a symmetric way of switching to another continuation directly,
without going through a handler, and it is conceivable that the double
hop through a handler might involve unnecessary overhead for use cases
like lightweight threading.

Though there is currently no evidence that the double hop overhead is
significant in practice, if it does turn out to be important for some
applications then the current proposal can be extended with a more
symmetric `switch_to` primitive.

Given named handlers, it is possible to introduce a somewhat magic
instruction for switching directly to another continuation:

```wast
  switch_to : [ t1* (ref $ct1) (ref $ht) ] -> [ t2* ]
  where:
  - $ht = handler t3*
  - $ct1 = cont ([ (ref $ht) (ref $ct2$) t1* ] -> [ t3* ])
  - $ct2 = cont ([ t2* ] -> [ t3* ])
```

This behaves as if there was a built-in tag

```wast
  (tag $Switch (param t1* (ref $ct1)) (result t3*))
```

with which the computation suspends to the handler, and the handler
implicitly handles this by resuming to the continuation argument,
thereby effectively switching to it in one step. Like `suspend_to`,
this would trap if the handler was not currently active.

The fact that the handler implicitly resumes, passing itself as a
handler to the target continuation, makes this construct behave like a
deep handler, which is slightly at odds with the rest of the proposal.

In addition to the handler, `switch_to` also passes the new
continuation to the target, which allows the target to switch back to
it in a symmetric fashion. Notably, in such a use case, `$ct1` and
`$ct2` would be the same type (and hence recursive).

In fact, symmetric switching need not necessarily be tied to named
handlers, since there could also be an indirect version with dynamic
handler lookup:

```wast
  switch : [ t1* (ref $ct1) ] -> [ t2* ]
  where:
  - $ct1 = cont ([ (ref $ct2) t1* ] -> [ t3* ])
  - $ct2 = cont ([ t2* ] -> [ t3* ])
```

It seems undesirable that every handler implicitly handles the
built-in `$Switch` tag, so this should be opt-in by a mode flag on the
resume instruction(s).

### Control/prompt as an alternative basis

An alternative to our typed continuations proposal is to use more
established delimited control operators such as control/prompt and
shift/reset. As illustrated in the examples section, control/prompt
can be viewed as a special instance of the current proposal with a
single universal control tag `control` and a handler for each
`prompt`.

As `control` amounts to a universal control tag it correspondingly has
a higher-order type. As illustrated by the example, this requires more
complicated types than with the current proposal and depends on
greater use of function closures.

When considered as a source language feature effect handlers are
preferable to control/prompt because they are more modular and easier
to reason about. Effect handlers naturally provide a separation of
concerns. Users program to an effect interface, whereas `control`
allows (and indeed requires) them to essentially rewrite the
implementation inline (in practice this is unmanageable, so one
abstracts over a few key behaviours using functions as illustrated in
the example). Of course, intermediate languages have different
requirements to source languages, so modularity and ease of reasoning
may be less critical. Nonetheless, they should not be discounted
entirely.

### Coupling of continuation capture and dispatch

A possible concern with the current design is that it relies on a
specific form of dispatch based on tags. Suspending not only captures
the current continuation up to the nearest prompt, but also dispatches
to the handler clause associated with the given tag. It might be
tempting to try to decouple continuation capture from dispatch, but it
is unclear what other form of dispatch would be useful or whether
there is a clean way to enable such decoupling.

With control/prompt there is no coupling of continuation capture with
dispatch, because there is no dispatch. But this is precisely because
`control` behaves as a universal tag, which requires behaviour to be
given inline via a closure, breaking modularity and necessitating a
higher-order type even for simple uses of continuations like
lightweight threads.

This is not to say that control/prompt or a generalisation to
multiprompt delimited continuations is necessarily a bad low-level
implementation technique. For instance, the
[libmprompt](https://github.com/koka-lang/libmprompt) C library
implements effect handlers on top of multiprompt delimited
continuations. However, a key difference there is that the C
implementation does not require static stack typing, something that is
fundamental to the design of Wasm. Thus, the implementation does not
need to contend directly with the higher-order type of `control`.

### Tail-resumptive handlers

A handler is said to be *tail-resumptive* if the handler invokes the
continuation in tail-position in every control tag clause. The
canonical example of a tail-resumptive handler is dynamic binding
(which can be useful to implement implicit parameters to
computations). The control tag clauses of a tail-resumptive handler
can be inlined at the control tag invocation sites, because they do
not perform any non-trivial control flow manipulation, they simply
retrieve a value. Inlining clause definitions means that no time is
spent constructing continuation objects.

The present iteration of this proposal does not include facilities for
identifying and inlining tail-resumptive handlers. None of the
critical use-cases requires such a facility. Nevertheless, it is
natural to envisage a future iteration of this proposal that includes
an extension for distinguishing tail-resumptive handlers.

### Multi-shot continuations

Continuations in this proposal are *single-shot* (aka *linear*),
meaning that they must be invoked exactly once (though this is not
statically enforced). A continuation can be invoked either by resuming
it (with `resume`) or by aborting it (with `resume_throw`). Some
applications such as backtracking, probabilistic programming, and
process duplication exploit *multi-shot* continuations, but none of
the critical use cases require multi-shot continuations. Nevertheless,
it is natural to envisage a future iteration of this proposal that
includes support for multi-shot continuations by way of a continuation
clone instruction.

### Interoperability, legacy code, and the barrier instruction

The barrier instruction provides a direct way of preventing control
tags from being suspended outside a particular computation.

Consider a module A written using an existing C/C++ compiler that
targets a Wasm backend. Let us assume that module A depends on a
second Wasm module B. Now suppose that the producer for module B is
updated to take advantage of typed continuations. In order to ensure
that suspensions arising in calls to B do not pass through A,
potentially causing unexpected changes to the semantics of A, the
producer for module A can ensure that all external calls are wrapped
in the barrier instruction.

It might seem preferable to somehow guarantee that support for typed
continuations is not enabled by default, meaning that no changes to
the producer for module A would be necessary. But it is unclear what
such an approach would look like in practice and whether it would
actually be feasible. In any case, using the barrier instruction the
producer for B could make module B safe for linking with an unchanged
module A by wrapping the barrier instruction around all of the
functions exported by module B.

Questions of Wasm interoperability and support for legacy code are
largely orthogonal to the typed continuations proposal and similar
issues already arise with extensions such as exceptions.

### First-class tags

In the current proposal tags are statically defined in a module
header. This should suffice for supporting the critical
use-cases. However, for some purposes, such as implementing richer
forms of control operators such as effect handlers, it might be useful
to add support for dynamically generated tags. These could be used,
for instance, for more efficiently compiling effect handlers that take
advantage of features such as Multicore OCaml's functors, where the
type of an effect (tag) may not be fully known at compile time.

### Shallow versus deep handlers

The effect handlers feature which underlies the design of the typed
continuations proposal classically comes in too forms: shallow and
deep handlers. With shallow handlers, the installation of handlers is
completely decoupled from resuming a continuation. With deep handlers,
the handler that produced the continuation is automatically
reinstalled when a continuation is resumed. The typed continuations
proposal adopts a hybrid of shallow and deep handlers, which we call
*sheep handlers*. Like a shallow handler, there is no automatic
reinstallation of an existing handler. But like deep handlers a new
handler is installed when a continuation is resumed: the new handler
is written explicitly as part of the `resume` instruction.


TODO: resuspend (aka OCaml's reperform, and analogous to exception proposal's rethrow)

TODO: return clauses

TODO: preemption / asynchrony / interrupts

TODO: how do we interact with parametric polymorphism?

TODO: lexically-scoped handlers

TODO: parametric tags / existential types?

TODO: tag subtyping?

TODO: compare to asyncify?

TODO: compare to Wasm/k?

TOOD: compare to the Koka Wasm backend?
