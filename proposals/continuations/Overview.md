# Typed Continuations for WebAssembly

## Language Extensions

Based on [typed reference proposal](https://github.com/WebAssembly/function-references/blob/master/proposals/function-references/Overview.md) and [exception handling proposal](https://github.com/WebAssembly/exception-handling/blob/master/proposals/exception-handling/Exceptions.md).


### Types

#### Defined Types

* `cont <typeidx>` is a new form of defined type
  - `(cont $ft) ok` iff `$ft ok` and `$ft = [t1*] -> [t2*]`


### Instructions

* `cont.new <typeidx>` creates a new continuation
  - `cont.new $ct : [(ref null? $ft)] -> [(ref $ct)]`
    - iff `$ct = cont $ft`

* `cont.bind <typeidx> <typeidx>` binds a continuation to (partial) arguments
  - `cont.bind $ct $ct' : [t3* (ref null? $ct)] -> [(ref $ct')]`
    - iff `$ct = cont $ft`
    - and `$ft = [t3* t1*] -> [t2*]`
    - and `$ct' = cont $ft'`
    - and `$ft' = [t1'*] -> [t2'*]`
    - and `[t1*] -> [t2*] <: [t1'*] -> [t2'*]`

* `suspend <tagidx>` suspends the current continuation
  - `suspend $t : [t1*] -> [t2*]`
    - iff `tag $t : [t1*] -> [t2*]`

* `resume <typeidx> (on <tagidx> <labelidx>)*` resumes a continuation
  - `resume $ct (on $t $l)* : [t1* (ref null? $ct)] -> [t2*]`
    - iff `$ct = cont $ft`
    - and `$ft = [t1*] -> [t2*]`
    - and `(on $t : [te1*] -> [te2*])*`
    - and `(label $l : [te1'* (ref null? $ct')])*`
    - and `([te1*] <: [te1'*])*`
    - and `($ct' = cont $ft')*`
    - and `($ft' = [t1'*] -> [t2'*])*`
    - and `([te2*] -> [t2*] <: [t1'*] -> [t2'*])*`

* `resume_throw <typeidx> <tagidx> (on <tagidx> <labelidx>)*` aborts a continuation
  - `resume_throw $ct $e (on $t $l)* : [te* (ref null? $ct)] -> [t2*]`
    - iff `(tag $e : [te*] -> [])`
    - and `$ct = cont $ft`
    - and `$ft = [t1*] -> [t2*]`
    - and `(on $t : [te1*] -> [te2*])*`
    - and `(label $l : [te1'* (ref null? $ct')])*`
    - and `([te1*] <: [te1'*])*`
    - and `($ct' = cont $ft')*`
    - and `($ft' = [t1'*] -> [t2'*])*`
    - and `([te2*] -> [t2*] <: [t1'*] -> [t2'*])*`

* `barrier <blocktype> <instr>* end` blocks suspension
  - `barrier $l bt instr* end : [t1*] -> [t2*]`
    - iff `bt = [t1*] -> [t2*]`
    - and `instr* : [t1*] -> [t2*]` with labels extended with `[t2*]`


## Reduction Semantics

### Store extensions

* New store component `tags` for allocated tags
  - `S ::= {..., tags <taginst>*}`

* A *tag instance* represents a control tag
  - `taginst ::= {type <tagtype>}`

* New store component `conts` for allocated continuations
  - `S ::= {..., conts <cont>?*}`

* A continuation is a context annotated with its hole's arity
  - `cont ::= (E : n)`


### Administrative instructions

* `(ref.cont a)` represents a continuation value, where `a` is a *continuation address* indexing into the store's `conts` component
  - `ref.cont a : [] -> [(ref $ct)]`
    - iff `S.conts[a] = epsilon \/ S.conts[a] = (E : n)`
    - and `$ct = cont $ft`
    - and `$ft = [t1^n] -> [t2*]`

* `(handle{(<tagaddr> <labelidx>)*}? <instr>* end)` represents an active handler (or a barrier when no handler list is present)
  - `(handle{(a $l)*}? instr* end) : [t1*] -> [t2*]`
    - iff `instr* : [t1*] -> [t2*]`
    - and `(S.tags[a].type = [te1*] -> [te2*])*`
    - and `(label $l : [te1'* (ref null? $ct')])*`
    - and `([te1*] <: [te1'*])*`
    - and `($ct' = cont $ft')*`
    - and `([te2*] -> [t2*] <: $ft')*`


### Handler contexts

```
H^ea ::=
  _
  val* H^ea instr*
  label_n{instr*} H^ea end
  frame_n{F} H^ea end
  catch{...} H^ea end
  handle{(ea' $l)*} H^ea end   (iff ea notin ea'*)
```


### Reduction

* `S; F; (ref.null t) (cont.new $ct)  -->  S; F; trap`

* `S; F; (ref.func fa) (cont.new $ct)  -->  S'; F; (ref.cont |S.conts|)`
  - iff `S' = S with conts += (E : n)`
  - and `E = _ (invoke fa)`
  - and `$ct = cont $ft`
  - and `$ft = [t1^n] -> [t2*]`

* `S; F; (ref.null t) (cont.bind $ct $ct')  -->  S; F; trap`

* `S; F; (ref.cont ca) (cont.bind $ct $ct')  -->  S'; F; trap`
  - iff `S.conts[ca] = epsilon`

* `S; F; v^n (ref.cont ca) (cont.bind $ct $ct')  -->  S'; F; (ref.const |S.conts|)`
  - iff `S.conts[ca] = (E' : n')`
  - and `$ct' = cont $ft'`
  - and `$ft' = [t1'*] -> [t2'*]`
  - and `n = n' - |t1'*|`
  - and `S' = S with conts[ca] = epsilon with conts += (E : |t1'*|)`
  - and `E = E'[v^n _]`

* `S; F; (ref.null t) (resume $ct (on $e $l)*)  -->  S; F; trap`

* `S; F; (ref.cont ca) (resume $ct (on $e $l)*)  -->  S; F; trap`
  - iff `S.conts[ca] = epsilon`

* `S; F; v^n (ref.cont ca) (resume $ct (on $t $l)*)  -->  S'; F; handle{(ea $l)*} E[v^n] end`
  - iff `S.conts[ca] = (E : n)`
  - and `(ea = F.tags[$t])*`
  - and `S' = S with conts[ca] = epsilon`

* `S; F; (ref.null t) (resume_throw $ct $e (on $t $l)*)  -->  S; F; trap`

* `S; F; (ref.cont ca) (resume_throw $ct $e (on $t $l)*)  -->  S; F; trap`
  - iff `S.conts[ca] = epsilon`

* `S; F; v^m (ref.cont ca) (resume_throw $ct $e (on $t $l)*)  -->  S'; F; handle{(ea $l)*} E[v^m (throw $e)] end`
  - iff `S.conts[ca] = (E : n)`
  - and `(ea = F.tags[$t])*`
  - and `S.tags[F.tags[$e]].type = [t1^m] -> [t2*]`
  - and `S' = S with conts[ca] = epsilon`

* `S; F; (barrier bt instr* end)  -->  S; F; handle instr* end`

* `S; F; (handle{(e $l)*}? v* end)  -->  S; F; v*`

* `S; F; (handle H^ea[(suspend $e)] end)  --> S; F; trap`
  - iff `ea = F.tags[$e]`

* `S; F; (handle{(ea1 $l1)* (ea $l) (ea2 $l2)*} H^ea[v^n (suspend $e)] end)  --> S'; F; v^n (ref.cont |S.conts|) (br $l)`
  - iff `ea notin ea1*`
  - and `ea = F.tags[$e]`
  - and `S.tags[ea].type = [t1^n] -> [t2^m]`
  - and `S' = S with conts += (H^ea : m)`
