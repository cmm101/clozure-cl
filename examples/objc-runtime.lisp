;;;-*-Mode: LISP; Package: CCL -*-
;;;
;;;   Copyright (C) 2002-2003 Clozure Associates
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


;;; Utilities for interacting with the Apple/GNU Objective-C runtime
;;; systems.

(eval-when (:compile-toplevel :load-toplevel :execute)
  #+darwinppc-target (pushnew :apple-objc *features*)
  #+linuxppc-target (pushnew :gnu-objc *features*)
  #-(or darwinppc-target linuxppc-target)
  (error "Not sure what ObjC runtime system to use."))


(eval-when (:compile-toplevel :load-toplevel :execute)
  (set-dispatch-macro-character
   #\#
   #\@
   (nfunction
    |objc-#@-reader|
    (lambda (stream subchar numarg)
      (declare (ignore subchar numarg))
      (let* ((string (read stream)))
	(check-type string string)
	`(@ ,string))))))

(eval-when (:compile-toplevel :execute)
  #+apple-objc
  (use-interface-dir :cocoa)
  #+gnu-objc
  (use-interface-dir :gnustep))

(defpackage "OBJC"
  (:use)
  (:export "OBJC-OBJECT" "OBJC-CLASS-OBJECT" "OBJC-CLASS" "OBJC-METACLASS"))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require "SPLAY-TREE")
  (require "NAME-TRANSLATION")
  (require "PROCESS-OBJC-MODULES")
  (require "OBJC-CLOS"))

(defloadvar *NSApp* nil )


(defun ensure-objc-classptr-resolved (classptr)
  #+apple-objc (declare (ignore classptr))
  #+gnu-objc
  (unless (logtest #$_CLS_RESOLV (pref classptr :objc_class.info))
    (external-call "__objc_resolve_class_links" :void)))




(let* ((objc-class-map (make-splay-tree #'%ptr-eql
					#'(lambda (x y)
					    (< (the (unsigned-byte 32)
						 (%ptr-to-int x))
					       (the (unsigned-byte 32)
						 (%ptr-to-int Y))))))
       (objc-metaclass-map (make-splay-tree #'%ptr-eql
					    #'(lambda (x y)
						(< (the (unsigned-byte 32)
						     (%ptr-to-int x))
						   (the (unsigned-byte 32)
						     (%ptr-to-int Y))))))
       (objc-class-lock (make-lock))
       (next-objc-class-id 0)
       (next-objc-metaclass-id 0)
       (class-table-size 1024)
       (c (make-array 1024))
       (m (make-array 1024))
       (cw (make-array 1024 :initial-element nil))
       (mw (make-array 1024 :initial-element nil))
       (csv (make-array 1024))
       (msv (make-array 1024))
       (class-id->metaclass-id (make-array 1024 :initial-element nil))
       (class-foreign-names (make-array 1024))
       (metaclass-foreign-names (make-array 1024))
       )

  (flet ((grow-vectors ()
	   (let* ((old-size class-table-size)
		  (new-size (* 2 old-size)))
	     (declare (fixnum old-size new-size))
	     (macrolet ((extend (v)
                              `(setq ,v (%extend-vector old-size ,v new-size))))
                   (extend c)
                   (extend m)
                   (extend cw)
                   (extend mw)
		   (fill cw nil :start old-size :end new-size)
		   (fill mw nil :start old-size :end new-size)
                   (extend csv)
                   (extend msv)
		   (extend class-id->metaclass-id)
		   (fill class-id->metaclass-id nil :start old-size :end new-size)
		   (extend class-foreign-names)
		   (extend metaclass-foreign-names))
	     (setq class-table-size new-size))))
    (flet ((assign-next-class-id ()
	     (let* ((id next-objc-class-id))
	       (if (= (incf next-objc-class-id) class-table-size)
		 (grow-vectors))
	       id))
	   (assign-next-metaclass-id ()
	     (let* ((id next-objc-metaclass-id))
	       (if (= (incf next-objc-metaclass-id) class-table-size)
		 (grow-vectors))
	       id)))
      (defun id->objc-class (i)
	(svref c i))
      (defun (setf id->objc-class) (new i)
	(setf (svref c i) new))
      (defun id->objc-metaclass (i)
	(svref m i))
      (defun (setf id->objc-metaclass) (new i)
	(setf (svref m i) new))
      (defun id->objc-class-wrapper (i)
	(svref cw i))
      (defun (setf id->objc-class-wrapper) (new i)
	(setf (svref cw i) new))
      (defun id->objc-metaclass-wrapper (i)
	(svref mw i))
      (defun (setf id->objc-metaclass-wrapper) (new i)
	(setf (svref mw i) new))
      (defun id->objc-class-slots-vector (i)
	(svref csv i))
      (defun (setf id->objc-class-slots-vector) (new i)
	(setf (svref csv i) new))
      (defun id->objc-metaclass-slots-vector (i)
	(svref msv i))
      (defun (setf id->objc-metaclass-slots-vector) (new i)
	(setf (svref msv i) new))
      (defun objc-class-id-foreign-name (i)
	(svref class-foreign-names i))
      (defun (setf objc-class-id-foreign-name) (new i)
	(setf (svref class-foreign-names i) new))
      (defun objc-metaclass-id-foreign-name (i)
	(svref metaclass-foreign-names i))
      (defun (setf objc-metaclass-id-foreign-name) (new i)
	(setf (svref metaclass-foreign-names i) new))
      (defun %clear-objc-class-maps ()
	(with-lock-grabbed (objc-class-lock)
	  (setf (splay-tree-root objc-class-map) nil
		(splay-tree-root objc-metaclass-map) nil
		(splay-tree-count objc-class-map) 0
		(splay-tree-count objc-metaclass-map) 0)))
      (flet ((install-objc-metaclass (meta)
	       (or (splay-tree-get objc-metaclass-map meta)
		   (let* ((id (assign-next-metaclass-id))
			  (meta (%inc-ptr meta 0)))
		     (splay-tree-put objc-metaclass-map meta id)
		     (setf (svref m id) meta
			   (svref msv id)
			   (make-objc-metaclass-slots-vector meta))
		     id))))
	(defun register-objc-class (class)
	  "ensure that the class is mapped to a small integer and associate a slots-vector with it."
	  (with-lock-grabbed (objc-class-lock)
	    (ensure-objc-classptr-resolved class)
	    (or (splay-tree-get objc-class-map class)
		(let* ((id (assign-next-class-id))
		       (class (%inc-ptr class 0))
		       (meta (pref class #+apple-objc :objc_class.isa #+gnu-objc :objc_class.class_pointer)))
		  (splay-tree-put objc-class-map class id)
		  (setf (svref c id) class
			(svref csv id)
			(make-objc-class-slots-vector class)
			(svref class-id->metaclass-id id)
			(install-objc-metaclass meta))
		  id)))))
      (defun objc-class-id (class)
	(with-lock-grabbed (objc-class-lock)
	  (splay-tree-get objc-class-map class)))
      (defun objc-metaclass-id (meta)
	(with-lock-grabbed (objc-class-lock)
	  (splay-tree-get objc-metaclass-map meta)))
      (defun objc-class-id->objc-metaclass-id (class-id)
	(svref class-id->metaclass-id class-id))
      (defun objc-class-id->objc-metaclass (class-id)
	(svref m (svref class-id->metaclass-id class-id)))
      (defun objc-class-map () objc-class-map)
      (defun %objc-class-count () next-objc-class-id)
      (defun objc-metaclass-map () objc-metaclass-map)
      (defun %objc-metaclass-count () next-objc-metaclass-id))))

(pushnew #'%clear-objc-class-maps *save-exit-functions* :test #'eq
         :key #'function-name)

(defun do-all-objc-classes (f)
  (map-splay-tree (objc-class-map) #'(lambda (id)
				       (funcall f (id->objc-class id)))))

(defun canonicalize-registered-class (c)
  (let* ((id (objc-class-id c)))
    (if id
      (id->objc-class id)
      (error "Class ~S isn't recognized." c))))

(defun canonicalize-registered-metaclass (m)
  (let* ((id (objc-metaclass-id m)))
    (if id
      (id->objc-metaclass id)
      (error "Class ~S isn't recognized." m))))


;;; Open shared libs.
#+darwinppc-target
(progn
(defloadvar *cocoa-event-process* *initial-process*)

(defun run-in-cocoa-process-and-wait  (f)
  (let* ((process *cocoa-event-process*)
	 (success (cons nil nil))
	 (done (make-semaphore)))
    (process-interrupt process #'(lambda ()
				   (unwind-protect
					(progn
					  (setf (car success) (funcall f)))
				     (signal-semaphore done))))
    (wait-on-semaphore done)
    (car success)))


(def-ccl-pointers cocoa-framework ()
  (run-in-cocoa-process-and-wait
   #'(lambda ()
       ;; We need to load and "initialize" the CoreFoundation library
       ;; in the thread that's going to process events.  Looking up a
       ;; symbol in the library should cause it to be initialized
       (open-shared-library "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
       (open-shared-library "/System/Library/Frameworks/Cocoa.framework/Cocoa")
       (let* ((current (#_CFRunLoopGetCurrent))
              (main (external-call "_CFRunLoopGetMain" :address)))
         ;; Sadly, it seems that OSX versions > 10.2 only want the
         ;; main CFRunLoop to be owned by the initial thread.  I
         ;; suppose that we could try to run the event process on that
         ;; thread, but that'd require some reorganization.
         (or
          (eql current main)
          (progn (external-call "__CFRunLoopSetCurrent"
                                :address main)
                 t))))))


(let* ((cfstring-sections (cons 0 nil)))
  (defun reset-cfstring-sections ()
    (rplaca cfstring-sections 0)
    (rplacd cfstring-sections nil))
  (defun find-cfstring-sections ()
    (let* ((image-count (#_ _dyld_image_count)))
      (when (> image-count (car cfstring-sections))
	(process-section-in-all-libraries
	 #$SEG_DATA
	 "__cfstring"
	 #'(lambda (sectaddr size)
	     (let* ((addr (%ptr-to-int sectaddr))
		    (limit (+ addr size))
		    (already (member addr (cdr cfstring-sections) :key #'car)))
	       (if already
		 (rplacd already limit)
		 (push (cons addr limit) (cdr cfstring-sections))))))
	(setf (car cfstring-sections) image-count))))
  (defun pointer-in-cfstring-section-p (ptr)
    (let* ((addr (%ptr-to-int ptr)))
      (dolist (s (cdr cfstring-sections))
	(when (and (>= addr (car s))
		   (< addr (cdr s)))
	  (return t))))))
	       
					  

)

#+gnu-objc
(progn
(defparameter *gnustep-system-root* "/usr/GNUstep/" "The root of all evil.")
(defparameter *gnustep-libraries-pathname*
  (merge-pathnames "System/Library/Libraries/" *gnustep-system-root*))

(defloadvar *pending-loaded-classes* ())

(defcallback register-class-callback (:address class :address category :void)
  (let* ((id (map-objc-class class)))
    (unless (%null-ptr-p category)
      (let* ((cell (or (assoc id *pending-loaded-classes*)
                       (let* ((c (list id)))
                         (push c *pending-loaded-classes*)
                         c))))
        (push (%inc-ptr category 0) (cdr cell))))))

;;; Shouldn't really be GNU-objc-specific.

(defun get-c-format-string (c-format-ptr c-arg-ptr)
  (do* ((n 128))
       ()
    (declare (fixnum n))
    (%stack-block ((buf n))
      (let* ((m (#_vsnprintf buf n c-format-ptr c-arg-ptr)))
	(declare (fixnum m))
	(cond ((< m 0) (return nil))
	      ((< m n) (return (%get-cstring buf)))
	      (t (setq n m)))))))



(defun init-gnustep-framework ()
  (or (getenv "GNUSTEP_SYSTEM_ROOT")
      (setenv "GNUSTEP_SYSTEM_ROOT" *gnustep-system-root*))
  (open-shared-library "libobjc.so.1")
  (setf (%get-ptr (foreign-symbol-address "_objc_load_callback"))
        register-class-callback)
  (open-shared-library (namestring (merge-pathnames "libgnustep-base.so"
                                                    *gnustep-libraries-pathname*)))
  (open-shared-library (namestring (merge-pathnames "libgnustep-gui.so"
                                                    *gnustep-libraries-pathname*))))

(def-ccl-pointers gnustep-framework ()
  (init-gnustep-framework))
)

(defun get-appkit-version ()
  (%get-double-float (foreign-symbol-address #+apple-objc "_NSAppKitVersionNumber" #+gnu-objc "NSAppKitVersionNumber")))

(defun get-foundation-version ()
  (%get-double-float (foreign-symbol-address #+apple-objc "_NSFoundationVersionNumber" #+gnu-objc "NSFoundationVersionNumber")))

(defparameter *appkit-library-version-number* (get-appkit-version))
(defparameter *foundation-library-version-number* (get-foundation-version))

(def-ccl-pointers cfstring-sections ()
  (reset-cfstring-sections)
  (find-cfstring-sections))

;;; When starting up an image that's had ObjC classes in it, all of
;;; those canonical classes (and metaclasses) will have had their type
;;; changed (by SAVE-APPLICATION) to, CCL::DEAD-MACPTR and the addresses
;;; of those classes may be bogus.  The splay trees (objc-class/metaclass-map)
;;; should be empty.
;;; For each class that -had- had an assigned ID, determine its ObjC
;;; class name, and ask ObjC where (if anywhere) the class is now.
;;; If we get a non-null answer, revive the class pointer and set its
;;; address appropriately, then add an entry to the splay tree; this
;;; means that classes that existed on both sides of SAVE-APPLICATION
;;; will retain the same ID.

(defun revive-objc-classes ()
  ;; Make a first pass over the class and metaclass tables;
  ;; resolving those foreign classes that existed in the old
  ;; image and still exist in the new.
  (unless (= *foundation-library-version-number* (get-foundation-version))
    (format *error-output* "~&Foundation version mismatch: expected ~s, got ~s~&"
	    *Foundation-library-version-number* (get-foundation-version))
    (#_exit 1))
  (unless (= *appkit-library-version-number* (get-appkit-version))
    (format *error-output* "~&AppKit version mismatch: expected ~s, got ~s~&"
	    *appkit-library-version-number* (get-appkit-version))
    (#_exit 1))
  (let* ((class-map (objc-class-map))
	 (metaclass-map (objc-metaclass-map))
	 (nclasses (%objc-class-count)))
    (dotimes (i nclasses)
      (let* ((c (id->objc-class i))
	     (meta-id (objc-class-id->objc-metaclass-id i))
	     (m (id->objc-metaclass meta-id)))
	(%revive-macptr c)
	(%revive-macptr m)
	(unless (splay-tree-get class-map c)
	  (%set-pointer-to-objc-class-address (objc-class-id-foreign-name i) c)
	  ;; If the class is valid and the metaclass is still a
	  ;; dead pointer, revive the metaclass 
	  (unless (%null-ptr-p c)
	    (splay-tree-put class-map c i)
	    (unless (splay-tree-get metaclass-map m)
	      (when (%null-ptr-p m)
		(%setf-macptr m (pref c #+apple-objc :objc_class.isa
				      #+gnu-objc :objc_class.class_pointer)))
	      (splay-tree-put metaclass-map m meta-id))))))
    ;; Second pass: install class objects for user-defined classes,
    ;; assuming the superclasses are already "revived".  If the
    ;; superclass is itself user-defined, it'll appear first in the
    ;; class table; that's an artifact of the current implementation.
    (dotimes (i nclasses)
      (let* ((c (id->objc-class i)))
	(when (and (%null-ptr-p c)
		   (not (slot-value c 'foreign)))
	  (let* ((super (dolist (s (class-direct-superclasses c)
				 (error "No ObjC superclass of ~s" c))
			  (when (objc-class-p s) (return s))))
		 (meta-id (objc-class-id->objc-metaclass-id i))
		 (m (id->objc-metaclass meta-id)))
	    (unless (splay-tree-get metaclass-map m)
	      (%revive-macptr m)
	      (%setf-macptr m (%make-basic-meta-class
			       (make-cstring (objc-metaclass-id-foreign-name meta-id))
			       super
			       (find-class 'ns::ns-object)))
	      (splay-tree-put metaclass-map m meta-id))
	    (%setf-macptr c (%make-class-object
			     m
			     super
			     (make-cstring (objc-class-id-foreign-name i))
			     (%null-ptr)
			     0))
	    (multiple-value-bind (ivars instance-size)
		(%make-objc-ivars c)
	      (%add-objc-class c ivars instance-size)
	      (splay-tree-put class-map c i))))))))

(pushnew #'revive-objc-classes *lisp-system-pointer-functions*
	 :test #'eq
	 :key #'function-name)
    
    

(defun install-foreign-objc-class (class)
  (let* ((id (objc-class-id class)))
    (unless id
      (setq id (register-objc-class class)
	    class (id->objc-class id))
      ;; If not mapped, map the superclass (if there is one.)
      (let* ((super (pref class :objc_class.super_class)))
	(unless (%null-ptr-p super)
	  (install-foreign-objc-class super))
	(let* ((class-foreign-name (%get-cstring
					 (pref class :objc_class.name)))
	       (class-name 
		(objc-to-lisp-classname class-foreign-name
					"NS"))
	       (meta-id (objc-class-id->objc-metaclass-id id)) 
	       (meta (id->objc-metaclass meta-id)))
	  ;; Metaclass may already be initialized.  It'll have a class
	  ;; wrapper if so.
	  (unless (id->objc-metaclass-wrapper meta-id)
	    (let* ((meta-foreign-name (%get-cstring
				       (pref meta :objc_class.name)))
		   (meta-name (intern
			       (concatenate 'string
					    "+"
					    (string
					     (objc-to-lisp-classname
					      meta-foreign-name
					      "NS")))
				      "NS"))
		   (meta-super (pref meta :objc_class.super_class)))
	      ;; It's important (here and when initializing the class
	      ;; below) to use the "canonical" (registered) version
	      ;; of the class, since some things in CLOS assume
	      ;; EQness.  We probably don't want to violate that
	      ;; assumption; it'll be easier to revive a saved image
	      ;; if we don't have a lot of EQL-but-not-EQ class pointers
	      ;; to deal with.
	      (initialize-instance meta
				   :name meta-name
				   :direct-superclasses
				   (list
				    (if (or (%null-ptr-p meta-super)
					    (not (%objc-metaclass-p meta-super)))
				      (find-class 'objc:objc-class)
				      (canonicalize-registered-metaclass meta-super)))
				   :peer class
				   :foreign t)
	      (setf (objc-metaclass-id-foreign-name meta-id)
		    meta-foreign-name)
	      (setf (find-class meta-name) meta)))
	  (setf (slot-value class 'direct-slots)
		(%compute-foreign-direct-slots class))
	  (initialize-instance class
			       :name class-name
			       :direct-superclasses
			       (list
				(if (%null-ptr-p super)
				  (find-class 'objc:objc-object)
				  (canonicalize-registered-class super)))
			       :peer meta
			       :foreign t)
	  (setf (objc-class-id-foreign-name id) class-foreign-name)
	  (setf (find-class class-name) class))))))
				

;;; An instance of NSConstantString (which is a subclass of NSString)
;;; consists of a pointer to the NSConstantString class (which the
;;; global "_NSConstantStringClassReference" conveniently refers to), a
;;; pointer to an array of 8-bit characters (doesn't have to be #\Nul
;;; terminated, but doesn't hurt) and the length of that string (not
;;; counting any #\Nul.)
;;; The global reference to the "NSConstantString" class allows us to
;;; make instances of NSConstantString, ala the @"foo" construct in
;;; ObjC.  Sure it's ugly, but it seems to be exactly what the ObjC
;;; compiler does.


(defloadvar *NSConstantString-class*
   #+apple-objc
  (foreign-symbol-address "__NSConstantStringClassReference")
  #+gnu-objc
  (with-cstrs ((name "NSConstantString"))
      (#_objc_lookup_class name)))

;;; Execute the body with the variable NSSTR bound to a
;;; stack-allocated NSConstantString instance (made from
;;; *NSConstantString-class*, CSTRING and LEN).
(defmacro with-nsstr ((nsstr cstring len) &body body)
  #+apple-objc
  `(rlet ((,nsstr :<NSC>onstant<S>tring
	   :isa *NSConstantString-class*
	   :bytes ,cstring
	   :num<B>ytes ,len))
      ,@body)
  #+gnu-objc
  `(rlet ((,nsstr :<NXC>onstant<S>tring
	   :isa *NSConstantString-class*
	   :c_string ,cstring
	   :len ,len))
    ,@body))

;;; Make a persistent (heap-allocated) NSConstantString.

(defun %make-constant-nsstring (string)
  "Make a persistent (heap-allocated) NSConstantString from the
argument lisp string."
  #+apple-objc
  (make-record :<NSC>onstant<S>tring
	       :isa *NSConstantString-Class*
	       :bytes (make-cstring string)
	       :num<B>ytes (length string))
  #+gnu-objc
  (make-record :<NXC>onstant<S>tring
	       :isa *NSConstantString-Class*
	       :c_string (make-cstring string)
	       :len (length string))
  )

(defun %make-nsstring (string)
  (with-cstrs ((s string))
    (make-objc-instance 'ns:ns-string
                        :with-c-string s)))
                        


;;; Intern NSConstantString instances.
(defvar *objc-constant-strings* (make-hash-table :test #'equal))

(defstruct objc-constant-string
  string
  nsstringptr)

(defun ns-constant-string (string)
  (or (gethash string *objc-constant-strings*)
      (setf (gethash string *objc-constant-strings*)
	    (make-objc-constant-string :string string
				       :nsstringptr (%make-constant-nsstring string)))))

(def-ccl-pointers objc-strings ()
  (maphash #'(lambda (string cached)
	       (setf (objc-constant-string-nsstringptr cached)
		     (%make-nsstring string)))
	   *objc-constant-strings*))

(defmethod make-load-form ((s objc-constant-string) &optional env)
  (declare (ignore env))
  `(ns-constant-string ,(objc-constant-string-string s)))

(defmacro @ (string)
  `(objc-constant-string-nsstringptr ,(ns-constant-string string)))

#+gnu-objc
(progn
  (defcallback lisp-objc-error-handler (:id receiver :int errcode (:* :char) format :address argptr :<BOOL>)
    (let* ((message (get-c-format-string format argptr)))
      (error "ObjC runtime error ~d, receiver ~s :~& ~a"
	     errcode receiver message))
    #$YES)

  (def-ccl-pointers install-lisp-objc-error-handler ()
    (#_objc_set_error_handler lisp-objc-error-handler)))





;;; Registering named objc classes.


(defun objc-class-name-string (name)
  (etypecase name
    (symbol (lisp-to-objc-classname name))
    (string name)))

;;; We'd presumably cache this result somewhere, so we'd only do the
;;; lookup once per session (in general.)
(defun lookup-objc-class (name &optional error-p)
  (with-cstrs ((cstr (objc-class-name-string name)))
    (let* ((p (#+apple-objc #_objc_lookUpClass
               #+gnu-objc #_objc_lookup_class
	       cstr)))
      (if (%null-ptr-p p)
	(if error-p
	  (error "ObjC class ~a not found" name))
	p))))

(defun %set-pointer-to-objc-class-address (class-name-string ptr)
  (with-cstrs ((cstr class-name-string))
    (%setf-macptr ptr
		  (#+apple-objc #_objc_lookUpClass
		   #+gnu-objc #_objc_lookup_class
		   cstr)))
  nil)
   
		  

(defvar *objc-class-descriptors* (make-hash-table :test #'equal))


(defstruct objc-class-descriptor
  name
  classptr)

(def-ccl-pointers invalidate-objc-class-descriptors ()
  (maphash #'(lambda (name descriptor)
	       (declare (ignore name))
	       (setf (objc-class-descriptor-classptr descriptor) nil))
	   *objc-class-descriptors*))

(defun %objc-class-classptr (class-descriptor &optional (error-p t))
  (or (objc-class-descriptor-classptr class-descriptor)
      (setf (objc-class-descriptor-classptr class-descriptor)
	    (lookup-objc-class (objc-class-descriptor-name class-descriptor)
			       error-p))))

(defun load-objc-class-descriptor (name)
  (let* ((descriptor (or (gethash name *objc-class-descriptors*)
			 (setf (gethash name *objc-class-descriptors*)
			       (make-objc-class-descriptor  :name name)))))
    (%objc-class-classptr descriptor nil)
    descriptor))

(defmacro objc-class-descriptor (name)
  `(load-objc-class-descriptor ,name))

(defmethod make-load-form ((o objc-class-descriptor) &optional env)
  (declare (ignore env))
  `(load-objc-class-descriptor ,(objc-class-descriptor-name o)))

(defmacro @class (name)
  (let* ((name (objc-class-name-string name)))
    `(the (@metaclass ,name) (%objc-class-classptr ,(objc-class-descriptor name)))))

;;; This isn't quite the inverse operation of LOOKUP-OBJC-CLASS: it
;;; returns a simple C string.  and can be applied to a class or any
;;; instance (returning the class name.)
(defun objc-class-name (object)
  #+apple-objc
  (with-macptrs (p)
    (%setf-macptr p (#_object_getClassName object))
    (unless (%null-ptr-p p)
      (%get-cstring p)))
  #+gnu-objc
  (unless (%null-ptr-p object)
    (with-macptrs ((parent (pref object :objc_object.class_pointer)))
      (unless (%null-ptr-p parent)
        (if (logtest (pref parent :objc_class.info) #$_CLS_CLASS)
          (%get-cstring (pref parent :objc_class.name))
          (%get-cstring (pref object :objc_class.name)))))))


;;; Likewise, we want to cache the selectors ("SEL"s) which identify
;;; method names.  They can vary from session to session, but within
;;; a session, all methods with a given name (e.g, "init") will be
;;; represented by the same SEL.
(defun get-selector-for (method-name &optional error)
  (with-cstrs ((cmethod-name method-name))
    (let* ((p (#+apple-objc #_sel_getUid
	       #+gnu-objc #_sel_get_uid
	       cmethod-name)))
      (if (%null-ptr-p p)
	(if error
	  (error "Can't find ObjC selector for ~a" method-name))
	p))))

(defvar *objc-selectors* (make-hash-table :test #'equal))

(defstruct objc-selector
  name
  %sel)

(defun %get-SELECTOR (selector &optional (error-p t))
  (or (objc-selector-%sel selector)
      (setf (objc-selector-%sel selector)
	    (get-selector-for (objc-selector-name selector) error-p))))

(def-ccl-pointers objc-selectors ()
  (maphash #'(lambda (name sel)
	       (declare (ignore name))
	       (setf (objc-selector-%sel sel) nil))
	   *objc-selectors*))

(defun load-objc-selector (name)
  (let* ((selector (or (gethash name *objc-selectors*)
		       (setf (gethash name *objc-selectors*)
			     (make-objc-selector :name name)))))
    (%get-SELECTOR selector nil)
    selector))

(defmacro @SELECTOR (name)
  `(%get-selector ,(load-objc-selector name)))

(defmethod make-load-form ((s objc-selector) &optional env)
  (declare (ignore env))
  `(load-objc-selector ,(objc-selector-name s)))

;;; Add a faster way to get the message from a SEL by taking advantage of the
;;; fact that a selector is really just a canonicalized, interned C string
;;; containing the message.  (This is an admitted modularity violation;
;;; there's a more portable but slower way to do this if we ever need to.)

(defun lisp-string-from-sel (sel)
  (%get-cstring
   #+apple-objc sel
   #+gnu-objc (#_sel_get_name sel)))

;;; #_objc_msgSend takes two required arguments (the receiving object
;;; and the method selector) and 0 or more additional arguments;
;;; there'd have to be some macrology to handle common cases, since we
;;; want the compiler to see all of the args in a foreign call.

;;; I don't remmber what the second half of the above comment might
;;; have been talking about.

(defmacro objc-message-send (receiver selector-name &rest argspecs)
  (when (evenp (length argspecs))
    (setq argspecs (append argspecs '(:id))))
  #+apple-objc
  `(external-call "_objc_msgSend"
    :id ,receiver
    :<SEL> (@selector ,selector-name)
    ,@argspecs)
  #+gnu-objc
    (let* ((r (gensym))
	 (s (gensym))
	 (imp (gensym)))
    `(with-macptrs ((,r ,receiver)
		    (,s (@selector ,selector-name))
		    (,imp (external-call "objc_msg_lookup"
					:id ,r
					:<SEL> ,s
					:<IMP>)))
      (ff-call ,imp :id ,r :<SEL> ,s ,@argspecs))))

;;; A method that returns a structure (whose size is > 4 bytes on
;;; darwin, in all cases on linuxppc) does so by copying the structure
;;; into a pointer passed as its first argument; that means that we
;;; have to invoke the method via #_objc_msgSend_stret in the #+apple-objc
;;; case.

(defmacro objc-message-send-stret (structptr receiver selector-name &rest argspecs)
  (if (evenp (length argspecs))
    (setq argspecs (append argspecs '(:void)))
    (unless (member (car (last argspecs)) '(:void nil))
      (error "Invalid result spec for structure return: ~s"
	     (car (last argspecs)))))
  #+apple-objc
  `(external-call "_objc_msgSend_stret"
    :address ,structptr
    :id ,receiver
    :<SEL> (@selector ,selector-name)
    ,@argspecs)
    #+gnu-objc
    (let* ((r (gensym))
	 (s (gensym))
	 (imp (gensym)))
    `(with-macptrs ((,r ,receiver)
		    (,s (@selector ,selector-name))
		    (,imp (external-call "objc_msg_lookup"
					 :id ,r
					 :<SEL> ,s
					 :<IMP>)))
      (ff-call ,imp :address ,structptr :id ,r :<SEL> ,s ,@argspecs))))

;;; #_objc_msgSendSuper is similar to #_objc_msgSend; its first argument
;;; is a pointer to a structure of type objc_super {self,  the defining
;;; class's superclass}.  It only makes sense to use this inside an
;;; objc method.
(defmacro objc-message-send-super (super selector-name &rest argspecs)
  (when (evenp (length argspecs))
    (setq argspecs (append argspecs '(:id))))
  #+apple-objc
  `(external-call "_objc_msgSendSuper"
    :address ,super
    :<SEL> (@selector ,selector-name)
    ,@argspecs)
  #+gnu-objc
  (let* ((sup (gensym))
	 (sel (gensym))
	 (imp (gensym)))
    `(with-macptrs ((,sup ,super)
		    (,sel (@selector ,selector-name))
		    (,imp (external-call "objc_msg_lookup_super"
					 :<S>uper_t ,sup
					 :<SEL> ,sel
					 :<IMP>)))
      (ff-call ,imp
       :id (pref ,sup :<S>uper.self)
       :<SEL> ,sel
       ,@argspecs))))

;;; Send to superclass method, returning a structure.
(defmacro objc-message-send-super-stret
    (structptr super selector-name &rest argspecs)
  (if (evenp (length argspecs))
    (setq argspecs (append argspecs '(:void)))
    (unless (member (car (last argspecs)) '(:void nil))
      (error "Invalid result spec for structure return: ~s"
	     (car (last argspecs)))))
  #+apple-objc
  `(external-call "_objc_msgSendSuper_stret"
    :address ,structptr
    :address ,super
    :<SEL> (@selector ,selector-name)
    ,@argspecs)
  #+gnu-objc
  (let* ((sup (gensym))
	 (sel (gensym))
	 (imp (gensym)))
    `(with-macptrs ((,sup ,super)
		    (,sel (@selector ,selector-name))
		    (,imp (external-call "objc_msg_lookup_super"
					 :<S>uper_t ,sup
					 :<SEL> ,sel
					 :<IMP>)))
      (ff-call ,imp
       :address ,structptr
       :id (pref ,sup :<S>uper.self)
       :<SEL> ,sel
       ,@argspecs))))



;;; The first 8 words of non-fp arguments get passed in R3-R10
(defvar *objc-gpr-offsets*
  #(4 8 12 16 20 24 28 32))

;;; The first 13 fp arguments get passed in F1-F13 (and also "consume"
;;; a GPR or two.)  It's certainly possible for an FP arg and a non-
;;; FP arg to share the same "offset", and parameter offsets aren't
;;; strictly increasing.
(defvar *objc-fpr-offsets*
  #(36 44 52 60 68 76 84 92 100 108 116 124 132))

;;; Just to make things even more confusing: once we've filled in the
;;; first 8 words of the parameter area, args that aren't passed in
;;; FP-regs get assigned offsets starting at 32.  That almost makes
;;; sense (even though it conflicts with the last offset in
;;; *objc-gpr-offsets* (assigned to R10), but we then have to add
;;; this constant to the memory offset.
(defconstant objc-forwarding-stack-offset 8)

(defvar *objc-id-type* (parse-foreign-type :id))
(defvar *objc-sel-type* (parse-foreign-type :<SEL>))
(defvar *objc-char-type* (parse-foreign-type :char))

(defun encode-objc-type (type &optional for-ivar)
  (if (or (eq type *objc-id-type*)
	  (foreign-type-= type *objc-id-type*))
    "@"
    (if (or (eq type *objc-sel-type*)
	    (foreign-type-= type *objc-sel-type*))
      ":"
      (if (eq (foreign-type-class type) 'root)
	"v"
	(typecase type
	  (foreign-pointer-type
	   (let* ((target (foreign-pointer-type-to type)))
	     (if (or (eq target *objc-char-type*)
		     (foreign-type-= target *objc-char-type*))
	       "*"
	       (format nil "^~a" (encode-objc-type target)))))
	  (foreign-double-float-type "d")
	  (foreign-single-float-type "f")
	  (foreign-integer-type
	   (let* ((signed (foreign-integer-type-signed type))
		  (bits (foreign-integer-type-bits type)))
	     (if (eq (foreign-integer-type-alignment type) 1)
	       (format nil "b~d" bits)
	       (cond ((= bits 8)
		      (if signed "c" "C"))
		     ((= bits 16)
		      (if signed "s" "S"))
		     ((= bits 32)
		      ;; Should be some way of noting "longness".
		      (if signed "i" "I"))
		     ((= bits 64)
		      (if signed "q" "Q"))))))
	  (foreign-record-type
	   (ensure-foreign-type-bits type)
	   (let* ((name (unescape-foreign-name
			 (or (foreign-record-type-name type) "?")))
		  (kind (foreign-record-type-kind type))
		  (fields (foreign-record-type-fields type)))
	     (with-output-to-string (s)
				    (format s "~c~a=" (if (eq kind :struct) #\{ #\() name)
				    (dolist (f fields (format s "~a" (if (eq kind :struct) #\} #\))))
				      (when for-ivar
					(format s "\"~a\""
						(unescape-foreign-name
						 (or (foreign-record-field-name f) "")))
					(format s "~a" (encode-objc-type
							(foreign-record-field-type f))))))))
	  (foreign-array-type
	   (ensure-foreign-type-bits type)
	   (let* ((dims (foreign-array-type-dimensions type))
		  (element-type (foreign-array-type-element-type type)))
	     (if dims (format nil "[~d~a]"
			      (car dims)
			      (encode-objc-type element-type))
	       (if (or (eq element-type *objc-char-type*)
		       (foreign-type-= element-type *objc-char-type*))
		 "*"
		 (format nil "^~a" (encode-objc-type element-type))))))
	  (t (break "type = ~s" type)))))))
		 
(defun encode-objc-method-arglist (arglist result-spec)
  (let* ((gprs-used 0)
	 (fprs-used 0)
	 (arg-info
	  (flet ((current-memory-arg-offset ()
		   (+ 32 (* 4 (- gprs-used 8))
		      objc-forwarding-stack-offset)))
	    (flet ((current-gpr-arg-offset ()
		     (if (< gprs-used 8)
		       (svref *objc-gpr-offsets* gprs-used)
		       (current-memory-arg-offset)))
		   (current-fpr-arg-offset ()
		     (if (< fprs-used 13)
		       (svref *objc-fpr-offsets* fprs-used)
		       (current-memory-arg-offset))))
	      (let* ((result nil))
		(dolist (argspec arglist (nreverse result))
		  (let* ((arg (parse-foreign-type argspec))
			 (offset 0)
			 (size 0))
		    (typecase arg
		      (foreign-double-float-type
		       (setq size 8 offset (current-fpr-arg-offset))
		       (incf fprs-used)
		       (incf gprs-used 2))
		      (foreign-single-float-type
		       (setq size 4 offset (current-fpr-arg-offset))
		       (incf fprs-used)
		       (incf gprs-used 1))
		      (foreign-pointer-type
		       (setq size 4 offset (current-gpr-arg-offset))
		       (incf gprs-used))
		      (foreign-integer-type
		       (let* ((bits (foreign-type-bits arg)))
			 (setq size (ceiling bits 8)
			       offset (current-gpr-arg-offset))
			 (incf gprs-used (ceiling bits 32))))
		      ((or foreign-record-type foreign-array-type)
		       (let* ((bits (ensure-foreign-type-bits arg)))
			 (setq size (ceiling bits 8)
			       offset (current-gpr-arg-offset))
			 (incf gprs-used (ceiling bits 32))))
		      (t (break "argspec = ~s, arg = ~s" argspec arg)))
		    (push (list (encode-objc-type arg) offset size) result))))))))
    (declare (fixnum gprs-used fprs-used))
    (let* ((max-parm-end
	    (- (apply #'max (mapcar #'(lambda (i) (+ (cadr i) (caddr i)))
				    arg-info))
	       objc-forwarding-stack-offset)))
      (format nil "~a~d~:{~a~d~}"
	      (encode-objc-type
	       (parse-foreign-type result-spec))
	      max-parm-end
	      arg-info))))

;;; In Apple Objc, a class's methods are stored in a (-1)-terminated
;;; vector of method lists.  In GNU ObjC, method lists are linked
;;; together.
(defun %make-method-vector ()
  #+apple-objc
  (let* ((method-vector (malloc 16)))
    (setf (%get-signed-long method-vector 0) 0
	  (%get-signed-long method-vector 4) 0
	  (%get-signed-long method-vector 8) 0
	  (%get-signed-long method-vector 12) -1)
    method-vector))
  

;;; Make a meta-class object (with no instance variables or class
;;; methods.)
(defun %make-basic-meta-class (nameptr superptr rootptr)
  #+apple-objc
  (let* ((method-vector (%make-method-vector)))
    (make-record :objc_class
		 :isa (pref rootptr :objc_class.isa)
		 :super_class (pref superptr :objc_class.isa)
		 :name nameptr
		 :version 0
		 :info #$CLS_META
		 :instance_size 0
		 :ivars (%null-ptr)
		 :method<L>ists method-vector
		 :cache (%null-ptr)
		 :protocols (%null-ptr)))
  #+gnu-objc
  (make-record :objc_class
               :class_pointer (pref rootptr :objc_class.class_pointer)
               :super_class (pref superptr :objc_class.class_pointer)
               :name nameptr
               :version 0
               :info #$_CLS_META
               :instance_size 0
               :ivars (%null-ptr)
               :methods (%null-ptr)
               :dtable (%null-ptr)
               :subclass_list (%null-ptr)
               :sibling_class (%null-ptr)
               :protocols (%null-ptr)
               :gc_object_type (%null-ptr)))

(defun %make-class-object (metaptr superptr nameptr ivars instance-size)
  #+apple-objc
  (let* ((method-vector (%make-method-vector)))
    (make-record :objc_class
		 :isa metaptr
		 :super_class superptr
		 :name nameptr
		 :version 0
		 :info #$CLS_CLASS
		 :instance_size instance-size
		 :ivars ivars
		 :method<L>ists method-vector
		 :cache (%null-ptr)
		 :protocols (%null-ptr)))
  #+gnu-objc
  (make-record :objc_class
		 :class_pointer metaptr
		 :super_class superptr
		 :name nameptr
		 :version 0
		 :info #$_CLS_CLASS
		 :instance_size instance-size
		 :ivars ivars
		 :methods (%null-ptr)
		 :dtable (%null-ptr)
		 :protocols (%null-ptr)))

(defun superclass-instance-size (class)
  (with-macptrs ((super (pref class :objc_class.super_class)))
    (if (%null-ptr-p super)
      0
      (pref super :objc_class.instance_size))))

	


#+gnu-objc
(progn
(defloadvar *gnu-objc-runtime-mutex*
    (%get-ptr (foreign-symbol-address "__objc_runtime_mutex")))
(defmacro with-gnu-objc-mutex-locked ((mutex) &body body)
  (let* ((mname (gensym)))
    `(let ((,mname ,mutex))
      (unwind-protect
	   (progn
	     (external-call "objc_mutex_lock" :address ,mname :void)
	     ,@body)
	(external-call "objc_mutex_lock" :address ,mname :void)))))
)

(defun %objc-metaclass-p (class)
  (logtest (pref class :objc_class.info)
	   #+apple-objc #$CLS_META
	   #+gnu-objc #$_CLS_META))
	   
(defun %objc-class-posing-p (class)
  (logtest (pref class :objc_class.info)
	   #+apple-objc #$CLS_POSING
	   #+gnu-objc #$_CLS_POSING))




;;; Create (malloc) class and metaclass objects with the specified
;;; name (string) and superclass name.  Initialize the metaclass
;;; instance, but don't install the class in the ObjC runtime system
;;; (yet): we don't know anything about its ivars and don't know
;;; how big instances will be yet.
;;; If an ObjC class with this name already exists, we're very
;;; confused; check for that case and error out if it occurs.
(defun %allocate-objc-class (name superptr)
  (let* ((class-name (compute-objc-classname name)))
    (if (lookup-objc-class class-name nil)
      (error "An Objective C class with name ~s already exists." class-name))
    (let* ((nameptr (make-cstring class-name))
	   (id (register-objc-class
		(%make-class-object
		 (%make-basic-meta-class nameptr superptr (@class "NSObject"))
		 superptr
		 nameptr
		 (%null-ptr)
		 0)))
	   (meta-id (objc-class-id->objc-metaclass-id id))
	   (meta (id->objc-metaclass meta-id))
	   (class (id->objc-class id))
	   (meta-name (intern (format nil "+~a" name)
			      (symbol-package name)))
	   (meta-super (canonicalize-registered-metaclass
			(pref meta :objc_class.super_class))))
      (initialize-instance meta
			 :name meta-name
			 :direct-superclasses (list meta-super))
      (setf (objc-class-id-foreign-name id) class-name
	    (objc-metaclass-id-foreign-name meta-id) class-name
	    (find-class meta-name) meta)
    class)))

;;; Set up the class's ivar_list and instance_size fields, then
;;; add the class to the ObjC runtime.
(defun %add-objc-class (class ivars instance-size)
  (setf
   (pref class :objc_class.ivars) ivars
   (pref class :objc_class.instance_size) instance-size)
  #+apple-objc
  (#_objc_addClass class)
  #+gnu-objc
  ;; Why would anyone want to create a class without creating a Module ?
  ;; Rather than ask that vexing question, let's create a Module with
  ;; one class in it and use #___objc_exec_class to add the Module.
  ;; (I mean "... to add the class", of course.
  ;; It appears that we have to heap allocate the module, symtab, and
  ;; module name: the GNU ObjC runtime wants to add the module to a list
  ;; that it subsequently ignores.
  (let* ((name (make-cstring "Phony Module"))
	 (symtab (malloc (+ (record-length :objc_symtab) (record-length (:* :void)))))
	 (m (make-record :objc_module
			 :version 8 #|OBJC_VERSION|#
			 :size (record-length :<M>odule)
			 :name name
			 :symtab symtab)))
    (setf (%get-ptr symtab (record-length :objc_symtab)) (%null-ptr))
    (setf (pref symtab :objc_symtab.sel_ref_cnt) 0
	  (pref symtab :objc_symtab.refs) (%null-ptr)
	  (pref symtab :objc_symtab.cls_def_cnt) 1
	  (pref symtab :objc_symtab.cat_def_cnt) 0
	  (%get-ptr (pref symtab :objc_symtab.defs)) class
	  (pref class :objc_class.info) (logior #$_CLS_RESOLV (pref class :objc_class.info)))
    (#___objc_exec_class m)))



;;; Return the "canonical" version of P iff it's a known ObjC class
(defun objc-class-p (p)
  (if (typep p 'macptr)
    (let* ((id (objc-class-id p)))
      (if id (id->objc-class id)))))

;;; Return the canonical version of P iff it's a known ObjC metaclass
(defun objc-metaclass-p (p)
  (if (typep p 'macptr)
    (let* ((id (objc-metaclass-id p)))
      (if id (id->objc-metaclass id)))))

;;; If P is an ObjC instance, return a pointer to its class.
;;; This assumes that all instances are allocated via something that's
;;; ultimately malloc-based.
(defun objc-instance-p (p)
  (when (typep p 'macptr)
    (let* ((idx (%objc-instance-class-index p)))
      (if idx (id->objc-class  idx)))))


#+apple-objc
(defun zone-pointer-size (p)
  (with-macptrs ((zone (#_malloc_zone_from_ptr p)))
    (unless (%null-ptr-p zone)
      (let* ((size (ff-call (pref zone :malloc_zone_t.size)
			    :address zone
			    :address p
			    :int)))
	(declare (fixnum size))
	(unless (zerop size)
	  size)))))
  
(defun %objc-instance-class-index (p)
  #+apple-objc
  (if (or (pointer-in-cfstring-section-p p)
	  (with-macptrs ((zone (#_malloc_zone_from_ptr p)))
	    (not (%null-ptr-p zone))))
    (with-macptrs ((parent (pref p :objc_object.isa)))
      (objc-class-id parent)))
  #+gnu-objc
  (with-macptrs ((parent (pref p objc_object.class_pointer)))
    (objc-class-id-parent))
  )

;;; If an instance, return (values :INSTANCE <class>)
;;; If a class, return (values :CLASS <class>).
;;; If a metaclass, return (values :METACLASS <metaclass>).
;;; Else return (values NIL NIL).
(defun objc-object-p (p)
  (let* ((instance-p (objc-instance-p p)))
    (if instance-p
      (values :instance instance-p)
      (let* ((class-p (objc-class-p p)))
	(if class-p
	  (values :class class-p)
	  (let* ((metaclass-p (objc-metaclass-p p)))
	    (if metaclass-p
	      (values :metaclass metaclass-p)
	      (values nil nil))))))))

       

;;; Stub until BRIDGE is loaded
(defun update-type-signatures-for-method (m c) (declare (ignore m c)))


;;; If the class contains an mlist that contains a method that
;;; matches (is EQL to) the selector, remove the mlist and
;;; set its IMP; return the containing mlist.
;;; If the class doesn't contain any matching mlist, create
;;; an mlist with one method slot, initialize the method, and
;;; return the new mlist.  Doing it this way ensures
;;; that the objc runtime will invalidate any cached references
;;; to the old IMP, at least as far as objc method dispatch is
;;; concerned.
(defun %mlist-containing (classptr selector typestring imp)
  #-apple-objc (declare (ignore classptr selector typestring imp))
  #+apple-objc
  (%stack-block ((iter 4))
    (setf (%get-ptr iter) (%null-ptr))
    (loop
	(let* ((mlist (#_class_nextMethodList classptr iter)))
	  (when (%null-ptr-p mlist)
	    (let* ((mlist (make-record :objc_method_list
				       :method_count 1))
		   (method (pref mlist :objc_method_list.method_list)))
	      (setf (pref method :objc_method.method_name) selector
		    (pref method :objc_method.method_types)
		    (make-cstring typestring)
		    (pref method :objc_method.method_imp) imp)
              (update-type-signatures-for-method method classptr)
	      (return mlist)))
	  (do* ((n (pref mlist :objc_method_list.method_count))
		(i 0 (1+ i))
		(method (pref mlist :objc_method_list.method_list)
			(%incf-ptr method (record-length :objc_method))))
	       ((= i n))
	    (declare (fixnum i n))
	    (when (eql selector (pref method :objc_method.method_name))
	      (#_class_removeMethods classptr mlist)
	      (setf (pref method :objc_method.method_imp) imp)
	      (return-from %mlist-containing mlist)))))))
	      

(defun %add-objc-method (classptr selector typestring imp)
  #+apple-objc
  (#_class_addMethods classptr
		      (%mlist-containing classptr selector typestring imp))
  #+gnu-objc
  ;;; We have to do this ourselves, and have to do it with the runtime
  ;;; mutex held.
  (with-gnu-objc-mutex-locked (*gnu-objc-runtime-mutex*)
    (let* ((ctypestring (make-cstring typestring))
	   (new-mlist nil))
      (with-macptrs ((method (external-call "search_for_method_in_list"
			      :address (pref classptr :objc_class.methods)
			      :address selector
			      :address)))
	(when (%null-ptr-p method)
	  (setq new-mlist (make-record :objc_method_list :method_count 1))
	  (%setf-macptr method (pref new-mlist :objc_method_list.method_list)))
	(setf (pref method :objc_method.method_name) selector
	      (pref method :objc_method.method_types) ctypestring
	      (pref method :objc_method.method_imp) imp)
	(if new-mlist
	  (external-call "GSObjCAddMethods"
			 :address classptr
			 :address new-mlist
			 :void)
	  (external-call "__objc_update_dispatch_table_for_class"
			 :address classptr
			 :void))
	(update-type-signatures-for-method (%inc-ptr method 0) classptr)))))

(defvar *lisp-objc-methods* (make-hash-table :test #'eq))

(defstruct lisp-objc-method
  class-descriptor
  sel
  typestring
  class-p				;t for class methods
  imp					; callback ptr
  )

(defun %add-lisp-objc-method (m)
  (let* ((class (%objc-class-classptr (lisp-objc-method-class-descriptor m)))
	 (sel (%get-selector (lisp-objc-method-sel m)))
	 (typestring (lisp-objc-method-typestring m))
	 (imp (lisp-objc-method-imp m)))
    (%add-objc-method
     (if (lisp-objc-method-class-p m)
       (pref class #+apple-objc :objc_class.isa #+gnu-objc :objc_class.class_pointer)
       class)
     sel
     typestring
     imp)))

(def-ccl-pointers add-objc-methods ()
  (maphash #'(lambda (impname m)
	       (declare (ignore impname))
	       (%add-lisp-objc-method m))
	   *lisp-objc-methods*))

(defun %define-lisp-objc-method (impname classname selname typestring imp
					 &optional class-p)
  (%add-lisp-objc-method
   (setf (gethash impname *lisp-objc-methods*)
	 (make-lisp-objc-method
	  :class-descriptor (load-objc-class-descriptor classname)
	  :sel (load-objc-selector selname)
	  :typestring typestring
	  :imp imp
	  :class-p class-p)))
  impname)
    




;;; If any of the argspecs denote a value of type :<BOOL>, push an
;;; appropriate SETQ on the front of the body.  (Order doesn't matter.)
(defun coerce-foreign-boolean-args (argspecs body)
  (do* ((argspecs argspecs (cddr argspecs))
	(type (car argspecs) (car argspecs))
	(var (cadr argspecs) (cadr argspecs)))
       ((null argspecs) body)
    (when (eq type :<BOOL>)
      (push `(setq ,var (not (eql ,var 0))) body))))
      
(defun lisp-boolean->foreign-boolean (form)
  (let* ((val (gensym)))
    `((let* ((,val (progn ,@form)))
	(if (and ,val (not (eql 0 ,val))) 1 0)))))

;;; Return, as multiple values:
;;;  the selector name, as a string
;;;  the ObjC class name, as a string
;;;  the foreign result type
;;;  the foreign argument type/argument list
;;;  the body
;;;  a string which encodes the foreign result and argument types
(defun parse-objc-method (selector-arg class-arg body)
  (let* ((class-name (objc-class-name-string class-arg))
	 (selector-form selector-arg)
	 (selector nil)
	 (argspecs nil)
	 (resulttype nil))
    (flet ((bad-selector (why) (error "Can't parse method selector ~s : ~a"
				   selector-arg why)))
      (typecase selector-form
	(string
	 (let* ((specs (pop body)))
	     (setq selector selector-form)
	     (if (evenp (length specs))
	       (setq argspecs specs resulttype :id)
	       (setq resulttype (car (last specs))
		     argspecs (butlast specs)))))
	(cons				;sic
	 (setq resulttype (pop selector-form))
	 (unless (consp selector-form)
	   (bad-selector "selector-form not a cons"))
	 (ccl::collect ((components)
			 (specs))
	   ;; At this point, selector-form should be either a list of
	   ;; a single symbol (a lispified version of the selector name
	   ;; of a selector that takes no arguments) or a list of keyword/
	   ;; variable pairs.  Each keyword is a lispified component of
	   ;; the selector name; each "variable" is either a symbol
	   ;; or a list of the form (<foreign-type> <symbol>), where
	   ;; an atomic variable is shorthand for (:id <symbol>).
	   (if (and (null (cdr selector-form))
		    (car selector-form)
		    (typep (car selector-form) 'symbol)
		    (not (typep (car selector-form) 'keyword)))
	     (components (car selector-form))
	     (progn
	       (unless (evenp (length selector-form))
		 (bad-selector "Odd length"))
	       (do* ((s selector-form (cddr s))
		     (comp (car s) (car s))
		     (var (cadr s) (cadr s)))
		    ((null s))
		 (unless (typep comp 'keyword) (bad-selector "not a keyword"))
		 (components comp)
		 (cond ((atom var)
			(unless (and var (symbolp var))
			  (bad-selector "not a non-null symbol"))
			(specs :id)
			(specs var))
		       ((and (consp (cdr var))
			     (null (cddr var))
			     (cadr var)
			     (symbolp (cadr var)))
			(specs (car var))
			(specs (cadr var)))
		       (t (bad-selector "bad variable/type clause"))))))
	   (setq argspecs (specs)
		 selector (lisp-to-objc-message (components)))))
	(t (bad-selector "general failure")))
      ;; If the result type is of the form (:STRUCT <typespec> <name>),
      ;; make <name> be the first argument (of type :address) and
      ;; make the resulttype :void
      (when (and (consp resulttype)
		 (eq (car resulttype) :struct))
	(destructuring-bind (typespec name) (cdr resulttype)
	(if (and (typep name 'symbol)
		 (typep (parse-foreign-type typespec)
			'foreign-record-type))
	  (progn
	    (push name argspecs)
	    (push :address argspecs)
	    (setq resulttype :void))
	  (bad-selector "Bad struct return type"))))
      (values selector
	      class-name
	      resulttype
	      argspecs
	      body
	      (do* ((argtypes ())
		    (argspecs argspecs (cddr argspecs)))
		   ((null argspecs) (encode-objc-method-arglist
				     `(:id :<sel> ,@(nreverse argtypes))
				     resulttype))
		(push (car argspecs) argtypes))))))

(defun objc-method-definition-form (class-p selector-arg class-arg body env)
  (multiple-value-bind (selector-name
			class-name
			resulttype
			argspecs
			body
			typestring)
      (parse-objc-method selector-arg class-arg body)
      (multiple-value-bind (body decls) (parse-body body env)
	(setq body (coerce-foreign-boolean-args argspecs body))
	(if (eq resulttype :<BOOL>)
	  (setq body (lisp-boolean->foreign-boolean body)))
	(let* ((impname (intern (format nil "~c[~a ~a]"
					(if class-p #\+ #\-)
					class-name
					selector-name)))
	       (self (intern "SELF"))
	       (_cmd (intern "_CMD"))
	       (super (gensym "SUPER")) 
	       (params `(:id ,self :<sel> ,_cmd ,@argspecs)))
	  `(progn
	    (defcallback ,impname
		    (:without-interrupts nil
					 #+(and openmcl-native-threads apple-objc) :error-return
					 #+(and openmcl-native-threads apple-objc)  (condition objc-callback-error-return) ,@params ,resulttype)
		  (declare (ignorable ,_cmd))
		  ,@decls
		  (rlet ((,super :objc_super
			   #+apple-objc :receiver #+gnu-objc :self ,self
			   :class
			   ,@(if class-p
				 `((pref
				    (pref (@class ,class-name)
				     #+apple-objc :objc_class.isa
				     #+gnu-objc :objc_class.super_class )
				    :objc_class.super_class))
				 `((pref (@class ,class-name) :objc_class.super_class)))))
		    (macrolet ((send-super (msg &rest args &environment env) 
				 (make-optimized-send nil msg args env nil ',super ,class-name))
			       (send-super/stret (s msg &rest args &environment env) 
				 (make-optimized-send nil msg args env s ',super ,class-name)))
		      (flet ((%send-super (msg &rest args)
			       (make-general-send nil msg args nil ,super ,class-name))
			     (%send-super/stret (s msg &rest args)
			       (make-general-send nil msg args s ,super ,class-name))
			     (super () ,super))
			,@body))))
	    (%define-lisp-objc-method
	     ',impname
	     ,class-name
	     ,selector-name
	     ,typestring
	     ,impname
	     ,class-p))))))

(defmacro define-objc-method ((selector-arg class-arg)
			      &body body &environment env)
  (objc-method-definition-form nil selector-arg class-arg body env))

(defmacro define-objc-class-method ((selector-arg class-arg)
				     &body body &environment env)
  (objc-method-definition-form t selector-arg class-arg body env))

(defun class-get-instance-method (class sel)
  #+apple-objc (progn
		 (unless (logtest #$CLS_INITIALIZED (pref (pref class :objc_class.isa)  :objc_class.info))
		   ;; Do this for effect; ignore the :<IMP> it returns.
		   ;; (It should cause the CLS_NEED_BIND flag to turn itself
		   ;; off after the class has been initialized; we need
		   ;; the class and all superclasses to have been initialized,
		   ;; so that we can find category methods via
		   ;; #_class_getInstanceMethod.
		   (external-call "_class_lookupMethod"
				  :id class
				  :<SEL> sel
				  :address))
		 (#_class_getInstanceMethod class sel))
  #+gnu-objc (#_class_get_instance_method class sel))

(defun class-get-class-method (class sel)
  #+apple-objc (#_class_getClassMethod class sel)
  #+gnu-objc   (#_class_get_class_method class sel))

(defun method-get-number-of-arguments (m)
  #+apple-objc (#_method_getNumberOfArguments m)
  #+gnu-objc (#_method_get_number_of_arguments m))

#+apple-objc
(progn
(defloadvar *original-deallocate-hook*
    (%get-ptr (foreign-symbol-address "__dealloc")))

(defcallback deallocate-nsobject (:address obj :int)
  (unless (%null-ptr-p obj)
        (remhash obj *objc-object-slot-vectors*)
    (ff-call *original-deallocate-hook* :address obj :int)))

(defun install-lisp-deallocate-hook ()
  (setf (%get-ptr (foreign-symbol-address "__dealloc")) deallocate-nsobject))

(def-ccl-pointers install-deallocate-hook ()
  (install-lisp-deallocate-hook))

(defun uninstall-lisp-deallocate-hook ()
  (clrhash *objc-object-slot-vectors*)
  (setf (%get-ptr (foreign-symbol-address "__dealloc")) *original-deallocate-hook*))

(pushnew #'uninstall-lisp-deallocate-hook *save-exit-functions* :test #'eq
         :key #'function-name)
)


;;; Return a typestring and offset as multiple values.

(defun objc-get-method-argument-info (m i)
  #+apple-objc
  (%stack-block ((type 4) (offset 4))
    (#_method_getArgumentInfo m i type offset)
    (values (%get-cstring (%get-ptr type)) (%get-signed-long offset)))
  #+gnu-objc
  (progn
    (with-macptrs ((typespec (#_objc_skip_argspec (pref m :objc_method.method_types))))
      (dotimes (j i (values (%get-cstring typespec)
			    (#_strtol (#_objc_skip_typespec typespec)
				      (%null-ptr)
				      10.)))
	(%setf-macptr typespec (#_objc_skip_argspec typespec))))))

  



(defloadvar *nsstring-newline* #@"
")


(defun retain-objc-instance (instance)
  (objc-message-send instance "retain"))

;;; Execute BODY with an autorelease pool

(defun create-autorelease-pool ()
  (objc-message-send
   (objc-message-send (@class "NSAutoreleasePool") "alloc") "init"))

(defun release-autorelease-pool (p)
  (objc-message-send p "release"))

(defmacro with-autorelease-pool (&body body)
  (let ((pool-temp (gensym)))
    `(let ((,pool-temp (create-autorelease-pool)))
      (unwind-protect
	   ,@body
	(release-autorelease-pool ,pool-temp)))))

;;; This can fail if the nsstring contains non-8-bit characters.
(defun lisp-string-from-nsstring (nsstring)
  (with-macptrs (cstring)
    (%setf-macptr cstring (objc-message-send nsstring "cString" (* :char)))
    (unless (%null-ptr-p cstring)
      (%get-cstring cstring))))

(defmacro with-ns-exceptions-as-errors (&body body)
  #+apple-objc
  (let* ((nshandler (gensym))
         (cframe (gensym)))
    `(rletZ ((,nshandler :<NSH>andler2))
      (unwind-protect
           (progn
             (external-call "__NSAddHandler2" :address ,nshandler :void)
             (catch ,nshandler
               (with-c-frame ,cframe
                 (%associate-jmp-buf-with-catch-frame
                  ,nshandler
                  (%fixnum-ref (%current-tcr) ppc32::tcr.catch-top)
                  ,cframe)
                 (progn
                   ,@body))))
        (check-ns-exception ,nshandler))))
  #+gnu-objc
  `(progn ,@body)
  )

#+apple-objc
(defun check-ns-exception (nshandler)
  (with-macptrs ((exception (external-call "__NSExceptionObjectFromHandler2"
                                           :address nshandler
                                           :address)))
    (if (%null-ptr-p exception)
      (external-call "__NSRemoveHandler2" :address nshandler :void)
      (error (ns-exception->lisp-condition (%inc-ptr exception 0))))))


