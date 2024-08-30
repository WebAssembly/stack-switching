(module $generator
  (type $ft (func))
  ;; Types of continuations used by the generator:
  ;; No need for param or result types: No data data passed back to the
  ;; generator when resuming it, and $generator function has no return
  ;; values.
  (type $ct (cont $ft))

  ;; Tag used to coordinate between generator and consumer: The i32 param
  ;; corresponds to the generated values passed; no values passed back from
  ;; generator to consumer.
  (tag $yield (param i32))


  (func $print (import "spectest" "print_i32") (param i32))

  ;; Simple generator yielding values from 100 down to 1
  (func $generator
    (local $i i32)
    (local.set $i (i32.const 100))
    (loop $l
      ;; Suspend execution, pass current value of $i to consumer
      (suspend $yield (local.get $i))
      ;; Decrement $i and exit loop once $i reaches 0
      (local.tee $i (i32.sub (local.get $i) (i32.const 1)))
      (br_if $l)
    )
  )
  (elem declare func $generator)

  (func $consumer
    (local $c (ref $ct))
    ;; Create continuation executing function $generator.
    ;; Execution only starts when resumed for the first time.
    (local.set $c (cont.new $ct (ref.func $generator)))

    (loop $loop
      (block $on_yield (result i32 (ref $ct))
        ;; Resume continuation $c
        (resume $ct (on $yield $on_yield) (local.get $c))
        ;; $generator returned: no more data
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
