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




(eval-when (:compile-toplevel :execute)

; undistinguished values of nhash.lock
(defconstant $nhash.lock-while-growing #x10000)
(defconstant $nhash.lock-while-rehashing #x20000)
(defconstant $nhash.lock-grow-or-rehash #x30000)
(defconstant $nhash.lock-map-count-mask #xffff)
(defconstant $nhash.lock-not-while-rehashing #x-20001)

; The hash.vector cell contains a vector with 8 longwords of overhead
; followed by alternating keys and values.
; A key of $undefined denotes an empty or deleted value
; The value will be $undefined for empty values, or NIL for deleted values.
(def-accessors () %svref
  nhash.vector.link                     ; GC link for weak vectors
  nhash.vector.flags                    ; a fixnum of flags
  nhash.vector.free-alist               ; empty alist entries for finalization
  nhash.vector.finalization-alist       ; deleted out key/value pairs put here
  nhash.vector.weak-deletions-count     ; incremented when the GC deletes an element
  nhash.vector.hash                     ; back-pointer
  nhash.vector.deleted-count            ; number of deleted entries
  nhash.vector.cache-idx                ; index of last cached key/value pair
  nhash.vector.cache-key                ; cached key
  nhash.vector.cache-value              ; cached value
  )

; number of longwords of overhead in nhash.vector.
; Must be a multiple of 2 or INDEX parameters in LAP code will not be tagged as fixnums.
(defconstant $nhash.vector_overhead 10)

(defconstant $nhash_weak_bit 12)        ; weak hash table
(defconstant $nhash_weak_value_bit 11)  ; weak on value vice key if this bit set
(defconstant $nhash_finalizeable_bit 10)
(defconstant $nhash_weak_flags_mask
  (bitset $nhash_weak_bit (bitset $nhash_weak_value_bit (bitset $nhash_finalizeable_bit 0))))

(defconstant $nhash_track_keys_bit 28)  ; request GC to track relocation of keys.
(defconstant $nhash_key_moved_bit 27)   ; set by GC if a key moved.
(defconstant $nhash_ephemeral_bit 26)   ; set if a hash code was computed using an address
                                        ; in ephemeral space
(defconstant $nhash_component_address_bit 25) ; a hash code was computed from a key's component


(defconstant $nhash-growing-bit 16)
(defconstant $nhash-rehashing-bit 17)

)
   
(defmacro immediate-p-macro (thing)	; boot weirdness
  (let* ((tag (gensym)))
    (target-arch-case
     (:ppc32
      `(let* ((,tag (lisptag ,thing)))
        (declare (fixnum ,tag))
        (or (= ,tag ppc32::tag-fixnum)
         (= ,tag ppc32::tag-imm))))
      (:ppc64
      `(let* ((,tag (lisptag ,thing)))
        (declare (fixnum ,tag))
        (or (= ,tag ppc64::tag-fixnum)
            (= (logand ,tag ppc64::lowtagmask) ppc64::lowtag-imm)))))))

(defmacro hashed-by-identity (thing)
  (let* ((typecode (gensym)))
    (target-arch-case
     (:ppc32
      `(let* ((,typecode (typecode ,thing)))
        (declare (fixnum ,typecode))
        (or
         (= ,typecode ppc32::tag-fixnum)
         (= ,typecode ppc32::tag-imm)
         (= ,typecode ppc32::subtag-symbol)
         (= ,typecode ppc32::subtag-instance))))
     (:ppc64
      `(let* ((,typecode (typecode ,thing)))
        (declare (fixnum ,typecode))
        (or
         (= ,typecode ppc64::tag-fixnum)
         (= (logand ,typecode ppc64::lowtagmask) ppc64::lowtag-imm)
         (= ,typecode ppc64::subtag-symbol)
         (= ,typecode ppc64::subtag-instance)))))))
          
	 
  

; state is #(index vector hash-table saved-lock)
(def-accessors %svref
  hti.index
  hti.vector
  hti.hash-table
  hti.lock
  hti.locked-additions)


;;; The rehash-lock is exclusive.  It must be held by any thread that
;;; might want to rehash the hash table (after GC.)
(defmacro with-rehash-lock ((hash) &body body)
  `(with-lock-grabbed ((nhash.rehash-lock ,hash))
    ,@body))

;;; There can (in general) be multiple simultaneous readers (GETHASH, etc)
;;; of a hash table; write access requires exlusivity.

(defmacro with-hash-read-lock ((hash) &body body)
  `(with-read-lock ((nhash.exclusion-lock ,hash))
    ,@body))

(defmacro with-hash-write-lock ((hash) &body body)
  `(with-write-lock ((nhash.exclusion-lock ,hash))
    ,@body))

;;; To ... er, um, ... expedite implementation, we lock the hash
;;; table exclusively whenever touching it.  For now.

(defmacro with-exclusive-hash-lock ((hash) &body body)
  `(with-hash-write-lock (,hash) ,@body))
