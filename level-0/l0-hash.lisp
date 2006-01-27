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

;;;;;;;;;;;;;
;;
;; hash.lisp
;; New hash table implementation

;;;;;;;;;;;;;
;;
;; Things I didn't do
;;
;; Save the 32-bit hash code along with the key so that growing the table can
;; avoid calling the hashing function (at least until a GC happens during growing).
;;
;; Maybe use Knuth's better method for hashing:
;; find two primes N-2, N.  N is the table size.
;; First probe is at primary = (mod (funcall (nhash.keytransF h) key) N)
;; Secondary probes are spaced by (mod (funcall (nhash.keytransF h) key) N-2)
;; This does a bit better scrambling of the secondary probes, but costs another divide.
;;
;; Rethink how finalization is reported to the user.  Maybe have a finalization function which
;; is called with the hash table and the deleted key & value.


;;;;;;;;;;;;;
;;
;; Documentation
;;
;; MAKE-HASH-TABLE is extended to accept a :HASH-FUNCTION keyword arg which
;; defaults for the 4 Common Lisp defined :TEST's.  Also, any fbound symbol can
;; be used for the :TEST argument.  The HASH-FUNCTION is a function of one
;; argument, the key, which returns two values:
;;
;; 1) HASH-CODE
;; 2) ADDRESSP
;;
;; The HASH-CODE can be any object.  If it is a relocateable object (not a
;; fixnum, short float, or immediate) then ADDRESSP will default to :KEY
;; and it is an error if NIL is returned for ADDRESSP.
;;
;; If ADDRESSP is NIL, the hashing code assumes that no addresses were used
;; in computing the HASH-CODE.  If ADDRESSP is :KEY (which is the default
;; if the hash function returns only one value and it is relocateable) then
;; the hashing code assumes that only the KEY's address was used to compute
;; the HASH-CODE.  Otherwise, it is assumed that the address of a
;; component of the key was used to compute the HASH-CODE.
;;
;;
;;
;; Some (proposed) functions for using in user hashing functions:
;;
;; (HASH-CODE object)
;;
;; returns two values:
;;
;; 1) HASH-CODE
;; 2) ADDRESSP
;;
;; HASH-CODE is the object transformed into a fixnum by changing its tag
;; bits to a fixnum's tag.  ADDRESSP is true if the object was
;; relocateable. 
;;
;;
;; (FIXNUM-ADD o1 o2)
;; Combines two objects additively and returns a fixnum.
;; If the two objects are fixnums, will be the same as (+ o1 o2) except
;; that the result can not be a bignum.
;;
;; (FIXNUM-MULTIPLY o1 o2)
;; Combines two objects multiplicatively and returns a fixnum.
;;
;; (FIXNUM-FLOOR dividend &optional divisor)
;; Same as Common Lisp's FLOOR function, but converts the objects into
;; fixnums before doing the divide and returns two fixnums: quotient &
;; remainder.
;;
;;;;;;;;;;;;;
;;
;; Implementation details.
;;
;; Hash table vectors have a header that the garbage collector knows about
;; followed by alternating keys and values.  Empty or deleted slots are
;; denoted by a key of $undefined.  Empty slots have a value of $undefined.
;; Deleted slots have a value of NIL.
;;
;;
;; Five bits in the nhash.vector.flags fixnum interact with the garbage
;; collector.  This description uses the symbols that represent bit numbers
;; in a fixnum.  $nhash_xxx_bit has a corresponding $nhash_lap_xxx_bit which
;; gives the byte offset of the bit for LAP code.  The two bytes in
;; question are at offsets $nhash.vector-weak-byte and
;; $nhash.vector-track-keys-byte offsets from the tagged vector.
;; The 32 bits of the fixnum at nhash.vector.flags look like:
;;
;;     TK0C0000 00000000 WVF00000 00000000
;;
;;
;; $nhash_track_keys_bit         "T" in the diagram above
;;                               Sign bit of the longword at $nhash.vector.flags
;;                               or the byte at $nhash.vector-track-keys-byte.
;;                               If set, GC tracks relocation of keys in the
;;                               vector.
;; $nhash_key_moved_bit          "K" in the diagram above
;;                               Set by GC to indicate that a key moved.
;;                               If $nhash_track_keys_bit is clear, this bit is set to
;;                               indicate that any GC will require a rehash.
;;                               GC never clears this bit, but may set it if
;;                               $nhash_track_keys_bit is set.
;; $nhash_component_address_bit  "C" in the diagram above.
;;                               Ignored by GC.  Set to indicate that the
;;                               address of a component of a key was used. 
;;                               Means that $nhash_track_keys_bit will
;;                               never be set until all such keys are
;;                               removed.
;; $nhash_weak_bit               "W" in the diagram above
;;                               Sign bit of the byte at $nhash.vector-weak-byte
;;                               Set to indicate a weak hash table
;; $nhash_weak_value_bit         "V" in the diagram above
;;                               If clear, the table is weak on key
;;                               If set, the table is weak on value
;; $nhash_finalizeable_bit       "F" in the diagram above
;;                               If set the table is finalizeable:
;;                               If any key/value pairs are removed, they will be added to
;;                               the nhash.vector.finalization-alist using cons cells
;;                               from nhash.vector.free-alist





(eval-when (:compile-toplevel :execute)
  (require "HASHENV" "ccl:xdump;hashenv")
  (require :number-case-macro)
  (define-symbol-macro free-hash-key-marker (%unbound-marker))
  (define-symbol-macro deleted-hash-key-marker (%slot-unbound-marker))
  (declaim (inline nhash.vector-size))
  (declaim (inline mixup-hash-code))
  (declaim (inline hash-table-p))
  (declaim (inline %%eqhash))
  (declaim (inline index->vector-index vector-index->index swap))
  (declaim (inline %already-rehashed-p %set-already-rehashed-p))
  (declaim (inline need-use-eql))
  (declaim (inline %needs-rehashing-p))
  (declaim (inline compute-hash-code))
  (declaim (inline eq-hash-find eq-hash-find-for-put))
  (declaim (inline lock-hash-table unlock-hash-table)))

(defun %cons-hash-table (rehash-function keytrans-function compare-function vector
                                         threshold rehash-ratio rehash-size address-based find find-new owner)
  (%istruct
   'HASH-TABLE                          ; type
   rehash-function                      ; nhash.rehashF
   keytrans-function                    ; nhash.keytransF
   compare-function                     ; nhash.compareF
   nil                                  ; nhash.rehash-bits
   vector                               ; nhash.vector
   0                                    ; nhash.lock
   0                                    ; nhash.count
   owner                                ; nhash.owner 
   (get-fwdnum)                         ; nhash.fixnum
   (gc-count)                           ; nhash.gc-count
   threshold                            ; nhash.grow-threshold
   rehash-ratio                         ; nhash.rehash-ratio
   rehash-size                          ; nhash.rehash-size
   0                                    ; nhash.puthash-count
   (unless owner
     (make-read-write-lock))               ; nhash.exclusion-lock
   nil ;;(make-lock)				; nhash.rehash-lock
   nil                                  ; nhash.iterator
   address-based                        ; nhash.address-based
   find                                 ; nhash.find
   find-new                             ; nhash.find-new
   ))


 
(defun nhash.vector-size (vector)
  (ash (the fixnum (- (the fixnum (uvsize vector)) $nhash.vector_overhead)) -1))

;;; Is KEY something which can be EQL to something it's not EQ to ?
;;; (e.g., is it a number or macptr ?)
;;; This can be more general than necessary but shouldn't be less so.
(defun need-use-eql (key)
  (let* ((typecode (typecode key)))
    (declare (fixnum typecode))
    (or (= typecode target::subtag-macptr)
        #+ppc32-target
        (and (>= typecode ppc32::min-numeric-subtag)
             (<= typecode ppc32::max-numeric-subtag))
        #+ppc64-target
        (or (= typecode ppc64::subtag-bignum)
            (= typecode ppc64::subtag-double-float)
            (= typecode ppc64::subtag-ratio)
            (= typecode ppc64::subtag-complex)))))

;;; Don't rehash at all, unless some key is address-based (directly or
;;; indirectly.)
(defun %needs-rehashing-p (hash)
  (let ((flags (nhash.vector.flags (nhash.vector hash))))
    (declare (fixnum flags))
    (if (logbitp $nhash_track_keys_bit flags)
      ;; GC is tracking key movement
      (logbitp $nhash_key_moved_bit flags)
      ;; GC is not tracking key movement
      (if (logbitp $nhash_component_address_bit flags)
        (not (eql (the fixnum (gc-count)) (the fixnum (nhash.gc-count hash))))))))

(defun %set-does-not-need-rehashing (hash)
  (get-fwdnum hash)
  (gc-count hash)
  (let* ((vector (nhash.vector hash))
         (flags (nhash.vector.flags vector)))
    (declare (fixnum flags))
    (when (logbitp $nhash_track_keys_bit flags)
      (setf (nhash.vector.flags vector)
            (logand (lognot (ash 1 $nhash_key_moved_bit)) flags)))))

(defun %set-needs-rehashing (hash)
  (setf (nhash.fixnum hash)   (the fixnum (1- (the fixnum (get-fwdnum))))
        (nhash.gc-count hash) (the fixnum (1- (the fixnum (gc-count)))))
  (let* ((vector (nhash.vector hash))
         (flags (nhash.vector.flags vector)))
    (declare (fixnum flags))
    (when (logbitp $nhash_track_keys_bit flags)
      (setf (nhash.vector.flags vector) (logior (ash 1 $nhash_key_moved_bit) flags)))))

(defun mixup-hash-code (fixnum)
  (declare (fixnum fixnum))
  (the fixnum
    (+ fixnum
       (the fixnum (%ilsl (- 32 8)
                          (logand (1- (ash 1 (- 8 3))) fixnum))))))


#+(or ppc32-target ppc64-target)
(defun rotate-hash-code (fixnum)
  (declare (fixnum fixnum))
  (let* ((low-3 (logand 7 fixnum))
         (but-low-3 (%ilsr 3 fixnum))
         (low-3*64K (%ilsl 13 low-3))
         (low-3-in-high-3 (%ilsl (- 32 3 3) low-3)))
    (declare (fixnum low-3 but-low-3 low-3*64K low-3-in-high-3))
    (the fixnum (+ low-3-in-high-3
                   (the fixnum (logxor low-3*64K but-low-3))))))

#+(and nil ppc64-target)
(defun rotate-hash-code (fixnum)
  (declare (fixnum fixnum))
  (logior (logand #xffff (the fixnum (ash fixnum -16)))
          (ash (the fixnum (logand fixnum #xffff)) 16)))


(defconstant $nhash-track-keys-mask
  #.(- (ash 1 $nhash_track_keys_bit)))

(defconstant $nhash-clear-key-bits-mask #xfffff)


;;; Hash on address, or at least on some persistent, immutable
;;; attribute of the key.  If all keys are fixnums or immediates (or if
;;; that attribute exists), rehashing won't ever be necessary.
(defun %%eqhash (key)
  (let* ((typecode (typecode key)))
    (if (eq typecode target::tag-fixnum)
      (values (mixup-hash-code key) nil)
      (if (eq typecode target::subtag-instance)
        (values (mixup-hash-code (instance.hash key)) nil)
        (if (eq typecode target::subtag-symbol)
          (let* ((name (if key (%svref key target::symbol.pname-cell) "NIL")))
            (values (mixup-hash-code (string-hash name 0 (length name))) nil))
          (let ((hash (mixup-hash-code (strip-tag-to-fixnum key))))
            (if (immediate-p-macro key)
              (values hash nil)
              (values hash :key ))))))))


(defun swap (num)
  (declare (fixnum num))
  (the fixnum (+ (the fixnum (%ilsl 16 num))(the fixnum (%ilsr 13 num)))))

;;; teeny bit faster when nothing to do
(defun %%eqlhash-internal (key)
  (number-case key
    (fixnum (mixup-hash-code key)) ; added this 
    (double-float (%dfloat-hash key))
    (short-float (%sfloat-hash key))
    (bignum (%bignum-hash key))
    (ratio (logxor (swap (%%eqlhash-internal (numerator key)))
                   (%%eqlhash-internal (denominator key))))
    (complex
     (logxor (swap (%%eqlhash-internal (realpart key)))
             (%%eqlhash-internal (imagpart key))))
    (t (cond ((macptrp key)
              (%macptr-hash key))
             (t key)))))

               


;;; new function

(defun %%eqlhash (key)
  ;; if key is a macptr, float, bignum, ratio, or complex, convert it
  ;; to a fixnum
  (if (hashed-by-identity key)
    (%%eqhash key)
    (let ((primary  (%%eqlhash-internal key)))
      (if (eq primary key)
        (%%eqhash key)
        (mixup-hash-code (strip-tag-to-fixnum primary))))))

;; call %%eqlhash

(defun string-hash (key start len)
  (declare (fixnum start len))
  (let* ((res len))
    (dotimes (i len)
      (let ((code (%scharcode key (%i+ i start))))
	(setq code (mixup-hash-code code))
	(setq res (%i+ (rotate-hash-code res) code))))
    res))



(defun %%equalhash (key)
  (let* ((id-p (hashed-by-identity key))
         (hash (if (and key (not id-p)) (%%eqlhash-internal key)))
         addressp)
    (cond ((null key) (mixup-hash-code 17))
          #+ppc64-target
          ((and (typep key 'single-float)
                (zerop (the single-float key)))
           0)
          ((immediate-p-macro key) (mixup-hash-code (strip-tag-to-fixnum key)))
          ((and hash (neq hash key)) hash)  ; eql stuff
          (t (typecase key
                (simple-string (string-hash key 0 (length key)))
                (string
                 (let ((length (length key)))
                   (multiple-value-bind (data offset) (array-data-and-offset key)
                     (string-hash data offset length))))
                (bit-vector (bit-vector-hash key))
                (cons
                 (let ((hash 0))
                   (do* ((i 0 (1+ i))
                         (list key (cdr list)))
                        ((or (not (consp list)) (> i 11))) ; who figured 11?
                     (declare (fixnum i))
                     (multiple-value-bind (h1 a1) (%%equalhash (%car list))
                       (when a1 (setq addressp t))
                       ; fix the case of lists of same stuff in different order
                       ;(setq hash (%ilogxor (fixnum-rotate h1 i) hash))
                       (setq hash (%i+ (rotate-hash-code hash) h1))
                       ))
                   (values hash addressp)))
                (pathname (%%equalphash key))
                (t (%%eqlhash key)))))))

(defun compute-hash-code (hash key update-hash-flags &optional
                               (vector (nhash.vector hash))) ; vectorp))
  (let ((keytransF (nhash.keytransF hash))
        primary addressp)
    (if (not (fixnump keytransF))
      ;; not EQ or EQL hash table
      (progn
        (multiple-value-setq (primary addressp) (funcall keytransF key))
        (let ((immediate-p (immediate-p-macro primary)))
          (setq primary (strip-tag-to-fixnum primary))
          (unless immediate-p
            (setq primary (mixup-hash-code primary))
            (setq addressp :key))))
      ;; EQ or EQL hash table
      (if (and (not (eql keytransF 0))
	       (need-use-eql key))
	;; EQL hash table
	(setq primary (%%eqlhash-internal key))
	;; EQ hash table - or something eql doesn't do
	(multiple-value-setq (primary addressp) (%%eqhash key))))
    (when addressp
      (when update-hash-flags
        (let ((flags (nhash.vector.flags vector)))
          (declare (fixnum flags))
          (if (eq :key addressp)
            ;; hash code depended on key's address
            (unless (logbitp $nhash_component_address_bit flags)
              (when (not (logbitp $nhash_track_keys_bit flags))
                (setq flags (bitclr $nhash_key_moved_bit flags)))
              (setq flags (logior $nhash-track-keys-mask flags)))
            ;; hash code depended on component address
            (progn
              (setq flags (logand (lognot $nhash-track-keys-mask) flags))
              (setq flags (bitset $nhash_component_address_bit flags))))
          (setf (nhash.vector.flags vector) flags))))
    (let* ((length (- (the fixnum (uvsize  vector)) $nhash.vector_overhead))
           (entries (ash length -1)))
      (declare (fixnum length entries))
      (values primary
              (fast-mod primary entries)
              entries))))

(defun %already-rehashed-p (primary rehash-bits)
  (declare (optimize (speed 3)(safety 0)))
  (declare (type (simple-array bit (*)) rehash-bits))
  (eql 1 (aref rehash-bits primary)))

(defun %set-already-rehashed-p (primary rehash-bits)
  (declare (optimize (speed 3)(safety 0)))
  (declare (type (simple-array bit (*)) rehash-bits))
  (setf (aref rehash-bits primary) 1))


(defun hash-table-p (hash)
  (istruct-typep hash 'hash-table))

(defun %normalize-hash-table-count (hash)
  (let* ((vector (nhash.vector hash))
         (weak-deletions-count (nhash.vector.weak-deletions-count vector)))
    (declare (fixnum weak-deletions-count))
    (unless (eql 0 weak-deletions-count)
      (setf (nhash.vector.weak-deletions-count vector) 0)
      (let ((deleted-count (the fixnum
                             (+ (the fixnum (nhash.vector.deleted-count vector))
                                weak-deletions-count)))
            (count (the fixnum (- (the fixnum (nhash.count hash)) weak-deletions-count))))
        (setf (nhash.vector.deleted-count vector) deleted-count
              (nhash.count hash) count)))))


(defparameter *shared-hash-table-default* t
  "Be sure that you understand the implications of changing this
before doing so.")

(defun make-hash-table (&key (test 'eql)
                             (size 60)
                             (rehash-size 1.5)
                             (rehash-threshold .85)
                             (hash-function nil)
                             (weak nil)
                             (finalizeable nil)
                             (address-based t)
                             (shared *shared-hash-table-default*))
  "Create and return a new hash table. The keywords are as follows:
     :TEST -- Indicates what kind of test to use.
     :SIZE -- A hint as to how many elements will be put in this hash
       table.
     :REHASH-SIZE -- Indicates how to expand the table when it fills up.
       If an integer, add space for that many elements. If a floating
       point number (which must be greater than 1.0), multiply the size
       by that amount.
     :REHASH-THRESHOLD -- Indicates how dense the table can become before
       forcing a rehash. Can be any positive number <=1, with density
       approaching zero as the threshold approaches 0. Density 1 means an
       average of one entry per bucket."
  (unless (and test (or (functionp test) (symbolp test)))
    (report-bad-arg test '(and (not null) (or symbol function))))
  (unless (or (functionp hash-function) (symbolp hash-function))
    (report-bad-arg hash-function '(or symbol function)))
  (unless (and (realp rehash-threshold) (<= 0.0 rehash-threshold) (<= rehash-threshold 1.0))
    (report-bad-arg rehash-threshold '(real 0 1)))
  (unless (or (fixnump rehash-size) (and (realp rehash-size) (< 1.0 rehash-size)))
    (report-bad-arg rehash-size '(or fixnum (real 1 *))))
  (unless (fixnump size) (report-bad-arg size 'fixnum))
  (setq rehash-threshold (/ 1.0 (max 0.01 rehash-threshold)))
  (let* ((default-hash-function
             (cond ((or (eq test 'eq) (eq test #'eq)) 
                    (setq test 0))
                   ((or (eq test 'eql) (eq test #'eql)) 
                    (setq test -1))
                   ((or (eq test 'equal) (eq test #'equal))
                    (setq test #'equal) #'%%equalhash)
                   ((or (eq test 'equalp) (eq test #'equalp))
                    (setq test #'equalp) #'%%equalphash)
                   (t (setq test (require-type test 'symbol))
                   (or hash-function 
                       (error "non-standard test specified without hash-function")))))
         (find-function
          (case test
            (0 #'eq-hash-find)
            (-1 #'eql-hash-find)
            (t #'general-hash-find)))
         (find-put-function
          (case test
            (0 #'eq-hash-find-for-put)
            (-1 #'eql-hash-find-for-put)
            (t #'general-hash-find-for-put))))
    (setq hash-function
          (if hash-function
            (require-type hash-function 'symbol)
            default-hash-function))
    (when (and weak (neq weak :value) (neq test 0))
      (error "Only EQ hash tables can be weak."))
    (when (and finalizeable (not weak))
      (error "Only weak hash tables can be finalizeable."))
    (multiple-value-bind (size total-size)
        (compute-hash-size (1- size) 1 rehash-threshold)
      (let* ((flags (if weak
                      (+ (+
                          (ash 1 $nhash_weak_bit)
                          (ecase weak
                            ((t :key) 0)
                            (:value (ash 1 $nhash_weak_value_bit))))
                         (if finalizeable (ash 1 $nhash_finalizeable_bit) 0))
                      0))
             (hash (%cons-hash-table 
                    #'%no-rehash hash-function test
                    (%cons-nhash-vector total-size flags)
                    size rehash-threshold rehash-size address-based
                    find-function find-put-function
                    (unless shared *current-process*))))
        (setf (nhash.vector.hash (nhash.vector hash)) hash)
        hash))))

(defun compute-hash-size (size rehash-size rehash-ratio)
  (let* ((new-size size))
    (setq new-size (max 30 (if (fixnump rehash-size)
                             (+ size rehash-size)
                             (ceiling (* size rehash-size)))))
    (if (<= new-size size)
      (setq new-size (1+ size)))        ; God save you if you make this happen
    
    (values new-size 
            (%hash-size (max (+ new-size 2) (ceiling (* new-size rehash-ratio)))))))

;;;  Suggested size is a fixnum: number of pairs.  Return a fixnum >=
;;;  that size that is relatively prime to all secondary keys.
(defun %hash-size (suggestion)
  (declare (fixnum suggestion))
  (declare (optimize (speed 3)(safety 0)))
  (if (<= suggestion #.(aref secondary-keys 7))
    (setq suggestion (+ 2 #.(aref secondary-keys 7)))
     (setq suggestion (logior 1 suggestion)))
  (loop
    (dovector (key secondary-keys (return-from %hash-size suggestion))
      (when (eql 0 (fast-mod suggestion key))
        (return)))
    (incf suggestion 2)))







;;; what if somebody is mapping, growing, rehashing? 
(defun clrhash (hash)
  "This removes all the entries from HASH-TABLE and returns the hash table
   itself."
  (unless (hash-table-p hash)
    (report-bad-arg hash 'hash-table))
  (without-interrupts
   (lock-hash-table hash)
   (let* ((vector (nhash.vector hash))
          (size (nhash.vector-size vector))
          (count (+ size size))
          (index $nhash.vector_overhead))
     (declare (fixnum size count index))
     (dotimes (i count)
       (setf (%svref vector index) (%unbound-marker))
       (incf index))
     (incf (the fixnum (nhash.grow-threshold hash))
           (the fixnum (+ (the fixnum (nhash.count hash))
                          (the fixnum (nhash.vector.deleted-count vector)))))
     (setf (nhash.count hash) 0
           (nhash.vector.cache-key vector) (%unbound-marker)
           (nhash.vector.cache-value vector) nil
           (nhash.vector.finalization-alist vector) nil
           (nhash.vector.free-alist vector) nil
           (nhash.vector.weak-deletions-count vector) 0
           (nhash.vector.deleted-count vector) 0
           (nhash.vector.flags vector) (logand $nhash_weak_flags_mask
                                               (nhash.vector.flags vector))))
   (unlock-hash-table hash)
   hash))

(defun index->vector-index (index)
  (declare (fixnum index))
  (the fixnum (+ $nhash.vector_overhead (the fixnum (+ index index)))))

(defun vector-index->index (index)
  (declare (fixnum index))
  (the fixnum (ash (the fixnum (- index $nhash.vector_overhead)) -1)))


(defun hash-table-count (hash)
  "Return the number of entries in the given HASH-TABLE."
  (require-type hash 'hash-table)
  (%normalize-hash-table-count hash)
  (the fixnum (nhash.count hash)))

(defun hash-table-rehash-size (hash)
  "Return the rehash-size HASH-TABLE was created with."
  (nhash.rehash-size (require-type hash 'hash-table)))

(defun hash-table-rehash-threshold (hash)
  "Return the rehash-threshold HASH-TABLE was created with."
  (/ 1.0 (nhash.rehash-ratio (require-type hash 'hash-table))))

(defun hash-table-size (hash)
  "Return a size that can be used with MAKE-HASH-TABLE to create a hash
   table that can hold however many entries HASH-TABLE can hold without
   having to be grown."
  (%i+ (the fixnum (hash-table-count hash))
       (the fixnum (nhash.grow-threshold hash))
       (the fixnum (nhash.vector.deleted-count (nhash.vector hash)))))

(defun hash-table-test (hash)
  "Return the test HASH-TABLE was created with."
  (let ((f (nhash.compareF (require-type hash 'hash-table))))
    (if (fixnump f)
      (if (eql 0 f) 'eq 'eql)
      (let ((name (if (symbolp f) f (function-name f))))
        (if (memq name '(equal equalp)) name f)))))

;;; sometimes you'd rather have the function than the symbol.
(defun hash-table-test-function (hash)
  (let ((f (nhash.compareF (require-type hash 'hash-table))))
    (if (fixnump f)
      (if (eql 0 f) #'eq #'eql)
      f)))

;; Finalization-list accessors are in "ccl:lib;hash" because SETF functions
;;  don't get dumped as "simple" %defuns.
;; 


(defun lock-hash-table (hash)
  (let* ((lock (nhash.exclusion-lock hash)))
    (if lock
      (write-lock-rwlock lock)
      (progn (unless (eq (nhash.owner hash) *current-process*)
               (error "Not owner of hash table ~s" hash))))))

(defun unlock-hash-table (hash)
  (let* ((lock (nhash.exclusion-lock hash)))
    (if lock
      (unlock-rwlock lock))))

(defun gethash (key hash &optional default)
  "Finds the entry in HASH-TABLE whose key is KEY and returns the associated
   value and T as multiple values, or returns DEFAULT and NIL if there is no
   such entry. Entries can be added using SETF."
  (unless (hash-table-p hash)
    (report-bad-arg hash 'hash-table))
  (let* ((value nil)
         (foundp nil))
    (without-interrupts
      (block protected
        (lock-hash-table hash)
        (%lock-gc-lock)
        (when (%needs-rehashing-p hash)
          (%rehash hash))
        (let* ((vector (nhash.vector hash)))
          (if (eq key (nhash.vector.cache-key vector))
            (setq foundp t
                  value (nhash.vector.cache-value vector))
            (let* ((vector-index (funcall (nhash.find hash) hash key))
                   (vector-key (%svref vector vector-index)))
              (declare (fixnum vector-index))
              (if (setq foundp (and (not (eq vector-key free-hash-key-marker))
                                    (not (eq vector-key deleted-hash-key-marker))))
                (setf value (%svref vector (the fixnum (1+ vector-index)))
                      (nhash.vector.cache-key vector) vector-key
                      (nhash.vector.cache-value vector) value
                      (nhash.vector.cache-idx vector) (vector-index->index
                                                       vector-index)))))))
      (%unlock-gc-lock)
      (unlock-hash-table hash))
    (if foundp
      (values value t)
      (values default nil))))

(defun remhash (key hash)
  "Remove the entry in HASH-TABLE associated with KEY. Return T if there
   was such an entry, or NIL if not."
  (unless (hash-table-p hash)
    (setq hash (require-type hash 'hash-table)))
  (let* ((foundp nil))
    (without-interrupts
     (lock-hash-table hash)
     (%lock-gc-lock)
     (when (%needs-rehashing-p hash)
       (%rehash hash))    
     (let* ((vector (nhash.vector hash)))
       (if (eq key (nhash.vector.cache-key vector))
         (progn
           (do* ((iterator (nhash.iterator hash) (hti.prev-iterator iterator)))
                ((null iterator))
             (unless (= (the fixnum (hti.index iterator))
                        (the fixnum (nhash.vector.cache-idx vector))) 
               (unlock-hash-table hash)
               (%unlock-gc-lock)
               (error "Can't remove key ~s during iteration on hash-table ~s"
                      key hash)))
           (setf (nhash.vector.cache-key vector) free-hash-key-marker
                 (nhash.vector.cache-value vector) nil)
           (let ((vidx (index->vector-index (nhash.vector.cache-idx vector))))
             (setf (%svref vector vidx) deleted-hash-key-marker)
             (setf (%svref vector (the fixnum (1+ vidx))) nil))
           (incf (the fixnum (nhash.vector.deleted-count vector)))
           (decf (the fixnum (nhash.count hash)))
           (setq foundp t))
         (let* ((vector-index (funcall (nhash.find hash) hash key))
                (vector-key (%svref vector vector-index)))
           (declare (fixnum vector-index))
           (when (setq foundp (and (not (eq vector-key free-hash-key-marker))
                                   (not (eq vector-key deleted-hash-key-marker))))
             (do* ((iterator (nhash.iterator hash) (hti.prev-iterator iterator)))
                  ((null iterator))
               (unless (= (the fixnum (hti.index iterator))
                          (the fixnum (vector-index->index vector-index)))
                 (unlock-hash-table hash)
                 (%unlock-gc-lock)
                 (error "Can't remove key ~s during iteration on hash-table ~s"
                        key hash)))
             ;; always clear the cache cause I'm too lazy to call the
             ;; comparison function and don't want to keep a possibly
             ;; deleted key from being GC'd
             (setf (nhash.vector.cache-key vector) free-hash-key-marker
                   (nhash.vector.cache-value vector) nil)
             ;; Update the count
             (incf (the fixnum (nhash.vector.deleted-count vector)))
             (decf (the fixnum (nhash.count hash)))
             ;; Remove a cons from the free-alist if the table is finalizeable
             (when (logbitp $nhash_finalizeable_bit (nhash.vector.flags vector))
               (pop (the list (svref nhash.vector.free-alist vector))))
             ;; Delete the value from the table.
             (setf (%svref vector vector-index) deleted-hash-key-marker
                   (%svref vector (the fixnum (1+ vector-index))) nil)))))
     ;; Return T if we deleted something
     (%unlock-gc-lock)
     (unlock-hash-table hash))
    foundp))

(defun puthash (key hash default &optional (value default))
  (declare (optimize (speed 3) (space 0)))
  (unless (hash-table-p hash)
    (report-bad-arg hash 'hash-table))
  (without-interrupts
   (block protected
     (lock-hash-table hash)
     (%lock-gc-lock)
     (when (%needs-rehashing-p hash)
       (%rehash hash))
     (do* ((iterator (nhash.iterator hash) (hti.prev-iterator iterator)))
          ((null iterator))
       (let* ((vector (hti.vector iterator))
              (index (index->vector-index (hti.index iterator)))
              (test (hash-table-test hash)))
         (declare (fixnum index))
         (when (and (< index (the fixnum (uvsize vector)))
                    (not (funcall test (%svref vector index) key)))
           (unlock-hash-table hash)
           (%unlock-gc-lock)
           (error "Can't add key ~s during iteration on hash-table ~s"
                  key hash))))
     (let ((vector (nhash.vector  hash)))     
       (when (eq key (nhash.vector.cache-key vector))
         (let* ((idx (nhash.vector.cache-idx vector)))
           (declare (fixnum idx))
           (setf (%svref vector (the fixnum (1+ (the fixnum (index->vector-index idx)))))
                 value)
           (setf (nhash.vector.cache-value vector) value)
           (return-from protected)))               
       (let* ((vector-index (funcall (nhash.find-new hash) hash key))
              (old-value (%svref vector vector-index)))
         (declare (fixnum vector-index))

         (cond ((eq old-value deleted-hash-key-marker)
                (%set-hash-table-vector-key vector vector-index key)
                (setf (%svref vector (the fixnum (1+ vector-index))) value)
                (setf (nhash.count hash) (the fixnum (1+ (the fixnum (nhash.count hash)))))
                ;; Adjust deleted-count
                (when (> 0 (the fixnum
                             (decf (the fixnum
                                     (nhash.vector.deleted-count vector)))))
                  (let ((weak-deletions (nhash.vector.weak-deletions-count vector)))
                    (declare (fixnum weak-deletions))
                    (setf (nhash.vector.weak-deletions-count vector) 0)
                    (incf (the fixnum (nhash.vector.deleted-count vector)) weak-deletions)
                    (decf (the fixnum (nhash.count hash)) weak-deletions))))
               ((eq old-value free-hash-key-marker)
                (when (eql 0 (nhash.grow-threshold hash))                 
                  (grow-hash-table hash)
                  (return-from protected (puthash key hash value)))
                (%set-hash-table-vector-key vector vector-index key)
                (setf (%svref vector (the fixnum (1+ vector-index))) value)
                (decf (the fixnum (nhash.grow-threshold hash)))
                (incf (the fixnum (nhash.count hash))))
               (t
                ;; Key was already there, update value.
                (setf (%svref vector (the fixnum (1+ vector-index))) value)))
         (setf (nhash.vector.cache-idx vector) (vector-index->index vector-index)
               (nhash.vector.cache-key vector) key
               (nhash.vector.cache-value vector) value))))
   (%unlock-gc-lock)
   (unlock-hash-table hash))
  value)


(defun count-entries (hash)
  (let* ((vector (nhash.vector hash))
         (size (uvsize vector))
         (idx $nhash.vector_overhead)
         (count 0))
    (loop
      (when (neq (%svref vector idx) (%unbound-marker))
        (incf count))
      (when (>= (setq idx (+ idx 2)) size)
        (return count)))))





     

;;; Grow the hash table, then add the given (key value) pair.
(defun grow-hash-table (hash)
  (unless (hash-table-p hash)
    (setq hash (require-type hash 'hash-table)))
  (%grow-hash-table hash))

;;; Interrupts are disabled, and the caller has an exclusive
;;; lock on the hash table.
(defun %grow-hash-table (hash)
  (block grow-hash-table
    (%normalize-hash-table-count hash)
    (let* ((old-vector (nhash.vector hash))
           (old-size (nhash.count hash))
           (old-total-size (nhash.vector-size old-vector))
           (flags 0)
           (flags-sans-weak 0)
           (weak-flags)
           rehashF)
      (declare (fixnum old-total-size flags flags-sans-weak weak-flags))    
      ; well we knew lock was 0 when we called this - is it still 0?
      (when (> (nhash.vector.deleted-count old-vector) 0)
        ;; There are enough deleted entries. Rehash to get rid of them
        (%rehash hash)
        (return-from grow-hash-table))
      (multiple-value-bind (size total-size)
                           (compute-hash-size 
                            old-size (nhash.rehash-size hash) (nhash.rehash-ratio hash))
        (unless (eql 0 (nhash.grow-threshold hash))       ; maybe it's done already - shouldnt happen                
          (return-from grow-hash-table ))
        (progn ;without-interrupts  ; this ???
          (unwind-protect
            (let ((fwdnum (get-fwdnum))
                  (gc-count (gc-count))
                  vector)
              (setq flags (nhash.vector.flags old-vector)
                    flags-sans-weak (logand flags (logxor -1 $nhash_weak_flags_mask))
                    weak-flags (logand flags $nhash_weak_flags_mask)
                    rehashF (nhash.rehashF hash))          
              (setf (nhash.lock hash) (%ilogior (nhash.lock hash) $nhash.lock-while-growing) ; dont need
                    (nhash.rehashF hash) #'%am-growing
                    (nhash.vector.flags old-vector) flags-sans-weak)      ; disable GC weak stuff
              (%normalize-hash-table-count hash)
              (setq vector (%cons-nhash-vector total-size 0))
              (do* ((index 0 (1+ index))
                    (vector-index (index->vector-index 0) (+ vector-index 2)))
                   ((>= index old-total-size))
                (declare (fixnum index vector-index))
                
                 (let ((key (%svref old-vector vector-index)))
                   (unless (or (eq key free-hash-key-marker)
                               (eq key deleted-hash-key-marker))
                     (let* ((new-index (%growhash-probe vector hash key))
                            (new-vector-index (index->vector-index new-index)))
                       (setf (%svref vector new-vector-index) key)
                       (setf (%svref vector (the fixnum (1+ new-vector-index)))
                             (%svref old-vector (the fixnum (1+ vector-index))))))))
              (without-interrupts  ; trying this ???
               (setf (nhash.vector.finalization-alist vector)
                     (nhash.vector.finalization-alist old-vector)
                     (nhash.vector.free-alist vector)
                     (nhash.vector.free-alist old-vector)
                     (nhash.vector.flags vector)
                     (logior weak-flags (the fixnum (nhash.vector.flags vector))))
               (setf (nhash.rehash-bits hash) nil
                     (nhash.vector hash) vector
                     (nhash.vector.hash vector) hash
                     (nhash.vector.cache-key vector) (%unbound-marker)
                     (nhash.vector.cache-value vector) nil
                     (nhash.fixnum hash) fwdnum
                     (nhash.gc-count hash) gc-count
                     (nhash.grow-threshold hash) (- size (nhash.count hash)))
               (when (eq #'%am-growing (nhash.rehashF hash))
                 ; if not changed to %maybe-rehash then contains no address based keys
                 (setf (nhash.rehashf hash) #'%no-rehash))
               (setq rehashF nil)       ; tell clean-up form we finished the loop
               (when (neq old-size (nhash.count hash))
                 (cerror "xx" "Somebody messed with count while growing")
                 (return-from grow-hash-table (grow-hash-table hash )))
               (when (minusp (nhash.grow-threshold hash))
                 (cerror "nn" "negative grow-threshold ~S ~s ~s ~s" 
                         (nhash.grow-threshold hash) size total-size old-size))
               ; If the old vector's in some static heap, zero it
               ; so that less garbage is retained.
	       (%init-misc 0 old-vector)))            
            (when rehashF
              (setf (nhash.rehashF hash) rehashF
                    (nhash.vector.flags old-vector)
                    (logior weak-flags (the fixnum (nhash.vector.flags old-vector)))))))))))



;;; values of nhash.rehashF
;;; %no-rehash - do nothing
;;; %maybe-rehash - if doesnt need rehashing - if is rehashing 0 else nil
;		  if locked 0
;		  else rehash, return t
;;; %am-rehashing - 0
;;; %am-growing   - calls %maybe-rehash

;;; compute-hash-code funcalls it if addressp and maybe-rehash-p
;;;                  sets to maybe-rehash if addressp and update-maybe-rehash (ie from puthash)
;;; grow-hash-table sets to %am-growing when doing so, resets to original value when done
;;; rehash sets to %am-rehashing, then to original when done

(defun %no-rehash (hash)
  (declare (%noforcestk)
           (optimize (speed 3) (safety 0))
           (ignore hash))
  nil)

(defun %maybe-rehash (hash)
  (declare (optimize (speed 3) (safety 0)))
  (cond ((not (%needs-rehashing-p hash))
         nil)
        (t (loop
             (%rehash hash)
             (unless (%needs-rehashing-p hash)
               (return))
             ;(incf n3)
             )
           t)))

(defun %am-rehashing (hash)
  (declare (optimize (speed 3) (safety 0))
           (ignore hash))
  0)

(defun %am-growing (hash)
  (declare (optimize (speed 3) (safety 0)))
  (%maybe-rehash hash))

(defun general-hash-find (hash key)
  (%hash-probe hash key nil))

(defun general-hash-find-for-put (hash key)
  (%hash-probe hash key t))

;;; returns a single value:
;;;   index - the index in the vector for key (where it was or where
;;;           to insert if the current key at that index is deleted-hash-key-marker
;;;           or free-hash-key-marker)


(defun %hash-probe (hash key update-hash-flags)
  (declare (optimize (speed 3) (space 0)))
  (multiple-value-bind (hash-code index entries)
                       (compute-hash-code hash key update-hash-flags)
    (locally (declare (fixnum hash-code index entries))
      (let* ((compareF (nhash.compareF hash))
             (vector (nhash.vector hash))
             (vector-index 0)
             table-key
             (first-deleted-index nil))
        (declare (fixnum vector-index))
        (macrolet ((return-it (form)
                     `(return-from %hash-probe ,form)))
          (macrolet ((test-it (predicate)
                       (unless (listp predicate) (setq predicate (list predicate)))
                       `(progn
                          (setq vector-index (index->vector-index index)
                                table-key (%svref vector vector-index))
                          (cond ((eq table-key free-hash-key-marker)
                                 (return-it (or first-deleted-index
                                                vector-index)))
                                ((eq table-key deleted-hash-key-marker)
                                 (when (null first-deleted-index)
                                   (setq first-deleted-index vector-index)))
                                ((,@predicate key table-key)
                                 (return-it vector-index))))))
            (macrolet ((do-it (predicate)
                         `(progn
                            (test-it ,predicate)
                            ; First probe failed. Iterate on secondary key
                            (let ((initial-index index)
                                  (secondary-hash (%svref secondary-keys (logand 7 hash-code))))
                              (declare (fixnum secondary-hash initial-index))
                              (loop
                                (incf index secondary-hash)
                                (when (>= index entries)
                                  (decf index entries))
                                (when (eql index initial-index)
                                  (unless first-deleted-index
                                    (error "No deleted entries in table"))
                                  (return-it first-deleted-index))
                                (test-it ,predicate))))))
              (if (fixnump comparef)
                ;; EQ or EQL hash table
                (if (or (eql 0 comparef)
                        (immediate-p-macro key)
                        (not (need-use-eql key)))
                  ;; EQ hash table or EQL == EQ for KEY
                  (do-it eq)
                  (do-it eql))
                ;; general compare function
                (do-it (funcall comparef))))))))))

(defun eq-hash-find (hash key)
  (declare (optimize (speed 3) (safety 0)))
  (let* ((vector (nhash.vector hash))
         (hash-code
          (let* ((typecode (typecode key)))
            (if (eq typecode target::tag-fixnum)
              (mixup-hash-code key)
              (if (eq typecode target::subtag-instance)
                (mixup-hash-code (instance.hash key))
                (if (eq typecode target::subtag-symbol)
                  (let* ((name (if key (%svref key target::symbol.pname-cell) "NIL")))
                    (mixup-hash-code (string-hash name 0 (length name))))
                  (mixup-hash-code (strip-tag-to-fixnum key)))))))
         (length (uvsize vector))
         (count (- length $nhash.vector_overhead))
         (entries (ash count -1))
         (vector-index (index->vector-index (fast-mod hash-code entries)))
         (table-key (%svref vector vector-index)))
    (declare (fixnum hash-code  entries vector-index count length))
    (if (or (eq key table-key)
            (eq table-key free-hash-key-marker))
      vector-index
      (let* ((secondary-hash (%svref secondary-keys-*-2
                                     (logand 7 hash-code)))
             (initial-index vector-index)             
             (first-deleted-index (if (eq table-key deleted-hash-key-marker)
                                    vector-index)))
        (declare (fixnum secondary-hash initial-index))
        (loop
          (incf vector-index secondary-hash)
          (when (>= vector-index length)
            (decf vector-index count))
          (setq table-key (%svref vector vector-index))
          (when (= vector-index initial-index)
            (return first-deleted-index))
          (if (eq table-key key)
            (return vector-index)
            (if (eq table-key free-hash-key-marker)
              (return (or first-deleted-index vector-index))
              (if (and (null first-deleted-index)
                       (eq table-key deleted-hash-key-marker))
                (setq first-deleted-index vector-index)))))))))

;;; As above, but note whether the key is in some way address-based
;;; and update the hash-vector's flags word if so.
;;; This only needs to be done by PUTHASH, and it only really needs
;;; to be done if we're adding a new key.
(defun eq-hash-find-for-put (hash key)
  (declare (optimize (speed 3) (safety 0)))
  (let* ((vector (nhash.vector hash))
         (hash-code
          (let* ((typecode (typecode key)))
            (if (eq typecode target::tag-fixnum)
              (mixup-hash-code key)
              (if (eq typecode target::subtag-instance)
                (mixup-hash-code (instance.hash key))
                (if (eq typecode target::subtag-symbol)
                  (let* ((name (if key (%svref key target::symbol.pname-cell) "NIL")))
                    (mixup-hash-code (string-hash name 0 (length name))))
                  (progn
                    (unless (immediate-p-macro key)
                      (let* ((flags (nhash.vector.flags vector)))
                        (declare (fixum flags))
                        (unless (logbitp $nhash_track_keys_bit flags)
                          (setq flags (bitclr $nhash_key_moved_bit flags)))
                        (setf (nhash.vector.flags vector)
                              (logior $nhash-track-keys-mask flags))))
                    (mixup-hash-code (strip-tag-to-fixnum key))))))))
         (length (uvsize  vector))
         (count (- length $nhash.vector_overhead))
         (vector-index (index->vector-index (fast-mod hash-code (ash count -1))))
         (table-key (%svref vector vector-index)))
    (declare (fixnum hash-code length count entries vector-index))
    (if (or (eq key table-key)
            (eq table-key free-hash-key-marker))
      vector-index
      (let* ((secondary-hash (%svref secondary-keys-*-2
                                     (logand 7 hash-code)))
             (initial-index vector-index)             
             (first-deleted-index (if (eq table-key deleted-hash-key-marker)
                                    vector-index)))
        (declare (fixnum secondary-hash initial-index))
        (loop
          (incf vector-index secondary-hash)
          (when (>= vector-index length)
            (decf vector-index count))
          (setq table-key (%svref vector vector-index))
          (when (= vector-index initial-index)
            (return first-deleted-index))
          (if (eq table-key key)
            (return vector-index)
            (if (eq table-key free-hash-key-marker)
              (return (or first-deleted-index vector-index))
              (if (and (null first-deleted-index)
                       (eq table-key deleted-hash-key-marker))
                (setq first-deleted-index vector-index)))))))))

(defun eql-hash-find (hash key)
  (declare (optimize (speed 3) (safety 0)))
  (if (need-use-eql key)
    (let* ((vector (nhash.vector hash))
           (hash-code (%%eqlhash-internal key))
           (length (uvsize  vector))
           (count (- length $nhash.vector_overhead))
           (entries (ash count -1))
           (vector-index (index->vector-index (fast-mod hash-code entries)))
           (table-key (%svref vector vector-index)))
      (declare (fixnum hash-code length entries count vector-index))
      (if (or (eql key table-key)
              (eq table-key free-hash-key-marker))
        vector-index
        (let* ((secondary-hash (%svref secondary-keys-*-2
                                       (logand 7 hash-code)))
               (initial-index vector-index)
               (first-deleted-index (if (eq table-key deleted-hash-key-marker)
                                      vector-index)))
          (declare (fixnum secondary-hash initial-index))
          (loop
            (incf vector-index secondary-hash)
            (when (>= vector-index length)
              (decf vector-index count))
            (setq table-key (%svref vector vector-index))
            (when (= vector-index initial-index)
              (return first-deleted-index))
          (if (eql table-key key)
            (return vector-index)
            (if (eq table-key free-hash-key-marker)
              (return (or first-deleted-index vector-index))
              (if (and (null first-deleted-index)
                       (eq table-key deleted-hash-key-marker))
                (setq first-deleted-index vector-index))))))))
    (eq-hash-find hash key)))

(defun eql-hash-find-for-put (hash key)
  (declare (optimize (speed 3) (safety 0)))
  (if (need-use-eql key)
    (let* ((vector (nhash.vector hash))
           (hash-code (%%eqlhash-internal key))
           (length (uvsize  vector))
           (count (- length $nhash.vector_overhead))
           (entries (ash count -1))
           (vector-index (index->vector-index (fast-mod hash-code entries)))
           (table-key (%svref vector vector-index)))
      (declare (fixnum hash-code length entries vector-index))
      (if (or (eql key table-key)
              (eq table-key free-hash-key-marker))
        vector-index
        (let* ((secondary-hash (%svref secondary-keys-*-2
                                       (logand 7 hash-code)))
               (initial-index vector-index)
               (first-deleted-index (if (eq table-key deleted-hash-key-marker)
                                      vector-index)))
          (declare (fixnum secondary-hash initial-index))
          (loop
            (incf vector-index secondary-hash)
            (when (>= vector-index length)
              (decf vector-index count))
            (setq table-key (%svref vector vector-index))
            (when (= vector-index initial-index)
              (return (or first-deleted-index
                          (error "Bug: no deleted entries in table"))))
            (if (eql table-key key)
              (return vector-index)
              (if (eq table-key free-hash-key-marker)
                (return (or first-deleted-index vector-index))
                (if (and (null first-deleted-index)
                         (eq table-key deleted-hash-key-marker))
                  (setq first-deleted-index vector-index))))))))
    (eq-hash-find-for-put hash key)))

;;; Rehash.  Caller should have exclusive access to the hash table
;;; and have disabled interrupts.
(defun %rehash (hash)
  (let* ((vector (nhash.vector hash))
         (flags (nhash.vector.flags vector))         )
    (setf (nhash.vector.flags vector)
          (logand flags $nhash-clear-key-bits-mask))
    (do-rehash hash)))


(defun %make-rehash-bits (hash &optional (size (nhash.vector-size (nhash.vector hash))))
  (declare (fixnum size))
  (let ((rehash-bits (nhash.rehash-bits hash)))
    (unless (and rehash-bits
                 (>= (uvsize rehash-bits) size))
      (return-from %make-rehash-bits
        (setf (nhash.rehash-bits hash) (make-array size :element-type 'bit :initial-element 0))))
    (fill (the simple-bit-vector rehash-bits) 0)))

(defun do-rehash (hash)
  (let* ((vector (nhash.vector hash))
         (vector-index (- $nhash.vector_overhead 2))
         (size (nhash.vector-size vector))
         (rehash-bits (%make-rehash-bits hash size))
         (index -1))
    (declare (fixnum size index vector-index))    
    (setf (nhash.vector.cache-key vector) (%unbound-marker)
          (nhash.vector.cache-value vector) nil)
    (%set-does-not-need-rehashing hash)
    (loop
      (when (>= (incf index) size) (return))
      (setq vector-index (+ vector-index 2))
      (unless (%already-rehashed-p index rehash-bits)
        (let* ((key (%svref vector vector-index))
               (deleted (eq key deleted-hash-key-marker)))
          (unless
            (when (or deleted (eq key free-hash-key-marker))
              (if deleted  ; one less deleted entry
                (let ((count (1- (nhash.vector.deleted-count vector))))
                  (declare (fixnum count))
                  (setf (nhash.vector.deleted-count vector) count)
                  (if (< count 0)
                    (let ((wdc (nhash.vector.weak-deletions-count vector)))
                      (setf (nhash.vector.weak-deletions-count vector) 0)
                      (incf (nhash.vector.deleted-count vector) wdc)
                      (decf (nhash.count hash) wdc)))
                  (incf (nhash.grow-threshold hash))
                  ;; Change deleted to free
                  (setf (%svref vector vector-index) free-hash-key-marker)))
              t)
            (let* ((last-index index)
                   (value (%svref vector (the fixnum (1+ vector-index))))
                   (first t))
                (loop
                  (let ((vector (nhash.vector hash))
                        (found-index (%rehash-probe rehash-bits hash key)))
                    (%set-already-rehashed-p found-index rehash-bits)
                    (if (eq last-index found-index)
                      (return)
                      (let* ((found-vector-index (index->vector-index found-index))
                             (newkey (%svref vector found-vector-index))
                             (newvalue (%svref vector (1+ found-vector-index))))
                        (when first ; or (eq last-index index) ?
                          (setq first nil)
                          (setf (%svref vector vector-index) free-hash-key-marker)
                          (setf (%svref vector (the fixnum (1+ vector-index))) free-hash-key-marker))
                        (%set-hash-table-vector-key vector found-vector-index key)
                        (setf (%svref vector (the fixnum (1+ found-vector-index))) value)                       
                        (when (or (eq newkey free-hash-key-marker)
                                  (setq deleted (eq newkey deleted-hash-key-marker)))
                          (when deleted  ; one less deleted entry - huh
                            (let ((count (1- (nhash.vector.deleted-count vector))))
                              (declare (fixnum count))
                              (setf (nhash.vector.deleted-count vector) count)
                              (if (< count 0)
                                (let ((wdc (nhash.vector.weak-deletions-count vector)))
                                  (setf (nhash.vector.weak-deletions-count vector) 0)
                                  (incf (nhash.vector.deleted-count vector) wdc)
                                  (decf (nhash.count hash) wdc)))
                              (incf (nhash.grow-threshold hash))))
                          (return))
                        (when  (eq key newkey)
                          (cerror "Delete one of the entries." "Duplicate key: ~s in ~s ~s ~s ~s ~s"
                                  key hash value newvalue index found-index)                       
                          (decf (nhash.count hash))
                          (incf (nhash.grow-threshold hash))
                          (return))
                        (setq key newkey
                              value newvalue
                              last-index found-index)))))))))))
    t )

;;; Hash to an index that is not set in rehash-bits
  
(defun %rehash-probe (rehash-bits hash key)
  (declare (optimize (speed 3)(safety 0)))  
  (multiple-value-bind (hash-code index entries)(compute-hash-code hash key t)
    (declare (fixnum hash-code index entries))
    (when (null hash-code)(cerror "nuts" "Nuts"))
    (let* ((vector (nhash.vector hash))
           (vector-index (index->vector-index  index)))
      (if (or (not (%already-rehashed-p index rehash-bits))
              (eq key (%svref vector vector-index)))
        (return-from %rehash-probe index)
        (let ((second (%svref secondary-keys (%ilogand 7 hash-code))))
          (declare (fixnum second))
          (loop
            (setq index (+ index second))
            (when (>= index entries)
              (setq index (- index entries)))
            (when (or (not (%already-rehashed-p index rehash-bits))
                      (eq key (%svref vector (index->vector-index index))))
              (return-from %rehash-probe index))))))))

;;; Returns one value: the index of the entry in the vector
;;; Since we're growing, we don't need to compare and can't find a key that's
;;; already there.
(defun %growhash-probe (vector hash key)
  (declare (optimize (speed 3)(safety 0)))
  (multiple-value-bind (hash-code index entries)(compute-hash-code hash key t vector)
    (declare (fixnum hash-code index entries))
    (let* ((vector-index (index->vector-index  index))
           (vector-key nil))
      (declare (fixnum vector-index))
      (if (or (eq free-hash-key-marker
                  (setq vector-key (%svref vector vector-index)))
              (eq deleted-hash-key-marker vector-key))
        (return-from %growhash-probe index)
        (let ((second (%svref secondary-keys (%ilogand 7 hash-code))))
          (declare (fixnum second))
          (loop
            (setq index (+ index second))
            (when (>= index entries)
              (setq index (- index entries)))
            (when (or (eq free-hash-key-marker
                          (setq vector-key (%svref vector (index->vector-index index))))
                      (eq deleted-hash-key-marker vector-key))
              (return-from %growhash-probe index))))))))

;;;;;;;;;;;;;
;;
;; Mapping functions are in "ccl:lib;hash"
;;



;;;;;;;;;;;;;
;;
;; Hashing functions
;; EQ & the EQ part of EQL are done in-line.
;;









;;; so whats so special about bit vectors as opposed to any other vectors of bytes
;;; For starters, it's guaranteed that they exist in the implementation; that may
;;; not be true of other immediate vector types.
(defun bit-vector-hash (bv)
  (declare (optimize (speed 3)(safety 0)))
  (let ((length (length bv)))
    (declare (fixnum length)) ;will this always be true? it's true of all vectors.
    (multiple-value-bind (data offset) (array-data-and-offset bv)
      (declare (type simple-bit-vector data) (fixnum offset))
      (let* ((hash 0)
             (limit (+ length offset))
             (nbytes (ash (the fixnum (+ length 7)) -3)))
        (declare (fixnum hash limit nbytes))
        (dotimes (i nbytes (mixup-hash-code hash))
          (let* ((w 0))
            (declare (fixnum w))
            (dotimes (j 8 (setq hash (+ (the fixnum (ash hash -3))  w)))
              (setq w (the fixnum
                        (logxor
                         (the fixnum
                           (ash (if (< offset limit) 
                                  (the fixnum (sbit data offset))
                                  0)
                                (the fixnum j)))
                         w)))
              (incf offset))))))))

#|
(defun bit-vector-hash (bv)
  (declare (optimize (speed 3)(safety 0)))
  (let ((length (length bv)))
    (declare (fixnum length))
    (let* ((all (+ length 15))
           (nwds (ash all -4))
           (rem (logand all 15))
           (hash 0)
           (mask (ash (the fixnum (1- (the fixnum (expt 2 rem))))(the fixnum(- 16 rem)))))
      (declare (fixnum all nwds rem hash mask))
      (multiple-value-bind (data offset)
                           (array-data-and-offset bv)
        (declare (fixnum offset))
        (locally (declare (type (simple-array (unsigned-byte 16) (*)) data))
          (dotimes (i nwds)
            (setq hash (%i+ hash (aref data (the fixnum (+ i offset))))))
          (when (neq 0 mask)            
            (setq hash (%i+ hash (%ilogand mask (aref data (the fixnum (+ offset nwds)))))))
          (mixup-hash-code hash))))))
|#


;;; Same as %%equalhash, but different:
;;;  1) Real numbers are hashed as if they were double-floats.  The real components of complex numbers
;;;     are hashed as double-floats and XORed together.
;;;  2) Characters and strings are hashed in a case-insensitive manner.
;;;  3) Hash tables are hashed based on their size and type.
;;;  4) Structures and CL array types are hashed based on their content.


;;; check fixnum befor immediate-p. call %%eqlhash

(defun %%equalphash (key)
  (cond ((or (fixnump key)(short-float-p key))
         (%dfloat-hash (float key 1.0d0))) 
        ((immediate-p-macro key)
         (mixup-hash-code (strip-tag-to-fixnum (if (characterp key)(char-upcase key) key))))
        ((bignump key)
         (if (<= most-negative-double-float key most-positive-double-float)
           (%dfloat-hash (float key 1.0d0))  ; with-stack-double-floats
           (%%eqlhash-internal key)))
        ((double-float-p key)
         (%dfloat-hash key))
        ((ratiop key)
         (%ilogxor (%%equalphash (numerator key)) (%%equalphash (denominator key))))
        ((complexp key)
         (%ilogxor (%%equalphash (realpart key)) (%%equalphash (imagpart key))))
        ((hash-table-p key)
         (equalphash-hash-table key))
        ((or (istructp key)
             (structurep key))  ; was (gvectorp key)
         (%%equalphash-structure 11 key))
        ((or (arrayp key)) ;(uvectorp key)) ;??
         (%%equalphash-array 11 key))
        ((consp key)
         (%%equalphash-aux 11 key))
        (t (%%eqlhash key))))


(defun equalphash-hash-table (hash-table)
  (let ((hash (%%equalhash "HASH-TABLE"))
        addressp)
    (declare (fixnum hash))
    (incf hash (the fixnum (%%eqhash (hash-table-count hash-table))))
    (multiple-value-bind (h ap) (%%eqhash (nhash.comparef hash-table))
      (declare (fixnum h))
      (incf hash h)
      (if ap (setq addressp t)))
    (multiple-value-bind (h ap) (%%eqhash (nhash.keytransF hash-table))
      (declare (fixnum h))
      (incf hash h)
      (if ap (setq addressp t)))
    (values hash addressp)))

(defun %%equalphash-structure (limit key)
  (let* ((size (uvsize key))
         (hash (mixup-hash-code size))
         addressp)
    (declare (fixnum limit size hash))
    (dotimes (i size)
      (multiple-value-bind (h ap) (%%equalphash-aux limit (%svref key i))
        (declare (fixnum h))
        (setq hash (the fixnum (+ (the fixnum (rotate-hash-code hash)) h)))
        (if ap (setq addressp t)))
      (when (<= (decf limit) 0)
        (setq hash (the fixnum (+ (the fixnum (rotate-hash-code hash))
                                  #.(mixup-hash-code 11))))
        (return)))
    (values hash addressp)))

(defun %%equalphash-array (limit key)
  (multiple-value-bind (array offset) (array-data-and-offset key)
    (let* ((rank (array-rank key))
           (vectorp (eql rank 1))
           (size (if vectorp (length key) (array-total-size key)))
           (hash (mixup-hash-code rank))
           addressp)
      (declare (fixnum size hash limit rank))
      (if vectorp
        (setq hash
              (the fixnum
                   (+ (the fixnum (rotate-hash-code hash))
                      (the fixnum (mixup-hash-code size)))))
        (dotimes (i rank)
          (declare (fixnum i))
          (setq hash
                (the fixnum 
                     (+ (the fixnum (rotate-hash-code hash))
                        (the fixnum
                             (mixup-hash-code (array-dimension key i))))))))      
      (dotimes (i size)
        (declare (fixnum i))
        (multiple-value-bind (h ap) (%%equalphash-aux limit (uvref array offset))
          (declare (fixnum h))
          (setq hash (the fixnum (+ (the fixnum (rotate-hash-code hash)) h)))
          (if ap (setq addressp t)))
        (when (<= (decf limit) 0)
          (setq hash (the fixnum (+ (the fixnum (rotate-hash-code hash))
                                    #.(mixup-hash-code 11))))
          (return))
        (incf offset))
      (values hash addressp))))

(defun %%equalphash-aux (limit key)
  (if (<= limit 0) 
    #.(mixup-hash-code 11)
    (if (null key) #.(mixup-hash-code 17)
        (cond ((consp key)
               (let ((hash 0)
                     address-p)
                 (do ((l limit (1- l)))
                     ((eq l 0)(values hash address-p))
                   (multiple-value-bind (ahash ap)
                                        (%%equalphash-aux l (if (consp key)(car key) key))
                     (setq hash (mixup-hash-code (logxor ahash hash)))
                     (if ap (setq address-p t)))
                   (when (not (consp key))
                     (return (values hash address-p)))
                   (setq key (cdr key)))))
              ((hash-table-p key)
               (equalphash-hash-table key))
              ; what are the dudes called that contain bits? they are uvectors but not gvectors?
              ; ivectors.
              ((or (istructp key)
                   (structurep key))    ;was (gvectorp key)
               (%%equalphash-structure limit key))
              ((or (arrayp key))  ; (uvectorp key))
               (%%equalphash-array limit key))
              (t (%%equalphash key))))))

(defun alist-hash-table (alist &rest hash-table-args)
  (declare (dynamic-extent hash-table-args))
  (if (typep alist 'hash-table)
    alist
    (let ((hash-table (apply #'make-hash-table hash-table-args)))
      (dolist (cons alist) (puthash (car cons) hash-table (cdr cons)))
      hash-table)))

(defun %hash-table-equalp (x y)
  ;; X and Y are both hash tables
  (and (eq (hash-table-test x)
           (hash-table-test y))
       (eql (hash-table-count x)
            (hash-table-count y))
       (block nil
         (let* ((default (cons nil nil))
                (foo #'(lambda (k v)
                         (let ((y-value (gethash k y default)))
                           (unless (and (neq default y-value)
                                        (equalp v y-value))
                             (return nil))))))
           (declare (dynamic-extent foo default))
           (maphash foo x))
         t)))

(defun sxhash (s-expr)
  "Computes a hash code for S-EXPR and returns it as an integer."
  (logand (sxhash-aux s-expr 7 17) most-positive-fixnum))

(defun sxhash-aux (expr counter key)
  (declare (fixnum counter))
  (if (> counter 0)
    (typecase expr
      ((or string bit-vector number character)  (+ key (%%equalhash expr)))
      ((or pathname logical-pathname)
       (dotimes (i (uvsize expr) key)
         (declare (fixnum i))
         (setq key (+ key (sxhash-aux (%svref expr i) (1- counter) key)))))
      (symbol (+ key (%%equalhash (symbol-name expr))))
      (cons (sxhash-aux
             (cdr expr)
             (the fixnum (1- counter))             
             (+ key (sxhash-aux (car expr) (the fixnum (1- counter)) key))))
      (t (+  key (%%equalhash (symbol-name (%type-of expr))))))
    key))



#+ppc32-target
(defun immediate-p (thing)
  (let* ((tag (lisptag thing)))
    (declare (fixnum tag))
    (or (= tag ppc32::tag-fixnum)
        (= tag ppc32::tag-imm))))

#+ppc64-target
(defun immediate-p (thing)
  (let* ((tag (lisptag thing)))
    (declare (fixnum tag))
    (or (= tag ppc64::tag-fixnum)
        (= (logand tag ppc64::lowtagmask) ppc64::lowtag-imm))))



(defun get-fwdnum (&optional hash)
  (let* ((res (%get-fwdnum)))
    (if hash
      (setf (nhash.fixnum hash) res))
    res))

(defun gc-count (&optional hash)
   (let ((res (%get-gc-count)))
    (if hash
      (setf (nhash.gc-count hash) res)
      res)))


(defun %cons-nhash-vector (size &optional (flags 0))
  (declare (fixnum size))
  (let* ((vector (%alloc-misc (+ (+ size size) $nhash.vector_overhead) target::subtag-hash-vector (%unbound-marker))))
    (setf (nhash.vector.link vector) 0
          (nhash.vector.flags vector) flags
          (nhash.vector.free-alist vector) nil
          (nhash.vector.finalization-alist vector) nil
          (nhash.vector.weak-deletions-count vector) 0
          (nhash.vector.hash vector) nil
          (nhash.vector.deleted-count vector) 0
          (nhash.vector.cache-key vector) (%unbound-marker)
          (nhash.vector.cache-value vector) nil
          (nhash.vector.cache-idx vector) nil)
    vector))

