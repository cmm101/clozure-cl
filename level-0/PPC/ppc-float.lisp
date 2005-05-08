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

#+allow-in-package
(in-package "CCL")

(eval-when (:compile-toplevel :execute)
  (require "NUMBER-MACROS")
  (require :number-case-macro) 
  

 

  (defppclapmacro 48x32-divide (x-hi16 x-lo y freg temp-freg freg2 immx)
    `(let ((temp 16)
           (temp.h 16)
           (temp.l 20)
           (zero 8)
           (zero.h 8)
           (zero.l 12))
      (stwu tsp -24 tsp)
      (stw tsp 4 tsp)
      (lwi ,immx #x43300000)  ; 1075 = 1022+53 
      (stw ,immx zero.h tsp)
      (stw rzero zero.l tsp)
      (lfd ,temp-freg zero tsp)
      (rlwimi ,immx ,x-hi16 0 16 31)           
      (stw ,immx temp.h tsp)
      (stw ,x-lo temp.l tsp)
      (lfd ,freg temp tsp)
      
      (fsub ,freg ,freg ,temp-freg)
      (lwi ,immx #x43300000)
      (stw ,immx temp.h tsp)
      (stw ,y temp.l tsp)
      (lfd ,freg2 temp tsp)
      (lwz tsp 0 tsp)
      (fsub ,freg2 ,freg2 ,temp-freg)
      (fdiv ,freg ,freg ,freg2)
      ))
   
)





; get xidx thing from x, yidx thing from y
; if same return #xffff #xffff
; otherwise get another thing from x and 1- xidx and do as %floor of xthing otherx ything
(defppclapfunction %floor-99 ((x-stk 0)(xidx arg_x)(yptr arg_y)(yidx arg_z))
  (let ((xptr temp0)
        (a imm1)
        (b imm2)
        (y imm3)
        (quo imm0)) 
    (vpop xptr)
    (la imm4 ppc32::misc-data-offset XIDX)
    (lwzx a xptr imm4)
    (la imm4 ppc32::misc-data-offset YIDX)
    (lwzx y yptr imm4)
    (cmpw a y)
    (bne @more)
    (li imm4 #xffff)
    (rlwinm imm4 imm4 ppc32::fixnumshift (- 16 ppc32::fixnumshift) (- 31 ppc32::fixnum-shift))
    (vpush imm4)
    (vpush imm4)
    (la temp0 8 vsp)
    (set-nargs 2)
    (ba .spvalues)
    @MORE
    ;  a has 16 bits from ahi, bhi gets alo blo gets bhi
    (la imm4 (- ppc32::misc-data-offset 4) xidx)
    (lwzx b xptr imm4)
    (rlwinm b b 16 16 31)  ; bhi to blo 
    (rlwimi b a 16 0 15)   ; alo to bhi
    (rlwinm a a 16 16 31)  ; a gets alo 
    (48x32-divide a b y fp0 fp1 fp2 imm4)
    (fctiwz fp0 fp0)
    (stwu tsp -32 tsp)
    (stw tsp 4 tsp)
    (stfd fp0 24 tsp)
    (lwz quo (+ 24 4) tsp) ; 16 quo bits above stuff used by 48x32
    ; now mul quo by y
    (mullw imm4 y quo)
    ; and subtract from a,b
    (subfc b imm4 b)
    ; AND AGAIN
    (rlwinm a b -16 16 31) ; a gets b hi
    (rlwinm b b 16 0 15)   ; b lo to b hi
    (la imm4 (- ppc32::misc-data-offset 4) xidx) 
    (lwzx imm4 imm4 xptr)
    (rlwimi b imm4 0 16 31)
    (48x32-divide a b y fp0 fp1 fp2 imm4)
    (fctiwz fp0 fp0)
    (stfd fp0 16 tsp)  ; quo lo
    (lwz quo (+ 24 4) tsp) ; quo-hi
    (box-fixnum temp0 quo)
    (vpush temp0)
    (lwz quo (+ 16 4) tsp) ; quo lo
    (lwz tsp 0 tsp)
    (box-fixnum temp0 quo)
    (vpush temp0)    
    (la temp0 8 vsp)
    (set-nargs 2)
    (ba .SPvalues)))
    
    
    

; for truncate-by-fixnum etal
; doesnt store quotient - just returns rem in 2 halves
(defppclapfunction %floor-loop-no-quo ((q arg_x)(yhi arg_y)(ylo arg_z))
  (let ((a imm1)
        (b imm2)
        (y imm3)
        (quo imm0)
        (qidx temp0)
        (qlen temp1))
    (lwz imm4 (- ppc32::fulltag-misc) q)
    (header-length qlen imm4)
    (subi qidx qlen 4)
    (mr b rzero)
    (compose-digit y yhi ylo)
    @loop
    (rlwinm a b -16 16 31)
    (rlwinm b b 16 0 15)
    (la imm4 ppc32::misc-data-offset q)
    (lwzx imm4 qidx imm4) ; q contents
    (rlwimi b imm4 16 16 31) ; hi 16 to lo b
    ;(dbg)         
    (48x32-divide a b y fp0 fp1 fp2 imm4)
    (fctiwz fp0 fp0)
    (stwu tsp -32 tsp)
    (stw tsp 4 tsp)
    (stfd fp0 24 tsp)
    (lwz quo (+ 24 4) tsp) ; 16 quo bits above stuff used by 48x32
    ; now mul quo by y
    (mullw imm4 y quo)
    ; and subtract from a,b
    (subfc b imm4 b)
    ; new a and b are low 2 digits of this (b) and last digit in array
    ; and do it again on low 3 digits
    ;(dbg)
    (rlwinm a b -16 16 31)
    (rlwinm b b 16 0 15)
    (la imm4 ppc32::misc-data-offset q)
    (lwzx imm4 qidx imm4)
    (rlwimi b imm4 0 16 31)
    (48x32-divide a b y fp0 fp1 fp2 imm4)
    (fctiwz fp0 fp0)
    (stfd fp0 16 tsp)  ; quo lo
    (subi qidx qidx 4)
    (cmpwi :cr1 qidx 0)
    (lwz quo (+ 16 4) tsp)
    (lwz tsp 0 tsp)
    (mullw imm4 y quo)
    (subfc b imm4 b)  ; b is remainder
    (bge :cr1 @loop)
    (digit-h temp0 b)
    (vpush temp0)
    (digit-l temp0 b)
    (vpush temp0)
    (la temp0 8 vsp)
    (set-nargs 2)
    (ba .SPvalues)))

; store result in dest, return rem in 2 halves
(defppclapfunction %floor-loop-quo ((q-stk 0)(dest arg_x)(yhi arg_y)(ylo arg_z))
  (let ((a imm1)
        (b imm2)
        (y imm3)
        (quo imm0)
        (qidx temp0)
        (qlen temp1)
        (q temp2))
    (vpop q)
    (lwz imm4 (- ppc32::fulltag-misc) q)
    (header-length qlen imm4)
    (subi qidx qlen 4)
    (mr b rzero)
    (compose-digit y yhi ylo)
    @loop
    (rlwinm a b -16 16 31)
    (rlwinm b b 16 0 15)
    (la imm4 ppc32::misc-data-offset q)
    (lwzx imm4 qidx imm4) ; q contents
    (rlwimi b imm4 16 16 31) ; hi 16 to lo b        
    (48x32-divide a b y fp0 fp1 fp2 imm4)
    (fctiwz fp0 fp0)
    (stwu tsp -32 tsp)
    (stw tsp 4 tsp)
    (stfd fp0 24 tsp)
    (lwz quo (+ 24 4) tsp) ; 16 quo bits above stuff used by 48x32
    ; now mul quo by y
    (mullw imm4 y quo)
    ; and subtract from a,b
    (subfc b imm4 b)
    ; new a and b are low 2 digits of this (b) and last digit in array
    ; and do it again on low 3 digits
    ;(dbg)
    (rlwinm a b -16 16 31)
    (rlwinm b b 16 0 15)
    (la imm4 ppc32::misc-data-offset q)
    (lwzx imm4 qidx imm4)
    (rlwimi b imm4 0 16 31)
    (48x32-divide a b y fp0 fp1 fp2 imm4)
    (fctiwz fp0 fp0)
    (stfd fp0 16 tsp)  ; quo lo
    (lwz quo (+ 16 4) tsp)
    (mullw imm4 y quo)
    (subfc b imm4 b)  ; b is remainder    
    (lwz quo (+ 24 4) tsp) ; quo-hi
    (rlwinm quo quo 16 0 15)
    (lwz imm4 (+ 16 4) tsp) ; quo lo
    (lwz tsp 0 tsp)
    (rlwimi quo imm4 0 16 31)    
    (la imm4 ppc32::misc-data-offset dest)
    (stwx quo qidx imm4)
    (subic. qidx qidx 4)
    (bge @loop)
    (digit-h temp0 b)
    (vpush temp0)
    (digit-l temp0 b)
    (vpush temp0)
    (la temp0 8 vsp)
    (set-nargs 2)
    (ba .SPvalues)))




; make a float from hi - high 24 bits mantissa (ignore implied higher bit)
;                   lo -  low 28 bits mantissa
;                   exp  - take low 11 bits
;                   sign - sign(sign) => result
; hi result - 1 bit sign: 11 bits exp: 20 hi bits of hi arg
; lo result - 4 lo bits of hi arg: 28 lo bits of lo arg
; no error checks, no tweaks, no nuthin 

(defppclapfunction %make-float-from-fixnums ((float 4)(hi 0) (lo arg_x) (exp arg_y) (sign arg_z))
  (rlwinm imm0 sign 0 0 0)  ; just leave sign bit 
  (rlwimi imm0 exp (- 20 ppc32::fixnumshift)  1 11) ;  exp left 20 right 2 keep 11 bits
  (lwz imm1 hi vsp)
  (srawi imm1 imm1 ppc32::fixnumshift)   ; fold into below? nah keep for later
  (rlwimi imm0 imm1 (- 32 4) 12 31)   ; right 4 - keep  20 - stuff into hi result
  (rlwinm imm1 imm1 28 0 3)  ; hi goes left 28 - keep 4 hi bits
  (rlwimi imm1 lo (- 32 ppc32::fixnumshift) 4 31) ; stuff in 28 bits of lo
  (lwz temp0 float vsp)         ; the float
  (stw imm0 ppc32::double-float.value temp0)
  (stw imm1 ppc32::double-float.val-low temp0)
  (la vsp 8 vsp)
  (blr))

(defppclapfunction %make-short-float-from-fixnums ((float 0) (sig arg_x) (exp arg_y) (sign arg_z))
  (unbox-fixnum imm0 sig)
  (rlwimi imm0 exp (- 29 8) 1 8)
  (inslwi imm0 sign 1 0)
  (vpop arg_z)
  (stw imm0 ppc32::single-float.value arg_z)
  (blr))



    

; this is also wrong - it doesn't check for invalid-operation
; same is true for double-float-negate
(defppclapfunction %%double-float-abs ((n arg_y)(val arg_z))
  (get-double-float fp1 n)
  (fabs fp1 fp1)
  (put-double-float fp1 val)
  (blr))

; Likewise.
(defppclapfunction %%short-float-abs ((n arg_y) (val arg_z))
  (get-single-float fp1 n)
  (fabs fp0 fp1)
  (put-single-float fp0 val)
  (blr))



; rets hi (25 bits) lo (28 bits) exp sign
(defppclapfunction %integer-decode-double-float ((n arg_z))
  (lwz imm0  ppc32::double-float.value n)
  (rlwinm imm1 imm0 (+ 1 ppc32::fixnumshift) (- 32 ppc32::fixnumshift 1) ; sign boxed
          				   (- 32 ppc32::fixnumshift 1))
  (add imm1 imm1 imm1)  ; imm1 = (fixnum 2) (neg) or 0 (pos)
  (subfic temp0 imm1 '1)  ; sign boxed
  (rlwinm. imm2 imm0 (- 32 20)  21  31)   ; right 20, keep 11 bits exp - test for 0
  ;(subi imm2 imm2 (+ 53 1022))            ; unbias and scale
  (slwi imm2 imm2 ppc32::fixnumshift)      ; box
  (mr temp1 imm2)                        ; boxed unbiased exponent
  (rlwinm imm0 imm0 12  0 19)            ; 20 bits of hi float left 12
  (beq @denorm)                          ; cr set way back
  (addi imm0 imm0 1)                     ;  add implied 1
  @denorm
  (rlwinm imm0 imm0 (+ (- 32 12) 4 ppc32::fixnumshift) 0 31)
  (lwz imm1 ppc32::double-float.val-low n) ; 
  (rlwimi imm0 imm1 (+ 4 ppc32::fixnumshift)
                    (1+ (- 31 4 ppc32::fixnumshift))
                    (- 31 ppc32::fixnumshift))  ; high 4 bits in fixnum pos
  (rlwinm imm1 imm1 (- 4 ppc32::fixnumshift) 
                    (- 4 ppc32::fixnumshift)
                    (- 31 ppc32::fixnum-shift)) ; 28 bits  thats 2 2 29
  (vpush imm0)   ; hi 25 bits of mantissa (includes implied 1)
  (vpush imm1)   ; lo 28 bits of mantissa
  (vpush temp1)  ; exp
  (vpush temp0)  ; sign
  (set-nargs 4)
  (la temp0 16 vsp)
  (ba .SPvalues))


; hi is 25 bits lo is 28 bits
; big is 32 lo, 21 hi right justified
(defppclapfunction make-big-53 ((hi arg_x)(lo arg_y)(big arg_z))
  (rlwinm imm0 lo (- 32 ppc32::fixnumshift) 4 31)
  (rlwimi imm0 hi (- 32 4 ppc32::fixnumshift) 0 3)
  (stw imm0 (+ ppc32::misc-data-offset 0) big)   ; low goes in 1st wd
  (rlwinm imm0 hi (- 32 (+ ppc32::fixnumshift 4)) 11 31)  ; high in second
  (stw imm0 (+ ppc32::misc-data-offset 4) big)
  (blr))





(defppclapfunction dfloat-significand-zeros ((dfloat arg_z))
  (lwz imm1 ppc32::double-float.value dfloat)
  (rlwinm. imm1 imm1 12 0 19)
  (cntlzw imm1 imm1)
  (beq @golo)
  (box-fixnum arg_z imm1)
  (blr)
  @golo
  (lwz imm1 ppc32::double-float.val-low dfloat)
  (cntlzw imm1 imm1)
  (addi imm1 imm1 20)
  (box-fixnum arg_z imm1)
  (blr))

(defppclapfunction sfloat-significand-zeros ((sfloat arg_z))
  (lwz imm1 ppc32::single-float.value sfloat)
  (rlwinm imm1 imm1 9 0 22)
  (cntlzw imm1 imm1)
  (box-fixnum arg_z imm1)
  (blr))




(defppclapfunction %%scale-dfloat ((float arg_x)(int arg_y)(result arg_z))
  (let ((fl.h 8)
        (fl.l 12)
        (sc.h 16)
        (sc.l 20))
    (clear-fpu-exceptions)
    (lwz imm0 ppc32::double-float.value float)
    (lwz imm1 ppc32::double-float.val-low float)
    (stwu tsp -24 tsp)
    (stw tsp 4 tsp)
    (stw imm0 fl.h tsp)
    (stw imm1 fl.l tsp)
    (unbox-fixnum imm0 int)
    ;(addi imm0 imm0 1022)  ; bias exponent - we assume no ovf
    (slwi imm0 imm0 20)     ; more important - get it in right place
    (stw imm0 sc.h tsp)
    (stw rzero sc.l tsp)
    (lfd fp0 fl.h tsp)
    (lfd fp1 sc.h tsp)
    (lwz tsp 0 tsp)
    (fmul fp2 fp0 fp1)
    (stfd fp2 ppc32::double-float.value result)
    (blr)))

(defppclapfunction %%scale-sfloat ((float arg_x)(int arg_y)(result arg_z))
  (let ((sc.h 12))
    (clear-fpu-exceptions)
    (lfs fp0 ppc32::single-float.value float)
    (unbox-fixnum imm0 int)
    (slwi imm0 imm0 IEEE-single-float-mantissa-width)
    (stwu tsp -16 tsp)
    (stw tsp 4 tsp)
    (stw imm0 sc.h tsp)
    (lfs fp1 sc.h tsp)
    (lwz tsp 0 tsp)
    (fmuls fp2 fp0 fp1)
    (stfs fp2 ppc32::single-float.value result)
    (blr)))
                   




(defppclapfunction %copy-double-float ((f1 arg_y) (f2 arg_z))
  (lfd fp0 ppc32::double-float.value f1)
  (stfd fp0 ppc32::double-float.value f2)
  (blr))
                   

(defppclapfunction %copy-short-float ((f1 arg_y) (f2 arg_z))
  (lfs fp0 ppc32::single-float.value f1)
  (stfs fp0 ppc32::single-float.value f2)
  (blr))

(defppclapfunction %double-float-exp ((n arg_z))
  (lwz imm1 ppc32::double-float.value n)
  (rlwinm arg_z imm1 (- 32 (- 20 ppc32::fixnumshift)) 19  29) ; right 20 left 2 = right 18 = left 14
  (blr))

(defppclapfunction set-%double-float-exp ((float arg_y) (exp arg_z))
  (lwz imm1 ppc32::double-float.value float)
  (rlwimi imm1 exp (- 20 ppc32::fixnumshift) 1 11)
  (stw imm1 ppc32::double-float.value float) ; hdr - tag = 8 - 2
  (blr))


(defppclapfunction %short-float-exp ((n arg_z))
  (lwz imm1 ppc32::single-float.value n)
  (rlwinm arg_z imm1 (- 32 (- 23 ppc32::fixnumshift)) 22 29)
  (blr))

(defppclapfunction set-%short-float-exp ((float arg_y) (exp arg_z))
  (lwz imm1 ppc32::single-float.value float)
  (rlwimi imm1 exp (- 23 ppc32::fixnumshift) 1 8)
  (stw imm1 ppc32::single-float.value float)
  (blr))

  
(defppclapfunction %short-float->double-float ((src arg_y) (result arg_z))
  (get-single-float fp0 src)
  (put-double-float fp0 result)
  (blr))

#+ppc32-target
(defppclapfunction %double-float->short-float ((src arg_y) (result arg_z))
  (clear-fpu-exceptions)
  (get-double-float fp0 src)
  (frsp fp1 fp0)
  (put-single-float fp1 result)
  (blr))

#+ppc64-target
(defppclapfunction %double-float->short-float ((src arg_z))
  (clear-fpu-exceptions)
  (get-double-float fp0 src)
  (frsp fp1 fp0)
  (stfs fp1 ppc64::tcr.single-float-convert rcontext)
  (ld arg_z ppc64::tcr.single-float-convert rcontext)
  (blr))
  


#+ppc32-target
(defppclapfunction %int-to-sfloat ((int arg_y) (sfloat arg_z))
  (int-to-freg int fp0 imm0)
  (stfs fp0 ppc32::single-float.value sfloat)
  (blr))

#+ppc64-target
(defppclapfunction %int-to-sfloat ((int arg_z))
  (int-to-freg int fp0 imm0)
  (stfs fp0 ppc64::tcr.single-float-convert rcontext)
  (ld arg_z ppc64::tcr.single-float-convert rcontext)
  (blr))
  

(defppclapfunction %int-to-dfloat ((int arg_y) (dfloat arg_z))
  (int-to-freg int fp0 imm0)
  (stfd fp0 target::double-float.value dfloat)
  (blr))



; Manipulating the FPSCR.
; This  returns the bottom 8 bits of the FPSCR
(defppclapfunction %get-fpscr-control ()
  (mffs fp0)
  (stfd fp0 target::tcr.lisp-fpscr-high rcontext)
  (lbz imm0 (+ target::tcr.lisp-fpscr-high 7) rcontext)
  (box-fixnum arg_z imm0)
  (blr))

; Returns the high 24 bits of the FPSCR
(defppclapfunction %get-fpscr-status ()
  (mffs fp0)
  (stfd fp0 target::tcr.lisp-fpscr-high rcontext)
  (lwz imm0 target::tcr.lisp-fpscr-low tsp)
  (clrrwi imm0 imm0 8)
  (srwi arg_z imm0 (- 8 target::fixnumshift))
  (blr))

; Set the high 24 bits of the FPSCR; leave the low 8 unchanged
(defppclapfunction %set-fpscr-status ((new arg_z))
  (slwi imm0 new (- 8 target::fixnumshift))
  (stw imm0 target::tcr.lisp-fpscr-low rcontext)
  (lfd fp0 target::tcr.lisp-fpscr-high rcontext)
  (mtfsf #xfc fp0)                      ; set status fields [0-5]
  (blr))

; Set the low 8 bits of the FPSCR.  Zero the upper 24 bits
(defppclapfunction %set-fpscr-control ((new arg_z))
  (unbox-fixnum imm0 new)
  (clrlwi imm0 imm0 24)                 ; ensure that "status" fields are clear
  (stw imm0 target::tcr.lisp-fpscr-low rcontext)
  (lfd fp0 target::tcr.lisp-fpscr-high rcontext)
  (mtfsf #xff fp0)                      ; set all fields [0-7]
  (blr))

(defppclapfunction %ffi-exception-status ()
  (lwz imm0  ppc32::tcr.ffi-exception rcontext)
  (mtcrf #xfc imm0)
  (mcrfs :cr6 :cr6)
  (mcrfs :cr7 :cr7)
  (crand ppc::fpscr-fex-bit ppc::fpscr-oe-bit ppc::fpscr-ox-bit)
  (bt ppc::fpscr-fex-bit @set)
  (crand ppc::fpscr-fex-bit ppc::fpscr-ve-bit ppc::fpscr-vx-bit)
  (bt ppc::fpscr-fex-bit @set)
  (crand ppc::fpscr-fex-bit ppc::fpscr-ue-bit ppc::fpscr-ux-bit)
  (bt ppc::fpscr-fex-bit @set)
  (crand ppc::fpscr-fex-bit ppc::fpscr-ze-bit ppc::fpscr-zx-bit)
  (bt ppc::fpscr-fex-bit @set)
  (crand ppc::fpscr-fex-bit ppc::fpscr-xe-bit ppc::fpscr-xx-bit)
  (bf ppc::fpscr-fex-bit @ret)
  @set
  (oris imm0 imm0 #xc000)
  @ret
  (srwi arg_z imm0 (- 8 target::fixnumshift))
  (blr))
  

; See if the binary double-float operation OP set any enabled
; exception bits in the fpscr
(defun %df-check-exception-2 (operation op0 op1 fp-status)
  (declare (type (unsigned-byte 24) fp-status))
  (when (logbitp (- 23 ppc::fpscr-fex-bit) fp-status)
    (%set-fpscr-status 0)
    ;; Ensure that operands are heap-consed
    (%fp-error-from-status fp-status 
			   (%get-fpscr-control)
			   operation 
			   (%copy-double-float op0 (%make-dfloat)) 
			   (%copy-double-float op1 (%make-dfloat)))))

(defun %sf-check-exception-2 (operation op0 op1 fp-status)
  (declare (type (unsigned-byte 24) fp-status))
  (when (logbitp (- 23 ppc::fpscr-fex-bit) fp-status)
    (%set-fpscr-status 0)
    ;; Ensure that operands are heap-consed
    (%fp-error-from-status fp-status 
			   (%get-fpscr-control)
			   operation
			   #+ppc32-target
			   (%copy-short-float op0 (%make-sfloat))
			   #+ppc64-target op0
			   #+ppc32-target
			   (%copy-short-float op1 (%make-sfloat))
			   #+ppc64-target op1)))

(defun %df-check-exception-1 (operation op0 fp-status)
  (declare (fixnum fp-status))
  (when (logbitp (- 23 ppc::fpscr-fex-bit) fp-status)
    (%set-fpscr-status 0)
    ;; Ensure that operands are heap-consed
    (%fp-error-from-status fp-status 
                              (%get-fpscr-control)
                              operation 
                              (%copy-double-float op0 (%make-dfloat)))))

(defun %sf-check-exception-1 (operation op0 fp-status)
  (declare (type (unsigned-byte 24) fp-status))
  (when (logbitp (- 23 ppc::fpscr-fex-bit) fp-status)
    (%set-fpscr-status 0)
					; Ensure that operands are heap-consed
    (%fp-error-from-status fp-status 
			   (%get-fpscr-control)
			   operation
			   #+ppc32-target
			   (%copy-short-float op0 (%make-sfloat))
			   #+ppc64-target op0)))


(defun fp-condition-from-fpscr (status-bits control-bits)
  (declare (fixnum status-bits control-bits))
  (cond 
   ((and (logbitp (- 23 ppc::fpscr-vx-bit) status-bits)
         (logbitp (- 31 ppc::fpscr-ve-bit) control-bits))
    'floating-point-invalid-operation)
   ((and (logbitp (- 23 ppc::fpscr-ox-bit) status-bits)
         (logbitp (- 31 ppc::fpscr-oe-bit) control-bits))
    'floating-point-overflow)
   ((and (logbitp (- 23 ppc::fpscr-ux-bit) status-bits)
         (logbitp (- 31 ppc::fpscr-ue-bit) control-bits))
    'floating-point-underflow)
   ((and (logbitp (- 23 ppc::fpscr-zx-bit) status-bits)
         (logbitp (- 31 ppc::fpscr-ze-bit) control-bits))
    'division-by-zero)
   ((and (logbitp (- 23 ppc::fpscr-xx-bit) status-bits)
         (logbitp (- 31 ppc::fpscr-xe-bit) control-bits))
    'floating-point-inexact)))

; This assumes that the FEX and one of {VX OX UX ZX XX} is set.
; Ignore 
(defun %fp-error-from-status (status-bits control-bits operation &rest operands)
  (declare (type (unsigned-byte 16) status-bits))
  (let* ((condition-class (fp-condition-from-fpscr status-bits control-bits)))
    (if condition-class
      (error (make-instance condition-class
               :operation operation
               :operands operands)))))

(defun fp-minor-opcode-operation (minor-opcode)
  (case minor-opcode
    (25 '*)
    (18 '/)
    (20 '-)
    (21 '+)
    (t 'unknown)))

;;; Don't we already have about 20 versions of this ?
(defppclapfunction %double-float-from-macptr! ((ptr arg_x) (byte-offset arg_y) (dest arg_z))
  (lwz imm0 ppc32::macptr.address ptr)
  (unbox-fixnum imm1 byte-offset)
  (lfdx fp1 imm0 imm1)
  (put-double-float fp1 dest)
  (blr))


(defvar *rounding-mode-alist*
  '((:nearest . 0) (:zero . 1) (:positive . 2) (:negative . 3)))

(defun get-fpu-mode ()
  (let* ((flags (%get-fpscr-control)))
    `(:rounding-mode ,(car (nth (logand flags 3) *rounding-mode-alist*))
                     :overflow ,(logbitp 6 flags)
                     :underflow ,(logbitp 5 flags)
                     :division-by-zero ,(logbitp 4 flags)
                     :invalid ,(logbitp 7 flags)
                     :inexact ,(logbitp 2 flags))))

;; did we document this?
(defun set-fpu-mode (&key (rounding-mode :nearest rounding-p)
                          (overflow t overflow-p)
                          (underflow t underflow-p)
                          (division-by-zero t zero-p)
                          (invalid t invalid-p)
                          (inexact t inexact-p))
  (let* ((mask (logior (if rounding-p #x03 #x00)
                       (if invalid-p #x80 #x00)
                       (if overflow-p #x40 #x00)
                       (if underflow-p #x20 #x00)
                       (if zero-p #x10 #x00)
                       (if inexact-p #x08 #x00)))
         (new (logior (or (cdr (assoc rounding-mode *rounding-mode-alist*))
                          (error "Unknown rounding mode: ~s" rounding-mode))
                      (if invalid #x80 0)
                      (if overflow #x40 0)
                      (if underflow #x20 0)
                      (if division-by-zero #x10 0)
                      (if inexact #x08 0))))
    (declare (type (unsigned-byte 8) new mask))
    (%set-fpscr-control (logior (logand new mask)
                                (logandc2 (%get-fpscr-control) mask)))
    (get-fpu-mode)))


; Copy a single float pointed at by the macptr in single
; to a double float pointed at by the macptr in double

(defppclapfunction %single-float-ptr->double-float-ptr ((single arg_y) (double arg_z))
  (check-nargs 2)
  (macptr-ptr imm0 single)
  (lfs fp0 0 imm0)
  (macptr-ptr imm0 double)
  (stfd fp0 0 imm0)
  (blr))

;;; Copy a double float pointed at by the macptr in double
;;; to a single float pointed at by the macptr in single.
(defppclapfunction %double-float-ptr->single-float-ptr ((double arg_y) (single arg_z))
  (check-nargs 2)
  (macptr-ptr imm0 double)
  (lfd fp0 0 imm0)
  (macptr-ptr imm0 single)
  (stfs fp0 0 imm0)
  (blr))


(defppclapfunction %set-ieee-single-float-from-double ((src arg_y) (macptr arg_z))
  (check-nargs 2)
  (macptr-ptr imm0 macptr)
  (get-double-float fp1 src)
  (stfs fp1 0 imm0)
  (blr))

#+ppc32-target
(defun host-single-float-from-unsigned-byte-32 (u32)
  (let* ((f (%make-sfloat)))
    (setf (uvref f ppc32::single-float.value-cell) u32)
    f))

#+ppc64-target
(defppclapfunction host-single-float-from-unsigned-byte-32 ((u32 arg_z))
  (sldi arg_z arg_z (- 32 ppc64::fixnumshift))
  (ori arg_z arg_z ppc64::subtag-single-float)
  (blr))


#+ppc32-target
(defun single-float-bits (f)
  (uvref f ppc32::single-float.value-cell))

#+ppc64-target
(defppclapfunction single-float-bits ((f arg_z))
  (srdi arg_z f (- 32 ppc64::fixnumshift))
  (blr))