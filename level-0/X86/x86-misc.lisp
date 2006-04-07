;;; -*- Mode: Lisp; Package: CCL -*-
;;;
;;;   Copyright (C) 1994-2001 Digitool, Inc
;;;   This file is part of OpenMCL.  
;;;
;;;   OpenMCL is licensed under the terms of the Lisp Lesser GNU Public
;;;   License , known as the LLGPL and distributed with OpenMCL as the
;;;   file "LICENSE".  The LLGPL consists of a preamble and the LGPL,
;;;   which is distributed with OpenMCL as the file "LGPL".  Where these
;;;   conflict, the preamble takes precedence.  
;;;
;;;   OpenMCL is referenced in the preamble as the "LIBRARY."
;;;
;;;   The LLGPL is also available online at
;;;   http://opensource.franz.com/preamble.html

;;; level-0;x86;x86-misc.lisp


(in-package "CCL")

;;; Copy N bytes from pointer src, starting at byte offset src-offset,
;;; to ivector dest, starting at offset dest-offset.
;;; It's fine to leave this in lap.
;;; Depending on alignment, it might make sense to move more than
;;; a byte at a time.
;;; Does no arg checking of any kind.  Really.

(defx86lapfunction %copy-ptr-to-ivector ((src (* 1 x8664::node-size) )
                                         (src-byte-offset 0) 
                                         (dest arg_x)
                                         (dest-byte-offset arg_y)
                                         (nbytes arg_z))
  (let ((rsrc temp0)
        (rsrc-byte-offset temp1))
    (testq (% nbytes) (% nbytes))
    (popq (% rsrc-byte-offset))         ; boxed src-byte-offset
    (popq (% rsrc))                     ; src macptr
    (jmp @test)
    @loop
    (unbox-fixnum rsrc-byte-offset imm0)
    (addq ($ '1) (% rsrc-byte-offset))
    (addq (@ x8664::macptr.address (% rsrc)) (% imm0))
    (movb (@ (% imm0)) (%b imm0))
    (unbox-fixnum dest-byte-offset imm1)
    (addq ($ '1) (% dest-byte-offset))
    (movb (%b imm0) (@ x8664::misc-data-offset (% dest) (% imm1)))
    (subq ($ '1) (% nbytes))
    @test
    (jne @loop)
    (movq (% dest) (% arg_z))
    (discard-reserved-frame)
    (single-value-return)))

(defx86lapfunction %copy-ivector-to-ptr ((src (* 1 x8664::node-size))
                                         (src-byte-offset 0) 
                                         (dest arg_x)
                                         (dest-byte-offset arg_y)
                                         (nbytes arg_z))
  (let ((rsrc temp0)
        (rsrc-byte-offset temp1))
    (testq (% nbytes) (% nbytes))
    (popq (% rsrc-byte-offset))
    (popq (% rsrc))
    (jmp @test)
    @loop
    (unbox-fixnum rsrc-byte-offset imm0)
    (addq ($ '1) (% rsrc-byte-offset))
    (movb (@ x8664::misc-data-offset (% rsrc) (% imm0)) (%b imm0))
    (unbox-fixnum dest-byte-offset imm1)
    (addq ($ '1) (% dest-byte-offset))
    (addq (@ x8664::macptr.address (%q dest)) (% imm1))
    (movb (%b imm0) (@ (% imm1)))
    (subq ($ '1) (% nbytes))
    @test
    (jne @loop)
    (movq (% dest) (% arg_z))
    (discard-reserved-frame)
    (single-value-return)))



(defx86lapfunction %copy-ivector-to-ivector ((src-offset 8) 
                                             (src-byte-offset 0) 
                                             (dest arg_x)
                                             (dest-byte-offset arg_y)
                                             (nbytes arg_z))
  (let ((rsrc temp0)
        (rsrc-byte-offset temp1))
    (pop (% rsrc-byte-offset))
    (pop (% rsrc))
    (cmpq (% dest) (% rsrc))
    (jne @front)
    (cmpq (% src-byte-offset) (% dest-byte-offset))
    (jg @back)
    @front
    (testq (% nbytes) (% nbytes))
    (jmp @front-test)
    @front-loop
    (unbox-fixnum rsrc-byte-offset imm0)
    (addq ($ '1) (% rsrc-byte-offset))
    (movb (@ x8664::misc-data-offset (% rsrc) (% imm0)) (%b imm0))
    (unbox-fixnum dest-byte-offset imm1)
    (addq ($ '1) (% dest-byte-offset))
    (movb (%b imm0) (@ x8664::misc-data-offset (% dest) (% imm1)))
    (subq ($ '1) (% nbytes))
    @front-test
    (jne @front-loop)
    (movq (% dest) (% arg_z))
    (discard-reserved-frame)
    (single-value-return)
    @back
    (addq (% nbytes) (% rsrc-byte-offset))
    (addq (% nbytes) (% dest-byte-offset))
    (testq (% nbytes) (% nbytes))
    (jmp @back-test)
    @back-loop
    (subq ($ '1) (% rsrc-byte-offset))
    (unbox-fixnum rsrc-byte-offset imm0)
    (movb (@ x8664::misc-data-offset (% rsrc) (% imm0)) (%b imm0))
    (subq ($ '1) (% dest-byte-offset))
    (unbox-fixnum dest-byte-offset imm1)
    (subq ($ '1) (% nbytes))
    (movb (%b imm0) (@ x8664::misc-data-offset (% dest) (% imm1)))
    @back-test
    (jne @back-loop)
    (movq (% dest) (% arg_z))
    (discard-reserved-frame)
    (single-value-return)))
  

(defx86lapfunction %copy-gvector-to-gvector ((src (* 1 x8664::node-size))
					     (src-element 0)
					     (dest arg_x)
					     (dest-element arg_y)
					     (nelements arg_z))
  (let ((rsrc temp0)
        (rsrc-element imm1)
        (val temp1))
    (popq (% rsrc-element))
    (popq (% rsrc))
    (cmpq (% rsrc) (% dest))
    (jne @front)
    (rcmp (% rsrc-element) (% dest-element))
    (jl @back)
    @front
    (testq (% nelements) (% nelements))
    (jmp @front-test)
    @front-loop
    (movq (@ x8664::misc-data-offset (% rsrc) (% rsrc-element)) (% val))
    (addq ($ '1) (% rsrc-element))
    (movq (% val) (@ x8664::misc-data-offset (% dest) (% dest-element)))
    (addq ($ '1) (% dest-element))
    (subq ($ '1) (% nelements))
    @front-test
    (jne @front-loop)
    (movq (% dest) (% arg_z))
    (discard-reserved-frame)
    (single-value-return)
    @back
    (addq (% nelements) (% rsrc-element))
    (addq (% nelements) (% dest-element))
    (testq (% nelements) (% nelements))
    (jmp @back-test)
    @back-loop
    (subq ($ '1) (% rsrc-element))
    (movq (@ x8664::misc-data-offset (% rsrc) (% rsrc-element)) (% val))
    (subq ($ '1) (% dest-element))
    (movq (% val) (@ x8664::misc-data-offset (% dest) (% dest-element)))
    (subq ($ '1) (% nelements))
    @back-test
    (jne @back-loop)
    (movq (% dest) (% arg_z))
    (discard-reserved-frame)
    (single-value-return)))

(defx86lapfunction %heap-bytes-allocated ()
  (movq (@ (% rcontext) x8664::tcr.last-allocptr) (% temp0))
  (movq (@ (% rcontext) x8664::tcr.save-allocptr) (% temp1))
  (movq (@ (% rcontext) x8664::tcr.total-bytes-allocated) (% imm0))
  (movq (% temp0) (% temp2))
  (subq (% temp1) (% temp0))
  (testq (% temp2) (% temp2))
  (jz @go)
  (add (% temp0) (% imm0))
  @go
  (jmp-subprim .SPmakeu64))


(defx86lapfunction values ()
  (push-argregs)
  (movzwl (%w nargs) (%l nargs))
  (rcmpw (% nargs) ($ '3))
  (lea (@ (% rsp) (%q nargs)) (% temp0))
  (lea (@ '2 (% temp0)) (% temp1))
  (cmovaq (% temp1) (% temp0))
  (jmp-subprim .SPvalues))

;;; It would be nice if (%setf-macptr macptr (ash (the fixnum value)
;;; ash::fixnumshift)) would do this inline.

(defx86lapfunction %setf-macptr-to-object ((macptr arg_y) (object arg_z))
  (check-nargs 2)
  (trap-unless-typecode= macptr x8664::subtag-macptr)
  (movq (% object) (@ x8664::macptr.address (% macptr)))
  (single-value-return))

(defx86lapfunction %fixnum-from-macptr ((macptr arg_z))
  (check-nargs 1)
  (trap-unless-typecode= arg_z x8664::subtag-macptr)
  (movq (@ x8664::macptr.address (% arg_z)) (% imm0))
  (trap-unless-lisptag= imm0 x8664::tag-fixnum imm1)
  (movq (% imm0) (% arg_z))
  (single-value-return))


(defx86lapfunction %%get-unsigned-longlong ((ptr arg_y) (offset arg_z))
  (trap-unless-typecode= ptr x8664::subtag-macptr)
  (macptr-ptr ptr imm1)
  (unbox-fixnum imm0 offset)
  (movq (@ (% imm1) (% imm0)) (% imm0))
  (jmp-subprim .SPmakeu64))


(defx86lapfunction %%get-signed-longlong ((ptr arg_y) (offset arg_z))
  (trap-unless-typecode= ptr x8664::subtag-macptr)
  (macptr-ptr ptr imm1)
  (unbox-fixnum imm0 offset)
  (movq (@ (% imm1) (% imm0)) (% imm0))
  (jmp-subprim .SPmakes64))




(defx86lapfunction %%set-unsigned-longlong ((ptr arg_x)
                                            (offset arg_y)
                                            (val arg_z))
  (save-simple-frame)
  (trap-unless-typecode= ptr x8664::subtag-macptr)
  (call-subprim .SPgetu64)
  (macptr-ptr ptr ptr)
  (unbox-fixnum offset imm1)
  (movq (% imm0) (@ (% ptr) (% imm1)))
  (restore-simple-frame)
  (single-value-return))


(defx86lapfunction %%set-signed-longlong ((ptr arg_x)
                                          (offset arg_y)
                                          (val arg_z))
  (save-simple-frame)
  (trap-unless-typecode= ptr x8664::subtag-macptr)
  (call-subprim .SPgets64)
  (macptr-ptr ptr ptr)
  (unbox-fixnum offset imm1)
  (movq (% imm0) (@ (% ptr) (% imm1)))
  (restore-simple-frame)
  (single-value-return))

(defx86lapfunction interrupt-level ()
  (movq (@ (% rcontext) x8664::tcr.tlb-pointer) (% imm1))
  (movq (@ x8664::interrupt-level-binding-index (% imm1)) (% arg_z))
  (single-value-return))

(defx86lapfunction set-interrupt-level ((new arg_z))
  (movq (@ (% rcontext) x8664::tcr.tlb-pointer) (% imm1))
  (trap-unless-fixnum new)
  (movq (% new) (@ x8664::interrupt-level-binding-index (% imm1)))
  (single-value-return))

(defx86lapfunction %current-tcr ()
  (movq (@ (% rcontext) x8664::tcr.linear) (% arg_z))
  (single-value-return))

(defx86lapfunction %tcr-toplevel-function ((tcr arg_z))
  (check-nargs 1)
  (cmpq (% tcr) (@ (% x8664::rcontext) x8664::tcr.linear))
  (movq (% rsp) (% imm0))
  (movq (@ x8664::tcr.vs-area (% tcr)) (% temp0))
  (movq (@ x8664::area.high (% temp0)) (% imm1))
  (jz @room)
  (movq (@ x8664::area.active (% temp0)) (% imm0))
  @room
  (cmpq (% imm1) (% imm0))
  (movl ($ x8664::nil-value) (%l arg_z))
  (cmovneq (@ (- x8664::node-size) (% imm1)) (% arg_z))
  (single-value-return))

(defx86lapfunction %set-tcr-toplevel-function ((tcr arg_y) (fun arg_z))
  (check-nargs 2)
  (cmpq (% tcr) (@ (% x8664::rcontext) x8664::tcr.linear))
  (movq (% rsp) (% imm0))
  (movq (@ x8664::tcr.vs-area (% tcr)) (% temp0))
  (movq (@ x8664::area.high (% temp0)) (% imm1))
  (jz @room)
  (movq (@ x8664::area.active (% temp0)) (% imm0))
  @room
  (cmpq (% imm1) (% imm0))
  (leaq (@ (- x8664::node-size) (% imm1)) (% imm1))
  (movq ($ 0) (@ (% imm1)))
  (jne @have-room)
  (movq (% imm1) (@ x8664::area.active (% temp0)))
  (movq (% imm1) (@ x8664::tcr.save-vsp (% tcr)))
  @have-room
  (movq (% fun) (@ (% imm1)))
  (single-value-return))

;;; This needs to be done out-of-line, to handle EGC memoization.
(defx86lapfunction %store-node-conditional ((offset 0) (object arg_x) (old arg_y) (new arg_z))
  (pop (% temp0))
  (discard-reserved-frame)
  (jmp-subprim .SPstore-node-conditional))

(defx86lapfunction %store-immediate-conditional ((offset 0) (object arg_x) (old arg_y) (new arg_z))
  (pop (% temp0))
  (discard-reserved-frame)
  (unbox-fixnum temp0 imm1)
  @again
  (movq (@ (% object) (% imm1)) (% rax))
  (cmpq (% rax) (% old))
  (jne @lose)
  (lock)
  (cmpxchgq (% new) (@ (% object) (% imm1)))
  (jne @again)
  (movl ($ x8664::t-value) (%l arg_z))
  (single-value-return)
  @lose
  (movl ($ x8664::nil-value) (%l arg_z))
  (single-value-return))

(defx86lapfunction set-%gcable-macptrs% ((ptr x8664::arg_z))
  @again
  (movq (@ (+ x8664::nil-value (x8664::kernel-global gcable-pointers)))
        (% rax))
  (movq (% rax) (@ x8664::xmacptr.link (% ptr)))
  (lock)
  (cmpxchgq (% ptr) (@ (+ x8664::nil-value (x8664::kernel-global gcable-pointers))))
  (jne @again)
  (single-value-return))

;;; Atomically increment or decrement the gc-inhibit-count kernel-global
;;; (It's decremented if it's currently negative, incremented otherwise.)
(defx86lapfunction %lock-gc-lock ()
  @again
  (movq (@ (+ x8664::nil-value (x8664::kernel-global gc-inhibit-count))) (% rax))
  (lea (@ '-1 (% rax)) (% temp0))
  (lea (@ '1 (% rax)) (% arg_z))
  (testq (% rax) (% rax))
  (cmovsq (% temp0) (% arg_z))
  (lock)
  (cmpxchgq (% arg_z) (@ (+ x8664::nil-value (x8664::kernel-global gc-inhibit-count))))
  (jnz @again)
  (single-value-return))

;;; Atomically decrement or increment the gc-inhibit-count kernel-global
;;; (It's incremented if it's currently negative, incremented otherwise.)
;;; If it's incremented from -1 to 0, try to GC (maybe just a little.)
(defx86lapfunction %unlock-gc-lock ()
  @again
  (movq (@ (+ x8664::nil-value (x8664::kernel-global gc-inhibit-count)))
        (% rax))
  (lea (@ '1 (% rax)) (% arg_x))
  (cmpq ($ -1) (% rax))
  (lea (@ '-1 (% rax)) (% arg_z))
  (cmovleq (% arg_x) (% arg_z))
  (lock)
  (cmpxchgq (% arg_z) (@ (+ x8664::nil-value (x8664::kernel-global gc-inhibit-count))))
  (jne @again)
  (cmpq ($ '-1) (% rax))
  (jne @done)
  ;; The GC tried to run while it was inhibited.  Unless something else
  ;; has just inhibited it, it should be possible to GC now.
  (mov ($ arch::gc-trap-function-immediate-gc) (% imm0))
  (uuo-gc-trap)
  @done
  (single-value-return))

;;; Return true iff we were able to increment a non-negative
;;; lock._value
(defx86lapfunction %try-read-lock-rwlock ((lock arg_z))
  (check-nargs 1)
  @try
  (movq (@ x8664::lock._value (% lock)) (% rax))
  (movq (% rax) (% imm1))
  (addq ($ '1) (% imm1))
  (jle @fail)
  (lock)
  (cmpxchgq (% imm1) (@ x8664::lock._value (% lock)))
  (jne @try)
  (single-value-return)                                 ; return the lock
@fail
  (movl ($ x8664::nil-value) (%l arg_z))
  (single-value-return))



(defx86lapfunction unlock-rwlock ((lock arg_z))
  (cmpq ($ 0) (@ x8664::lock._value (% lock)))
  (jle @unlock-write)
  @unlock-read
  (movq (@ x8664::lock._value (% lock)) (% rax))
  (lea (@ '-1 (% imm0)) (% imm1))
  (lock)
  (cmpxchgq (% imm1) (@ x8664::lock._value (% lock)))
  (jne @unlock-read)
  (single-value-return)
  @unlock-write
  ;;; If we aren't the writer, return NIL.
  ;;; If we are and the value's about to go to 0, clear the writer field.
  (movq (@ x8664::lock.writer (% lock)) (% imm0))
  (cmpq (% imm0) (@ (% rcontext) x8664::tcr.linear))
  (jne @fail)
  (addq ($ '1) (@ x8664::lock._value (% lock)))
  (jne @home)
  (movsd (% fpzero) (@ x8664::lock.writer (% lock)))
  @home
  (single-value-return)
  @fail
  (movl ($ x8664::nil-value) (%l arg_z))
  (single-value-return))

(defx86lapfunction %atomic-incf-node ((by arg_x) (node arg_y) (disp arg_z))
  (check-nargs 3)
  (unbox-fixnum disp imm1)
  @again
  (movq (@ (% node) (% disp)) (% rax))
  (lea (@ (% rax) (% by)) (% arg_z))
  (lock)
  (cmpxchgq (% arg_z) (@ (% node) (% disp)))
  (jne @again)
  (single-value-return))

(defx86lapfunction %atomic-incf-ptr ((ptr arg_z))
  (macptr-ptr ptr ptr)
  @again
  (movq (@ (% ptr)) (% rax))
  (lea (@ 1 (% rax)) (% imm1))
  (lock)
  (cmpxchgq (% imm1) (@ (% ptr)))
  (jne @again)
  (box-fixnum imm1 arg_z)
  (single-value-return))

(defx86lapfunction %atomic-incf-ptr-by ((ptr arg_y) (by arg_z))
  (macptr-ptr ptr ptr)
  @again
  (movq (@ (% ptr)) (% rax))
  (unbox-fixnum by imm1)
  (add (% rax) (% imm1))
  (lock)
  (cmpxchgq (% imm1) (@ (% ptr)))
  (jnz @again)
  (box-fixnum imm1 arg_z)
  (single-value-return))


(defx86lapfunction %atomic-decf-ptr ((ptr arg_z))
  (macptr-ptr ptr ptr)
  @again
  (movq (@ (% ptr)) (% rax))
  (lea (@ -1 (% rax)) (% imm1))
  (lock)
  (cmpxchgq (% imm1) (@ (% ptr)))
  (jnz @again)
  (box-fixnum imm1 arg_z)
  (single-value-return))

(defx86lapfunction %atomic-decf-ptr-if-positive ((ptr arg_z))
  (macptr-ptr ptr ptr)                  ;must be fixnum-aligned
  @again
  (movq (@ (% ptr)) (% rax))
  (testq (% rax) (% rax))
  (lea (@ -1 (% rax)) (% imm1))
  (jz @done)
  (lock)
  (cmpxchgq (% imm1) (@ (% ptr)))
  (jnz @again)
  @done
  (box-fixnum imm1 arg_z)
  (single-value-return))


(defx86lapfunction %atomic-swap-ptr ((ptr arg_y) (newval arg_z))
  (macptr-ptr arg_y imm1)
  (unbox-fixnum newval imm0)
  (lock)
  (xchgq (% imm0) (@ (% imm1)))
  (box-fixnum imm0 arg_z)
  (single-value-return))

;;; Try to store the fixnum NEWVAL at PTR, if and only if the old value
;;; was equal to OLDVAL.  Return the old value
(defx86lapfunction %ptr-store-conditional ((ptr arg_x) (expected-oldval arg_y) (newval arg_z))
  (macptr-ptr ptr ptr)                  ;  must be fixnum-aligned
  @again
  (movq (@ (% ptr)) (% imm0))
  (box-fixnum imm0 temp0)
  (cmpq (% temp0) (% expected-oldval))
  (jne @done)
  (unbox-fixnum newval imm1)
  (lock)
  (cmpxchgq (% imm1) (@ (% ptr)))
  (jne @again)
  @done
  (movq (% temp0) (% arg_z))
  (single-value-return))


(defx86lapfunction %macptr->dead-macptr ((macptr arg_z))
  (check-nargs 1)
  (movb ($ x8664::subtag-dead-macptr) (@ x8664::misc-subtag-offset (% macptr)))
  (single-value-return))

#+are-you-kidding
(defx86lapfunction %%apply-in-frame ((catch-count imm0) (srv temp0) (tsp-count imm0) (db-link imm0)
                                     (parent arg_x) (function arg_y) (arglist arg_z))
  (check-nargs 7)

  ; Throw through catch-count catch frames
  (lwz imm0 12 vsp)                      ; catch-count
  (vpush parent)
  (vpush function)
  (vpush arglist)
  (bla .SPnthrowvalues)

  ; Pop tsp-count TSP frames
  (lwz tsp-count 16 vsp)
  (cmpi cr0 tsp-count 0)
  (b @test)
@loop
  (subi tsp-count tsp-count '1)
  (cmpi cr0 tsp-count 0)
  (lwz tsp 0 tsp)
@test
  (bne cr0 @loop)

  ; Pop dynamic bindings until we get to db-link
  (lwz imm0 12 vsp)                     ; db-link
  (lwz imm1 x8664::tcr.db-link x8664::rcontext)
  (cmp cr0 imm0 imm1)
  (beq cr0 @restore-regs)               ; .SPunbind-to expects there to be something to do
  (bla .SPunbind-to)

@restore-regs
  ; restore the saved registers from srv
  (lwz srv 20 vsp)
@get0
  (svref imm0 1 srv)
  (cmpwi cr0 imm0 x8664::nil-value)
  (beq @get1)
  (lwz save0 0 imm0)
@get1
  (svref imm0 2 srv)
  (cmpwi cr0 imm0 x8664::nil-value)
  (beq @get2)
  (lwz save1 0 imm0)
@get2
  (svref imm0 3 srv)
  (cmpwi cr0 imm0 x8664::nil-value)
  (beq @get3)
  (lwz save2 0 imm0)
@get3
  (svref imm0 4 srv)
  (cmpwi cr0 imm0 x8664::nil-value)
  (beq @get4)
  (lwz save3 0 imm0)
@get4
  (svref imm0 5 srv)
  (cmpwi cr0 imm0 x8664::nil-value)
  (beq @get5)
  (lwz save4 0 imm0)
@get5
  (svref imm0 6 srv)
  (cmpwi cr0 imm0 x8664::nil-value)
  (beq @get6)
  (lwz save5 0 imm0)
@get6
  (svref imm0 7 srv)
  (cmpwi cr0 imm0 x8664::nil-value)
  (beq @get7)
  (lwz save6 0 imm0)
@get7
  (svref imm0 8 srv)
  (cmpwi cr0 imm0 x8664::nil-value)
  (beq @got)
  (lwz save7 0 imm0)
@got

  (vpop arg_z)                          ; arglist
  (vpop temp0)                          ; function
  (vpop parent)                         ; parent
  (extract-lisptag imm0 parent)
  (cmpi cr0 imm0 x8664::tag-fixnum)
  (if (:cr0 :ne)
    ; Parent is a fake-stack-frame. Make it real
    (progn
      (svref sp %fake-stack-frame.sp parent)
      (stwu sp (- x8664::lisp-frame.size) sp)
      (svref fn %fake-stack-frame.fn parent)
      (stw fn x8664::lisp-frame.savefn sp)
      (svref temp1 %fake-stack-frame.vsp parent)
      (stw temp1 x8664::lisp-frame.savevsp sp)
      (svref temp1 %fake-stack-frame.lr parent)
      (extract-lisptag imm0 temp1)
      (cmpi cr0 imm0 x8664::tag-fixnum)
      (if (:cr0 :ne)
        ;; must be a macptr encoding the actual link register
        (macptr-ptr loc-pc temp1)
        ;; Fixnum is offset from start of function vector
        (progn
          (svref temp2 0 fn)        ; function vector
          (unbox-fixnum temp1 temp1)
          (add loc-pc temp2 temp1)))
      (stw loc-pc x8664::lisp-frame.savelr sp))
    ;; Parent is a real stack frame
    (mr sp parent))
  (set-nargs 0)
  (bla .SPspreadargz)
  (ba .SPtfuncallgen))



  
(defx86lapfunction %%save-application ((flags arg_y) (fd arg_z))
  (unbox-fixnum flags imm0)
  (orq ($ arch::gc-trap-function-save-application) (% imm0))
  (unbox-fixnum fd imm1)
  (uuo-gc-trap)
  (single-value-return))



(defx86lapfunction %misc-address-fixnum ((misc-object arg_z))
  (check-nargs 1)
  (lea (@ x8664::misc-data-offset (% misc-object)) (% arg_z))
  (single-value-return))


(defx86lapfunction fudge-heap-pointer ((ptr arg_x) (subtype arg_y) (len arg_z))
  (check-nargs 3)
  (macptr-ptr ptr imm1) ; address in macptr
  (lea (@ 17 (% imm1)) (% imm0))     ; 2 for delta + 15 for alignment
  (andb ($ -16) (%b  imm0))   ; Clear low four bits to align
  (subq (% imm0) (% imm1))  ; imm1 = -delta
  (negw (%w imm1))
  (movw (%w imm1) (@  -2 (% imm0)))     ; save delta halfword
  (unbox-fixnum subtype imm1)  ; subtype at low end of imm1
  (shlq ($ (- x8664::num-subtag-bits x8664::fixnum-shift)) (% len ))
  (orq (% len) (% imm1))
  (movq (% imm1) (@ (% imm0)))       ; store subtype & length
  (lea (@ x8664::fulltag-misc (% imm0)) (% arg_z)) ; tag it, return it
  (single-value-return))

(defx86lapfunction %%make-disposable ((ptr arg_y) (vector arg_z))
  (check-nargs 2)
  (lea (@ (- x8664::fulltag-misc) (% vector)) (% imm0)) ; imm0 is addr = vect less tag
  (movzwq (@ -2 (% imm0)) (% imm1))     ; get delta
  (subq (% imm1) (% imm0))              ; vector addr (less tag)  - delta is orig addr
  (movq (% imm0) (@ x8664::macptr.address (% ptr)))
  (single-value-return))


(defx86lapfunction %vect-data-to-macptr ((vect arg_y) (ptr arg_z))
  (lea (@ x8664::misc-data-offset (% vect)) (% imm0))
  (movq (% imm0) (@ x8664::macptr.address (% ptr)))
  (single-value-return))

(defx86lapfunction get-saved-register-values ()
  (movq (% rsp) (% temp0))
  (push (% save0))
  (push (% save1))
  (push (% save2))
  (push (% save3))
  (set-nargs 4)
  (jmp-subprim .SPvalues))


(defx86lapfunction %current-db-link ()
  (movq (@ (% rcontext) x8664::tcr.db-link) (% arg_z))
  (single-value-return))

(defx86lapfunction %no-thread-local-binding-marker ()
  (movq ($ x8664::subtag-no-thread-local-binding) (% arg_z))
  (single-value-return))


(defx86lapfunction break-event-pending-p ()
  (xorq (% imm0) (% imm0))
  (ref-global x8664::intflag imm1)
  (set-global imm0 x8664::intflag)
  (testq (% imm1) (% imm1))
  (setne (%b imm0))
  (andl ($ x8664::t-offset) (%l imm0))
  (lea (@ x8664::nil-value (% imm0)) (% arg_z))
  (single-value-return))

;;; end of x86-misc.lisp
