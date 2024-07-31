[![CI for specs](https://github.com/wasmfx/specfx/actions/workflows/ci-spec.yml/badge.svg)](https://github.com/wasmfx/specfx/actions/workflows/ci-spec.yml)
[![CI for interpreter & tests](https://github.com/wasmfx/specfx/actions/workflows/ci-interpreter.yml/badge.svg)](https://github.com/wasmfx/specfx/actions/workflows/ci-interpreter.yml)

# Typed Continuations Proposal for WebAssembly

This repository is a clone of
[github.com/WebAssembly/spec/](https://github.com/WebAssembly/spec/).
It is meant for discussion, prototype specification and implementation
of a proposal to add support for different patterns of non-local
control flow to WebAssembly.

The proposal is fully implemented as part of the reference interpreter.

* See the [explainer](proposals/continuations/Explainer.md) for a high-level summary of the proposal.

* See the [overview](proposals/continuations/Overview.md) for a more formal description of the proposal.

* See the [examples](proposals/continuations/examples) for Wasm code for implementing various different features including lightweight threads, actors, and async/await.

Original `README` from upstream repository follows.

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
