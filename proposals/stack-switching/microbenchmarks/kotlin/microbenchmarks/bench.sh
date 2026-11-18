#!/bin/sh

set -ev

echo -n #######################
echo -n ### Kotlin Baseline ###
echo -n #######################

cp build.gradle.kts-baseline build.gradle.kts
./gradlew build
/opt/wasmfx/v8/v8/out/x64.release/d8 --experimental-wasm-wasmfx \
  build/wasm/packages/kotlin-wasm-nodejs-example/kotlin/kotlin-wasm-nodejs-example.mjs

echo -n #######################
echo -n ### Kotlin WasmFX   ###
echo -n #######################

cp build.gradle.kts-wasmfx build.gradle.kts
./gradlew build
/opt/wasmfx/v8/v8/out/x64.release/d8 --experimental-wasm-wasmfx \
  build/wasm/packages/kotlin-wasm-nodejs-example/kotlin/kotlin-wasm-nodejs-example.mjs