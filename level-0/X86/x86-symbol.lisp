;;;-*- Mode: Lisp; Package: CCL -*-
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

(in-package "CCL")

(eval-when (:compile-toplevel :execute)
  (require "X8664-ARCH")
  (require "X86-LAPMACROS"))

;;; This assumes that macros & special-operators
;;; have something that's not FUNCTIONP in their
;;; function-cells.  It also assumes that NIL
;;; isn't a true symbol, but that NILSYM is.
(defx86lapfunction %function ((sym arg_z))
  (check-nargs 1)
  (let ((symaddr temp0))
    (movq ($ (+ x8664::nil-value x8664::nilsym-offset)) (% symaddr))
    (cmp-reg-to-nil sym)
    (cmovneq (% sym) (% symaddr))
    (trap-unless-fulltag= symaddr x8664::fulltag-symbol)
    (movq (% sym) (% arg_y))
    (movq (@ x8664::symbol.fcell (% symaddr)) (% arg_z))
    (extract-fulltag arg_z imm0)
    (cmpb ($ x8664::fulltag-function) (%b imm0))
    (je.pt @ok)
    (uuo-error-udf (% arg_y))
    @ok
    (single-value-return)))

;;; Traps unless sym is NIL or some other symbol.  If NIL, return
;;; nilsym
(defx86lapfunction %symbol->symptr ((sym arg_z))
  (let ((tag imm0 ))
    (movq ($ (+ x8664::nil-value x8664::nilsym-offset)) (% tag))
    (cmp-reg-to-nil sym)
    (cmoveq (% sym) (% tag))
    (je :done)
    (trap-unless-fulltag= sym x8664::fulltag-symbol)
    :done
    (single-value-return)))

;;; If symptr is NILSYM, return NIL; else typecheck and return symptr
(defx86lapfunction %symptr->symbol ((symptr arg_z))
  (movw ($ (ash 1 x8664::fulltag-symbol)) (% imm0.w))
  (btw (%w symptr) (% imm0.w))
  (jb.pt @ok)
  (uuo-error-reg-not-tag (% symptr) ($ x8664::fulltag-symbol))
  @ok
  (cmpq ($ (+ x8664::nil-value x8664::nilsym-offset)) (% symptr))
  (sete (% imm0.b))
  (negb (% imm0.b))
  (andl ($ x8664::nilsym-offset) (% imm0.l))
  (subq (% imm0) (% symptr))
  (single-value-return))


;;; Given something whose fulltag is FULLTAG-SYMBOL, return the
;;; underlying uvector.  This function and its inverse would
;;; be good candidates for inlining.
(defx86lapfunction %symptr->symvector ((symptr arg_z))
  (subb ($ (- x8664::fulltag-symbol x8664::fulltag-misc)) (% arg_z.b))
  (single-value-return))

(defx86lapfunction %symvector->symptr ((symbol-vector arg_z))
  (addb ($ (- x8664::fulltag-symbol x8664::fulltag-misc)) (% arg_z.b))
  (single-value-return))
    
(defx86lapfunction %symptr-value ((symptr arg_z))
  (jmp-subprim .SPspecref))

(defx86lapfunction %set-symptr-value ((symptr arg_y) (val arg_z))
  (jmp-subprim .SPspecset))

;;; This gets a tagged symbol as an argument.
;;; If there's no thread-local binding, it should return
;;; the underlying symbol vector as a first return value.
(defx86lapfunction %symptr-binding-address ((symptr arg_z))
  (movq (@ x8664::symbol.binding-index (% symptr)) (% arg_y))
  (rcmp (% arg_y) (@ (% :rcontext) x8664::tcr.tlb-limit))
  (movq (@ (% :rcontext) x8664::tcr.tlb-pointer) (% arg_x))
  (jae @sym)
  (cmpb ($ x8664::no-thread-local-binding-marker) (@ (% arg_x) (% arg_y)))
  (je @sym)
  (shl ($ x8664::word-shift) (% arg_y))
  (push (% arg_x))
  (push (% arg_y))
  (set-nargs 2)
  (lea (@ '2 (% rsp)) (% temp0))
  (jmp-subprim .SPvalues)
  @sym
  (subb ($ (- x8664::fulltag-symbol x8664::fulltag-misc)) (% arg_z.b))
  (push (% arg_z))
  (pushq ($ '#.x8664::symptr.vcell))
  (set-nargs 2)
  (lea (@ '2 (% rsp)) (% temp0))
  (jmp-subprim .SPvalues))

(defx86lapfunction %tcr-binding-location ((tcr arg_y) (sym arg_z))
  (movq (@ x8664::symbol.binding-index (% sym)) (% arg_x))
  (movl ($ nil) (% arg_z.l))
  (rcmp (% arg_x) (@ x8664::tcr.tlb-limit (% tcr)))
  (movq (@ x8664::tcr.tlb-pointer (% tcr)) (% arg_y))
  (jae @done)
  (lea (@ (% arg_y) (% arg_x)) (% arg_y))
  ;; We're little-endian, so the tag is at the EA with no
  ;; displacement
  (cmpb ($ x8664::subtag-no-thread-local-binding) (@ (% arg_y)))
  (cmovneq (% arg_y) (% arg_z))
  @done
  (single-value-return))

  
(defx86lapfunction %pname-hash ((str arg_y) (len arg_z))
  (let ((accum imm0)
        (offset imm1))
    (xorq (% offset) (% offset))
    (xorq (% accum) (% accum))
    (cmpq ($ 0) (% len))
    (jz.pn @done)
    @loop8
    (roll ($ 5) (%l accum))
    (xorl (@ x8664::misc-data-offset (% str) (% offset) 4) (%l accum))
    (addq ($ 1) (% offset))    
    (subq ($ '1) (% len))
    (jnz @loop8)
    (shlq ($ 5) (% accum))
    (shrq ($ (- 5 x8664::fixnumshift)) (% accum))
    (movq (% accum) (% arg_z))
    @done
    (single-value-return)))
