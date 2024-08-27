;; queue of threads
(module $queue
  (rec
    (type $ft (func (param (ref null $ct))))
    (type $ct (cont $ft)))

  ;; Table as simple queue (keeping it simple, no ring buffer)
  (table $queue 0 (ref null $ct))
  (global $qdelta i32 (i32.const 10))
  (global $qback (mut i32) (i32.const 0))
  (global $qfront (mut i32) (i32.const 0))

  (func $queue_empty (export "queue-empty") (result i32)
    (i32.eq (global.get $qfront) (global.get $qback))
  )

  (func $dequeue (export "dequeue") (result (ref null $ct))
    (local $i i32)
    (if (call $queue_empty)
      (then (return (ref.null $ct)))
    )
    (local.set $i (global.get $qfront))
    (global.set $qfront (i32.add (local.get $i) (i32.const 1)))
    (table.get $queue (local.get $i))
  )

  (func $enqueue (export "enqueue") (param $k (ref null $ct))
    ;; Check if queue is full
    (if (i32.eq (global.get $qback) (table.size $queue))
      (then
        ;; Check if there is enough space in the front to compact
        (if (i32.lt_u (global.get $qfront) (global.get $qdelta))
          (then
            ;; Space is below threshold, grow table instead
            (drop (table.grow $queue (ref.null $ct) (global.get $qdelta)))
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
              (ref.null $ct)      ;; init value
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

(module $scheduler2
  (rec
    (type $ft (func (param (ref null $ct))))
    ;; Continuation type of all tasks
    (type $ct (cont $ft))
  )

  (func $task_enqueue (import "queue" "enqueue") (param (ref null $ct)))
  (func $task_dequeue (import "queue" "dequeue") (result (ref null $ct)))
  (func $task_queue-empty (import "queue" "queue-empty") (result i32))
  (func $print_i32 (import "spectest" "print_i32") (param i32))

  ;; Tag used to yield execution in one task and resume another one.
  (tag $yield)

  ;; Entry point, becomes parent of all tasks.
  ;; Only acts as scheduler when tasks finish.
  (func $entry (param $initial_task (ref $ft))
    (local $next_task (ref null $ct))

    ;; initialise $task_queue with initial task
    (call $task_enqueue (cont.new $ct (local.get $initial_task)))

    (loop $resume_next
      (if (call $task_queue-empty)
        (then (return))
        (else (local.set $next_task (call $task_dequeue)))
      )
      (resume $ct (on $yield switch)
        (ref.null $ct) (local.get $next_task))
      ;; task finished execution: loop to pick next one
      (br $resume_next)
    )
  )

  ;; To simplify the example, all task_i functions execute this function. Each
  ;; task has an $id, but this is only used for printing.
  ;; $to_spawn represents another task that this function will add to the task
  ;; queue, unless the reference is null.
  ;; $c corresponds to the continuation parameter of the original $task_i
  ;; functions.
  ;; This means that it is the previous continuation we just switch-ed away
  ;; from, or a null reference if the task was resumed from $entry.
  (func $task_impl
        (param $id i32)
        (param $to_spawn (ref null $ft))
        (param $c (ref null $ct))

    (if (ref.is_null (local.get $c))
      (then)
      (else (call $task_enqueue (local.get $c))))

    (if (ref.is_null (local.get $to_spawn))
      (then)
      (else (call $task_enqueue (cont.new $ct (local.get $to_spawn)))))

    (call $print_i32 (local.get $id))
    (call $yield_to_next)
    (call $print_i32 (local.get $id))
  )

  ;; The actual $task_i functions simply call $task_impl, with i as the value
  ;; for $id, and $task_(i+1) as the task to spawn, except for $task_4, which
  ;; does not spawn another task.
  ;;
  ;; The observant reader may note that all $task_i functions may be seen as
  ;; partial applications of $task_impl.
  ;; Indeed, we could obtain *continuations* running each $task_i from a
  ;; continuation running $task_impl and cont.bind.

  (func $task_4 (type $ft)
    (i32.const 4)
    (ref.null $ft)
    (local.get 0)
    (call $task_impl)
  )
  (elem declare func $task_4)

  (func $task_3 (type $ft)
    (i32.const 3)
    (ref.func $task_4)
    (local.get 0)
    (call $task_impl)
  )
  (elem declare func $task_3)

  (func $task_2 (type $ft)
    (i32.const 2)
    (ref.func $task_3)
    (local.get 0)
    (call $task_impl)
  )
  (elem declare func $task_2)

  (func $task_1 (type $ft)
    (i32.const 1)
    (ref.func $task_2)
    (local.get 0)
    (call $task_impl)
  )
  (elem declare func $task_1)


  ;; Determines next task to switch to directly.
  (func $yield_to_next
    (local $next_task (ref null $ct))
    (block $done
      (br_if $done (call $task_queue-empty))
      ;; Switch to $next_task.
      ;; The switch instruction implicitly passes a reference to the currently
      ;; executing continuation as an argument to $next_task.
      (local.set $next_task (call $task_dequeue))
      (switch $ct $ct $yield (local.get $next_task))
      (local.set $next_task)
      (if (ref.is_null (local.get $next_task))
        (then)
        (else (call $task_enqueue (local.get $next_task))))
      ;; If we get here, some other continuation switch-ed directly to us, or
      ;; $entry resumed us.
      ;; In the first case, we receive the continuation that switched to us here
      ;; and we need to enqueue it in the task list.
      ;; In the second case, the passed continuation reference will be null.
    )
    ;; Just return if no other task in queue, making the $yield_to_next call
    ;; a noop.
  )

  (func (export "main")
    (call $entry (ref.func $task_1))
  )
)
(invoke "main")
