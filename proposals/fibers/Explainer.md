# Stack Switching with Fibers

## Motivation

Non-local control flow (sometimes called _fiber switching_) operators allow applications to manage their own computations. Technically, this means that an application can partition its logic into separable computations and can manage (i.e., schedule) their execution. Pragmatically, this enables a range of control flows that include supporting the handling of asynchronous events, supporting cooperatively scheduled threads of execution, and supporting yield-style iterators and consumers.

This proposal refers solely to those features of the core WebAssembly virtual machine needed to support non-local control flow and does not attempt to preclude any particular strategy for implementing high level languages. We also aim for a deliberately low-level minimal spanning set of concepts: the author of a high level language compiler should find all the necessary elements to enable their compiler to generate appropriate WebAssembly code fragments.

## Fibers and Events

The main concepts in this proposal are the _fiber_ and the _event_. A fiber is a first class value which denotes the resources needed to support a computation. An event denotes a change in the flow of computation from one fiber to another. 

### The `fiber` abstraction

Computations have an extent in time: they are initiated, instructions are executed and have a termination. A `fiber` is a resource that embodies a computation; fibers are stateful and and may be referenced.[^fiber] Being able to reference fibers allows applications to manage their own computations and support patterns such as async/await, green threads and yield-style generators.

[^fiber]: The term `fiber` is also a term of the art; however, there is no specific consensus on what a fiber is in the computer industry. Our intention is to reflect the lower-level semantics: a mechanism that allows computations to support context switching but without relying on any operating system support and with minimal impact on source language-level concepts such as coroutines and async functions.

Associated with fiber references is a new type:

```
fiberref [<rtype>*] [<stype>*]
```
which is a reference type that denotes fibers.

Notice that our `fiberref` type is qualified with two types: the `<rtype>*` vector is the types of values that are communicated to the fiber whenever the fiber is resumed, and the `<stype>*` vector is the vector of types that are communicated when the fiber is suspended, retired or returns.

#### The state of a fiber

A fiber is inherently stateful; as the computation proceeds the fiber's state reflects that evolution. The state of a fiber includes function call frames and local variables that are currently live within the computation as well as whether the fiber is currently being executed.

However, apart from when a significant event occurs within the computation, the state of a fiber is not externally visible.

In our descriptions of fiber states it is convenient to identify an enumerated symbol that denotes the execution state of the fiber:

```
typedef enum {
  suspended,
  inuse,
  active,
  moribund
} FiberExecutionState
```
The state conveys information about what can happen to the fiber:
* The `suspended` state implies that the ask has suspended execution. It may be resumed or released; but until one of those events, the fiber will not be performing any computations.
* The `active` state implies that the fiber is performing computations; and that it is the currently active fiber. I.e., any new function calls made will be directly using the fiber resources of this fiber.
* The `inuse` state implies that the fiber has resumed another fiber; or is suspended because a parent fiber was suspended.
* The `moribund` state implies that the fiber has terminated execution (or been released) and cannot perform any additional computation.

The state of a fiber is not directly inspectable by WebAssembly instructions.

Only fibers that are in the `active` or `inuse` states may be suspended, and only fibers that are in the `suspended` state may be resumed. `moribund` fibers are those that are no longer capable of execution but may still be referenced in some way.

#### Fibers, ancestors and children

It is convenient to identify some relationships between fibers: the parent of a fiber is the fiber that most recently resumed that fiber. A fiber parent is part of the state of the fiber; and it changes for any event associated with the computation.

The root of the ancestor relation is the _root fiber_ and represents the initial entry point into WebAssembly execution.

#### Fiber identity
The root fiber does not have an explicit identity. This is because, in general, child fibers cannot manage their ancestors.

In addition, it is not possible for WebAssembly code to _discover_ the fiber it is running on. When fibers are created -- using `fiber.new` -- they are given a reference to themselves; but other than that, a WebAssembly function can only be told about which fiber it is running on. This is, in part, to ensure that, when a WebAssembly function calls another function from another module (say), that module cannot discover the identity of the fiber and misuse it. Overall, this is in keeping with a capability-based approach to resource management.

### The switch event abstraction

A switch event occurs whenever computation switches between fibers: when a fiber is suspended, resumed, created or retired. In this proposal, switch events also represent a communications opportunity between computations.

An event _description_ consists of a vector of WebAssembly values that are communicated via the value fiber: for example, when a fiber suspends, it leaves a description of the event associated with the suspension; this description is passed to the fiber's parent as values on the stack.

The types of data values that are communicated is governed by the type of the fiber; specifically, the _stype_ vector for suspending events and the _rtype_ vector for resuming events.

#### Fiber nesting
The type of the fiber reference is fixed for the entire duration of its existence. At first sight this would seem to be a limitation, since many applications will suspend for different reasons at different points in their lifecycle. However, the type of a fiber is also important for those fibers that must respond to its switch events. 

The simplest technique for supporting multiple kinds of switch event is _fiber nesting_: if a computation has multiple kinds of switch event, with multiple handlers for those events, then the programmer should nest fibers -- i.e., use `fiber.new` inside a `fiber.new`. Then, when a WebAssembly program suspends it _chooses_ which of the nested fibers should suspend and therefore chooses which code is responsible for handling the event.

In the rest of this document we introduce the key instructions, give some worked examples and answer some of the frequently asked questions.

## Instructions

We introduce instructions for creating, suspending, resuming and terminating fibers.

### Fiber instructions

#### `fiber.new` Create a new fiber, continue executing in the new fiber

The `fiber.new` instruction creates a new fiber entity. The instruction has a literal operand which is the index of a function of type 

```
[[fiberref [rt*] [st*]] t*]->[st*]
```
together with corresponding values on the argument stack.

This is effectively an indirect function call of the fiber function
The result is a `fiberref` which is the identifier for the newly created fiber. The identity of the fiber is also the first argument to the fiber function itself&mdash;this allows fibers to know their own identity in a straightforward way.

The other arguments to the function include the values for the first resumption to the fiber as well as additional arguments that are specific to the function.

The function's return type must match the suspension type of the fiber ref; because one of the ways that a fiber can 'suspend' is by returning.

The effect is that, when the function starts executing&mdash;which will be when the fiber is first resumed&mdash;the fiber's identity and the fibers first resume event will be available to it.

The fiber itself is created in a `suspended` state&mdash;it will not start until the fiber is resumed.

#### `fiber.suspend` Suspend an active fiber

The `fiber.suspend` instruction takes a fiber as an argument and suspends the fiber. The identified fiber must be in the `active` state; or, if the fiber being suspended is an ancestor of the currently `active` state, in the `inuse` state.

The _root_ fiber does not have an explicit identifier; and so it may not be suspended.

The fiber being suspended is marked as being `suspended`, as well as the currently `active` fiber.

`fiber.suspend` has two operands: the identity of the fiber being suspended and a description of the event it is signaling. The types of the event arguments must be consistent with the suspend type vector&mdash;`<stype*>` of the fiber.

Immediately following the `fiber.suspend` instruction&mdash;which is only reachable if the suspended fiber is resumed using a `fiber.resume` instruction&mdash;the values corresponding to the suspension event are discarded and replaced with values that correspond to the resumption event.

#### `fiber.resume` Resume a suspended fiber

The `fiber.resume` instruction takes a fiber as argument, together with a vector of values that describe the event, and resumes its execution. The types of the arguments passed to the resuming fiber must match the `<rtype*>` type vector in the fiber's type signature.

The `fiber.resume` instruction takes a `suspended` fiber, together with any descendant fibers that were suspended along with it, and resumes its execution. 

The event arguments are used to encode how the resumed fiber should react: for example, whether the fiber's requested information is available, or whether the fiber should enter into cancelation mode. This information is typically encoded using a sentinel value as one of the event's resumption arguments.

#### `fiber.switchto` Switch to a different fiber

The `fiber.switchto` instruction is a combination of a `fiber.suspend` and a `fiber.resume` to an identified fiber. This instruction is useful for circumstances where the suspending fiber knows which other fiber should be resumed.

The `fiber.switchto` instruction has three arguments: the identity of the fiber being suspended, the identity of the fiber being resumed and the signaling event.

Although it may be viewed as being a combination of the two instructions, there is an important distinction also: the signaling event. Under the common hierarchical organization, a suspending fiber does not know which fiber will be resumed. This means that the signaling event has to be of a form that the fiber's manager is ready to process. However, with a `fiber.switchto` instruction, the fiber's manager is not informed of the switch and does not need to understand the signaling event.

This, in turn, means that a fiber manager may be relieved of the burden of communicating between fibers. I.e., `fiber.switchto` supports a symmetric coroutining pattern. However, precisely because the fiber's manager is not made aware of the switch between fibers, it must also be the case that this does not _matter_; in effect, the fiber manager may not directly be aware of any of the fibers that it is managing.  

#### `fiber.retire` Retire a fiber

The `fiber.retire` instruction is used when a fiber has finished its work and wishes to inform its parent of any final results. Like `fiber.suspend` (and `fiber.resume`), `fiber.retire` has an event argument&mdash;together with associated values on the agument fiber&mdash; that are communicated. As with `fiber.suspend`, the values communicated must match the fiber's `<stype*>` type arguments.

In addition, the retiring fiber is put into a `moribund` state and any computation resources associated with it are released. If the fiber has any active descendants then they too are made `moribund`.

Where a fiber's function returns normally, this counts as the fiber being retired. Therefore, the return type of the fiber function must also match the fiber's `<stype*>` type vector.

#### `fiber.release` Destroy a suspended fiber

The `fiber.release` instruction clears any computation resources associated with the identified fiber. The identified fiber must be in `suspended` state.

If the suspended fiber has current descendant fibers (such as when the fiber was suspended), then those fibers are `fiber.release`d also.

Since fiber references are wasm values, the reference itself remains valid. However, the fiber itself is now in a `moribund` state that cannot be resumed.

The `fiber.release` instruction is primarily intended for situations where a fiber manage needs to eliminate unneeded fiber and does not wish to formally cancel them.

Since no values are communicated to the fiber being released, and no values are returned by the fiber either, this instruction is effectively _polymorphic_ in the type of tsk being released.

## Examples

We look at three examples in order of increasing complexity and sophistication: a yield-style generator, cooperative threading and handling asynchronous I/O.


### Yield-style generators

The so-called yield style generator pattern consists of a pair: a generator function that generates elements and a consumer that consumes those elements. When the generator has found the next element it yields it to the consumer, and when the consumer needs the next element it waits for it. Yield-style generators represents the simplest use case for fiber switching in general; which is why we lead with it here.

One problem that must be addressed by any language compiler that emits fiber switching code is how to represent any events that may occur. If fiber switching is combined with Wasm GC it would be possible to use a structure to represent events; in which case a single reference value would be communicated for each event in much the same way that algebraic data values might be represented using references.

However, allocating structures for events may represent a significant memory turnover resulting in unwanted GC pressure.

In the generator example, is is quite important to perform as little allocations as possible (yield-style generators are effectively competing with java-style iterators and with normal inline while loops). So, for this example, we use a vector of n+1 values for each event description; where the first event is a sentinel value&mdash;encoded using the equivalent of an enumerated type&mdash; and the remaining arguments depending on the event itself[^1].

This strategy involves determining the maximum number of values that may be communicated to/from a fiber and _padding_ in the situation where the actual event does not need all the arguments. Computing these vectors is the resonsibility of the code generator. 

In the case of the yield generator, there are four events of interest: prompting for the next value from the  generator, canceling the generator, returning the next value and signaling the end of teh iteration. Only one of these involves any variable data&mdash;the yield of the next value.

[^1]: An alternate strategy could be to pass a single value describing the event; but to reuse the event's allocation as appropriate.

#### Generating elements of an array
We start with a simple C-style pseudo-code example of a generator that yields for every element of an array:

```
yieldEnum arrayGenerator(fiber *thisFiber,int count,int els){
  for(int ix=0;ix<count;ix++){
    switch(yield(thisFiber,els[ix])) {
      case next:
        continue;
      case cancel:
        return end;
    }
  }
  return end;
}
```
In WebAssembly, we have to determine how to represent the two events: `yield` and `next`. We will use an enumeration value&mdash;embedded in an `i32` value&mdash;to represent the four different kinds of events:
```
typedef enum{
  yield = 0,
  end = 1
} yieldEnum;

typedef enum{
  next = 0,
  cancel = 1
} generatorEnum;
```
The `yield` carries a value that represents the next value found, so when we suspend the generator fiber we always return two values. We capture this in the type definition for the `$generatorFiber`:
```
(type $generatorFiber (fiberref (i32)(i32 i32)))
```
The `$arrayGenerator` function looks like:
```
(func $arrayGenerator (param $thisFiber $generatorFiber) 
  (param $first i32)(param $count i32) (param $els i32)
  (returns i32 i32))

  (block $on-cancel
    (block $on-init-next
      (local.get $first)
      (br-table $on-init-next $on-cancel)))
    )

    (local $ix i32)
    (local.set $ix (i32.const 0))
    (loop $l
      (local.get $ix)
      (local.get $count)
      (br_if $l (i32.ge (local.get $ix) (local.get $count)))

      (block $on-next ;; set up for the switch back on next
        (fiber.suspend (local.get $thisFiber) 
                      (i32.load (i32.add (local.get $els) 
                             (i32.mul (local.get $ix)
                                      (i32.const 4)))
                      (i32.const #yield))
        (br_table $on-next $on-cancel)
      )
      (local.set $ix (i32.add (local.get $ix) (i32.const 1)))
      (br $l)
    )
  ) ;; $on-cancel

  (i32.const 0) ;; dummy
  (i32.const #end)
  return
)
```
When a fiber suspends, it must be followed by instructions that analyse the effect of being resumed. In this case, the value coming back is a sentinel that is either `#next` or `#cancel` depending on whether the client of the generator wants another value or wants to cancel the iteration.

Our example code handles this by a `br_table` instruction that either continues to the next block or arranges to exit the entire function.

The beginning of the `$arrayGenerator` function is marked by a block of code that looks like the function is waiting for an `#next` event. This is because, when a new fiber is created, it is in an initially suspended state; and we are also required to ensure the invariant that suspended fibers are waiting for an event to occur. Creating fibers in suspended state ensures that the function that creates a fiber has the necessary opportunity to appropriately record the identity of the new fiber without it executing any code.

Notice that the array generator has definite knowledge of its own fiber reference&mdash;it is given the identity of its fiber explictly. This is needed because when a fiber suspends, it must use the identity of the fiber that is suspending. There is no implicit searching for which computation to suspend.

The end of the `$arrayGenerator`&mdashwhich is triggered when there are no more elements to generate&mdash;is marked by returning a pair of `i32` values: a dummy value and the `#end` sentinel. The dummy value is needed because the function signature requires the return of two values; which, in turn, is required because one of the ways the fiber can suspend is with a `#yield` event which has to be represented with two `i32`s.

#### Consuming generated elements
The consumer side of the generator/consumer scenario is similar to the generator; with a few key differences:

* The consumer drives the overall choreography
* The generator does not have a specific reference to the consumer; but the consumer knows and manages the generator. 

As before, we start with a C-style psuedo code that uses a generator to add up all the elements generated
```
int addAllElements(int count, int els[]){
  fiber *generator = fiber(arrayGenerator,count,els);
  int total = 0;
  while(true){
    switch(next(generator)){
      case yield(El):
        total += El;
        continue;
      case end:
        return total;
    }
  }
}
```
In WebAssembly, this takes the form:
```
(func $addAllElements (param $count i32) (param $els i32) (result i32)
  (local $generator (fiber.new $arrayGenerator (local.get $count) (local.get $els)))
  (local $total i32)
  (local.set $total i32.const 0)
  (loop $l
    (block $on-end
      (block $on-yield (i32) ;; 'returned' by the generator when it yields the next element
         (fiber.resume (local.get $generator) (i32.const #next))
         (br_table $on-yield $on-end))
      ) ;; the fiber contains the #yield sentinel value and the value being yielded
      (drop) 
      (local.get $total) ;; next entry to add is already on the fiber
      (i32.add)
      (local.set $total)
      (br $l)
    ) ;; ending the iteration
    (local.get $total)
    (return)
  )
)       
```
Since `$addAllElements` is likely not itself a fiber, we do not start it with a blocking preamble&mdash;as we had to do with the generator.

The structure of the consumer takes the form of an unbounded loop, with a forced termination when the generator signals that there are no further elements to generate. This is taken into account by the fact that the `event.switch` instruction has two event tags it is looking for: `#next` and `#end`. Our particular consumer never sends the `#cancel` event to the generator; but other situations may call for it.

The way that our example is written, if the generator sees an event it is not expecting it will interpret it as a `#cancel` event. Similarly, if the generator suspends with anything other than `#yield` or `#end`, the consumer code will interpret it as the equivalent of `#end`. A more robust implementation would likely raise exceptions in either of these cases.

### Cooperative Coroutines

Cooperative coroutines, sometimes known as _green threads_ or _fibers_ allow an application to be structured in such a way that different responsibilities may be handled by different computations. The reasons for splitting into such fibers may vary; but one common scenario is to allow multiple sessions to proceed at their own pace.

In our formulation of fibers, we take an _arena_ based approach: when a program wishes to fork into separate fibers it does so by creating an arena or pool of fibers that represent the different activities. The arena computation as a whole only terminates when all of the fibers within it have completed. This allows a so-called _structured concurrency_ architecture that greatly enhances composability[^2].

[^2]: However, how cooperative coroutines are actually structured depends on the source language and its approach to handling fibers. We present one alternative.

#### Structure of a Fiber
We start with a sketch of a fiber, in C-style pseudo-code, that adds a collection of generated numbers, but yielding to the arena scheduler between every number:

```
void adderFiber(fiber *thisFiber, fiber *generatorFiber){
  int total = 0;
  while(true){
    switch(pause_fiber(thisFiber)){
      case cancel_fiber:
        cancel(generator);
        return;
      case go_ahead_fiber:{
        switch(next(generator)){
          case yield(El):
            total += El;
            continue;
          case end:
            // report the total somewhere
            end_fiber(thisFiber,total);
            return;
        }
      }
    }
  }
}
```
Note that we cannot simply use the previous function we constructed because we want to pause the fiber between every number. A more realistic scenario would not pause so frequently.

The WebAssembly version of `adderFiber` is straightforward. As with our generator, we need to define a type for the fiber:
```
(type $fiberFiber (fiberref (i32) (i32 i32)))
```
This is similar to the type for the `$generatorFiber` but the meaning of the sentinels is a little different:
```
typedef enum {
  pause_fiber = 0,
  end_fiber = 1
} fiberSuspends;

typedef enum{
  go_ahead_fiber = 0,
  cancel_fiber = 1
}
```
The only event with additional data associated with it is `#end_fiber` which returns the value computed by the fiber to the fiber arena manager. 

```
(func $adderFiber (param $thisFiber fiberref)
   (param $first i32)
   (param $generator fiberref)
  (local $total i32)
  (block $on-cancel
    (block $on-init 
      (br_table $on-init $on-cancel))
    )
    (drop)
    (local.set $total (i32.const 0))
    (loop $l
      (block $on-end
        (block $on-yield (i32) ;; 'returned' by the generator when it yields the next element
          (fiber.resume (local.get $generator) (i32.const #next))
          (br_table $on-yield $on-end))
        )
        (block $on-continue
          (local.get $total) ;; next entry to add is already on the fiber
          (i32.add)
          (local.set $total)
          (fiber.yield (local.get $thisFiber) (i32.const #pause_fiber))
          (br_table $on-continue $on-cancel)
        )
        (br $l) ;; go back and do some more
      )
      (local.get $total)
      (i32.const #end_fiber)
      (return)
    )
  ) ;; $on-cancel
  (fiber.release (local.get $generator)) ;; Kill of the generator
  (local.get $total)
  (i32.const #end_fiber)
  (return)
)
```
A lot of the apparent complexity of this code is due to the fact that it has to embody two roles: it is a yielding client of the fiber manager and it is also the manager of a generator. Other than that, this is similar in form to `$addAllElements`.

#### Managing Fibers in an Arena
Managing multiple computations necessarily introduces the concept of _cancellation_: not all the computations launched will be needed. In our arena implementation, we launch several fibers and when the first one returns we will cancel the others:

```
int cancelingArena(fiber fibers[]){
  while(true){
    // start them off in sequence
    for(int ix=0;ix<fibers.length;ix++){
        switch(go_ahead(fibers[ix])){
        case pause_fiber:
            continue;
        case end_fiber(T):{
            for(int jx=0;jx<fibers.length;jx++){
              cancel_fiber(fibers[jx]); // including the one that just finished
          }
          return T
        }
      }
    }
  } // Loop until something interesting happens
}
```

The WebAssembly translation of this is complex but not involved:
```
(fun $cancelingArena (param $fibers i32)(param $len i32)(result i32)
  (local $ix i32)
  (local $jx i32)
  (loop $l
    (local.set $ix (i32.const 0))
    (loop $for_ix
      (fiber.resume 
        (table.get $fiber_table (i32.add (local.get $fibers)(local.get $ix)))
        (i32.const #go_ahead))
      (block $on-end (result i32)
        (block $on-pause
          (br_table $on-pause  $on-end))
        ) ;; pause_fiber event
        (local.set $ix (i32.add (local.get $ix)(i32.const 1)))
        (br_if $for_ix (i32.ge (local.get $ix) (local.get $len)))
      ) ;; end_fiber event, found total on fiber
      (local.set $jx (i32.const 0))
      (loop $for_jx
        (block $inner_jx
          (br_if $inner_jx (i32.eq (local.get $ix)(local.get $jx)))
          (fiber.resume
              (table.get $fiber_table (i32.add (local.get $fibers)(local.get $jx)))
              (i32.const #cancel_fiber))
          (br_table $inner_jx) ;; only acceptable event
        )
        (local.set $jx (i32.add (local.get $jx)(i32.const 1)))
        (br_if $for_jx (i32.ge (local.get $jx)(local.get $len)))
      )
      (return) ;; total still on fiber
    )
  )
)
```
The main additional complications here don't come from fibers per se; but rather from the fact that we have to use a table to keep track of our fibers. 

### Asynchronous I/O
TBD

## Frequently Asked Questions

### What is the difference between first class continuations and fibers?
A continuation is semantically a function that, when entered with a value, will finish the computation. In effect, continuations represent snapshots of the computation. A first class continuation is reified; i.e., it becomes a first class value and can be stored in tables and other locations.

This is especially apparent when you compare delimited continuations and fibers. A fiber has a natural delimiter: the point in the overall computation where the fiber is created. Over the course of a fiber's computation, it may suspend and be resumed multiple times[^3]. Each point where a fiber is suspended, we may consider that a continuation exists that denotes the remainder of the fiber.

One salient aspect of first class continuations is _restartability_. In principal, a continuation can be restarted more than once. However, this proposal, as well as others under consideration, ban to resuability of computations. A design for computation management that depends on first class continuations must test for the attempted reuse of a continuation.

However, this proposal does not reify continuations; instead the focus is on computations which do have an identity in this model.

[^3]: It can be reasonably argued that a computation that never suspends represents an anti-pattern. Setting up suspendable computations is associated with significant costs; and if it is known that a computation will not suspend then one should likely use a function instead of a fiber.

### Can Continuations be modeled with fibers?
Within reason, this is straightforward. A fiber can be encapsulated into a function object in such a way that invoking the function becomes the equivalent of entering the continuation.

However, this approach would not support restartable continuations without some additional ability to clone a fiber. This latter capability is not part of this proposal.

In addition, this proposal does not directly model effect handlers. However, as can be seen with the code examples, it is straightforward to do so using existing WebAssembly instructions. Furthermore, it requires no additional design chenages to support languages that allow the use of so-called first class events[^4].

[^4]: So-called first class event are better described as first-class _event descriptions_.

### Can fibers be modeled with continuations?
Within reason, this too is straightforward. A fiber becomes an object that embeds a continuation. When the fiber is to be resumed, the embedded continuation is entered.

Care would need to be taken in that the embedded continuation would need to be cleared; a more problematic issue is that, when a computation suspends, the correct fiber would have to be updated with the appropriate continuation.

### How are exceptions handled?
Exceptions arise in the context of suspendable computations because operations that are triggered prior to a suspension can fail. However, we do not make special accomodation for exceptions. Instead we use the common event mechanism to report both successful and unsuccessful computations.

When an I/O operation fails (say), and a requesting fiber needs to be resumed with that failure, then the resuming code (perhaps as part of an exception handler) resumes the suspended fiber with a suitable event. In general, all fibers, when they suspend, have to be prepared for three situations on their resumption: success, error and cancelation. This is best modeled in terms of an `event.switch` instruction listening for the three situations.

One popular feature of exception handling systems is that of _automatic exception propagation`; where an exception is automatically propagated from its point of origin to an outer scope that is equipped to respond to it. In the case of an exception arising within a fiber that is not caught by the fiber function then the exception will naturally be propagated to the parent of the fiber.

However, we do not recommend that language providers rely on this policy of exception propagation. 

The reason is that, when a fiber is resumed, it may be from a context that does not at all resemble the original situation; indeed it may be resumed from a context that cannot handle any application exceptions. This happens today in the browser, for example. When a `Promise` is resumed, it is typically from the context of the so-called micro fiber runner. If the resumed code throws an exception the micro fiber runner would be excepted to deal with it. In practice, the micro fiber runner will silently drop all exceptions raised in this way.

A more appropriate strategy for handling exceptions is for a specified sibling fiber, or at least a fiber that the language run-time is aware of, to handle the exception within the fiber function. This can be arranged by the language run-time straightforwardly by having the failing fiber signal an appropriate event. On the other hand, this kind of policy is extremely difficult to specify at the WebAssembly VM level. 

### How do fibers fit in with structured concurrency?
The fiber-based approach works well with structured concurrency architectures. A relevant approach would likely take the form of so-called fiber _arenas_. A fiber arena is a collection of fibers under the management of some scheduler. All the fibers in the arena have the same manager; although a given fiber in an arena may itself be the manager of another arena.

This proposal does not enfore structured concurrency however. It would be quite possible, for example, for all of the fibers within a WebAssembly module to be managed by a single fiber scheduler. It is our opinion that this degree of choice is advisable in order to avoid unnecessary obstacles in the path of a language implementer.

### Are there any performance issues?
Fiber switching can be viewed as a technology that can be used to support suspendable computations and their management. Fiber switching has been shown to be more efficient than approaches based on continuation passing style transformations[^5].

[^5]:Although CPS transformations do not require any change to the underlying engine; and they more readily can support restartable computations.

A fiber, as outlined here, can be viewed as a natural proxy for the fiber in fiber switching. I.e., a fiber entity would have an embedded link to the fibers used for that fiber. 

Furthermore, since the lifetime of a fiber is approximately that of a fiber (a deep fiber may involve multiple fibers), the alignment of the two is good. In particular, a fiber can be discarded precisely when the fiber is complete&mdash;although the fiber entity may still be referenced even though it is moribund.

On the other hand, any approach based on reifing continuations must deal with a more difficult alignment. The lifetime of a continuation is governed by the time a computation is suspended, not the whole lifetime. This potentially results in significant GC pressure to discard continuation objects after their utility is over.

### How do fibers relate to the JS Promise integration API?
There are three scenarios in which fibers might _interact_ with `Promises`: a `Promise` is caught by the import wrapper and tuned into a suspension which is either propagated directly out of the executing WebAssembly code via a wrapped export, or the suspension is caught by a fiber within the execution. The third pattern is where a fiber wishes to suspend the entire WebAssembly execution and have it projected out as a `Promise`.

In the first two cases, we can distinguish the _projected through_ scenario from the _caught internally_ scenario quite straightforwardly: if the `Suspender` object that the import wrapper is using is actually a `fiberref` of an internally executing fiber, then that fiber will be suspended; just as though the fiber had executed an appropropriate `fiber.suspend` instruction. Otherwise, the `Suspender` object must have originated from the export wrapper and the suspension is converted to an appropriate `Promise`.

The third case&mdash;where an internal fiber wishes to cause suspension of the whole module&mdash;is also straightforward. The suspending fiber simply references the `Suspender` object that originated from the export wrapper.

All three of these scenarios represent compelling use cases and we expect all of them to be supported. All that would remain would be standardizing the sentinel values that the `suspendOnReturnedPromise` and `returnPromiseOnSuspension` functions would use.

A final aspect of this relationship is that it should be straightforward to _polyfill_ the JS Promise integration API using the fiber capabilities&mdash;and a little glue code in JavaScript that directly inspected and created the appropriate `Promise` objects.

### How does this proposal relate to exception handling?
Fibers and fiber management have some conceptual overlap with exception handling. However, where exception handling is oriented to responding to exceptional situations and errors, fiber management is intended to model the normal&mdash;if non-local&mdash; flow of control.

This proposal integrates with the exception handling proposal in the sense that exceptions that are thrown by a fiber (and not caught by its fiber function) will be propagated out to the parent of the fiber. However, we do not recommend tool chain providers relying on this behavior: it is there primarly to support compatibility with the JS-Promise integration proposal.

### How does one support opt-out and opt-in?
The fundamental architecture of this proposal is capability based: having access to a fiber identifier allows a program to suspend and resume it. As such, opt-out is extremely straightforward: simply do not allow such code to become aware of the fiber identifier.

Supporting opt-in, where only specially prepared code can suspend and resume, and especially in the so-called _sandwich scenario_ is more difficult. If a suspending module invokes an import that reconnects to the module via another export, then this design will allow the module to suspend itself. This can invalidate execution assumptions of the sandwich filler module.

It is our opinion that the main method for preventing the sandwich scenario is to prevent non-suspending modules from importing functions from suspending modules. Solutions to this would have greater utility than preventing abuse of suspendable computations; and perhaps should be subject to a different effort.

### Fibers and session types

This proposal qualifies fiber types with two types: the vector of types corresponding to values passed when a fiber suspends and a similar vector for when the fiber is resumed. The types of values passed to a fiber when it is resumed is nearly always different to the types it generates when it suspends. 

In a language with algebraic types, the two scenarios may often be modeled using algebraic types; specifically using a sum type to distiguish the different ways that a fiber may suspend/be resumed.

However, this strategy often does not fully capture the _communication pattern_ of fibers; typically computations may be involved with multiple overlapping communication patterns.

One approach that may support this would be to use [_session types_](http://www.dcs.gla.ac.uk/research/betty/summerschool2016.behavioural-types.eu/programme/DardhaIntroBST.pdf/at_download/file.pdf). Session types use algebraic data types (typically recursive) to model the state of a conversation between two or more parties. 

We could model valid fibers by assigning them a session type and we would ensure _conversational integrity_ by requiring session types to match when creating fibers.

While this may be a promising line of research, it seems that the gain from this (statically validating fibers vs dynamically validating each event) may not be sufficient to justify the effort. We are not currently planning on relying of session types for this proposal.

### Why does a fiber function have to suspend immediately?

The `fiber.new` instruction creates a new fiber using a function as the computation template for the fiber. In addition, the fiber is created in a `suspended` state&mdash;which necessitates the arguably clumsy handling of the fiber's first resuming event.

Fibers are created in the context of fiber management; of course, there are many flavors of fiber management depending on the application pattern being used. However, in many cases, the managing software must additionally perform other bookkeeping fibers (sic) when creating sub-computations. For example, in a green threading scenario, it may be necessary to record the newly created green thread in a scheduling data structure.

By requiring the `fiber.new` instruction to not immediately start executing the new fiber we enable this bookkeeping to be accomplished with minimal overhead.
