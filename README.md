[![Build Status](https://travis-ci.org/WebAssembly/stack-switching.svg?branch=master)](https://travis-ci.org/WebAssembly/stack-switching)

# Stack Switching Proposal for WebAssembly

This repository is a clone of [github.com/WebAssembly/spec/](https://github.com/WebAssembly/spec/).
It is meant for discussion, prototype specification and implementation of a proposal to
add support for different patterns of non-local control flow to WebAssembly.

* See the [overview](proposals/stack-switching/Overview.md) for a summary of the proposal.

* See the [modified spec](https://webassembly.github.io/stack-switching/) for details.

## Typed Continuations Proposal for WebAssembly

This is a concrete proposal for realising the aims of the stack-switching proposal.

It is based on the [function references](proposals/function-references/Overview.md) and the [tail call](proposals/tail-call/Overview.md) proposals and includes all respective changes.

The proposal is fully [implemented](https://github.com/effect-handlers/wasm-spec) as part of the reference interpreter.

* See the [explainer](proposals/continuations/Explainer.md) for a high-level summary of the proposal.

* See the [overview](proposals/continuations/Overview.md) for a more formal description of the proposal.

* See the [examples](proposals/continuations/examples) for Wasm code for implementing various different features including lightweight threads, actors, and async/await.

Original `README` from upstream repository follows.

# spec

This repository holds a prototypical reference implementation for WebAssembly,
which is currently serving as the official specification. Eventually, we expect
to produce a specification either written in human-readable prose or in a formal
specification language.

It also holds the WebAssembly testsuite, which tests numerous aspects of
conformance to the spec.

View the work-in-progress spec at [webassembly.github.io/spec](https://webassembly.github.io/spec/).

At this time, the contents of this repository are under development and known
to be "incomplet and inkorrect".

Participation is welcome. Discussions about new features, significant semantic
changes, or any specification change likely to generate substantial discussion
should take place in
[the WebAssembly design repository](https://github.com/WebAssembly/design)
first, so that this spec repository can remain focused. And please follow the
[guidelines for contributing](Contributing.md).

# citing

For citing WebAssembly in LaTeX, use [this bibtex file](wasm-specs.bib).
