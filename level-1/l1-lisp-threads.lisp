;;; -*- Mode: LISP; Package: CCL -*-
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

;; l1-lisp-threads.lisp

(in-package "CCL")

(defvar *bind-io-control-vars-per-process* nil
  "If true, bind I/O control variables per process")

(eval-when (:compile-toplevel :execute)
  (macrolet ((thread-accessor (name)
	       `(defmacro ,(intern
			    (concatenate 'string "LISP-THREAD." (string name)))
		 (thread)
		 `(%svref ,thread ,,(intern
				     (concatenate
				      'string
				      "LISP-THREAD."
				      (string name)
				      "-CELL")
				     "TARGET")))))
    (progn
      (thread-accessor tcr)
      (thread-accessor name)
      (thread-accessor cs-size)
      (thread-accessor vs-size)
      (thread-accessor ts-size)
      (thread-accessor initial-function.args)
      (thread-accessor interrupt-functions)
      (thread-accessor interrupt-lock)
      (thread-accessor startup-function)
      (thread-accessor state)
      (thread-accessor state-change-lock))))
	     
(defun lisp-thread-p (thing)
  (eq (typecode thing) target::subtag-lisp-thread))

(setf (type-predicate 'lisp-thread) 'lisp-thread-p)

(defloadvar *ticks-per-second*
    (#_sysconf #$_SC_CLK_TCK))

(defloadvar *ns-per-tick*
    (floor 1000000000 *ticks-per-second*))

(defun %nanosleep (seconds nanoseconds)
  (rlet ((a :timespec)
         (b :timespec))
    (setf (pref a :timespec.tv_sec) seconds
          (pref a :timespec.tv_nsec) nanoseconds)
    (let* ((aptr a)
           (bptr b))
      (loop
        (let* ((result 
                (external-call #+darwinppc-target "_nanosleep"
                               #-darwinppc-target "nanosleep"
                               :address aptr
                               :address bptr
                               :signed-fullword)))
          (if (and (< result 0)
                   (eql (%get-errno) (- #$EINTR))
                   (not (or (eql (pref bptr :timespec.tv_sec) 0)
                            (eql (pref bptr :timespec.tv_nsec) 0))))
		(psetq aptr bptr bptr aptr)
		(return)))))))


(defun timeval->ticks (tv)
  (+ (* *ticks-per-second* (pref tv :timeval.tv_sec))
     (round (pref tv :timeval.tv_usec) (floor 1000000 *ticks-per-second*))))

(defloadvar *lisp-start-timeval*
    (progn
      (let* ((r (make-record :timeval)))
        (#_gettimeofday r (%null-ptr))
        r)))

(defun get-tick-count ()
  (rlet ((now :timeval)
         (since :timeval))
    (#_gettimeofday now (%null-ptr))
    (%sub-timevals since now *lisp-start-timeval*)
    (timeval->ticks since)))
  

; Allocate a tstack area with at least useable-bytes
; Returns a fixnum encoding the address of an area structure.
(defun allocate-tstack (useable-bytes)
  (with-macptrs ((tstack (ff-call (%kernel-import target::kernel-import-allocate_tstack)
                                      :unsigned-fullword (logand (+ useable-bytes 4095) -4096)
                                      :address)))
    (when (%null-ptr-p tstack)
      (error "Can't allocate tstack"))
    (%fixnum-from-macptr tstack)))



; Allocate a vstack area with at least useable-bytes
; Returns a fixnum encoding the address of an area structure.
(defun allocate-vstack (useable-bytes)
  (with-macptrs ((vstack (ff-call (%kernel-import target::kernel-import-allocate_vstack)
                                      :unsigned-fullword (logand (+ useable-bytes 4095) -4096)
                                      :address)))
    (when (%null-ptr-p vstack)
      (error "Can't allocate vstack"))
    (%fixnum-from-macptr vstack)))



; Create a new, empty control stack area
; Returns a fixnum encoding the address of an area structure.
(defun new-cstack-area ()
  (with-macptrs ((cstack (ff-call (%kernel-import target::kernel-import-register_cstack)
                                      :unsigned-fullword 0   ; address
                                      :unsigned-fullword 0   ; size
                                      :address)))
    (when (%null-ptr-p cstack)
      (error "Can't allocate cstack"))
    (%fixnum-from-macptr cstack)))


; Free the result of allocate-tstack, allocate-vstack, or register-cstack
(defun free-stack-area (stack-area)
  (with-macptrs ((area-ptr (%null-ptr)))
    (%setf-macptr-to-object area-ptr stack-area)
    (ff-call (%kernel-import target::kernel-import-condemn-area)
                 :address area-ptr
                 :void))
  nil)



(defun %kernel-global-offset (name-or-offset)
  (if (fixnump name-or-offset)
    name-or-offset
    (target::%kernel-global name-or-offset)))

(defun %kernel-global-offset-form (name-or-offset-form)
  (cond ((and (listp name-or-offset-form)
              (eq 'quote (car name-or-offset-form))
              (listp (cdr name-or-offset-form))
              (symbolp (cadr name-or-offset-form))
              (null (cddr name-or-offset-form)))
         (target-arch-case
          (:ppc32 (ppc32::%kernel-global (cadr name-or-offset-form)))
          (:ppc64 (ppc64::%kernel-global (cadr name-or-offset-form)))))
        ((fixnump name-or-offset-form)
         name-or-offset-form)
        (t `(%kernel-global-offset ,name-or-offset-form))))

; This behaves like a function, but looks up the kernel global
; at compile time if possible. Probably should be done as a function
; and a compiler macro, but we can't define compiler macros yet,
; and I don't want to add it to "ccl:compiler;optimizers.lisp"
(defmacro %get-kernel-global (name-or-offset)
  (target-arch-case
   (:ppc32
    `(%fixnum-ref 0 (+ ppc32::nil-value  ,(%kernel-global-offset-form name-or-offset))))
   (:ppc64
    `(%fixnum-ref 0 (+ ppc64::nil-value  ,(%kernel-global-offset-form name-or-offset))))))

(defmacro %get-kernel-global-ptr (name-or-offset dest)
  (target-arch-case
   (:ppc32
    `(%setf-macptr ,dest
      (%fixnum-ref-natural 0 (+ ppc32::nil-value  ,(%kernel-global-offset-form name-or-offset)))))
   (:ppc64
    `(%setf-macptr ,dest
      (%fixnum-ref-natural 0 (+ ppc64::nil-value  ,(%kernel-global-offset-form name-or-offset)))))))

(defmacro %set-kernel-global (name-or-offset new-value)
  `(%set-kernel-global-from-offset
    ,(%kernel-global-offset-form name-or-offset)
    ,new-value))



; The number of bytes in a consing (or stack) area
(defun %area-size (area)
  (ash (- (%fixnum-ref area target::area.high)
          (%fixnum-ref area target::area.low))
       target::fixnumshift))

(defun %stack-area-usable-size (area)
  (ash (- (%fixnum-ref area target::area.high)
	  (%fixnum-ref area target::area.softlimit))
       target::fixnum-shift))

(defun %cons-lisp-thread (name &optional tcr)
  (%gvector target::subtag-lisp-thread
	    tcr
	    name
	    0
	    0
	    0
	    nil
	    nil
            (make-lock)
	    nil
	    :reset
	    (make-lock)
	    nil))

(defvar *current-lisp-thread*
  (%cons-lisp-thread "Initial" (%current-tcr)))

(defvar *initial-lisp-thread* *current-lisp-thread*)

(defun thread-change-state (thread oldstate newstate)
  (with-lock-grabbed ((lisp-thread.state-change-lock thread))
    (when (eq (lisp-thread.state thread) oldstate)
      (setf (lisp-thread.state thread) newstate))))

(thread-change-state *initial-lisp-thread* :reset :run)

(defun thread-state (thread)
  (with-lock-grabbed ((lisp-thread.state-change-lock thread))
    (lisp-thread.state thread)))
  
(defun thread-make-startup-function (thread tcr)
  #'(lambda ()
      (thread-change-state thread :reset :run)
      (let* ((*current-lisp-thread* thread)
	     (initial-function (lisp-thread.initial-function.args thread)))
	(tcr-clear-preset-state tcr)
	(%set-tcr-toplevel-function tcr nil)
	(setf (interrupt-level) 0)
	(apply (car initial-function) (cdr initial-function))
	(cleanup-thread-tcr thread tcr))))

(defun init-thread-from-tcr (tcr thread)
  (let* ((cs-area (%fixnum-ref tcr target::tcr.cs-area))
         (vs-area (%fixnum-ref tcr target::tcr.vs-area))
         (ts-area (%fixnum-ref tcr target::tcr.ts-area)))
    (when (or (zerop cs-area)
              (zerop vs-area)
              (zerop ts-area))
      (error "Can't allocate new thread"))
    (setf (lisp-thread.tcr thread) tcr
          (lisp-thread.cs-size thread)
          (%stack-area-usable-size cs-area)
          (lisp-thread.vs-size thread)
          (%stack-area-usable-size vs-area)
          (lisp-thread.ts-size thread)
          (%stack-area-usable-size ts-area)
          (lisp-thread.startup-function thread)
          (thread-make-startup-function thread tcr)))
  thread)

(defun new-lisp-thread-from-tcr (tcr name)
  (let* ((thread (%cons-lisp-thread name tcr)))    
    (init-thread-from-tcr tcr thread)
    (push thread (population-data *lisp-thread-population*))
    thread))

(def-ccl-pointers initial-thread ()
  (init-thread-from-tcr (%current-tcr) *initial-lisp-thread*))

(defmethod print-object ((thread lisp-thread) stream)
  (print-unreadable-object (thread stream :type t :identity t)
    (format stream "~a" (lisp-thread.name thread))
    (let* ((tcr (lisp-thread.tcr thread)))
      (if (and tcr (not (eql 0 tcr)))
	(format stream " [tcr @ #x~x]" (ash tcr target::fixnumshift))))))


(defvar *lisp-thread-population*
  (%cons-population (list *initial-lisp-thread*) $population_weak-list nil))





(defparameter *default-control-stack-size* (ash 1 20))
(defparameter *default-value-stack-size* (ash 1 20))
(defparameter *default-temp-stack-size* (ash 1 19))


(defmacro with-area-macptr ((var area) &body body)
  `(with-macptrs (,var)
     (%setf-macptr-to-object ,var ,area)
     ,@body))


(defun gc-area.return-sp (area)
  (%fixnum-ref area target::area.gc-count))


(defun (setf gc-area.return-sp) (return-sp area)
  (setf (%fixnum-ref area target::area.gc-count) return-sp))



(defun shutdown-lisp-threads ()
  )

(defun %current-xp ()
  (let ((xframe (%fixnum-ref (%current-tcr) target::tcr.xframe)))
    (when (eql xframe 0)
      (error "No current exception frame"))
    (%fixnum-ref xframe
                 (get-field-offset :xframe-list.this))))

(defun new-tcr (cs-size vs-size ts-size)
  (let* ((tcr (macptr->fixnum
               (ff-call
                (%kernel-import target::kernel-import-newthread)
                :unsigned-fullword cs-size
                :unsigned-fullword vs-size
                :unsigned-fullword ts-size
                :address))))
    (declare (fixum tcr))
    (if (zerop tcr)
      (error "Can't create thread")
      tcr)))

(defun new-thread (name cstack-size vstack-size tstack-size)
  (new-lisp-thread-from-tcr (new-tcr cstack-size vstack-size tstack-size) name))

(defun new-tcr-for-thread (thread)
  (let* ((tcr (new-tcr
	       (lisp-thread.cs-size thread)
	       (lisp-thread.vs-size thread)
	       (lisp-thread.ts-size thread))))
    (setf (lisp-thread.tcr thread) tcr
	  (lisp-thread.startup-function thread)
	  (thread-make-startup-function thread tcr))
    tcr))
  
	 
(defmacro with-self-bound-io-control-vars (&body body)
  `(let (; from CLtL2, table 22-7:
         (*package* *package*)
         (*print-array* *print-array*)
         (*print-base* *print-base*)
         (*print-case* *print-case*)
         (*print-circle* *print-circle*)
         (*print-escape* *print-escape*)
         (*print-gensym* *print-gensym*)
         (*print-length* *print-length*)
         (*print-level* *print-level*)
         (*print-lines* *print-lines*)
         (*print-miser-width* *print-miser-width*)
         (*print-pprint-dispatch* *print-pprint-dispatch*)
         (*print-pretty* *print-pretty*)
         (*print-radix* *print-radix*)
         (*print-readably* *print-readably*)
         (*print-right-margin* *print-right-margin*)
         (*read-base* *read-base*)
         (*read-default-float-format* *read-default-float-format*)
         (*read-eval* *read-eval*)
         (*read-suppress* *read-suppress*)
         (*readtable* *readtable*))
     ,@body))


(defconstant cstack-hardprot (ash 100 10))
(defconstant cstack-softprot (ash 100 10))



(defun tcr-flags (tcr)
  (%fixnum-ref tcr target::tcr.flags))

(defun tcr-exhausted-p (tcr)
  (or (null tcr)
      (eql tcr 0)
      (unless (logbitp arch::tcr-flag-bit-awaiting-preset
		       (the fixnum (tcr-flags tcr)))
	(let* ((vs-area (%fixnum-ref tcr target::tcr.vs-area)))
	  (declare (fixnum vs-area))
	  (or (zerop vs-area)
	      (eq (%fixnum-ref vs-area target::area.high)
		  (%fixnum-ref tcr target::tcr.save-vsp)))))))

(defun thread-exhausted-p (thread)
  (or (null thread)
      (tcr-exhausted-p (lisp-thread.tcr thread))))

(defun thread-total-run-time (thread)
  (unless (thread-exhausted-p thread)
    nil))


(defun thread-interrupt (thread process function &rest args)
  (with-lock-grabbed ((lisp-thread.state-change-lock thread))
    (case (lisp-thread.state thread)
      (:run 
       (with-lock-grabbed ((lisp-thread.interrupt-lock thread))
	 (let* ((pthread (lisp-thread-os-thread thread)))
	   (when pthread
	     (push (cons function args)
		   (lisp-thread.interrupt-functions thread))
	     (eql 0 (#_pthread_kill pthread (%get-kernel-global 'ppc::interrupt-signal)))))))
      (:reset
       ;; Preset the thread with a function that'll return to the :reset
       ;; state
       (let* ((pif (process-initial-form process))
	      (pif-f (car pif))
	      (pif-args (cdr pif)))
	 (process-preset process #'(lambda ()
				     (%rplaca pif pif-f)
				     (%rplacd pif pif-args)
				     (apply function args)
				     ;; If function returns normally,
				     ;; return to the reset state
				     (%process-reset nil)))
	 (thread-enable thread 0)
         t)))))

(defun thread-handle-interrupts ()
  (let* ((thread *current-lisp-thread*))
    (with-process-whostate ("Active")
      (loop
        (let* ((f (with-lock-grabbed ((lisp-thread.interrupt-lock thread))
                    (pop (lisp-thread.interrupt-functions thread)))))
          (if f
            (apply (car f) (cdr f))
            (return)))))))


	
(defun thread-preset (thread function &rest args)
  (setf (lisp-thread.initial-function.args thread)
	(cons function args)))

(defun thread-enable (thread &optional (timeout most-positive-fixnum))
  (let* ((tcr (or (lisp-thread.tcr thread) (new-tcr-for-thread thread))))
    (multiple-value-bind (seconds nanos) (nanoseconds timeout)
      (with-macptrs (s)
	(%setf-macptr-to-object s (%fixnum-ref tcr target::tcr.reset-completion))
	(when (%wait-on-semaphore-ptr s seconds nanos)
	  (%set-tcr-toplevel-function
	   tcr
	   (lisp-thread.startup-function thread))
	  (%activate-tcr tcr)
	  thread)))))
			      

(defun cleanup-thread-tcr (thread tcr)
  (let* ((flags (%fixnum-ref tcr target::tcr.flags)))
    (declare (fixnum flags))
    (if (logbitp arch::tcr-flag-bit-awaiting-preset flags)
      (thread-change-state thread :run :reset)
      (progn
	(thread-change-state thread :run :exit)
	(setf (lisp-thread.tcr thread) nil)))))

(defun kill-lisp-thread (thread)
  (let* ((pthread (lisp-thread-os-thread thread)))
    (when pthread
      (setf (lisp-thread.tcr thread) nil
	    (lisp-thread.state thread) :exit)
      (#_pthread_cancel pthread))))

;;; This returns the underlying pthread, whatever that is.
(defun lisp-thread-os-thread (thread)
  (with-macptrs (tcrp)
    (%setf-macptr-to-object tcrp (lisp-thread.tcr thread))
    (unless (%null-ptr-p tcrp)
      #+linuxppc-target
      (let* ((pthread (#+ppc32-target %get-unsigned-long
                       #+ppc64-target %%get-unsigned-longlong
                                      tcrp target::tcr.osid)))
	(unless (zerop pthread) pthread))
      #-linuxppc-target
      (let* ((pthread (%get-ptr tcrp target::tcr.osid)))
	(unless (%null-ptr-p pthread) pthread)))))
                         
;;; This returns something lower-level than the pthread, if that
;;; concept makes sense.  On current versions of Linux, it returns
;;; the pid of the clone()d process; on Darwin, it returns a Mach
;;; thread.  On some (near)future version of Linux, the concept
;;; may not apply.
;;; The future is here: on Linux systems using NPTL, this returns
;;; exactly the same thing that (getpid) does.
;;; This should probably be retired; even if it does something
;;; interesting, is the value it returns useful ?

(defun lisp-thread-native-thread (thread)
  (with-macptrs (tcrp)
    (%setf-macptr-to-object tcrp (lisp-thread.tcr thread))
    (unless (%null-ptr-p tcrp)
      (#+ppc32-target %get-unsigned-long
       #+ppc64-target %%get-unsigned-longlong tcrp target::tcr.native-thread-id))))

(defun lisp-thread-suspend-count (thread)
  (with-macptrs (tcrp)
    (%setf-macptr-to-object tcrp (lisp-thread.tcr thread))
    (unless (%null-ptr-p tcrp)
      (#+ppc32-target %get-unsigned-long
       #+ppc64-target %%get-unsigned-longlong tcrp target::tcr.suspend-count))))

(defun tcr-clear-preset-state (tcr)
  (let* ((flags (%fixnum-ref tcr target::tcr.flags)))
    (declare (fixnum flags))
    (setf (%fixnum-ref tcr target::tcr.flags)
	  (bitclr arch::tcr-flag-bit-awaiting-preset flags))))

(defun tcr-set-preset-state (tcr)
  (let* ((flags (%fixnum-ref tcr target::tcr.flags)))
    (declare (fixnum flags))
    (setf (%fixnum-ref tcr target::tcr.flags)
	  (bitset arch::tcr-flag-bit-awaiting-preset flags))))  

(defun %activate-tcr (tcr)
  (if (and tcr (not (eql 0 tcr)))
    (with-macptrs (s)
      (%setf-macptr-to-object s (%fixnum-ref tcr target::tcr.activate))
      (unless (%null-ptr-p s)
	(%signal-semaphore-ptr s)
	t))))
                         
(defvar *canonical-error-value*
  '(*canonical-error-value*))


(defun symbol-value-in-tcr (sym tcr)
  (if (eq tcr (%current-tcr))
    (%sym-value sym)
    (unwind-protect
         (progn
           (%suspend-tcr tcr)
           (let* ((loc (%tcr-binding-location tcr sym)))
             (if loc
               (%fixnum-ref loc)
               (%sym-global-value sym))))
      (%resume-tcr tcr))))

(defun (setf symbol-value-in-tcr) (value sym tcr)
  (if (eq tcr (%current-tcr))
    (%set-sym-value sym value)
    (unwind-protect
         (progn
           (%suspend-tcr tcr)
           (let* ((loc (%tcr-binding-location tcr sym)))
             (if loc
               (setf (%fixnum-ref loc) value)
               (%set-sym-global-value sym value))))
      (%resume-tcr tcr))))

;;; Backtrace support
;;;

; Linked list of fake stack frames.
; %frame-backlink looks here
(def-standard-initial-binding *fake-stack-frames* nil)


  
(defmacro %cons-fake-stack-frame (&optional sp next-sp fn lr vsp link)
  `(%istruct 'fake-stack-frame ,sp ,next-sp ,fn ,lr ,vsp ,link))



(defun fake-stack-frame-p (x)
  (istruct-typep x 'fake-stack-frame))


(defmacro do-db-links ((db-link &optional var value) &body body)
  (let ((thunk (gensym))
        (var-var (or var (gensym)))
        (value-var (or value (gensym))))
    `(block nil
       (let ((,thunk #'(lambda (,db-link ,var-var ,value-var)
                         (declare (ignorable ,db-link))
                         ,@(unless var (list `(declare (ignore ,var-var))))
                         ,@(unless value (list `(declare (ignore ,value-var))))
                         ,@body)))
         (declare (dynamic-extent ,thunk))
         (map-db-links ,thunk)))))




(defun map-db-links (f)
  (without-interrupts
   (let ((db-link (%current-db-link)))
     (loop
       (when (eql 0 db-link) (return))
       (funcall f db-link (%fixnum-ref db-link (* 1 target::node-size)) (%fixnum-ref db-link (* 2 target::node-size)))
       (setq db-link (%fixnum-ref db-link))))))

(defun %get-frame-ptr ()
  (%current-frame-ptr))

(defun %stack< (index1 index2 &optional context)
  (cond ((fake-stack-frame-p index1)
         (let ((sp1 (%fake-stack-frame.sp index1)))
           (declare (fixnum sp1))
           (if (fake-stack-frame-p index2)
             (or (%stack< sp1 (%fake-stack-frame.sp index2) context)
                 (eq index2 (%fake-stack-frame.next-sp index1)))
             (%stack< sp1 (%i+ index2 1) context))))
        ((fake-stack-frame-p index2)
         (%stack< index1 (%fake-stack-frame.sp index2) context))
        (t (let* ((tcr (if context (bt.tcr context) (%current-tcr)))
                  (cs-area (%fixnum-ref tcr target::tcr.cs-area)))
             (and (%ptr-in-area-p index1 cs-area)
                  (%ptr-in-area-p index2 cs-area)
                  (< (the fixnum index1) (the fixnum index2)))))))


(defun %frame-savefn (p)
  (if (fake-stack-frame-p p)
    (%fake-stack-frame.fn p)
    (%%frame-savefn p)))

(defun %frame-savevsp (p)
  (if (fake-stack-frame-p p)
    (%fake-stack-frame.vsp p)
    (%%frame-savevsp p)))

(defun frame-vsp (frame)
  (%frame-savevsp frame))

(defun bottom-of-stack-p (p context)
  (and (fixnump p)
       (locally (declare (fixnum p))
	 (let* ((tcr (if context (bt.tcr context) (%current-tcr)))
                (cs-area (%fixnum-ref tcr target::tcr.cs-area)))
	   (not (%ptr-in-area-p p cs-area))))))

(defun next-catch (catch)
  (let ((next-catch (uvref catch target::catch-frame.link-cell)))
    (unless (eql next-catch 0) next-catch)))

(defun catch-frame-sp (catch)
  (uvref catch target::catch-frame.csp-cell))

(defun catch-csp-p (p context)
  (let ((catch (if context
                 (bt.top-catch context)
                 (%catch-top (%current-tcr)))))
    (loop
      (when (null catch) (return nil))
      (let ((sp (catch-frame-sp catch)))
        (when (eql sp p)
          (return t)))
      (setq catch (next-catch catch)))))

; @@@ this needs to load early so errors can work
(defun next-lisp-frame (p context)
  (let ((frame p))
    (loop
      (let ((parent (%frame-backlink frame context)))
        (multiple-value-bind (lisp-frame-p bos-p) (lisp-frame-p parent context)
          (if lisp-frame-p
            (return parent)
            (if bos-p
              (return nil))))
        (setq frame parent)))))

(defun parent-frame (p context)
  (loop
    (let ((parent (next-lisp-frame p context)))
      (when (or (null parent)
                (not (catch-csp-p parent context)))
        (return parent))
      (setq p parent))))


; @@@ this needs to load early so errors can work
(defun cfp-lfun (p)
  (if (fake-stack-frame-p p)
    (let ((fn (%fake-stack-frame.fn p))
          (lr (%fake-stack-frame.lr p)))
      (when (and (functionp fn) (fixnump lr))
        (values fn (%fake-stack-frame.lr p))))
    (%cfp-lfun p)))

(defun last-frame-ptr (&optional context)
  (let* ((current (if context (bt.current context) (%current-frame-ptr)))
         (last current))
    (loop
      (setq current (parent-frame current context))
      (if current
        (setq last current)
        (return last)))))



(defun child-frame (p context )
  (let* ((current (if context (bt.current context) (%current-frame-ptr)))
         (last nil))
    (loop
      (when (null current)
        (return nil))
      (when (eq current p) (return last))
      (setq last current
            current (parent-frame current context)))))



; Used for printing only.
(defun index->address (p)
  (when (fake-stack-frame-p p)
    (setq p (%fake-stack-frame.sp p)))
  (ldb (byte #+ppc32-target 32 #+ppc64-target 64 0)  (ash p target::fixnumshift)))

; This returns the current head of the db-link chain.
(defun db-link (&optional context)
  (if context
    (bt.db-link context)
    (%fixnum-ref (%current-tcr)  target::tcr.db-link)))

(defun previous-db-link (db-link start )
  (declare (fixnum db-link start))
  (let ((prev nil))
    (loop
      (when (or (eql db-link start) (eql 0 start))
        (return prev))
      (setq prev start
            start (%fixnum-ref start 0)))))

(defun count-db-links-in-frame (vsp parent-vsp &optional context)
  (declare (fixnum vsp parent-vsp))
  (let ((db (db-link context))
        (count 0)
        (first nil)
        (last nil))
    (declare (fixnum db count))
    (loop
      (cond ((eql db 0)
             (return (values count (or first 0) (or last 0))))
            ((and (>= db vsp) (< db parent-vsp))
             (unless first (setq first db))
             (setq last db)
             (incf count)))
      (setq db (%fixnum-ref db)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; bogus-thing-p support
;;;

(defun %ptr-in-area-p (ptr area)
  (declare (fixnum ptr area))           ; lie, maybe
  (and (<= (the fixnum (%fixnum-ref area target::area.low)) ptr)
       (> (the fixnum (%fixnum-ref area target::area.high)) ptr)))

(defun %active-area (area active)
  (or (do ((a area (%fixnum-ref a target::area.older)))
          ((eql a 0))
        (when (%ptr-in-area-p active a)
          (return a)))
      (do ((a (%fixnum-ref area target::area.younger) (%fixnum-ref a target::area.younger)))
          ((eql a 0))
        (when (%ptr-in-area-p active a)
          (return a)))))

(defun %ptr-to-vstack-p (tcr idx)
  (%ptr-in-area-p idx (%fixnum-ref tcr target::tcr.vs-area)))

(defun %on-tsp-stack (tcr object)
  (%ptr-in-area-p object (%fixnum-ref tcr target::tcr.ts-area)))

(defparameter *aux-tsp-ranges* ())
(defparameter *aux-vsp-ranges* ())
(defun object-in-range-p (object range)
  (declare (fixnum object))
  (when range
    (destructuring-bind (active . high) range
      (declare (fixnum active high))
      (and (< active object)
           (< object high)))))

(defun object-in-some-range (object ranges)
  (dolist (r ranges)
    (when (object-in-range-p object r)
      (return t))))


(defun on-any-tsp-stack (object)
  (or (%on-tsp-stack (%current-tcr) object)
      (object-in-some-range object *aux-tsp-ranges*)))

(defun on-any-vstack (idx)
  (or (%ptr-to-vstack-p (%current-tcr) idx)
      (object-in-some-range idx *aux-vsp-ranges*)))

; This MUST return either T or NIL.
(defun temporary-cons-p (x)
  (and (consp x)
       (not (null (or (on-any-vstack x)
                      (on-any-tsp-stack x))))))

(defmacro do-gc-areas ((area) &body body)
  (let ((initial-area (gensym)))
    `(let* ((,initial-area (%get-kernel-global 'all-areas))
            (,area ,initial-area))
       (declare (fixnum ,initial-area ,area))
       (loop
         (setq ,area (%fixnum-ref ,area ,(target-arch-case
                                          (:ppc32 ppc32::area.succ)
                                          (:ppc64 ppc64::area.succ))))
         (when (eql ,area ,initial-area)
           (return))
         ,@body))))

(defmacro do-consing-areas ((area) &body body)
  (let ((code (gensym)))
  `(do-gc-areas (,area)
     (let ((,code (%fixnum-ref ,area  ,(target-arch-case
                                        (:ppc32 ppc32::area.code)
                                        (:ppc64 ppc64::area.code)))))
       (when (or (eql ,code ppc::area-readonly)
                 (eql ,code ppc::area-staticlib)
                 (eql ,code ppc::area-static)
                 (eql ,code ppc::area-dynamic))
         ,@body)))))



(defun %value-cell-header-at-p (cur-vsp)
  (eql target::value-cell-header (%fixnum-address-of (%fixnum-ref cur-vsp))))

(defun count-stack-consed-value-cells-in-frame (vsp parent-vsp)
  (let ((cur-vsp vsp)
        (count 0))
    (declare (fixnum cur-vsp count))
    (loop
      (when (>= cur-vsp parent-vsp) (return))
      (when (and (evenp cur-vsp) (%value-cell-header-at-p cur-vsp))
        (incf count)
        (incf cur-vsp))                 ; don't need to check value after header
      (incf cur-vsp))
    count))

; stack consed value cells are one of two forms:
;
; nil             ; n-4
; header          ; n = even address (multiple of 8)
; value           ; n+4
;
; header          ; n = even address (multiple of 8)
; value           ; n+4
; nil             ; n+8

(defun in-stack-consed-value-cell-p (arg-vsp vsp parent-vsp)
  (declare (fixnum arg-vsp vsp parent-vsp))
  (if (evenp arg-vsp)
    (%value-cell-header-at-p arg-vsp)
    (or (and (> arg-vsp vsp)
             (%value-cell-header-at-p (the fixnum (1- arg-vsp))))
        (let ((next-vsp (1+ arg-vsp)))
          (declare (fixnum next-vsp))
          (and (< next-vsp parent-vsp)
               (%value-cell-header-at-p next-vsp))))))

; Return two values: the vsp of p and the vsp of p's "parent" frame.
; The "parent" frame vsp might actually be the end of p's segment,
; if the real "parent" frame vsp is in another segment.
(defun vsp-limits (p context)
  (let* ((vsp (%frame-savevsp p))
         parent)
    (when (eql vsp 0)
      ; This frame is where the code continues after an unwind-protect cleanup form
      (setq vsp (%frame-savevsp (child-frame p context))))
    (flet ((grand-parent (frame)
             (let ((parent (parent-frame frame context)))
               (when (and parent (eq parent (%frame-backlink frame context)))
                 (let ((grand-parent (parent-frame parent context)))
                   (when (and grand-parent (eq grand-parent (%frame-backlink parent context)))
                     grand-parent))))))
      (declare (dynamic-extent #'grand-parent))
      (let* ((frame p)
             grand-parent)
        (loop
          (setq grand-parent (grand-parent frame))
          (when (or (null grand-parent) (not (eql 0 (%frame-savevsp grand-parent))))
            (return))
          (setq frame grand-parent))
        (setq parent (parent-frame frame context)))
      (let* ((parent-vsp (if parent (%frame-savevsp parent) vsp))
             (tcr (if context (bt.tcr context) (%current-tcr)))
             (vsp-area (%fixnum-ref tcr target::tcr.vs-area)))
        (if (eql 0 parent-vsp)
          (values vsp vsp)              ; p is the kernel frame pushed by an unwind-protect cleanup form
          (progn
            (unless vsp-area
              (error "~s is not a stack frame pointer for context ~s" p tcr))
            (unless (%ptr-in-area-p parent-vsp vsp-area)
              (setq parent-vsp (%fixnum-ref vsp-area target::area.high)))
            (values vsp parent-vsp)))))))

(defun count-values-in-frame (p context &optional child)
  (declare (ignore child))
  (multiple-value-bind (vsp parent-vsp) (vsp-limits p context)
    (values
     (- parent-vsp 
        vsp
        (* 2 (count-db-links-in-frame vsp parent-vsp context))
        (* 3 (count-stack-consed-value-cells-in-frame vsp parent-vsp))))))

(defun nth-value-in-frame-loc (sp n context lfun pc child-frame vsp parent-vsp)
  (declare (ignore child-frame))        ; no ppc function info yet
  (declare (fixnum sp))
  (setq n (require-type n 'fixnum))
  (unless (or (null vsp) (fixnump vsp))
    (setq vsp (require-type vsp '(or null fixnum))))
  (unless (or (null parent-vsp) (fixnump parent-vsp))
    (setq parent-vsp (require-type parent-vsp '(or null fixnum))))
  (unless (and vsp parent-vsp)
    (multiple-value-setq (vsp parent-vsp) (vsp-limits sp context)))
  (locally (declare (fixnum n vsp parent-vsp))
    (multiple-value-bind (db-count first-db last-db)
                         (count-db-links-in-frame vsp parent-vsp context)
      (declare (ignore db-count))
      (declare (fixnum first-db last-db))
      (let ((arg-vsp (1- parent-vsp))
            (cnt n)
            (phys-cell 0)
            db-link-p)
        (declare (fixnum arg-vsp cnt phys-cell))
        (loop
          (if (eql (the fixnum (- arg-vsp 2)) last-db)
            (setq db-link-p t
                  arg-vsp last-db
                  last-db (previous-db-link last-db first-db)
                  phys-cell (+ phys-cell 2))
            (setq db-link-p nil))
          (unless (in-stack-consed-value-cell-p arg-vsp vsp parent-vsp)
            (when (< (decf cnt) 0)
              (return
               (if db-link-p
                 (values (+ 2 arg-vsp)
                         :saved-special
                         (binding-index-symbol (%fixnum-ref (1+ arg-vsp))))
                 (multiple-value-bind (type name) (find-local-name phys-cell lfun pc)
                   (values arg-vsp type name))))))
          (incf phys-cell)
          (when (< (decf arg-vsp) vsp)
            (error "n out of range")))))))



(defun nth-value-in-frame (sp n context &optional lfun pc child-frame vsp parent-vsp)
  (multiple-value-bind (loc type name)
                       (nth-value-in-frame-loc sp n context lfun pc child-frame vsp parent-vsp)
    (let* ((val (%fixnum-ref loc)))
      (when (and (eq type :saved-special)
		 (eq val (%no-thread-local-binding-marker))
		 name)
	(setq val (%sym-global-value name)))
      (values val  type name))))

(defun set-nth-value-in-frame (sp n context new-value &optional child-frame vsp parent-vsp)
  (multiple-value-bind (loc type name)
      (nth-value-in-frame-loc sp n context nil nil child-frame vsp parent-vsp)
    (let* ((old-value (%fixnum-ref loc)))
      (if (and (eq type :saved-special)
	       (eq old-value (%no-thread-local-binding-marker))
	       name)
	;; Setting the (shallow-bound) value of the outermost
	;; thread-local binding of NAME.  Hmm.
	(%set-sym-global-value name new-value)
	(setf (%fixnum-ref loc) new-value)))))

(defun nth-raw-frame (n start-frame context)
  (declare (fixnum n))
  (do* ((p start-frame (parent-frame p context))
	(i 0 (1+ i))
	(q (last-frame-ptr context)))
       ((or (null p) (eq p q) (%stack< q p context)))
    (declare (fixnum i))
    (if (= i n)
      (return p))))

; True if the object is in one of the heap areas
(defun %in-consing-area-p (x area)
  (declare (fixnum x))                  ; lie
  (let* ((low (%fixnum-ref area target::area.low))
         (high (%fixnum-ref area target::area.high))
)
    (declare (fixnum low high))
    (and (<= low x) (< x high))))



(defun in-any-consing-area-p (x)
  (do-consing-areas (area)
    (when (%in-consing-area-p x area)
      (return t))))

#+ppc32-target
(defun valid-subtag-p (subtag)
  (declare (fixnum subtag))
  (let* ((tagval (ldb (byte (- ppc32::num-subtag-bits ppc32::ntagbits) ppc32::ntagbits) subtag)))
    (declare (fixnum tagval))
    (case (logand subtag ppc32::fulltagmask)
      (#. ppc32::fulltag-immheader (not (eq (%svref *immheader-types* tagval) 'bogus)))
      (#. ppc32::fulltag-nodeheader (not (eq (%svref *nodeheader-types* tagval) 'bogus)))
      (t nil))))

#+ppc64-target
(defun valid-subtag-p (subtag)
  (declare (fixnum subtag))
  (let* ((tagval (ash subtag (- ppc64::nlowtagbits))))
    (declare (fixnum tagval))
    (case (logand subtag ppc64::lowtagmask)
      (#. ppc64::lowtag-immheader (not (eq (%svref *immheader-types* tagval) 'bogus)))
      (#. ppc64::lowtag-nodeheader (not (eq (%svref *nodeheader-types* tagval) 'bogus)))
      (t nil))))


#+ppc32-target
(defun valid-header-p (thing)
  (let* ((fulltag (fulltag thing)))
    (declare (fixnum fulltag))
    (case fulltag
      (#.ppc32::fulltag-misc (valid-subtag-p (typecode thing)))
      ((#.ppc32::fulltag-immheader #.ppc32::fulltag-nodeheader) nil)
      (t t))))

#+ppc64-target
(defun valid-header-p (thing)
  (let* ((fulltag (fulltag thing)))
    (declare (fixnum fulltag))
    (case fulltag
      (#.ppc64::fulltag-misc (valid-subtag-p (typecode thing)))
      ((#.ppc64::fulltag-immheader-0
        #.ppc64::fulltag-immheader-1
        #.ppc64::fulltag-immheader-2
        #.ppc64::fulltag-immheader-3
        #.ppc64::fulltag-nodeheader-0
        #.ppc64::fulltag-nodeheader-1
        #.ppc64::fulltag-nodeheader-2
        #.ppc64::fulltag-nodeheader-3) nil)
      (t t))))


#+ppc32-target
(defun bogus-thing-p (x)
  (when x
    (or (not (valid-header-p x))
        (let ((tag (lisptag x)))
          (unless (or (eql tag ppc32::tag-fixnum)
                      (eql tag ppc32::tag-imm)
                      (in-any-consing-area-p x))
            ;; This is terribly complicated, should probably write some LAP
            (let ((typecode (typecode x)))
                  (not (or (case typecode
                             (#.ppc32::tag-list
                              (temporary-cons-p x))
                             ((#.ppc32::subtag-symbol #.ppc32::subtag-code-vector)
                              t)              ; no stack-consed symbols or code vectors
                             (#.ppc32::subtag-value-cell
                              (on-any-vstack x))
                             (t
                              (on-any-tsp-stack x)))
                           (%heap-ivector-p x)))))))))

#+ppc64-target
(defun bogus-thing-p (x)
  (when x
    (or (not (valid-header-p x))
        (let ((tag (lisptag x)))
          (unless (or (eql tag ppc64::tag-fixnum)
                      (eql tag ppc64::tag-imm-0)
                      (eql tag ppc64::tag-imm-2)
                      (in-any-consing-area-p x))
            ;; This is terribly complicated, should probably write some LAP
            (let ((typecode (typecode x)))
                  (not (or (case typecode
                             (#.ppc64::fulltag-cons
                              (temporary-cons-p x))
                             ((#.ppc64::subtag-symbol #.ppc64::subtag-code-vector)
                              t)              ; no stack-consed symbols or code vectors
                             (#.ppc64::subtag-value-cell
                              (on-any-vstack x))
                             (t
                              (on-any-tsp-stack x)))
                           (%heap-ivector-p x)))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; terminate-when-unreachable
;;;

#|
Message-Id: <v02130502ad3e6a2f1542@[205.231.144.48]>
Mime-Version: 1.0
Content-Type: text/plain; charset="us-ascii"
Date: Wed, 7 Feb 1996 10:32:55 -0500
To: pmcldev@digitool.com
From: bitCraft@taconic.net (Bill St. Clair)
Subject: terminate-when-unreachable

I propose that we add a general termination mechanism to PPC MCL.
We need it to properly terminate stack groups, it would be
a nicer way to do the termination for macptrs than the current
ad-hoc mechanism (which BTW is not yet part of PPC MCL), and
it is a nice addition to MCL. I don't think it's hard to make
the garbage collector support this, and I volunteer to do the
work unless Gary really wants to.

I see two ways to support termination:

1) Do termination for hash tables. This was our plan for
   2.0, but Gary got confused about how to mark the objects at
   the right time (or so I remember).

2) Resurrect weak alists (they're not part of the PPC garbage
   collector) and add a termination bit to the population type.
   This allows for termination of weak lists and weak alists,
   though the termination mechanism really only needs termination
   for a single weak alist.

I prefer option 2, weak alists, since it avoids the overhead
necessary to grow and rehash a hash table. It also uses less space,
since a finalizeable hash table needs to allocate two cons cells
for each entry so that the finalization code has some place to
put the deleted entry.

I propose the following interface (slightly modified from what
Apple Dylan provides):

terminate-when-unreachable object &optional (function 'terminate)
  When OBJECT becomes unreachable, funcall FUNCTION with OBJECT
  as a single argument. Each call of terminate-when-unreachable
  on a single (EQ) object registers a new termination function.
  All will be called when the object becomes unreachable.

terminate object                                         [generic function]
  The default termination function

terminate (object t)                                     [method]
  The default method. Ignores object. Returns nil.

drain-termination-queue                                  [function]
  Drain the termination queue. I.e. call the termination function
  for every object that has become unreachable.

*enable-automatic-termination*                           [variable]
  If true, the default, drain-termination-queue will be automatically
  called on the first event check after the garbage collector runs.
  If you set this to false, you are responsible for calling
  drain-termination-queue.

cancel-terminate-when-unreachable object &optional function
  Removes the effect of the last call to terminate-when-unreachable
  for OBJECT & FUNCTION (both tested with EQ). Returns true if
  it found a match (which it won't if the object has been moved
  to the termination queue since terminate-when-unreachable was called).
  If FUNCTION is NIL or unspecified, then it will not be used; the
  last call to terminate-when-unreachable with the given OBJECT will
  be undone.

termination-function object
  Return the function passed to the last call of terminate-when-unreachable
  for OBJECT. Will be NIL if the object has been put in the
  termination queue since terminate-when-unreachable was called.

|#


(defvar *termination-population*
  (%cons-terminatable-alist))

(defvar *termination-population-lock* (make-lock))


(defvar *enable-automatic-termination* t)

(defun terminate-when-unreachable (object &optional (function 'terminate))
  "The termination mechanism is a way to have the garbage collector run a
function right before an object is about to become garbage. It is very
similar to the finalization mechanism which Java has. It is not standard
Common Lisp, although other Lisp implementations have similar features.
It is useful when there is some sort of special cleanup, deallocation,
or releasing of resources which needs to happen when a certain object is
no longer being used."
  (let ((new-cell (list (cons object function)))
        (population *termination-population*))
    (without-interrupts
     (with-lock-grabbed (*termination-population-lock*)
       (setf (cdr new-cell) (population-data population)
	     (population-data population) new-cell)))
    function))

(defmethod terminate ((object t))
  nil)

(defun drain-termination-queue ()
  (let ((cell nil)
        (population *termination-population*))
    (loop
    (without-interrupts
     (with-lock-grabbed (*termination-population-lock*)
       (without-gcing
        (let ((list (population-termination-list population)))
          (unless list (return))
          (setf cell (car list)
                (population-termination-list population) (cdr list))))))
      (funcall (cdr cell) (car cell)))))

(defun cancel-terminate-when-unreachable (object &optional (function nil function-p))
  (let ((found-it? nil))
    (flet ((test (object cell)
             (and (eq object (car cell))
                  (or (not function-p)
                      (eq function (cdr cell)))
                  (setq found-it? t))))
      (declare (dynamic-extent #'test))
      (without-interrupts
       (with-lock-grabbed (*termination-population-lock*)
	 (setf (population-data *termination-population*)
	       (delete object (population-data *termination-population*)
		       :test #'test
		       :count 1))))
      found-it?)))

(defun termination-function (object)
  (without-interrupts
   (with-lock-grabbed (*termination-population-lock*)
     (cdr (assq object (population-data *termination-population*))))))

(defun do-automatic-termination ()
  (when *enable-automatic-termination*
    (drain-termination-queue)))

(queue-fixup
 (add-gc-hook 'do-automatic-termination :post-gc))

