;-*- Mode: Lisp; Package: CCL -*-
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



;(in-package "CCL")

;(push (cons 'number-case 1) *fred-special-indent-alist*) do later



(defppclapfunction %fixnum-signum ((number arg_z))
  (cmpri :cr0 number '0)
  (li arg_z '0)
  (beqlr :cr0)
  (li arg_z '1)               ; assume positive
  (bgtlr :cr0)
  (li arg_z '-1)
  (blr))

; see %logcount (ppc-bignum.lisp)
(defppclapfunction %ilogcount ((number arg_z))
  (let ((arg imm0)
        (shift imm1)
        (temp imm2))
    (unbox-fixnum arg number)
    (mr. shift arg)
    (li arg_z 0)
    (b @test)
    @next
    (la temp -1 shift)
    (and. shift shift temp)
    (la arg_z '1 arg_z)
    @test
    (bne @next)
    (blr)))

(defppclapfunction %iash ((number arg_y) (count arg_z))
  (unbox-fixnum imm1 count)
  (unbox-fixnum imm0 number)
  (neg. imm2 imm1)
  (blt @left)
  (srar imm0 imm0 imm2)
  (box-fixnum arg_z imm0)
  (blr)
  @left
  (slr arg_z number imm1)
  (blr))

(defparameter *double-float-zero* 0.0d0)
(defparameter *short-float-zero* 0.0s0)


#+ppc32-target
(defppclapfunction %sfloat-hwords ((sfloat arg_z))
  (lwz imm0 ppc32::single-float.value sfloat)
  (digit-h temp0 imm0)
  (digit-l temp1 imm0)
  (vpush temp0)
  (vpush temp1)
  (la temp0 8 vsp)
  (set-nargs 2)
  (ba .SPvalues))


; (integer-length arg) = (- 32 (cntlz (if (>= arg 0) arg (lognot arg))))
#+ppc32-target
(defppclapfunction %fixnum-intlen ((number arg_z))  
  (unbox-fixnum imm0 arg_z)
  (cntlzw. imm1 imm0)			; testing result of cntlzw? - ah no zeros if neg
  (bne @nonneg)
  (not imm1 imm0)
  (cntlzw imm1 imm1)
  @nonneg
  (subfic imm1 imm1 32)
  (box-fixnum arg_z imm1)
  (blr))

#+ppc64-target
(defppclapfunction %fixnum-intlen ((number arg_z))  
  (unbox-fixnum imm0 arg_z)
  (cntlzd. imm1 imm0)
  (bne @nonneg)
  (not imm1 imm0)
  (cntlzd imm1 imm1)
  @nonneg
  (subfic imm1 imm1 64)
  (box-fixnum arg_z imm1)
  (blr))


(defppclapfunction %double-float-negate! ((src arg_y) (res arg_z))
  (get-double-float fp0 src)
  (fneg fp1 fp0)
  (put-double-float fp1 res)
  (blr))

#+ppc32-target
(defppclapfunction %short-float-negate! ((src arg_y) (res arg_z))
  (get-single-float fp0 src)
  (fneg fp1 fp0)
  (put-single-float fp1 res)
  (blr))

#+ppc64-target
;;; Non-destructive.
(defppclapfunction %short-float-negate ((src arg_z))
  (get-single-float fp0 src)
  (fneg fp1 fp0)
  (put-single-float fp1 arg_z)
  (blr))


;;; Caller guarantees that result fits in a fixnum.
#+ppc32-target
(defppclapfunction %truncate-double-float->fixnum ((arg arg_z))
  (get-double-float fp0 arg)
  (fctiwz fp0 fp0)
  (stwu tsp -16 tsp)
  (stw tsp 4 tsp)
  (stfd fp0 8 tsp)
  (lwz imm0 (+ 8 4) tsp)
  (lwz tsp 0 tsp)
  (box-fixnum arg_z imm0)  
  (blr))

#+ppc64-target
(defppclapfunction %truncate-double-float->fixnum ((arg arg_z))
  (get-double-float fp0 arg)
  (fctidz fp0 fp0)
  (stdu tsp -32 tsp)
  (std tsp 8 tsp)
  (stfd fp0 16 tsp)
  (ld imm0 16 tsp)
  (la tsp 32 tsp)
  (box-fixnum arg_z imm0)  
  (blr))

#+ppc32-target
(defppclapfunction %truncate-short-float->fixnum ((arg arg_z))
  (get-single-float fp0 arg)
  (fctiwz fp0 fp0)
  (stwu tsp -16 tsp)
  (stw tsp 4 tsp)
  (stfd fp0 8 tsp)
  (lwz imm0 (+ 8 4) tsp)
  (lwz tsp 0 tsp)
  (box-fixnum arg_z imm0)  
  (blr))

#+ppc64-target
(defppclapfunction %truncate-short-float->fixnum ((arg arg_z))
  (get-single-float fp0 arg)
  (fctidz fp0 fp0)
  (stdu tsp -32 tsp)
  (std tsp 8 tsp)
  (stfd fp0 16 tsp)
  (ld imm0 16 tsp)
  (la tsp 32 tsp)
  (box-fixnum arg_z imm0)  
  (blr))

;;; DOES round to even
#+ppc32-target
(defppclapfunction %round-nearest-double-float->fixnum ((arg arg_z))
  (get-double-float fp0 arg)
  (fctiw fp0 fp0)
  (stwu tsp -16 tsp)
  (stw tsp 4 tsp)
  (stfd fp0 8 tsp)
  (lwz imm0 (+ 8 4) tsp)
  (lwz tsp 0 tsp)
  (box-fixnum arg_z imm0)  
  (blr))

#+ppc64-target
(defppclapfunction %round-nearest-double-float->fixnum ((arg arg_z))
  (get-double-float fp0 arg)
  (fctid fp0 fp0)
  (stdu tsp -32 tsp)
  (std tsp 8 tsp)
  (stfd fp0 16 tsp)
  (ld imm0 16 tsp)
  (la tsp 32 tsp)
  (box-fixnum arg_z imm0)  
  (blr))

#+ppc32-target
(defppclapfunction %round-nearest-short-float->fixnum ((arg arg_z))
  (get-single-float fp0 arg)
  (fctiw fp0 fp0)
  (stwu tsp -16 tsp)
  (stw tsp 4 tsp)
  (stfd fp0 8 tsp)
  (lwz imm0 (+ 8 4) tsp)
  (lwz tsp 0 tsp)
  (box-fixnum arg_z imm0)  
  (blr))

#+ppc64-target
(defppclapfunction %round-nearest-short-float->fixnum ((arg arg_z))
  (get-single-float fp0 arg)
  (fctid fp0 fp0)
  (stdu tsp -32 tsp)
  (std tsp 8 tsp)
  (stfd fp0 16 tsp)
  (ld imm0 16 tsp)
  (la tsp 32 tsp)
  (box-fixnum arg_z imm0)  
  (blr))




;;;; maybe this could be smarter but frankly scarlett I dont give a damn
#+ppc32-target
(defppclapfunction %fixnum-truncate ((dividend arg_y) (divisor arg_z))
  (let ((unboxed-quotient imm0)
        (unboxed-dividend imm1)
        (unboxed-divisor imm2)
        (unboxed-product imm3)
        (product temp0)
        (boxed-quotient temp1)
        (remainder temp2))
    (unbox-fixnum unboxed-dividend dividend)
    (unbox-fixnum unboxed-divisor divisor)
    (divwo. unboxed-quotient unboxed-dividend unboxed-divisor)          ; set OV if divisor = 0
    (box-fixnum boxed-quotient unboxed-quotient)
    (mullw unboxed-product unboxed-quotient unboxed-divisor)
    (bns+ @ok)
    (mtxer rzero)
    (save-lisp-context)
    (set-nargs 3)
    (load-constant arg_x 'truncate)
    (call-symbol divide-by-zero-error)
    @not-0
    @ok
    (subf imm0 unboxed-product unboxed-dividend)
    (vpush boxed-quotient)
    (box-fixnum remainder imm0)
    (vpush remainder)
    (set-nargs 2)
    (la temp0 8 vsp)
    (ba .SPvalues)))

#+ppc64-target
(defppclapfunction %fixnum-truncate ((dividend arg_y) (divisor arg_z))
  (let ((unboxed-quotient imm0)
        (unboxed-dividend imm1)
        (unboxed-divisor imm2)
        (unboxed-product imm3)
        (product temp0)
        (boxed-quotient temp1)
        (remainder temp2))
    (unbox-fixnum unboxed-dividend dividend)
    (unbox-fixnum unboxed-divisor divisor)
    (divdo. unboxed-quotient unboxed-dividend unboxed-divisor)          ; set OV if divisor = 0
    (box-fixnum boxed-quotient unboxed-quotient)
    (mulld unboxed-product unboxed-quotient unboxed-divisor)
    (bns+ @ok)
    (mtxer rzero)
    (save-lisp-context)
    (set-nargs 3)
    (load-constant arg_x 'truncate)
    (call-symbol divide-by-zero-error)
    @not-0
    @ok
    (subf imm0 unboxed-product unboxed-dividend)
    (vpush boxed-quotient)
    (box-fixnum remainder imm0)
    (vpush remainder)
    (set-nargs 2)
    (la temp0 '2 vsp)
    (ba .SPvalues)))


(defppclapfunction called-for-mv-p ()
  (ref-global imm0 ret1valaddr)
  (ldr imm1 target::lisp-frame.savelr sp)
  (eq->boolean arg_z imm0 imm1 imm0)
  (blr))
  







#|
Date: Mon, 3 Feb 1997 10:04:08 -0500
To: info-mcl@digitool.com, wineberg@franz.scs.carleton.ca
From: dds@flavors.com (Duncan Smith)
Subject: Re: More info on the random number generator
Sender: owner-info-mcl@digitool.com
Precedence: bulk

The generator is a Linear Congruential Generator:

   X[n+1] = (aX[n] + c) mod m

where: a = 16807  (Park&Miller recommend 48271)
       c = 0
       m = 2^31 - 1

See: Knuth, Seminumerical Algorithms (Volume 2), Chapter 3.

The period is: 2^31 - 2  (zero is excluded).

What makes this generator so simple is that multiplication and addition mod
2^n-1 is easy.  See Knuth Ch. 4.3.2 (2nd Ed. p 272).

    ab mod m = ...

If         m = 2^n-1
           u = ab mod 2^n
           v = floor( ab / 2^n )

    ab mod m = u + v                   :  u+v < 2^n
    ab mod m = ((u + v) mod 2^n) + 1   :  u+v >= 2^n

What we do is use 2b and 2n so we can do arithemetic mod 2^32 instead of
2^31.  This reduces the whole generator to 5 instructions on the 680x0 or
80x86, and 8 on the 60x.

-Duncan

|#
; Use the two fixnums in state to generate a random fixnum >= 0 and < 65536
; Scramble those fixnums up a bit.
#+ppc32-target
(defppclapfunction %next-random-seed ((state arg_z))
  (let ((seed0 imm0)
        (seed1 imm1)
        (temp imm2))
    (check-nargs 1)             ; check
    (lhz seed1 (+ ppc32::misc-data-offset 4) state)
    (lwi temp #.(* 2 48271))      ; 48271 * 2
    (lhz seed0 (+ ppc32::misc-data-offset 8) state)
    (rlwimi seed0 seed1 16 0 15)  ; combine into 32 bits, x
    (mullw  seed1 temp seed0)     ; seed1 = (x * 48271), lo, * 2
    (rlwinm temp temp 1 0 30)     ; 48271 * 2 * 2
    (mulhw  seed0 temp seed0)     ; seed0 = (x * 48271), hi, * 2
    (addc   seed0 seed0 seed1)    ; do mod 2^31-1
    (rlwinm seed0 seed0 31 1 31)
    (addze. seed0 seed0)
    (insrwi seed1 seed0 16 16)
    (sth seed1 (+ ppc32::misc-data-offset 8) state)
    (rotlwi seed0 seed0 16)
    (bne @storehigh)
    (addi seed0 seed0 1)
    @storehigh
    (sth seed0 (+ ppc32::misc-data-offset 4) state)
    (clrlwi temp seed1 16)
    (box-fixnum arg_z temp)
    (blr)))



#+ppc64-target
(defun %next-random-seed (state)
  (let* ((seed (logior (%svref state 1) (%svref state 2))))
    (multiple-value-bind (seed-low seed-high) (%multiply seed (* 2 48271))
      (setq seed (logand #xffffffff (+ seed-low seed-high)))
      (setf (%svref state 1) (logand seed #xffff0000)
            (%svref state 2) (logand seed #x0000ffff))
      (dpb (ldb (byte 8 0) seed-low) (byte 8 8) (ldb (byte 8 3) seed-high)))))



;;; n1 and n2 must be positive (esp non zero)
#+ppc32-target
(defppclapfunction %fixnum-gcd ((n1 arg_y)(n2 arg_z))
  (let ((temp imm0)
	(u imm1)
	(v imm2)
	(ut0 imm3)
	(vt0 imm4))
    (unbox-fixnum u n1)
    (unbox-fixnum v n2)
    (neg temp u)
    (and temp temp u)
    (cntlzw ut0 temp)
    (subfic ut0 ut0 31)
    (neg temp v)
    (and temp temp v)
    (cntlzw vt0 temp)
    (subfic vt0 vt0 31)
    (cmpw cr2 ut0 vt0)
    (srw u u ut0)
    (srw v v vt0)
    (addi ut0 ut0 ppc32::fixnum-shift)
    (addi vt0 vt0 ppc32::fixnum-shift)
    @loop
    (cmpw cr0 u v)
    (slw arg_z u ut0)
    (bgt cr0 @u>v)
    (blt cr0 @u<v)
    (blelr cr2)
    (slw arg_z u vt0)
    (blr)
    @u>v
    (sub u u v)
    @shiftu
    (andi. temp u (ash 1 1))
    (srwi u u 1)
    (beq cr0 @shiftu)
    (b @loop)
    @u<v
    (sub v v u)
    @shiftv
    (andi. temp v (ash 1 1))
    (srwi v v 1)
    (beq cr0 @shiftv)
    (b @loop)))

#+ppc64-target
(defppclapfunction %fixnum-gcd ((n1 arg_y)(n2 arg_z))
  (let ((temp imm0)
	(u imm1)
	(v imm2)
	(ut0 imm3)
	(vt0 imm4))
    (unbox-fixnum u n1)
    (unbox-fixnum v n2)
    (neg temp u)
    (and temp temp u)
    (cntlzd ut0 temp)
    (subfic ut0 ut0 63)
    (neg temp v)
    (and temp temp v)
    (cntlzd vt0 temp)
    (subfic vt0 vt0 63)
    (cmpw cr2 ut0 vt0)
    (srd u u ut0)
    (srd v v vt0)
    (addi ut0 ut0 ppc64::fixnum-shift)
    (addi vt0 vt0 ppc64::fixnum-shift)
    @loop
    (cmpd cr0 u v)
    (sld arg_z u ut0)
    (bgt cr0 @u>v)
    (blt cr0 @u<v)
    (blelr cr2)
    (sld arg_z u vt0)
    (blr)
    @u>v
    (sub u u v)
    @shiftu
    (andi. temp u (ash 1 1))
    (srdi u u 1)
    (beq cr0 @shiftu)
    (b @loop)
    @u<v
    (sub v v u)
    @shiftv
    (andi. temp v (ash 1 1))
    (srdi v v 1)
    (beq cr0 @shiftv)
    (b @loop)))
    



; End of ppc-numbers.lisp
