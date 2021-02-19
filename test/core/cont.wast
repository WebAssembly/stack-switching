(module
  (event $e1)
  (event $e2)

  (type $f1 (func))
  (type $k1 (cont (type $f1)))

  (func $f1 (export "unhandled-1")
    (cont.suspend $e1)
  )

  (func (export "unhandled-2")
    (block $h (result (ref $k1))
      (cont.resume (event $e2 $h) (cont.new (type $k1) (ref.func $f1)))
      (unreachable)
    )
    (drop)
  )

  (func (export "handled")
    (block $h (result (ref $k1))
      (cont.resume (event $e1 $h) (cont.new (type $k1) (ref.func $f1)))
      (unreachable)
    )
    (drop)
  )
)

(assert_suspension (invoke "unhandled-1") "unhandled")
(assert_suspension (invoke "unhandled-2") "unhandled")
(assert_return (invoke "handled"))


(module $state
  (event $get (result i32))
  (event $set (param i32) (result i32))

  (type $f (func (param i32) (result i32)))
  (type $k (cont (type $f)))

  (func $runner (param $s i32) (param $k (ref $k)) (result i32)
    (loop $loop
      (block $on_get (result (ref $k))
        (block $on_set (result i32 (ref $k))
          (cont.resume (event $get $on_get) (event $set $on_set)
            (local.get $s) (local.get $k)
          )
          (return)
        )
        ;; on set
        (local.set $k)
        (local.set $s)
        (br $loop)
      )
      ;; on get
      (local.set $k)
      (br $loop)
    )
    (unreachable)
  )

  (func $f (param i32) (result i32)
    (drop (cont.suspend $set (i32.const 7)))
    (i32.add
      (cont.suspend $get)
      (i32.mul
        (i32.const 2)
        (i32.add
          (cont.suspend $set (i32.const 3))
          (cont.suspend $get)
        )
      )
    )
  )

  (elem declare func $f)
  (func (export "run") (result i32)
    (call $runner (i32.const 0) (cont.new (type $k) (ref.func $f)))
  )
)

(assert_return (invoke "run") (i32.const 19))
