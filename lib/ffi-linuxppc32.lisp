;;;-*- Mode: Lisp; Package: CCL -*-
;;;
;;;   Copyright (C) 2007, Clozure Associates and contributors
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

;;; LinuxPPC32:
;;; Structures are never actually passed by value; the caller
;;; instead passes a pointer to the structure or a copy of it.
;;; Structures whose size is 8 bytes or less are returned in r3/r4;
;;; this happens rarely enough that we can probably get away with
;;; boxing an :UNSIGNED-DOUBLEWORD and storing it in the structure-return
;;; argument.

(defun linux32::record-type-returns-structure-as-first-arg (rtype)
  (when (and rtype
             (not (typep rtype 'unsigned-byte))
             (not (member rtype *foreign-representation-type-keywords*
                          :test #'eq)))
    (let* ((ftype (if (typep rtype 'foreign-type)
                    rtype
                    (parse-foreign-type rtype))))
      (and (typep ftype 'foreign-record-type)
           (> (ensure-foreign-type-bits ftype) 64)))))


(defun linux32::expand-ff-call (callform args &key (arg-coerce #'null-coerce-foreign-arg) (result-coerce #'null-coerce-foreign-result))
  (let* ((result-type-spec (or (car (last args)) :void))
         (enclosing-form nil)
         (result-form nil))
    (multiple-value-bind (result-type error)
        (parse-foreign-type result-type-spec)
      (if error
        (setq result-type-spec :void result-type *void-foreign-type*)
        (setq args (butlast args)))
      (collect ((argforms))
        (when (eq (car args) :monitor-exception-ports)
          (argforms (pop args)))
        (when (typep result-type 'foreign-record-type)
          (if (linux32::record-type-returns-structure-as-first-arg result-type)
            (progn
              (setq result-type *void-foreign-type*
                    result-type-spec :void)
              (argforms :address)
              (argforms result-form))
            (progn
              (setq result-type (parse-foreign-type :unsigned-doubleword)
                    result-type-spec :unsigned-doubleword
                    enclosing-form `(setf (%%get-unsigned-longlong ,result-form))))))
        (unless (evenp (length args))
          (error "~s should be an even-length list of alternating foreign types and values" args))        
        (do* ((args args (cddr args)))
             ((null args))
          (let* ((arg-type-spec (car args))
                 (arg-value-form (cadr args)))
            (if (or (member arg-type-spec *foreign-representation-type-keywords*
                           :test #'eq)
                    (typep arg-type-spec 'unsigned-byte))
              (progn
                (argforms arg-type-spec)
                (argforms arg-value-form))
              (let* ((ftype (parse-foreign-type arg-type-spec)))
                (if (typep ftype 'foreign-record-type)
                  (progn
                    (argforms :address)
                    (argforms arg-value-form))
                  (progn
                    (argforms (foreign-type-to-representation-type ftype))
                    (argforms (funcall arg-coerce arg-type-spec arg-value-form))))))))
        (argforms (foreign-type-to-representation-type result-type))
        (let* ((call (funcall result-coerce result-type-spec `(,@callform ,@(argforms)))))
          (if enclosing-form
            `(,@enclosing-form ,call)
            call))))))

;;; Return 7 values:
;;; A list of RLET bindings
;;; A list of LET* bindings
;;; A list of DYNAMIC-EXTENT declarations for the LET* bindings
;;; A list of initializaton forms for (some) structure args
;;; A FOREIGN-TYPE representing the "actual" return type.
;;; A form which can be used to initialize FP-ARGS-PTR, relative
;;;  to STACK-PTR.  (This is unused on linuxppc32.)
;;; The byte offset of the foreign return address, relative to STACK-PTR
(defun linux32::generate-callback-bindings (stack-ptr fp-args-ptr argvars argspecs result-spec struct-result-name)
  (declare (ignore fp-args-ptr))
  (collect ((lets)
            (rlets)
            (dynamic-extent-names))
    (let* ((rtype (parse-foreign-type result-spec)))
      (when (typep rtype 'foreign-record-type)
        (let* ((bits (ensure-foreign-type-bits rtype)))
          (if (<= bits 64)
            (rlets (list struct-result-name (foreign-record-type-name rtype)))
            (setq argvars (cons struct-result-name argvars)
                  argspecs (cons :address argspecs)
                  rtype *void-foreign-type*))))
          (let* ((offset  96)
                 (gpr 0)
                 (fpr 32))
            (do* ((argvars argvars (cdr argvars))
                  (argspecs argspecs (cdr argspecs)))
                 ((null argvars)
                  (values (rlets) (lets) (dynamic-extent-names) nil rtype nil 0 #|wrong|#))
              (let* ((name (car argvars))
                     (spec (car argspecs))
                     (nextgpr gpr)
                     (nextfpr fpr)
                     (nextoffset offset)
                     (target gpr)
                     (bias 0)
                     (argtype (parse-foreign-type spec)))
                (if (typep argtype 'foreign-record-type)
                  (setq argtype (parse-foreign-type :address)))
                (let* ((access-form
                        `(,(cond
                            ((typep argtype 'foreign-single-float-type)
                             (incf nextfpr 8)
                             (if (< fpr 96)
                               (setq target fpr)
                               (setq target (+ offset (logand offset 4))
                                     nextoffset (+ target 8)))
                             '%get-single-float-from-double-ptr)
                            ((typep argtype 'foreign-double-float-type)
                             (incf nextfpr 8)
                             (if (< fpr 96)
                               (setq target fpr)
                               (setq target (+ offset (logand offset 4))
                                     nextoffset (+ target 8)))
                             '%get-double-float)
                            ((and (typep argtype 'foreign-integer-type)
                                  (= (foreign-integer-type-bits argtype) 64)
                                  (foreign-integer-type-signed argtype))
                             (if (< gpr 56)
				     (setq target (+ gpr (logand gpr 4))
					   nextgpr (+ 8 target))
				     (setq target (+ offset (logand offset 4))
					   nextoffset (+ 8 offset)))
				   '%%get-signed-longlong)
                            ((and (typep argtype 'foreign-integer-type)
                                  (= (foreign-integer-type-bits argtype) 64)
                                  (not (foreign-integer-type-signed argtype)))
                             (if (< gpr 56)
                               (setq target (+ gpr (logand gpr 4))
                                     nextgpr (+ 8 target))
                               (setq target (+ offset (logand offset 4))
                                     nextoffset (+ 8 offset)))
                             '%%get-unsigned-longlong)
                            (t
                             (incf nextgpr 4)
                             (if (< gpr 64)
                               (setq target gpr)
                               (setq target offset nextoffset (+ offset 4)))
                             (cond ((typep argtype 'foreign-pointer-type) '%get-ptr)
                                   ((typep argtype 'foreign-integer-type)
                                    (let* ((bits (foreign-integer-type-bits argtype))
                                           (signed (foreign-integer-type-signed argtype)))
                                      (cond ((<= bits 8)
                                             (setq bias 3)
                                             (if signed
                                               '%get-signed-byte '
                                               '%get-unsigned-byte))
                                            ((<= bits 16)
                                             (setq bias 2)
                                             (if signed
                                               '%get-signed-word 
                                               '%get-unsigned-word))
                                            ((<= bits 32)
                                             (if signed
                                               '%get-signed-long 
                                               '%get-unsigned-long))
                                            (t
                                             (error "Don't know how to access foreign argument of type ~s" (unparse-foreign-type argtype))))))
                                   (t
                                    (error "Don't know how to access foreign argument of type ~s" (unparse-foreign-type argtype))))))
                          ,stack-ptr
                          ,(+ target bias))))
                  (lets (list name access-form))
                  (when (eq spec :address)
                    (dynamic-extent-names name))
                  (setq gpr nextgpr fpr nextfpr offset nextoffset))))))))

(defun linux32::generate-callback-return-value (stack-ptr fp-args-ptr result return-type struct-return-arg)
  (declare (ignore fp-args-ptr))
  (unless (eq return-type *void-foreign-type*)
    (let* ((return-type-keyword
            (if (typep return-type 'foreign-record-type)
              (progn
                (setq result `(%%get-unsigned-longlong ,struct-return-arg 0))
                :unsigned-doubleword)
              (foreign-type-to-representation-type return-type)))
           (offset (case return-type-keyword
                   ((:single-float :double-float)
                    8)
                   (t 0))))
      `(setf (,
              (case return-type-keyword
                (:address '%get-ptr)
                (:signed-doubleword '%%get-signed-longlong)
                (:unsigned-doubleword '%%get-unsigned-longlong)
                ((:double-float :single-float) '%get-double-float)
                (t '%get-long)) ,stack-ptr ,offset) ,result))))
      
                 
