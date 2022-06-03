# Task Oriented Stack Switching

## Motivation

Non-local control flow (sometimes called _stack switching_) operators allow applications to manage their own computations. Technically, this means that an application can partition its logic into separable computations and can manage (i.e., schedule) their execution. Pragmatically, this enables a range of control flows that include supporting the handling of asynchronous events, supporting cooperatively scheduled threads of execution, and supporting yield-style iterators and consumers.

This proposal refers solely to those features of the core WebAssembly virtual machine needed to support non-local control flow and does not attempt to preclude any particular strategy for implementing high level languages. We also aim for a minimal spanning set of concepts: the author of a high level language compiler should find all the necessary elements to enable their compiler to generate appropriate WebAssembly code fragments.

## Tasks and Events

The main concepts in this proposal are the _task_ and the _event_. A task is a first class value which denotes a computation. An event is used to signal a change in the flow of computation from one task to another. 

### The `task` abstraction

A `task` denotes a computation that has an extent in time and may be referenced. The latter allows applications to manage their own computations and support patterns such as asynch/await, green threads and yield-style generators. 

Associated with tasks are a new type:

```
taskref
```
which denotes tasks.

Notice that our `taskref` type is not qualified: tasks are not expected to return in the normal way that functions do. We explore this topic again in [Frequently Asked Questions](#frequently-asked-questions).


#### The state of a task

A task is inherently stateful; as the computation proceeds the task's state reflects that evolution. The state of a task includes function call frames and local variables that are currently live within the computation as well as whether the task is currently being executed.

However, apart from when a significant event occurs within the computation, the state of a task is not externally visible.

In our descriptions of task states it is convenient to identify an enumerated symbol that denotes the execution state of the task:

```
typedef enum{
  suspended,
  active,
  moribund
} TaskExecutionState
```

Only tasks that are in the `active` state may be suspended, and only tasks that are in the `suspended` state may be resumed. `moribund` tasks are those that are no longer capable of execution but may still be referenced in some way. The execution state of a task is not directly inspectable by WebAssembly instructions.

#### Tasks, anscestors and children

It is convenient to identify some relationships between tasks: the parent of a task is the task that most recently resumed that task. 

The root of the ancestor relation is the _root task_ and represents the initial entry point into WebAssembly execution.

The root task does not have an explicit identity. This is because, in general, child tasks cannot manage their ancestors.

### The `event` abstraction

An event is an occurrence where computation switches between tasks. Events also represent a communications opportunity between tasks: an event may communicate data as well as signal a change in tasks.

#### Event declaration
An event has a predeclared `tag` which determines the type of event and what values are associated with the event. Event tags are declared:

```
(tag $e (param t*))
```
where the parameter types are the types of values communicated along with the event. Event tags may be exported from modules and imported into modules.

Every change in computation is associated with an event: whenever a task is suspended, the suspending task uses an event to signal both the reason for the suspension and to communicate any necessary data. Similarly, when a task is resumed, an event is used to signal to the resumed task the reason for the resumption.

## Instructions

We introduce instructions for managing tasks and instructions for signalling and responding to events.

### Task instructions

#### `task.new` Create a new task

The `task.new` instruction creates a new task entity. The instruction has a literal operand which is the index of a function of type `[taskref t*]->[]`, together with corresponding values on the argument stack.

The result is a `taskref` which is the identifier for the newly created task. The identity of the task is also the first argument to the task function itself&mdash;this allows tasks to know their own identity in a straightforward way.

The task itself is created in a `suspended` state: it must be the case that the first executable instruction in the function body is an `event.switch` instruction.

#### `task.suspend` Suspend an active task

The `task.suspend` instruction takes a task as an argument and suspends the task. The identified task must be in the `active` state&mdash;but it need not be the most recently activated task: it may be an ancestor of the most recent task. The _root_ ancestor task does not have an explicit identifier; and so it may not be suspended.

All the tasks between the most recently activated task and the identified task inclusive are marked as `suspended`.

`task.suspend` has two operands: the identity of the task being suspended and a description of the event it is signaling: the `event` tag and any arguments to the event. The event operands must be on the argument stack.

The instruction following the `task.suspend` must be an `event.switch` instruction.

#### `task.resume` Resume a suspended task

The `task.resume` instruction takes a task as argument, together with an `event` description&mdash;consisting of an event tag and possible values, and resumes its execution.

The `task.resume` instruction takes a `suspended` task, together with any descendant tasks that were suspended along with it, and resumes its execution. The event is used to encode how the resumed task should react: for example, whether the task's requested information is available, or whether the task should enter into cancelation mode.

#### `task.switchto` Switch to a different task

The `task.switchto` instruction is a combination of a `task.suspend` and a `task.resume` to an identified task. This instruction is useful for circumstances where the suspending task knows which other task should be resumed.

The `task.switchto` instruction has three arguments: the identity of the task being suspended, the identity of the task being resumed and the signaling event.

Although it may be viewed as being a combination of the two instructions, there is an important distinction also: the signaling event. Under the common hierarchical organization, a suspending task does not know which task will be resumed. This means that the signaling event has to be of a form that the task's manager is ready to process. However, with a `task.switchto` instruction, the task's manager is not informed of the switch and does not need to understand the signaling event.

This, in turn, means that a task manager may be relieved of the burden of communicating between tasks. I.e., `task.switchto` supports a symmetric coroutining pattern. However, precisely because the task's manager is not made aware of the switch between tasks, it must also be the case that this does not _matter_; in effect, the task manager may not directly be aware of any of the tasks that it is managing.  

#### `task.retire` Retire a task

The `task.retire` instruction is used when a task has finished its work and wishes to inform its parent of any final results. Like `task.suspend` (and `task.resume`), `task.retire` has an event argument&mdash;together with associated values on the agument stack&mdash; that are communicated.

In addition, the retiring task is put into a `moribund` state and any computation resources associated with it are released. If the task has any active descendants then they too are made `moribund`.

#### `task.release` Destroy a suspended task

The `task.release` instruction clears any computation resources associated with the identified task. The identified task must be in `suspended` state.

If the suspended task has current descendant tasks (such as when the task was suspended), then those tasks are `task.release`d also.

Since task references are wasm values, the reference itself remains valid. However, the task itself is now in a `moribund` state that cannot be resumed.

The `task.release` instruction is primarily intended for situations where a task manage needs to eliminate unneeded task and does not wish to formally cancel them.

### Event Instructions

The main event instruction is `event.switch`; which is used to react to an event.

#### `event.switch`

The `event.switch` instruction takes a list of pairs as a literal operand. Each pair consists of the identity of an event tag and a block label.

If an event is signaled that is not in the list of event/label pairs then the engine traps: there is no fall back or stack search implied by this instruction.

If an event is signaled for which there is an event label in the list, then it must also be the case that the top n elements of the argument stack are present and are of the right type. This is validated by a combination of the event declaration and the type signatures of the identified blocks[^2].  If there is a mismatch in type expectations, then the module does not validate.

[^2]: If there are more types in the block's result type, then those must correspond to elements of the input of that block.

## Examples

We look at three examples in order of increasing complexity and sophistication: a yield-style generator, cooperative threading and handling asynchronous I/O.

### Yield-style generators

The so-called yield style generator pattern consists of a pair: a generator function that generates elements and a consumer that consumes those elements. When the generator has found the next element it yields it to the consumer, and when the consumer needs the next element it waits for it. Yield-style generators represents the simplest use case for stack switching in general; which is why we lead with it here.

#### Generating elements of an array
We start with a simple C-style pseudo-code example of a generator that yields for every element of an array:

```
void arrayGenerator(task *thisTask,int count,int els){
  for(int ix=0;ix<count;ix++){
    switch(yield(thisTask,els[ix])) {
      case next:
        continue;
    }
  }
  end(thisTask); // Signal an end to the generation
}
```
In WebAssembly, this becomes:
```
(tag $yield (param i32))
(tag $next)
(tag $end-gen)

(func $arrayGenerator (param $thisTask taskref) (param $count i32) (param $els i32)
  (block $on-init
    (event.switch ($next $on-init))
    (unreachable)
  )
  (local $ix i32)
  (local.set $ix (i32.const 0))
  (loop $l
    (local.get $ix)
    (local.get $count)
    (br_if $l (i32.ge (local.get $ix) (local.get $count)))
    
    (block $on-next ;; set up for the switch back on next
      (task.suspend (local.get $thisTask) ($yield 
          (i32.load (i32.add (local.get $els) (local.get $ix)))))
      (event.switch ($next $on-next))
    )
    (local.set $ix (i32.add (local.get $ix) (i32.const 1)))
    (br $l)
  )
  ;; set up for return
  (task.retire (local.get $thisTask) ($end-gen))
  (unreachable)
)
```
When a task suspends, it must be followed by a `event.switch` instruction; furthermore, the instruction immediately following the `event.switch` instruction is unreachable&mdash;an artifact of WebAssembly's way of structuring switch statements. The `event.switch` instruction is used by the task to determine how to respond to the resume event when the task is resumed.

In the case of the `$arrayGenerator`, it is always waiting for an `$on-next` event to trigger the computation of the next element in the generated sequence. If a different event were signaled to the generator the engine will simply trap.

The beginning of the `$arrayGenerator` function is marked by a block of code that looks like the function is waiting for an `$on-next` event. This is because, when a new task is created, it is in an initially suspended state; and we are also required to ensure the invariant that suspended tasks are waiting for an event to occur. Creating tasks in suspended state ensures that the function that creates a task has the necessary opportunity to appropriately record the identity of the new task without it executing any code.

Notice that the array generator has definite knowledge of its own task&mdash;it is given the identity of its task explictly. This is needed because when a task suspends, it must use the identity of the task that is suspending. There is no implicit searching for which computation to suspend.

The end of the `$arrayGenerator`&mdashwhich is triggered when there are no more elements to generate&mdash;is marked by the use of `task.retire`. This will terminate the task and also signal to the consumer that generation has finished by signaling a `$end-gen` event.

#### Consuming generated elements
The consumer side of the generator/consumer scenario is similar to the generator; with a few key differences:

* The consumer drives the overall choreography
* The generator does not have a specific reference to the consumer; but the consumer knows and manages the generator. 

As before, we start with a C-style psuedo code that uses a generator to add up all the elements generated
```
int addAllElements(int count, int els[]){
  task *generator = task(arrayGenerator,count,els);
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
  (local $generator (task.new $arrayGenerator (local.get $count) (local.get $els)))
  (local $total i32)
  (local.set $total i32.const 0)
  (loop $l
    (block $on-end
      (block $on-yield (i32) ;; 'returned' by the generator when it yields the next element
         (task.resume (local.get $generator) ($next ))
         (event.switch ($yield $on-yield) ($end $on-end))
      )
      (local.get $total) ;; next entry to add is already on the stack
      (i32.add)
      (local.set $total)
      (br $l)
    ) ;; ending the iteration
    (local.get $total)
    (return)
  )
  (unreachable)
)       
```
Since `$addAllElements` is likely not itself a task, we do not start it with a blocking preamble&mdash;as we had to do with the generator.

The structure of the consumer takes the form of an unbounded loop, with a forced termination when the generator signals that there are no further elements to generate. This is taken into account by the fact that the `event.switch` instruction has two event tags it is looking for: `$on-next` and `$on-end`.

Again, as with the generator, if an event is signaled to the consumer that does not match either event tag, the engine will trap. A toolchain wishing to implement a more robust execution can arrange to have an additional tag used for exceptions, for example. We will see this in how we handle access asynchronous I/O functions.

### Cooperative Coroutines

Cooperative coroutines, sometimes known as _green threads_ or _fibers_ allow an application to be structured in such a way that different responsibilities may be handled by different computations. The reasons for splitting into such fibers may vary; but one common scenario is to allow multiple sessions to proceed at their own pace.

In our formulation of fibers, we take an _arena_ based approach: when a program wishes to fork into separate fibers it does so by creating an arena or pool of fibers that represent the different activities. The arena computation as a whole only terminates when all of the fibers within it have completed. This allows a so-called _structured concurrency_ architecture that greatly enhances composability[^1].

[^1]: However, how cooperative coroutines are actually structured depends on the source language and its approach to handling fibers. We present one alternative.

#### Structure of a Fiber
We start with a sketch of a fiber, in C-style pseudo-code, that adds a collection of generated numbers, but yielding to the arena scheduler between every number:

```
void adderFiber(task *thisTask, task *generatorTask){
  int total = 0;
  while(true){
    switch(pause_fiber(thisTask)){
      case cancel_fiber:
        return; // Should really cancel the generator too
      case go_ahead_fiber:{
        switch(next(generator)){
          case yield(El):
            total += El;
            continue;
          case end:
            // report the total somewhere
            end_fiber(thisTask,total);
            return;
        }
      }
    }
  }
}
```
Note that we cannot simply use the previous function we constructed because we want to pause the fiber between every number. A more realistic scenario would not pause so frequently.

The WebAssembly version of `adderFiber` is straightforward:

```
(tag $pause_fiber)
(tag $end_fiber (param i32))
(tag $go_ahead_fiber)
(tag $cancel_fiber)

(func $adderFiber (param $thisTask taskref) (param $generator taskref)
  (local $total i32)
  (block $on-cancel
    (block $on-init 
      (event.switch ($go-ahead $on-init))
      (unreachble)
    )
    (local.set $total (i32.const 0))
    (loop $l
      (block $on-end
        (block $on-yield (i32) ;; 'returned' by the generator when it yields the next element
          (task.resume (local.get $generator) ($next ))
          (event.switch ($yield $on-yield) ($end $on-end))
        )
        (block $on-continue
          (local.get $total) ;; next entry to add is already on the stack
          (i32.add)
          (local.set $total)
          (task.yield (local.get $thisTask) ($pause_fiber))
          (event.switch ($go-ahead $on-continue) ($cancel_fiber $on-cancel))
          (unreachable)
        )
        (br $l) ;; go back and do some more
      )
      (task.retire (local.get $thisTask) ($end_fiber (local.get $total)))
      (unreachable)
    )
  ) ;; $on-cancel
  (task.release (local.get $generator)) ;; Kill of the generator
  (task.retire (local.get $thisTask) ($end_fiber (local.get $total)))
  (unreachable))
```
A lot of the apparent complexity of this code is due to the fact that it has to embody two roles: it is a yielding client of the fiber manager and it is also the manager of a generator. Other than that, this is similar in form to `$addAllElements`.

#### Managing Fibers in an Arena
Managing multiple computations necessarily introduces the concept of _cancellation_: not all the computations launched will be needed. In our arena implementation, we launch several fibers and when the first one returns we will cancel the others:

```
int cancelingArena(task fibers[]){
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
      (table.get $task_table (i32.add (local.get $fibers)(local.get $ix)))
      (task.resume ($go_ahead))
      (block $on-end (result i32)
        (block $on-pause
          (event.switch ($pause_fiber $on-pause)($end_fiber $on-end))
          (unreachable)
        ) ;; pause_fiber event
        (local.set $ix (i32.add (local.get $ix)(i32.const 1)))
        (br_if $for_ix (i32.ge (local.get $ix) (local.get $len)))
      ) ;; end_fiber event, found total on stack
      (local.set $jx (i32.const 0))
      (loop $for_jx
        (block $inner_jx
          (br_if $inner_jx (i32.eq (local.get $ix)(local.get $jx)))
          (table.get $task_table (i32.add (local.get $fibers)(local.get $jx)))
          (task.resume ($cancel_fiber))
          (event.switch ($end_fiber $inner_jx)) ;; only acceptable event
        )
        (local.set $jx (i32.add (local.get $jx)(i32.const 1)))
        (br_if $for_jx (i32.ge (local.get $jx)(local.get $len)))
      )
      (return) ;; total still on stack
    )
  )
)
```
The main additional complications here don't come from tasks per se; but rather from the fact that we have to use a table to keep track of our fibers. 

### Asynchronous I/O
TBD

## Frequently Asked Questions

### What is the difference between first class continuations and tasks?
A continuation is semantically a function that, when entered with a value, will finish the computation. In effect, continuations represent snapshots of the computation. A first class continuation is reified; i.e., it becomes a first class value and can be stored in tables and other locations.

This is especially apparent when you compare delimited continuations and tasks. A task has a natural delimiter: the point in the overall computation where the task is created. Over the course of a task's computation, it may suspend and be resumed multiple times[^3]. Each point where a task is suspended, we may consider that a continuation exists that denotes the remainder of the task.

One salient aspect of first class continuations is _restartability_. In principal, a continuation can be restarted more than once. However, this proposal, as well as others under consideration, ban to resuability of computations. A design for computation management that depends on first class continuations must test for the attempted reuse of a continuation.

However, this proposal does not reify continuations; instead the focus is on computations which do have an identity in this model.

[^3]: It can be reasonably argued that a computation that never suspends represents an anti-pattern. Setting up suspendable computations is associated with significant costs; and if it is known that a computation will not suspend then one should likely use a function instead of a task.

### Can Continuations be modeled with tasks?
Within reason, this is straightforward. A task can be encapsulated into a function object in such a way that invoking the function becomes the equivalent of entering the continuation.

However, this approach would not support restartable continuations without some additional ability to clone a task. This latter capability is not part of this proposal.

### Can tasks be modeled with continuations?
Within reason, this too is straightforward. A task becomes an object that embeds a continuation. When the task is to be resumed, the embedded continuation is entered.

Care would need to be taken in that the embedded continuation would need to be cleared; a more problematic issue is that, when a computation suspends, the correct task would have to be updated with the appropriate continuation.

### How are exceptions handled?
Exceptions arise in the context of suspendable computations because operations that are triggered prior to a suspension can fail. However, we do not make special accomodation for exceptions. Instead we use the common event mechanism to report both successful and unsuccessful computations.

When an I/O operation fails (say), and a requesting task needs to be resumed with that failure, then the resuming code (perhaps as part of an exception handler) resumes the suspended task with a suitable event. In general, all tasks, when they suspend, have to be prepared for three situations on their resumption: success, error and cancelation. This is best modeled in terms of an `event.switch` instruction listening for the three situations.

One popular feature of exception handling systems is that of _automatic exception propagation`; where an exception is automatically propagated from its point of origin to an outer scope that is equipped to respond to it. However, this policy is incompatible with any form of computation manipulation. 

The reason is that, when a task is resumed, it may be from a context that does not at all resemble the original situation; indeed it may be resumed from a context that cannot handle any application exceptions. This happens today in the browser, for example. When a `Promise` is resumed, it is typically from the context of the so-called micro task runner. If the resumed code throws an exception the micro task runner would be excepted to deal with it. In practice, the micro task runner will silently drop all exceptions raised in this way.

A more appropriate strategy for handling exceptions is for a specified sibling task, or at least a task that the language run-time is aware of, to handle the exception. This can be arranged by the language run-time straightforwardly by having the failing task signal an appropriate event. On the other hand, this kind of policy is extremely difficult to specify at the WebAssembly VM level. 

As a result, when a task throws an exception that is not caught by the task itself, we view this as a fatal error. There is no automatic propagation of exceptions out of tasks.

### How do tasks fit in with structured concurrency?
The task-based approach works well with structured concurrency architectures. A relevant approach would likely take the form of so-called task _arenas_. A task arena is a collection of tasks under the management of some scheduler. All the tasks in the arena have the same manager; although a given task in an arena may itself be the manager of another arena.

This proposal does not enfore structured concurrency however. It would be quite possible, for example, for all of the tasks within a WebAssembly module to be managed by a single task scheduler. It is our opinion that this degree of choice is advisable in order to avoid unnecessary obstacles in the path of a language implementer.

### Are there any performance issues?
Stack switching can be viewed as a technology that can be used to support suspendable computations and their management. Stack switching has been shown to be more efficient than approaches based on continuation passing style transformations[^4].

[^4]:Although CPS transformations do not require any change to the underlying engine; and they more readily can support restartable computations.

A task, as outlined here, can be viewed as a natural proxy for the stack in stack switching. I.e., a task entity would have an embedded link to the stacks used for that task. 

Furthermore, since the lifetime of a stack is approximately that of a task (a deep task may involve multiple stacks), the alignment of the two is good. In particular, a stack can be discarded precisely when the task is complete&mdash;although the task entity may still be referenced even though it is moribund.

On the other hand, any approach based on reifing continuations must deal with a more difficult alignment. The lifetime of a continuation is governed by the time a computation is suspended, not the whole lifetime. This potentially results in significant GC pressure to discard continuation objects after their utility is over.

### How do tasks relate to the JS Promise integration API?
A `Suspender` object, as documented in that API, corresponds reasonably well with a task. Like `Suspender`s, in order to suspend and resume tasks, there needs to be explicit communication between the top-level function of a task and the function that invokes suspension.

A wrapped export in the JS Promise integration API can be realized using tasks quite straightforwardly: as code that creates a task and executes the wrapped export. Similarly, wrapping imports can be translated into code that looks for a `Promise` object and suspends the task as needed.

### How does this proposal relate to exception handling?
Tasks and task management have some conceptua overlap with exception handling. However, where exception handling is oriented to responding to exceptional situations and errors, task management is intended to model the normal&mdash;if non-local&mdash; flow of control.

There is a common design element between this proposal and the exception handling proposal: the concept of an event. However, events as used in task oriented computation are explicitly intended to be as lightweight as possible. For example, there is no provision in events as described here to represent stack traces. Furthermore, events are not first class entities and cannot be manipulated, stored or transmitted.

### How does one support opt-out and opt-in?
The fundamental architecture of this proposal is capability based: having access to a task identifier allows a program to suspend and resume it. As such, opt-out is extremely straightforward: simply do not allow such code to become aware of the task identifier.

Supporting opt-in, where only specially prepared code can suspend and resume, and especially in the so-called _sandwich scenario_ is more difficult. If a suspending module invokes an import that reconnects to the module via another export, then this design will allow the module to suspend itself. This can invalidate execution assumptions of the sandwich filler module.

It is our opinion that the main method for preventing the sandwich scenario is to prevent non-suspending modules from importing functions from suspending modules. Solutions to this would have greater utility than preventing abuse of suspendable computations; and perhaps should be subject to a different effort.

### Types and Tasks (or, why dont tasks have types?)

Although we use functions to define the executable logic of tasks, such task functions naturally have a structure that is very different to normal functions. In particular, tasks communicate with each other via events which are not present in non-task functions. In addition, _task management_ requires a uniformity between tasks that is separate from the values computed by them.

If one views a task as representing a computation with an extent in time, one can view them as having three phases:

1. Initialization of local state, typically from the arguments to the task's initialization function;
1. communication with other tasks&mdash;using events; and
1. finalization of task, with a potential returning of a value.

It seems likely that most of the communications involved with tasks is in the second phase; in addition, given the ability to communicate, the communication of task results may often be folded into the middle phase.

The type safety of individual events is guaranteed by the type signature of the event tag; when an event occurs the types of values communicated during the event is guaranteed by static type checking. The validity of the event itself must be checked dynamically: the recipient of the event must be prepared for the event in the corresponding `event.switch` instruction; otherwise the engine must trap.

#### Tasks and session types

A demerit of assigning a type to a task is that it would not be possible to fully capture the communication pattern of tasks; whereas, for functions, types are a better fit to capture how functions communicate (arguments and results).

Despite this, and the fact that individual communication events are statically typed&mdash;although some computation may be needed to verify which event is triggered&mdash; it is worth thinking about whether we can type an entire task computation.

One approach that may support this would be to use [_session types_](http://www.dcs.gla.ac.uk/research/betty/summerschool2016.behavioural-types.eu/programme/DardhaIntroBST.pdf/at_download/file.pdf). Session types use algebraic data types (typically recursive) to model the state of a conversation between two or more parties. 

We could model valid tasks by assigning them a session type and we would ensure _conversational integrity_ by requiring session types to match when creating tasks.

While this may be a promising line of research, it seems that the gain from this (statically validating tasks vs dynamically validating each event) may not be sufficient to justify the effort. We are not currently planning on relying of session tyoes for this proposal.

### Why does a task function have to suspend immediately?

The `task.new` instruction requires that the first executable instruction is an `event.switch` instruction. The primary reason for this is that, in many cases, eliminates an extraneous stack switch.

Tasks are created in the context of task management; of course, there are many flavors of task management depending on the application pattern being used. However, in many cases, the managing software must additionally perform other bookkeeping tasks (sic) when creating sub-computations. For example, in a green threading scenario, it may be necessary to record the newly created green thread in a scheduling data structure.

By requiring the `task.new` instruction to not immediately start executing the new task we enable this bookkeeping to be accomplished with minimal overhead.

### Why isn't the `event.switch` instruction folded in with `task.suspend` and `task.resume`?

Although it would be possible to combine the task switching instructions with the event response instructions there are a few reasons why this may not be optimal:

* The boundary between a `task.suspend` instruction and its following `event.switch` instruction represents a significant change in the semantic state of the WebAssembly machine. Merging instructions like this would require a concept such as _restarting the execution of an instruction in the middle_. The semantics of such half-executed instructions is problematic; and there is a reason that real CPUs tend not to have such instructions in their ISA.

* The `event.switch` instruction is used in three situations: at the beginning of a task function, after a `task.suspend` and after a `task.resume` instruction. The first of these could not be eliminated without significant refactoring of the design.

* Not all task manipulation instructions are involved with an `event.switch` instruction. In particular, the `task.retire` instruction combines some of the semantics of a `task.suspend` with a `task.release`. 

* The potential code space saving is trivial: one opcode per `task.suspend`/`event.switch` combination. Any merged instruction would still need to support the literal argument vector associated with the `event.switch` instruction.
