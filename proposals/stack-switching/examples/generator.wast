(module $generator
  (type $ft (func))
  ;; Type of continuations used by the generator:
  ;; No need for param or result types: No data data passed back to the
  ;; generator when resuming it, and $generator function has no return
  ;; values.
  (type $ct (cont $ft))

  (func $print (import "spectest" "print_i32") (param i32))

  ;; Tag used to coordinate between generator and consumer: The i32 param
  ;; corresponds to the generated values passed to consumer; no values passed
  ;; back from generator to consumer.
  (tag $gen (param i32))


  ;; Simple generator yielding values from 100 down to 1.
  (func $generator
    (local $i i32)
    (local.set $i (i32.const 100))
    (loop $loop
      ;; Suspend execution, pass current value of $i to consumer.
      (suspend $gen (local.get $i))
      ;; Decrement $i and exit loop once $i reaches 0.
      (local.tee $i (i32.sub (local.get $i) (i32.const 1)))
      (br_if $loop)
    )
  )
  (elem declare func $generator)

  (func $consumer (export "consumer")
    (local $c (ref $ct))
    ;; Create continuation executing function $generator.
    ;; Execution only starts when resumed for the first time.
    (local.set $c (cont.new $ct (ref.func $generator)))

    (loop $loop
      (block $on_gen (result i32 (ref $ct))
        ;; Resume continuation $c.
        (resume $ct (on $gen $on_gen) (local.get $c))
        ;; $generator returned: no more data.
        (return)
      )
      ;; Generator suspended, stack now contains [i32 (ref $ct)]
      ;; Save continuation to resume it in next iteration
      (local.set $c)
      ;; Stack now contains the i32 value yielded by $generator
      (call $print)

      (br $loop)
    )
  )

)

(invoke "consumer")
