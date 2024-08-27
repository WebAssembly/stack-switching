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

  (func $queue-empty (export "queue-empty") (result i32)
    (i32.eq (global.get $qfront) (global.get $qback))
  )

  (func $dequeue (export "dequeue") (result (ref null $ct))
    (local $i i32)
    (if (call $queue-empty)
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

  (func $task-enqueue (import "queue" "enqueue") (param (ref null $ct)))
  (func $task-dequeue (import "queue" "dequeue") (result (ref null $ct)))
  (func $task-queue-empty (import "queue" "queue-empty") (result i32))
  (func $print-i32 (import "spectest" "print_i32") (param i32))

  (global $taskid (mut i32) (i32.const 0))

  ;; Tag used to yield execution in one task and resume another one.
  (tag $yield)

  ;; Entry point, becomes parent of all tasks.
  ;; Only acts as scheduler when tasks finish.
  (func $entry (param $initial_task (ref $ft))
    (local $next_task (ref null $ct))

    ;; initialise $task_queue with initial task
    (call $task-enqueue (cont.new $ct (local.get $initial_task)))

    (loop $resume_next
      (if (call $task-queue-empty)
        (then (return))
        (else (local.set $next_task (call $task-dequeue)))
      )
      (resume $ct (on $yield switch)
        (ref.null $ct) (local.get $next_task))
      ;; task finished execution: loop to pick next one
      (br $resume_next)
    )
  )

  (func $task_impl
        (param $id i32)
        (param $to_spawn (ref null $ft))
        (param $c (ref null $ct))

    (if (ref.is_null (local.get $c))
      (then)
      (else (call $task-enqueue (local.get $c))))

    (if (ref.is_null (local.get $to_spawn))
      (then)
      (else (call $task-enqueue (cont.new $ct (local.get $to_spawn)))))

    (call $print-i32 (local.get $id))
    (call $yield_to_next)
    (call $print-i32 (local.get $id))
  )

  ;; (func $task (type $ft)
  ;;   (local $id i32)
  ;;   (local $c (ref null $ct))
  ;;   (local.set $c (local.get 0))
  ;;   (if (ref.is_null (local.get $c))
  ;;     (then)
  ;;     (else (call $task-enqueue (local.get $c))))
  ;;   (local.set $id (global.get $taskid))
  ;;   (global.set $taskid (i32.add (local.get $id) (i32.const 1)))

  ;;   (if (i32.lt_u (local.get $id) (i32.const 4))
  ;;     (then (call $task-enqueue (cont.new $ct (ref.func $task))))
  ;;     (else))

  ;;   (call $print-i32 (local.get $id))
  ;;   (call $yield_to_next)
  ;;   (call $print-i32 (local.get $id))
  ;; )

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
      (br_if $done (call $task-queue-empty))
      ;; Switch to $next_task.
      ;; The switch instruction implicitly passes a reference to the currently
      ;; executing continuation as an argument to $next_task.
      (local.set $next_task (call $task-dequeue))
      (switch $ct $ct $yield (local.get $next_task))
      (local.set $next_task)
      (if (ref.is_null (local.get $next_task))
        (then)
        (else (call $task-enqueue (local.get $next_task))))
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
