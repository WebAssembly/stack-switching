# Benchmarks for Asyncify and WasmFX using fiber-c

This directory contains benchmarks for comparing WasmFX (suspend/resume stack
switching) against Asyncify. The [fiber-c
library](https://github.com/wasmfx/fiber-c) is used to provide a C interface for
fibers, which can be compiled with either backend.

## Dependencies

You'll need some dependencies:
  * Binaryen
  * Wasi-SDK clang: https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-30/wasi-sdk-30.0-x86_64-linux.tar.gz
  * The Wasm interpreter/assembler from this repo (stack-switching/interpreter/wasm)

Set the environment variables BINARYEN, WASI_SDK and WASM_INTERP to the paths to
these. You should also set WASMTIME to your wasmtime interpreter, which is not
strictly needed but it is used to precompile .cwasm files for running under
wasmtime.

## Benchmarks

The primary benchmarks of interest are itersum, treesum, pi and c10m. Some other
secondary benchmarks are here as well. To compile benchmarks, either use `make`
to make every flavor of the primary and secondary ones, or `make pi` for example
to make all flavors of the pi benchmark.

Results will be found in `bin/`, for example `bin/itersum_asyncify.wasm` or
`bin/itersum_wasmfx.wasm`.

## To use

First run `make` or choose targets to make. Find build products in `bin/`. Run
those targets through your engine of choice. Most of the programs take no
command-line arguments, but itersum needs the total number of iterations to run
(try 100000000), and treesum needs a tree depth (up to 25; 25 is standard).
Treesum will always run 2^25 iterations of suspend/resume regardless of how big
a tree is used, by repeating full tree iterations.

## Symmetric stack switching

Independent of the wasmfx and asyncify flavors, some targets also support a
switch format. "Switch" is an alternative flavor of the fiber-c interface
itself, which source programs can be ported to (see itersum_switch and
treesum_switch).

## Other build products

The `.cwasm` build products are pre-compiled for Wasmtime, which saves a small
amount of startup time on that engine; these files are not compatible with other
engines.

The makefile produces "stripped" version of each target, which strips out
debugging symbols. These versions are used to compare binary sizes without the
inflation that debugging symbols bring.

There is a .unopt (unoptimised) version of each target which can be useful
for debugging or ad-hoc experiments.
