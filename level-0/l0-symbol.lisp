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

;;; No error checking, no interrupts, no protect_caller, no nuthin.
;;; No error, no cons.  No problem.
(defun %progvrestore (saved)
  (declare (optimize (speed 3) (safety 0)))
  (dolist (pair saved)
    (%set-sym-value (car pair) (cdr pair))))

;;; Check that something that's supposed to be a proper list of
;;; symbols is; error otherwise.
;;; This is called only by the compiler output of a PROGV form.
;;; It checks for the maximum length that the progvsave subprim
;;; can handle.

(defun check-symbol-list (l &optional (max-length
                                        (floor (- 4096 20) (* target::node-size 3))
                                       ))
  (let ((len (list-length l)))
    (if (and len
             (or (null max-length)
                 (< len max-length))
             (dolist (s l t) 
               (unless (and (symbolp s)
                            (not (constant-symbol-p s))
                            (not (logbitp $sym_vbit_global (the fixnum (%symbol-bits s))))
                            (ensure-binding-index s))
                 (return nil))))
      l
      (error "~s is not a proper list of bindable symbols~@[ of length < ~s~]." l max-length))))

;;; The type-checking done on the "plist" arg shouldn't be removed.
(defun set-symbol-plist (sym plist)
  (let* ((len (list-length plist)))
    (unless (and len (evenp len))
      (error "Bad plist: ~s" plist)))
  (setf (%svref (%symbol->symptr sym) target::symbol.plist-cell) plist))


(eval-when (:compile-toplevel :execute)
  (declaim (inline %pl-search)))

(defun %pl-search (l key)
  (declare (list l) (optimize (speed 3)))
  (loop
    (if (eq (car l) key)
      (return)
      (if l
        (setq l (cdr (the list (cdr l))))
        (return))))
  l)


(defun symbol-plist (sym)
  "Return SYMBOL's property list."
  (%svref (%symbol->symptr sym) target::symbol.plist-cell))


(defun get (sym key &optional default)
  "Look on the property list of SYMBOL for the specified INDICATOR. If this
  is found, return the associated value, else return DEFAULT."
  (let* ((tail (%pl-search
                (%svref (%symbol->symptr sym) target::symbol.plist-cell) key)))
    (if tail (%cadr tail) default)))

(defun put (sym key value)
  (let* ((symptr (%symbol->symptr sym))
         (plist (%svref symptr target::symbol.plist-cell))
         (tail (%pl-search plist key)))
    (if tail 
      (%rplaca (%cdr tail) value)
      (setf (%svref symptr target::symbol.plist-cell) (cons key (cons value plist))))
    value))


(defun get-type-predicate (name)
  (let* ((symptr (%symbol->symptr name))
         (pp (%svref symptr target::symbol.package-predicate-cell)))
    (if (consp pp)
      (%cdr pp))))


(defun set-type-predicate (name function)
  (let* ((bits (%symbol-bits name))
         (symptr (%symbol->symptr name))
         (spp (%svref symptr target::symbol.package-predicate-cell)))
    (declare (fixnum bits))
    (if (logbitp $sym_vbit_typeppred bits)
      (%rplacd spp function)
      (progn
        (%symbol-bits name (the fixnum (bitset $sym_vbit_typeppred bits)))
        (setf (%svref symptr target::symbol.package-predicate-cell) (cons spp function))))))

(defun symbol-value (sym)
  "Return SYMBOL's current bound value."
  (let* ((val (%sym-value sym)))
    (if (eq val (%unbound-marker))
      (%kernel-restart $xvunbnd sym)
      val)))

(defun set (sym value)
  "Set SYMBOL's value cell to NEW-VALUE."
  (let* ((bits (%symbol-bits sym)))
    (declare (fixnum bits))
    (if (logbitp $sym_vbit_const bits)
      (%err-disp $XCONST sym)
      (%set-sym-value sym value))))

(defun constant-symbol-p (sym)
  (and (symbolp sym)
       (%ilogbitp $sym_vbit_const (%symbol-bits sym))))

;;; This leaves the SPECIAL bit alone, clears the others.
(defun makunbound (sym)
  "Make SYMBOL unbound, removing any value it may currently have."
  (if (and *warn-if-redefine-kernel*
           (constant-symbol-p sym))
    (cerror "Make ~S be unbound anyway."
            "~S is a constant; making it unbound might be a bad idea." sym))
  (%symbol-bits sym (the fixnum (logand (logior #xff00 (ash 1 $sym_bit_special))
                                        (the fixnum (%symbol-bits sym)))))
  (%set-sym-value sym (%unbound-marker))
  sym)

(defun non-nil-symbolp (x)
  "Returns symbol if true"
  (if (symbolp x) x))

(defun symbol-package (sym)
  "Return the package SYMBOL was interned in, or NIL if none."
  (let* ((pp (%svref (%symbol->symptr sym) target::symbol.package-predicate-cell)))
    (if (consp pp) (car pp) pp)))

(defun boundp (sym)
  "Return non-NIL if SYMBOL is bound to a value."
  (not (eq (%sym-value sym) (%unbound-marker))))

(defun make-symbol (name)
  "Make and return a new symbol with the NAME as its print name."
  (%gvector target::subtag-symbol
                (ensure-simple-string name) ; pname
                (%unbound-marker)       ; value cell
                %unbound-function%      ; function cell
                nil                     ; package&predicate
                0                       ; flags
                nil                     ; plist
                0))                       ; binding-index

(defun %symbol-bits (sym &optional new)
  (let* ((p (%symbol->symptr sym))
         (bits (%svref p target::symbol.flags-cell)))
    (if new
      (setf (%svref p target::symbol.flags-cell) new))
    bits))

(defun %sym-value (name)
  (%symptr-value (%symbol->symptr name)))

(defun %set-sym-value (name val)
  (%set-symptr-value (%symbol->symptr name) val))
    
(defun %sym-global-value (name)
  (%svref (%symbol->symptr name) target::symbol.vcell-cell))

(defun %set-sym-global-value (name val)
  (setf (%svref (%symbol->symptr name) target::symbol.vcell-cell) val))

(defun symbol-name (sym)
  "Return SYMBOL's name as a string."
  #+ppc32-target
  (%svref (%symbol->symptr sym) ppc32::symbol.pname-cell)
  #+ppc64-target
  (if sym                               ;NIL's pname is implicit
    (%svref (%symbol->symptr sym) ppc64::symbol.pname-cell)
    "NIL")
  )




(defun %global-macro-function (symbol)
  (let* ((fbinding (fboundp symbol)))
    (if (and (typep fbinding 'simple-vector)
             (= (the fixnum (uvsize fbinding)) 2))
      (let* ((fun (%svref fbinding 1)))
        (if (functionp fun) fun)))))

(defun %symbol-binding-address (sym)
  (%symptr-binding-address (%symbol->symptr sym)))

(defun symbol-binding-index (sym)
  (%svref (%symbol->symptr sym) target::symbol.binding-index-cell))

(defvar *interrupt-level* -1)

;;; Special binding indices, and the inverse mapping between indices
;;; and symbols
(let* ((binding-index-lock (make-lock))
       (binding-index-reverse-map (make-hash-table :test #'eq :weak :value))
       (next-binding-index 0))
  (defun %set-binding-index (val) (setq next-binding-index val))
  (defun next-binding-index () (1+ next-binding-index))
  (defun ensure-binding-index (sym)
    (with-lock-grabbed (binding-index-lock)
      (let* ((symptr (%symbol->symptr sym))
             (idx (%svref symptr target::symbol.binding-index-cell))
             (bits (%symbol-bits sym)))
        (declare (fixnum idx bits))
        (if (or (logbitp $sym_vbit_global bits)
                (logbitp $sym_vbit_const bits))
          (unless (zerop idx)
            (remhash idx binding-index-reverse-map)
            (setf (%svref symptr target::symbol.binding-index-cell) 0))
          (if (zerop idx)
            (let* ((new-idx (incf next-binding-index)))
              (setf (%svref symptr target::symbol.binding-index-cell) new-idx)
              (setf (gethash new-idx binding-index-reverse-map) sym))))
        sym)))
  (defun binding-index-symbol (idx)
    (with-lock-grabbed (binding-index-lock)
      (gethash idx binding-index-reverse-map)))
  (defun cold-load-binding-index (sym)
    ;; Index may have been assigned via xloader.  Update
    ;; reverse map
    (with-lock-grabbed (binding-index-lock)
      (let* ((idx (%svref sym target::symbol.binding-index-cell)))
        (declare (fixnum idx))
        (unless (zerop idx)
          (setf (gethash idx binding-index-reverse-map) sym))))))

       

