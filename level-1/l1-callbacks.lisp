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

;;; l1-callbacks.lisp

(defglobal *callback-lock* (make-lock))


;;; MacOS toolbox routines were once written mostly in Pascal, so some
;;; code still refers to callbacks from foreign code as "pascal-callable
;;; functions".

; %Pascal-Functions% Entry
(def-accessor-macros %svref
  pfe.routine-descriptor
  pfe.proc-info
  pfe.lisp-function)

(defun %cons-pfe (routine-descriptor proc-info lisp-function sym without-interrupts)
  (vector routine-descriptor proc-info lisp-function sym without-interrupts))

; (defcallback ...) on the PPC expands into a call to this function.
(defun define-callback-function (lisp-function  &optional doc-string (without-interrupts t) monitor-exception-ports
                                                   &aux name trampoline)
  (unless (functionp lisp-function)
    (setq lisp-function (require-type lisp-function 'function)))
  (unless (and (symbolp (setq name (function-name lisp-function)))
               ;Might as well err out now before do any _Newptr's...
               (not (constant-symbol-p name)))
    (report-bad-arg name '(and symbol (not (satisfies constantp)))))
  (with-lock-grabbed (*callback-lock*)
    (let ((len (length %pascal-functions%)))
      (declare (fixnum len))
      (when (boundp name)
        (let ((old-tramp (symbol-value name)))
          (dotimes (i len)
            (let ((pfe (%svref %pascal-functions% i)))
              (when (and (vectorp pfe)
                         (eql old-tramp (pfe.routine-descriptor pfe)))
                
                (setf (pfe.without-interrupts pfe) without-interrupts)
                (setf (pfe.lisp-function pfe) lisp-function)
                (setq trampoline old-tramp))))))
      (unless trampoline
        (let ((index (dotimes (i (length %pascal-functions%)
                               (let* ((new-len (+ len 5))
                                      (new-pf (make-array (the fixnum new-len))))
                                 (declare (fixnum new-len))
                                 (dotimes (i len)
                                   (setf (%svref new-pf i) (%svref %pascal-functions% i)))
                                 (do ((i len (1+ i)))
                                     ((>= i new-len))
                                   (declare (fixnum i))
                                   (setf (%svref new-pf i) nil))
                                 (setq %pascal-functions% new-pf)
                                 len))
                       (unless (%svref %pascal-functions% i)
                         (return i)))))
          (setq trampoline (make-callback-trampoline index))
          (setf (%svref %pascal-functions% index)
                (%cons-pfe trampoline monitor-exception-ports lisp-function name without-interrupts)))))
    ;;(%proclaim-special name)          ;
    ;; already done by defpascal expansion
    (set name trampoline)
    (record-source-file name 'defcallback)
    (when (and doc-string *save-doc-strings*)
      (setf (documentation name 'variable) doc-string))
    (when *fasload-print* (format t "~&~S~%" name))
    name))


(defun %lookup-pascal-function (index)
  (declare (optimize (speed 3) (safety 0)))
  (with-lock-grabbed (*callback-lock*)
    (let* ((pfe (svref %pascal-functions% index)))
      (values (pfe.lisp-function pfe)
              (pfe.without-interrupts pfe)))))


;; The kernel only really knows how to call back to one function,
;; and you're looking at it ...
(defun %pascal-functions% (index args-ptr-fixnum)
  (declare (optimize (speed 3) (safety 0)))
  (multiple-value-bind (lisp-function without-interrupts)
      (%lookup-pascal-function index)
    (if without-interrupts
      (without-interrupts (funcall lisp-function args-ptr-fixnum))
      (funcall lisp-function args-ptr-fixnum))))
