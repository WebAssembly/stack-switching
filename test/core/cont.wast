;; Unhandled events

(module
  (exception $exn)
  (event $e1)
  (event $e2)

  (type $f1 (func))
  (type $k1 (cont $f1))

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

  (elem declare func $f2)
  (func $f2
    (throw $exn)
  )

  (func (export "uncaught-1")
    (block $h (result (ref $k1))
      (cont.resume (event $e1 $h) (cont.new (type $k1) (ref.func $f2)))
      (unreachable)
    )
    (drop)
  )

  (func (export "uncaught-2")
    (block $h (result (ref $k1))
      (cont.resume (event $e1 $h) (cont.new (type $k1) (ref.func $f1)))
      (unreachable)
    )
    (cont.throw $exn)
  )
)

(assert_suspension (invoke "unhandled-1") "unhandled")
(assert_suspension (invoke "unhandled-2") "unhandled")
(assert_return (invoke "handled"))
(assert_exception (invoke "uncaught-1") "unhandled")
(assert_exception (invoke "uncaught-2") "unhandled")


;; Simple state example

(module $state
  (event $get (result i32))
  (event $set (param i32) (result i32))

  (type $f (func (param i32) (result i32)))
  (type $k (cont $f))

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


;; Simple scheduler example

(module $scheduler
  (type $proc (func))
  (type $cont (cont $proc))

  (event $yield (export "yield"))
  (event $spawn (export "spawn") (param (ref $proc)))

  (table $queue 0 (ref null $cont))
  (global $qdelta i32 (i32.const 10))
  (global $qback (mut i32) (i32.const 0))
  (global $qfront (mut i32) (i32.const 0))

  (func $queue-empty (result i32)
    (i32.eq (global.get $qfront) (global.get $qback))
  )

  (func $dequeue (result (ref null $cont))
    (local $k (ref null $cont))
    ;; Check if queue is empty
    (if (call $queue-empty)
      (then (return (ref.null $cont)))
    )
    (local.set $k (table.get $queue (global.get $qfront)))
    (global.set $qfront (i32.add (global.get $qfront) (i32.const 1)))
    (local.get $k)
  )

  (func $enqueue (param $k (ref $cont))
    (local $qlen i32)
    ;; Check if queue is full
    (if (i32.eq (global.get $qback) (table.size $queue))
      (then
        ;; Check if there is enough space in the front to compact
        (if (i32.lt_u (global.get $qfront) (global.get $qdelta))
          (then
            ;; Not enough room, grow table
            (drop (table.grow $queue (ref.null $cont) (global.get $qdelta)))
          )
          (else
            ;; Enough room, move entries down
            (local.set $qlen (i32.sub (global.get $qback) (global.get $qfront)))
            (table.copy $queue $queue
              (i32.const 0)
              (global.get $qfront)
              (local.get $qlen)
            )
            (table.fill $queue
              (local.get $qlen)
              (ref.null $cont)
              (global.get $qfront)
            )
            (global.set $qfront (i32.const 0))
            (global.set $qback (local.get $qlen))
          )
        )
      )
    )
    (table.set $queue (global.get $qback) (local.get $k))
    (global.set $qback (i32.add (global.get $qback) (i32.const 1)))
  )

  (func $scheduler (export "scheduler") (param $main (ref $proc))
    (call $enqueue (cont.new (type $cont) (local.get $main)))
    (loop $l
      (if (call $queue-empty) (then (return)))
      (block $on_yield (result (ref $cont))
        (block $on_spawn (result (ref $proc) (ref $cont))
          (cont.resume (event $yield $on_yield) (event $spawn $on_spawn)
            (call $dequeue)
          )
          (br $l)  ;; thread terminated
        )
        ;; on $spawn, proc and cont on stack
        (call $enqueue)             ;; continuation of old thread
        (cont.new (type $cont))
        (call $enqueue)             ;; new thread
        (br $l)
      )
      ;; on $yield, cont on stack
      (call $enqueue)
      (br $l)
    )
  )
)

(register "scheduler")

(module
  (type $proc (func))
  (type $cont (cont $proc))
  (event $yield (import "scheduler" "yield"))
  (event $spawn (import "scheduler" "spawn") (param (ref $proc)))
  (func $scheduler (import "scheduler" "scheduler") (param $main (ref $proc)))

  (func $log (import "spectest" "print_i32") (param i32))

  (elem declare func $main $thread1 $thread2 $thread3)

  (func $main
    (call $log (i32.const 0))
    (cont.suspend $spawn (ref.func $thread1))
    (call $log (i32.const 1))
    (cont.suspend $spawn (ref.func $thread2))
    (call $log (i32.const 2))
    (cont.suspend $spawn (ref.func $thread3))
    (call $log (i32.const 3))
  )

  (func $thread1
    (call $log (i32.const 10))
    (cont.suspend $yield)
    (call $log (i32.const 11))
    (cont.suspend $yield)
    (call $log (i32.const 12))
    (cont.suspend $yield)
    (call $log (i32.const 13))
  )

  (func $thread2
    (call $log (i32.const 20))
    (cont.suspend $yield)
    (call $log (i32.const 21))
  )

  (func $thread3
    (call $log (i32.const 30))
    (cont.suspend $yield)
    (call $log (i32.const 31))
    (cont.suspend $yield)
    (call $log (i32.const 32))
  )

  (func (export "run")
    (call $log (i32.const -1))
    (call $scheduler (ref.func $main))
    (call $log (i32.const -2))
  )
)

(assert_return (invoke "run"))
