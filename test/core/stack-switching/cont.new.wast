;; No type immediate.
(assert_malformed
  (module quote
    "(module"
      "(func (drop (cont.new)))"
    ")"
  )
  "unexpected token"
)

(assert_malformed
  (module binary
    "\00asm\01\00\00\00"
    "\01\04\01\60\00\00"       ;; Type section: 1 type
    "\03\02\01\00"             ;; Function section: 1 function
    "\0a\04\01"                ;; Code section: 1 function
    ;; function 0
    "\02\00"                   ;; Function size and local type count
    "\e0"                      ;; cont.new (missing type immediate)
  )
  "unexpected end"
)

;; Valid binary module parsing, validating, and executing correctly
(module binary
  "\00\61\73\6d\01\00\00\00" ;; Magic header and version
  "\01\8b\80\80\80\00\03"    ;; Type section: 3 types
  "\60\00\00"                ;; type 0: func [] -> []
  "\5d\00"                   ;; type 1: cont 0
  "\60\00\01\64\01"          ;; type 2: func [] -> [ref 1]
  "\03\83\80\80\80\00\02"    ;; Function section: 2 functions
  "\00\02"                   ;; func 0: type 0, func 1: type 2
  "\07\88\80\80\80\00\01"    ;; Export section: 1 export
  "\04\74\65\73\74\00\01"    ;; "test" -> func 1
  "\09\85\80\80\80\00\01"    ;; Element section: 1 segment
  "\03\00\01\00"             ;; declarative, elem kind func, 1 func, func index 0
  "\0a\93\80\80\80\00\02"    ;; Code section: 2 functions
  ;; function 0
  "\82\80\80\80\00\00\0b"    ;; size 2, 0 locals, end
  ;; function 1
  "\86\80\80\80\00\00"       ;; size 6, 0 locals
  "\d2\00"                   ;; ref.func 0
  "\e0\01"                   ;; cont.new 1
  "\0b"                      ;; end
)
(assert_return (invoke "test") (ref.cont))

;; Out-of-bounds type immediate.
(assert_invalid
  (module
    (func (drop (cont.new 0 (unreachable))))
  )
  "non-continuation type"
)

;; Non-continuation type.
(assert_invalid
  (module
    (type $f (func))
    (func (drop (cont.new $f (unreachable))))
  )
  "non-continuation type"
)

;; Defined function ref.func operand.
(module
  (type $f (func))
  (type $k (cont $f))
  (elem declare func $f)
  (func $f (type $f))
  (func (export "test") (result (ref $k)) (cont.new $k (ref.func $f)))
)
(assert_return (invoke "test") (ref.cont))

;; Imported function ref.func operand.
(module definition
  (type $f (func))
  (type $k (cont $f))
  (elem declare func $f)
  (import "" "" (func $f (type $f)))
  (func (result (ref $k)) (cont.new $k (ref.func $f)))
)

;; Defined global operand.
(module
  (type $f (func))
  (type $k (cont $f))
  (global $g (ref null $f) (ref.null nofunc))
  (func (export "test") (result (ref $k)) (cont.new $k (global.get $g)))
)
(assert_trap (invoke "test") "null function reference")

;; Defined global operand (non-null at runtime).
(module
  (type $f (func))
  (type $k (cont $f))
  (elem declare func $f)
  (func $f (type $f))
  (global $g (ref null $f) (ref.func $f))
  (func (export "test") (result (ref $k)) (cont.new $k (global.get $g)))
)
(assert_return (invoke "test") (ref.cont))

;; Imported global operand.
(module definition
  (type $f (func))
  (type $k (cont $f))
  (import "" "" (global $g (ref null $f)))
  (func (result (ref $k)) (cont.new $k (global.get $g)))
)

;; Param operand.
(module
  (type $f (func))
  (type $k (cont $f))
  (func (export "test") (param (ref null $f)) (result (ref $k))
    (cont.new $k (local.get 0))
  )
)
(assert_trap (invoke "test" (ref.null nofunc)) "null function reference")

;; Stack-polymorphic (unreachable) input.
(module
  (type $f (func))
  (type $k (cont $f))
  (func (export "test") (result (ref $k)) (cont.new $k (unreachable)))
)
(assert_trap (invoke "test") "unreachable")

;; Stack-polymorphic (unreachable) input due to branch.
(module
  (type $f (func))
  (type $k (cont $f))
  (func (export "test")
    (drop
      (block $l (result (ref $k))
        (cont.new $k (return))
      )
    )
  )
)
(assert_return (invoke "test"))

;; Uninhabitable bottom input.
(module
  (type $f (func))
  (type $k (cont $f))
  (func (param (ref nofunc)) (result (ref $k)) (cont.new $k (local.get 0)))
)

;; Null constant input.
(module
  (type $f (func))
  (type $k (cont $f))
  (func (export "test") (result (ref $k)) (cont.new $k (ref.null $f)))
)
(assert_trap (invoke "test") "null function reference")

;; Bottom null constant input.
(module
  (type $f (func))
  (type $k (cont $f))
  (func (export "test") (result (ref $k)) (cont.new $k (ref.null nofunc)))
)
(assert_trap (invoke "test") "null function reference")

;; Top null constant input.
(assert_invalid
  (module
    (type $f (func))
    (type $k (cont $f))
    (func (result (ref $k)) (cont.new $k (ref.null func)))
  )
  "type mismatch"
)

;; Any hierarchy null constant input.
(assert_invalid
  (module
    (type $f (func))
    (type $k (cont $f))
    (func (result (ref $k)) (cont.new $k (ref.null none)))
  )
  "type mismatch"
)

;; Cont hierarchy null constant input.
(assert_invalid
  (module
    (type $f (func))
    (type $k (cont $f))
    (func (result (ref $k)) (cont.new $k (ref.null nocont)))
  )
  "type mismatch"
)

;; Top reference input.
(assert_invalid
  (module
    (type $f (func))
    (type $k (cont $f))
    (func (param funcref) (result (ref $k)) (cont.new $k (local.get 0)))
  )
  "type mismatch"
)

;; Declared subtype input.
(module
  (type $super (sub (func)))
  (type $sub (sub $super (func)))
  (type $k (cont $super))
  (elem declare func $sub)
  (func $sub (type $sub))
  (func (export "test") (result (ref $k)) (cont.new $k (ref.func $sub)))
)
(assert_return (invoke "test") (ref.cont))

;; Declared supertype input.
(assert_invalid
  (module
    (type $super (sub (func)))
    (type $sub (sub $super (func)))
    (type $k (cont $sub))
    (func (param (ref null $super)) (result (ref $k)) (cont.new $k (local.get 0)))
  )
  "type mismatch"
)

;; Unrelated input.
(assert_invalid
  (module
    (rec
      (type $f (func))
      (type $other (func))
    )
    (type $k (cont $f))
    (func (param (ref null $other)) (result (ref $k)) (cont.new $k (local.get 0)))
  )
  "type mismatch"
)

;; Missing input.
(assert_invalid
  (module
    (type $f (func))
    (type $k (cont $f))
    (func (result (ref $k)) (cont.new $k))
  )
  "type mismatch"
)

;; Extra input.
(assert_invalid
  (module
    (type $f (func))
    (type $k (cont $f))
    (func (param (ref null $f)) (result (ref $k)) (cont.new $k (i32.const 0) (local.get 0)))
  )
  "type mismatch"
)

;; Extra input matching continuation params.
(assert_invalid
  (module
    (type $f (func (param i32)))
    (type $k (cont $f))
    (func (param (ref null $f)) (result (ref $k)) (cont.new $k (i32.const 0) (local.get 0)))
  )
  "type mismatch"
)

;; Contref output type.
(module
  (type $f (func))
  (type $k (cont $f))
  (func (param (ref null $f)) (result contref) (cont.new $k (local.get 0)))
)

;; Nullable cont reference output type.
(module
  (type $f (func))
  (type $k (cont $f))
  (func (param (ref null $f)) (result (ref null cont)) (cont.new $k (local.get 0)))
)

;; Non-nullable cont reference output type.
(module
  (type $f (func))
  (type $k (cont $f))
  (func (param (ref null $f)) (result (ref cont)) (cont.new $k (local.get 0)))
)

;; Declared supertype output type.
(module
  (type $f (func))
  (type $super (sub (cont $f)))
  (type $sub (sub $super (cont $f)))
  (func (param (ref null $f)) (result (ref $super)) (cont.new $sub (local.get 0)))
)

;; Declared subtype output type.
(assert_invalid
  (module
    (type $f (func))
    (type $super (sub (cont $f)))
    (type $sub (sub $super (cont $f)))
    (func (param (ref null $f)) (result (ref $sub)) (cont.new $super (local.get 0)))
  )
  "type mismatch"
)

;; Unrelated output.
(assert_invalid
  (module
    (type $f (func))
    (rec
      (type $k (cont $f))
      (type $other (cont $f))
    )
    (func (param (ref null $f)) (result (ref $other)) (cont.new $k (local.get 0)))
  )
  "type mismatch"
)

;; Constant expression in global definition.
(module
  (type $f (func))
  (type $k (cont $f))
  (global $k (export "k") (ref $k) (cont.new $k (ref.func $f)))
  (func $f (type $f))
)
(assert_return (get "k") (ref.cont))

;; Constant expression in element segment definition.
(module
  (type $f (func))
  (type $k (cont $f))
  (table $t (ref null $k) (elem (cont.new $k (ref.func $f))))
  (func $f (type $f))
  (func (export "get") (result (ref null $k)) (table.get $t (i32.const 0)))
)
(assert_return (invoke "get") (ref.cont))
