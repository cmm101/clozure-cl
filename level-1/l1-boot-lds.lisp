;;;-*-Mode: LISP; Package: CCL -*-
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


; l1-boot-lds.lisp

(in-package "CCL")





(defun command-line-arguments ()
  *command-line-argument-list*)

(defun startup-ccl (&optional init-file)
  (with-simple-restart (abort "Abort startup.")
    (when init-file
      (with-simple-restart (continue "Skip loading init file.")
	(load init-file :if-does-not-exist nil :verbose nil)))
    (flet ((eval-string (s)
	     (with-simple-restart (continue "Skip evaluation of ~a" s)
	       (eval (read-from-string s))))
	   (load-file (name)
	     (with-simple-restart (continue "Skip loading ~s" name)
	       (load name))))
      (dolist (p *lisp-startup-parameters*)
	(let* ((param (cdr p)))
	  (case (car p)
	    (:gc-threshold
	     (multiple-value-bind (n last) (parse-integer param :junk-allowed t)
	       (when n
		 (if (< last (length param))
		   (case (schar param last)
		     ((#\k #\K) (setq n (ash n 10)))
		     ((#\m #\M) (setq n (ash n 20)))))
		 (set-lisp-heap-gc-threshold n)
		 (use-lisp-heap-gc-threshold))))
	    (:eval (eval-string param))
	    (:load (load-file param))))))))


(defun listener-function ()
  (progn
    (unless (or *inhibit-greeting* *quiet-flag*)
      (format t "~&Welcome to ~A ~A!~%"
	      (lisp-implementation-type)
	      (lisp-implementation-version)))
    (toplevel-loop)))


(defun make-mcl-listener-process (procname
                                  input-stream
                                  output-stream
                                  cleanup-function
                                  &key
                                  (initial-function #'listener-function)
                                  (close-streams t)
                                  (class 'process))
  (let ((p (make-process procname :class class)))
    (process-preset p #'(lambda ()
                          (let ((*terminal-io*
				 (make-echoing-two-way-stream
				  input-stream output-stream)))
			    (unwind-protect
				 (progn
				   (with-lock-grabbed
				       (*auto-flush-streams-lock*)
				     (pushnew output-stream
					      *auto-flush-streams*))
				   (let* ((shared-input
					   (input-stream-shared-resource
					    input-stream)))
				     (when shared-input
				       (setf (shared-resource-primary-owner
					      shared-input)
					     *current-process*)))
                                   (application-ui-operation
                                    *application*
                                    :note-current-package *package*)
				   (funcall initial-function))
			      (with-lock-grabbed
				  (*auto-flush-streams-lock*)
				(setq *auto-flush-streams*
				      (delete output-stream
					      *auto-flush-streams*)))
			      (funcall cleanup-function)
			      (when close-streams
				(close input-stream)
				(close output-stream))))))
    (process-enable p)
    p))


; End of l1-boot-lds.lisp
