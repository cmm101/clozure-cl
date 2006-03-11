;;;-*-Mode: LISP; Package: CCL -*-
;;;
;;;   Copyright (C) 2001 Clozure Associates
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

;;; "Generic" syscall sypport.

(in-package "CCL")

(defstruct syscall
  (idx 0 :type fixnum)
  (arg-specs () :type list)
  (result-spec nil :type symbol)
  (min-args 0 :type fixnum))

(defmacro define-syscall (name idx (&rest arg-specs) result-spec
			       &key (min-args (length arg-specs)))
  `(locally
    (declare (special #+linux-target *linux-syscalls* #+darwin-target *darwin-syscalls*))
    (setf (gethash ',name
                    #+linux-target *linux-syscalls*
                    #+darwin-target *darwin-syscalls*)
     (make-syscall :idx ,idx
      :arg-specs ',arg-specs
      :result-spec ',result-spec
      :min-args ,min-args))
    ',name))

(defmacro syscall (name &rest args)
  (let* ((info (or (gethash name #+linux-target *linux-syscalls*
                                 #+darwin-target *darwin-syscalls*)
		   (error "Unknown system call: ~s" name)))
	 (idx (syscall-idx info))
	 (arg-specs (syscall-arg-specs info))
	 (n-argspecs (length arg-specs))
	 (n-args (length args))
	 (min-args (syscall-min-args info))
	 (result (syscall-result-spec info)))
    (unless (and (>= n-args min-args) (<= n-args n-argspecs))
      (error "wrong number of args in ~s" args))
    (do* ((call ())
	  (specs arg-specs (cdr specs))
	  (args args (cdr args)))
	 ((null args)
	  `(%syscall ,idx ,@(nreverse (cons result call))))
      (push (car specs) call)
      (push (car args) call))))
