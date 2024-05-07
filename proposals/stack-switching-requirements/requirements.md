# Multi-Stack Requirements

## Goals
Capabilities to permit Wasm applications to safely and efficiently implement common patterns of non-local control flow.

## Critical Use Cases
* Async/await
* Green Threads
* Yield-style generators
* First class continuations (e.g., Scheme, react-style programming over large trees)

## Critical Success Factors
* Must respect browser implementation constraints
* Must permit competitive implementations in modern Wasm engines
* Must interoperate with JS Promises
  * Must not allow stack switching to leak into JavaScript
* Must be consistent with modern Control Flow Integrity measures
* Must be compatible with existing and proposed Wasm extensions; e.g.,
  * Exception handling
  * Threading
  * Garbage Collection
* Must enable applications/engines to maintain critical invariants:
  * Maintain integrity of host embedder’s event loop
  * Preserving critical sections
  * Ensuring reachability of linear memory GC roots
  * Maintaining correctness of application shadow stacks

## Criteria
1. Prefer languages and features that are most likely to lead to adoption
1. Prefer approaches that are known to be efficiently implementable
   * Without undue reliance on in-engine optimization techniques
1. Prefer ‘small’ designs that are compatible with future features
1. Prefer expressive orthogonally composable sets of features
1. Prefer designs that facilitate reasoning about execution environment
1. Design to enable embedder neutral wasm modules
