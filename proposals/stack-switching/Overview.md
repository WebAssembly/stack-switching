# Stack Switching Proposal

## Summary

This proposal extends Wasm with capabilities to permit Wasm applications to safely and efficiently implement common patterns of non-local control flow.

## Motivation

* Support for Asynch/await programming pattern.
* Support for green threads.
* Support for yield-style generators.

See [requirements](requirements.md) for a complete summary of requirements.

## Overview

Here is a sketch of what we wanna add.