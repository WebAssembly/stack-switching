(module
  ;; Fiber type: takes no resume args, yields only an i32
  (type $GenFiberF (func (param i32) (result i32)))
  (type $GenFiber (fiber 0))

  (func $reifiber_suspend (param $self (ref $GenFiber)) (param $state i32) (result i32)
     local.get $state
     local.get $self
     fiber.suspend $GenFiber
     drop
 )

  (func $reifiber_resume
    (param $f (ref $GenFiber))

    block $suspend_handler (result i32)
      ;; Push fiber ref and resume
      local.get $f
      i32.const 0
      fiber.resume $GenFiber $suspend_handle
      ;; If we reach here, the generator returned (finished)
      return
    end

    ;; If we reach here, the generator suspended.
    ;; Stack contains: [ arg ]
    ;; The resumer already knows `$f` is the fiber that suspended.
    ;; Process the yielded i32 arg...
    return
 )

 (export "_start" (func $consumer))
)