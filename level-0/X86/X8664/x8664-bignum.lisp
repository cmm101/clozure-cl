;;-*- Mode: Lisp; Package: CCL -*-
;;;
;;;   Copyright (C) 2006, Clozure Associates
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


(in-package "CCL")

;;; The caller has allocated a two-digit bignum (quite likely on the stack).
;;; If we can fit in a single digit (if the high word is just a sign
;;; extension of the low word), truncate the bignum in place (the
;;; trailing words should already be zeroed.
(defx86lapfunction %fixnum-to-bignum-set ((bignum arg_y) (fixnum arg_z))
  (movq (% fixnum) (% arg_x))
  (shl ($ (- 32 x8664::fixnumshift)) (% arg_x))
  (sar ($ (- 32 x8664::fixnumshift)) (% arg_x))
  (unbox-fixnum fixnum imm0)
  (cmp (% arg_x) (% fixnum))
  (je @chop)
  (movq (% imm0)  (@ x8664::misc-data-offset (% bignum)))
  (single-value-return)
  @chop
  (movq ($ x8664::one-digit-bignum-header) (@ x8664::misc-header-offset (% bignum)))
  (movl (% imm0.l) (@ x8664::misc-data-offset (% bignum)))
  (single-value-return))
  


;;; Multiply the (32-bit) digits X and Y, producing a 64-bit result.
;;; Add the 32-bit "prev" digit and the 32-bit carry-in digit to that 64-bit
;;; result; return the halves as (VALUES high low).
(defx86lapfunction %multiply-and-add4 ((x 0) (y arg_x) (prev arg_y) (carry-in arg_z))
  (let ((unboxed-x imm0)
        (unboxed-y imm1)
        (unboxed-prev imm0)
        (unboxed-carry-in imm0)
        (unboxed-low imm0)
        (high arg_y)
        (low arg_z))
    (popq (% temp0))
    (discard-reserved-frame)
    (unbox-fixnum temp0 unboxed-x)
    (unbox-fixnum y unboxed-y)
    (mull (%l unboxed-y))
    (shlq ($ 32) (% unboxed-y))
    (orq (% unboxed-x) (% unboxed-y))   ; I got yer 64-bit product right here
    (unbox-fixnum prev unboxed-prev)
    (addq (% unboxed-prev) (% unboxed-y))
    (unbox-fixnum carry-in unboxed-carry-in)
    (addq (% unboxed-carry-in) (% unboxed-y))
    (movl (%l unboxed-y) (%l unboxed-low))
    (box-fixnum unboxed-low low)
    (shr ($ 32) (% unboxed-y))
    (box-fixnum unboxed-y high)
    (pushq (% high))
    (pushq (% low))
    (set-nargs 2)
    (leaq (@ '2 (% rsp)) (% temp0))
    (jmp-subprim .SPvalues)))

(defx86lapfunction %multiply-and-add3 ((x arg_x) (y arg_y) (carry-in arg_z))
  (let ((unboxed-x imm0)
        (unboxed-y imm1)
        (unboxed-carry-in imm0)
        (unboxed-low imm0)
        (high arg_y)
        (low arg_z))
    (unbox-fixnum arg_x unboxed-x)
    (unbox-fixnum y unboxed-y)
    (mull (%l unboxed-y))
    (shlq ($ 32) (% unboxed-y))
    (orq (% unboxed-x) (% unboxed-y))
    (unbox-fixnum carry-in unboxed-carry-in)
    (addq (% unboxed-carry-in) (% unboxed-y))
    (movl (%l unboxed-y) (%l unboxed-low))
    (box-fixnum unboxed-low low)
    (shr ($ 32) (% unboxed-y))
    (box-fixnum unboxed-y high)
    (pushq (% high))
    (pushq (% low))
    (set-nargs 2)
    (leaq (@ '2 (% rsp)) (% temp0))
    (jmp-subprim .SPvalues)))

;;; Return the (possibly truncated) 32-bit quotient and remainder
;;; resulting from dividing hi:low by divisor.
;;; We only have two immediate registers, and -have- to use them
;;; to represent hi:low.  We -can- store the unboxed divisor in
;;; %ebp, if we commit to the idea that %rbp will never be traced
;;; by the GC.  I'm willing to commit to that for x8664, since
;;; this is an example of not having enough imm regs.  We do need
;;; to save/restore %rbp, but hopefully we can do wo without
;;; hitting memory.
;;; For x8632, we'll probably have to mark something (%ecx ?) as
;;; being "temporarily unboxed" by mucking with some bits in the
;;; TCR.
(defx86lapfunction %floor ((num-high arg_x) (num-low arg_y) (divisor arg_z))
  (let ((unboxed-high imm1)
        (unboxed-low imm0)
        (unboxed-divisor ebp)
        (unboxed-quo imm0)
        (unboxed-rem imm1))
    (movd (% rbp) (% mm0))
    (unbox-fixnum divisor rbp)
    (unbox-fixnum num-high unboxed-high)
    (unbox-fixnum num-low unboxed-low)
    (divl (% ebp))
    (movd (% mm0) (% rbp))
    (box-fixnum unboxed-quo arg_y)
    (box-fixnum unboxed-rem arg_z)
    (movq (% rsp) (% temp0))
    (pushq (% arg_y))
    (pushq (% arg_z))
    (set-nargs 2)
    (jmp-subprim .SPvalues)))

;;; Multiply two (UNSIGNED-BYTE 32) arguments, return the high and
;;; low halves of the 64-bit result
(defx86lapfunction %multiply ((x arg_y) (y arg_z))
  (let ((unboxed-x imm0)
        (unboxed-y imm1)
        (unboxed-high imm1)
        (unboxed-low imm0))
    (unbox-fixnum x unboxed-x)
    (unbox-fixnum y unboxed-y)
    (mull (%l unboxed-y))
    (box-fixnum unboxed-high arg_y)
    (box-fixnum unboxed-low arg_z)
    (movq (% rsp) (% temp0))
    (pushq (% arg_y))
    (pushq (% arg_z))
    (set-nargs 2)
    (jmp-subprim .SPvalues)))

;;; Any words in the "tail" of the bignum should have been
;;; zeroed by the caller.
(defx86lapfunction %set-bignum-length ((newlen arg_y) (bignum arg_z))
  (movq (% newlen) (% imm0))
  (shl ($ (- x8664::num-subtag-bits x8664::fixnumshift)) (% imm0))
  (movb ($ x8664::subtag-bignum) (%b imm0))
  (movq (% imm0) (@ x8664::misc-header-offset (% bignum)))
  (single-value-return))

;;; Count the sign bits in the most significant digit of bignum;
;;; return fixnum count.
(defx86lapfunction %bignum-sign-bits ((bignum arg_z))
  (vector-size bignum imm0 imm0)
  (movl (@ (- x8664::misc-data-offset 4) (% bignum) (% imm0) 4) (%l imm0))
  (movl (% imm0.l) (% imm1.l))
  (notl (% imm0.l))
  (testl (% imm1.l) (% imm1.l))
  (js @wasneg)
  (notl (% imm0.l))  
  @wasneg
  (bsrl (% imm0.l) (% imm0.l))
  (xorl ($ 31) (% imm0))
  (box-fixnum imm0 arg_z)
  (single-value-return))

(defx86lapfunction %signed-bignum-ref ((bignum arg_y) (index arg_z))
  (uuo-error-debug-trap)
  (unbox-fixnum index imm0)
  (movslq (@ x8664::misc-data-offset (% bignum) (% imm0) 4) (% imm0))
  (box-fixnum imm0 arg_z)
  (single-value-return))


;;; If the bignum is a one-digit bignum, return the value of the
;;; single digit as a fixnum.  Otherwise, if it's a two-digit-bignum
;;; and the two words of the bignum can be represented in a fixnum,
;;; return that fixnum; else return nil.
(defx86lapfunction %maybe-fixnum-from-one-or-two-digit-bignum ((bignum arg_z))
  (getvheader bignum imm1)
  (cmpq ($ x8664::one-digit-bignum-header) (% imm1))
  (je @one)
  (cmpq ($ x8664::two-digit-bignum-header) (% imm1))
  (jne @no)
  (movq (@ x8664::misc-data-offset (% bignum)) (% imm0))
  (box-fixnum imm0 arg_z)
  (unbox-fixnum arg_z imm1)
  (cmpq (% imm0) (% imm1))
  (je @done)
  @no
  (movq ($ nil) (% arg_z))
  (single-value-return)
  @one
  (movslq (@ x8664::misc-data-offset (% bignum)) (% imm0))
  (box-fixnum imm0 arg_z)
  @done
  (single-value-return))

;;; Again, we're out of imm regs: a variable shift count has to go in %cl.
;;; Make sure that the rest of %rcx is 0, to keep the GC happy.
;;; %rcx == temp1
(defx86lapfunction %digit-logical-shift-right ((digit arg_y) (count arg_z))
  (unbox-fixnum digit imm0)
  (unbox-fixnum count imm1)
  (xorq (% temp2) (% temp2))
  (movb (% imm1.b) (% temp2.b))
  (shrq (% temp2.b) (% imm0))
  (movb ($ 0) (% temp2.b))
  (box-fixnum imm0 arg_z)
  (single-value-return))

(defx86lapfunction %ashr ((digit arg_y) (count arg_z))
  (unbox-fixnum digit imm0)
  (unbox-fixnum count imm1)
  (movslq (%l imm0) (% imm0))
  (xorq (% temp2) (% temp2))
  (movb (% imm1.b) (% temp2.b))
  (sarq (% temp2.b) (% imm0))
  (movb ($ 0) (% temp2.b))
  (box-fixnum imm0 arg_z)
  (single-value-return))

(defx86lapfunction %ashl ((digit arg_y) (count arg_z))
  (unbox-fixnum digit imm0)
  (unbox-fixnum count imm1)
  (xorq (% temp2) (% temp2))
  (movb (% imm1.b) (% temp2.b))
  (shll (% temp2.b) (%l imm0))
  (movb ($ 0) (% temp2.b))  
  (movl (%l imm0) (%l imm0))            ;zero-extend
  (box-fixnum imm0 arg_z)
  (single-value-return))

(defx86lapfunction macptr->fixnum ((ptr arg_z))
  (macptr-ptr arg_z ptr)
  (single-value-return))

(defx86lapfunction fix-digit-logand ((fix arg_x) (big arg_y) (dest arg_z)) ; index 0
  (let ((w1 imm0)
        (w2 imm1))
    (movq (@ x8664::misc-data-offset (% big)) (% w2))
    (unbox-fixnum  fix w1)
    (andq (% w2) (% w1))
    (cmp-reg-to-nil dest)
    (jne @store)
    (box-fixnum w1 arg_z)
    (single-value-return)
    @store
    (movq (% w1) (@ x8664::misc-data-offset (% dest)))
    (single-value-return)))

(defx86lapfunction fix-digit-logandc2 ((fix arg_x) (big arg_y) (dest arg_z))
  (uuo-error-debug-trap)
  (let ((w1 imm0)
        (w2 imm1))
    (movq (@ x8664::misc-data-offset (% big)) (% w2))
    (unbox-fixnum  fix w1)
    (notq (% w2))
    (andq (% w2) (% w1))
    (cmp-reg-to-nil dest)
    (jne @store)
    (box-fixnum w1 arg_z)
    (single-value-return)
    @store
    (movq (% w1) (@ x8664::misc-data-offset (% dest)))
    (single-value-return)))


(defx86lapfunction fix-digit-logandc1 ((fix arg_x) (big arg_y) (dest arg_z))
  (uuo-error-debug-trap)
  (let ((w1 imm0)
        (w2 imm1))
    (movq (@ x8664::misc-data-offset (% big)) (% w2))
    (unbox-fixnum  fix w1)
    (notq (% w1))
    (andq (% w2) (% w1))
    (cmp-reg-to-nil dest)
    (jne @store)
    (box-fixnum w1 arg_z)
    (single-value-return)
    @store
    (movq (% w1) (@ x8664::misc-data-offset (% dest)))
    (single-value-return)))



