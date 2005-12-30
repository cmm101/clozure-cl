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

(in-package "CCL")

; Miscellany.

(defun memq (item list)
  (do* ((tail list (%cdr tail)))
       ((null tail))
    (if (eq item (car tail))
      (return tail))))




(defun append-2 (y z)
  (if (null y)
    z
    (let* ((new (cons (car y) nil))
           (tail new))
      (declare (list new tail))
      (dolist (head (cdr y))
        (setq tail (cdr (rplacd tail (cons head nil)))))
      (rplacd tail z)
      new)))









(defun dbg (&optional arg)
  (dbg arg))


; This takes a simple-base-string and passes a C string into
; the kernel "Bug" routine.  Not too fancy, but neither is #_DebugStr,
; and there's a better chance that users would see this message.
(defun bug (arg)
  (if (typep arg 'simple-base-string)
    (let* ((len (length arg)))
      (%stack-block ((buf (1+ len)))
        (%copy-ivector-to-ptr arg 0 buf 0 len)
        (setf (%get-byte buf len) 0)
        (ff-call 
         (%kernel-import target::kernel-import-lisp-bug)
         :address buf
         :void)))
    (bug "Bug called with non-simple-base-string.")))

(defun total-bytes-allocated ()
  (%heap-bytes-allocated)
  #+not-any-more
  (+ (unsignedwide->integer *total-bytes-freed*)
     (%heap-bytes-allocated)))

(defun %freebytes ()
  (%normalize-areas)
  (let ((res 0))
    (with-macptrs (p)
      (do-consing-areas (area)
        (when (eql (%fixnum-ref area target::area.code) ppc::area-dynamic)
          (%setf-macptr-to-object p  area)
          (incf res (- #+ppc32-target
                       (%get-unsigned-long p target::area.high)
                       #+ppc64-target
                       (%%get-unsigned-longlong p target::area.high)
                       #+ppc32-target
                       (%get-unsigned-long p target::area.active)
                       #+ppc64-target
                       (%%get-unsigned-longlong p target::area.active))))))
    res))

(defun %reservedbytes ()
  (with-macptrs (p)
    (%setf-macptr-to-object p (%get-kernel-global 'ppc::all-areas))
    (- #+ppc32-target
       (%get-unsigned-long p target::area.high)
       #+ppc64-target
       (%%get-unsigned-longlong p target::area.high)
       #+ppc32-target
       (%get-unsigned-long p target::area.low)
       #+ppc64-target
       (%%get-unsigned-longlong p target::area.low))))

(defun object-in-application-heap-p (address)
  (declare (ignore address))
  t)


(defun %usedbytes ()
  (%normalize-areas)
  (let ((static 0)
        (dynamic 0)
        (library 0))
      (do-consing-areas (area)
	(let* ((active (%fixnum-ref area target::area.active))
	       (bytes (ash (- active
                            (%fixnum-ref area target::area.low))
                           target::fixnumshift))
	       (code (%fixnum-ref area target::area.code)))
	  (when (object-in-application-heap-p active)
	    (if (eql code ppc::area-dynamic)
	      (incf dynamic bytes)
	      (if (eql code ppc::area-managed-static)
		(incf library bytes)
		(incf static bytes))))))
      (let* ((hons-size (ash (openmcl-hons:hons-space-size) target::dnode-shift)))
        (decf dynamic hons-size)
        (values dynamic static library hons-size))))



(defun %stack-space ()
  (%normalize-areas)
  (let ((free 0)
        (used 0))
    (with-macptrs (p)
      (do-gc-areas (area)
	(when (member (%fixnum-ref area target::area.code)
		      '(#.ppc::area-vstack
			#.ppc::area-cstack
                      #.ppc::area-tstack))
	  (%setf-macptr-to-object p area)
	  (let ((active
                 #+ppc32-target
                  (%get-unsigned-long p ppc32::area.active)
                  #+ppc64-target
                  (%%get-unsigned-longlong p ppc64::area.active))
		(high
                 #+ppc32-target
                  (%get-unsigned-long p ppc32::area.high)
                  #+ppc64-target
                  (%%get-unsigned-longlong p ppc64::area.high))
		(low
                 #+ppc32-target
                 (%get-unsigned-long p ppc32::area.low)
                 #+ppc64-target
                 (%%get-unsigned-longlong p ppc64::area.low)))
	    (incf used (- high active))
	    (incf free (- active low))))))
    (values (+ free used) used free)))



; Returns an alist of the form:
; ((thread cstack-free cstack-used vstack-free vstack-used tstack-free tstack-used)
;  ...)
(defun %stack-space-by-lisp-thread ()
  (let* ((res nil))
    (without-interrupts
     (dolist (p (all-processes))
       (let* ((thread (process-thread p)))
         (when thread
           (push (cons thread (multiple-value-list (%thread-stack-space thread))) res)))))
    res))



; Returns six values.
;   sp free
;   sp used
;   vsp free
;   vsp used
;   tsp free
;   tsp used
(defun %thread-stack-space (&optional (thread *current-lisp-thread*))
  (when (eq thread *current-lisp-thread*)
    (%normalize-areas))
  (labels ((free-and-used (area)
	     (with-macptrs (p)
	       (%setf-macptr-to-object p area)
	       (let* ((low
                       #+ppc32-target
                       (%get-unsigned-long p ppc32::area.low)
                       #+ppc64-target
                       (%%get-unsigned-longlong p ppc64::area.low))
		      (high
                       #+ppc32-target
                        (%get-unsigned-long p ppc32::area.high)
                        #+ppc64-target
                        (%%get-unsigned-longlong p ppc64::area.high))
		      (active
                       #+ppc32-target
                       (%get-unsigned-long p ppc32::area.active)
                       #+ppc64-target
                       (%%get-unsigned-longlong p ppc64::area.active))
		      (free (- active low))
		      (used (- high active)))
		 (loop
		     (setq area (%fixnum-ref area target::area.older))
		     (when (eql area 0) (return))
		   (%setf-macptr-to-object p area)
		   (let ((low
                          #+ppc32-target
                           (%get-unsigned-long p ppc32::area.low)
                           #+ppc64-target
                           (%%get-unsigned-longlong p ppc64::area.low))
			 (high
                          #+ppc32-target
                           (%get-unsigned-long p ppc32::area.high)
                           #+ppc64-target
                           (%%get-unsigned-longlong p ppc64::area.high)))
		     (declare (fixnum low high))
		     (incf used (- high low))))
		 (values free used)))))
    (let* ((tcr (%svref thread target::lisp-thread.tcr-cell)))
      (if (or (null tcr)
	      (zerop (%fixnum-ref (%fixnum-ref tcr target::tcr.cs-area))))
	(values 0 0 0 0 0 0)
	(multiple-value-bind (cf cu) (free-and-used (%fixnum-ref tcr target::tcr.cs-area))
	  (multiple-value-bind (vf vu) (free-and-used (%fixnum-ref tcr target::tcr.vs-area))
	    (multiple-value-bind (tf tu) (free-and-used (%fixnum-ref tcr target::tcr.ts-area ))
	      (values cf cu vf vu tf tu))))))))


(defun room (&optional (verbose :default))
  "Print to *STANDARD-OUTPUT* information about the state of internal
  storage and its management. The optional argument controls the
  verbosity of output. If it is T, ROOM prints out a maximal amount of
  information. If it is NIL, ROOM prints out a minimal amount of
  information. If it is :DEFAULT or it is not supplied, ROOM prints out
  an intermediate amount of information."
  (let* ((freebytes nil)
         (usedbytes nil)
         (static-used nil)
         (staticlib-used nil)
         (hons-space-size nil)
         (lispheap nil)
         (reserved nil)
         (static nil)
         (stack-total)
         (stack-used)
         (stack-free)
         (stack-used-by-thread nil))
    (with-other-threads-suspended
        (without-gcing
         (setq freebytes (%freebytes))
         (when verbose
           (multiple-value-setq (usedbytes static-used staticlib-used hons-space-size)
             (%usedbytes))
           (setq lispheap (+ freebytes usedbytes)
                 reserved (%reservedbytes)
                 static (+ static-used staticlib-used hons-space-size))
           (multiple-value-setq (stack-total stack-used stack-free)
             (%stack-space))
           (unless (eq verbose :default)
             (setq stack-used-by-thread (%stack-space-by-lisp-thread))))))
    (format t "~&Approximately ~:D bytes of memory can be allocated ~%before the next full GC is triggered. ~%" freebytes)
    (when verbose
      (flet ((k (n) (round n 1024)))
        (princ "
                  Total Size             Free                 Used")
        (format t "~&Lisp Heap: ~12T~10D (~DK)  ~33T~10D (~DK)  ~54T~10D (~DK)"
                lispheap (k lispheap)
                freebytes (k freebytes)
                usedbytes (k usedbytes))
        (format t "~&Stacks:    ~12T~10D (~DK)  ~33T~10D (~DK)  ~54T~10D (~DK)"
                stack-total (k stack-total)
                stack-free (k stack-free)
                stack-used (k stack-used))
        (format t "~&Static: ~12T~10D (~DK)  ~33T~10D (~DK) ~54T~10D (~DK)"
                static (k static)
                0 0
                static (k static))
        (when hons-space-size
          (format t "~&~,3f MB of static memory reserved for hash consing."
                  (/ hons-space-size (float (ash 1 20)))))
        (format t "~&~,3f MB reserved for heap expansion."
                (/ reserved (float (ash 1 20))))
        (unless (eq verbose :default)
          (terpri)
          (let* ((processes (all-processes)))
            (dolist (thread-info stack-used-by-thread)
              (destructuring-bind (thread sp-free sp-used vsp-free vsp-used tsp-free tsp-used)
                  thread-info
                (let* ((process (dolist (p processes)
                                  (when (eq (process-thread p) thread)
                                    (return p)))))
                  (when process
                    (let ((sp-total (+ sp-used sp-free))
                          (vsp-total (+ vsp-used vsp-free))
                          (tsp-total (+ tsp-used tsp-free)))
                      (format t "~%~a(~d)~%  cstack:~12T~10D (~DK)  ~33T~10D (~DK)  ~54T~10D (~DK)~
                               ~%  vstack:~12T~10D (~DK)  ~33T~10D (~DK)  ~54T~10D (~DK)~
                               ~%  tstack:~12T~10D (~DK)  ~33T~10D (~DK)  ~54T~10D (~DK)"
                              (process-name process)
                              (process-serial-number process)
                              sp-total (k sp-total) sp-free (k sp-free) sp-used (k sp-used)
                              vsp-total (k vsp-total) vsp-free (k vsp-free) vsp-used (k vsp-used)
                              tsp-total (k tsp-total) tsp-free (k tsp-free) tsp-used (k tsp-used)))))))))))))


(defun list-length (l)
  "Return the length of the given LIST, or NIL if the LIST is circular."
  (do* ((n 0 (+ n 2))
        (fast l (cddr fast))
        (slow l (cdr slow)))
       ((null fast) n)
    (declare (fixnum n))
    (if (null (cdr fast))
      (return (the fixnum (1+ n)))
      (if (and (eq fast slow)
               (> n 0))
        (return nil)))))

(defun proper-list-p (l)
  (and (typep l 'list)
       (do* ((n 0 (+ n 2))
             (fast l (if (and (listp fast) (listp (cdr fast)))
                       (cddr fast)
                       (return-from proper-list-p nil)))
             (slow l (cdr slow)))
            ((null fast) n)
         (declare (fixnum n))
         (if (atom fast)
           (return nil)
           (if (null (cdr fast))
             (return t)
             (if (and (eq fast slow)
                      (> n 0))
               (return nil)))))))

(defun proper-sequence-p (x)
  (cond ((typep x 'vector))
	((typep x 'list) (not (null (list-length x))))))


(defun length (seq)
  "Return an integer that is the length of SEQUENCE."
  (seq-dispatch
   seq
   (or (list-length seq)
       (%err-disp $XIMPROPERLIST seq))
   (if (= (the fixnum (typecode seq)) target::subtag-vectorH)
     (%svref seq target::vectorH.logsize-cell)
     (uvsize seq))))

(defun %str-from-ptr (pointer len)
  (%copy-ptr-to-ivector pointer 0 (make-string len :element-type 'base-char) 0 len))

(defun %get-cstring (pointer)
  (do* ((end 0 (1+ end)))
       ((zerop (%get-byte pointer end))
        (%str-from-ptr pointer end))))

;;; This is mostly here so we can bootstrap shared libs without
;;; having to bootstrap #_strcmp.
;;; Return true if the cstrings are equal, false otherwise.
(defun %cstrcmp (x y)
  (do* ((i 0 (1+ i))
	(bx (%get-byte x i) (%get-byte x i))
	(by (%get-byte y i) (%get-byte y i)))
       ((not (= bx by)))
    (declare (fixnum i bx by))
    (when (zerop bx)
      (return t))))

(defvar %documentation nil)

(defvar %documentation-lock% nil)

(setq %documentation
  (make-hash-table :weak t :size 100 :test 'eq :rehash-threshold .95)
  %documentation-lock% (make-lock))

(defun %put-documentation (thing doc-id doc)
  (with-lock-grabbed (%documentation-lock%)
    (let* ((info (gethash thing %documentation))
	   (pair (assoc doc-id info)))
      (if doc
        (progn
          (unless (typep doc 'string)
            (report-bad-arg doc 'string))
          (if pair
            (setf (cdr pair) doc)
            (setf (gethash thing %documentation) (cons (cons doc-id doc) info))))
	(when pair
	  (if (setq info (nremove pair info))
	    (setf (gethash thing %documentation) info)
	    (remhash thing %documentation))))))
  doc)

(defun %get-documentation (object doc-id)
  (cdr (assoc doc-id (gethash object %documentation))))

;;; This pretends to be (SETF DOCUMENTATION), until that generic function
;;; is defined.  It handles a few common cases.
(defun %set-documentation (thing doc-id doc-string)
  (case doc-id
    (function 
     (if (typep thing 'function)
       (%put-documentation thing t doc-string)
       (if (typep thing 'symbol)
         (let* ((def (fboundp thing)))
           (if def
             (%put-documentation def t doc-string)))
         (if (setf-function-name-p thing)
           (%set-documentation
            (setf-function-name thing) doc-id doc-string)))))
    (variable
     (if (typep thing 'symbol)
       (%put-documentation thing doc-id doc-string)))
    (t (%put-documentation thing doc-id doc-string)))
  doc-string)


(%fhave 'set-documentation #'%set-documentation)



;;; This is intended for use by debugging tools.  It's a horrible thing
;;; to do otherwise.  The caller really needs to hold the heap-segment
;;; lock; this grabs the tcr queue lock as well.
(defun %suspend-other-threads ()
  (ff-call (%kernel-import target::kernel-import-suspend-other-threads)
           :void))

(defun %resume-other-threads ()
  (ff-call (%kernel-import target::kernel-import-resume-other-threads)
           :void))

(defun %lock-recursive-lock (lock &optional flag)
  (with-macptrs ((p)
		 (owner (%get-ptr lock target::lockptr.owner))
		 (signal (%get-ptr lock target::lockptr.signal)))
    (%setf-macptr-to-object p (%current-tcr))
    (if (istruct-typep flag 'lock-acquisition)
      (setf (lock-acquisition.status flag) nil)
      (if (consp flag)
        (rplaca flag nil)
        (if flag (report-bad-arg flag '(or lock-acquisition cons)))))
    (loop
      (without-interrupts
       (when (eql p owner)
         (incf #+ppc32-target
               (%get-unsigned-long lock ppc32::lockptr.count)
               #+ppc64-target
               (%%get-unsigned-longlong lock ppc64::lockptr.count))
         (when flag
           (if (consp flag)
             (rplaca flag t)
             (setf (lock-acquisition.status flag) t)))
         (return t))
       (when (eql 1 (%atomic-incf-ptr lock))
         (setf (%get-ptr lock target::lockptr.owner) p
               #+ppc32-target
               (%get-unsigned-long lock ppc32::lockptr.count)
               #+ppc64-target
               (%%get-unsigned-longlong lock ppc64::lockptr.count) 1)
         (if flag
           (if (consp flag)
             (rplaca flag t)
             (setf (lock-acquisition.status flag) t)))
         (return t)))
      (%timed-wait-on-semaphore-ptr signal 1 0 "waiting for lock"))))

(defun %try-recursive-lock (lock &optional flag)
  (with-macptrs ((p)
		 (owner (%get-ptr lock target::lockptr.owner)))
    (%setf-macptr-to-object p (%current-tcr))
    (if flag
      (if (istruct-typep flag 'lock-acquisition)
        (setf (lock-acquisition.status flag) nil)
        (report-bad-arg flag 'lock-acquisition)))
    (without-interrupts
     (cond ((eql p owner)
            (incf #+ppc32-target
                  (%get-unsigned-long lock ppc32::lockptr.count)
                  #+ppc64-target
                  (%%get-unsigned-longlong lock ppc64::lockptr.count))
            (if flag (setf (lock-acquisition.status flag) t))
            t)
           ((eql 0 (%ptr-store-conditional lock 0 1))
            (setf (%get-ptr lock target::lockptr.owner) p
                  #+ppc32-target
                  (%get-unsigned-long lock ppc32::lockptr.count)
                  #+ppc64-target
                  (%%get-unsigned-longlong lock ppc64::lockptr.count) 1)
            (if flag (setf (lock-acquisition.status flag) t))
            t)
           (t nil)))))


(defun %unlock-recursive-lock (lock)
  (with-macptrs ((p)
		 (owner (%get-ptr lock target::lockptr.owner))
		 (signal (%get-ptr lock target::lockptr.signal)))
    (%setf-macptr-to-object p (%current-tcr))
    (unless (eql p owner)
      (error 'not-lock-owner :lock lock))
    (without-interrupts
     (when (eql 0 (decf (the fixnum
                          #+ppc32-target
                          (%get-unsigned-long lock ppc32::lockptr.count)
                          #+ppc64-target
                          (%%get-unsigned-longlong lock ppc64::lockptr.count))))
       (setf (%get-ptr lock target::lockptr.owner) (%null-ptr))
       (let* ((pending (1- (the fixnum (%atomic-swap-ptr lock 0)))))
         (declare (fixnum pending))
         (with-macptrs ((waiting (%inc-ptr lock target::lockptr.waiting)))
           (%atomic-incf-ptr-by waiting pending)
           (when (>= (the fixnum (%atomic-decf-ptr-if-positive waiting)) 0)
             (%signal-semaphore-ptr signal))))))
    nil))


(defun %%lock-owner (lock)
  "Intended for debugging only; ownership may change while this code
   is running."
  (let* ((tcr (%get-object (recursive-lock-ptr lock) target::lockptr.owner)))
    (unless (zerop tcr)
      (tcr->process tcr))))

 
  
(defun %suspend-tcr (tcr)
  (not (zerop (the fixnum 
                (ff-call (%kernel-import target::kernel-import-suspend-tcr)
                         :unsigned-fullword (ash tcr target::fixnumshift)
                         :unsigned-fullword)))))

(defun %resume-tcr (tcr)
  (not (zerop (the fixnum
		(ff-call (%kernel-import target::kernel-import-resume-tcr)
			 :unsigned-fullword (ash tcr target::fixnumshift)
			 :unsigned-fullword)))))



(defun %rplaca-conditional (cons-cell old new)
  (%store-node-conditional target::cons.car cons-cell old new))

(defun %rplacd-conditional (cons-cell old new)
  (%store-node-conditional target::cons.cdr cons-cell old new))

;;; Atomically push NEW onto the list in the I'th cell of uvector V.
(defun atomic-push-uvector-cell (v i new)
  (let* ((cell (cons new nil))
         (offset (+ target::misc-data-offset (ash i target::word-shift))))
    (loop
      (let* ((old (uvref v i)))
        (rplacd cell old)
        (when (%store-node-conditional offset v old cell)
          (return cell))))))

(defun store-gvector-conditional (index gvector old new)
  (%store-node-conditional (+ target::misc-data-offset
			      (ash index target::word-shift))
			   gvector
			   old
			   new))

(defun %atomic-incf-car (cell &optional (by 1))
  (%atomic-incf-node (require-type by 'fixnum)
		     (require-type cell 'cons)
		     target::cons.car))

(defun %atomic-incf-cdr (cell &optional (by 1))
  (%atomic-incf-node (require-type by 'fixnum)
		     (require-type cell 'cons)
		     target::cons.cdr))

(defun %atomic-incf-gvector (v i &optional (by 1))
  (setq v (require-type v 'gvector))
  (setq i (require-type i 'fixnum))
  (%atomic-incf-node by v (+ target::misc-data-offset (ash i target::word-shift))))

(defun %atomic-incf-symbol-value (s &optional (by 1))
  (setq s (require-type s 'symbol))
  (let* ((binding-address (%symbol-binding-address s)))
    (declare (fixnum binding-address))
    (if (zerop binding-address)
      (%atomic-incf-node by s target::symbol.vcell-cell)
      (%atomic-incf-node by binding-address (* 2 target::node-size)))))

;;; Yield the CPU, via a platform-specific syscall.
(defun yield ()
  (%syscall target::yield-syscall :signed-fullword))

(defun write-lock-rwlock (lock)
    (let* ((context (%current-tcr)))
      (if (eq (%svref lock target::lock.writer-cell) context)
        (progn
          (decf (%svref lock target::lock._value-cell))
          lock)
        (loop
          (when (%store-immediate-conditional target::lock._value lock 0 -1)
            (setf (%svref lock target::lock.writer-cell) context)
            (return lock))
          (%nanosleep 0 *ns-per-tick*)))))

;;; Return with the the old interrupt level, with the lock held and
;;; interrupts disabled, if we return at all.
(defun write-lock-rwlock-disable-interrupts (lock)
    (let* ((context (%current-tcr))
           (old-interrupt-level (disable-lisp-interrupts)))
      (if (eq (%svref lock target::lock.writer-cell) context)
        (progn
          (decf (%svref lock target::lock._value-cell))
          old-interrupt-level)
        (loop
          (when (%store-immediate-conditional target::lock._value lock 0 -1)
            (setf (%svref lock target::lock.writer-cell) context)
            (return old-interrupt-level))
          (ignoring-without-interrupts
           (%nanosleep 0 *ns-per-tick*))))))

(defun read-lock-rwlock (lock)
  (loop
    (when (%try-read-lock-rwlock lock)
      (return lock))
    (%nanosleep 0 *ns-per-tick*)))
