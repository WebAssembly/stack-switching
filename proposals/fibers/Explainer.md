# Fiber Oriented Stack Switching

## Motivation

Non-local control flow (sometimes called _stack switching_) operators allow applications to manage their own computations. Technically, this means that an application can partition its logic into separable computations and can manage (i.e., schedule) their execution. Pragmatically, this enables a range of control flows that include supporting the handling of asynchronous events, supporting cooperatively scheduled threads of execution, and supporting yield-style iterators and consumers.

This proposal refers solely to those features of the core WebAssembly virtual machine needed to support non-local control flow and does not attempt to preclude any particular strategy for implementing high level languages. We also aim for a reasonably minimal spanning set of concepts[^a]: the author of a high level language compiler should find all the necessary elements to enable their compiler to generate appropriate WebAssembly code fragments.

[^a]: _Minimality_ here means something slightly more than a strictly minimal set. In particular, if there is a feature that _could_ be implemented in terms of other features but that would incur significant penalties for many applications then we likely include it.

## Fibers and Events

The main concepts in this proposal are the _fiber_ and the _event_. A fiber is a first class value which denotes the resource used to support a computation. An event is used to signal a change in the flow of computation from one fiber to another.

### The `fiber` concept

A `fiber` is a resource that is used to enable a computation that has an extent in time and has identity. The latter allows applications to manage their own computations and support patterns such as async/await, green threads and yield-style generators.

Associated with fibers is a new heap type:

```
fiber t*
```

which denotes a fiber that returns types `t*`.


#### The state of a fiber

A fiber is inherently stateful; as the computation proceeds the fiber's state reflects that evolution.
The state of a fiber includes function call frames and local variables that are currently live within the computation as well as whether the fiber is currently being executed.
In keeping with the main design principles of WebAssembly, the frames and local variables represented within a fiber are not accessible other than by normal operations.

Fibers themselves are in one of three states: active, suspended, or moribund.
All Wasm execution occurs on an _active_ fiber and there can only be one active fiber at a time in a given Wasm execution context.
Other fibers are either _suspended_, which means they hold state and can become active in the future, or they are _moribund_, which means that all resources associated with the fiber have been released and attempts to make it the active fiber will trap.

#### Fiber relationships

It is convenient to identify some relationships between fibers: the _parent_ of a fiber is the fiber that first makes it active by switching into it[^b].
From there we can define _child_, _ancestor_, and _descendant_ in the usual ways.
Since each fiber explicitly switched into by the program has one parent (the fiber that first switched into it), these fibers form trees.
At the root of each of these trees is a _root fiber_ that is the _root ancestor_ of all the fibers in that tree (including itself).
A root fiber is implicitly created and made active by each call from the host to an exported function.

Note that during the life cycle of a Wasm instance there may be many calls from the host to exported functions, so there may be many root fibers.
Note also that fibers that have been created but never switched into do not have parents—we do not consider these fibers to have ancestors or root ancestors at all.

[^b]: The parent of a fiber is usually the other fiber that originally created it, but with `fiber.new` it is possible to create a fiber, then switch to a different fiber, and only then switch into the new fiber. In this case the parent of the new fiber is not the fiber that created it.

#### The resume stack

Although fibers can suspend themselves and switch to other fibers using mechanisms described below, control can also leave a fiber via a normal return from the fiber's top-level call frame or via an exception that propagates out of that top-level call frame.
When that happens, execution needs to continue on a different fiber[^c].
Normal and exceptional return mechanisms do not specify a target fiber to switch to, so in these cases Wasm semantics must prescribe a policy for choosing the fiber to switch to.

The chosen policy can be described in terms of the _resume stack_, which is a stack of fibers.

When a new root fiber is created by a host call to an export:

 - a new resume stack is created containing just that root fiber[^d].

When switching to a fiber _F_, the following occurs:

 - If _F_ has a root ancestor but that root ancestor is not the root fiber at the base of the resume stack, trap.

 - Otherwise, if _F_ is already in the resume stack, pop the stack until _F_ is at the top.

 - In all other cases push _F_ onto the resume stack.

When the active fiber returns normally or exceptionally:

 - Pop the active fiber off the top of the resume stack and mark it moribund.

 - If the resume stack is now empty, return (normally or exceptionally) to the host.

 - Otherwise make the new top fiber active and return (normally or exceptionally) to it.

The resume stack maintains several important invariants (with trivial proofs by induction on execution traces):

 1. The active fiber is always on top of the resume stack.
 2. The root fiber for the current computation is always at the base of the resume stack.
 3. No fiber appears more than once in the resume stack, so uncaught exceptions always reach the root.

[^c]: Alternatively, we could have fibers trap when their top-level function returns or propagates an exception, but then we would have to special-case root fibers to allow them to return or propagate exceptions to the host normally. This would also inhibit optimizations that allow fibers that return without ever suspending to be no more expensive than function calls, since the only nontrapping way to leave a fiber would be suspending.

[^d]: In practice, engines are expected to maintain just one resume stack, just as they maintain just one call stack for MVP Wasm, even though the spec treats each host call to an export as the beginning of a fresh computation with a fresh stack.

### Resumption events

Every time a fiber suspends itself and resumes another fiber, that transfer of control is a _resumption event_ with an associated tag that indicates the reason for the event.
It's possible for resumption events to carry values from the suspending fiber to the resuming fiber as well, and the event tag specifies the types of those values so the resuming fiber can receive them properly.

Event tag declarations are the same as for the tags in the [exception handling proposal](https://github.com/WebAssembly/exception-handling):

```
(tag $e (param t*))
```

where the parameter types are the types of values communicated by the event.
As in exception handling, tags may be exported and imported from and into modules.

## Instructions

We introduce instructions for creating, switching, and terminating fibers and instructions for receiving values while resuming.

### Switching Blocks

We manage the code that is responsible for handling resumption events in terms of _handler blocks_. A handler block is a block that defines a localized context for handling resumptions.
Within a handler block there are zero or more _event_ blocks, each of which contains code that is responsible for handling resumptions with a particular tag.

This block organization is reminiscent of how `try`..`catch` blocks are structured to enable exception handling; although there are significant differences.

#### `handle-event` blocks

A `handle` block introduces an execution scope where fibers may be suspended and subsequently resumed.
Within a `handle` block, any resumption event that arises must be handled by a subsidiary `event` block, otherwise the `handle` block will trap.

The overall format of a `handle` block is:

```
(handle $label $blocktype
  (do
    ...
    fiber.spawn ...
    ...
    fiber.suspend_to ...
    ...
  )
  (event $tag
   ...
  )
  (event $tag
   ...
  )
) ;; $label
```

Function bodies are implicit handle blocks with no event handlers.

`handle` blocks also have labels and types that work equivalently to labels and types on other control flow structures.
Like `catch` blocks in exception handling, `event` blocks take type types from their tags as input and must produce the same output types as their enclosing `handle` block.

When control reaches a `handle-event` block, it executes the `do` portion normally.
When control reaches the end of the `do` portion or when the label is branched to, control continues after the `handle-event` block.
`event` blocks are executed in response to resumptions with matching tags inside the `do` portion of the `handle-event` and are never otherwise executed.

`handle` blocks may be nested, in which case the available `event` blocks are the concatenation of all the `event` blocks in all the `handle` blocks that a given switching instruction is syntactically enclosed within[^f].

[^e]: Although this further restricts function decomposition, so maybe suspending instructions should take immediate lists (tag, branch label) pairs instead of using `handle-event` blocks.

[^f]: This seems weird. Revisit it.

### Fiber instructions

### `fiber.current` Get the current fiber

`fiber.current $F : [] -> [(ref $F)]`

 - where `$F = fiber t*`

The `fiber.current` instruction dynamically checks the type of the current active fiber.
If the type is `$F`, `fiber.current` returns a reference to the current fiber and otherwise it traps.
The type parameter and dynamic type check are necessary so that `fiber.current` can be assigned a concrete fiber type during validation.

#### `fiber.spawn` Create and switch to a new fiber

`fiber.spawn $f : [t*] -> [t'*]`

 - where `$f = func $sig`
 - and `$sig = [t*] -> [t'*]`

The `fiber.spawn` instruction creates a new fiber from the function given as the literal argument and immediately switches to it, updating the resume stack accordingly.

When the new fiber does not suspend, the `fiber.spawn` instruction is indistinguishable from a `call` instruction; the effect of the instruction is to leave on the value stack the return values of the fiber's function and to proceed with execution at the next instruction.
However, if the fiber that executed `fiber.spawn` is resumed before the new fiber returns, execution resumes in the corresponding `event` block of the enclosing `handle-event`, if any.
If there is no corresponding `event` block, the resumption traps.

#### `fiber.new` Create a new suspended fiber

`fiber.new $F $f : [t*] -> [(ref $F)]`

 - where `$F = fiber t'*`
 - and `$f = func $sig`
 - and `$sig = [t*] -> [t'*]`

TODO: either needs multi-entry functions or to take a list of (tag, function) pairs.

#### `fiber.suspend_to` Suspend the active fiber and switch to a new one

`fiber.suspend_to $F $tag : [t* (ref null $F)] -> [t'*]`

 - where `$F = fiber t'*`
 - and `$tag = tag (param t*)`

The `fiber.suspend_to` instruction takes an event tag as an immediate argument and event values and a target fiber as stack operands.

 - If the target fiber reference is null, trap.
 - If the target fiber is moribund, trap.
 - If the target fiber is already the current fiber, trap.
 - If the target fiber has a root ancestor but it is different from the current root ancestor, trap.
 - Otherwise, suspend the current fiber and switch control to the target fiber using the specified event and event operands. Update the resume stack accordingly.

If the target fiber returns normally and the fiber that executed `fiber.suspend_to` is the next active fiber as determined by the resume stack, it will resume execution with the instruction following `fiber.suspend_to`.
Otherwise, execution resumes in the corresponding `event` block of the enclosing `handle-event`, if any.
If there is no corresponding `event` block, the resumption traps.

#### `fiber.release` Destroy a suspended fiber

`fiber.release $F : [t* (ref null $F)] -> [t*]`

 - where `$F = fiber t*`

The `fiber.release` instruction clears any computation resources associated with the identified fiber.
To keep the resume stack in a consistent state if the target fiber is in the resume stack, this has to update the resume stack and transfer control as if a `fiber.resume_to` had been executed followed by a normal return of the given values from the target fiber.
Since the next active fiber may not be the current fiber, this instruction may suspend[^g]

 - If the target fiber reference is null, trap.
 - If the target fiber is the current fiber, trap.
 - If the target fiber has a root ancestor but it is different from the current root ancestor, trap.
 - If the target fiber is already moribund, do nothing but push the `t*` operands back to the stack.
 - Otherwise, update the resume stack as if switching to the target fiber, pop the target fiber off the resume stack, mark the target fiber as moribund, and return normally with the given `t*` values to the new active fiber.

This instruction is primarily a performance optimization over killing a thread cooperatively by switching to it using `fiber.resume_to` with a cancellation event and then having it return normally.
In particular, if the new active fiber after executing `fiber.release` is the same as the previous active fiber (i.e. if the target fiber was not in the resume stack), then the engine does not actually have to perform any context switches.

[^g]: This is exceptionally weird. Maybe we should trap instead if the target fiber is in the resume stack? This would prevent children from killing their parent and spoofing normal return values as well.

## Invariants and requirements

Beyond the invariants ensured by the design of the resume stack alone, the instructions in this proposal ensure additional invariants as well.

 1. Normal return from fibers is type safe.

     - Switching to a fiber either pops the previous active fiber off the resume stack or pushes the new fiber on top of the previous fiber in the resume stack.
       - In the first case the previous fiber's last suspending instruction will not return, so its return type doesn't matter.
       - In the second case, the suspending instruction expects to return the same types the new active fiber expects to return.
     - There is no other way for a different fiber to become the resume child of our suspended fiber without the suspended fiber being resumed first and suspending itself again.

 2. Host frames are never suspended.

     - All switching instructions trap if they would switch to a fiber with a different root ancestor than the current active fiber.
     - The root ancestor of the current active fiber was created when the current computation was started by the host calling an export.
     - Whenever a host import is called and the host then calls back into Wasm (putting a host frame on the stack), a new root ancestor is installed and any attempts to resume fibers that had been executed before that point will trap.

 3. If the identities of a fiber's ancestors are not provided to the fiber's descendants and the ancestors never resume the descendants directly, the descendants cannot transfer control to the ancestors without the fiber's cooperation (or by releasing the fiber).

     - Transferring control via resumption events requires the target fiber's identity, so this is not an option.
     - Since the ancestors always resume the fiber rather than the descendants, the fiber is always deeper in the resume stack than its descendants, so normal or exceptional return will reach the fiber before its ancestors.

## Examples

We look at three examples in order of increasing complexity and sophistication: a yield-style generator, cooperative threading and handling asynchronous I/O.

### Yield-style generators

The so-called yield style generator pattern consists of a pair: a generator function that generates elements and a consumer that consumes those elements.
When the generator has found the next element it yields it to the consumer, and when the consumer needs the next element it waits for it.
Yield-style generators represents the simplest use case for stack switching in general, which is why we lead with it here.

#### Generating elements of an array

We start with a simple C-style pseudo-code example of a generator that yields for every element of an array.
For explanatory purposes, we introduce a new `generator` function type and a new ``yield` statement to C:
```
void generator arrayGenerator(fiber *thisTask, int count, int els) {
  for(int ix = 0; ix < count; ix++) {
    thisTask yield els[ix];
  }
}
```
The statement:
```
thisTask yield els[ix]
```
is hypothetical code that a generator might execute to yield a value from a generator.

In WebAssembly, this generator can be written:
```
(type $generator (fiber i32))
(tag $identify (param (ref $generator)))
(tag $yield (param i32))
(tag $next)

(func $arrayGenerator (typeparam $F fiber) (param $parent (ref $F)) (param $count i32) (param $els i32)
  (local $ix i32)

  (handle $on-init
    (do
      ;; Suspend immediately back to the parent and send our identity along
      (fiber.suspend_to $F $identify
        (fiber.current $generator)
        (local.get $parent)
      )
    )
    (event $next)  ;; We are just waiting for the first next event
  )

  (block $break
    (loop $l
      (br_if $break (i32.ge (local.get $ix) (local.get $count)))

      ;; Yield and wait for a next event
      (handle
        (do
          (fiber.suspend_to $F $yield
            (i32.load (i32.add (local.get $els)
                               (i32.mul (local.get $ix)
                                        (i32.const 4))))
            (local.get $parent)
          )
        )
        (event $next)
      ) ;; handle

      ;; Update the loop counter and continue
      (local.set $ix (i32.add (local.get $ix) (i32.const 1)))
      (br $l)
    ) ;; $l
  ) ;; $break

  ;; Return normally to kill the fiber.
)
```
When a fiber suspends, it must be in a `handle` context where one or more `event` handlers are available to it.
In this case our generator has two such `handle` blocks; the first is used during the generator's initialization phase and the second during the main loop.

Our generator will be created in a running state using the `fiber.spawn` instruction.
This means that one of the generator function's first responsibilities is to communicate its identity to the caller.
This is achieved through the fragment:

```
  (handle $on-init
    (do
      ;; Suspend immediately back to the parent and send our identity along
      (fiber.suspend_to $F $identify
        (fiber.current $generator)
        (local.get $parent)
      )
    )
    (event $next)  ;; We are just waiting for the first next event
  )
```

The `$arrayGenerator` suspends itself and resumes its parent, issuing an `identify` event to send its identity to the caller.
The caller needs that identity so that it can resume the `$arrayGenerator` fiber with a `$next` event to continue execution.
Note that `$arrayGenerator` similarly had to take its parent's identity as an argument so it could suspend back to the parent in the first place.
Since the parent fiber could have any type, `$arrayGenerator` needs to be parameterized with that type `$F` so it can receive and use the parent's fiber reference.

During normal execution, the `$arrayGenerator` is always waiting for an `$next` event to trigger the computation of the next element in the generated sequence.
If a different event were signaled to the generator the engine would simply trap.

The end of the `$arrayGenerator`, which is triggered when there are no more elements to generate, is marked by a simple `return`.
This will terminate the fiber and also signal to the consumer that generation has finished.

#### Consuming generated elements

The consumer side of the generator/consumer scenario is similar to the generator except that the consumer is driving the overall control flow.

As before, we start with a C-style psuedo code that uses a generator to add up all the elements generated:
```
int addAllElements(int count, int els[]) {
  fiber *generator = arrayGenerator(count, els);
  int total = 0;
  while (true) {
    switch (generator resume next) {
      case yield(El):
        total += El;
        continue;
      case end:
        return total;
    }
  }
}
```
>The expression `generator resume next` is new syntax to resume a fiber with an
>identified event (in this case `next`); the value returned by the expression is
>the event signaled by the resumed fiber when it suspends.

In WebAssembly, the `addAllElements` function takes the form:

```
(func $addAllElements (typeparam $F fiber) (param $count i32) (param $els i32) (result i32)
  (local $generator (ref $generator))
  (local $total i32)

  (local.set $generator
    (handle (result (ref $generator))
      (do
        (fiber.spawn $arrayGenerator $F
          (fiber.current $F)
          (local.get $count)
          (local.get $els)
        )
        (unreachable) ;; do not expect generator to return yet
      )
      (event $identify) ;; receives (ref $generator) on the stack
    )
  )

  (loop $l
    (handle $body
      (do
        (fiber.suspend_to $generator $next (local.get $generator))
        ;; The generator returned, exit $body, $l
      )
      (event $yield ;; i32 on stack
        (local.set $total (i32.add (local.get $total)))
        (br $l)
      )
    )
  )
  (local.get $total)
)
```

The first task of `$addAllElements` is to establish a new fiber to handle the generation of elements of the array.
We start the generator running, which implies that we first of all need to wait for it to report back its identity.
If the function called by `fiber.spawn` returns without suspending, the next instruction will execute normally.
However, we don't expect the generator to return yet, so we will trap if that occurs.

The main structure of the consumer takes the form of an unbounded loop with a forced termination when the generator signals that there are no further elements to generate by returning normally.

>In practice, the style of generators and consumers is dictated by the toolchain. It would have been possible to structure our generator differently. For example, if generators were created as suspended fibers using `fiber.new` instructions then the initial code of our generator would not have suspended using the `$identify` event.
>In any case, generator functions enjoy a somewhat special relationship with their callers and their structure reflects that.

Again, as with the generator, if an event is signaled to the consumer that does not match either event tag, the engine will trap.

### Cooperative Coroutines (TODO: port to fiber.resume_to)

Cooperative coroutines, sometimes known as _green threads_ allow an application to be structured in such a way that different responsibilities may be handled by different computations. The reasons for splitting into such threads may vary; but one common scenario is to allow multiple sessions to proceed at their own pace.

In our formulation of green threads, we take an _arena_ based approach: when a program wishes to fork into separate threads it does so by creating an arena or pool of fibers that represent the different activities. The arena computation as a whole only terminates when all of the threads within it have completed. This allows a so-called _structured concurrency_ architecture that greatly enhances composability[^c].

[^c]: However, how cooperative coroutines are actually structured depends on the source language and its approach to handling fibers. We present one alternative; many languages don't use structured concurrency techniques and collect all green threads into a single pool.

Our `$arrayGenerator` was structured so that it was entered using a `fiber.spawn` instruction; which implied that the `$arrayGenerator`'s first operation involved suspending itself with an `$identify` event.

In our threads example, we will take a different approach: each green thread
will be associated with a function, but will be created as a suspended fiber.
This allows the fiber arena manager to properly record the identity of each
thread as it is created and to separately schedule the execution of its managed
threads.

#### Structure of a Green Thread
We start with a sketch of a thread, in our C-style pseudo-code, that adds a collection of generated numbers, but yielding to the arena scheduler between every number:
```
void fiber adderThread(fiber *thisThred, fiber *generatorTask){
  int total = 0;
  while(true){
    switch(thisThred suspend pause_){
      case cancel_thread:
        return; // Should really cancel the generator too
      case go_ahead_fiber:{
        switch(generator resume next){
          case yield(El):
            total += El;
            continue;
          case end:
            // report the total somewhere
            thisThred suspend finish_(total);
            return;
        }
      }
    }
  }
}
```
Note that we cannot simply use the previous consumer function we constructed because we want to pause the fiber between every number. A more realistic scenario would not pause so frequently.

The WebAssembly version of `adderThread` is straightforward:
```
(tag $pause_)
(tag $yield_ (param i32))
(tag $go_ahead)
(tag $cancel_thread)
(type $thread ref fiber)

(func $adderThread (param $thisThred $thread) (param $generator $generator)
  (local $total i32 (i32.const 0))
  (event $cancel_thread)
    (local.get $generator)
    (fiber.release) ;; kill off the generator fiber
    (local.get $total) ;; initially zero
    (return)
  )
  (event $go_ahead           ;; event block at top-level of function
    (local.set $total (i32.const 0))
    (loop $l
      (handle $body
        (handle $gen
          (fiber.resume (local.get $generator) $next)
          (br $body)           ;; generator returned, so we're done
          (event $yield (param i32)
            (local.get $total) ;; next entry to add is already on the stack
            (i32.add)
            (local.set $total)
            (fiber.suspend (local.get $thisThred) $pause_)
          )
          (event $end
            (br $body)
          )
        )
        (event $go_ahead
          (br $l)
        )
        (event $cancel_thread
          (br $body)         ;; strictly redundant
        )
      ) ;; $body
    ) ;; $l
    (fiber.retire (local.get $thisThred) ($finish_ (local.get $total)))
  )
)
```
The fiber function is structured to have an essentially empty top-level
body&mdash;it only consists of `event` handlers for the fiber protocol. This
protocol has two parts: when a fiber is resumed, it can be either told to
continue execution (using a `$go_ahead` event), or it can be told to cancel
itself (using a `$cancel_thread` event).

This is at the top-level because our green thread fibers are created initially in suspended state.

The main logic of the fiber function is a copy of the `$addAllElements` logic, rewritten to accomodate the fiber protocol.

A lot of the apparent complexity of this code is due to the fact that it has to embody two roles: it is a yielding client of the fiber manager and it is also the manager of a generator. Other than that, this is similar in form to `$addAllElements`.

>Notice that our `$adderFiber` function uses `fiber.release` to terminate the generator fiber. This avoids a potential memory leak in the case that the `$adderFiber` is canceled.
>In addition, the `$adderFiber` function does not return normally, it uses a `fiber.retire` instruction. This is used to slightly simplify our fiber arena manager.

#### Managing Fibers in an Arena
Managing multiple computations necessarily introduces the concept of
_cancellation_: not all the computations launched will be needed. In our arena
implementation, we launch several fibers and when the first one returns we will
cancel the others:
```
int cancelingArena(fiber fibers[]){
  while(true){
    // start them off in sequence
    for(int ix=0;ix<fibers.length;ix++){
        switch(fibers[ix] resume go_ahead){
        case pause_:
            continue;
        case finish_(T):{
            for(int jx=0;jx<fibers.length;jx++){
              cancel fibers[jx]; // including the one that just finished
          }
          return T
        }
      }
    }
  } // Loop until something interesting happens
}
```
>We don't include, in this example, the code to construct the array of fibers.
>This is left as an exercise.

The WebAssembly translation of this is complex but not involved:
```
(fun $cancelingArena (param $fibers i32)(param $len i32)(result i32)
  (local $ix i32)
  (local $jx i32)
  (loop $l
    (local.set $ix (i32.const 0))
    (loop $for_ix
      (handle
        (fiber.resume
          (table.get $task_table (i32.add (local.get $fibers)(local.get $ix)))
          $go_ahead)
        (event $pause_
          (local.set $ix (i32.add (local.get $ix)(i32.const 1)))
          (br_if $for_ix (i32.ge (local.get $ix) (local.get $len)))
          (br $l)
        )
        (event finish_ ;; We cancel all other fibers
          (local.set $jx (i32.const 0))
          (loop $for_jx
            (handle $inner_jx
              (br_if $inner_jx (i32.eq (local.get $ix)(local.get $jx)))
              (table.get $task_table (i32.add (local.get $fibers)(local.get $jx)))
              (fiber.resume $cancel_thread) ;; cancel fibers != ix
              (event $finish_ ;; only acceptable event
                (local.set $jx (i32.add (local.get $jx)(i32.const 1)))
                (br_if $for_jx (i32.ge (local.get $jx)(local.get $len)))
                (return) ;; total on stack
              )
              (event $pause
                (trap)
              )
            )
          )
        )
      )
    )
  )
)
```
The main additional complications here don't come from threads per se; but rather from the fact that we have to use a table to keep track of our fibers.

### Asynchronous I/O (TODO: port to `fiber.suspend_to`)
In our third example, we look at integrating fibers with access to asynchronous APIs; which are accessed from module imports.

On the web, asynchronous functions use the `Promise` pattern: an asynchronous I/O operation operates by first of all returning a `Promise` that 'holds' the I/O request, and at some point after the I/O operation is resolved a callback function attached to the `Promise` is invoked.

>While non-Web embeddings of WebAssembly may not use `Promise`s in exactly the same way, the overall architecture of using promise-like entities to support async I/O is widespread. One specific feature that may be special to the Web is that it is not possible for an application to be informed of the result of an I/O request until after the currently executing code has completed and the browser's event loop has been invoked.

#### Our Scenario
The JavaScript Promise Integration API (JSPI) allows a WebAssembly module to call a `Promise`-returning import and have it result in the WebAssembly module being suspended. In effect, using the JSPI results in the entire program being suspended.

However, we would like to enable applications where several fibers can make independant requests to a `fetch` import and only 'return' when we have issued them all. Specifically, our example will involve multiple fibers making `fetch` requests and responding when the requests complete.

This implies a combination of local scheduling of tasks, possibly a _tree_ of schedulers reflecting a hierarchical structure to the application, and, as we shall see, some form of multiplexing of requests and demultiplexing of responses. This aspect is perhaps unexpected but is forced on us by the common Web browser embedding: only the browser's outermost event loop is empowered to actually schedule tasks when I/O activities complete.

#### A `fetch`ing Fiber
On the surface, our fibers that fetch data are very simple:
```
async fetcher(string url){
  string text = await simple_fetch(url);
  doSomething(text);
}
```
In another extension to the C language, we have invented a new type of function&mdash;the `async` function. In our mythical extension, only `async` functions are permitted to use the `await` expression form. Our intention is that such a function has an implicit parameter: the `Fiber` that will be suspended when executing `await`.

#### Importing `fetch`
The actual `fetch` Web API is quite complex; and we do not intend to explore that complexity. Instead, we will use a simplified `simple_fetch` that takes a url string and returns a `Promise` of a `string`. (Again, we ignore issues such as failures of `fetch` here.)

Since it is our intention to continue execution of our application even while we are waiting for the `fetch`, we have to somewhat careful in how we integrate with the browser's event loop. In particular, we need to be able to separate which fiber is being _suspended_&mdash;when we encounter the `fetch`es `Promise`&mdash;and which fiber is resumed when the fetch data becomes _available_.

We can express this with the pseudo code:
```
function simple_fetch(client,url){
    fetch(url).then(response => {
      scheduler resume io_notify(client,response.data);
    });
    switch(client.suspend async_request){
      case io_result(text): return text;
    }
  }
}
```
Notice how the `simple_fetch` function invokes `fetch` and attaches a callback to it that resumes the `scheduler` fiber, passing it the identity of the actual `client` fiber and the results of the `fetch`. Before returning, `simple_fetch` suspends the `client` fiber; and a continuation of _that_ suspension will result in `text` being delivered to the client code.

It is, of course, going to be the responsibility of the `scheduler` to ensure that the data is routed to the correct client fiber.

#### A note about the browser event loop
It is worth digging in a little deeper why we have this extra level of indirection. Fundamentally, this arises due to a limitation[^d] of the Web browser architecture itself. The browser's event loop has many responsibilities; inluding the one of monitoring for the completion of asynchronous I/O activities initialized by the Web application. In addition, the _only_ way that an application can be informed of the completion (and success/failure) of an asynchronous operation is for the event loop to invoke the callback on a `Promise`.

This creates a situation where our asynchronous WebAssembly application must ultimately return to the browser before any `fetch`es it has initiated can be delivered. However, this kind of return has to be through our application's own scheduler. And it must also be the case that any resumption of the WebAssembly application is initiated through the same scheduler.

In particular, if the browser's event loop tries to directly resume the fiber that created the `Promise` we would end up in a situation that is very analogous to a _deadlock_: when that fiber is further suspended, or even if if completes, the application as a whole will stop&mdash;because other parts of the application are still waiting for the scheduler to be resumed; but that scheduler was waiting to be resumed by the browser's event loop scheduler.

[^d]: A better phrasing of this might be an unexpected consequence of the browser's event model. This limitation does not apply, for example, to normal desktop applications running in regular operating systems.

The net effect of this is that, for browser-based applicatios, we must ensure that we _multiplex_ all I/O requests through the scheduler and _demultiplex_ the results of those requests back to the appropriate leaf fibers. The demultiplex is the reason why the actual callback call looks like:
```
scheduler resume io_notify(client,response.data)
```
This `resume` tells the scheduler to resume `client` with the data `response.data`. I.e., it is a kind of indirect resume: we resume the scheduler with an event that asks it to resume a client fiber. One additional complication of this architecture is that the scheduler must be aware of the types of data that Web APIs return.

It is expected that, in a non-browser setting, one would not need to distort the architecture so much. In that case, the same scheduler that decides which fiber to resume next could also keep track of I/O requests as they become available.

#### An async-aware scheduler
Implementing async functions requires that a scheduler is implemented within the language runtime library. This is actually a consequence of having a special syntax for `async` functions.

Our async-aware scheduler must, in addition to scheduling any green threads under its control, also arrange to suspend to the non-WebAssembly world of the browser in order to allow the I/O operations that were started to complete. And we must also route the responses to the appropriate leaf fiber.

A simple, probably naïve, scheduler walks through a circular list of fibers to run through. Our one does that, but also records whenever a fiber is suspending due to a `Promise`d I/O operation:

```
typedef struct{
  Fiber f;
  ResumeProtol reason;
} FiberState;
Queue<FiberState> fibers;
List<Fiber> delayed;

void naiveScheduler(){
  while(true){
    while(!fibers.isEmpty()){
      FiberState next = fibers.deQueue();
      switch(next.f resume next.reason){
        case pause:
          fibers.push(FiberState{f:next,reason:go_ahead});
          break;
        case async_request:{
          delayed.put(next);
          break;
        }
      }
      if(fibers.isEmpty() || pausing){
        switch(scheduler suspend global_pause){
          case io_notify(client,data):{
            reschedule(client,data);
          }
        }
      }
    }
  }
}
```

#### Reporting a paused execution
The final piece of our scenario involves arranging for the WebAssembly application itself to pause so that browser's eventloop can complete the I/O operations and cause our code to be reentered.

This is handled at the point where the WebAssembly is initially entered&mdash;i.e., through one of its exports. For the sake of exposition, we shall assume that we have a single export: `main`, which simply starts the scheduler:
```
void inner_main(fiber scheduler){
  startScheduler(scheduler);
}
```
In fact, however, our application itself should be compatible with the overall browser architecture. This means that our actual toplevel function returns a `Promise`:
```
function outer_main() {
  return new Promise((resolve,reject) => {
    spawn Fiber((F) => {
      try{
        resolve(inner_main(F));
      } catch (E) {
        reject(E);
      }
    });
  }
}
```
We should not claim that this is the only way of managing the asynchronous activities; indeed, indiviual language toolchains will have their own language specific requirements. However, this example is primarily intended to explain how one might implement the integration between WebAPIs such as `fetch` and a `Fiber` aware programming language.

#### The importance of stable identifiers
One of the hallmarks of this example is the need to keep track of the identities of different computations; possibly over extended periods of time and across significant _code distances_.

For example, we have to connect the scheduler to the import in order to ensure correct rescheduling of client code. At the time that we set up the callback to the `Promise` returned by `fetch` we reference the `scheduler` fiber. However, at that moment in time, the `scheduler` fiber is still technically running (i.e., it is not suspended). Of course, when the callback is invoked by the event loop the scheduler is suspended.

This correlation is only possible because the identity of a fiber is stable&dash;regardless of its current execution state.

#### Final note

Finally, the vast majority of the code for this scheduler is _boilerplate_ code that is manipulating data structures. We leave it as an exercise for the reader to translate it into WebAssembly.

## Frequently Asked Questions (TODO: Edit for `fiber.resume_to`)

### Why are we using 'lexical scoping' rather than 'dynamic scoping'
A key property of this design is that, in order for a WebAssembly program to switch fibers, the target of the switch is explicitly identified. This so-called lexical scoping approach is in contract with a dynamic approach&mdash;commonly used for exception handling&mdash;where the engine is expected to search the current evaluation context to decide where to suspend to (say).

#### Implementation
In a lexically-scoped design, the engine is explicitly told by the program where to transfer control to.
Thus, the only additional obligation the engine has to implement, besides the actual transfer of control, is validation that the target is _valid_ from the current control point.

In a dynamically-scoped design, the engine has to search for the transfer target. This search is typically not a simple search to specify and/or implement since the _criteria_ for a successful search depends on the language, both current and future.

By requiring the program to determine the target, the computation of this target becomes a burden for the toolchain rather than for the WebAssembly engine implementor.

#### Symmetric coroutining (and its cousin: task chaining)
With symmetric coroutines you can have a (often binary) collection of coroutines that directly yield to each other via application-specific messages. We saw a simple example of this in our [generator example](#generating-elements-of-an-array).

Similar patterns arise when chaining tasks together, where one computation is intended to be followed by another. Involving a scheduler in this situation creates difficulties for types (the communication patterns between the tasks is often private and the types of data are not known to a general purpose scheduler).

A lexically-scoped design more directly/simply/efficiently supports these common horizonal control-transfer patterns than a dynamically-scoped design.

#### Composing Components
In applications where multiple _components_ are combined to form an application the risks of dynamic scoping may be unacceptable. By definition, components have a _shared nothing_ interface where the only permitted communications are those permitted by a common _interface language_. This includes prohibiting exceptions to cross component boundaries&mdash;unless via coercion&mdash;and switching between tasks.

By requiring explicit fiber identifiers we make the task (sic) of implementing component boundaries more manageable when coroutining is involved. In fact, this is envisaged in the components design by using _streaming_ and _future_ metaphors to allow for this kind of control flow between components.

### What is the difference between first class continuations and fibers?
A continuation is semantically a function that, when entered with a value, will finish an identified computation. In effect, continuations represent snapshots of computations. A first class continuation is reified; i.e., it becomes a first class value and can be stored in tables and other locations.

The snapshot nature of a continuation is especially apparent when you compare delimited continuations and fibers. A fiber may give rise to multiple continuations&mdash;each time it suspends[^e] there is a new continuation implied by the state of the fiber. However, in this proposal, the fiber is reified wheras continuations are not.

One salient aspect of first class continuations is _restartability_. In principal, a reified continuation can be restarted more than once&mdash;simply by invoking it.

It would be possible to achieve the effect of restartability within a fibers design&mdash;by providing a means of _cloning_ fibers.

However, this proposal, as well as others under consideration, does not support the restartability of continuations or cloning of fibers.

[^e]: It can be reasonably argued that a computation that never suspends represents an anti-pattern. Setting up suspendable computations is associated with significant costs; and if it is known that a computation will not suspend then one should likely use a function instead of a fiber.

### Can Continuations be modeled with fibers?
Within reason, this is straightforward. A fiber can be encapsulated into a function object in such a way that invoking the function becomes the equivalent of entering the continuation. This function closure would have to include a means of preventing the restartability of the continuation.

### Can fibers be modeled with continuations?
Within reason, this too is straightforward. A fiber becomes an object that embeds a continuation. When the fiber is to be resumed, the embedded continuation is entered.

Care would need to be taken in that the embedded continuation would need to be cleared; a more problematic issue is that, when a computation suspends, the correct fiber would have to be updated with the appropriate continuation.

### How are exceptions handled?

Fibers and fiber management have some conceptual overlap with exception handling. However, where exception handling is oriented to responding to exceptional situations and errors, fiber management is intended to model the normal&mdash;if non-local&mdash; flow of control.

When an I/O operation fails (say), and a requesting fiber needs to be resumed with that failure, then the resuming code (perhaps as part of an exception handler) resumes the suspended fiber with a suitable event. In general, all fibers, when they suspend, have to be prepared for three situations on their resumption: success, error and cancelation. This is best modeled in terms of an `event.switch` instruction listening for the three situations.

One popular feature of exception handling systems is that of _automatic exception propagation`; where an exception is automatically propagated from its point of origin to an outer scope that is equipped to respond to it. This proposal follows this by allowing unhandled exceptions to be propagated out of an executing fiber and into its resuming parent.

However, this policy is generally incompatible with any form of computation manipulation.

The reason is that, when a fiber is resumed, it may be from a context that does not at all resemble the original situation; indeed it may be resumed from a context that cannot handle any application exceptions. This happens today in the browser, for example. When a `Promise` is resumed, it is typically from the context of the so-called micro fiber runner. If the resumed code throws an exception the micro fiber runner would be excepted to deal with it. In practice, the micro fiber runner will silently drop all exceptions raised in this way.

A more appropriate strategy for handling exceptions is for a specified sibling fiber, or at least a fiber that the language runtime is aware of, to handle the exception. This can be arranged by the language runtime straightforwardly by having the failing fiber signal an appropriate event.

There is a common design element between this proposal and the exception handling proposal: the concept of an event. However, events as used in fiber oriented computation are explicitly intended to be as lightweight as possible. For example, there is no provision in events as described here to represent stack traces. Furthermore, events are not first class entities and cannot be manipulated, stored or transmitted.

### How do fibers fit in with structured concurrency?
The fiber-based approach works well with structured concurrency architectures. A relevant approach would likely take the form of so-called fiber _arenas_. A fiber arena is a collection of fibers under the management of some scheduler. All the fibers in the arena have the same manager; although a given fiber in an arena may itself be the manager of another arena.

This proposal does not enfore structured concurrency however. It would be quite possible, for example, for all of the fibers within a WebAssembly module to be managed by a single fiber scheduler. It is our opinion that this degree of choice is advisable in order to avoid unnecessary obstacles in the path of a language implementer.

### Are there any performance issues?
Stack switching can be viewed as a technology that can be used to support suspendable computations and their management. Stack switching has been shown to be more efficient than approaches based on continuation passing style transformations[^f].

[^f]:Although CPS transformations do not require any change to the underlying engine; and they more readily can support restartable computations.

A fiber, as outlined here, can be viewed as a natural proxy for the stack in stack switching. I.e., a fiber entity would have an embedded link to the stacks used for that fiber.

Furthermore, since the lifetime of a stack is approximately that of a fiber (a deep fiber may involve multiple stacks), the alignment of the two is good. In particular, a stack can be discarded precisely when the fiber is complete&mdash;although the fiber entity may still be referenced even though it is moribund.

On the other hand, any approach based on reifing continuations must deal with a more difficult alignment. The lifetime of a continuation is governed by the time a computation is suspended, not the whole lifetime. This potentially results in significant GC pressure to discard continuation objects after their utility is over.

### How do fibers relate to the JS Promise integration API?
A `Suspender` object, as documented in that API, corresponds reasonably well with a fiber. Like `Suspender`s, in order to suspend and resume fibers, there needs to be explicit communication between the top-level function of a fiber and the function that invokes suspension.

A wrapped export in the JS Promise integration API can be realized using fibers
quite straightforwardly: as code that creates a fiber and executes the wrapped
export. This can be seen in the pseudo-JavaScript fragment for the export
wrapper[^g]:
```
function makeAsyncExportWrapper(wasmFn) {
  return function(...args) {
    return new Promise((resolve,reject) => {
      spawn Fiber((F) => {
        try{
          resolve(wasmFn(F,args));
        } catch (E) {
          reject(E);
        }
      })
    })
  }
}
```
[^g]: This code does not attempt to depict any _real_ JavaScript; if for no other reason than that we do not anticipate extending JavaScript with fibers.

Similarly, wrapping imports can be translated into code that attaches a callback to the incoming `Promise` that will resume the fiber with the results of the `Promise`:
```
function makeAsyncImportWrapper(jsFn) {
  return function(F,...args) {
    jsFn(...args).then(result => {
      F.resume(result);
    });
    F.suspend()
  }
}
```
However, as can be seen with the [asynchronous I/O example](#asynchronous-io), other complexities involving managing multiple `Promise`s have the combined effect of making the JSPI itself somewhat moot: for example, we had to multiplex multiple `Promise`s into a single one to ensure that, when an I/O `Promise` was resolved, our scheduler could be correctly woken up and it had to demultiplex the event into the correct sub-computation.

### How does one support opt-out and opt-in?
The fundamental architecture of this proposal is capability based: having access to a fiber identifier allows a program to suspend and resume it. As such, opt-out is extremely straightforward: simply do not allow such code to become aware of the fiber identifier.

Supporting full opt-in, where only specially prepared code can suspend and resume, and especially in the so-called _sandwich scenario_ is more difficult. If a suspending module invokes an import that reconnects to the module via another export, then this design will allow the module to suspend itself. This can invalidate execution assumptions of the sandwich filler module.

It is our opinion that the main method for preventing the sandwich scenario is to prevent non-suspending modules from importing functions from suspending modules. Solutions to this would have greater utility than preventing abuse of suspendable computations; and perhaps should be subject to a different effort.

### Why does a fiber function have to suspend immediately?

The `fiber.new` instruction requires that the first executable instruction is an `event.switch` instruction. The primary reason for this is that, in many cases, eliminates an extraneous stack switch.

Fibers are created in the context of fiber management; of course, there are many flavors of fiber management depending on the application pattern being used. However, in many cases, the managing software must additionally perform other bookkeeping fibers (sic) when creating sub-computations. For example, in a green threading scenario, it may be necessary to record the newly created green thread in a scheduling data structure.

By requiring the `fiber.new` instruction to not immediately start executing the new fiber we enable this bookkeeping to be accomplished with minimal overhead.

However, this proposal also includes the `fiber.spawn` instruction to accomodate those language runtimes that prefer the pattern of immediately executing new fibers.

### Isn't the 'search' for an event handler expensive? Does it involve actual search?
Although there is a list of `event` blocks that can respond to a switch event,
this does not mean that the engine has to conduct a linear search when decided
which code to execute.

Associated with each potential suspension point in a `handle` block one can construct a table of possible entry points; each table entry consisting of a program counter and an event tag. When a fiber is continued, this table is 'searched' for a corresponding entry that matches the actual event.

Because both the table entries and any potential search key are all determined statically, the table search can be implemented using a [_perfect hash_](https://en.wikipedia.org/wiki/Perfect_hash_function) algorithm. I.e., a situation-specific hash algorithm that can guarantee constant access to the correct event handler.

As a result, in practice, when switching between fibers and activating appropriate `event` blocks, there is no costly search involved.

### How does this concept of fiber relate to Wikipedia's concept
The Wikipedia definition of a [Fiber](https://en.wikipedia.org/wiki/Fiber_(computer_science)) is[^h]:

>In computer science, a fiber is a particularly lightweight thread of execution.

[^h]: As of 8/5/2022.

Our use of the term is consistent with that definition; but our principal modification is the concept of a `fiber`. In particular, this allows us to clarify that computations modeled in terms of fibers may be explicitly suspended, resumed etc., and that there may be a chain of fibers connected to each other via the resuming relationship.

Our conceptualization of fibers is also intended to support [Structured Concurrency](https://en.wikipedia.org/wiki/Structured_concurrency). I.e., we expect our fibers to have a hierachical relationship and we also support high-level programming patterns involving groups of fibers and single exit of multiple cooperative activities.

## Open Design Issues

This section identifies areas of the design that are either not completely resolved or have significant potential for variability.

### The type signature of a fiber
The type signature of a fiber has a return type associated with it. This is not an essential requirement and may, in fact, cause problems in systems that must manage fibers.

The reason for it is to accomodate the scenario of a fiber function returning. Since all functions must end at some point, establishing a reasonable semantics of what happens then seems important.

Without the possiblity of returning normally, the only remaining recourse for a fiber would be to _retire_. We expect that, in many usage scenarios, this would be the correct way of ending the life of a fiber.

### Exceptions are propagated
When an exception is thrown in the context of a fiber that is _not_ handled by the code of the fiber then that exception is propagated out of the fiber&mdash;into the code of the resuming parent.

The biggest issue with this is that, for many if not most applications, the resuming parent of a parent is typically ill-equipped to handle the exception or to be able to recover gracefully from it.

The issue is exacerbated by the fact that functions are _not_ annotated with any indication that they may throw an exception let alone what type of exception they may throw.

### Fibers are started in suspended/running state
This proposal allows fibers to be created in a suspended state or they can be created and immediately entered when `spawn`ed.

Allowing fibers to be created in suspended state causes significant architectural issues in this design: in particular, because such a fiber has no prior history of execution (it *is* a new fiber), the fiber function has to be structured differently to account for the fact that there will be a resume event with no corresponding suspend event.

On the other hand, requiring fibers to be started immediately on creation raises its own questions. In particular, if the spawner of a fiber also needs to record the identity of the fiber then the fiber must immediately suspend with some form of `identify` event. We saw this in the generator example. There are enough applications where this would result in a significant performance penalty, for example in a green threading library that is explicitly managing its fiber identities.

For this reason, we support both forms of fiber creation. However, this also represents a compromise and added cost for implementation.
