;; Test the minimal "exception handling" extension

(module
  (func (export "catch-1") (result i32)
    (try (result i32)
      (do
        throw
        i32.const 0)
      (catch
        (i32.const 1))))

  (func (export "catch-2") (result i32)
    (try (result i32)
      (do
        (try (result i32)
          (do
            throw
            i32.const 0)
          (catch
            throw
            i32.const 1)))
      (catch
        (i32.const 2))))

  (func (export "uncaught")
    (throw))
)

(assert_return (invoke "catch-1") (i32.const 1))
(assert_return (invoke "catch-2") (i32.const 2))
(assert_uncaught (invoke "uncaught") "uncaught exception")
