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

; l1-readloop-lds.lisp

(in-package "CCL")



(defun toplevel-loop ()
  (loop
    (if (eq (catch :toplevel 
              (read-loop :break-level 0)) $xstkover)
      (format t "~&;[Stacks reset due to overflow.]")
      (when (eq *current-process* *initial-process*)
        (toplevel)))))


(defvar *defined-toplevel-commands* ())
(defvar *active-toplevel-commands* ())

(defun %define-toplevel-command (group-name key name fn doc args)
  (let* ((group (or (assoc group-name *defined-toplevel-commands*)
		    (car (push (list group-name)
			       *defined-toplevel-commands*))))
	 (pair (assoc key (cdr group) :test #'eq)))
    (if pair
      (rplacd pair (list* fn doc args))
      (push (cons key (list* fn doc args)) (cdr group))))
  name)

(define-toplevel-command 
    :global y (&optional p) "Yield control of terminal-input to process
whose name or ID matches <p>, or to any process if <p> is null"
    (if p
      (let* ((proc (find-process p)))
	(%%yield-terminal-to proc)	;may be nil
	(%%yield-terminal-to nil))))

(define-toplevel-command
    :global kill (p) "Kill process whose name or ID matches <p>"
    (let* ((proc (find-process p)))
      (if p
	(process-kill proc))))

(define-toplevel-command 
    :global proc (&optional p) "Show information about specified process <p>/all processes"
    (flet ((show-process-info (proc)
	     (format t "~&~d : ~a ~a ~20t[~a] "
		     (process-serial-number proc)
		     (if (eq proc *current-process*)
		       "->"
		       "  ")
		     (process-name proc)
		     (process-whostate proc))
	     (let* ((suspend-count (process-suspend-count proc)))
	       (if (and suspend-count (not (eql 0 suspend-count)))
		 (format t " (Suspended)")))
	     (let* ((terminal-input-shared-resource
		     (if (typep *terminal-io* 'two-way-stream)
		       (input-stream-shared-resource
			(two-way-stream-input-stream *terminal-io*)))))
	       (if (and terminal-input-shared-resource
			(%shared-resource-requestor-p
			 terminal-input-shared-resource proc))
		 (format t " (Requesting terminal input)")))
	     (fresh-line)))
      (if p
	(let* ((proc (find-process p)))
	  (if (null proc)
	    (format t "~&;; not found - ~s" p)
	    (show-process-info proc)))
	(dolist (proc (all-processes) (values))
	  (show-process-info proc)))))

(define-toplevel-command :break pop () "exit current break loop" (abort-break))
(define-toplevel-command :break go () "continue" (continue))
(define-toplevel-command :break q () "return to toplevel" (toplevel))
(define-toplevel-command :break r () "list restarts"
  (let* ((r (apply #'vector (compute-restarts *break-condition*))))
    (dotimes (i (length r) (terpri))
      (format t "~&~d. ~a" i (svref r i)))))

;;; From Marco Baringer 2003/03/18
(define-toplevel-command :break set (n frame value) "Set <n>th item of frame <frame> to <value>"
  (let* ((frame-sp (nth-raw-frame frame *break-frame* (%current-tcr))))
    (if frame-sp
        (toplevel-print (list (set-nth-value-in-frame frame-sp n (%current-tcr) value)))
        (format *debug-io* "No frame with number ~D~%" frame))))

(define-toplevel-command :global ? () "help"
  (dolist (g *active-toplevel-commands*)
    (dolist (c (cdr g))
      (let* ((command (car c))
	     (doc (caddr c))
	     (args (cdddr c)))
	(if args
	  (format t "~& (~S~{ ~A~}) ~8T~A" command args doc)
	  (format t "~& ~S  ~8T~A" command doc))))))


(define-toplevel-command :break b (&optional show-frame-contents) "backtrace"
  (when *break-frame*
    (print-call-history :detailed-p show-frame-contents
                        :start-frame *break-frame*)))

(define-toplevel-command :break c (n) "Choose restart <n>"
   (select-restart n))

(define-toplevel-command :break f (n) "Show backtrace frame <n>"
   (print-call-history :start-frame *break-frame*
                       :detailed-p n))

(define-toplevel-command :break v (n frame-number) "Return value <n> in frame <frame-number>"
  (let* ((frame-sp (nth-raw-frame frame-number *break-frame* (%current-tcr))))
    (if frame-sp
      (toplevel-print (list (nth-value-in-frame frame-sp n (%current-tcr)))))))

(defun %use-toplevel-commands (group-name)
  ;; Push the whole group
  (pushnew (assoc group-name *defined-toplevel-commands*)
	   *active-toplevel-commands*
	   :key #'(lambda (x) (car x))))  ; #'car not defined yet ...

(%use-toplevel-commands :global)

(defun check-toplevel-command (form)
  (let* ((cmd (if (consp form) (car form) form))
         (args (if (consp form) (cdr form))))
    (if (keywordp cmd)
      (dolist (g *active-toplevel-commands*)
	(when
	    (let* ((pair (assoc cmd (cdr g))))
	      (if pair 
		(progn (apply (cadr pair) args)
		       t)))
	  (return t))))))

;This is the part common to toplevel loop and inner break loops.
(defun read-loop (&key (break-level *break-level*)
		       (prompt-function #'(lambda (stream) (print-listener-prompt stream t)))
		       (input-stream *terminal-io*)
		       (output-stream *terminal-io*))
  (let* ((*break-level* break-level)
         (*last-break-level* break-level)
         *loading-file-source-file*
         *in-read-loop*
         *** ** * +++ ++ + /// // / -
         (eof-value (cons nil nil)))
    (declare (dynamic-extent eof-value))
    (loop
      (restart-case
        (catch :abort ;last resort...
          (loop
            (catch-cancel
              (loop                
                (setq *in-read-loop* nil
                      *break-level* break-level)
                (multiple-value-bind (form path print-result)
                    (toplevel-read :input-stream input-stream
                                   :output-stream output-stream
                                   :prompt-function prompt-function
                                   :eof-value eof-value)
                  (if (eq form eof-value)
                    (if (eof-transient-p (stream-device input-stream :input))
                      (progn
                        (stream-clear-input *terminal-io*)
                        (abort-break))
                      (quit))
                    (or (check-toplevel-command form)
                        (let* ((values (toplevel-eval form path)))
                        (if print-result (toplevel-print values))))))))
            (format *terminal-io* "~&Cancelled")))
        (abort () :report (lambda (stream)
                            (if (eq break-level 0)
                              (format stream "Return to toplevel.")
                              (format stream "Return to break level ~D." break-level)))
               #| ; Handled by interactive-abort
                ; go up one more if abort occurred while awaiting/reading input               
                (when (and *in-read-loop* (neq break-level 0))
                  (abort))
                |#
               )
        (abort-break () 
                     (unless (eq break-level 0)
                       (abort))))
      (clear-input *terminal-io*)
      (format *terminal-io* "~%"))))



;Read a form from *terminal-io*.
(defun toplevel-read (&key (input-stream *standard-input*)
			   (output-stream *standard-output*)
			   (prompt-function #'print-listener-prompt)
                           (eof-value *eof-value*))
  (force-output output-stream)
  (funcall prompt-function output-stream)
  (read-toplevel-form input-stream eof-value))

(defvar *always-eval-user-defvars* nil)

(defun process-single-selection (form)
  (if (and *always-eval-user-defvars*
           (listp form) (eq (car form) 'defvar) (cddr form))
    `(defparameter ,@(cdr form))
    form))

(defun toplevel-eval (form &optional *loading-file-source-file*)
  (setq +++ ++ ++ + + - - form)
  (let* ((package *package*)
         (values (multiple-value-list (cheap-eval-in-environment form nil))))
    (unless (eq package *package*)
      (application-ui-operation *application* :note-current-package *package*))
    values))

(defun toplevel-print (values)
  (setq /// // // / / values)
  (setq *** ** ** * * (if (neq (%car values) (%unbound-marker-8)) (%car values)))
  (when values
    (fresh-line)
    (dolist (val values) (write val) (terpri))))

(defun print-listener-prompt (stream &optional (force t))
  (when (or force (neq *break-level* *last-break-level*))
    (let* ((*listener-indent* nil))
      (fresh-line stream)            
      (if (%izerop *break-level*)
        (%write-string "?" stream)
        (format stream "~s >" *break-level*)))        
    (write-string " " stream)        
    (setq *last-break-level* *break-level*))
      (force-output stream))


;;; Fairly crude default error-handlingbehavior, and a fairly crude mechanism
;;; for customizing it.

(defvar *app-error-handler-mode* :quit
  "one of :quit, :quit-quietly, :listener might be useful.")

(defmethod application-error ((a application) condition error-pointer)
  (case *app-error-handler-mode*
    (:listener   (break-loop-handle-error condition error-pointer))
    (:quit-quietly (quit -1))
    (:quit  (format t "~&Fatal error in ~s : ~a"
                    (pathname-name (car *command-line-argument-list*))
                    condition)
                    (quit -1))))

(defun make-application-error-handler (app mode)
  (declare (ignore app))
  (setq *app-error-handler-mode* mode))


; You may want to do this anyway even if your application
; does not otherwise wish to be a "lisp-development-system"
(defmethod application-error ((a lisp-development-system) condition error-pointer)
  (break-loop-handle-error condition error-pointer))

(defun break-loop-handle-error (condition error-pointer)
  (multiple-value-bind (bogus-globals newvals oldvals) (%check-error-globals)
    (dolist (x bogus-globals)
      (set x (funcall (pop newvals))))
    (when (and *debugger-hook* *break-on-errors*)
      (let ((hook *debugger-hook*)
            (*debugger-hook* nil))
        (funcall hook condition hook)))
    (%break-message (error-header "Error") condition error-pointer)
    (with-terminal-input
      (let* ((s *error-output*))
	(dolist (bogusness bogus-globals)
	  (let ((oldval (pop oldvals)))
	    (format s "~&;  NOTE: ~S was " bogusness)
	    (if (eq oldval (%unbound-marker-8))
	      (format s "unbound")
	      (format s "~s" oldval))
	    (format s ", was reset to ~s ." (symbol-value bogusness)))))
      (if *break-on-errors*
	(break-loop condition error-pointer)
	(abort)))))

(defun break (&optional string &rest args &aux (fp (%get-frame-ptr)))
  (flet ((do-break-loop ()
           (let ((c (make-condition 'simple-condition
                                    :format-control (or string "")
                                    :format-arguments args)))
             (cbreak-loop (error-header "Break") "Return from BREAK." c fp))))
    (cond ((%i> (interrupt-level) -1)
           (do-break-loop))
          (*break-loop-when-uninterruptable*
           (format *error-output* "Break while interrupt-level less than zero; binding to 0 during break-loop.")
           (let ((interrupt-level (interrupt-level)))
	     (unwind-protect
		  (progn
		    (setf (interrupt-level) 0)
		    (do-break-loop))
	       (setf (interrupt-level) interrupt-level))))
          (t (format *error-output* "Break while interrupt-level less than zero; ignored.")))))

(defun invoke-debugger (condition &aux (fp (%get-frame-ptr)))
  (let ((c (require-type condition 'condition)))
    (when *debugger-hook*
      (let ((hook *debugger-hook*)
            (*debugger-hook* nil))
        (funcall hook c hook)))
    (%break-message "Debug" c fp)
    (with-terminal-input
	(break-loop c fp))))

(defun %break-message (msg condition error-pointer &optional (prefixchar #\>))
  (let ((*print-circle* *error-print-circle*)
        ;(*print-prett*y nil)
        (*print-array* nil)
        (*print-escape* t)
        (*print-gensym* t)
        (*print-length* nil)  ; ?
        (*print-level* nil)   ; ?
        (*print-lines* nil)
        (*print-miser-width* nil)
        (*print-readably* nil)
        (*print-right-margin* nil)
        (*signal-printing-errors* nil)
        (s (make-indenting-string-output-stream prefixchar nil)))
    (format s "~A ~A: " prefixchar msg)
    (setf (indenting-string-output-stream-indent s) (column s))
    ;(format s "~A" condition) ; evil if circle
    (report-condition condition s)
    (if (not (and (typep condition 'simple-program-error)
                  (simple-program-error-context condition)))
      (format *error-output* "~&~A~%~A While executing: ~S~%"
              (get-output-stream-string s) prefixchar (%real-err-fn-name error-pointer))
      (format *error-output* "~&~A~%"
              (get-output-stream-string s)))
  (force-output *error-output*)))
					; returns NIL

(defun cbreak-loop (msg cont-string condition error-pointer)
  (let* ((*print-readably* nil))
    (%break-message msg condition error-pointer)
    (with-terminal-input
      (restart-case (break-loop condition error-pointer)
		    (continue () :report (lambda (stream) (write-string cont-string stream))))
      (fresh-line *error-output*)
      nil)))

(defun warn (condition-or-format-string &rest args)
  (when (typep condition-or-format-string 'condition)
    (unless (typep condition-or-format-string 'warning)
      (report-bad-arg condition-or-format-string 'warning))
    (when args
      (error 'type-error :datum args :expected-type 'null
	     :format-control "Extra arguments in ~s.")))
  (let ((fp (%get-frame-ptr))
        (c (require-type (condition-arg condition-or-format-string args 'simple-warning) 'warning)))
    (when *break-on-warnings*
      (cbreak-loop "Warning" "Signal the warning." c fp))
    (restart-case (signal c)
      (muffle-warning () :report "Skip the warning" (return-from warn nil)))
    (%break-message (if (typep c 'compiler-warning) "Compiler warning" "Warning") c fp #\;)
    ))

(declaim (notinline select-backtrace))

(defmacro new-backtrace-info (dialog youngest oldest tcr)
  `(vector ,dialog ,youngest ,oldest ,tcr nil (%catch-top ,tcr)))

(defun select-backtrace ()
  (declare (notinline select-backtrace))
  (require 'new-backtrace)
  (require :inspector)
  (select-backtrace))

(defvar *break-condition* nil "condition argument to innermost break-loop.")
(defvar *break-frame* nil "frame-pointer arg to break-loop")
(defvar *break-loop-when-uninterruptable* t)





(defvar %last-continue% nil)
(defun break-loop (condition frame-pointer)
  "Never returns"
  (when (and (%i< (interrupt-level) 0) (not *break-loop-when-uninterruptable*))
    (abort))
  (let* ((%handlers% (last %handlers%))		; firewall
         (*break-frame* frame-pointer)
         (*break-condition* condition)
         (*compiling-file* nil)
         (*backquote-stack* nil)
         (continue (find-restart 'continue))
         (*continuablep* (unless (eq %last-continue% continue) continue))
         (%last-continue% continue)
         (*standard-input* *debug-io*)
         (*standard-output* *debug-io*)
         (level (interrupt-level))
         (*signal-printing-errors* nil)
         (*read-suppress* nil)
         (*print-readably* nil))
    (unwind-protect
         (let* ((context (new-backtrace-info nil
                                      frame-pointer
                                      (if *backtrace-contexts*
                                        (or (child-frame
                                             (bt.youngest (car *backtrace-contexts*))
                                             (%current-tcr))
                                            (last-frame-ptr))
                                        (last-frame-ptr))
                                      (%current-tcr)))
                (*backtrace-contexts* (cons context *backtrace-contexts*)))
	 (with-toplevel-commands :break
           (if *continuablep*
             (let* ((*print-circle* *error-print-circle*)
					;(*print-pretty* nil)
                    (*print-array* nil))
               (format t "~&> Type :GO to continue, :POP to abort.")
               (format t "~&> If continued: ~A~%" continue))
             (format t "~&> Type :POP to abort.~%"))
           (format t "~&Type :? for other options.")
           (terpri)
           (force-output)

           (clear-input *debug-io*)
           (setq *error-reentry-count* 0) ; succesfully reported error
           (unwind-protect
                (progn
                  (application-ui-operation *application*
                                            :enter-backtrace-context context)
                  (read-loop :break-level (1+ *break-level*)))
             (application-ui-operation *application* :exit-backtrace-context
                                       context))))
      (setf (interrupt-level) level))))



(defun display-restarts (&optional (condition *break-condition*))
  (let ((i 0))
    (format t "~&[Pretend that these are buttons.]")
    (dolist (r (compute-restarts condition) i)
      (format t "~&~a : ~A" i r)
      (setq i (%i+ i 1)))
    (fresh-line nil)))

(defun select-restart (n &optional (condition *break-condition*))
  (let* ((restarts (compute-restarts condition)))
    (invoke-restart-interactively
     (nth (require-type n `(integer 0 (,(length restarts)))) restarts))))




; End of l1-readloop-lds.lisp
