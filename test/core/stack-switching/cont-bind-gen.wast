(module
  (tag $gen (param i32) (result i32))

  (type $f_gen (func (result i32)))
  (type $k_gen (cont $f_gen))

  (type $f_resume (func (param i32) (result i32)))
  (type $k_resume (cont $f_resume))


  (func $generator (result i32)
    (local $i i32)
    (local.set $i (i32.const 2))
    (loop $loop (result i32)
      (if (result i32) (i32.eqz (local.get $i))
        (then (i32.const -1))
        (else
          (local.set $i (suspend $gen (local.get $i)))
          (br $loop)
          (i32.const 0)
        )
      )
    )
  )
  (elem declare func $generator)

  (func (export "run") (result i32)
    (local $k_gen (ref null $k_gen))
    (local $k_resume (ref null $k_resume))
    (local $val i32)

    (local.set $k_gen (cont.new $k_gen (ref.func $generator)))

    (block $on_suspend (result i32 (ref $k_resume))
      (resume $k_gen (on $gen $on_suspend) (local.get $k_gen))
      (return)
    )
    (local.set $k_resume)
    (local.set $val)

    (i32.sub (local.get $val) (i32.const 1))
    (local.get $k_resume)
    (cont.bind $k_resume $k_gen)
    (local.set $k_gen)

    (block $on_suspend2 (result i32 (ref $k_resume))
      (resume $k_gen (on $gen $on_suspend2) (local.get $k_gen))
      (return)
    )
    (local.set $k_resume)
    (local.set $val)

    (i32.sub (local.get $val) (i32.const 1))
    (local.get $k_resume)
    (cont.bind $k_resume $k_gen)
    (local.set $k_gen)

    (resume $k_gen (local.get $k_gen))
  )
)

(assert_return (invoke "run") (i32.const -1))
