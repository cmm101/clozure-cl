;;;-*- Mode: Lisp; Package: (ARCH :use CL) -*-
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

(defpackage "ARCH"
  (:use "CL"))

(in-package "ARCH")



(eval-when (:compile-toplevel :load-toplevel :execute)



(defconstant tcr-flag-bit-foreign 0)
(defconstant tcr-flag-bit-awaiting-preset 1)



)

(defmacro make-vheader (element-count subtag)
  `(logior ,subtag (ash ,element-count 8)))



;; Error numbers, as used in UU0s and such.
;; These match "ccl:pmcl;errors.h" & "ccl:pmcl;errors.s"

(defconstant error-reg-regnum 0)        ; "real" error number is in RB field of UU0.
                                        ; Currently only used for :errchk in emulated traps
                                        ; The errchk macro should expand into a check-trap-error vinsn, too.
(defconstant error-udf 1)               ; Undefined function (reported by symbol-function)
(defconstant error-udf-call 2)          ; Attempt to call undefined function
(defconstant error-throw-tag-missing 3)
(defconstant error-alloc-failed 4)      ; can't allocate (largish) vector
(defconstant error-stack-overflow 5)    ; some stack overflowed.
(defconstant error-excised-function-call 6)     ; excised function was called.
(defconstant error-too-many-values 7)   ; too many values returned
(defconstant error-cant-take-car 8)
(defconstant error-cant-take-cdr 9)
(defconstant error-cant-call 17)        ; Attempt to funcall something that is not a symbol or function.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defconstant error-type-error 64)
)

(defconstant error-fpu-exception-double 1024)   ; FPU exception, binary double-float op
(defconstant error-fpu-exception-single 1025)

(defconstant error-memory-full 2048)

;; These are now supposed to match (mod 64) the %type-error-typespecs%
;; array that %err-disp looks at.
(ccl::defenum (:start  error-type-error :prefix "ERROR-OBJECT-NOT-")
  array
  bignum
  fixnum
  character
  integer
  list
  number
  sequence
  simple-string
  simple-vector
  string
  symbol
  macptr
  real
  cons
  unsigned-byte
  radix
  float  
  rational
  ratio
  short-float
  double-float
  complex
  vector
  simple-base-string
  function
  unsigned-byte-16
  unsigned-byte-8
  unsigned-byte-32
  signed-byte-32
  signed-byte-16
  signed-byte-8
  base-char
  bit
  unsigned-byte-24
  unsigned-byte-64
  signed-byte-64
  unsigned-byte-56
  )





(defun builtin-function-name-offset (name)
  (and name (position name ccl::%builtin-functions% :test #'eq)))

(ccl::defenum ()
  storage-class-lisp                    ; General lisp objects
  storage-class-imm                     ; Fixnums, chars, NIL: not relocatable
  storage-class-wordptr                 ; "Raw" (fixnum-tagged) pointers to stack,etc
  storage-class-u8                      ; Unsigned, untagged, 8-bit objects
  storage-class-s8                      ; Signed, untagged, 8-bit objects
  storage-class-u16                     ; Unsigned, untagged, 16-bit objects
  storage-class-s16                     ; Signed, untagged, 16-bit objects
  storage-class-u32                     ; Unsigned, untagged, 8-bit objects
  storage-class-s32                     ; Signed, untagged, 8-bit objects
  storage-class-address                 ; "raw" (untagged) 32-bit addresses.
  storage-class-single-float            ; 32-bit single-float objects
  storage-class-double-float            ; 64-bit double-float objects
  storage-class-pc                      ; pointer to/into code vector
  storage-class-locative                ; pointer to/into node-misc object
  storage-class-crf                     ; condition register field
  storage-class-crbit                   ; condition register bit: 0-31
  storage-class-crfbit                  ; bit within condition register field : 0-3
  storage-class-u64			; (unsigned-byte 64)
  storage-class-s64			; (signed-byte 64)
)

;; For assembly/disassembly, at least on RISC platforms.
(defstruct opcode 
  (name (error "Opcode name must be present") :type (or string symbol))
  (opcode 0 :type (unsigned-byte 32))
  (majorop 0 :type (unsigned-byte 6))
  (mask #xffffffff :type (unsigned-byte 32))
  (flags 0 :type (unsigned-byte 32))
  (operands () :type list)
  (min-args 0 :type (unsigned-byte 3))
  (max-args 0 :type (unsigned-byte 3))
  (op-high 0 :type (unsigned-byte 16))
  (op-low 0 :type (unsigned-byte 16))
  (mask-high #xffff :type (unsigned-byte 16))
  (mask-low #xffff :type (unsigned-byte 16))
  (vinsn-operands () :type list)
  (min-vinsn-args 0 :type fixnum)
  (max-vinsn-args 0 :type fixnum))

(defmethod print-object ((p opcode) stream)
  (declare (ignore depth))
  (print-unreadable-object (p stream :type t) 
    (format stream "~a" (string (opcode-name p)))))

(defmethod make-load-form ((p opcode) &optional env)
  (make-load-form-saving-slots p :environment env))

(defstruct operand
  (index 0 :type unsigned-byte)
  (width 0 :type (mod 32))
  (offset 0 :type (mod 32))
  (insert-function nil :type (or null symbol function))
  (extract-function 'nil :type (or symbol function))
  (flags 0 :type fixnum))

(defmethod make-load-form ((o operand) &optional env)
  (make-load-form-saving-slots o :environment env))

(defconstant operand-optional 27)
(defconstant operand-fake 28)

(defvar *known-target-archs* ())

(defstruct (target-arch (:conc-name target-)
                        (:constructor %make-target-arch))
  (name nil)
  (lisp-node-size 0)
  (nil-value 0)
  (fixnum-shift 0)
  (most-positive-fixnum 0)
  (most-negative-fixnum 0)
  (misc-data-offset 0)
  (misc-dfloat-offset 0)
  (nbits-in-word 0)
  (ntagbits 0)
  (nlisptagbits 0)
  (uvector-subtags 0)
  (max-64-bit-constant-index 0)
  (max-32-bit-constant-index 0)
  (max-16-bit-constant-index 0)
  (max-8-bit-constant-index 0)
  (max-1-bit-constant-index 0)
  (word-shift 0)
  (code-vector-prefix ())
  (gvector-types ())
  (1-bit-ivector-types ())
  (8-bit-ivector-types ())
  (16-bit-ivector-types ())
  (32-bit-ivector-types ())
  (64-bit-ivector-types ())
  (array-type-name-from-ctype-function ())
  (package-name ())
  (t-offset ())
  (array-data-size-function ())
  (numeric-type-name-to-typecode-function ())
  (subprims-base ())
  (subprims-shift ())
  (subprims-table ())
  (primitive->subprims ())
  (unbound-marker-value ())
  (slot-unbound-marker-value ())
  (fixnum-tag 0)
  (single-float-tag nil)
  (single-float-tag-is-subtag nil)
  (double-float-tag nil)
  (cons-tag nil)
  (null-tag nil)
  (symbol-tag nil)
  (symbol-tag-is-subtag nil)
  (function-tag nil)
  (function-tag-is-subtag nil)
  (big-endian t)
  (target-macros (make-hash-table :test #'eq)))
  
(defun make-target-arch (&rest keys)
  (declare (dynamic-extent keys))
  (let* ((arch (apply #'%make-target-arch keys))
         (tail (member (target-name arch) *known-target-archs*
                       :key #'target-name
                       :test #'eq)))
    (if tail
      (rplaca tail arch)
      (push arch *known-target-archs*))
    arch))

(defun find-target-arch (name)
  (car (member name *known-target-archs*
               :key #'target-name
               :test #'eq)))

(defun target-arch-macros (arch-name)
  (let* ((arch (or (find-target-arch arch-name)
                   (error "unknown arch: ~s" arch-name))))
    (target-target-macros arch)))

(defmacro defarchmacro (arch-name name arglist &body body &environment env)
  (let* ((lambda-form (ccl::parse-macro-1 name arglist body env)))
    `(progn
      (setf (gethash ',name (target-arch-macros ',arch-name))
       (ccl::nfunction ,name ,lambda-form))
      ',name)))

(defun arch-macro-function (arch-name name)
  (gethash name (target-arch-macros arch-name)))
    


;;; GC related operations
(defconstant gc-trap-function-immediate-gc -1)
(defconstant gc-trap-function-gc 0)
(defconstant gc-trap-function-purify 1)
(defconstant gc-trap-function-impurify 2)
(defconstant gc-trap-function-save-application 8)
(defconstant gc-trap-function-get-lisp-heap-threshold 16)
(defconstant gc-trap-function-set-lisp-heap-threshold 17)
(defconstant gc-trap-function-use-lisp-heap-threshold 18)
(defconstant gc-trap-function-egc-control 32)
(defconstant gc-trap-function-configure-egc 64)
(defconstant gc-trap-function-set-hons-area-size 128)


(provide "ARCH")
