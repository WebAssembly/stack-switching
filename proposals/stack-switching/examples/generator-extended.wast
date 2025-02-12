(module $generator
  (type $ft0 (func))
  (type $ft1 (func (param i32)))
  ;; Type of continuations used by the generator:
  ;; No param or result types for $ct0: $generator function has no
  ;; parameters or return values.
  (type $ct0 (cont $ft0))

  ;; One param of type i32 for $ct1: An i32 is passed back to the
  ;; generator when resuming it, and $generator function has no return
  ;; values.
  (type $ct1 (cont $ft1))

  (func $print (import "spectest" "print_i32") (param i32))

  ;; Tag used to coordinate between generator and consumer: The i32 param
  ;; corresponds to the generated values passed to consumer, and the i32 result
  ;; corresponds to the value passed from the consumer back to the generator.
  (tag $gen (param i32) (result i32))


  ;; Simple generator yielding values from 100 down to 1.
  ;; If non-zero value received back from consumer, resets counter to 100.
  (func $generator
    (local $i i32)
    (local.set $i (i32.const 100))
    (loop $loop
      ;; Suspend execution, pass current value of $i to consumer.
      (suspend $gen (local.get $i))
      ;; We now have the flag on the stack given to us by the consumer, telling
      ;; us whether to reset the generator or not.
      (if (result i32)
        (then (i32.const 100))
        (else (i32.sub  (local.get $i) (i32.const 1)))
      )
      (local.tee $i)
      (br_if $loop)
    )
  )
  (elem declare func $generator)

  (func $consumer (export "consumer")
    ;; The continuation of the generator.
    (local $c0 (ref $ct0))
    ;; For temporarily storing the continuation received in handler.
    (local $c1 (ref $ct1))
    (local $i i32)
    ;; Create continuation executing function $generator.
    ;; Execution only starts when resumed for the first time.
    (local.set $c0 (cont.new $ct0 (ref.func $generator)))
    ;; Just counts how many values we have received so far.
    (local.set $i (i32.const 1))

    (loop $loop
      (block $on_gen (result i32 (ref $ct1))
        ;; Resume continuation $c0
        (resume $ct0 (on $gen $on_gen) (local.get $c0))
        ;; $generator returned: no more data
        (return)
      )
      ;; Generator suspended, stack now contains [i32 (ref $ct0)]
      ;; Save continuation to resume it in next iteration
      (local.set $c1)
      ;; Stack now contains the i32 value yielded by $generator
      (call $print)

      ;; Calculate flag to be passed back to generator:
      ;; Reset after the 42nd iteration
      (i32.eq (local.get $i) (i32.const 42))
      ;; Create continuation of type (ref $ct0) by binding flag value.
      (cont.bind $ct1 $ct0 (local.get $c1))
      (local.set $c0)

      (local.tee $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $loop)
    )
  )

)

(invoke "consumer")
