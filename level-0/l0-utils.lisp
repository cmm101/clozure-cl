; -*- Mode: Lisp;  Package: CCL; -*-
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



; l0-utils.lisp


#+allow-in-package
(in-package "CCL")

(defun %proclaim-notspecial (sym)
  (%symbol-bits sym (logandc2 (%symbol-bits sym) (ash 1 $sym_bit_special))))



; We MAY need a scheme for finding all of the areas in a lisp library.
(defun %map-areas (function &optional (maxcode ppc32::area-dynamic) (mincode ppc32::area-readonly))
  (declare (fixnum maxcode mincode))
  (do* ((a (%normalize-areas) (%lisp-word-ref a (ash ppc32::area.succ -2)))
        (code ppc32::area-dynamic (%lisp-word-ref a (ash ppc32::area.code -2)))
        (dynamic t nil))
       ((= code ppc32::area-void))
    (declare (fixnum code))
    (if (and (<= code maxcode)
             (>= code mincode))
      (if dynamic 
        (walk-dynamic-area a function)
        (unless (= code ppc32::area-dynamic)        ; ignore egc areas, 'cause walk-dynamic-area sees them.
          (walk-static-area a function))))))


   ; there'll be functions in static lib areas.


(defun %map-lfuns (f)
  (let* ((filter #'(lambda (obj) (when (functionp obj) (funcall f obj)))))
    (declare (dynamic-extent filter))
    (%map-areas filter ppc32::area-dynamic ppc32::area-staticlib)))


(defun ensure-simple-string (s)
  (cond ((simple-string-p s) s)
        ((stringp s)
         (let* ((len (length s))
                (new (make-string len :element-type 'base-char)))
           (declare (fixnum len)(optimize (speed 3)(safety 0)))
           (multiple-value-bind (ss offset) (array-data-and-offset s)
	     (%copy-ivector-to-ivector ss offset new 0 len))
           new))
        (t (report-bad-arg s 'string))))

; Returns two fixnums: low, high
#+ppc-target
(defppclapfunction macptr-to-fixnums ((macptr arg_z))
  (check-nargs 1)
  (trap-unless-typecode= macptr ppc32::subtag-macptr)
  (lwz imm0 ppc32::macptr.address macptr)
  (rlwinm imm1 imm0 2 14 29)
  (vpush imm1)
  (rlwinm imm1 imm0 18 14 29)
  (vpush imm1)
  (set-nargs 2)
  (la temp0 8 vsp)
  (ba .SPvalues))

#+sparc-target
(defsparclapfunction macptr-to-fixnums ((macptr %arg_z))
  (check-nargs 1)
  (trap-unless-typecode= macptr ppc32::subtag-macptr)
  (ld (macptr ppc32::macptr.address) %imm0)
  (sll %imm0 16 %imm1)
  (srl %imm1 (- 16 ppc32::fixnumshift) %imm1)
  (vpush %imm1)
  (srl %imm0 (- 16 ppc32::fixnumshift) %imm1)
  (vpush %imm1)
  (set-nargs 2)
  (jump-subprim .SPvalues)
  (add %vsp 8 %temp0))



(defun macptr<= (p1 p2)
  (multiple-value-bind (p1-low p1-high) (macptr-to-fixnums p1)
    (declare (fixnum p1-low p1-high))
    (multiple-value-bind (p2-low p2-high) (macptr-to-fixnums p2)
      (declare (fixnum p2-low p2-high))
      (or (< p1-high p2-high)
          (and (eql p1-high p2-high)
               (<= p1-low p2-low))))))

(defun macptr-evenp (p)
  (let ((low (macptr-to-fixnums p)))
    (declare (fixnum low))
    (evenp low)))

(defun nremove (elt list)
  (let* ((handle (cons nil list))
         (splice handle))
    (declare (dynamic-extent handle))
    (loop
      (if (eq elt (car (%cdr splice)))
        (unless (setf (%cdr splice) (%cddr splice)) (return))
        (unless (cdr (setq splice (%cdr splice)))
          (return))))
    (%cdr handle)))

; end
