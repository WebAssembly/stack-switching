;; Test tag section

(module
  (tag)
  (tag (param i32))
  (tag (export "t2") (param i32))
  (tag $t3 (param i32 f32))
  (export "t3" (tag 3))
)

(register "test")

(module
  (tag $t0 (import "test" "t2") (param i32))
  (import "test" "t3" (tag $t1 (param i32 f32)))
)

;; NOTE(dhil): This test is invalid as our proposal allows non-empty
;; (assert_invalid
;;   (module (tag (result i32)))
;;   "non-empty tag result type"
;; )

;; Mutually recursive types
(module
  (rec
    (type $f (func (param (ref null $c))))
    (type $c (cont $f))
  )
  (tag (type $f))
)

;; Link-time typing

(module
  (rec
    (type $t1 (func))
    (type $t2 (func))
  )
  (tag (export "tag") (type $t1))
)

(register "M")

(module
  (rec
    (type $t1 (func))
    (type $t2 (func))
  )
  (tag (import "M" "tag") (type $t1))
)

(assert_unlinkable
  (module
    (rec
      (type $t1 (func))
      (type $t2 (func))
    )
    (tag (import "M" "tag") (type $t2))
  )
  "incompatible import"
)

(assert_unlinkable
  (module
    (type $t (func))
    (tag (import "M" "tag") (type $t))
  )
  "incompatible import"
)
