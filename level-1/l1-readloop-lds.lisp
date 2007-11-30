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
              (read-loop :break-level 0 )) $xstkover)
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
    (%%yield-terminal-to (if p (find-process p))))	;may be nil


(define-toplevel-command
    :global kill (p) "Kill process whose name or ID matches <p>"
    (let* ((proc (find-process p)))
      (if proc
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

(define-toplevel-command :global cd (dir) "Change to directory DIR" (setf (current-directory) dir) (toplevel-print (list (current-directory))))

(define-toplevel-command :global pwd () "Print the pathame of the current directory" (toplevel-print (list (current-directory))))



(define-toplevel-command :break pop () "exit current break loop" (abort-break))
(define-toplevel-command :break go () "continue" (continue))
(define-toplevel-command :break q () "return to toplevel" (toplevel))
(define-toplevel-command :break r () "list restarts"
  (format t "~&   (:C <n>) can be used to invoke one of the following restarts in this break loop:")
  (let* ((r (apply #'vector (compute-restarts *break-condition*))))
    (dotimes (i (length r) (terpri))
      (format *debug-io* "~&~d. ~a" i (svref r i)))))

;;; From Marco Baringer 2003/03/18

(define-toplevel-command :break set (n frame value) "Set <n>th item of frame <frame> to <value>"
  (let* ((frame-sp (nth-raw-frame frame *break-frame* nil)))
    (if frame-sp
        (toplevel-print (list (set-nth-value-in-frame frame-sp n nil value)))
        (format *debug-io* "No frame with number ~D~%" frame))))

(define-toplevel-command :break nframes ()
                         "print the number of stack frames accessible from this break loop"
                         (do* ((p *break-frame* (parent-frame p nil))
                               (i 0 (1+ i))
                               (last (last-frame-ptr)))
                              ((eql p last) (toplevel-print (list i)))))

(define-toplevel-command :global ? () "help"
  (dolist (g *active-toplevel-commands*)
    (dolist (c (cdr g))
      (let* ((command (car c))
	     (doc (caddr c))
	     (args (cdddr c)))
	(if args
	  (format t "~& (~S~{ ~A~}) ~8T~A" command args doc)
	  (format t "~& ~S  ~8T~A" command doc))))))


(define-toplevel-command :break b (&key start count show-frame-contents) "backtrace"
  (when *break-frame*
      (print-call-history :detailed-p show-frame-contents
                          :origin *break-frame*
                          :count count
                          :start-frame-number (or start 0))))

(define-toplevel-command :break c (n) "Choose restart <n>"
   (select-restart n))

(define-toplevel-command :break f (n) "Show backtrace frame <n>"
   (print-call-history :origin *break-frame*
                       :start-frame-number n
                       :count 1
                       :detailed-p t))

(define-toplevel-command :break raw (n) "Show raw contents of backtrace frame <n>"
   (print-call-history :origin *break-frame*
                       :start-frame-number n
                       :count 1
                       :detailed-p :raw))

(define-toplevel-command :break v (n frame-number) "Return value <n> in frame <frame-number>"
  (let* ((frame-sp (nth-raw-frame frame-number *break-frame* nil)))
    (if frame-sp
      (toplevel-print (list (nth-value-in-frame frame-sp n nil))))))

(define-toplevel-command :break arg (name frame-number) "Return value of argument named <name> in frame <frame-number>"
  (let* ((frame-sp (nth-raw-frame frame-number *break-frame* nil)))
    (when frame-sp
      (multiple-value-bind (lfun pc) (cfp-lfun frame-sp)
        (when (and lfun pc)
          (let* ((unavailable (cons nil nil)))
            (declare (dynamic-extent unavailable))
            (let* ((value (arg-value nil frame-sp lfun pc unavailable name)))
              (if (eq value unavailable)
                (format *debug-io* "~&;; Can't determine value of ~s in frame ~s." name frame-number)
                (toplevel-print (list value))))))))))

(define-toplevel-command :break set-arg (name frame-number new) "Set value of argument named <name> in frame <frame-number> to value <new>."
  (let* ((frame-sp (nth-raw-frame frame-number *break-frame* nil)))
    (when frame-sp
      (multiple-value-bind (lfun pc) (cfp-lfun frame-sp)
        (when (and lfun pc)
          (or (set-arg-value nil frame-sp lfun pc name new)
              (format *debug-io* "~&;; Can't change value of ~s in frame ~s." name frame-number)))))))
   

(define-toplevel-command :break local (name frame-number) "Return value of local denoted by <name> in frame <frame-number> <name> can either be a symbol - in which case the most recent
binding of that symbol is used - or an integer index into the frame's set of local bindings."
  (let* ((frame-sp (nth-raw-frame frame-number *break-frame* nil)))
    (when frame-sp
      (multiple-value-bind (lfun pc) (cfp-lfun frame-sp)
        (when (and lfun pc)
          (let* ((unavailable (cons nil nil)))
            (declare (dynamic-extent unavailable))
            (let* ((value (local-value nil frame-sp lfun pc unavailable name)))
              (if (eq value unavailable)
                (format *debug-io* "~&;; Can't determine value of ~s in frame ~s." name frame-number)
                (toplevel-print (list value))))))))))

(define-toplevel-command :break set-local (name frame-number new) "Set value of argument denoted <name> (see :LOCAL) in frame <frame-number> to value <new>."
  (let* ((frame-sp (nth-raw-frame frame-number *break-frame* nil)))
    (when frame-sp
      (multiple-value-bind (lfun pc) (cfp-lfun frame-sp)
        (when (and lfun pc)
          (or (set-local-value nil frame-sp lfun pc name new)
              (format *debug-io* "~&;; Can't change value of ~s in frame ~s." name frame-number)))))))


(define-toplevel-command :break form (frame-number)
   "Return a form which looks like the call which established the stack frame identified by <frame-number>.  This is only well-defined in certain cases: when the function is globally named and not a lexical closure and when it was compiled with *SAVE-LOCAL-SYMBOLS* in effect."
   (let* ((form (dbg-form frame-number)))
     (when form
       (let* ((*print-level* *backtrace-print-level*)
              (*print-length* *backtrace-print-length*))
         (toplevel-print (list form))))))

;;; Ordinarily, form follows function.
(define-toplevel-command :break function (frame-number)
  "Returns the function invoked in backtrace frame <frame-number>.  This may be useful for, e.g., disassembly"
  (let* ((cfp (nth-raw-frame frame-number *break-frame* nil)))
    (when (and cfp (not (catch-csp-p cfp nil)))
      (let* ((function (cfp-lfun cfp)))
        (when function
          (toplevel-print (list function)))))))
  


          

  

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

(defparameter *quit-on-eof* nil)

;;; This is the part common to toplevel loop and inner break loops.
(defun read-loop (&key (input-stream *standard-input*)
                       (output-stream *standard-output*)
                       (break-level *break-level*)
		       (prompt-function #'(lambda (stream) (print-listener-prompt stream t))))
  (let* ((*break-level* break-level)
         (*last-break-level* break-level)
         *loading-file-source-file*
         *in-read-loop*
         *** ** * +++ ++ + /// // / -
         (eof-value (cons nil nil)))
    (declare (dynamic-extent eof-value))
    (loop
      (restart-case
       (catch :abort                    ;last resort...
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
                  (if (and (not *batch-flag*)
                           (not *quit-on-eof*)
                           (eof-transient-p (stream-device input-stream :input)))
                    (progn
                      (stream-clear-input input-stream)
                      (abort-break))
                    (exit-interactive-process *current-process*))
                    (or (check-toplevel-command form)
                        (let* ((values (toplevel-eval form path)))
                          (if print-result (toplevel-print values))))))))
           (format *terminal-io* "~&Cancelled")))
       (abort () :report (lambda (stream)
                           (if (eq break-level 0)
                             (format stream "Return to toplevel.")
                             (format stream "Return to break level ~D." break-level)))
              #|                        ; Handled by interactive-abort
                                        ; go up one more if abort occurred while awaiting/reading input               
              (when (and *in-read-loop* (neq break-level 0))
              (abort))
              |#
               )
        (abort-break () 
                     (unless (eq break-level 0)
                       (abort))))
       (clear-input input-stream)
      (format output-stream "~%"))))

;;; The first non-whitespace character available on INPUT-STREAM is a colon.
;;; Try to interpret the line as a colon command (or possibly just a keyword.)
(defun read-command-or-keyword (input-stream eof-value)
  (let* ((line (read-line input-stream nil eof-value)))
    (if (eq line eof-value)
      eof-value
      (let* ((in (make-string-input-stream line))
             (keyword (read in nil eof-value)))
        (if (eq keyword eof-value)
          eof-value
          (if (not (keywordp keyword))
            keyword
            (collect ((params))
              (loop
                (let* ((param (read in nil eof-value)))
                  (if (eq param eof-value)
                    (return
                      (let* ((params (params)))
                        (if params
                          (cons keyword params)
                          keyword)))
                    (params (eval param))))))))))))

;;; Read a form from the specified stream.
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

(defun toplevel-print (values &optional (out *standard-output*))
  (setq /// // // / / values)
  (unless (eq (car values) (%unbound-marker))
    (setq *** ** ** * *  (%car values)))
  (when values
    (fresh-line out)
    (dolist (val values) (write val :stream out) (terpri out))))

(defun print-listener-prompt (stream &optional (force t))
  (unless *quiet-flag*
    (when (or force (neq *break-level* *last-break-level*))
      (let* ((*listener-indent* nil))
        (fresh-line stream)            
        (if (%izerop *break-level*)
          (%write-string "?" stream)
          (format stream "~s >" *break-level*)))        
      (write-string " " stream)        
      (setq *last-break-level* *break-level*)))
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

(defun abnormal-application-exit ()
  (print-call-history)
  (quit -1))

(defun break-loop-handle-error (condition error-pointer)
  (multiple-value-bind (bogus-globals newvals oldvals) (%check-error-globals)
    (dolist (x bogus-globals)
      (set x (funcall (pop newvals))))
    (when (and *debugger-hook* *break-on-errors* (not *batch-flag*))
      (let ((hook *debugger-hook*)
            (*debugger-hook* nil))
        (funcall hook condition hook)))
    (%break-message "Error" condition error-pointer)
    (let* ((s *error-output*))
      (dolist (bogusness bogus-globals)
        (let ((oldval (pop oldvals)))
          (format s "~&;  NOTE: ~S was " bogusness)
          (if (eq oldval (%unbound-marker-8))
            (format s "unbound")
            (format s "~s" oldval))
          (format s ", was reset to ~s ." (symbol-value bogusness)))))
    (if (and *break-on-errors* (not *batch-flag*))
      (with-terminal-input
          (break-loop condition error-pointer))
      (if *batch-flag*
        (abnormal-application-exit)
        (abort)))))

(defun break (&optional string &rest args)
  "Print a message and invoke the debugger without allowing any possibility
   of condition handling occurring."
  (if *batch-flag*
    (apply #'error string args)
    (apply #'%break-in-frame (%get-frame-ptr) string args)))

(defun %break-in-frame (fp &optional string &rest args)
  (flet ((do-break-loop ()
           (let ((c (if (typep string 'condition)
                      string
                      (make-condition 'simple-condition
                                    :format-control (or string "")
                                    :format-arguments args))))
             (cbreak-loop "Break" "Return from BREAK." c fp))))
    (cond ((%i> *interrupt-level* -1)
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
  "Enter the debugger."
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
        (*print-length* *backtrace-print-length*)  ; ?
        (*print-level* *backtrace-print-level*)   ; ?
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
      (format *error-output* "~&~A~%~A While executing: ~S"
              (get-output-stream-string s) prefixchar (%real-err-fn-name error-pointer))
      (format *error-output* "~&~A"
              (get-output-stream-string s)))
    (format *error-output* ", in process ~a(~d).~%" (process-name *current-process*) (process-serial-number *current-process*))
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
  "Warn about a situation by signalling a condition formed by DATUM and
   ARGUMENTS. While the condition is being signaled, a MUFFLE-WARNING restart
   exists that causes WARN to immediately return NIL."
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

(defmacro new-backtrace-info (dialog youngest oldest tcr condition current fake db-link level)
  (let* ((cond (gensym)))
  `(let* ((,cond ,condition))
    (vector ,dialog ,youngest ,oldest ,tcr (cons nil (compute-restarts ,cond)) (%catch-top ,tcr) ,cond ,current ,fake ,db-link ,level))))

(defun select-backtrace ()
  (declare (notinline select-backtrace))
  ;(require 'new-backtrace)
  (require :inspector)
  (select-backtrace))

(defvar *break-condition* nil "condition argument to innermost break-loop.")
(defvar *break-frame* nil "frame-pointer arg to break-loop")
(defvar *break-loop-when-uninterruptable* t)

(defvar *error-reentry-count* 0)

(defun funcall-with-error-reentry-detection (thunk)
  (let* ((count *error-reentry-count*)
         (*error-reentry-count* (1+ count)))
    (cond ((eql count 0) (funcall thunk))
          ((eql count 1) (error "Error reporting error"))
          (t (bug "Error reporting error")))))




(defvar %last-continue% nil)
(defun break-loop (condition frame-pointer)
  "Never returns"
  (let* ((%handlers% (last %handlers%)) ; firewall
         (*break-frame* frame-pointer)
         (*break-condition* condition)
         (*compiling-file* nil)
         (*backquote-stack* nil)
         (continue (find-restart 'continue))
         (*continuablep* (unless (eq %last-continue% continue) continue))
         (%last-continue% continue)
         (*standard-input* *debug-io*)
         (*standard-output* *debug-io*)
         (*signal-printing-errors* nil)
         (*read-suppress* nil)
         (*print-readably* nil))
    (let* ((context (new-backtrace-info nil
                                        frame-pointer
                                        (if *backtrace-contexts*
                                          (or (child-frame
                                               (bt.youngest (car *backtrace-contexts*))
                                               nil)
                                              (last-frame-ptr))
                                          (last-frame-ptr))
                                        (%current-tcr)
                                        condition
                                        (%current-frame-ptr)
                                        #+ppc-target *fake-stack-frames*
                                        #+x86-target (%current-frame-ptr)
                                        (db-link)
                                        (1+ *break-level*)))
           (*backtrace-contexts* (cons context *backtrace-contexts*)))
      (with-toplevel-commands :break
        (if *continuablep*
          (let* ((*print-circle* *error-print-circle*)
                 (*print-level* *backtrace-print-level*)
                 (*print-length* *backtrace-print-length*)
					;(*print-pretty* nil)
                 (*print-array* nil))
            (format t "~&> Type :GO to continue, :POP to abort, :R for a list of available restarts.")
            (format t "~&> If continued: ~A~%" continue))
          (format t "~&> Type :POP to abort, :R for a list of available restarts.~%"))
        (format t "~&> Type :? for other options.")
        (terpri)
        (force-output)

        (clear-input *debug-io*)
        (setq *error-reentry-count* 0)  ; succesfully reported error
        (ignoring-without-interrupts
         (unwind-protect
              (progn
                (application-ui-operation *application*
                                          :enter-backtrace-context context)
                  (read-loop :break-level (1+ *break-level*)
                             :input-stream *debug-io*
                             :output-stream *debug-io*))
           (application-ui-operation *application* :exit-backtrace-context
                                     context)))))))



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
