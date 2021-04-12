;; functional lightweight threads

;; interface to lightweight threads
(module $lwt
  (type $func (func))
  (event $yield (export "yield"))
  (event $fork (export "fork") (param (ref $func)))
)
(register "lwt")

(module $example
  (type $func (func))
  (type $cont (cont $func))
  (event $yield (import "lwt" "yield"))
  (event $fork (import "lwt" "fork") (param (ref $func)))

  (func $log (import "spectest" "print_i32") (param i32))

  (elem declare func $thread1 $thread2 $thread3)

  (func $main (export "main")
    (call $log (i32.const 0))
    (suspend $fork (ref.func $thread1))
    (call $log (i32.const 1))
    (suspend $fork (ref.func $thread2))
    (call $log (i32.const 2))
    (suspend $fork (ref.func $thread3))
    (call $log (i32.const 3))
  )

  (func $thread1
    (call $log (i32.const 10))
    (suspend $yield)
    (call $log (i32.const 11))
    (suspend $yield)
    (call $log (i32.const 12))
  )

  (func $thread2
    (call $log (i32.const 20))
    (suspend $yield)
    (call $log (i32.const 21))
    (suspend $yield)
    (call $log (i32.const 22))
  )

  (func $thread3
    (call $log (i32.const 30))
    (suspend $yield)
    (call $log (i32.const 31))
    (suspend $yield)
    (call $log (i32.const 32))
  )
)
(register "example")

(module $queue
  (type $func (func))
  (type $cont (cont $func))

  ;; Table as simple queue (keeping it simple, no ring buffer)
  (table $queue 0 (ref null $cont))
  (global $qdelta i32 (i32.const 10))
  (global $qback (mut i32) (i32.const 0))
  (global $qfront (mut i32) (i32.const 0))

  (func $queue-empty (export "queue-empty") (result i32)
    (i32.eq (global.get $qfront) (global.get $qback))
  )

  (func $dequeue (export "dequeue") (result (ref null $cont))
    (local $i i32)
    (if (call $queue-empty)
      (then (return (ref.null $cont)))
    )
    (local.set $i (global.get $qfront))
    (global.set $qfront (i32.add (local.get $i) (i32.const 1)))
    (table.get $queue (local.get $i))
  )

  (func $enqueue (export "enqueue") (param $k (ref $cont))
    ;; Check if queue is full
    (if (i32.eq (global.get $qback) (table.size $queue))
      (then
        ;; Check if there is enough space in the front to compact
        (if (i32.lt_u (global.get $qfront) (global.get $qdelta))
          (then
            ;; Space is below threshold, grow table instead
            (drop (table.grow $queue (ref.null $cont) (global.get $qdelta)))
          )
          (else
            ;; Enough space, move entries up to head of table
            (global.set $qback (i32.sub (global.get $qback) (global.get $qfront)))
            (table.copy $queue $queue
              (i32.const 0)         ;; dest = new front = 0
              (global.get $qfront)  ;; src = old front
              (global.get $qback)   ;; len = new back = old back - old front
            )
            (table.fill $queue      ;; null out old entries to avoid leaks
              (global.get $qback)   ;; start = new back
              (ref.null $cont)      ;; init value
              (global.get $qfront)  ;; len = old front = old front - new front
            )
            (global.set $qfront (i32.const 0))
          )
        )
      )
    )
    (table.set $queue (global.get $qback) (local.get $k))
    (global.set $qback (i32.add (global.get $qback) (i32.const 1)))
  )
)
(register "queue")

(module $schedulers
  (type $func (func))
  (type $cont (cont $func))

  (event $yield (import "lwt" "yield"))
  (event $fork (import "lwt" "fork") (param (ref $func)))

  (func $queue-empty (import "queue" "queue-empty") (result i32))
  (func $dequeue (import "queue" "dequeue") (result (ref null $cont)))
  (func $enqueue (import "queue" "enqueue") (param $k (ref $cont)))

  ;; four different schedulers:
  ;;   * lwt-kt and lwt-tk don't yield on encountering a fork
  ;;     1) lwt-kt runs the continuation, queuing up the new thread for later
  ;;     2) lwt-tk runs the new thread first, queuing up the continuation for later
  ;;   * lwt-ykt and lwt-ytk do yield on encountering a fork
  ;;     3) lwt-ykt runs the continuation, queuing up the new thread for later
  ;;     4) lwt-ytk runs the new thread first, queuing up the continuation for later

  ;; no yield on fork, continuation first
  (func $lwt-kt (param $r (ref null $cont))
    (if (ref.is_null (local.get $r)) (then (return)))
    (block $on_yield (result (ref $cont))
      (block $on_fork (result (ref $func) (ref $cont))
        (resume (event $yield $on_yield) (event $fork $on_fork) (local.get $r))
        (call $dequeue)
        (return_call $lwt-tk)
      ) ;;   $on_fork (result (ref $func) (ref $cont))
      (let (param (ref $func)) (result (ref $cont)) (local $r (ref $cont))
      (cont.new (type $cont))
      (call $enqueue)
      (return_call $lwt-tk (local.get $r)))
    ) ;;   $on_yield (result (ref $cont))
    (call $enqueue)
    (call $dequeue)
    (return_call $lwt-tk)
  )

  ;; no yield on fork, new thread first
  (func $lwt-tk (param $r (ref null $cont))
    (if (ref.is_null (local.get $r)) (then (return)))
    (block $on_yield (result (ref $cont))
      (block $on_fork (result (ref $func) (ref $cont))
        (resume (event $yield $on_yield) (event $fork $on_fork) (local.get $r))
        (call $dequeue)
        (return_call $lwt-kt)
      ) ;;   $on_fork (result (ref $func) (ref $cont))
      (call $enqueue)
      (return_call $lwt-kt (cont.new (type $cont)))
    ) ;;   $on_yield (result (ref $cont))
    (call $enqueue)
    (call $dequeue)
    (return_call $lwt-kt)
  )

  ;; yield on fork, continuation first
  (func $lwt-ykt (param $r (ref null $cont))
    (if (ref.is_null (local.get $r)) (then (return)))
    (block $on_yield (result (ref $cont))
      (block $on_fork (result (ref $func) (ref $cont))
        (resume (event $yield $on_yield) (event $fork $on_fork) (local.get $r))
        (call $dequeue)
        (return_call $lwt-ykt)
      ) ;;   $on_fork (result (ref $func) (ref $cont))
      (call $enqueue)
      (cont.new (type $cont))
      (call $enqueue)
      (return_call $lwt-ykt (call $dequeue))
    ) ;;   $on_yield (result (ref $cont))
    (call $enqueue)
    (call $dequeue)
    (return_call $lwt-ykt)
  )

  ;; yield on fork, new thread first
  (func $lwt-ytk (param $r (ref null $cont))
    (if (ref.is_null (local.get $r)) (then (return)))
    (block $on_yield (result (ref $cont))
      (block $on_fork (result (ref $func) (ref $cont))
        (resume (event $yield $on_yield) (event $fork $on_fork) (local.get $r))
        (call $dequeue)
        (return_call $lwt-ytk)
      ) ;;   $on_fork (result (ref $func) (ref $cont))
      (let (param (ref $func)) (local $k (ref $cont))
        (cont.new (type $cont))
        (call $enqueue)
        (call $enqueue (local.get $k))
      )
      (return_call $lwt-ytk (call $dequeue))
    ) ;;   $on_yield (result (ref $cont))
    (call $enqueue)
    (call $dequeue)
    (return_call $lwt-ytk)
  )

  (func $scheduler1 (export "scheduler1") (param $main (ref $func))
     (call $lwt-kt (cont.new (type $cont) (local.get $main)))
  )
  (func $scheduler2 (export "scheduler2") (param $main (ref $func))
     (call $lwt-tk (cont.new (type $cont) (local.get $main)))
  )
  (func $scheduler3 (export "scheduler3") (param $main (ref $func))
     (call $lwt-ykt (cont.new (type $cont) (local.get $main)))
  )
  (func $scheduler4 (export "scheduler4") (param $main (ref $func))
     (call $lwt-ytk (cont.new (type $cont) (local.get $main)))
  )
)

(register "schedulers")

(module
  (type $func (func))
  (type $cont (cont $func))

  (func $scheduler1 (import "schedulers" "scheduler1") (param $main (ref $func)))
  (func $scheduler2 (import "schedulers" "scheduler2") (param $main (ref $func)))
  (func $scheduler3 (import "schedulers" "scheduler3") (param $main (ref $func)))
  (func $scheduler4 (import "schedulers" "scheduler4") (param $main (ref $func)))

  (func $log (import "spectest" "print_i32") (param i32))

  (func $main (import "example" "main"))

  (elem declare func $main)

  (func (export "run")
    (call $log (i32.const -1))
    (call $scheduler1 (ref.func $main))
    (call $log (i32.const -2))
    (call $scheduler2 (ref.func $main))
    (call $log (i32.const -3))
    (call $scheduler3 (ref.func $main))
    (call $log (i32.const -4))
    (call $scheduler4 (ref.func $main))
    (call $log (i32.const -5))
  )
)

(invoke "run")

