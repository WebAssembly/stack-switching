;; Actors via lightweight threads

;; actor interface
(module $actor
  (type $func (func))
  (type $cont (cont $func))

  (event $self (export "self") (result i32))
  (event $spawn (export "spawn") (param (ref $cont)) (result i32))
  (event $send (export "send") (param i32 i32))
  (event $recv (export "recv") (result i32))
)
(register "actor")

;; a simple example - pass a message through a chain of actors
(module $chain
  (type $func (func))
  (type $cont (cont $func))

  (type $i-func (func (param i32)))
  (type $i-cont (cont $i-func))

  (event $self (import "actor" "self") (result i32))
  (event $spawn (import "actor" "spawn") (param (ref $cont)) (result i32))
  (event $send (import "actor" "send") (param i32 i32))
  (event $recv (import "actor" "recv") (result i32))

  (elem declare func $next)

  (func $log (import "spectest" "print_i32") (param i32))

  (func $next (param $p i32)
    (local $s i32)
    (local.set $s (suspend $recv))
    (call $log (i32.const -1))
    (suspend $send (local.get $s) (local.get $p))
  )

  ;; send the message 42 through a chain of n actors
  (func $chain (export "chain") (param $n i32)
    (local $p i32)
    (local.set $p (suspend $self))

    (loop $l
      (if (i32.eqz (local.get $n))
        (then (suspend $send (i32.const 42) (local.get $p)))
        (else (local.set $p (suspend $spawn (cont.bind (type $cont) (local.get $p) (cont.new (type $i-cont) (ref.func $next)))))
              (local.set $n (i32.sub (local.get $n) (i32.const 1)))
              (br $l))
      )
    )
    (call $log (suspend $recv))
  )
)
(register "chain")

;; interface to lightweight threads
(module $lwt
  (type $func (func))
  (type $cont (cont $func))

  (event $yield (export "yield"))
  (event $fork (export "fork") (param (ref $cont)))
)
(register "lwt")

;; queue of threads
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

;; simple scheduler for lightweight threads
(module $scheduler
  (type $func (func))
  (type $cont (cont $func))

  (event $yield (import "lwt" "yield"))
  (event $fork (import "lwt" "fork") (param (ref $cont)))

  (func $queue-empty (import "queue" "queue-empty") (result i32))
  (func $dequeue (import "queue" "dequeue") (result (ref null $cont)))
  (func $enqueue (import "queue" "enqueue") (param $k (ref $cont)))

  (func $run (export "run") (param $main (ref $cont))
    (call $enqueue (local.get $main))
    (loop $l
      (if (call $queue-empty) (then (return)))
      (block $on_yield (result (ref $cont))
        (block $on_fork (result (ref $cont) (ref $cont))
          (resume (event $yield $on_yield) (event $fork $on_fork)
            (call $dequeue)
          )
          (br $l)  ;; thread terminated
        ) ;;   $on_fork (result (ref $cont) (ref $cont))
        (call $enqueue)  ;; current thread
        (call $enqueue)  ;; new thread
        (br $l)
      )
      ;;     $on_yield (result (ref $cont))
      (call $enqueue) ;; current thread
      (br $l)
    )
  )
)
(register "scheduler")

(module $mailboxes
  ;; Stupid implementation of mailboxes that raises an exception if
  ;; there are too many mailboxes or if more than one message is sent
  ;; to any given mailbox.
  ;;
  ;; Sufficient for the simple chain example.

  ;; -1 means empty

  (exception $too-many-mailboxes)
  (exception $too-many-messages)

  (memory 1)

  (global $msize (mut i32) (i32.const 0))
  (global $mmax i32 (i32.const 1024)) ;; maximum number of mailboxes

  (func $init (export "init")
     (memory.fill (i32.const 0) (i32.const -1) (i32.mul (global.get $mmax) (i32.const 4)))
  )

  (func $empty-mb (export "empty-mb") (param $mb i32) (result i32)
    (local $offset i32)
    (local.set $offset (i32.mul (local.get $mb) (i32.const 4)))
    (i32.eq (i32.load (local.get $offset)) (i32.const -1))
  )

  (func $new-mb (export "new-mb") (result i32)
     (local $mb i32)

     (if (i32.ge_u (global.get $msize) (global.get $mmax))
         (then (throw $too-many-mailboxes))
     )

     (local.set $mb (global.get $msize))
     (global.set $msize (i32.add (global.get $msize) (i32.const 1)))
     (return (local.get $mb))
  )

  (func $send-to-mb (export "send-to-mb") (param $v i32) (param $mb i32)
    (local $offset i32)
    (local.set $offset (i32.mul (local.get $mb) (i32.const 4)))
    (if (call $empty-mb (local.get $mb))
      (then (i32.store (local.get $offset) (local.get $v)))
      (else (throw $too-many-messages))
    )
  )

  (func $recv-from-mb (export "recv-from-mb") (param $mb i32) (result i32)
    (local $v i32)
    (local $offset i32)
    (local.set $offset (i32.mul (local.get $mb) (i32.const 4)))
    (local.set $v (i32.load (local.get $offset)))
    (i32.store (local.get $offset) (i32.const -1))
    (local.get $v)
  )
)
(register "mailboxes")

;; actors implemented via lightweight threads
(module $actor-as-lwt
  (type $func (func))
  (type $cont (cont $func))

  (type $i-func (func (param i32)))
  (type $i-cont (cont $i-func))

  (type $ic-func (func (param i32 (ref $cont))))
  (type $ic-cont (cont $ic-func))

  (func $log (import "spectest" "print_i32") (param i32))

  ;; lwt interface
  (event $yield (import "lwt" "yield"))
  (event $fork (import "lwt" "fork") (param (ref $cont)))

  ;; mailbox interface
  (func $init (import "mailboxes" "init"))
  (func $empty-mb (import "mailboxes" "empty-mb") (param $mb i32) (result i32))
  (func $new-mb (import "mailboxes" "new-mb") (result i32))
  (func $send-to-mb (import "mailboxes" "send-to-mb") (param $v i32) (param $mb i32))
  (func $recv-from-mb (import "mailboxes" "recv-from-mb") (param $mb i32) (result i32))

  ;; queue interface
  (func $queue-empty (import "queue" "queue-empty") (result i32))
  (func $dequeue (import "queue" "dequeue") (result (ref null $cont)))
  (func $enqueue (import "queue" "enqueue") (param $k (ref $cont)))

  ;; actor interface
  (event $self (import "actor" "self") (result i32))
  (event $spawn (import "actor" "spawn") (param (ref $cont)) (result i32))
  (event $send (import "actor" "send") (param i32 i32))
  (event $recv (import "actor" "recv") (result i32))

  (elem declare func $actk)

  (func $actk (param $mine i32) (param $nextk (ref $cont))
    (loop $l
      (block $on_self (result (ref $i-cont))
        (block $on_spawn (result (ref $cont) (ref $i-cont))
          (block $on_send (result i32 i32 (ref $cont))
            (block $on_recv (result (ref $i-cont))
               (resume (event $self $on_self)
                       (event $spawn $on_spawn)
                       (event $send $on_send)
                       (event $recv $on_recv)
                       (local.get $nextk)
               )
               (return)
            ) ;;   $on_recv (result (ref $i-cont))
            (let (local $ik (ref $i-cont))
              ;; block this thread until the mailbox is non-empty
              (loop $blocked
                (if (call $empty-mb (local.get $mine))
                    (then (suspend $yield)
                          (br $blocked))
                )
              )
              (local.set $nextk (cont.bind (type $cont) (call $recv-from-mb (local.get $mine)) (local.get $ik)))
            )
            (br $l)
          ) ;;   $on_send (result i32 i32 (ref $cont))
          (let (param i32 i32) (local $k (ref $cont))
            (call $send-to-mb)
            (local.set $nextk (local.get $k))
          )
          (br $l)
        ) ;;   $on_spawn (result (ref $cont) (ref $i-cont))
        (let (local $you (ref $cont)) (local $ik (ref $i-cont))
          (call $new-mb)
          (let (local $yours i32)
            (suspend $fork (cont.bind (type $cont)
                                      (local.get $yours)
                                      (local.get $you)
                                      (cont.new (type $ic-cont) (ref.func $actk))))
            (local.set $nextk (cont.bind (type $cont) (local.get $yours) (local.get $ik)))
          )
        )
        (br $l)
      ) ;;   $on_self (result (ref $i-cont))
      (let (local $ik (ref $i-cont))
        (local.set $nextk (cont.bind (type $cont) (local.get $mine) (local.get $ik)))
      )
      (br $l)
    )
  )

  (func $act (export "act") (param $k (ref $cont))
    (call $init)
    (call $actk (call $new-mb) (local.get $k))
  )
)
(register "actor-as-lwt")

;; composing the actor and scheduler handlers together
(module $actor-scheduler
  (type $func (func))
  (type $cont (cont $func))

  (type $cont-func (func (param (ref $cont))))
  (type $cont-cont (cont $cont-func))

  (elem declare func $act $scheduler)

  (func $act (import "actor-as-lwt" "act") (param $k (ref $cont)))
  (func $scheduler (import "scheduler" "run") (param $k (ref $cont)))

  (func $run-actor (export "run-actor") (param $k (ref $cont))
    (call $scheduler (cont.bind (type $cont) (local.get $k) (cont.new (type $cont-cont) (ref.func $act))))
  )
)
(register "actor-scheduler")

(module
  (type $func (func))
  (type $cont (cont $func))

  (type $i-func (func (param i32)))
  (type $i-cont (cont $i-func))

  (elem declare func $chain)

  (func $run-actor (import "actor-scheduler" "run-actor") (param $k (ref $cont)))
  (func $chain (import "chain" "chain") (param $n i32))

  (func $run-chain (export "run-chain") (param $n i32)
    (call $run-actor (cont.bind (type $cont) (local.get $n) (cont.new (type $i-cont) (ref.func $chain))))
  )
)

(invoke "run-chain" (i32.const 64))
