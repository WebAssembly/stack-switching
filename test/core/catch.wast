;; Test the minimal "exception handling" extension

(module
  (exception $e0)
  (exception $e1 (param i32))

  (func (export "catch-1") (result i32)
    (try (result i32)
      (do (i32.const -1) (throw $e0) (i32.const 0))
      (catch_all (i32.const 1))
    )
  )

  (func (export "catch-2") (result i32)
    (try (result i32)
      (do
        (try (result i32)
          (do
            (throw $e0)
            (i32.const 0)
          )
          (catch_all
            (throw $e0)
            (i32.const 1)
          )
        )
      )
      (catch_all
        (i32.const 2)
      )
    )
  )

  (func (export "catch-3") (result i32)
    (try (result i32)
      (do (throw $e1 (i32.const 66)) (i32.const 0))
      (catch_all (i32.const 1))
    )
  )

  (func (export "catch-4") (result i32)
    (try (result i32)
      (do (throw $e1 (i32.const 66)) (i32.const 0))
      (catch $e1)
    )
  )

  (func (export "success-0") (result i32)
    (try (result i32)
      (do (i32.const 0))
      (catch_all (i32.const 1))
    )
  )

  (func (export "success-1") (result i32)
    (try (result i32)
      (do
        (try (result i32)
          (do (throw $e0) (i32.const 0))
          (catch_all (i32.const 1))
        )
      )
      (catch_all (i32.const 2))
    )
  )

  (func (export "uncaught-1")
    (throw $e0)
  )

  (func (export "uncaught-2") (result i32)
    (try (result i32)
      (do (throw $e0) (i32.const 0))
      (catch $e1)
    )
  )
)

(assert_return (invoke "catch-1") (i32.const 1))
(assert_return (invoke "catch-2") (i32.const 2))
(assert_return (invoke "catch-3") (i32.const 1))
(assert_return (invoke "catch-4") (i32.const 66))
(assert_return (invoke "success-0") (i32.const 0))
(assert_return (invoke "success-1") (i32.const 1))
(assert_exception (invoke "uncaught-1") "unhandled")
(assert_exception (invoke "uncaught-2") "unhandled")
