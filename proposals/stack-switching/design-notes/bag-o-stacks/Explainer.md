# Stack Switching Coroutines

## Motivation

Non-local control flow (sometimes called _stack switching_) operators allow applications to manage their own computations. Technically, this means that an application can partition its logic into separable computations and can manage (i.e., schedule) their execution.[^nothreads] Pragmatically, this enables a range of control flows that include supporting the handling of asynchronous events, supporting cooperatively scheduled threads of execution, and supporting yield-style iterators and consumers.

[^nothreads]: In this proposal we are solely concerned with _single threaded_ execution. Otherwise known as _cooperative scheduling_, applications that use coroutines have explicit events that mark changes of control between managed computations. In effect, the cooperative coroutines are all _multiplexed_ onto a single thread of computation.

This proposal refers to those features of the core WebAssembly virtual machine needed to support non-local control flow and does not attempt to preclude any particular strategy for implementing high level language features. We also aim for a deliberately low-level minimal spanning set of concepts: the author of a high level language compiler should find all the necessary elements to enable their compiler to generate appropriate WebAssembly code fragments.

## A bag of stacks approach

Informally, the approach outlined in this proposal is aligned with the 'bag of stacks' style: the engine allows many different computations to be modeled but does not establish any pairwise relationship between them. I.e., there is no parent/child relationship between any two computations.

There are two main reasons for adopting this style:

* Requiring the engine to maintain parent/child relationships implies, in many instances, proving properties that are potentially onerous and do not significantly enhance the safety of the application. For example, in this design, the engine does not have to search when switching computations: it is a requirement of the language provider to ensure that the target is always directly known when switching between coroutines. Similarly, when suspending a computation, the engine does not need to dynamically verify that the subject of suspension is legitimate.[^types]

[^types]: However, type safety is guaranteed: a switch to another computation requires a reference to that computation; and that reference is statically verified for type safety.

* Given that WebAssembly is not a source language but a target language for a wide variety of programming languages, the fewer the embodied concepts in a design for coroutining, the less likely it will be for a given programming language provider to encounter semantic difficulties. For example, if a programming language does not itself incorporate a notion of a suspend/resume relationship between coroutines, then adding such a relationship to this design results in ignored features at best and additional complexity and performance penalty at worst.

At the same time, it should be noted, this style is significantly lower level than other possible designs. This means that most language providers will have to make more of an effort to map their language features to the design. The tradeoff is that that work is not against design decisions that we embody in this proposal; and that we do not require features that language providers can't or won't use.

## Terminology

Selecting an appropriate terminology to model 'computations that can manage themselves' is challenging. Most terms are either slightly off the mark or are so over-used as to become meaningless. (The term computation is an example of the latter.) In this proposal we standardize certain nomenclature to aid readability:

* Coroutine. A coroutine is a _computation_ that is under the active management of the application itself. This means that the coroutine can be started, paused[^selfPause] and stopped; however, it does not mean that the coroutine is running in parallel: true parallel or multi-threaded execution is beyond the scope of this design.

[^selfPause]: Technically, a coroutine can be started, but must pause or stop itself: it is not possible for an 'outsider' to stop a coroutine.

* Coroutine function. A coroutine function is a _function_ that denotes what the overall computation of a coroutine is. When a coroutine is started, the coroutine function is entered, and when the coroutine function terminates the coroutine is no longer available for execution.

* Event. An event is an _occurrance_ that is of interest to some observer.

* Event description. An event description is a _data value_ (or collection of data values) that the application deems is important to describe the event.

* Stack. A stack is a _resource_ that may be used within the implementation of an engine to support some of the features of WebAssembly. Stacks are used to represent the active frames of a computation (including coroutines), some of the local variables used and so on. We often use the term _switching stacks_ to imply switching between coroutines.

* Stack switch. A stack switch is an _event_ that is associated with the transfer of active execution from one coroutine to another. Stack switch events are typically also associated with event descriptions that encode the reason for the switch.

## Stacks, Coroutines and Stack references

Executing coroutines require internal resources that enable the execution system to keep track of their execution. These resources include the memory needed to represent local variables, arguments and function calls as well as the execution status of the coroutine. I.e., machines need a _stack resource_ to hold the state of execution. In this proposal, we do not expose stacks as first class entities; however, we do model suspended computations with a _stack reference_.

### The coroutine abstraction

Computations have an extent in time and space: they are initiated, instructions are executed and have a termination.  A _coroutine_ is a computation that is potentially addressable directly by the application itself. A coroutine is analogous to a function call, with the additional potential for being _suspended_, _resumed_ and for suspended coroutines[^susponly] to be referenced as the value of an expression.

[^susponly]: We do not allow the actively executing coroutine to be explicitly referenced.

#### The state of a coroutine

In addition to storage for variables and function calls, particularly when describing the operations that can be applied to coroutines, it is useful to talk about the coroutine's execution status:

* The `suspended` state implies that the coroutine has suspended execution. It may be resumed; but until then, the coroutine will not be executing any instructions.

* The `active` state implies that the coroutine is currently executing; and that it is _the_ currently active coroutine. There is always exactly one active coroutine in a single threaded WebAssembly application.

* The `moribund` state implies that the coroutine has terminated execution and cannot perform any additional computation -- attempting to resume a moribund computation will result in an execution trap. Any stack resources previously associated with the moribund coroutine may have been released.

The status of a coroutine is not directly inspectable by WebAssembly instructions.

Only the `active` coroutine may be suspended, and only coroutines that are in the `suspended` state may be resumed. Attempting to resume a `moribund` coroutine will result in a trap.

We should note here that terms such as _resuming_ or _suspending_ are meant somewhat informally. The only operation that this proposal supports is _switching_ between coroutines: suspending and resuming are simply informal names of usage patterns of switching.

### Stack references

A stack is a first class value denoting a coroutine in a _suspended_ state. Associated with stacks is the `stack` type:

```wasm
(type $c (stack <params> <rt>))
```

where `<params>` are the types of values to be sent to the suspended computation as part of _waking it up_.

The <rt> parameter is somewhat special: it is also a reference to a stack type; specifically it should be the stack type of the currently executing coroutine. This is the type of the stack that is needed to switch back to the current coroutine.

The return stack type must be of the form:

```wasm
(ref null? $c)
```

where $c is the index of a stack type.

>This affects which instructions are legal to perform; the switch_retire instruction passes a null stack as the return stack, whereas the regular switch instruction never passes a null stack.
>
>This, in turn, permits some potential optimizations in avoiding null checks; for those cases where it is not permitted.

For example, a stack that is expecting a pair of `i32` values and is expected to signal back a single `i32` would have the type signature $cp from the definition:

```wasm
(rec
  (type $cp
    (stack (param i32) (param i32) (ref $co)))
  (type $co
    (stack (param i32) (ref $cp))))
```

All stack references participate in such recursively defined groups of types. The reason is straightforward: when switching from one coroutine to another, the default expectation is that the computation will eventually switch back. In general, the collection of messages between coroutines forms a closed conversation governed by a particular use case.

This is in recognition that, in many cases, the communication patterns between coroutines is _asymmetric_: one coroutine expects event descriptions that fit one type and its partner coroutines expect a different form of event description.

Stack references are single use: when used to switch to a coroutine the stack reference becomes invalid afterwards -- the engine is expected to trap if a stack reference is used twice.

Stack references are created in two circumstances: when a coroutine is created and when a coroutine is switched from. Stack references are also consumed in two ways: when used to switch to a coroutine, the target stack reference is used, and when a coroutine finally completes no new stack reference for the returning coroutine is created (i.e., null is sent as the return stack).

#### Type safety in switching

In order for a switch between coroutines to be valid, the type of the target stack reference must be consistent with the current state of the stack -- the value stack on the originating coroutine must be populated with the appropriate list of values corresponding to the parameters of the stack reference being used; in addition, the target coroutine must be _expecting_ the same set of values. These values are transferred during the switch. Both of these conditions can be verified at code validation time.

Given this, we can statically verify that WebAssembly programs that switch between coroutines are guaranteed to observe type safety during the switch.

#### Subtyping

Like function types, stack types are contravariant in their parameters.

```pseudo
C |- stack t_1* rt_1 <: stack t_2* rt_2
-- C |- t_2* rt_2 <: t_1* rt_1
```

`stack t_1 rt_1` is a subtype of `stack t_2* rt_2` iff:
 - `t_2* rt_2` is a subtype of `t_1* rt_1`.

The top type for stack references is `stack` and the bottom type is `nostack`. Like other bottom types, the nostack type is uninhabited.

```pseudo
absheaptype ::= ... | stack | nostack
```

### Life-cycle of a coroutine

A coroutine is allocated in the suspended state using the `stack.new` instruction. The initial `switch` to the newly allocated coroutine performs the equivalent of a function call on the new stack resource. In addition to the arguments provided to the `switch`, an additional argument is provided that is a stack reference to the caller code -- the caller is suspended as a result of the `switch` instruction.

During the normal execution of a coroutine, it is expected that it will switch to other coroutines using further `switch` instructions. It is only possible for a WebAssembly code to switch to a coroutine if the code has available to it the stack reference of the associated suspended coroutine.

This direct access aspect implies that higher-level programming language features that rely on dynamic scoping must be realized using other facilities of WebAssembly. For one such approach, we refer the reader to [this proposal](dynamic scoping url).

Eventually, the coroutine will be ready for termination; in which case it signals this by switching to another coroutine -- using the `switch_retire` instruction. This instruction is a `switch` instruction but it also results in the switching coroutine to become `moribund`; and the associated computation resources to become available for release.

Note that coroutine functions are _not_ permitted to return normally, nor are they permitted to abort by throwing exceptions. Returning from a coroutine, or allowing an exception to be propagated out, results in a trap.

>The primary justification for this is that the control flow patterns of switching coroutines do not typically embody a reasonable logical relationship that can be utilized when returning results. For example, a scheduler is responsible for ensuring the execution of one or more coroutines; but, schedulers are not typically interested in the _result_ of the computations of the coroutines they manage. Instead, return results (normal or exceptional) would typically be communicated to another coroutine – using normal switch_retire instructions.

#### The Life-cycle of a stack reference

Stack references identify coroutines that are in a suspended state. They are created as a coroutine becomes suspended when computation switches to a different coroutine. Stack references are consumed when the corresponding coroutine is switched to -- using a `switch` instruction.

Once a stack reference has been used to `switch` to its identified coroutine, it is no longer valid. Any attempt to switch to a stack reference that has already been used will result in a trap. Unfortunately, the design of WebAssembly means that it is not possible to statically validate that any given stack reference is actually valid -- it is the responsibility of the application program to ensure that stack references are used just once.

>It may seem that this can result in a large number of values being created and becoming garbage. However, stack references are implicitly references to the underlying stack resource which is _stable_ across the lifetime of the coroutine itself. Thus, one reasonable implementation strategy is to represent stack references as a pair: the stack resource and a counter. The counter -- which would also be stored in the stack resource -- is incremented every time the coroutine switches and is checked when the coroutine is switched to.
>
> Since the stack reference pair is never unpacked by WebAssembly code, it can be stored as a fat value in the value stack, in local variables, globals and in tables.[^shared]

[^shared]: This implementation strategy becomes more complex when threading is taken into account, and the possibility of shared stack references arise.

#### Coroutine identity

Coroutines do not have a specific identity in this proposal. Instead, a stack reference denotes the particular state of a suspended coroutine. This token is only created when switching from a coroutine or when a `stack.new` instruction is executed to create a new coroutine.

>It is not possible for WebAssembly code to discover which coroutine it is running on; indeed the currently active coroutine has no valid stack reference. One consequence of this design is that when a WebAssembly function calls another function from another module (say), that module cannot discover the identity of the coroutine and misuse it. Overall, this is in keeping with a capability-based approach to resource management.

In the rest of this document we introduce the key instructions, give some worked examples and answer some of the frequently asked questions.

## Instructions

We introduce instructions for creating, switching between, and retiring stacks.

### `stack.new` Create a new stack

```pseudo
  C |- stack.new x y : [] -> (ref x)
  -- expand(C.TYPES[x]) = stack t* rt
  -- expand(C.FUNCS[y]) = func t* rt -> []
```

`stack.new` takes two immediates: a type index `x` and a function index `y`. It is valid with type `[] -> (ref x)` iff:

 - The expansion of the type at index `x` is a stack type with parameters `t* rt`.
 - The expansion of the type of the function at index `y` is a function type `t* rt -> []`.

Let `f` be the function at index `y`. `stack.new` allocates a new suspended stack that expects to receive the arguments for `f`. Once the allocated stack is switched to, it will continue on to call `f` with the provided arguments and a reference to the previous active stack, or a null value if the previous active stack has been retired.

### `switch` Switch to a stack

```pseudo
  C |- switch x : t_1* (ref null x) -> t_2* rt
  -- expand(C.TYPES[x]) = stack t_1* (ref null? y)
  -- expand(C.TYPES[y]) = stack t_2* rt
```

`switch` takes one immediate: a type index `x`. It is valid with type `t_1* (ref null x) -> t_2* rt` iff:

 - The expansion of the type at index `x` is a stack type with parameters `t_1* (ref null? y)`.
 - The expansion of the type at index `y` is a stack type with parameters `t_2* rt`.

If its stack reference operand is null or detached, `switch` traps. Otherwise, `switch` switches to the stack denoted by its stack reference operand, popping and sending the expected values `t_1*` along with a reference of type `(ref y)` denoting the prior active stack. The parameters of the stack type at index `y` determine what types will be received when the prior active stack is switched back to.

> TODO: Describe checking whether a switch is allowed and trapping if it is not.

### `switch_retire` Switch to a stack and retire the old stack

```pseudo
  C |- switch_retire x : t_1* (ref null x) -> t_2*
  -- expand(C.TYPES[x]) = stack t_1* (ref null y)
```

`switch_retire` takes one immediate: a type index `x`. It is valid with type `t_1* (ref null x) -> t_2*` iff:

 - The expansion of the type at index `x` is a stack type with parameters `t_1* (ref null y)`.

`switch_retire` is very much like `switch`, except that it requires the target stack to be expecting a nullable stack reference and that instead of sending a reference to the previous active stack, it sends a null reference. This makes the previous active stack unreachable and potentially allows the engine to reclaim its resources eagerly. Since the previous active stack can never be resumed and the instructions following the `switch_retire` can never be executed, this instruction is valid with any result type.

### `stack.bind` Partial application of stack arguments

```pseudo
  C |- stack.bind x y : t_1* (ref null x) -> (ref y)
  -- expand(C.TYPES[x]) = stack t_1* t_2* rt
  -- epxand(C.TYPES[y]) = stack t_2* rt
```

`stack.bind` takes two immediates: type indices `x` and `y`. It is valid with type `t_1* (ref null x) -> (ref y)` iff:

 - The expansion of the type at index `x` is a stack type with parameters `t_1* t_2* rt`.
 - The expansion of the type at index `y` is a stack type with parameters `t_2* rt`.

 `stack.bind` takes a prefix of the arguments expected by a stack of type `x` as well as a reference to such a stack. It binds the provided arguments to the stack and returns a new stack reference to the same underlying stack, now expecting only the remaining, unbound arguments. Detaches all outstanding references to the stack.

> Note: `stack.bind` is implementable in userspace either by bundling the bound values with the continuation or by introducing intermediate stack types that allow the values to be bound incrementally over the course of multiple switches to the target stack.

## Examples

We look at three examples in order of increasing complexity and sophistication: a yield-style generator, cooperative threading and handling asynchronous I/O.

The objectives behind these examples are to demonstrate how common usage patterns may be implemented  and to exemplify how a compiler might target the features of this proposal.

### Yield-style generators

The so-called yield-style generator pattern consists of a pair: a generator function that generates elements and a consumer that consumes those elements -- the latter often taking the form of a `for`-loop. When the generator has found the next element it yields it to the consumer, and when the consumer needs the next element it waits for it. Yield-style generators represent the simplest use case for stack switching in general; which is why we lead with it here.

There are several potential styles of the generator pattern in source languages: the source language may provide special function forms for the generator expression; or the source language may permit _any_ higher-order function to act as the core of a generator, and simply pass a special yield function to that higher-order walker. Another approach, common in OO-style languages, is to use the iterator pattern. Our example will take its cue from the first style.

#### Communicating between the generator and its consumer

One problem that must be addressed by any language compiler that emits coroutining code is how to represent any events that may occur. In the case of the generator pattern, there are two kinds of events that need to be modeled: the generator needs to be able to signal individual data elements as they are generated and it needs to be able to signal the end of the stream. Conversely, the consumer needs to be able to ask for the next element; and, in some cases, the consumer needs to be able to _cancel_ the generator -- to ask it to stop producing values.

>The two sides of this conversation are not identical: the consumer sends control signals and the generator produces a stream of values. This asymmetry is prevalent in interactions amongst coroutines and is the main reason that the stack type structure has two type definitions.

For our yield-style generator example, we identify four different events, two originating from the generator and two from the consumer:

* `#yield <value>`. This event communicates a single data value from the generator, together with the encoding of the `#yield` code.

* `#end`. This communicates that there are no data values (left) to get from the generator.

>Note that the `#end` event only needs a single value to represent it; but, since the vector of values must have the same WebAssembly type for all kinds of messages from the generator, we will actually use two values: the encoding of `#end` and a dummy zero value.

* `#next`. This is a message from the consumer to the generator: to produce the next value.

* `#cancel`. This is a message from the consumer to cancel the generator.

The required set of messages can be modeled using a recursive pattern of stack types, as in the WebAssembly type declaration:

```wasm
(rec
  (type $genCmd (stack (param i32) (ref $genResp)))
  (type $genResp (stack (param i32) (param i32) (ref null $genCmd))))
```
where $genCmd has a single i32 which contains the command to the generator, and $genResp has two i32 elements, one encoding a response sentinel (e.g., #yield means there is a value and #end signals the end of the stream).

>Note that, for convenience, the sentinel in a response is the second of the two i32 values.

#### Generating elements of an array

In this example, we implement an extremely minimal generator: one which iterates over the elements of an `i32` array. The array is assumed to lie in linear memory, and we pass to the generator function the address of the base of the array, where to start the iteration and the number of elements in it:

```wasm
(rec
  ;; generic types for any generator of i32s
  (type $toConsumer (stack (param $val i32) (param (ref null $toGenerator))))
  (type $toGenerator (stack (param (ref $toConsumer))))
)

;; types to initialize the array generator specifically
(type $finishInit (stack (param (ref $toGenerator))))
(type $initArrayGen (stack (param $from i32) (param $to i32) (param $els i32) (param (ref $finishInit))))

(func $arrayGenerator (param $from i32) (param $to i32) (param $els i32) (param $finishInit (ref $finishInit))
  (local $toConsumer (ref $toConsumer))

  ;; switch back to the consumer now that $from, $to, and $els have been initialized.
  (switch $finishInitArrayGen (local.get $finishInit))
  (local.set $toConsumer)

  (block $on-end
    (loop $l
      (br_if $on-end (i32.ge (local.get $from) (local.get $to)))

      (switch $toConsumer             ;; load and yield a value to the consumer
        (i32.load (i32.add (local.get $els)
                           (i32.mul (local.get $from)
                                    (i32.const 4))))
        (i32.const 0)                 ;; not end
        (local.get $toConsumer))
      (local.set $toConsumer)         ;; remember the consumer

      ;; continue to the next element
      (local.set $from (i32.add (local.get $from) (i32.const 1)))
      (br $l)
    )
  ) ;; $on-end

  (switch_retire
    (i32.const 0)                     ;; dummy value
    (local.get $consumer))
)
```

Whenever the `$arrayGenerator` function yields after its initialization -- including when it finally finishes -- it returns three values: a new stack reference that allows the consumer to resume the generator, the value being yielded together with a sentinel which encodes whether this is a normal yield or the end of the generated elements.

When there are no more elements to yield, the `$arrayGenerator` issues the `switch_retire` instruction which simultaneously discards the generator's resources and communicates the end to the consumer by sending a null return stack reference. We also pass a dummy value of zero to comply with type safety requirements.

Whenever a `switch` instruction is used, it must be followed by instructions that store the return stack reference and use any sent values. In this example, the return stack reference is stored in the `$toConsumer` local variable, replacing its previous value which is no longer valid.

>There is one aspect of building a generator that is not addressed by our code so far: how to start it. We will look at this in more detail as we look at the consumer side of yield-style generators next.

#### Consuming generated elements

The consumer of a generator/consumer pair is typically represented as a `for` loop in high level languages. However, we need to go 'under the covers' a little in order to realize our example.

In WebAssembly, our `addAllElements` function creates the generator -- using the `stack.new` and `switch` instructions -- and employs a loop that repeatedly switches to it until the generator reports that there are no more elements. The code takes the form:

```wasm
(func $addAllElements (param $from i32) (param $to i32) (param $els i32) (result i32)
  (local $total i32) ;; initialized to 0
  (local $toGenerator (ref $toGenerator))

  ;; create the generator stack and switch to it with the initialization parameters.
  (switch $initArrayGen
    (local.get $from)
    (local.get $to)
    (local.get $els)
    (stack.new $initArrayGen $arrayGenerator))
  (local.set $toGenerator)

  (block $on-end
    (loop $l
      (switch $toGenerator (local.get $toGenerator))
      (br_on_null $on-end)     ;; check whether we have ended

      (local.set $toGenerator)  ;; remember the new generator reference

      ;; add the yielded value to the total
      (local.get $total)
      (i32.add)
      (local.set $total)
      (br $l)
    )
  ) ;; $on-end
  (local.get $total)
)
```

The loop uses a `br_on_null` instruction to determine when the generator has signaled the end by retiring and producing a null stack reference.

#### Simplifying initialization with `stack.bind`

Initializing the generator in this example required two stack switches and two additional stack types just to move the initialization values into the generator stack. This initialization can be simplified using the `stack.bind` instruction:

```wasm

;; no separate stack type necessary for finishing initialization.
(type $initArrayGen (stack (param $from i32) (param $to i32) (param $els i32) (param (ref $toConsumer))))

(func $arrayGenerator (param $from i32) (param $to i32) (param $els i32) (param $toConsumer (ref $toConsumer))

  ;; no switch necessary to finish initialization.

  (block $on-end ...
)

(func $addAllElements (param $from i32) (param $to i32) (param $els i32) (result i32)
  (local $total i32) ;; initialized to 0
  (local $toGenerator (ref $toGenerator))

  ;; create the generator stack and partially apply the initialization parameters.
  (stack.bind $initArrayGen $toGenerator
    (local.get $from)
    (local.get $to)
    (local.get $els)
    (stack.new $initArrayGen $arrayGenerator))
  (local.set $toGenerator)

  (block $on-end ...
)
```

#### Flattening Communication

The set of possible messages between coroutines is typically tied to the actual pattern being implemented: in this case we have a generator/consumer pair. But, in general, the messages form a _protocol_; typically, each message in a protocol will have different argument values with different types.

There are various options for modeling protocols more-or-less precisely. However, in those programming languages that support algebraic data types, we can use them as a kind of poor man's protocol description. We cannot easily use algebraic data types to capture the ordering of messages, however.

When implementing generators, it is quite important to perform as few allocations as possible (yield-style generators are effectively competing with java-style iterators and with normal inline while loops). So, for this example, we use a vector of values for each event description; where the one value is a sentinel -- encoded using the equivalent of an enumerated type --  and the remaining vector values depend on the event itself[^1].

[^1]: An alternate strategy could be to pass a pointer to a data structure describing the event. A toolchain might be able to avoid multiple allocations by reusing the data structure.

This strategy is effectively one of _flattening_ the type that represents the messages in the generator/consumer conversation into a vector of values. This involves determining the maximum number of values that may be communicated to/from a coroutine and _padding_ in the situations where the actual event does not need all the slots. Computing these vectors is the responsibility of the code generator.


### Cooperative Coroutines

Cooperative coroutines, sometimes known as _green threads_ or _fibers_, allow an application to be structured in such a way that different responsibilities may be handled by different computations. The reasons for splitting into such coroutines may vary; but one common scenario is to allow multiple tasks to proceed at their own pace.

In our formulation of fibers, we take an _arena_ based approach: when a program wishes to fork into separate fibers it does so by creating an arena or pool of fibers that represent the different activities. The arena computation as a whole only terminates when all of the fibers within it have completed. This allows a so-called _structured concurrency_ architecture that greatly enhances composability[^2].

[^2]: However, how cooperative coroutines are actually structured depends on the source language and its approach to handling coroutines. We present one alternative.

#### Structure of a Fiber

One can argue that the most salient aspect of a fiber, compared (say) to a generator/consumer pair, is the notion of _peristence_. A fiber has an identity that persists throughout the lifetime of the fiber. This is in direct tension with the nature of stack references.

The second architectural feature of fibers is the implied _scheduler_ or _arena_. An arena is responsible for managing a collection of fibers, and ensuring that each gets a reasonable chance at execution; typically realized via some form of scheduler.

A straightforward approach to modeling fiber identity is to capture it with a user data structure -- two fibers are considered the same if they have the same fiber structure. This would typically have a mutable field in it to hold the stack reference when the fiber is suspended, and which would be null in the case the fiber was active (or dead).

It is also likely that, in practice, a language runtime would include other language specific information in the same data structure: access to fiber-local variables is an obvious example. However, we will assume a minimal structure that has two fields in it:

```wasm
(type $fiber (struct
  (field $stack mut (ref null $fiberCont))
  (field $arena (ref $arena))
))
```

A scheduler needs to be able to select which of its fibers to execute next. It also needs to be able to inform its fibers whether they are being resumed normally, or are being canceled.

Similarly, a fiber needs to communicate to its scheduler why it is yielding to the scheduler: it may be reporting success, an exception, or simply yielding. A final category of communication from the fiber is ‘yield with a reason’; such as when the fiber is requesting asynchronous I/O or a delayed timer.

Together, these messages form the fiber protocol.

In our example, we are going to assume that the only messages that a scheduler is expected to understand (from its managed fibers) are #pause, #terminate.[^wake] The assumption is that other messages are really directed to other fibers and not to the scheduler itself (and therefore will use different mechanisms).

[^wake]: A slightly fuller exposition would typically also include a #wake command to allow a fiber to request that a given sibling be scheduled. We omit this for the sake of brevity.

Conversely, a scheduler has one of two messages to send to its fibers: #resume and #cancel.

We can model this pattern of communication using the following type declaration:

```wasm
(rec
  (type $sched (stack (param i32) (ref $fbr)))
  (type $fbr (stack (param i32) (ref null $sched)))
)
```

where we also define the constants in the enumerations:

```c
typedef enum{
  pause = 0,
  terminate = 1
} fbrCmd;

typedef enum{
  resume = 0,
  cancel = 1
} arenaCmd
```

#### Running Fibers

The WebAssembly implementation of `#pause` has two pieces: switching to the arena and maintaining the fiber structure so that the fiber can be resumed later on. Given that the fiber’s stack will not be available until after the switch to the scheduler, this means there are two parts to the code: one executed by the fiber and the other by the scheduler.

The $pause function below is given a reference to the currently running fiber structure, and, we assume, that the arena is also modeled as a fiber (accessed from the $fiber structure):

```wasm
(func $pause (param $fiber (ref $fiber))
  (local $cmd i32)
  (local.get $fiber)
  (struct.get $fiber $arena)
  (struct.get $arena $arenaCont)
  (i32.const #pause)
  (switch $fbr) ;; Switch to scheduler
  (local.set $cmd)    ;; Decode why we are being woken up
  (struct.get $fiber $arena)
  (struct.set $arena $arenaCont) ;; update arena’s stack
  (local.get $cmd)    ;; return resume or cancel signal
  (return)
)
```

As can be seen, most of this code is simply accessing structures and updating them. In this case, `$pause` has to access the arena's stack, and update it when the fiber is resumed by the arena scheduler. Similarly, the arena has to manage the fiber's data structure:

```wasm
  ...
  (local.get $resumee)    ;; the fiber we are going to resume
  (local.get $resumee)    ;; we need it twice
  (struct.get $fiber $stack)
  (i32.const #resume)     ;; we are resuming the fiber
  (switch $sched)
  (if                     ;; What did the fiber sent us
    (struct.set $fiber $stack)
  else
    ...                   ;; kill off the fiber
  end)
  ...
```

This is not a complete function: we are just highlighting that part of the arena scheduler that is relevant to resuming a fiber. Apart from the manipulation of data structures, perhaps the most salient aspect of this code is an apparent inversion: the arena code is responsible for managing the storage of its client fibers, and the fiber is responsible for keeping track of the arena's stack. This is a result of computations not being able to address themselves -- of the active coroutine not having a 'pointer to itself'.

It also implies that the design of functions such as `$pause` is fundamentally intertwined with that of the fiber's arena scheduler. However, the combination of a scheduler, a suite of library functions giving fibers capabilities, results in a complete package.

#### A Fiber Function

Given this, we can give a more complete example, building on the generator example above. This example uses fibers to split processing an array into segments: each fiber is responsible for adding up the elements of its segment.[^proxy]

[^proxy]: This example is intended to serve as a proxy for a much more realistic situation: collecting multiple resources by splitting each into a separate task.

Like stack functions, fiber functions have an extra argument: which is a reference to the `$fiber` structure.

```wasm
(func $adderFiber (param $arena (ref $fiber))
   (param $els i32) (param $from i32) (param $to i32)
   (return i32)
  (local $total i32)

  (switch $genResp
    (local.get $els)
    (local.get $from)
    (local.get $to)
    (stack.new $genResp $arrayGenerator))

  (block $on-end
    (loop $l
      (block $on-yield ((ref $genResp) i32) ;; 'returned' by the generator
        (br_table $on-yield $on-end)  ;; dispatch on sentinel
      ) ;; the stack contains the generator and the yielded value
      (local.get $total)               ;; next entry to add is already on the fiber
      (i32.add)
      (local.set $total)
      (local.set $generator)           ;; store the generator reference that came back
      (switch $genResp
        (local.get $generator)
        (i32.const 0)                  ;; padding
        (i32.const #next))
      (local.get $fiber)
      (call $pause)                    ;; pause returns zero if we continue
      (if (br $on-end) (br $l))
    ) ;; fiber loop
  )
  (switch_retire   ;; report total to arena
    (local.get $fiber)
    (struct.get $fiber $arena)
    (local.get $total)
    (i32.const #terminate)
  ) ;; unreachable
)
```

#### Managing Tasks in an Arena

The core principle of structured concurrency is the same single entry/single exit principle behind structured programming: a group of concurrent activities (a.k.a. tasks) arranged into an _arena_ which is not terminated until its component tasks are accounted for.[^newtask] An arena denotes a set of computations that have some application-related role: i.e., the arena embodies a set of _tasks_.

[^newtask]: In addition, to be consistent, any _new_ computations started are always associated with an arena.

There are several legitimate varieties of arenas: in one scenario, all the tasks are _competing_ and the first one that completes results in all the others being canceled. Another common pattern involves the arena completing only when all the tasks have completed.

This arena takes an array of fibers and terminates when the first one ends:

```wasm
(type $fiberArray (array (ref $fiber)))

(func $cancelingArena (param $fibers (ref $fiberArray))
  (result i32)
  (local $ix i32 (array.len (local.get $fibers)))
  (local $jx i32)
  (loop $l
    (local.set $ix (i32.const 0))
    (loop $for_ix
      (block $on-endGreen (i32)
        (block $on-pauseGreen
          (switch $fbr
            (array.get $fibers
              (local.get $fibers) (local.get $ix)) ;; pick up fiber
            (struct.get $fiber $fiberCont)
            (i32.const #resume)) ;; Our message is 'go'
          (br-table $on-pauseGreen $on-endGreen)
        )
        (local.set $ix
          (i32.add
            (local.get $ix)
            (i32.const 1)))
        (array.get $fibers (local.get $fibers) (local.get $ix)) ;; pick up the fiber again
        (struct.set $fiber $fiberCont)                          ;; update fiber structure
        (br_if $for_ix (i32.ge (local.get $ix) (local.get $len)))
      )
      (local.set $total
        (i32.add
          (local.get $total)))
      (local.set $jx (i32.const 0))
      (loop $for-jx
        (block $no-cancel
          (br_if $no_cancel
            (i32.eq
              (local.get $ix)
              (local.get $jx)))
          (switch $fbr
            (array.get $fibers
              (local.get $fibers) (local.get $ix)) ;; pick up fiber
            (struct.get $fiber $fiberCont)
            (i32.const #cancel)) ;; Our message is 'stop'
          drop
          drop
          drop ;; drop the results from this cancelation
        )
        (local.set $jx
          (i32.add
            (local.get $jx)
            (i32.const 1)))
        (br_if $for_jx
          (i32.lt (local.get $jx) (local.get $len)))
      )
      (local.get $total)
      return
    )
  )
)
```

Although we are using structure and array concepts which are part of WasmGC, it would be straightforward -- if a little tedious -- to use tables and linear memory to store the relevant structures needed to support fibers.

### Asynchronous I/O

In our third example, we look at integrating coroutines with access to asynchronous APIs; which are accessed from module imports.

On the web, asynchronous functions use the `Promise` pattern: an asynchronous I/O operation operates by first of all returning a `Promise` that 'holds' the I/O request, and at some point after the I/O operation is resolved a callback function attached to the `Promise` is invoked.[^other]

[^other]: While non-Web embeddings of WebAssembly may not use `Promise`s in exactly the same way, the overall architecture of using promise-like entities to support async I/O is widespread.
  One specific feature that may be special to the Web is that it is not possible for an application to be informed of the result of an I/O request until after the currently executing code has completed and the browser's event loop has been invoked.

#### JavaScript Promise Integration

The JavaScript Promise Integration API (JSPI) allows a WebAssembly module to call a `Promise`-returning import and have it result in the WebAssembly module being suspended. In addition, calling into a marked export converts the normal return convention into a `Promise`-based convention: instead of returning the result indicated by the WebAssembly function, the marked function returns a `Promise`. This is `resolved` if the function returns normally (presumably after suspending at least once); if the function throws an exception, that exception is transmuted to a `reject` of the `Promise`.

In normal mode, JSPI operates on the entire call chain -- between the call to the WebAssembly module itself and the call to a `Promise`-bearing import. It assumes that the WebAssembly code is synchronous in nature. However, what happens when your language already has coroutines?

#### Our Scenario

We would like to enable applications where several coroutines can make independant requests to a `fetch` import and only 'return' when we have issued them all. Specifically, our example will involve multiple tasks -- modeled using fibers -- making `fetch` requests and responding when all the requests complete.

This implies a combination of local scheduling of tasks, possibly a _tree_ of arenas reflecting a hierarchical structure to the application.

#### A `fetch`ing Task

On the surface, the code for `fetch`ing data is very simple:[^async-c]

```c
async fetcher(string url){
  string text = await simple_fetch(url);
  doSomething(text);
}
```

[^async-c]: In an extension to the C language, we have invented a new type of function--the `async` function. In our mythical extension, only `async` functions are permitted to use the `await` expression form.

#### Importing `fetch`

The actual `fetch` Web API is quite complex; and we do not intend to explore that complexity. Instead, we will use a simplified `simple_fetch` that takes a url string and returns a `Promise` of a `string`. (Again, we ignore issues such as failures of `fetch` here.)

JSPI works by wrapping imports to functions that suspend. More accurately, a marked import uses a different calling convention: when the callee returns – with a Promise – the calling computation is suspended. Whe Promise is ultimately resolved, the then function that is attached to the Promise is called by the task runner. That then function resumes the suspended computation, passing it the revolved value of the Promise

Balancing these suspending imports is a Promising export: we mark one or more exports as promising. This affects how the export is invoked: it is executed on a separate stack. This is the stack that is suspended when the import is called; and resumed when the Promise is resolved.

>The exports are marked as Promising because the original is wrapped into a function that returns a Promise, which is resolved by the value originally returned from the export.

Our goal is to achieve similar functionality to JSPI, but to allow the application to continue in some fashion when calling a suspending import.

This pseudo code describes a function that calls a ‘raw’ fetch function, and suspends back to the arena scheduler with an #ioPause request – sending the Promise from the simpleFetch.

```pseudo
func callSimpleFetch(f:Fiber,u:Url):
  p: Promise = simpleFetch(u);
  f.suspend(#ioPause(p));
  return p.value
```

#### Trees of schedulers

In a complete application, there will likely be a tree of schedulers; each scheduler must also yield to it’s parent arena scheduler: this is the primary route by which the WebAssembly application as a whole can eventually yield back to the browser’s event loop.

When, finally, the application does ‘return’ to the event loop, it must be the case that all the schedulers in tree – and all the fibers referenced from all the schedulers – are suspended.

Ultimately, the application will be reentered when one of the Promises has been resolved and the event loop invokes the appropriate fiber. This must be handled with some care to avoid creating issues with the hierarchy of arena schedulers. In effect, the tree of schedulers will need to be re-awoken in the correct order so that each client fiber has access to its own scheduler in a valid state.

One way to achieve this is for each arena scheduler to keep track of any Promises its client fibers create and, when it yields to its parent, create a special composite Promise consisting of an array of client Promises. This allows the tree to be correctly woken up when a client Promise is resolved.

We do not claim that this is the only way of managing the asynchronous activities; indeed, individual language toolchains will have their own language specific requirements. However, this example is primarily intended to explain how one might implement the integration between WebAPIs such as `fetch` and a coroutining aware programming language.

## Frequently Asked Questions

### What is the difference between this proposal and the 'typed continuations' proposal?

This proposal shares some common elements with the typed continuations proposal: for example, we have statically typed first class continuations – called stack references in this proposal.

However, this proposal is significantly simpler also. There is no built-in mechanism for searching for effect handlers, there is no built-in mechanism for maintaining a suspend/resume relationship, there is no mechanism for automatic propagation of results, and there is no built-in mechanism for implementation dispatch when a stack is re-entered.

The reasoning behind this 'concept shedding' is straightforward: we have tried to focus on the essential features that _all_ language providers will need to support _their own_ models of concurrency.

On the other hand, in many realistic situations, higher-level abstractions are still required. We saw this with the [API](#a-fibers-api) that allowed us to model with long running computations as opposed to instantaneous snapshots. Using WebAssembly to realize this abstraction is also important: higher-level abstractions are often also less universal.

### How do coroutines relate to the JS Promise integration API?

JSPI focuses on the behavior of the whole application: it is targeted at enabling so-called legacy code (which is not aware of asynchronous computation) to access many of the Web APIs which are fundamentally asynchronous in nature.

Internally, the implementation of JSPI requires many if not most of the techniques needed to support coroutines; however, this is largely hidden from the developer using JSPI.

JSPI can be used to implement coroutine language features. However, this carries significant performance penalties as each time an application suspends using JSPI, it will not be re-entered until the brower’s task runner invokes the associated Promise’s then function. This effectively eliminates one of the key benefits of coroutines: of allowing an application to manage and schedule its own computations.

A legitimate question remains of whether it is possible to polyfill JSPI in terms of coroutines. It definitely is possible to do so, albeit involving substantial amounts of extra JavaScript and WebAssembly code.

### What other instructions might we want to include in this proposal?

We may choose to add other instructions to the proposal to round out the instruction set or if there is specific demand for them. Potential additions include:

 - `stack.new_ref`: a variant of `stack.new` that takes a function reference operand instead of a function index immediate. The latter instructions can be specified in terms of the `*_ref` variants, but the `*_ref` variants would be less efficient in real implementations.
 - `switch_throw`: Switch to a stack and throw an exception rather than sending the expected values. This can instead be accomplished by sending a sentinel value that informs the recipient that it should throw an exception itself, but `switch_throw` would be more direct.
 - `return_switch`: Combines a `return_call` with a stack switch. Returns out of the current frame, switches to another stack, and calls into a new function once control returns to the original stack. This may end up being useful in combination with shared-everything threads, where creating shareable stack references would require careful management of the kinds of frames on the stack.
 - `return_switch_throw`: Combines both of the above.

### Why are we using 'lexical scoping' rather than 'dynamic scoping'

A key property of this design is that, in order for a WebAssembly program to switch between coroutines, the target of the switch is explicitly identified. This so-called lexical scoping approach is in contrast with a dynamic approach -- commonly used for exception handling -- where the engine is expected to search the current evaluation context to decide where to suspend to (say).

#### Implementation

In a lexically-scoped design, the engine is explicitly told by the program where to transfer control to.
Thus, the only additional obligation the engine has to implement, besides the actual transfer of control, is validation that the target is _valid_ from the current control point.

In a dynamically-scoped design, the engine has to search for the transfer target. This search is typically not a simple search to specify and/or implement since the _criteria_ for a successful search depends on the language, both current and future.

By requiring the program to determine the target, the computation of this target becomes a burden for the toolchain rather than for the WebAssembly engine implementor.

#### Symmetric coroutining (and its cousin: task chaining)

With symmetric coroutines you can have a (often binary) collection of coroutines that directly yield to each other via application-specific messages. We saw a simple example of this in our [generator example](#generating-elements-of-an-array).

Similar patterns arise when chaining tasks together, where one computation is intended to be followed by another. Involving a scheduler in this situation creates difficulties for types (the communication patterns between the tasks is often private and the types of data are not known to a general purpose scheduler).

A lexically-scoped design more directly/simply/efficiently supports these common horizonal control-transfer patterns than a dynamically-scoped design which would typically bake in a parent scheduler.

#### Composing Components

In applications where multiple _components_ are combined to form an application the risks of dynamic scoping may be unacceptable. By definition, components have a _shared nothing_ interface where the only permitted communications are those permitted by a common _interface language_. This includes prohibiting exceptions to cross component boundaries--unless via coercion--and switching between tasks.

By requiring explicit identification of the target of a switch we make the task (sic) of implementing component boundaries more manageable when coroutining is involved. In fact, this is envisaged in the components design by using _streaming_ and _future_ metaphors to allow for this kind of control flow between components.

In addition, due to a focus on stack references, it is only possible for one component to be aware of coroutines in another component if they are given explicit access to them (by passing them as arguments of functions for example). Furthermore, since a stack reference is inherently single use, there is reduced risk of _leakage_ across the component boundary.

Finally, since the active component does not have a valid stack reference. So, calling a function (across a component boundary) cannot result in the current coroutine's identity being discovered by the callee. This enhances the security boundary between components.

#### Dynamic Scoped extensions to WebAssembly

However, in a [companion proposal](), we explore a simple extension to WebAssembly that can be efficiently realized and that brings a dynamic scoping mechanism to WebAssembly. The two proposals are separate, but their combination can be used to realize a dynamically scoped effect handler scenario.

### How are exceptions handled?

One popular feature of exception handling systems is that of _automatic exception propagation_; where an exception is automatically propagated from its point of origin to an outer scope that is equipped to respond to it. However, this policy is generally incompatible with many forms of coroutining.

The reason is that, when a coroutine is resumed, it may be from a context that does not resemble the context when it was executing previously; indeed it may be resumed from a context that cannot handle any application exceptions.

This happens today in the browser, for example. When a `Promise`'s callback revolved and/or reject functions are called, it is typically from the context of the so-called microtask runner. The micro task runner cannot handle results from tasks it runs; instead, the convention is to map results into calls to the relevant callback function of the appropriate `Promise` chain. If that chain does not exist, the task runner simply drops results, exceptional or not.

This, in turn, implies that application specific actions need to be taken when any exception is bubbling out of a coroutine. In general, we expect a great deal of variability in how results are transmitted from coroutines, and, as a result, choose not to specify any automatic propagation mechanism.

So, in this proposal, results do _not_ propagate out of a coroutine. Instead, the application uses the `switch_retire` instruction to simultaneously terminate and send a final result to a coroutine that can take responsibility for the result. In the case of exceptions, one pattern that may apply is for the coroutine function to catch exceptions not handled by the application logic. This would then result in a message to another coroutine; which may rethrow the exception in that coroutine. The key here is that this routing logic is application or language specific: it is not mandated by the engine.

### What about structured concurrency?

As we noted above, structured concurrency is an approach to managing concurrent applications; one that enforces the equivalent of the single entry/single exit control flow property from structured programming. However, there are many other patterns of coroutining possible. Some languages, for example, stipulate a single global coroutine scheduler and do not support hierarchies of arena managers.

On the other hand, if a WebAssembly application is constructed from multiple languages, then across multiple component boundaries, it is highly likely that such systems would have multiple schedulers. Furthermore, in the context of a Web browser, these schedulers will be forced to work together: a given language scheduler will be required to yield to other schedulers if they want to resolve their asynchronous I/O results.

Structured concurrency is not built-in to our proposal. However, it is straightforward for a toolchain to generate patterns such as the arena pattern we illustrated [above](#cooperative-coroutines). It is our opinion that this degree of choice is advisable in order to avoid unnecessary obstacles in the path of a language implementer.

### How does one support opt-out and opt-in?

The only way that a suspended computation can be resumed is if one has access to its stack reference. As such, opt-out is extremely straightforward: simply do not allow code to become aware of the stack reference.

Supporting full opt-in, where only specially prepared code can switch, and especially in the so-called _sandwich scenario_ is more difficult. If a  module invokes an import that reconnects to the module via another export, then this design will allow code to invoke switching patterns without being explicitly enabled.

It is our opinion that the main method for preventing the sandwich scenario is to prevent modules that do not support switching from importing functions from suspending modules. Solutions to this would have greater utility than preventing abuse of suspendable computations; and perhaps should be subject to a different effort.

### How are different patterns combined?

A given fragment of code may be involved with more than one coroutining pattern. We saw a simple example of this [here](#cooperative-coroutines). It is straightforward to combine scenarios when one considers that each is distinguished by its own protocol.

For example, most implementations of the generator pattern will not also be an implementation of the green thread pattern; and conversely, all the suspended green threads that a fiber scheduler is managing will be waiting for a go signal from the scheduler: they will not be waiting in the queue for the next yielded element from a generator.

It is much more likely that different patterns will also be distinguished by separate suspension points and switching targets: A single switching target denotes a point in a conversation, different conversations will not intersect around any single switching location.

Pragmatically, what this means is that each coroutining conversation that a given code is involved with will be 'represented' by a different target. If a code is both part of a generator/consumer pair and is a green thread, then, when pausing as a green thread, the scheduler target (i.e., the scheduler's stack reference) will be identified as the target of the switch. When yielding a value (say), the code will reference the consumer's stack reference. At no point is any given stack reference part of more than once coroutining conversation.

### How are event descriptions represented?

Event descriptions are the data packages that are exchanged when switching from one coroutine to another. For any given coroutining conversation, the space of such event descriptions is likely to be fixed by the designers of the conversation. In such a case, the set of possible event descriptions can often be modeled in terms of an _algebraic data type_ i.e., a sum of possible data values.

WebAssembly does not, at this time, directly support algebraic data types. However, they can be _realized_ in a number of ways. The approach that we have been following in this design is one of _flattening_: we unpack all the possible argument data elements into a vector of values and then use a _discriminator_ value to signal which case is actually involved.

There are two immediate consequences of this: we have to arrange for the vector of values to be large enough to encompass all the possible elements, and for any given event description there may be unused spaces in the vector. This last aspect may require the implementer to use slightly more general types than they otherwise would: for example, to use a nullable type where that may not be implied by the application logic.

However, in practice, we don't anticipate that this wastage will be significant. This is, in part, because there is another strategy available to the implementer where this flattening approach does not work: boxing. In a boxed approach, the event description consists of a single value: a pointer to the event description; and it is up to the application code to construct the event description and to decode it as appropriate.

For those scenarios that are more dynamic in nature: where it is not possible to predict, at compile-time, the contents of the event description, some form of boxing is likely to be necessary when using this design. However, in the future, some form of algebraic data type capability may be added to WebAssembly; in which case, such a capability could be used to advantage for communicating event descriptions.

### How can this proposal be implemented?

Implementing this proposal in a production engine raises some issues: how are stack references (and any underlying resources) managed, how to manage the sizes of the stack memories, how to integrate stack switching with accessing 'external' functions that may make special assumptions about the stack memory they use, and how to ensure performant implementations of the key operations. Many of these concerns arise from the fact that most language runtimes were not crafted with coroutining in mind.

#### Growing stacks

When a new coroutine is established, using the `stack.new` instruction, the engine must also allocate memory to allow the stack frames of functions to be stored. Normally, we expect the `stack.new` instruction to result in a new stack allocation and for subsequence function calls to be executed on this new stack memory. This allows for a rapid switch between coroutines since we can switch simply by ensuring that the `SP` register of the processor points to the new target.

The engine also has to decide how much memory to allocate, and there also needs to be a strategy for dealing with the case when that memory is exhausted. The primary issue here is to determine how much memory to allocate for the newly created stack. It is not feasible in many cases to allocate a large block for each coroutine: if an application uses large numbers of coroutines then this can result in a lot of wasted memory. In addition, it is quite likely that most coroutines will have very small memory requirements; and only a few needing larger memories.

However, given the capability for switching between coroutines, it is quite conceivable to allow stacks to be automatically grown when their stack memory is exhausted. This could be by creating a new larger memory and copying an existing stack resource into it; or it could be by allowing execution stacks to be segmented.

Which approach is taken depends on the larger requirements of the WebAssembly engine itself.
