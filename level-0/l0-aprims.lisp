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



; l0-aprims.lisp

;;; This weak list is used to track semaphores as well as locks.
(defvar %system-locks% nil)
(setf %system-locks% (%cons-population nil))

(defun record-system-lock (l)
  (atomic-push-uvector-cell %system-locks% population.data l)
  l)

;;; This has to run very early in the initial thread.
(defun %revive-system-locks ()
  (dolist (s (population-data %system-locks%))
    (%revive-macptr s)
    (%setf-macptr s
                  (case (uvref s ppc32::xmacptr.flags-cell)
                    (#.$flags_DisposeRecursiveLock
                     (ff-call
                      (%kernel-import ppc32::kernel-import-new-recursive-lock)
                      :address))
                    (#.$flags_DisposeRwlock
                     (ff-call
                      (%kernel-import ppc32::kernel-import-rwlock-new)
                      :address))
		    (#.$flags_DisposeSemaphore
		     (ff-call
		      (%kernel-import ppc32::kernel-import-new-semaphore)
		      :signed-fullword 0
		      :address))))
    (set-%gcable-macptrs% s)))

(dolist (p %all-packages%)
  (setf (pkg.lock p) (make-read-write-lock)))

(defparameter %all-packages-lock% nil)
(setq %all-packages-lock% (make-read-write-lock))



(defun %cstr-pointer (string pointer)
  (multiple-value-bind (s o n) (dereference-base-string string)
    (declare (fixnum o n))
    (%copy-ivector-to-ptr s o pointer 0 n)
    (setf (%get-byte pointer n) 0))
  nil)

(defun %cstr-segment-pointer (string pointer start end)
  (declare (fixnum start end))
  (let* ((n (- end start)))
    (multiple-value-bind (s o) (dereference-base-string string)
      (declare (fixnum o))
      (%copy-ivector-to-ptr s (the fixnum (+ o start)) pointer 0 n)
    (setf (%get-byte pointer n) 0)
    nil)))

(defun string (thing)
  "Coerces X into a string. If X is a string, X is returned. If X is a
   symbol, X's pname is returned. If X is a character then a one element
   string containing that character is returned. If X cannot be coerced
   into a string, an error occurs."
  (etypecase thing
    (string thing)
    (symbol (symbol-name thing))
    (character (make-string 1 :initial-element thing))))


(defun dereference-base-string (s)
  (multiple-value-bind (vector offset) (array-data-and-offset s)
    (unless (typep vector 'simple-base-string) (report-bad-arg s 'base-string))
    (values vector offset (length s))))

(defun make-gcable-macptr (flags)
  (let ((v (%alloc-misc ppc32::xmacptr.element-count ppc32::subtag-macptr)))
    (setf (uvref v ppc32::xmacptr.address-cell) 0) ; ?? yup.
    (setf (uvref v ppc32::xmacptr.flags-cell) flags)
    (set-%gcable-macptrs% v)
    v))

(defun %make-recursive-lock-ptr ()
  (record-system-lock
   (%setf-macptr
    (make-gcable-macptr $flags_DisposeRecursiveLock)
    (ff-call (%kernel-import ppc32::kernel-import-new-recursive-lock)
             :address))))


  
(defun make-recursive-lock ()
  (make-lock nil))

(defun make-lock (&optional name)
  (gvector :lock (%make-recursive-lock-ptr) 'recursive-lock 0 name))

(defun lock-name (lock)
  (uvref (require-type lock 'lock) ppc32::lock.name-cell))

(defun recursive-lock-ptr (r)
  (if (and (eq ppc32::subtag-lock (typecode r))
           (eq (%svref r ppc32::lock.kind-cell) 'recursive-lock))
    (%svref r ppc32::lock._value-cell)
    (report-bad-arg r 'recursive-lock)))



(defun make-read-write-lock ()
  (gvector :lock 0 'read-write-lock 0 nil))


(defun %make-semaphore-ptr ()
  (let* ((p (ff-call (%kernel-import ppc32::kernel-import-new-semaphore)
	     :signed-fullword 0
             :address)))
    (if (%null-ptr-p p)
      (error "Can't create semaphore.")
      (record-system-lock
       (%setf-macptr
	(make-gcable-macptr $flags_DisposeSemaphore)
	p)))))

(defun make-semaphore ()
  (%istruct 'semaphore (%make-semaphore-ptr)))
  

; end
