#!/bin/sh

set -ev

#######################
### Kotlin Baseline ###
#######################

cp build.gradle.kts-baseline build.gradle.kts
./gradlew build
/opt/wasmfx/v8/v8/out/x64.release/d8 --experimental-wasm-wasmfx \
  build/wasm/packages/kotlin-wasm-nodejs-example/kotlin/kotlin-wasm-nodejs-example.mjs

#######################
### Kotlin WasmFX   ###
#######################

cp build.gradle.kts-wasmfx build.gradle.kts
./gradlew build
/opt/wasmfx/v8/v8/out/x64.release/d8 --experimental-wasm-wasmfx \
  build/wasm/packages/kotlin-wasm-nodejs-example/kotlin/kotlin-wasm-nodejs-example.mjs