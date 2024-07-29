# Stack switching
TODO

## Table of contents

1. [Specification changes](#specification-changes)
   1. [Instructions](#instructions)
   2. [Binary format](#binary-format)

## Specification changes

This proposal is based on the [function references proposal](https://github.com/WebAssembly/function-references) and [exception handling proposal](https://github.com/WebAssembly/exception-handling).

`cont <typeidx>` is a new form of composite type
- `(cont $ft) ok` iff `$ft ok` and `$ft = [t1*] -> [t2*]`

We add two new continuation heap types and their subtyping hierachy:
- `heaptypes ::= ... | cont | nocont`
- `nocont ok` and `cont ok` always
- `nocont` is the bottom type of continuation types, whereas `cont` is the top type, i.e. `nocont <: cont`

### Instructions

- `cont.new <typeidx>`
  - Create a new continuation from a given typed funcref.
  - `cont.new $ct : [(ref null? $ft)] -> [(ref $ct)]`
    - iff `C.types[$ct] = cont $ft`
    - and `C.types[$ft] = [t1*] -> [t2*]`

- `cont.bind <typeidx> <typeidx>`
  - Partially apply a continuation.
  - `cont.bind $ct $ct' : [t3* (ref null? $ct)] -> [(ref $ct')]`
    - iff `C.types[$ct'] = cont $ft'`
    - and `C.types[$ft'] = [t1'*] -> [t2'*]`
    - and `C.types[$ct] = cont $ft`
    - and `C.types[$ft] = [t1* t3*] -> [t2*]`
    - and `[t1*] -> [t2*] <: [t1'*] -> [t2'*]`
  - note - currently binding from right as discussed in https://github.com/WebAssembly/stack-switching/pull/53

- `suspend <tagidx>`
  - Send a tagged signal to suspend the current computation.
  - `suspend $t : [t1*] -> [t2*]`
    - iff `C.tags[$t] : tag $ft`
    - and `C.types[$ft] : [t1*] -> [t2*]`

- `resume <typeidx> (on <tagidx> <labelidx>|switch)*`
  - Execute a given continuation.
    - If the executed continuation suspends with a tagged signal `$t`, the corresponding handler `(tag $t H)` is executed.
  - `resume $ct (on $t H)* : [t1* (ref null? $ct)] -> [t2*]`
    - iff `C.types[$ct] = cont $ft`
    - and `C.types[$ft] = [t1*] -> [t2*]`
    - and for each `(tag $t H)`:
      - `C.tags[$t] : tag $ft`
      - and `C.types[$ft] : [te1*] -> [te2*]`
      - and either `H = $l`
        - and `C.labels[$l] = [te1'* (ref null? $ct')])*` 
        - and `([te1*] <: [te1'*])*`
        - and `(C.types[$ct'] = cont $ft')*`
        - and `([te2*] -> [t2*] <: C.types[$ft'])*`
      - or `H = switch`
        - and `te2* = []`
        - and `te1* <: t2*`


- `resume_throw <typeidx> <exnidx> (on <tagidx> <labelidx>|switch)*`
  - Execute a given continuation, but force it to immediately throw the annotated exception.
  - Used to abort a continuation.
  - `resume_throw $ct $e (on $t H)* : [te* (ref null? $ct)] -> [t2*]`
    - iff `C.types[$ct] = cont $ft`
    - and `C.types[$ft] = [t1*] -> [t2*]`
    - and `C.tags[$e] : tag $ft1`
    - and `C.types[$ft1] : [te*] -> []`
    - and for each `(tag $t H)`:
      - `C.tags[$t] : tag $ft`
      - and `C.types[$ft] : [te1*] -> [te2*]`
      - and either `H = $l`
        - and `C.labels[$l] = [te1'* (ref null? $ct')])*` 
        - and `([te1*] <: [te1'*])*`
        - and `(C.types[$ct'] = cont $ft')*`
        - and `([te2*] -> [t2*] <: C.types[$ft'])*`
      - or `H = switch`
        - and `te2* = []`
        - and `te1* <: t2*`

- `switch <typeidx> <tagidx>`
- Switch to executing a given continuation directly, suspending the current execution.
  - The suspension and switch are performed from the perspective of a parent `switch` handler, determined by the annotated tag.
  - `switch $ct1 $e : t1* (ref null $ct1) -> t2*`
    - iff `C.tags[$e] : tag $ft`
    - and `C.types[$ft] : [t*] -> []`
    - and `C.types[$ct1] = cont $ft1`
    - and `C.types[$ft1] = [t1* (ref null? $ct2)] -> [te1*]`
    - and `te1* <: t*`
    - and `C.types[$ct2] = cont $ft2`
    - and `C.types[$ft2] = [t2*] -> [te2*]`
    - and `te2* <: t*`

### Binary format
The binary format is modified as follows:

#### Composite types

| Opcode | Type            | Parameters | Note |
| ------ | --------------- | ---------- |------|
| -0x20  | `func t1* t2*`  | `t1* : vec(valtype)` `t2* : vec(valtype)` | from Wasm 1.0 |
| -0x23  | `cont $ft`      | `$ft : typeidx` | new |

#### Heap Types

The opcode for heap types is encoded as an `s33`.

| Opcode | Type            | Parameters | Note |
| ------ | --------------- | ---------- | ---- |
| i >= 0 | i               |            | from function-references |
| -0x0b  | `nocont`        |            | new  |
| -0x18  | `cont`          |            | new  |

### Instructions

| Opcode | Instruction              | Immediates |
| ------ | ------------------------ | ---------- |
| 0xe0   | `cont.new $ct`           | `$ct : u32` |
| 0xe1   | `cont.bind $ct $ct'`     | `$ct : u32`, `$ct' : u32` |
| 0xe2   | `suspend $t`             | `$t : u32` |
| 0xe3   | `resume $ct (on $t $h)*` | `$ct : u32`, `($t : u32 and $h : u32)*` |
| 0xe4   | `resume_throw $ct $e (on $t $h)` | `$ct : u32`, `$e : u32`, `($t : u32 and $h : u32)*` |
| 0xTODO | `switch`                 | TODO |

