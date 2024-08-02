# Stack-Switching Proposal for WebAssembly

This repository is a clone of
[`WebAssembly/spec`](https://github.com/WebAssembly/spec/). It is meant for
discussion, prototype specification, and implementation of a proposal to add
support for stack-switching.

There are currently two active stack-switching proposals: Typed Continuations
(aka WasmFX) and Bag of Stacks. Documentation about each proposal is available
in separate directories of the `main` branch of this repository (as detailed
below).

In order to minimise future difficulties merging upstream, the two
corresponding extensions to the reference interpreter will be
maintained in separate branches (as detailed below).

## Typed Continuations Proposal

* See the [explainer](proposals/continuations/Explainer.md) for a high-level
  summary of the proposal.

* See the [overview](proposals/continuations/Overview.md) for a more formal
  description of the proposal.

* See the [examples](proposals/continuations/examples) for Wasm code for
  implementing various different features including lightweight threads, actors,
  and async/await.

* An
[implementation](https://github.com/WebAssembly/stack-switching/tree/wasmfx) is
available as an extension to the reference interpreter. It is accesible from the
`wasmfx` branch.

## Bag of Stacks Proposal

* See the [explainer](proposals/bag-o-stacks/Explainer.md) for a high-level
  summary of the proposal.

* An extension to the reference interpreter will be made available in the
`bag-o-stacks` branch in due course.


Original README from upstream repository follows.

--------------------------------------------------------------------------------

[![CI for specs](https://github.com/WebAssembly/stack-switching/actions/workflows/ci-spec.yml/badge.svg)](https://github.com/WebAssembly/stack-switching/actions/workflows/ci-spec.yml)
[![CI for interpreter & tests](https://github.com/WebAssembly/stack-switching/actions/workflows/ci-interpreter.yml/badge.svg)](https://github.com/WebAssembly/stack-switching/actions/workflows/ci-interpreter.yml)

# spec

This repository holds the sources for the WebAssembly specification,
a reference implementation, and the official test suite.

A formatted version of the spec is available here:
[webassembly.github.io/spec](https://webassembly.github.io/spec/),

Participation is welcome. Discussions about new features, significant semantic
changes, or any specification change likely to generate substantial discussion
should take place in
[the WebAssembly design repository](https://github.com/WebAssembly/design)
first, so that this spec repository can remain focused. And please follow the
[guidelines for contributing](Contributing.md).

# citing

For citing WebAssembly in LaTeX, use [this bibtex file](wasm-specs.bib).
