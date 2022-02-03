;; Actors via lightweight threads

;; actor interface
(module $actor
  (type $func (func))       ;; [] -> []
  (type $cont (cont $func)) ;; cont ([] -> [])

  ;; self : [i32] -> []
  ;; spawn : [cont ([] -> [])] -> [i32]
  ;; send : [i32 i32] -> []
  ;; recv : [] -> [i32]
  (tag $self (export "self") (result i32))
  (tag $spawn (export "spawn") (param (ref $cont)) (result i32))
  (tag $send (export "send") (param i32 i32))
  (tag $recv (export "recv") (result i32))
)
(register "actor")

;; a simple example - pass a message through a chain of actors
(module $chain
  (type $func (func))       ;; [] -> []
  (type $cont (cont $func)) ;; cont ([] -> [])

  (type $i-func (func (param i32))) ;; [i32] -> []
  (type $i-cont (cont $i-func))     ;; cont ([i32] -> [])

  ;; self : [i32] -> []
  ;; spawn : [cont ([] -> [])] -> [i32]
  ;; send : [i32 i32] -> []
  ;; recv : [] -> [i32]
  (tag $self (import "actor" "self") (result i32))
  (tag $spawn (import "actor" "spawn") (param (ref $cont)) (result i32))
  (tag $send (import "actor" "send") (param i32 i32))
  (tag $recv (import "actor" "recv") (result i32))

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

;; queues of threads and mailboxes
(module $queue
  (type $func (func))       ;; [] -> []
  (type $cont (cont $func)) ;; cont ([] -> [])

  (func $log (import "spectest" "print_i32") (param i32))

  ;; table (threads) and memory (mailboxes) as simple queues
  (table $queue 0 (ref null $cont))
  (memory 1)

  (exception $too-many-mailboxes)

  (global $qdelta i32 (i32.const 10))

  (global $qback-k (mut i32) (i32.const 0))
  (global $qfront-k (mut i32) (i32.const 0))

  (func $queue-empty-k (export "queue-empty") (result i32)
    (i32.eq (global.get $qfront-k) (global.get $qback-k))
  )

  (func $dequeue-k (export "dequeue-k") (result (ref null $cont))
    (local $i i32)
    (if (call $queue-empty-k)
      (then (return (ref.null $cont)))
    )
    (local.set $i (global.get $qfront-k))
    (global.set $qfront-k (i32.add (local.get $i) (i32.const 1)))
    (table.get $queue (local.get $i))
  )

  (func $enqueue-k (export "enqueue-k") (param $k (ref $cont))
    ;; Check if queue is full
    (if (i32.eq (global.get $qback-k) (table.size $queue))
      (then
        ;; Check if there is enough space in the front to compact
        (if (i32.lt_u (global.get $qfront-k) (global.get $qdelta))
          (then
            ;; Space is below threshold, grow table instead
            (drop (table.grow $queue (ref.null $cont) (global.get $qdelta)))
          )
          (else
            ;; Enough space, move entries up to head of table
            (global.set $qback-k (i32.sub (global.get $qback-k) (global.get $qfront-k)))
            (table.copy $queue $queue
              (i32.const 0)         ;; dest = new front = 0
              (global.get $qfront-k)  ;; src = old front
              (global.get $qback-k)   ;; len = new back = old back - old front
            )
            (table.fill $queue      ;; null out old entries to avoid leaks
              (global.get $qback-k)   ;; start = new back
              (ref.null $cont)      ;; init value
              (global.get $qfront-k)  ;; len = old front = old front - new front
            )
            (global.set $qfront-k (i32.const 0))
          )
        )
      )
    )
    (table.set $queue (global.get $qback-k) (local.get $k))
    (global.set $qback-k (i32.add (global.get $qback-k) (i32.const 1)))
  )

  (global $qback-mb (mut i32) (i32.const 0))
  (global $qfront-mb (mut i32) (i32.const 0))

  (func $queue-empty-mb (export "queue-empty-mb") (result i32)
    (i32.eq (global.get $qfront-mb) (global.get $qback-mb))
  )

  (func $dequeue-mb (export "dequeue-mb") (result i32)
    (local $i i32)
    (local $mb i32)
    (if (call $queue-empty-mb)
      (then (return (i32.const -1)))
    )
    (local.set $i (global.get $qfront-mb))
    (global.set $qfront-mb (i32.add (local.get $i) (i32.const 1)))
    (local.set $mb (i32.load (i32.mul (local.get $i) (i32.const 4))))
    (return (local.get $mb))
  )

  (func $enqueue-mb (export "enqueue-mb") (param $mb i32)
    ;; Check if queue is full
    (if (i32.eq (global.get $qback-mb) (i32.const 16383))
      (then
        ;; Check if there is enough space in the front to compact
        (if (i32.lt_u (global.get $qfront-mb) (global.get $qdelta))
          (then
            ;; Space is below threshold, throw exception
            (throw $too-many-mailboxes)
          )
          (else
            ;; Enough space, move entries up to head of table
            (global.set $qback-mb (i32.sub (global.get $qback-mb) (global.get $qfront-mb)))
            (memory.copy
              (i32.const 0)                                    ;; dest = new front = 0
              (i32.mul (global.get $qfront-mb) (i32.const 4))  ;; src = old front
              (i32.mul (global.get $qback-mb) (i32.const 4))   ;; len = new back = old back - old front
            )
            (memory.fill                                       ;; null out old entries to avoid leaks
              (i32.mul (global.get $qback-mb) (i32.const 4))   ;; start = new back
              (i32.const -1)                                   ;; init value
              (i32.mul (global.get $qfront-mb) (i32.const 4))  ;; len = old front = old front - new front
            )
            (global.set $qfront-mb (i32.const 0))
          )
        )
      )
    )
    (i32.store (i32.mul (global.get $qback-mb) (i32.const 4)) (local.get $mb))
    (global.set $qback-mb (i32.add (global.get $qback-mb) (i32.const 1)))
  )
)
(register "queue")

(module $mailboxes
  ;; Stupid implementation of mailboxes that raises an exception if
  ;; there are too many mailboxes or if more than one message is sent
  ;; to any given mailbox.
  ;;
  ;; Sufficient for the simple chain example.

  ;; -1 means empty

  (func $log (import "spectest" "print_i32") (param i32))

  (exception $too-many-mailboxes)
  (exception $too-many-messages)

  (memory 1)

  (global $msize (mut i32) (i32.const 0)) ;; current number of mailboxes
  (global $mmax i32 (i32.const 1024))     ;; maximum number of mailboxes

  (func $init (export "init")
     (global.set $msize (i32.const 0))
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


;; a simple example - pass a message through a chain of actors
(module $chain
  (type $func (func))
  (type $cont (cont $func))

  (type $i-func (func (param i32)))
  (type $i-cont (cont $i-func))

  (tag $self (import "actor" "self") (result i32))
  (tag $spawn (import "actor" "spawn") (param (ref $cont)) (result i32))
  (tag $send (import "actor" "send") (param i32 i32))
  (tag $recv (import "actor" "recv") (result i32))

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

  (tag $yield (export "yield"))
  (tag $fork (export "fork") (param (ref $cont)))
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

  (tag $yield (import "lwt" "yield"))
  (tag $fork (import "lwt" "fork") (param (ref $cont)))

  (func $queue-empty (import "queue" "queue-empty") (result i32))
  (func $dequeue (import "queue" "dequeue") (result (ref null $cont)))
  (func $enqueue (import "queue" "enqueue") (param $k (ref $cont)))

  (func $run (export "run") (param $main (ref $cont))
    (call $enqueue (local.get $main))
    (loop $l
      (if (call $queue-empty) (then (return)))
      (block $on_yield (result (ref $cont))
        (block $on_fork (result (ref $cont) (ref $cont))
          (resume (tag $yield $on_yield) (tag $fork $on_fork)
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
  (type $func (func))       ;; [] -> []
  (type $cont (cont $func)) ;; cont ([] -> [])

  (type $i-func (func (param i32))) ;; [i32] -> []
  (type $i-cont (cont $i-func))     ;; cont ([i32] -> [])

  (type $ic-func (func (param i32 (ref $cont)))) ;; [i32 (cont ([] -> []))] -> []
  (type $ic-cont (cont $ic-func))                ;; cont ([i32 (cont ([] -> []))] -> [])

  (func $log (import "spectest" "print_i32") (param i32))

  ;; lwt interface
  (tag $yield (import "lwt" "yield"))
  (tag $fork (import "lwt" "fork") (param (ref $cont)))

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
  ;; self : [i32] -> []
  ;; spawn : [cont ([] -> [])] -> [i32]
  ;; send : [i32 i32] -> []
  ;; recv : [] -> [i32]
  (tag $self (import "actor" "self") (result i32))
  (tag $spawn (import "actor" "spawn") (param (ref $cont)) (result i32))
  (tag $send (import "actor" "send") (param i32 i32))
  (tag $recv (import "actor" "recv") (result i32))

  (elem declare func $actk)

  (func $actk (param $mine i32) (param $nextk (ref $cont))
    (loop $l
      (block $on_self (result (ref $i-cont))
        (block $on_spawn (result (ref $cont) (ref $i-cont))
          (block $on_send (result i32 i32 (ref $cont))
            (block $on_recv (result (ref $i-cont))
               (resume (tag $self $on_self)
                       (tag $spawn $on_spawn)
                       (tag $send $on_send)
                       (tag $recv $on_recv)
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
  (type $func (func))       ;; [] -> []
  (type $cont (cont $func)) ;; cont ([] -> [])

  (type $cont-func (func (param (ref $cont)))) ;; [cont ([] -> []) -> []]
  (type $cont-cont (cont $cont-func))          ;; cont ([cont ([] -> []) -> []])

  (elem declare func $act $scheduler)

  (func $act (import "actor-as-lwt" "act") (param $k (ref $cont)))
  (func $scheduler (import "scheduler" "run") (param $k (ref $cont)))

  (func $run-actor (export "run-actor") (param $k (ref $cont))
    (call $scheduler (cont.bind (type $cont) (local.get $k) (cont.new (type $cont-cont) (ref.func $act))))
  )
)
(register "actor-scheduler")

(module
  (type $func (func))       ;; [] -> []
  (type $cont (cont $func)) ;; cont ([] -> [])

  (type $i-func (func (param i32))) ;; [i32] -> []
  (type $i-cont (cont $i-func))     ;; cont ([i32] -> [])

  (elem declare func $chain)

  (func $run-actor (import "actor-scheduler" "run-actor") (param $k (ref $cont)))
  (func $chain (import "chain" "chain") (param $n i32))

  (func $run-chain (export "run-chain") (param $n i32)
    (call $run-actor (cont.bind (type $cont) (local.get $n) (cont.new (type $i-cont) (ref.func $chain))))
  )
)

(invoke "run-chain" (i32.const 64))
