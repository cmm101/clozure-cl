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


;; sysutils.lisp - things which have outgrown l1-utils

(in-package :ccl)

(eval-when (:execute :compile-toplevel)
  (require 'level-2)
  (require 'optimizers)
  (require 'backquote)
  (require 'defstruct-macros)
  )

;;; things might be clearer if this stuff were in l1-typesys?
;;; Translation from type keywords to specific predicates.
(eval-when (:execute :compile-toplevel)

(defconstant type-pred-pairs
  '((array . arrayp)
    (atom . atom)
    (base-string . base-string-p)
    (bignum . bignump)
    (bit . bitp)
    (bit-vector . bit-vector-p)
    (character . characterp)
    (compiled-function . compiled-function-p)
    (complex . complexp)
    (cons . consp)
    (double-float . double-float-p)
    (fixnum . fixnump) ;not cl
    (float . floatp)
    (function . functionp)
    (hash-table . hash-table-p)
    (integer . integerp)
    (real . realp)
    (keyword . keywordp)
    (list . listp)
    (long-float . double-float-p)
    (nil . false)
    (null . null)
    (number . numberp)
    (package . packagep)
    (pathname . pathnamep)
    (logical-pathname . logical-pathname-p)
    (random-state . random-state-p)
    (ratio . ratiop)
    (rational . rationalp)
    (readtable . readtablep)
    (sequence . sequencep)
    (short-float . short-float-p)
    (signed-byte . integerp)
    (simple-array . simple-array-p)
    (simple-base-string . simple-base-string-p)
    (simple-extended-string . simple-extended-string-p)
    (simple-bit-vector . simple-bit-vector-p)
    (simple-string . simple-string-p)
    (simple-vector . simple-vector-p)
    (single-float . short-float-p)
    (stream . streamp)
    (string . stringp)
    (extended-string . extended-string-p)
    (base-char . base-char-p)
    (extended-char . extended-char-p)
    (structure . structurep)
    (structure-object . structurep)
    (symbol . symbolp)
    (t . true)
    (unsigned-byte . unsigned-byte-p) ;unsigned-byte-p is not cl.
    (vector . vectorp)
    ))

(defmacro init-type-predicates ()
  `(dolist (pair ',type-pred-pairs)
     (setf (type-predicate (car pair)) (cdr pair))
     (let ((ctype (info-type-builtin (car pair))))       
       (if (typep ctype 'numeric-ctype)
         (setf (numeric-ctype-predicate ctype) (cdr pair))))))

)

(init-type-predicates)

(defun unsigned-byte-8-p (n)
  (and (fixnump n)
       (locally (declare (fixnum n))
         (and 
          (>= n 0)
          (< n #x100)))))

(defun signed-byte-8-p (n)
  (and (fixnump n)
       (locally (declare (fixnum n))
         (and 
          (>= n -128)
          (<= n 127)))))

(defun unsigned-byte-16-p (n)
  (and (fixnump n)
       (locally (declare (fixnum n))
         (and 
          (>= n 0)
          (< n #x10000)))))

(defun signed-byte-16-p (n)
  (and (fixnump n)
       (locally (declare (fixnum n))
         (and 
          (>= n -32768)
          (<= n 32767)))))

(defun unsigned-byte-32-p (n)
  (and (integerp n)
       (>= n 0)
       (<= n #xffffffff)))

(defun signed-byte-32-p (n)
  (and (integerp n)
       (>= n  -2147483648)
       (<= n 2147483647)))

(eval-when (:load-toplevel :execute)
  (let ((more-pairs
         '(((unsigned-byte 8) . unsigned-byte-8-p)
           ((signed-byte 8) . signed-byte-8-p)
           ((unsigned-byte 16) . unsigned-byte-16-p)
           ((signed-byte 16) . signed-byte-16-p)
           ((unsigned-byte 32) . unsigned-byte-32-p)
           ((signed-byte 32) . signed-byte-32-p))))         
    (dolist (pair more-pairs)
      (let ((ctype (info-type-builtin (car pair))))       
        (if (typep ctype 'numeric-ctype) (setf (numeric-ctype-predicate ctype) (cdr pair))))))
  )


(defun specifier-type-known (type)  
  (let ((ctype (specifier-type type)))
    (if (typep ctype 'unknown-ctype)
      (error "Unknown type specifier ~s." type)
      (if (and (typep ctype 'numeric-ctype) ; complexp??
               (eq 'integer (numeric-ctype-class ctype))
               (not (numeric-ctype-predicate ctype)))
        (setf (numeric-ctype-predicate ctype)(make-numeric-ctype-predicate ctype))))
    ctype))


(defun find-builtin-cell (type  &optional (create t))
  (let ((cell (gethash type %builtin-type-cells%)))
    (or cell
        (when create
          (setf (gethash type %builtin-type-cells%)
                (cons type (or (info-type-builtin type)(specifier-type-known type))))))))


; for now only called for builtin types or car = unsigned-byte, signed-byte, mod or integer

(defun builtin-typep (form cell)
  (unless (listp cell)
    (setq cell (require-type cell 'list)))
  (locally (declare (type list cell))
    (let ((ctype (cdr cell))
          (name (car cell)))
      (when (not ctype)
        (setq ctype (or (info-type-builtin name)(specifier-type-known name)))
        (when ctype (setf (gethash (car cell) %builtin-type-cells%) cell))
        (rplacd cell ctype))
      (if ctype 
        (if (and (typep ctype 'numeric-ctype)
                 (numeric-ctype-predicate ctype))
          ; doing this inline is a winner - at least if true
          (funcall (numeric-ctype-predicate ctype) form)
          (%%typep form ctype))
        (typep form name)))))

#|
(defvar %find-classes% (make-hash-table :test 'eq))

(defun find-class-cell (name create?)
  (let ((cell (gethash name %find-classes%)))
    (or cell
        (and create?
             (setf (gethash name %find-classes%) (cons name nil))))))
|#

;(setq *type-system-initialized* t)


;; Type-of, typep, and a bunch of other predicates.

;;; Data type predicates.

;;; things might be clearer if this stuff were in l1-typesys?
;;; Translation from type keywords to specific predicates.




;necessary since standard-char-p, by definition, errors if not passed a char.
(setf (type-predicate 'standard-char)
      #'(lambda (form) (and (characterp form) (standard-char-p form))))

(defun type-of (form)
  (cond ((null form) 'null)
        ((arrayp form) (describe-array form))
        (t (let ((class (class-of form)))
             (if (eq class *istruct-class*)
               (uvref form 0)
               (let ((name (class-name class)))
                 (if name
                   (if (eq name 'complex)
                     (cond ((floatp (realpart form)) '(complex float))
                           (t '(complex rational)))
                     name)
                   (%type-of form))))))))


;;; Create the list-style description of an array.

;made more specific by fry. slisp used  (mod 2) , etc.
;Oh.
; As much fun as this has been, I think it'd be really neat if
; it returned a type specifier.

(defun describe-array (array)
  (if (arrayp array)
    (type-specifier
     (specifier-type
      `(,(if (simple-array-p array) 'simple-array 'array) 
        ,(array-element-type array) 
        ,(array-dimensions array))))
    (report-bad-arg array 'array)))
  

;;;; TYPEP and auxiliary functions.



(defun type-specifier-p (form &aux sym)
  (cond ((symbolp form)
         (or (type-predicate form)
             (structure-class-p form)
             (%deftype-expander form)
             (find-class form nil)
             ))
        ((consp form)
         (setq sym (%car form))
         (or (type-specifier-p sym)
             (memq sym '(member satisfies mod))
             (and (memq sym '(and or not))
                  (dolist (spec (%cdr form) t)
                    (unless (type-specifier-p spec) (return nil))))))
        (t (typep form 'class))))

(defun built-in-type-p (type)
  (if (symbolp type)
    (or (type-predicate type)
        (let ((class (find-class type nil)))
          (and class (typep class 'built-in-class))))
    (and (consp type)
         (or (and (memq (%car type) '(and or not))
                  (every #'built-in-type-p (%cdr type)))
             (memq (%car type) '(array simple-array vector simple-vector
                                 string simple-string bit-vector simple-bit-vector 
                                 complex integer mod signed-byte unsigned-byte
                                 rational float short-float single-float
                                 double-float long-float real member))))))

(defun typep (object type &optional env)
  (declare (ignore env))
  (let* ((pred (if (symbolp type) (type-predicate type))))
    (if pred
      (funcall pred object)
      (%typep object type))))



;This is like check-type, except it returns the value rather than setf'ing
;anything, and so can be done entirely out-of-line.
(defun require-type (arg type)  
  (if (typep  arg type)
    arg
    (%kernel-restart $xwrongtype arg type)))

; Might want to use an inverted mapping instead of (satisfies ccl::obscurely-named)
(defun %require-type (arg predsym)
    (if (funcall predsym arg)
    arg
    (%kernel-restart $xwrongtype arg `(satisfies ,predsym))))

(defun %require-type-builtin (arg type-cell)  
  (if (builtin-typep arg type-cell)
    arg
    (%kernel-restart $xwrongtype arg (car type-cell))))






; Subtypep.

(defun subtypep (type1 type2 &optional env)
  (declare (ignore env))
  "Return two values indicating the relationship between type1 and type2:
  T and T: type1 definitely is a subtype of type2.
  NIL and T: type1 definitely is not a subtype of type2.
  NIL and NIL: who knows?"
  (csubtypep (specifier-type type1) (specifier-type type2)))




(defun preload-all-functions ()
  nil)


 ; used by arglist
(defun temp-cons (a b)
  (cons a b))




(defun copy-into-float (src dest)
  (%copy-double-float src dest))

(queue-fixup
 (defun fmakunbound (name)
   (let* ((fname (validate-function-name name)))
     (remhash fname %structure-refs%)
     (%unfhave fname))
   name))

(defun frozen-definition-p (name)
  (if (symbolp name)
    (%ilogbitp $sym_fbit_frozen (%symbol-bits name))))

(defun redefine-kernel-function (name)
  (when (and *warn-if-redefine-kernel*
             (frozen-definition-p name)
             (or (lfunp (fboundp name))
                 (and (not (consp name)) (macro-function name)))
             (or (and (consp name) (neq (car name) 'setf))
                 (let ((pkg (symbol-package (if (consp name) (cadr name) name))))
                   (or (eq *common-lisp-package* pkg) (eq *ccl-package* pkg)))))
    (cerror "Replace the definition of ~S."
            "The function ~S is predefined in OpenMCL." name)
    (unless (consp name)
      (proclaim-inline nil name))))

(defun fset (name function)
  (setq function (require-type function 'function))
  (when (symbolp name)
    (when (special-operator-p name)
      (error "Can not redefine a special-form: ~S ." name))
    (when (macro-function name)
      (cerror "Redefine the macro ~S as a function"
              "The macro ~S is being redefined as a function." name)))
; This lets us redefine %FHAVE.  Big fun.
  (let ((fhave #'%fhave))
    (redefine-kernel-function name)
    (fmakunbound name)
    (funcall fhave name function)
    function))

(defsetf symbol-function fset)
(defsetf fdefinition fset)

(defun set-macro-function (name macro-fun)
  (if (special-operator-p name)
    (error "Can not redefine a special-form: ~S ." name))
  (when (and (fboundp name) (not (macro-function name)))
    (cerror "Redefine function ~S as a macro."
            "The function ~S is being redefined as a macro." name))
  (redefine-kernel-function name)
  (fmakunbound name)
  (%macro-have name macro-fun)
  macro-fun)

(defsetf macro-function set-macro-function)



;;; Arrays and vectors, including make-array.



(defun make-array (dims &key (element-type t element-type-p)
                        displaced-to
                        displaced-index-offset
                        adjustable
                        fill-pointer
                        (initial-element nil initial-element-p)
                        (initial-contents nil initial-contents-p))
  (when (and initial-element-p initial-contents-p)
        (error "Cannot specify both ~S and ~S" :initial-element-p :initial-contents-p))
  (make-array-1 dims element-type element-type-p
                displaced-to
                displaced-index-offset
                adjustable
                fill-pointer
                initial-element initial-element-p
                initial-contents initial-contents-p
                nil))



(defun char (string index)
 (if (stringp string)
  (aref string index)
  (report-bad-arg string 'string)))

(defun set-char (string index new-el)
  (if (stringp string)
    (aset string index new-el)
    (report-bad-arg string 'string)))

(defun equalp (x y)
  "Just like EQUAL, but more liberal in several respects.
  Numbers may be of different types, as long as the values are identical
  after coercion.  Characters may differ in alphabetic case.  Vectors and
  arrays must have identical dimensions and EQUALP elements, but may differ
  in their type restriction.
  If one of x or y is a pathname and one is a string with the name of the
  pathname then this will return T."
  (cond ((eql x y) t)
        ((characterp x) (and (characterp y) (eq (char-upcase x) (char-upcase y))))
        ((numberp x) (and (numberp y) (= x y)))
        ((consp x)
         (and (consp y)
              (equalp (car x) (car y))
              (equalp (cdr x) (cdr y))))        
        ((pathnamep x) (equal x y))
        ((vectorp x)
         (and (vectorp y)
              (let ((length (length x)))
                (when (eq length (length y))
                  (dotimes (i length t)
                    (declare (fixnum i))
                    (let ((x-el (aref x i))
                          (y-el (aref y i)))
                      (unless (or (eq x-el y-el) (equalp x-el y-el))
                        (return nil))))))))
        ((arrayp x)
         (and (arrayp y)
              (let ((rank (array-rank x)) x-el y-el)
                (and (eq (array-rank y) rank)
                     (if (%izerop rank) (equalp (aref x) (aref y))
                         (and
                          (dotimes (i rank t)
                            (declare (fixnum i))
                            (unless (eq (array-dimension x i)
                                        (array-dimension y i))
                              (return nil)))
                          (multiple-value-bind (x0 i) (array-data-and-offset x)
                            (multiple-value-bind (y0 j) (array-data-and-offset y)
                              (dotimes (count (array-total-size x) t)
                                (declare (fixnum count))
                                (setq x-el (uvref x0 i) y-el (uvref y0 j))
                                (unless (or (eq x-el y-el) (equalp x-el y-el))
                                  (return nil))
                                (setq i (%i+ i 1) j (%i+ j 1)))))))))))
        ((and (structurep x) (structurep y))
	 (let ((size (uvsize x)))
	   (and (eq size (uvsize y))
	        (dotimes (i size t)
                  (declare (fixnum i))
		  (unless (equalp (uvref x i) (uvref y i))
                    (return nil))))))
        ((and (hash-table-p x) (hash-table-p y))
         (%hash-table-equalp x y))
        (t nil)))


; The compiler (or some transforms) might want to do something more interesting
; with these, but they have to exist as functions anyhow.



(defun complement (function)
  (let ((f (coerce-to-function function))) ; keep poor compiler from consing value cell
  #'(lambda (&rest args)
      (declare (dynamic-extent args)) ; not tail-recursive anyway
      (not (apply f args)))))

; Special variables are evil, but I can't think of a better way to do this.

(defparameter *outstanding-deferred-warnings* nil)
(def-accessors (deferred-warnings) %svref
  nil
  deferred-warnings.parent
  deferred-warnings.warnings
  deferred-warnings.defs
  deferred-warnings.flags ; might use to distinguish interactive case/compile-file
)

(defun %defer-warnings (override &optional flags)
  (%istruct 'deferred-warnings (unless override *outstanding-deferred-warnings*) nil nil flags))

(defun report-deferred-warnings ()
  (let* ((current *outstanding-deferred-warnings*)
         (parent (deferred-warnings.parent current))
         (defs (deferred-warnings.defs current))
         (warnings (deferred-warnings.warnings current))
         (any nil)
         (harsh nil))
    (if parent
      (setf (deferred-warnings.warnings parent) (append warnings (deferred-warnings.warnings parent))
            (deferred-warnings.defs parent) (append defs (deferred-warnings.defs parent))
            parent t)
      (let* ((file nil)
             (init t))
        (dolist (w warnings)
          (let ((wfname (car (compiler-warning-args w))))
            (when (if (typep w 'undefined-function-reference)
                    (not (or (fboundp wfname)
                             (assq wfname defs))))
              (multiple-value-setq (harsh any file) (signal-compiler-warning w init file harsh any))
              (setq init nil))))))
    (values (values any harsh parent))))

(defun print-nested-name (name-list stream)
  (if (null name-list)
    (princ "a toplevel form" stream)
    (progn
      (if (car name-list)
        (prin1 (%car name-list) stream)
        (princ "an anonymous lambda form" stream))
      (when (%cdr name-list)
        (princ " inside " stream)
        (print-nested-name (%cdr name-list) stream)))))

(defparameter *suppress-compiler-warnings* nil)

(defun signal-compiler-warning (w init-p last-w-file harsh-p any-p &optional eval-p)
  (let ((muffled *suppress-compiler-warnings*)
        (w-file (compiler-warning-file-name w))
        (s *error-output*))
    (unless muffled 
      (restart-case (signal w)
        (muffle-warning () (setq muffled t))))
    (unless muffled
      (setq any-p t)
      (unless (typep w 'style-warning) (setq harsh-p t))
      (when (or init-p (not (equalp w-file last-w-file)))
        (format s "~&;~A warnings " (if (null eval-p) "Compiler" "Interpreter"))
        (if w-file (format s "for ~S :" w-file) (princ ":" s)))
      (format s "~&;   ~A" w))
    (values harsh-p any-p w-file)))

;;;; Assorted mumble-P type predicates. 
;;;; No functions have been in the kernel for the last year or so.
;;;; (Just thought you'd like to know.)

(defun sequencep (form)
  "Not CL. SLISP Returns T if form is a sequence, NIL otherwise."
   (or (listp form) (vectorp form)))

;;; The following are not defined at user level, but are necessary for
;;; internal use by TYPEP.

(defun bitp (form)
  "Not CL. SLISP"
  (or (eq form 0) (eq form 1)))

(defun unsigned-byte-p (form)
  (and (integerp form) (not (< form 0))))

;This is false for internal structures.
;;; ---- look at defenv.structures, not defenv.structrefs

(defun structure-class-p (form &optional env)
  (and (symbolp form)
       (let ((sd (or (and env
                          (let ((defenv (definition-environment env)))
                            (and defenv
                                 (%cdr (assq form (defenv.structures defenv))))))
                     (gethash form %defstructs%))))
         (and sd
              (null (sd-type sd))
              sd))))


(defparameter *target-type-codes*
  '((:bignum #.ppc32::subtag-bignum)
    (:ratio #.ppc32::subtag-ratio)
    (:single-float #.ppc32::subtag-single-float . nil)
    (:double-float #.ppc32::subtag-double-float . nil)
    (:complex #.ppc32::subtag-complex  )
    (:symbol #.ppc32::subtag-symbol . nil)
    (:lfun-vector nil )
    (:function #.ppc32::subtag-function )
    (:code-vector #.ppc32::subtag-code-vector)
    (:macptr #.ppc32::subtag-macptr )
    (:catch-frame #.ppc32::subtag-catch-frame . nil)
    (:structure #.ppc32::subtag-struct )
    (:istruct #.ppc32::subtag-istruct )
    (:pool #.ppc32::subtag-pool )
    (:population #.ppc32::subtag-weak )
    (:hash-vector #.ppc32::subtag-hash-vector )
    (:package #.ppc32::subtag-package )
    (:value-cell #.ppc32::subtag-value-cell . nil)
    (:instance #.ppc32::subtag-instance )
    (:lock #.ppc32::subtag-lock )
    (:slot-vector #.ppc32::subtag-slot-vector)
    (:svar #.ppc32::subtag-svar)
    (:base-string #.ppc32::subtag-simple-base-string )
    (:bit-vector #.ppc32::subtag-bit-vector )
    (:signed-8-bit-vector #.ppc32::subtag-s8-vector )
    (:unsigned-8-bit-vector #.ppc32::subtag-u8-vector )
    (:signed-16-bit-vector #.ppc32::subtag-s16-vector )
    (:unsigned-16-bit-vector #.ppc32::subtag-u16-vector )
    (:signed-32-bit-vector #.ppc32::subtag-s32-vector )
    (:unsigned-32-bit-vector #.ppc32::subtag-u32-vector )
    (:single-float-vector #.ppc32::subtag-single-float-vector . nil)
    (:double-float-vector #.ppc32::subtag-double-float-vector )
    (:simple-vector #.ppc32::subtag-simple-vector )))


(defun type-keyword-code (type-keyword &optional platform)
  (declare (ignore platform))
  (let* ((entry (assq type-keyword *target-type-codes*)))
    (if entry
      (let* ((code (cadr entry)))
        (or code (error "Vector type ~s invalid," type-keyword)))
      (error "Unknown type-keyword ~s. " type-keyword))))


(defstruct id-map
  (vector (make-array 1 :initial-element nil))
  (free 0)
  (lock (make-lock)))

;;; Caller owns the lock on the id-map.
(defun id-map-grow (id-map)
  (without-interrupts
   (let* ((old-vector (id-map-vector id-map))
          (old-size (length old-vector))
          (new-size (+ old-size old-size))
          (new-vector (make-array new-size)))
     (declare (fixnum old-size new-size))
     (dotimes (i old-size)
       (setf (svref new-vector i) (svref old-vector i)))
     (let* ((limit (1- new-size)))
       (declare (fixnum limit))
       (do* ((i old-size (1+ i)))
            ((= i limit) (setf (svref new-vector i) nil))
         (declare (fixnum i))
         (setf (svref new-vector i) (the fixnum (1+ i)))))
     (setf (id-map-vector id-map) new-vector
           (id-map-free id-map) old-size))))

;;; Map an object to a small fixnum ID in id-map.
;;; Object can't be NIL or a fixnum itself.
(defun assign-id-map-id (id-map object)
  (if (or (null object) (typep object 'fixnum))
    (setq object (require-type object '(not (or null fixnum)))))
  (with-lock-grabbed ((id-map-lock id-map))
    (let* ((free (or (id-map-free id-map) (id-map-grow id-map)))
           (vector (id-map-vector id-map))
           (newfree (svref vector free)))
      (setf (id-map-free id-map) newfree
            (svref vector free) object)
      free)))
      
;;; Referemce the object with id ID in ID-MAP.  Leave the object in
;;; the map.
(defun id-map-object (id-map id)
  (let* ((object (with-lock-grabbed ((id-map-lock id-map))
                   (svref (id-map-vector id-map) id))))
    (if (or (null object) (typep object 'fixnum))
      (error "invalid index ~d for ~s" id id-map)
      object)))

;;; Referemce the object with id ID in ID-MAP.  Remove the object from
;;; the map.
(defun id-map-free-object (id-map id)
  (with-lock-grabbed ((id-map-lock id-map))
    (let* ((vector (id-map-vector id-map))
           (object (svref vector id)))
      (if (or (null object) (typep object 'fixnum))
        (error "invalid index ~d for ~s" id id-map))
      (setf (svref vector id) (id-map-free id-map)
            (id-map-free id-map) id)
      object)))

(defun id-map-modify-object (id-map id old-value new-value)
  (with-lock-grabbed ((id-map-lock id-map))
    (let* ((vector (id-map-vector id-map))
           (object (svref vector id)))
      (if (or (null object) (typep object 'fixnum))
        (error "invalid index ~d for ~s" id id-map))
      (if (eq object old-value)
	(setf (svref vector id) new-value)))))


    

(setq *type-system-initialized* t)
    


