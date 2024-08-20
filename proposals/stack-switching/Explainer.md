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
1. [Introduction to continuation-based stack switching](#introduction-to-continuation-based-stack-switching)
   1. [Generators](#generators)
   1. [Task scheduling](#task-scheduling)
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
continuation. Direct switching establishes a peer-to-peer relationship
between the current continuation and its peer. In this respect the
design provides a form of *symmetric coroutines*.

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


## Introduction to continuation-based stack switching

We informally demonstrate the proposed stack switching mechanisms using two
examples. They showcase how generators and a task scheduler can be implemented
using our proposal. For the sake of exposition, both examples are kept minimal,
but could be extended to real world programs. The two examples demonstrate
asymmetric and symmetric stack switching, respectively.


### Generators

This example shows a generator-consumer pattern, implemented by switching
between the stack running the consumer and the one running the generator.

We implement this in a module with the folllowing toplevel definitions.

```wat
(module $generator
  (type $ft (func))
  ;; Types of continuations used by the generator:
  ;; No need for param or result types: No data data passed back to the
  ;; generator when resuming it, and $generator function has no return
  ;; values.
  (type $ct (cont $ft))

  ;; Tag used to coordinate between generator and consumer: The i32 param
  ;; corresponds to the generated values passed; no values passed back from
  ;; generator to consumer.
  (tag $yield (param i32))


  (func $print (import "spectest" "print_i32") (param i32))

  ;; Simple generator yielding values from 100 down to 1
  (func $generator ...)
  (elem declare func $generator)

  (func $consumer ...)

)
```

Intuitively, the `$consumer` function creates a new continuation that executes
the function `$generator`. The latter executes a loop counting from 100 down
to 0. In each iteration, the `$generator` function suspends execution,
transferring control back to the `$consumer` function, passing along the next
generated value at the same time.
Execution then continues in `$consumer`, which receives the generated value,
as well as a continuation that allows continuing execution of `$generator` at
its `suspend` instruction.

The interface between generator and consumer is defined in two parts:
- The *continuation type* `$ct` defined from the function type `$ft`. It allows
  passing continuations corresponding to suspended executions of `$generator` as
  first-class values of type `(ref $ct)`, similar to function references.
- Defining the tag `$yield` allows us to use it as a delimiter for
  continuations. This means that when suspending execution in `$generator` using
  tag `$yield`, the latter is used at runtime to identify where to continue
  execution afterwards. In our example, this will be inside the function
  `$consumer`.

 
 The function `$generator` is defined as follows.
 
 ```wat
(func $consumer
  (local $c (ref $ct))
  ;; Create continuation executing function $generator.
  ;; Execution only starts when resumed for the first time.
  (local.set $c (cont.new $ct (ref.func $generator)))

  (loop $loop
    (block $on_yield (result i32 (ref $ct))
      ;; Resume continuation $c
      (resume $ct (on $yield $on_yield) (local.get $c))
      ;; $generator returned: no more data
      (return)
    )
    ;; Generator suspended, stack now contains [i32 (ref $ct)]
    ;; Save continuation to resume it in next iteration
    (local.set $c)
    ;; Stack now contains the i32 value yielded by $generator
    (call $print)

    (br $loop)
  )
)
 ```
 
The function `$consumer` uses `cont.new` to create a continuation executing
`$generator`. This creates a value of reference type `(ref $ct)`, saved in `$c`.


The function `$generator` then runs a loop, where a `resume` instruction is used
to continue execution of the continuation currently saved in `$c` in each
iteration.

In general, a `resume` instruction not only takes a continuation as argument,
but also additional values to be passed to the continuation to be resumed,
reflected in the parameters of continuation's type. In our example, `$ct` has no
parameters, indicating that no data is passed from `$consumer` to `$generator`.

Whenever a continuation is resumed, the stack where the `resume` instruction
executes (which may be another continuation, or the main stack) becomes the
*parent* of the resumed continuation, such as `$c` in our example. These
parent-child relationship reflect the asymmetric nature of this stack switching
proposal. They affect execution in two ways, which we discuss in the following.

Firstly, in our `resume` instruction, the *handler clause* `(on $yield
$on_yield)` installs a handler for that tag while executing the continuation.
This means that if during the execution of `$c`, the continuation suspends
itself using tag `$yield` (i.e., it executes the instruction `suspend $yield`),
this is handled by the block `$on_yield`. In general, executing an instruction
`suspend $t` for some tag `$t` means that execution continues at the innermost
ancestor whose `resume` instruction installed a handler for `$t`. This is
analogous to the search for a matching exception handler after raising an
exception.

In our example, this means that whenever `$generator` executes a `suspend
$yield` instruction, execution continues in the `$on_yield` block in
`$consumer`.
In that case, two values are found on the Wasm value stack:
The topmost value is a new continuation, representing the remaining execution of
`$generator` after the `suspend` instruction therein.
The other value is the `i32` value passed from the generator to the consumer:
The tag `$yield` was defined with `(param i32)`, meaning that such a value is
passed from the `suspend` site to the handler. In our example, `$consumer`
prints the generated value and saves the new continuation in `$c` for the next
iteration.

Secondly, parent-child relationships dictate where execution continues after the
toplevel function running inside a continuation, such as `$generator`, returns.
Control simply transfers to after the `resume` instruction in the immediate
parent, making the return values of the function inside the continuation the
return values of the matching `resume` instruction.
 
 
In our example, the toplevel continuation (i.e., `$generator`) simply returns
once the loop counter `$i` reaches 0. Thus, this causes execution to continue
after the `resume` instruction in `$generator`. The absence of results in the
continuation type `$ct` reflects that `$generator` has no return values and
`$consumer` returns, too.
 
The concrete definition of `$generator` is as follows.

```wat
;; Simple generator yielding values from 100 down to 1
(func $generator
  (local $i i32)
  (local.set $i (i32.const 100))
  (loop $l
    ;; Suspend execution, pass current value of $i to consumer
    (suspend $yield (local.get $i))
    ;; Decrement $i and exit loop once $i reaches 0
    (local.tee $i (i32.sub (local.get $i) (i32.const 1)))
    (br_if $l)
  )
)
```

As described earlier, the function executes 100 iterations of a loop and returns
afterwards. In each iteration, it suspends execution, passing along the current
loop counter `$i`.

The full definition of the module can be found [here](examples/generator.wast).

### Task scheduling


We now show how the following use case may be implemented efficiently using this
proposal: We may want to schedule a number of tasks, represented by functions
`$task_0` to `$task_n`, to be executed concurrently. Scheduling is cooperative,
meaning that tasks explicitly yield execution so that a scheduler may pick the
next task to run.

We may implement this using the asymmetric stack switching approach discussed
for generators: We could define a function `$scheduler` that `resume`s the
initial task, and installs a handler for a tag `$yield`. To yield execution,
tasks simply perform `(suspend $yield)`, transferring control back to
`$scheduler`, their parent. The latter then picks the next task (if any) from a
task queue and `resume`s it.
However, we observe that this asymmetric approach requires two stack switches in
order to change execution from one task to another: The first when suspending
from the yielding task to the scheduler, and a second when the scheduler resumes
the next task.


For patterns like the one described above, where a `suspend` in one continuation
would immediately be followed by the handler resuming another continuation `$c`,
this proposal provides a mechanism to switch from the original continuation
directly to `$c`. This is achieved using the `switch` instruction, which also
relies on tags.

Executing `switch $yield (local.get $c)` then behaves equivalently to
`(suspend $yield)`, assuming that the active (ordinary) handler for `$yield`
immediately resumes `$c` and additionally passes the continuation obtained from
handling `$yield` along as an argument to `$c`.

However, using a switch instruction in this situation means that only a single
stack switch occurs.

We illustrate this using the following skeleton code.


```wat
(module
  (rec
    (type $ft (func (param (ref null $ct))))
    ;; Continuation type  of all tasks:
    (type $ct (cont $ft))
  )

  ;; tag used to yield execution in one task and resume another one.
  (tag $yield)

  ;; Used by scheduler to manage task continuations
  (table $task_queue 1000 (ref null $ct))

  ;; Entry point, becomes parent of all tasks.
  ;; No actual scheduling here, besides resuming first task.
  (func $entry
    ...
    (resume $ct (on $yield switch)
      (ref.null $ct)
      (local.get $first_task)
    )
    ...
  )

  (func $task_0 (param (ref null $ct))

    ...
    ;; To yield execution, call scheduler
    (call $scheduler)
    ...

  )
  ...
  (func $task_n (param (ref null $ct)) ...)

  (func $scheduler
    ;; determine $next_task
    ...
    (block $done
      (br_if $done (ref.is_null (local.get $next_task)))
      ;; Switch to $next_task.
      ;; The switch instruction passes a reference to the current
      ;; continuation as an argument to $next_task.
      (switch $ct $yield (local.get $next_task))
      ;; If we get here, some other continuation switched back to us, and we
      ;; receive that continuation as a value on the stack. Need to enqueue it
      ;; in the task list.
      ...
    )
    ;; Just return if no other task in queue, making the $scheduler call a noop.

  )
  
)
```


Here, the function `entry` resumes the first task to execute. It will act as the
parent of all task continuations. However, it does not install an ordinary
handler for the tag `yield`. Instead, the resume instruction installs a *switch
handler* for tag `yield`.

FE: We need to come up with names for the two types of handlers.
"suspend handler" vs "switch handler". Or not call the latter "handlers" at all?

The function `$entry` does not perform any scheduling
besides resuming the initial task. Instead, if a task wants to yield execution,
it simply calls a separate `$scheduler` function. Therein, the scheduling logic
picks the next task `$next_task` and switches to it.
Here, the target continuation (i.e.,`$next_task`) receives the current
continuation as an argument, similar to how values were passed in the
generator example.

As a minor complication, we need to encode the fact that the continuation
switched to receives the current one as an argument in the type of
the continuations handled by the scheduler.
Thus, the type `$ct` is recursive: A continuation of that type takes a nullable
reference to a continuation of the same type as an argument.
In order to give the same type to continuations that have yielded execution
(i.e., created by `switch`) and those continuations that correspond to beginning
the execution of a `$task_i` function (i.e., those created by `cont.new`), we
add a `(ref null $ct)` parameter to all of the `$task_i` functions.

Our proposal also allows passing additional payloads when `switch`-ing from one
continuation to another, besides the continuation switched away from. We eschew
this in our example, which is reflected by the type `$ct` having no further
parameters besides the continuation argument required by `switch`.

Note that installing a switch handler for `$yield` in `entry` is strictly
necessary: It acts as a delimiter, determining the shape of the continuation
created when a `switch` using `yield` is performed.
The resulting stack switching is indeed symmetric: Rather than switching back to
the parent (as `suspend` would), `switch` effectively replaces the continuation
under the `yield` handler in `$entry` with a different continuation.


<!--- ## Examples

In this section we give a series of examples illustrating possible encodings of common non-local control flow idioms.

### Yield-style generators

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

TODO -->

## Instruction set extension

Here we give an informal account of the proposed instruction set
extension. In the [specification changes](#specification-changes) we
give a more formal account of the validation rules and changes to the
binary format.

For simplicity we ignore subtyping in this section, but in the
[specification changes](#specification-changes) we take full account
of subtyping.

The proposal adds a new reference type for continuations.

```wast
  (cont $ft)
```

A continuation type is specified in terms of a function type `$ft`,
whose parameter types `t1*` describe the expected stack shape prior to
resuming/starting the continuation, and whose return types `t2*`
describe the stack shape after the continuation has run to completion.

As a shorthand, we will often write the function type inline and write
a continuation type as

```wast
  (cont [t1*] -> [t2*])
```

### Declaring control tags

Control tags generalise exception tags to include result
types. Operationally, a control tag may be thought of as a *resumable*
exception. A tag declaration provides the type signature of a control
tag.

```wast
  (tag $t (param t1*) (result t2*))
```

The `$t` is the symbolic index of the control tag in the index space
of tags. The parameter types `t1*` describe the expected stack layout
prior to invoking the tag, and the result types `t2*` describe the
stack layout following an invocation of the operation.

We will often write `$t : [t1*] -> [t2*]` as shorthand for indicating
that such a declaration is in scope.

### Creating continuations

The following instruction creates a *suspended continuation* from a
function.

```wast
  cont.new $ct : [(ref $ft)] -> [(ref $ct)]
  where:
  - $ft = func [t1*] -> [t2*]
  - $ct = cont $ft
```

It takes a reference to a function of type `[t1*] -> [t2*]` whose body
may perform non-local control flow.

### Invoking continuations

There are three ways to invoke a suspended continuation.

The first way to invoke a continuation is to resume the suspended
continuation under a *handler*. The handler specifies what to do when
control is subsequently suspended again.

```wast
  resume $ct hdl* : [t1* (ref $ct)] -> [t2*]
  where:
  - $ct = cont [t1*] -> [t2*]
```

The `resume` instruction is parameterised by a continuation type and a
handler dispatch table `hdl`. The shape of `hdl` can be either:

1. `(on $e $l)` mapping the control tag `$e` to the label
`$l`. Intercepting `$e` causes a branch to `$l`.

2. `(on $e switch)` allowing a direct switch with control tag `$e`.

The `resume` instruction consumes its continuation argument, meaning
that a continuation may be resumed only once.


The second way to invoke a continuation is to raise an exception at
the control tag invocation site which causes the stack to be unwound.


```wast
  resume_throw $ct $exn hdl* : [te* (ref $ct)])] -> [t2*]
  where:
  - $ct = cont [t1*] -> [t2*]
  - $exn : [te*] -> []
```

The `resume_throw` instruction is parameterised by a continuation
type, the exception to be raised at the control tag invocation site,
and a handler dispatch table. As with `resume`, this instruction also
fully consumes its continuation argument. This instruction raises the
exception `$exn` with parameters of type `te*` at the control tag
invocation point in the context of the supplied continuation. As an
exception is being raised (the continuation is not actually being
supplied a value) the parameter types for the continuation `t1*` are
unconstrained.


The third way to invoke a continuation is to perform a symmetric
switch.

```wast
  switch $ct1 $e : [t1* (ref $ct1)] -> [t2*]
  where:
  - $e : [] -> [t*]
  - $ct1 = cont [t1* (ref $ct2)] -> [t*]
  - $ct2 = cont [t2*] -> [t*]
```

The `switch` instruction is parameterised by a continuation type
(`$ct1`) and a control tag (`$e`). It suspends the current
continuation (of type `$ct2`), then performs a direct switch to the
suspended peer continuation (of type `$ct1`), passing in the required
parameters (including the just suspended current continuation, in
order to allow the peer to switch back again). As with `resume` and
`resume_throw`, the `switch` instruction fully consumes its suspended
continuation argument.

### Suspending continuations

The current continuation can be suspended.

```wast
  suspend $e : [t1*] -> [t2*]
  where:
  - $e : [t1*] -> [t2*]
```

The `suspend` instruction invokes the control tag `$e` with arguments
of types `t1*`. It suspends the current continuation up to the nearest
enclosing handler for `$e`. This behaviour is similar to how raising
an exception transfers control to the nearest exception handler that
handles the exception. The key difference is that the continuation at
the suspension point expects to be resumed later with arguments of
types `t2*`.

### Partial application

A suspended continuation can be partially applied to a prefix of its
arguments yielding another suspended continuation.

```wast
  cont.bind $ct1 $ct2 : [t1* (ref $ct1)] -> [(ref $ct2)]
  where:
  - $ct1 = cont [t1* t3*] -> [t2*]
  - $ct2 = cont [t3*] -> [t2*]
```

The `cont.bind` instruction binds a prefix of its arguments of type
`t1*` to a suspended continuation of type `$ct1`, yielding a modified
suspended continuation of type `$ct2`. The `cont.bind` instruction
also consumes its continuation argument, and yields a new continuation
that can be supplied to `resume`,`resume_throw`, `switch` or
`cont.bind`.


SL: I think the following observation probably belongs in design
considerations rather than here

Partial application turns out to be important in practice due to the
block and type structure of Wasm as in order to return a continuation
from a block, all branches within the block must agree on the type of
continuation. By using `cont.bind`, one can programmatically ensure
that the branches within a block each return a continuation with
compatible type (the [Examples](#examples) section provides several
example usages of `cont.bind`).

### Continuation lifetime

#### Producing continuations

There are four different ways in which continuations may be produced
(`cont.new,suspend,cont.bind,switch`). A fresh continuation object
is allocated with `cont.new` and the current continuation is reused
with `suspend`, `cont.bind`, and `switch`.

The `cont.bind` instruction is similar to the `func.bind` instruction
that was initially part of the function references proposal. However,
whereas the latter necessitates the allocation of a new closure, as
continuations are single-shot no allocation is necessary: all
allocation happens when the original continuation is created by
preallocating one slot for each continuation argument.

#### Consuming continuations

There are four different ways in which suspended continuations are
consumed (`resume,resume_throw,switch,cont.bind`). A suspended
continuation may be resumed with a particular handler with `resume`;
aborted with `resume_throw`; directly switched to via `switch`; or
partially applied with `cont.bind`.

In order to ensure that continuations are one-shot, `resume`,
`resume_throw`, `switch`, and `cont.bind` destructively modify the
suspended continuation such that any subsequent use of the same
suspended continuation will result in a trap.

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

We use the use the opcode space `0xe0-0xe5` for the six new instructions.

| Opcode | Instruction              | Immediates |
| ------ | ------------------------ | ---------- |
| 0xe0   | `cont.new $ct`           | `$ct : u32` |
| 0xe1   | `cont.bind $ct $ct'`     | `$ct : u32`, `$ct' : u32` |
| 0xe2   | `suspend $t`             | `$t : u32` |
| 0xe3   | `resume $ct (on $t $h)*` | `$ct : u32`, `($t : u32 and $h : u32)*` |
| 0xe4   | `resume_throw $ct $e (on $t $h)` | `$ct : u32`, `$e : u32`, `($t : u32 and $h : u32)*` |
| 0xe5   | `switch $ct $e`          | `$ct : u32`, `$e : u32` |
