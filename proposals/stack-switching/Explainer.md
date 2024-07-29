# Stack switching
TODO

## Table of contents
TODO

## Instructions

- `cont.new <typeidx>`
  - Create a new continuation from a given typed funcref.
  - `cont.new $ct : [(ref null? $ft)] -> [(ref $ct)]`
    - iff `C.types[$ct] = cont $ft`
    - and `C.types[$ft] = [t1*] -> [t2*]`

- `cont.bind <typeidx>`
  - Partially apply a continuation.
  - `cont.bind $ct : [t3* (ref null? $ct')] -> [(ref $ct)]`
    - iff `C.types[$ct] = cont $ft`
    - and `C.types[$ft] = [t1*] -> [t2*]`
    - and `C.types[$ct'] = cont $ft'`
    - and `C.types[$ft'] = [t1'* t3*] -> [t2'*]`
    - and `[t1'*] -> [t2'*] <: [t1*] -> [t2*]`
  - note - currently binding from right as discussed in https://github.com/WebAssembly/stack-switching/pull/53

- `suspend <tagidx>`
  - Send a tagged signal to suspend the current computation.
  - `suspend $t : [t1*] -> [t2*]`
    - iff `C.tags[$t] : tag $ft`
    - and `C.types[$ft] : [t1*] -> [t2*]`

- `resume <typeidx> (on <tagidx> <labelidx>|switch)*`
  - Execute a given continuation.
    - If the executed continuation suspends with a tagged signal `$t`, the corresponding handler `(tag $t H)` is executed.
  - `resume $ct (tag $t H)* : [t1* (ref null? $ct)] -> [t2*]`
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
        - and `te1* <: t2*`
        - and `te2* = []`

- `resume_throw <typeidx> <exnidx>`
- Execute a given continuation, but force it to immediately handle the annotated exception.
- Used to abort a continuation.
  - resume_throw $ct $e : `[te* (ref null? $ct)] -> [t2*]`
    - iff `C.types[$ct] = cont $ft`
    - and `C.types[$ft] = [t1*] -> [t2*]`
    - and `C.tags[$e] : tag $ft1`
    - and `C.types[$ft1] : [te*] -> []`

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

## Binary encoding
TODO
