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

;;; This is a slightly-watered-down version of CMUCL's ALIEN-TYPE system.

(in-package "CCL")

(defstruct (interface-dir
	     (:include dll-node)
	     (:print-object
	      (lambda (d stream)
		(print-unreadable-object (d stream :type t :identity t)
		  (format stream "~s ~s"
			  (interface-dir-name d)
			  (interface-dir-subdir d))))))
  (name)
  (subdir)
  (constants-interface-db-file)
  (functions-interface-db-file)
  (records-interface-db-file)
  (types-interface-db-file))

  
;;; This is intended to try to encapsulate foreign type stuff, to
;;; ease cross-compilation (among other things.)

(defstruct (foreign-type-data (:conc-name ftd-)
			      (:constructor make-ftd))
  (translators (make-hash-table :test #'eq))
  (kind-info (make-hash-table :test #'eq))
  (definitions (make-hash-table :test #'eq))
  (struct-definitions (make-hash-table :test #'eq))
  (union-definitions (make-hash-table :test #'eq))
  ;; Do we even use this ?
  (enum-definitions (make-hash-table :test #'eq))
  (interface-db-directory
   #+linuxppc-target"ccl:headers;"
   #+darwinppc-target "ccl:darwin-headers;")
  (interface-package-name
   #+linuxppc-target "LINUX"
   #+darwinppc-target "DARWIN")
  (external-function-definitions (make-hash-table :test #'eq))
  (syscalls (make-hash-table :test #'eq))
  (dirlist (make-dll-header))
  (attributes #+darwinppc-target '(:signed-char :struct-by-value :prepend-underscores)
	      #+linuxppc-target ())
  (ordinal->type (make-array 100 :fill-pointer 1)))

(defvar *host-ftd* (make-ftd))
(defvar *target-ftd* *host-ftd*)
(setf (backend-target-foreign-type-data *host-backend*)
      *host-ftd*)

(defmacro do-interface-dirs ((dir &optional (ftd '*target-ftd*)) &body body)
  `(do-dll-nodes  (,dir (ftd-dirlist ,ftd))
    ,@body))

(defun find-interface-dir (name &optional (ftd *target-ftd*))
  (do-interface-dirs (d ftd)
    (when (eq name (interface-dir-name d))
      (return d))))

(defun require-interface-dir (name &optional (ftd *target-ftd*))
  (or (find-interface-dir name ftd)
      (error "Interface directory ~s not found" name)))

(defun ensure-interface-dir (name &optional (ftd *target-ftd*))
  (or (find-interface-dir name ftd)
      (let* ((d (make-interface-dir
		 :name name
		 :subdir (make-pathname
			  :directory
			  `(:relative ,(string-downcase name))))))
	(append-dll-node d (ftd-dirlist ftd)))))

(defun use-interface-dir (name &optional (ftd *target-ftd*))
  (let* ((d (ensure-interface-dir name ftd)))
    (move-dll-nodes d (ftd-dirlist ftd))
    d))

(defun unuse-interface-dir (name &optional (ftd *target-ftd*))
  (let* ((d (find-interface-dir name ftd)))
    (when d
      (remove-dll-node d)
      t)))


(use-interface-dir :libc)


;;;; Utility functions.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun align-offset (offset alignment)
    (let ((extra (rem offset alignment)))
      (if (zerop extra) offset (+ offset (- alignment extra)))))

  (defun guess-alignment (bits)
    (cond ((null bits) nil)
          ((> bits 32) 64)
          ((> bits 16) 32)
          ((> bits 8) 16)
          ((> bits 1) 8)
          (t 1)))

  (defstruct (foreign-type-class
	       (:print-object
		(lambda (f out)
		  (print-unreadable-object (f out :type t :identity t)
		    (prin1 (foreign-type-class-name f) out)))))
    (name nil :type symbol)
    (include nil :type (or null foreign-type-class))
    (unparse nil :type (or null function))
    (type= nil :type (or null function))
    (lisp-rep nil :type (or null function))
    (foreign-rep nil :type (or null function))
    (extract-gen nil :type (or null function))
    (deposit-gen nil :type (or null function))
    (naturalize-gen nil :type (or null function))
    (deport-gen nil :type (or null function))
    ;; Cast?
    (arg-tn nil :type (or null function))
    (result-tn nil :type (or null function))
    (subtypep nil :type (or null function)))


  (defvar *foreign-type-classes* (make-hash-table :test #'eq))
  
  (defun info-foreign-type-translator (x)
    (gethash (make-keyword x) (ftd-translators *target-ftd*)))
  (defun (setf info-foreign-type-translator) (val x)
    (setf (gethash (make-keyword x) (ftd-translators *target-ftd*)) val))

  (defun info-foreign-type-kind (x)
    (or (gethash (make-keyword x) (ftd-kind-info *target-ftd*)) :unknown))
  (defun (setf info-foreign-type-kind) (val x)
    (setf (gethash (make-keyword x) (ftd-kind-info *target-ftd*)) val))
		   
  (defun info-foreign-type-definition (x)
    (gethash (make-keyword x) (ftd-definitions *target-ftd*)))
  (defun (setf info-foreign-type-definition) (val x)
    (setf (gethash (make-keyword x) (ftd-definitions *target-ftd*)) val))
  (defun clear-info-foreign-type-definition (x)
    (remhash (make-keyword x) (ftd-definitions *target-ftd*)))

  (defun info-foreign-type-struct (x)
    (gethash (make-keyword x) (ftd-struct-definitions *target-ftd*)))
  (defun (setf info-foreign-type-struct) (val x)
    (setf (gethash (make-keyword x) (ftd-struct-definitions *target-ftd*)) val))

  (defun info-foreign-type-union (x)
    (gethash (make-keyword x) (ftd-union-definitions *target-ftd*)))
  (defun (setf info-foreign-type-union) (val x)
    (setf (gethash (make-keyword x) (ftd-union-definitions *target-ftd*)) val))

  (defun info-foreign-type-enum (x)
    (gethash (make-keyword x) (ftd-enum-definitions *target-ftd*)))
  (defun (setf info-foreign-type-enum) (val x)
    (setf (gethash (make-keyword x) (ftd-enum-definitions *target-ftd*)) val))



  (defun require-foreign-type-class (name)
    (or (gethash name  *foreign-type-classes*)
        (error "Unknown foreign type class ~s" name)))

  (defun find-or-create-foreign-type-class (name include)
    (let* ((old (gethash name *foreign-type-classes*))
           (include-class (if include (require-foreign-type-class include))))
      (if old
        (setf (foreign-type-class-name old) include-class)
        (setf (gethash name *foreign-type-classes*)
              (make-foreign-type-class :name name :include include-class)))))


  (defconstant method-slot-alist
    '((:unparse . foreign-type-class-unparse)
      (:type= . foreign-type-class-type=)
      (:subtypep . foreign-type-class-subtypep)
      (:lisp-rep . foreign-type-class-lisp-rep)
      (:foreign-rep . foreign-type-class-foreign-rep)
      (:extract-gen . foreign-type-class-extract-gen)
      (:deposit-gen . foreign-type-class-deposit-gen)
      (:naturalize-gen . foreign-type-class-naturalize-gen)
      (:deport-gen . foreign-type-class-deport-gen)
      ;; Cast?
      (:arg-tn . foreign-type-class-arg-tn)
      (:result-tn . foreign-type-class-result-tn)))

  (defun method-slot (method)
    (cdr (or (assoc method method-slot-alist)
             (error "No method ~S" method))))
  )


;;; We define a keyword "BOA" constructor so that we can reference the slots
;;; names in init forms.
;;;
(defmacro def-foreign-type-class ((name &key include include-args) &rest slots)
  (let ((defstruct-name
	 (intern (concatenate 'string "FOREIGN-" (symbol-name name) "-TYPE"))))
    (multiple-value-bind
	(include include-defstruct overrides)
	(etypecase include
	  (null
	   (values nil 'foreign-type nil))
	  (symbol
	   (values
	    include
	    (intern (concatenate 'string
				 "FOREIGN-" (symbol-name include) "-TYPE"))
	    nil))
	  (list
	   (values
	    (car include)
	    (intern (concatenate 'string
				 "FOREIGN-" (symbol-name (car include)) "-TYPE"))
	    (cdr include))))
      `(progn
	 (eval-when (:compile-toplevel :load-toplevel :execute)
	   (find-or-create-foreign-type-class ',name ',(or include 'root)))
	 (defstruct (,defstruct-name
			(:include ,include-defstruct
				  (class ',name)
				  ,@overrides)
			(:constructor
			 ,(intern (concatenate 'string "MAKE-"
					       (string defstruct-name)))
			 (&key class bits alignment
			       ,@(mapcar #'(lambda (x)
					     (if (atom x) x (car x)))
					 slots)
			       ,@include-args)))
	   ,@slots)))))

(defmacro def-foreign-type-method ((class method) lambda-list &rest body)
  (let ((defun-name (intern (concatenate 'string
					 (symbol-name class)
					 "-"
					 (symbol-name method)
					 "-METHOD"))))
    `(progn
       (defun ,defun-name ,lambda-list
	 ,@body)
       (setf (,(method-slot method) (require-foreign-type-class ',class))
	     #',defun-name))))

(defmacro invoke-foreign-type-method (method type &rest args)
  (let ((slot (method-slot method)))
    (once-only ((type type))
      `(funcall (do ((class (require-foreign-type-class (foreign-type-class ,type))
			    (foreign-type-class-include class)))
		    ((null class)
		     (error "Method ~S not defined for ~S"
			    ',method (foreign-type-class ,type)))
		  (let ((fn (,slot class)))
		    (when fn
		      (return fn))))
		,type ,@args))))


;;;; Foreign-type defstruct.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (find-or-create-foreign-type-class 'root nil))

(defstruct (foreign-type
	    (:constructor make-foreign-type (&key class bits alignment))
	    (:print-object
	     (lambda (s out)
	       (print-unreadable-object (s out :type t :identity t)
		 (prin1 (unparse-foreign-type s) out)))))
  (class 'root :type symbol)
  (bits nil :type (or null unsigned-byte))
  (alignment (guess-alignment bits) :type (or null unsigned-byte))
  (assigned-ordinal nil))

(defun foreign-type-ordinal (ftype)
  (or (foreign-type-assigned-ordinal ftype)
      (setf (foreign-type-assigned-ordinal ftype)
	    (vector-push-extend ftype (ftd-ordinal->type *target-ftd*)))))

(defun ordinal-to-foreign-type (ordinal &optional (ftd *target-ftd*))
  (elt (ftd-ordinal->type ftd) ordinal))


(defmethod make-load-form ((s foreign-type) &optional env)
  (make-load-form-saving-slots s :environment env))






;;;; Type parsing and unparsing.

(defvar *auxiliary-type-definitions* nil)
(defvar *new-auxiliary-types*)

;;; WITH-AUXILIARY-FOREIGN-TYPES -- internal.
;;;
;;; Process stuff in a new scope.
;;;
(defmacro with-auxiliary-foreign-types (&body body)
  `(let ((*auxiliary-type-definitions*
	  (if (boundp '*new-auxiliary-types*)
	      (append *new-auxiliary-types* *auxiliary-type-definitions*)
	      *auxiliary-type-definitions*))
	 (*new-auxiliary-types* nil))
     ,@body))

;;; PARSE-FOREIGN-TYPE -- public
;;;
(defun parse-foreign-type (type)
  "Parse the list structure TYPE as a foreign type specifier and return
   the resultant foreign-type structure."
  (if (boundp '*new-auxiliary-types*)
    (%parse-foreign-type type)
    (let ((*new-auxiliary-types* nil))
      (%parse-foreign-type type))))

(defun %parse-foreign-type (type)
  (if (consp type)
    (let ((translator (info-foreign-type-translator (car type))))
      (unless translator
        (error "Unknown foreign type: ~S" type))
      (funcall translator type nil))
    (case (info-foreign-type-kind type)
      (:primitive
       (let ((translator (info-foreign-type-translator type)))
         (unless translator
           (error "No translator for primitive foreign type ~S?" type))
      (funcall translator (list type) nil)))
      (:defined
          (or (info-foreign-type-definition type)
              (error "Definition missing for foreign type ~S?" type)))
      (:unknown
       (let* ((loaded (load-foreign-type type)))
	 (if loaded
	   (setq type loaded)))
       (or (info-foreign-type-definition type)
           (error "Unknown foreign type: ~S" type))))))

(defun auxiliary-foreign-type (kind name)
  (flet ((aux-defn-matches (x)
	   (and (eq (first x) kind) (eq (second x) name))))
    (let ((in-auxiliaries
	   (or (find-if #'aux-defn-matches *new-auxiliary-types*)
	       (find-if #'aux-defn-matches *auxiliary-type-definitions*))))
      (if in-auxiliaries
	  (values (third in-auxiliaries) t)
	  (ecase kind
	    (:struct
	     (info-foreign-type-struct name))
	    (:union
	     (info-foreign-type-union name))
	    (:enum
	     (info-foreign-type-enum name)))))))

(defun %set-auxiliary-foreign-type (kind name defn)
  (flet ((aux-defn-matches (x)
	   (and (eq (first x) kind) (eq (second x) name))))
    (when (find-if #'aux-defn-matches *new-auxiliary-types*)
      (error "Attempt to multiple define ~A ~S." kind name))
    (when (find-if #'aux-defn-matches *auxiliary-type-definitions*)
      (error "Attempt to shadow definition of ~A ~S." kind name)))
  (push (list kind name defn) *new-auxiliary-types*)
  defn)

(defsetf auxiliary-foreign-type %set-auxiliary-foreign-type)

(defun verify-local-auxiliaries-okay ()
  (dolist (info *new-auxiliary-types*)
    (destructuring-bind (kind name defn) info
      (declare (ignore defn))
      (when (ecase kind
	      (:struct
	       (info-foreign-type-struct name))
	      (:union
	       (info-foreign-type-union name))
	      (:enum
	       (info-foreign-type-enum name)))
	(error "Attempt to shadow definition of ~A ~S." kind name)))))

;;; *record-type-already-unparsed* -- internal
;;;
;;; Holds the list of record types that have already been unparsed.  This is
;;; used to keep from outputing the slots again if the same structure shows
;;; up twice.
;;; 
(defvar *record-types-already-unparsed*)

;;; UNPARSE-FOREIGN-TYPE -- public.
;;; 
(defun unparse-foreign-type (type)
  "Convert the foreign-type structure TYPE back into a list specification of
   the type."
  (declare (type foreign-type type))
  (let ((*record-types-already-unparsed* nil))
    (%unparse-foreign-type type)))

;;; %UNPARSE-FOREIGN-TYPE -- internal.
;;;
;;; Does all the work of UNPARSE-FOREIGN-TYPE.  It's seperate because we need
;;; to recurse inside the binding of *record-types-already-unparsed*.
;;; 
(defun %unparse-foreign-type (type)
  (invoke-foreign-type-method :unparse type))




;;;; Foreign type defining stuff.

(defmacro def-foreign-type-translator (name lambda-list &body body &environment env)
  (expand-type-macro '%def-foreign-type-translator name lambda-list body env))


(defun %def-foreign-type-translator (name translator docs)
  (declare (ignore docs))
  (setf (info-foreign-type-kind name) :primitive)
  (setf (info-foreign-type-translator name) translator)
  (clear-info-foreign-type-definition name)
  #+nil
  (setf (documentation name 'foreign-type) docs)
  name)


(defmacro def-foreign-type (name type)
  (with-auxiliary-foreign-types
    (let ((foreign-type (parse-foreign-type type)))
      `(eval-when (:compile-toplevel :load-toplevel :execute)
	 ,@(when *new-auxiliary-types*
	     `((%def-auxiliary-foreign-types ',*new-auxiliary-types*)))
	 ,@(when name
	     `((%def-foreign-type ',name ',foreign-type)))))))

(defun %def-auxiliary-foreign-types (types)
  (dolist (info types)
    (destructuring-bind (kind name defn) info
      (macrolet ((frob (accessor)
		   `(let ((old (,accessor name)))
		      (unless (or (null old) (foreign-type-= old defn))
			(warn "Redefining ~A ~S to be:~%  ~S,~%was:~%  ~S"
			      kind name defn old))
		      (setf (,accessor name) defn))))
	(ecase kind
	  (:struct (frob info-foreign-type-struct))
	  (:union (frob info-foreign-type-union))
	  (:enum (frob info-foreign-type-enum)))))))

(defun %def-foreign-type (name new)
  (ecase (info-foreign-type-kind name)
    (:primitive
     (error "~S is a built-in foreign type." name))
    (:defined
     (let ((old (info-foreign-type-definition name)))
       (unless (or (null old) (foreign-type-= new old))
	 (warn "Redefining ~S to be:~%  ~S,~%was~%  ~S" name
	       (unparse-foreign-type new) (unparse-foreign-type old)))))
    (:unknown))
  (setf (info-foreign-type-definition name) new)
  (setf (info-foreign-type-kind name) :defined)
  name)



;;;; Interfaces to the different methods

(defun foreign-type-= (type1 type2)
  "Return T iff TYPE1 and TYPE2 describe equivalent foreign types."
  (or (eq type1 type2)
      (and (eq (foreign-type-class type1)
	       (foreign-type-class type2))
	   (invoke-foreign-type-method :type= type1 type2))))

(defun foreign-subtype-p (type1 type2)
  "Return T iff the foreign type TYPE1 is a subtype of TYPE2.  Currently, the
   only supported subtype relationships are is that any pointer type is a
   subtype of (* t), and any array type first dimension will match 
   (array <eltype> nil ...).  Otherwise, the two types have to be
   FOREIGN-TYPE-=."
  (or (eq type1 type2)
      (invoke-foreign-type-method :subtypep type1 type2)))

(defun foreign-typep (object type)
  "Return T iff OBJECT is a foreign of type TYPE."
  (let ((lisp-rep-type (compute-lisp-rep-type type)))
    (if lisp-rep-type
	(typep object lisp-rep-type))))


(defun compute-naturalize-lambda (type)
  `(lambda (foreign ignore)
     (declare (ignore ignore))
     ,(invoke-foreign-type-method :naturalize-gen type 'foreign)))

(defun compute-deport-lambda (type)
  (declare (type foreign-type type))
  (multiple-value-bind
      (form value-type)
      (invoke-foreign-type-method :deport-gen type 'value)
    `(lambda (value ignore)
       (declare (type ,(or value-type
			   (compute-lisp-rep-type type)
			   `(foreign ,type))
		      value)
		(ignore ignore))
       ,form)))

(defun compute-extract-lambda (type)
  `(lambda (sap offset ignore)
     (declare (type system-area-pointer sap)
	      (type unsigned-byte offset)
	      (ignore ignore))
     (naturalize ,(invoke-foreign-type-method :extract-gen type 'sap 'offset)
		 ',type)))

(defun compute-deposit-lambda (type)
  (declare (type foreign-type type))
  `(lambda (sap offset ignore value)
     (declare (type system-area-pointer sap)
	      (type unsigned-byte offset)
	      (ignore ignore))
     (let ((value (deport value ',type)))
       ,(invoke-foreign-type-method :deposit-gen type 'sap 'offset 'value)
       ;; Note: the reason we don't just return the pre-deported value
       ;; is because that would inhibit any (deport (naturalize ...))
       ;; optimizations that might have otherwise happen.  Re-naturalizing
       ;; the value might cause extra consing, but is flushable, so probably
       ;; results in better code.
       (naturalize value ',type))))

(defun compute-lisp-rep-type (type)
  (invoke-foreign-type-method :lisp-rep type))

(defun compute-foreign-rep-type (type)
  (invoke-foreign-type-method :foreign-rep type))





;;;; Default methods.

(def-foreign-type-method (root :unparse) (type)
  `(!!unknown-foreign-type!! ,(type-of type)))

(def-foreign-type-method (root :type=) (type1 type2)
  (declare (ignore type1 type2))
  t)

(def-foreign-type-method (root :subtypep) (type1 type2)
  (foreign-type-= type1 type2))

(def-foreign-type-method (root :lisp-rep) (type)
  (declare (ignore type))
  nil)

(def-foreign-type-method (root :foreign-rep) (type)
  (declare (ignore type))
  '*)

(def-foreign-type-method (root :naturalize-gen) (type foreign)
  (declare (ignore foreign))
  (error "Cannot represent ~S typed foreigns." type))

(def-foreign-type-method (root :deport-gen) (type object)
  (declare (ignore object))
  (error "Cannot represent ~S typed foreigns." type))

(def-foreign-type-method (root :extract-gen) (type sap offset)
  (declare (ignore sap offset))
  (error "Cannot represent ~S typed foreigns." type))

(def-foreign-type-method (root :deposit-gen) (type sap offset value)
  `(setf ,(invoke-foreign-type-method :extract-gen type sap offset) ,value))

(def-foreign-type-method (root :arg-tn) (type state)
  (declare (ignore state))
  (error "Cannot pass foreigns of type ~S as arguments to call-out"
	 (unparse-foreign-type type)))

(def-foreign-type-method (root :result-tn) (type state)
  (declare (ignore state))
  (error "Cannot return foreigns of type ~S from call-out"
	 (unparse-foreign-type type)))


;;;; The INTEGER type.

(def-foreign-type-class (integer)
  (signed t :type (member t nil)))

(defvar *unsigned-integer-types*
  (let* ((a (make-array 33)))
    (dotimes (i 33 a)
      (setf (svref a i) (make-foreign-integer-type :signed nil
						   :bits i
						   :alignment
						   (if (logtest 7 i) 1 i))))))

(defvar *signed-integer-types*
  (let* ((a (make-array 33)))
    (dotimes (i 33 a)
      (setf (svref a i) (make-foreign-integer-type :signed t
						   :bits i
						   :alignment
 						   (if (logtest 7 i) 1 i))))))
         
(def-foreign-type-translator signed (&optional (bits 32))
  (if (<= bits 32)
    (svref *signed-integer-types* bits)
    (make-foreign-integer-type :bits bits)))



(def-foreign-type-translator integer (&optional (bits 32))
  (if (<= bits 32)
    (svref *signed-integer-types* bits)
    (make-foreign-integer-type :bits bits)))

(def-foreign-type-translator unsigned (&optional (bits 32))
  (if (<= bits 32)
    (svref *unsigned-integer-types* bits)
    (make-foreign-integer-type :bits bits :signed nil)))

(def-foreign-type-method (integer :unparse) (type)
  (list (if (foreign-integer-type-signed type) :signed :unsigned)
	(foreign-integer-type-bits type)))

(def-foreign-type-method (integer :type=) (type1 type2)
  (and (eq (foreign-integer-type-signed type1)
	   (foreign-integer-type-signed type2))
       (= (foreign-integer-type-bits type1)
	  (foreign-integer-type-bits type2))))

(def-foreign-type-method (integer :lisp-rep) (type)
  (list (if (foreign-integer-type-signed type) 'signed-byte 'unsigned-byte)
	(foreign-integer-type-bits type)))

(def-foreign-type-method (integer :foreign-rep) (type)
  (list (if (foreign-integer-type-signed type) 'signed-byte 'unsigned-byte)
	(foreign-integer-type-bits type)))

(def-foreign-type-method (integer :naturalize-gen) (type foreign)
  (declare (ignore type))
  foreign)

(def-foreign-type-method (integer :deport-gen) (type value)
  (declare (ignore type))
  value)

(def-foreign-type-method (integer :extract-gen) (type sap offset)
  (declare (type foreign-integer-type type))
  (let ((ref-form
	 (if (foreign-integer-type-signed type)
	  (case (foreign-integer-type-bits type)
	    (8 `(%get-signed-byte ,sap (/ ,offset 8)))
	    (16 `(%get-signed-word ,sap (/ ,offset 8)))
	    (32 `(%get-signed-long ,sap (/ ,offset 8)))
	    (64 `(%%get-signed-longlong ,sap (/ ,offset 8))))
	  (case (foreign-integer-type-bits type)
            (1 `(%get-bit ,sap ,offset))
	    (8 `(%get-unsigned-byte ,sap (/ ,offset 8)))
	    (16 `(%get-unsigned-word ,sap (/ ,offset 8)))
	    (32 `(%get-unsigned-long ,sap (/ ,offset 8)))
	    (64 `(%%get-unsigned-longlong ,sap (/ ,offset 8)))
	    (t  `(%get-bitfield ,sap ,offset ,(foreign-integer-type-bits type)))))))
    (or ref-form
	(error "Cannot extract ~D bit integers."
	       (foreign-integer-type-bits type)))))



;;;; The BOOLEAN type.

(def-foreign-type-class (boolean :include integer :include-args (signed)))

(def-foreign-type-translator boolean (&optional (bits 32))
  (make-foreign-boolean-type :bits bits :signed nil))

(def-foreign-type-method (boolean :unparse) (type)
  `(boolean ,(foreign-boolean-type-bits type)))

(def-foreign-type-method (boolean :lisp-rep) (type)
  (declare (ignore type))
  `(member t nil))

(def-foreign-type-method (boolean :naturalize-gen) (type foreign)
  (declare (ignore type))
  `(not (zerop ,foreign)))

(def-foreign-type-method (boolean :deport-gen) (type value)
  (declare (ignore type))
  `(if ,value 1 0))



;;;; the FLOAT types.

(def-foreign-type-class (float)
  (type () :type symbol))

(def-foreign-type-method (float :unparse) (type)
  (foreign-float-type-type type))

(def-foreign-type-method (float :lisp-rep) (type)
  (foreign-float-type-type type))

(def-foreign-type-method (float :foreign-rep) (type)
  (foreign-float-type-type type))

(def-foreign-type-method (float :naturalize-gen) (type foreign)
  (declare (ignore type))
  foreign)

(def-foreign-type-method (float :deport-gen) (type value)
  (declare (ignore type))
  value)


(def-foreign-type-class (single-float :include (float (bits 32))
				    :include-args (type)))

(def-foreign-type-translator single-float ()
  (make-foreign-single-float-type :type 'single-float))

(def-foreign-type-method (single-float :extract-gen) (type sap offset)
  (declare (ignore type))
  `(%get-single-float ,sap (/ ,offset 8)))


(def-foreign-type-class (double-float :include (float (bits 64))
				    :include-args (type)))

(def-foreign-type-translator double-float ()
  (make-foreign-double-float-type :type 'double-float))

(def-foreign-type-method (double-float :extract-gen) (type sap offset)
  (declare (ignore type))
  `(%get-double-float ,sap (/ ,offset 8)))



;;;; The MACPTR type

(def-foreign-type-class (macptr))

(def-foreign-type-translator macptr ()
  (make-foreign-macptr-type :bits #-alpha 32 #+alpha 64))

(def-foreign-type-method (macptr :unparse) (type)
  (declare (ignore type))
  'macptr)

(def-foreign-type-method (macptr :lisp-rep) (type)
  (declare (ignore type))
  'macptr)

(def-foreign-type-method (macptr :foreign-rep) (type)
  (declare (ignore type))
  'macptr)

(def-foreign-type-method (macptr :naturalize-gen) (type foreign)
  (declare (ignore type))
  foreign)

(def-foreign-type-method (macptr :deport-gen) (type object)
  (declare (ignore type))
  object)

(def-foreign-type-method (macptr :extract-gen) (type sap offset)
  (declare (ignore type))
  `(%get-ptr ,sap (/ ,offset 8)))


;;;; the FOREIGN-VALUE type.

(def-foreign-type-class (foreign-value :include macptr))

(def-foreign-type-method (foreign-value :lisp-rep) (type)
  (declare (ignore type))
  nil)

(def-foreign-type-method (foreign-value :naturalize-gen) (type foreign)
  `(%macptr-foreign ,foreign ',type))

(def-foreign-type-method (foreign-value :deport-gen) (type value)
  (declare (ignore type))
  `(foreign-macptr ,value))



;;;; The POINTER type.

(def-foreign-type-class (pointer :include (foreign-value (bits
						      #-alpha 32
						      #+alpha 64)))
  (to nil :type (or foreign-type null)))

(def-foreign-type-translator * (to)
  (make-foreign-pointer-type :to (if (eq to t) nil (parse-foreign-type to))))

(def-foreign-type-method (pointer :unparse) (type)
  (let ((to (foreign-pointer-type-to type)))
    `(* ,(if to
	     (%unparse-foreign-type to)
	     t))))

(def-foreign-type-method (pointer :type=) (type1 type2)
  (let ((to1 (foreign-pointer-type-to type1))
	(to2 (foreign-pointer-type-to type2)))
    (if to1
	(if to2
	    (foreign-type-= to1 to2)
	    nil)
	(null to2))))

(def-foreign-type-method (pointer :subtypep) (type1 type2)
  (and (foreign-pointer-type-p type2)
       (let ((to1 (foreign-pointer-type-to type1))
	     (to2 (foreign-pointer-type-to type2)))
	 (if to1
	     (if to2
		 (foreign-subtype-p to1 to2)
		 t)
	     (null to2)))))

(def-foreign-type-method (pointer :deport-gen) (type value)
  (values
   `(etypecase ,value
      (null
       (int-sap 0))
      (macptr
       ,value)
      ((foreign ,type)
       (foreign-sap ,value)))
   `(or null macptr (foreign ,type))))


;;;; The MEM-BLOCK type.


(def-foreign-type-class (mem-block :include foreign-value))

(def-foreign-type-method (mem-block :extract-gen) (type sap offset)
  (let* ((nbytes (%foreign-type-or-record-size type :bytes)))
    `(%composite-pointer-ref ,nbytes ,sap (/ ,offset 8))))

(def-foreign-type-method (mem-block :deposit-gen) (type sap offset value)
  (let ((bits (foreign-mem-block-type-bits type)))
    (unless bits
      (error "Cannot deposit foreigns of type ~S (unknown size)." type))
    `(%copy-macptr-to-macptr ,value 0 ,sap ,offset ',bits)))



;;;; The ARRAY type.

(def-foreign-type-class (array :include mem-block)
  (element-type () :type foreign-type)
  (dimensions () :type list))

(def-foreign-type-translator array (ele-type &rest dims)
  (when dims
    (unless (typep (first dims) '(or index null))
      (error "First dimension is not a non-negative fixnum or NIL: ~S"
	     (first dims)))
    (let ((loser (find-if-not #'(lambda (x) (typep x 'index))
			      (rest dims))))
      (when loser
	(error "Dimension is not a non-negative fixnum: ~S" loser))))
	
  (let ((type (parse-foreign-type ele-type)))
    (make-foreign-array-type
     :element-type type
     :dimensions dims
     :alignment (foreign-type-alignment type)
     :bits (if (and (ensure-foreign-type-bits type)
		    (every #'integerp dims))
	       (* (align-offset (foreign-type-bits type)
				(foreign-type-alignment type))
		  (reduce #'* dims))))))

(def-foreign-type-method (array :unparse) (type)
  `(array ,(%unparse-foreign-type (foreign-array-type-element-type type))
	  ,@(foreign-array-type-dimensions type)))

(def-foreign-type-method (array :type=) (type1 type2)
  (and (equal (foreign-array-type-dimensions type1)
	      (foreign-array-type-dimensions type2))
       (foreign-type-= (foreign-array-type-element-type type1)
                       (foreign-array-type-element-type type2))))

(def-foreign-type-method (array :subtypep) (type1 type2)
  (and (foreign-array-type-p type2)
       (let ((dim1 (foreign-array-type-dimensions type1))
	     (dim2 (foreign-array-type-dimensions type2)))
	 (and (= (length dim1) (length dim2))
	      (or (and dim2
		       (null (car dim2))
		       (equal (cdr dim1) (cdr dim2)))
		  (equal dim1 dim2))
	      (foreign-subtype-p (foreign-array-type-element-type type1)
			       (foreign-array-type-element-type type2))))))


;;;; The RECORD type.

(defstruct (foreign-record-field
	     (:print-object
	      (lambda (field stream)
		(print-unreadable-object (field stream :type t)
		  (funcall (formatter "~S ~S~@[:~D~]")
			   stream
			   (foreign-record-field-type field)
			   (foreign-record-field-name field)
			   (foreign-record-field-bits field))))))
  (name () :type symbol)
  (type () :type foreign-type)
  (bits nil :type (or unsigned-byte null))
  (offset 0 :type unsigned-byte))



(defmethod make-load-form ((f foreign-record-field) &optional env)
  (make-load-form-saving-slots f :environment env))

(def-foreign-type-class (record :include mem-block)
  (kind :struct :type (member :struct :union))
  (name nil :type (or symbol null))
  (fields nil :type list)
  ;; For, e.g., records defined with #pragma options align=mac68k
  ;; in effect.  When non-nil, this specifies the maximum alignment
  ;; of record fields and the overall alignment of the record.
  (alt-align nil :type (or unsigned-byte null)))

(def-foreign-type-translator struct (name &rest fields)
  (parse-foreign-record-type :struct name fields))

(def-foreign-type-translator union (name &rest fields)
  (parse-foreign-record-type :union name fields))

(defun parse-foreign-record-type (kind name fields)
  (if fields
      (let* ((old (and name (auxiliary-foreign-type kind name)))
	     (result (if (or (null old)
			     (foreign-record-type-fields old))
			 (make-foreign-record-type :name name :kind kind)
			 old)))
	(when (and name (not (eq old result)))
	  (setf (auxiliary-foreign-type kind name) result))
	(parse-foreign-record-fields result fields)
	result)
      (if name
	  (or (auxiliary-foreign-type kind name)
	      (setf (auxiliary-foreign-type kind name)
		    (make-foreign-record-type :name name :kind kind)))
	  (make-foreign-record-type :kind kind))))

;;; PARSE-FOREIGN-RECORD-FIELDS -- internal
;;;
;;; Used by parse-foreign-type to parse the fields of struct and union
;;; types.  RESULT holds the record type we are paring the fields of,
;;; and FIELDS is the list of field specifications.
;;; 
(defun parse-foreign-record-fields (result fields)
  (declare (type foreign-record-type result)
	   (type list fields))
  (let ((total-bits 0)
	(overall-alignment 1)
	(parsed-fields nil)
	#+poweropen-target
	(first-field-p t)
	(alt-alignment (foreign-record-type-alt-align result)))
    (dolist (field fields)
      (destructuring-bind (var type &optional bits) field
	(declare (ignore bits))
	(let* ((field-type (parse-foreign-type type))
	       (bits (ensure-foreign-type-bits field-type))
	       (natural-alignment (foreign-type-alignment field-type))
	       (alignment (if alt-alignment
			    (min natural-alignment alt-alignment)
			    #+poweropen-target
			    (if first-field-p
			      (progn
				(setq first-field-p nil)
				natural-alignment)
			      (min 32 natural-alignment))
			    #-poweropen-target
			    natural-alignment))
	       (parsed-field
		(make-foreign-record-field :type field-type
					   :name var)))
	  (push parsed-field parsed-fields)
	  (when (null bits)
	    (error "Unknown size: ~S"
		   (unparse-foreign-type field-type)))
	  (when (null alignment)
	    (error "Unknown alignment: ~S"
		   (unparse-foreign-type field-type)))
	  (setf overall-alignment (max overall-alignment alignment))
	  (ecase (foreign-record-type-kind result)
	    (:struct
	     (let ((offset (align-offset total-bits alignment)))
	       (setf (foreign-record-field-offset parsed-field) offset)
	       (setf total-bits (+ offset bits))))
	    (:union
	     (setf total-bits (max total-bits bits)))))))
    (let ((new (nreverse parsed-fields)))
      (setf (foreign-record-type-fields result) new))
    (setf (foreign-record-type-alignment result) (or alt-alignment
						     overall-alignment))
    (setf (foreign-record-type-bits result)
	  (align-offset total-bits (or alt-alignment overall-alignment)))))

(def-foreign-type-method (record :unparse) (type)
  `(,(case (foreign-record-type-kind type)
       (:struct 'struct)
       (:union 'union)
       (t '???))
    ,(foreign-record-type-name type)
    ,@(unless (member type *record-types-already-unparsed* :test #'eq)
	(push type *record-types-already-unparsed*)
	(mapcar #'(lambda (field)
		    `(,(foreign-record-field-name field)
		      ,(%unparse-foreign-type (foreign-record-field-type field))
		      ,@(if (foreign-record-field-bits field)
			    (list (foreign-record-field-bits field)))))
		(foreign-record-type-fields type)))))

;;; Test the record fields. The depth is limiting in case of cyclic
;;; pointers.
(defun record-fields-match (fields1 fields2 depth)
  (declare (type list fields1 fields2)
	   (type (mod 64) depth))
  (labels ((record-type-= (type1 type2 depth)
	     (and (eq (foreign-record-type-name type1)
		      (foreign-record-type-name type2))
		  (eq (foreign-record-type-kind type1)
		      (foreign-record-type-kind type2))
		  (= (length (foreign-record-type-fields type1))
		     (length (foreign-record-type-fields type2)))
		  (record-fields-match (foreign-record-type-fields type1)
				       (foreign-record-type-fields type2)
				       (1+ depth))))
	   (pointer-type-= (type1 type2 depth)
	     (let ((to1 (foreign-pointer-type-to type1))
		   (to2 (foreign-pointer-type-to type2)))
	       (if to1
		   (if to2
		    (or (> depth 10)
		       (type-= to1 to2 (1+ depth)))
		       nil)
		   (null to2))))
	   (type-= (type1 type2 depth)
	     (cond ((and (foreign-pointer-type-p type1)
			 (foreign-pointer-type-p type2))
		    (or (> depth 10)
			(pointer-type-= type1 type2 depth)))
		   ((and (foreign-record-type-p type1)
			 (foreign-record-type-p type2))
		    (record-type-= type1 type2 depth))
		   (t
		    (foreign-type-= type1 type2)))))
    (do ((fields1-rem fields1 (rest fields1-rem))
	 (fields2-rem fields2 (rest fields2-rem)))
	((or (eq fields1-rem fields2-rem)
	     (endp fields1-rem)
             (endp fields2-rem))
	 (eq fields1-rem fields2-rem))
      (let ((field1 (first fields1-rem))
	    (field2 (first fields2-rem)))
	(declare (type foreign-record-field field1 field2))
	(unless (and (eq (foreign-record-field-name field1)
			 (foreign-record-field-name field2))
		     (eql (foreign-record-field-bits field1)
			  (foreign-record-field-bits field2))
		     (eql (foreign-record-field-offset field1)
			  (foreign-record-field-offset field2))
		     (let ((field1 (foreign-record-field-type field1))
			   (field2 (foreign-record-field-type field2)))
		       (type-= field1 field2 (1+ depth))))
	  (return nil))))))

(def-foreign-type-method (record :type=) (type1 type2)
  (and (eq (foreign-record-type-name type1)
	   (foreign-record-type-name type2))
       (eq (foreign-record-type-kind type1)
	   (foreign-record-type-kind type2))
       (= (length (foreign-record-type-fields type1))
	  (length (foreign-record-type-fields type2)))
       (record-fields-match (foreign-record-type-fields type1)
			    (foreign-record-type-fields type2) 0)))


;;;; The FUNCTION and VALUES types.

(defvar *values-type-okay* nil)

(def-foreign-type-class (function :include mem-block)
  (result-type () :type foreign-type)
  (arg-types () :type list)
  (stub nil :type (or null function)))

(def-foreign-type-translator function (result-type &rest arg-types)
  (make-foreign-function-type
   :result-type (let ((*values-type-okay* t))
		  (parse-foreign-type result-type))
   :arg-types (mapcar #'parse-foreign-type arg-types)))

(def-foreign-type-method (function :unparse) (type)
  `(function ,(%unparse-foreign-type (foreign-function-type-result-type type))
	     ,@(mapcar #'%unparse-foreign-type
		       (foreign-function-type-arg-types type))))

(def-foreign-type-method (function :type=) (type1 type2)
  (and (foreign-type-= (foreign-function-type-result-type type1)
		     (foreign-function-type-result-type type2))
       (= (length (foreign-function-type-arg-types type1))
	  (length (foreign-function-type-arg-types type2)))
       (every #'foreign-type-=
	      (foreign-function-type-arg-types type1)
	      (foreign-function-type-arg-types type2))))


(def-foreign-type-class (values)
  (values () :type list))

(def-foreign-type-translator values (&rest values)
  (unless *values-type-okay*
    (error "Cannot use values types here."))
  (let ((*values-type-okay* nil))
    (make-foreign-values-type
     :values (mapcar #'parse-foreign-type values))))

(def-foreign-type-method (values :unparse) (type)
  `(values ,@(mapcar #'%unparse-foreign-type
		     (foreign-values-type-values type))))

(def-foreign-type-method (values :type=) (type1 type2)
  (and (= (length (foreign-values-type-values type1))
	  (length (foreign-values-type-values type2)))
       (every #'foreign-type-=
	      (foreign-values-type-values type1)
	      (foreign-values-type-values type2))))



;;;; Foreign variables.

;;; HEAP-FOREIGN-INFO -- defstruct.
;;;
;;; Information describing a heap-allocated foreign.
;;; 
(defstruct (heap-foreign-info
	     (:print-object
	      (lambda (info stream)
		(print-unreadable-object (info stream :type t)
		  (funcall (formatter "~S ~S")
			   stream
			   (heap-foreign-info-sap-form info)
			   (unparse-foreign-type (heap-foreign-info-type info)))))))
  ;; The type of this foreign.
  (type () :type foreign-type)
  ;; The form to evaluate to produce the SAP pointing to where in the heap
  ;; it is.
  (sap-form ()))


;;;


(defmethod make-load-form ((h heap-foreign-info) &optional env)
  (make-load-form-saving-slots h :environment env))

;;; LOCAL-FOREIGN-INFO -- public defstruct.
;;;
;;; Information about local foreigns.  The WITH-FOREIGN macro builds one of these
;;; structures and local-foreign and friends comunicate information about how
;;; that local foreign is represented.
;;; 
(defstruct (local-foreign-info
	     (:constructor make-local-foreign-info (&key type force-to-memory-p))
	     (:print-object
	      (lambda (info stream)
		(print-unreadable-object (info stream :type t)
		  (funcall (formatter "~:[~;(forced to stack) ~]~S")
			   stream
			   (local-foreign-info-force-to-memory-p info)
			   (unparse-foreign-type (local-foreign-info-type info)))))))
  ;; The type of the local foreign.
  (type () :type foreign-type)
  ;; T if this local foreign must be forced into memory.  Using the ADDR macro
  ;; on a local foreign will set this.
  (force-to-memory-p (or (foreign-array-type-p type) (foreign-record-type-p type))
		     :type (member t nil)))
;;;


(defmethod make-load-form ((l local-foreign-info) &optional env)
  (make-load-form-saving-slots l :environment env))

;;; GUESS-FOREIGN-NAME-FROM-LISP-NAME -- internal.
;;;
;;; Make a string out of the symbol, converting all uppercase letters to
;;; lower case and hyphens into underscores.
;;; 
(defun guess-foreign-name-from-lisp-name (lisp-name)
  (declare (type symbol lisp-name))
  (nsubstitute #\_ #\- (string-downcase (symbol-name lisp-name))))

;;; GUESS-LISP-NAME-FROM-FOREIGN-NAME -- internal.
;;;
;;; The opposite of GUESS-FOREIGN-NAME-FROM-LISP-NAME.  Make a symbol out of the
;;; string, converting all lowercase letters to uppercase and underscores into
;;; hyphens.
;;;
(defun guess-lisp-name-from-foreign-name (foreign-name)
  (declare (type simple-string foreign-name))
  (intern (nsubstitute #\- #\_ (string-upcase foreign-name))))

;;; PICK-LISP-AND-FOREIGN-NAMES -- internal.
;;;
;;; Extract the lisp and foreign names from NAME.  If only one is given, guess
;;; the other.
;;; 
(defun pick-lisp-and-foreign-names (name)
  (etypecase name
    (string
     (values (guess-lisp-name-from-foreign-name name) name))
    (symbol
     (values name (guess-foreign-name-from-lisp-name name)))
    (list
     (unless (= (length name) 2)
       (error "Badly formed foreign name."))
     (values (cadr name) (car name)))))


;;;; The FOREIGN-SIZE macro.

(defmacro foreign-size (type &optional (units :bits))
  "Return the size of the foreign type TYPE.  UNITS specifies the units to
   use and can be either :BITS, :BYTES, or :WORDS."
  (let* ((foreign-type (parse-foreign-type type))
         (bits (ensure-foreign-type-bits foreign-type)))
    (if bits
      (values (ceiling bits
                       (ecase units
                         (:bits 1)
                         (:bytes 8)
                         (:words 32))))
      (error "Unknown size for foreign type ~S."
             (unparse-foreign-type foreign-type)))))

(defun ensure-foreign-type-bits (type)
  (or (foreign-type-bits type)
      (and (typep type 'foreign-record-type)
           (let* ((name (foreign-record-type-name type)))
             (and name
                  (load-record name)
                  (foreign-type-bits type))))
      (and (typep type 'foreign-array-type)
	   (let* ((element-type (foreign-array-type-element-type type))
		  (dims (foreign-array-type-dimensions type)))
	     (if (and (ensure-foreign-type-bits element-type)
		      (every #'integerp dims))
	       (setf (foreign-array-type-alignment type)
		     (foreign-type-alignment element-type)
		     (foreign-array-type-bits type)
		     (* (align-offset (foreign-type-bits element-type)
				      (foreign-type-alignment element-type))
			(reduce #'* dims))))))))

(defun %find-foreign-record (name)
  (or (info-foreign-type-struct name)
      (info-foreign-type-union name)
      (load-record name)))


(defun %foreign-type-or-record (type)
  (if (typep type 'foreign-type)
    type
    (if (consp type)
      (parse-foreign-type type)
      (or (%find-foreign-record type)
	  (parse-foreign-type type)))))

(defun %foreign-type-or-record-size (type &optional (units :bits))
  (let* ((info (%foreign-type-or-record type))
         (bits (ensure-foreign-type-bits info)))
    (if bits
      (values (ceiling bits
                       (ecase units
                         (:bits 1)
                         (:bytes 8)
                         (:words 32))))
      (error "Unknown size for foreign type ~S."
             (unparse-foreign-type info)))))

(defun %find-foreign-record-type-field (type field-name)
  (ensure-foreign-type-bits type)       ;load the record type if necessary.
  (let* ((fields (foreign-record-type-fields type)))
    (or (find field-name  fields :key #'foreign-record-field-name :test #'string-equal)
                         (error "Record type ~a has no field named ~s.~&Valid field names are: ~&~a"
                                (foreign-record-type-name type)
                                field-name
                                (mapcar #'foreign-record-field-name fields)))))

(defun %foreign-access-form (base-form type bit-offset accessors)
  (if (null accessors)
    (invoke-foreign-type-method :extract-gen type base-form bit-offset)
    (etypecase type
      (foreign-record-type
       (let* ((field (%find-foreign-record-type-field type (car accessors))))
         (%foreign-access-form base-form
                               (foreign-record-field-type field)
                               (+ bit-offset (foreign-record-field-offset field))
                               (cdr accessors))))
      (foreign-pointer-type
       (%foreign-access-form
        (invoke-foreign-type-method :extract-gen type base-form bit-offset)
        (foreign-pointer-type-to type)
        0
        accessors)))))



;;;; Naturalize, deport, extract-foreign-value, deposit-foreign-value

(defun naturalize (foreign type)
  (declare (type foreign-type type))
  (funcall (coerce (compute-naturalize-lambda type) 'function)
           foreign type))

(defun deport (value type)
  (declare (type foreign-type type))
  (funcall (coerce (compute-deport-lambda type) 'function)
           value type))

(defun extract-foreign-value (sap offset type)
  (declare (type macptr sap)
           (type unsigned-byte offset)
           (type foreign-type type))
  (funcall (coerce (compute-extract-lambda type) 'function)
           sap offset type))

(defun deposit-foreign-value (sap offset type value)
  (declare (type macptr sap)
           (type unsigned-byte offset)
           (type foreign-type type))
  (funcall (coerce (compute-deposit-lambda type) 'function)
           sap offset type value))


(def-foreign-type signed-char (signed 8))
(def-foreign-type signed-byte (signed 8))
(def-foreign-type short (signed 16))
(def-foreign-type signed-halfword short)
(def-foreign-type int (signed 32))
(def-foreign-type signed-fullword int)
(def-foreign-type long (integer 32))
(def-foreign-type signed-short (signed 16))
(def-foreign-type signed-int (signed 32))
(def-foreign-type signed-long (signed 32))
(def-foreign-type signed-doubleword (signed 64))
(def-foreign-type char #+linuxppc-target (unsigned 8)
		  #+darwinppc-target (signed 8))
(def-foreign-type unsigned-char (unsigned 8))
(def-foreign-type unsigned-byte (unsigned 8))
(def-foreign-type unsigned-short (unsigned 16))
(def-foreign-type unsigned-halfword unsigned-short)
(def-foreign-type unsigned-int (unsigned 32))
(def-foreign-type unsigned-fullword unsigned-int)
(def-foreign-type unsigned-long (unsigned 32))
(def-foreign-type unsigned-doubleword (unsigned 64))

(def-foreign-type float single-float)
(def-foreign-type double double-float)
(def-foreign-type-translator root ()
  (make-foreign-type :class 'root :bits 0 :alignment 0))

(def-foreign-type void (root))
(def-foreign-type address (* :void))

(defmacro external (name)
  `(load-eep ,name))

(defmacro external-call (name &rest args)
  `(ff-call (%reference-external-entry-point
	     (load-time-value (external ,name))) ,@args))

(defmacro ff-call (entry &rest args)
  (let* ((monitor (eq (car args) :monitor-exception-ports)))
    (when monitor
      (setq args (cdr args)))
    (collect ((representation nil))
      (when monitor
	(representation :monitor-exception-ports))
      (do* ((a args (cddr a)))
	   ((null (cdr a))
	    (if (null a) (representation :void)
	      (let* ((rettype (car a)))
		(representation (foreign-type-to-representation-type
				 rettype)))))
	(let* ((spec (car a))
	       (val (cadr a)))
	  (representation (foreign-type-to-representation-type spec))
	(representation val)))
    `(%ff-call ,entry ,@(representation)))))
	
	  
(make-built-in-class 'external-entry-point *istruct-class*)

(defmethod make-load-form ((eep external-entry-point) &optional env)
  (declare (ignore env))
  `(load-eep ,(eep.name eep)))

(defmethod print-object ((eep external-entry-point) out)
  (print-unreadable-object (eep out :type t :identity t)
    (format out "~s" (eep.name eep))
    (let* ((addr (eep.address eep))
	   (container (eep.container eep)))
      (if addr
	(format out " (#x~8,'0x) " (logand #xffffffff (ash addr 2)))
	(format out " {unresolved} "))
      (when (and container (or (not (typep container 'macptr))
				    (not (%null-ptr-p container))))
	(format out "~a" (shlib.soname container))))))

(make-built-in-class 'shlib *istruct-class*)

(defmethod print-object ((s shlib) stream)
  (print-unreadable-object (s stream :type t :identity t)
    (format stream "~a" (or (shlib.soname s) (shlib.pathname s)))))

#-darwinppc-target
(defun dlerror ()
  (with-macptrs ((p))
    (%setf-macptr p (#_dlerror))
    (unless (%null-ptr-p p) (%get-cstring p))))

(defstruct (external-function-definition (:conc-name "EFD-")
                                         (:constructor
                                          make-external-function-definition
                                          (&key entry-name arg-specs
                                                result-spec
                                                (min-args (length arg-specs))))
                                         )
  (entry-name "" :type string)
  (arg-specs () :type list)
  (result-spec nil :type symbol)
  (min-args 0 :type fixnum))


(defun %external-call-expander (whole env)
  (declare (ignore env))
  (destructuring-bind (name &rest args) whole
    (let* ((info (or (gethash name (ftd-external-function-definitions
				    *target-ftd*))
		     (error "Unknown external-function: ~s" name)))
	   (external-name (efd-entry-name info))
	   (arg-specs (efd-arg-specs info))
	   (result (efd-result-spec info))
	   (monitor (eq (car args) :monitor-exception-ports)))
      (when monitor
	(setq args (cdr args)))
      (do* ((call (if monitor '(:monitor-exception-ports) ()))
	    (specs arg-specs (cdr specs))
	    (args args (cdr args)))
	   ((null specs)
	    (if args
	      (error "Extra arguments in ~s" call)
	      `(external-call ,external-name ,@(nreverse (cons result call)))))
	(let* ((spec (car specs)))
	  (cond ((eq spec :void)
		 ;; must be last arg-spec; remaining args should be
		 ;; keyword/value pairs
		 (unless (evenp (length args))
		   (error "Remaining arguments should be keyword/value pairs: ~s"
			  args))
		 (do* ()
		      ((null args))
		   (push (pop args) call)
		   (push (pop args) call)))
		(t
		 (push spec call)
		 (if args
		   (push (car args) call)
		   (error "Missing arguments in ~s" whole)))))))))

(defun translate-foreign-arg-type (foreign-type-spec)
  (let* ((foreign-type (parse-foreign-type foreign-type-spec)))
    (etypecase foreign-type
      (foreign-pointer-type :address)
      (foreign-integer-type
       (let* ((bits (foreign-integer-type-bits foreign-type))
              (signed (foreign-integer-type-signed foreign-type)))
         (declare (fixnum bits))
         (cond ((<= bits 8) (if signed :signed-byte :unsigned-byte))
               ((<= bits 16) (if signed :signed-halfword :unsigned-halfword))
               ((<= bits 32) (if signed :signed-fullword :unsigned-fullword))
               (t `(:record ,bits)))))
      (foreign-float-type
       (ecase (foreign-float-type-bits foreign-type)
         (32 :single-float)
         (64 :double-float)))
      (foreign-record-type
       `(:record ,(foreign-record-type-bits foreign-type))))))
      

(defmacro define-external-function (name (&rest arg-specs) result-spec
					 &key (min-args (length arg-specs)))
  (let* ((entry-name nil)
         (package (find-package (ftd-interface-package-name *target-ftd*)))
         (arg-keywords (mapcar #'translate-foreign-arg-type arg-specs))
         (result-keyword (unless (and (symbolp result-spec)
                                    (eq (make-keyword result-spec) :void))
                               (translate-foreign-arg-type result-spec))))
    (when (and (consp result-keyword) (eq (car result-keyword) :record))
      (push :address arg-keywords)
      (setq result-keyword nil))
    (if (consp name)
      (setq entry-name (cadr name) name (intern (unescape-foreign-name
                                                 (car name))
                                                package))
      (progn
        (setq entry-name (unescape-foreign-name name)
              name (intern entry-name package))
        (if (member :prepend-underscore
                    (ftd-attributes *target-ftd*))
          (setq entry-name (concatenate 'string "_" entry-name)))))
    `(progn
      (setf (gethash ',name (ftd-external-function-definitions *target-ftd*))
       (make-external-function-definition
	:entry-name ',entry-name
	:arg-specs ',arg-keywords
	:result-spec ',result-keyword
	:min-args ,min-args))
      (setf (macro-function ',name) #'%external-call-expander)
      ',name)))


#+darwinppc-target
(defun open-dylib (name)
  (with-cstrs ((name name))
    (#_NSAddImage name (logior #$NSADDIMAGE_OPTION_RETURN_ON_ERROR 
			       #$NSADDIMAGE_OPTION_WITH_SEARCHING))))

(defparameter *foreign-representation-type-keywords*
  `(:signed-doubleword :signed-fullword :signed-halfword :signed-byte
    :unsigned-doubleword :unsigned-fullword :unsigned-halfword :unsigned-byte
    :address
    :single-float :double-float
    :void))

(defun foreign-type-to-representation-type (f)
  (if (or (member f *foreign-representation-type-keywords*)
	  (typep f 'unsigned-byte))
    f
    (let* ((ftype (parse-foreign-type f)))
      (or
       (and (eq (foreign-type-class ftype) 'root) :void)	 
       (typecase ftype
	 (foreign-pointer-type :address)
	 (foreign-double-float-type :double-float)
	 (foreign-single-float-type :single-float)
	 (foreign-integer-type
	  (let* ((signed (foreign-integer-type-signed ftype))
		 (bits (foreign-integer-type-bits ftype)))
	    (if signed
	      (if (<= bits 8)
		:signed-byte
		(if (<= bits 16)
		  :signed-halfword
		  (if (<= bits 32)
		    :signed-fullword
		    (if (<= bits 64)
		      :signed-doubleword))))
	      (if (<= bits 8)
		:unsigned-byte
		(if (<= bits 16)
		  :unsigned-halfword
		  (if (<= bits 32)
		    :unsigned-fullword
		    (if (<= bits 64)
		      :unsigned-doubleword)))))))
	 ((or foreign-record-type foreign-array-type)
	  (let* ((bits (ensure-foreign-type-bits ftype)))
	    (ceiling bits 32))))
       (error "can't determine representation keyword for ~s" f)))))

(defun foreign-record-accessor-names (record-type &optional prefix)
  (collect ((accessors))
    (dolist (field (foreign-record-type-fields record-type) (accessors))
      (let* ((field-name (append prefix (list (foreign-record-field-name field))))
	     (field-type (foreign-record-field-type field)))
	(if (typep field-type 'foreign-record-type)
	  (dolist (s (foreign-record-accessor-names field-type field-name))
	    (accessors s))
	  (accessors field-name))))))

(defun %assert-macptr-ftype (macptr ftype)
  (if (eq (class-of macptr) *macptr-class*)
    (%set-macptr-type macptr (foreign-type-ordinal ftype)))
  macptr)

(defun %macptr-ftype (macptr)
  (if (eq (class-of macptr) *macptr-class*)
    (ordinal-to-foreign-type (%macptr-type macptr))))


  
  
