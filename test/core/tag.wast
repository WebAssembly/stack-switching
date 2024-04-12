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
;; tag result types
;; (assert_invalid
;;   (module (tag (result i32)))
;;   "non-empty tag result type"
;; )
