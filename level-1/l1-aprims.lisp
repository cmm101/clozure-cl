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

;; L1-aprims.lisp


(in-package :ccl)


(let* ((standard-initial-bindings ())
       (standard-initial-bindings-lock (make-read-write-lock)))

  (defun standard-initial-bindings ()
    (with-read-lock (standard-initial-bindings-lock)
      (copy-list standard-initial-bindings)))

  (defun define-standard-initial-binding (symbol initform)
    (setq symbol (require-type symbol 'symbol))
    (%proclaim-special symbol)
    (unless (boundp symbol)
      (set symbol (funcall initform)))
    (with-write-lock (standard-initial-bindings-lock)
      (let* ((pair (assoc symbol standard-initial-bindings)))
	(if pair
	  (setf (cdr pair) initform)
	  (push (cons symbol initform) standard-initial-bindings))))
    (record-source-file symbol 'variable)
    symbol))

(def-standard-initial-binding *package*)

(defun %badarg (arg type)
  (%err-disp $XWRONGTYPE arg type))

(defun atom (arg)
  (not (consp arg)))

(defun list (&rest args) args)

(%fhave '%temp-list #'list)

(defun list* (arg &rest others)
  "Returns a list of the arguments with last cons a dotted pair"
  (cond ((null others) arg)
	((null (cdr others)) (cons arg (car others)))
	(t (do ((x others (cdr x)))
	       ((null (cddr x)) (rplacd x (cadr x))))
	   (cons arg others))))



(defun funcall (fn &rest args)
  (declare (dynamic-extent args))
  (apply fn args))


(defun apply (function arg &rest args)
  "Applies FUNCTION to a list of arguments produced by evaluating ARGS in
  the manner of LIST*.  That is, a list is made of the values of all but the
  last argument, appended to the value of the last argument, which must be a
  list."
  (declare (dynamic-extent args))
  (cond ((null args)
	 (apply function arg))
	((null (cdr args))
	 (apply function arg (car args)))
	(t (do* ((a1 args a2)
		 (a2 (cdr args) (cdr a2)))
		((atom (cdr a2))
		 (rplacd a1 (car a2))
		 (apply function arg args))))))


; This is not fast, but it gets the functionality that
; Wood and possibly other code depend on.
(defun applyv (function arg &rest other-args)
  (declare (dynamic-extent other-args))
  (let* ((other-args (cons arg other-args))
         (last-arg (car (last other-args)))
         (last-arg-length (length last-arg))
         (butlast-args (nbutlast other-args))
         (rest-args (make-list last-arg-length))
         (rest-args-tail rest-args))
    (declare (dynamic-extent other-args rest-args))
    (dotimes (i last-arg-length)
      (setf (car rest-args-tail) (aref last-arg i))
      (pop rest-args-tail))
    (apply function (nconc butlast-args rest-args))))

; This is slow, and since %apply-lexpr isn't documented either,
; nothing in the world should depend on it.  This is just being
; anal retentive.  VERY anal retentive.

(defun %apply-lexpr (function arg &rest args)
  (cond ((null args) (%apply-lexpr function arg))
        (t (apply function arg (nconc (nbutlast args)
                                      (collect-lexpr-args (car (last args)) 0))))))


(defun values-list (arg)
  (apply #'values arg))



(defun make-list (size &key initial-element)
  (unless (and (typep size 'fixnum)
               (>= (the fixnum size) 0))
    (report-bad-arg size '(and fixnum unsigned-byte)))
  (locally (declare (fixnum size))
    (do* ((result '() (cons initial-element result)))
        ((zerop size) result)
      (decf size))))


; copy-list

(defun copy-list (list)
  (if list
    (let ((result (cons (car list) '()) ))
      (do ((x (cdr list) (cdr x))
           (splice result
                   (%cdr (%rplacd splice (cons (%car x) '() ))) ))
          ((atom x) (unless (null x)
                      (%rplacd splice x)) result)))))


; take two args this week

(defun last (list &optional (n 1))
  (unless (and (typep n 'fixnum)
               (>= (the fixnum n) 0))
    (report-bad-arg n '(and fixnum unsigned-byte)))
  (locally (declare (fixnum n))
    (do* ((checked-list list (cdr checked-list))
          (returned-list list)
          (index 0 (1+ index)))
         ((atom checked-list) returned-list)
      (declare (type index index))
      (if (>= index n)
	  (pop returned-list)))))





(defun nthcdr (index list)
  (if (and (typep index 'fixnum)
	   (>= (the fixnum index) 0))
    (locally (declare (fixnum index))
      (dotimes (i index list)
	(when (null (setq list (cdr list))) (return))))
    (progn
      (unless (typep index 'unsigned-byte)
	(report-bad-arg index 'unsigned-byte))
      (do* ((n index (- n most-positive-fixnum)))
	   ((typep n 'fixnum) (nthcdr n list))
	(unless (setq list (nthcdr most-positive-fixnum list))
	  (return))))))


(defun nth (index list) (car (nthcdr index list)))


(defun nconc (&rest lists)
  (declare (dynamic-extent lists))
  "Concatenates the lists given as arguments (by changing them)"
  (do* ((top lists (cdr top)))
       ((null top) nil)
    (let* ((top-of-top (car top)))
      (cond
       ((consp top-of-top)
        (let* ((result top-of-top)
               (splice result))
          (do* ((elements (cdr top) (cdr elements)))
	         ((endp elements))
            (let ((ele (car elements)))
              (typecase ele
                (cons (rplacd (last splice) ele)
                      (setf splice ele))
                (null (rplacd (last splice) nil))
                (atom (if (cdr elements)
                        (report-bad-arg ele 'list)
                        (rplacd (last splice) ele)))
                (t (report-bad-arg ele 'list)))))
          (return result)))
       ((null top-of-top) nil)
       (t
        (if (cdr top)
          (report-bad-arg top-of-top 'list)
          (return top-of-top)))))))


(defvar %setf-function-names% (make-hash-table :weak t :test 'eq))

(defun setf-function-name (sym)
   (or (gethash sym %setf-function-names%)
       (setf (gethash sym %setf-function-names%) (construct-setf-function-name sym))))



                     

(defconstant *setf-package* (or (find-package "SETF") (make-package "SETF" :use nil :external-size 1)))

(defun construct-setf-function-name (sym)
  (let ((pkg (symbol-package sym)))
    (setq sym (symbol-name sym))
    (if (null pkg)
      (gentemp sym *setf-package*)
      (values
       (intern
        ;I wonder, if we didn't check, would anybody report it as a bug?
        (if (not (%str-member #\: (setq pkg (package-name pkg))))
          (%str-cat pkg "::" sym)
          (%str-cat (prin1-to-string pkg) "::" (princ-to-string sym)))
        *setf-package*)))))

(defun valid-function-name-p (name)
  (if (symbolp name)                    ; Nil is a valid function name.  I guess.
    (values t name)
    (if (and (consp name)
             (consp (%cdr name))
             (null (%cddr name))
             (symbolp (%cadr name)))
      (values t (setf-function-name (%cadr name)))
      ; What other kinds of function names do we care to support ?
      (values nil nil))))

; Why isn't this somewhere else ?
(defun ensure-valid-function-name (name)
  (multiple-value-bind (valid-p nm) (valid-function-name-p name)
    (if valid-p nm (error "Invalid function name ~s." name))))


; Returns index if char appears in string, else nil.

(defun %str-member (char string &optional start end)
  (let* ((base-string-p (typep string 'simple-base-string)))
    (unless base-string-p
      (setq string (require-type string 'simple-string)))
    (unless (characterp char)
      (setq char (require-type char 'character)))
    (do* ((i (or start 0) (1+ i))
            (n (or end (uvsize string))))
           ((= i n))
        (declare (fixnum i n) (optimize (speed 3) (safety 0)))
        (if (eq (schar (the simple-base-string string) i) char)
          (return i)))))



; Returns index of elt in vector, or nil if it's not there.
(defun %vector-member (elt vector)
  (unless (typep vector 'simple-vector)
    (report-bad-arg vector 'simple-vector))
  (dotimes (i (the fixnum (length vector)))
    (when (eq elt (%svref vector i)) (return i))))


(progn
; It's back ...
(defun list-nreverse (list)
  (nreconc list nil))

; We probably want to make this smarter so that less boxing
; (and bignum/double-float consing!) takes place.

(defun vector-nreverse (v)
  (let* ((len (length v))
         (middle (ash (the fixnum len) -1)))
    (declare (fixnum middle len))
    (do* ((left 0 (1+ left))
          (right (1- len) (1- right)))
         ((= left middle) v)
      (declare (fixnum left right))
      (rotatef (aref v left) (aref v right)))))
    
(defun nreverse (seq)
  (seq-dispatch seq
   (list-nreverse seq)
   (vector-nreverse seq)))
)

(defun nreconc (x y)
  "Returns (nconc (nreverse x) y)"
  (do ((1st (cdr x) (if (atom 1st) 1st (cdr 1st)))
       (2nd x 1st)		;2nd follows first down the list.
       (3rd y 2nd))		;3rd follows 2nd down the list.
      ((atom 2nd) 3rd)
    (rplacd 2nd 3rd)))

(defun append (&lexpr lists)
  (let* ((n (%lexpr-count lists)))
    (declare (fixnum n))
    (if (> n 0)
      (if (= n 1)
        (%lexpr-ref lists n 0)
        (do* ((res (%lexpr-ref lists n 0) (append-2 res (%lexpr-ref lists n j)))
              (j 1 (1+ j)))
             ((= j n) res)
          (declare (fixnum j)))))))







(progn
(defun list-reverse (l)
  (do* ((new ()))
       ((null l) new)
    (push (pop l) new)))

; Again, it's worth putting more work into this when the dust settles.
(defun vector-reverse (v)
  (let* ((len (length v))
         (new (make-array (the fixnum len) :element-type (array-element-type v))))   ; a LOT more work ...
    (declare (fixnum len))
    (do* ((left 0 (1+ left))
          (right (1- len) (1- right)))
         ((= left len) new)
      (declare (fixnum left right))
      (setf (uvref new left)
            (aref v right)))))

(defun reverse (seq)
  (seq-dispatch seq (list-reverse seq) (vector-reverse seq)))
)

(defun check-sequence-bounds (seq start end)
  (let* ((length (length seq)))
    (declare (fixnum length))
    (if (not end)
      (setq end length)
      (unless (typep end 'fixnum)
	(report-bad-arg end 'fixnum)))
    (unless (typep start 'fixnum)
      (report-bad-arg start 'fixnum))
    (locally (declare (fixnum start end))
      (cond ((> end length)
	     (report-bad-arg end `(integer 0 (,length))))
	    ((< start 0)
	     (report-bad-arg start `(integer 0)))
	    ((> start end)
	     (report-bad-arg start `(integer 0 ,end)))
	    (t end)))))
  

(defun byte-length (string &optional  (start 0) end)
  (setq end (check-sequence-bounds string start end))
  (- end start))



(defun make-cstring (string)
  (let* ((len (length string)))
    (declare (fixnum len))
    (let* ((s (malloc (the fixnum (1+ len)))))
      (setf (%get-byte s len) 0)
      (multiple-value-bind (data offset) (array-data-and-offset string)
	(%copy-ivector-to-ptr data offset s 0 len)
	s))))


(defun extended-string-p (thing)
  (declare (ignore thing)))

(defun simple-extended-string-p (thing)
  (declare (ignore thing)))



(defun move-string-bytes (source dest off1 off2 n)
  (declare (optimize (speed 3)(safety 0)))
  (declare (fixnum off1 off2 n))
  (let* ((base-source (typep source 'simple-base-string))
         (base-dest (typep dest 'simple-base-string)))
    (if (and base-dest base-source)
      (%copy-ivector-to-ivector source off1 dest off2 n))))


(defun %str-cat (s1 s2 &rest more)
  (declare (dynamic-extent more))
  (require-type s1 'simple-string)
  (require-type s2 'simple-string)
  (let* ((len1 (length s1))
         (len2 (length s2))
         (len (%i+ len2 len1)))
    (declare (optimize (speed 3)(safety 0)))
    (dolist (s more)
      (require-type s 'simple-string)
      (setq len (+ len (length s))))
    (let ((new-string (make-string len :element-type 'base-char)))
      (move-string-bytes s1 new-string 0 0 len1)
      (move-string-bytes s2 new-string 0 len1 len2)
      (dolist (s more)
        (setq len2 (%i+ len1 len2))
        (move-string-bytes s new-string 0 len2 (setq len1 (length s))))
      new-string)))


(defun %substr (str start end)
  (require-type start 'fixnum)
  (require-type end 'fixnum)
  (require-type str 'string)
  (let ((len (length str)))
    (multiple-value-bind (str strb)(array-data-and-offset str)
      (let ((newlen (%i- end start)))
        (when (%i> end len)(error "End ~S exceeds length ~S." end len))
        (when (%i< start 0)(error "Negative start"))
        (let ((new (make-string newlen :element-type (array-element-type str))))
          (move-string-bytes str new (%i+ start strb) 0 newlen)
          new)))))


(defun coerce-to-uvector (object subtype simple-p)  ; simple-p ?  
  (let ((type-code (typecode object)))
    (cond ((eq type-code ppc32::tag-list)
           (%list-to-uvector subtype object))
          ((>= type-code ppc32::min-cl-ivector-subtag)  ; 175
           (if (or (null subtype)(= subtype type-code))
             (return-from coerce-to-uvector object)))
          ((>= type-code ppc32::min-vector-subtag)     ; 170
           (if (= type-code ppc32::subtag-simple-vector)
             (if (or (null subtype)
                     (= type-code subtype))
               (return-from coerce-to-uvector object))
             (if (and (null simple-p)
                      (or (null subtype)
                          (= subtype (typecode (array-data-and-offset object)))))
               (return-from coerce-to-uvector object))))
          (t (error "Can't coerce ~s to Uvector" object))) ; or just let length error
    (if (null subtype)(setq subtype ppc32::subtag-simple-vector))
    (let* ((size (length object))
           (val (%alloc-misc size subtype)))
      (declare (fixnum size))
      (multiple-value-bind (vect offset) (array-data-and-offset object)
        (declare (fixnum offset))
        (dotimes (i size val)
          (declare (fixnum i)) 
          (uvset val i (uvref vect (%i+ offset i))))))))








; 3 callers
(defun %list-to-uvector (subtype list)   ; subtype may be nil (meaning simple-vector
  (let* ((n (length list))
         (new (%alloc-misc n (or subtype ppc32::subtag-simple-vector))))  ; yech
    (dotimes (i n)
      (declare (fixnum i))
      (uvset new i (%car list))
      (setq list (%cdr list)))
    new))


; appears to be unused
(defun upgraded-array-element-type (type &optional env)
  (declare (ignore env))
  (element-subtype-type (element-type-subtype type)))

(defun upgraded-complex-part-type (type &optional env)
  (declare (ignore env))
  (declare (ignore type))               ; Ok, ok.  So (upgraded-complex-part-type 'bogus) is 'REAL. So ?
  'real)



(progn
  ; we are making assumptions - put in ppc-arch? - almost same as *ppc-immheader-array-types
  (defparameter array-element-subtypes
    #(single-float 
      (unsigned-byte 32)
      (signed-byte 32)
      (unsigned-byte 8)
      (signed-byte 8)
      base-char
      *unused*
      (unsigned-byte 16)
      (signed-byte 16)
      double-float
      bit))
  
  ; given uvector subtype - what is the corresponding element-type
  (defun element-subtype-type (subtype)
    (declare (fixnum subtype))
    (if  (= subtype ppc32::subtag-simple-vector) t
        (svref array-element-subtypes 
               (ash (- subtype ppc32::min-cl-ivector-subtag) (- ppc32::ntagbits)))))
  )






;Used by transforms.
(defun make-uvector (length subtype &key (initial-element () initp))
  (if initp
    (%alloc-misc length subtype initial-element)
    (%alloc-misc length subtype)))

; %make-displaced-array assumes the following

(eval-when (:compile-toplevel)
  (assert (eql ppc32::arrayH.flags-cell ppc32::vectorH.flags-cell))
  (assert (eql ppc32::arrayH.displacement-cell ppc32::vectorH.displacement-cell))
  (assert (eql ppc32::arrayH.data-vector-cell ppc32::vectorH.data-vector-cell)))


(defun %make-displaced-array (dimensions displaced-to
                                         &optional fill adjustable offset temp-p)
  (declare (ignore temp-p))
  (if offset 
    (unless (and (fixnump offset) (>= (the fixnum offset) 0))
      (setq offset (require-type offset '(and fixnum (integer 0 *)))))
    (setq offset 0))
  (locally (declare (fixnum offset))
    (let* ((disp-size (array-total-size displaced-to))
           (rank (if (listp dimensions)(length dimensions) 1))
           (new-size (if (fixnump dimensions)
                       dimensions
                       (if (listp dimensions)
                         (if (eql rank 1)
                           (car dimensions)
                           (if (eql rank 0) 1 ; why not 0?
                           (apply #'* dimensions))))))
           (vect-subtype (%vect-subtype displaced-to))
           (target displaced-to)
           (real-offset offset)
           (flags 0))
      (declare (fixnum disp-size rank flags vect-subtype real-offset))
      (if (not (fixnump new-size))(error "Bad array dimensions ~s." dimensions)) 
      (locally (declare (fixnum new-size))
        ; (when (> (+ offset new-size) disp-size) ...), but don't cons bignums
        (when (or (> new-size disp-size)
                  (let ((max-offset (- disp-size new-size)))
                    (declare (fixnum max-offset))
                    (> offset max-offset)))
          (%err-disp $err-disp-size displaced-to))
        (if adjustable  (setq flags (bitset $arh_adjp_bit flags)))
        (when fill
          (if (eq fill t)
            (setq fill new-size)
            (unless (and (eql rank 1)
                         (fixnump fill)
                         (locally (declare (fixnum fill))
                           (and (>= fill 0) (<= fill new-size))))
              (error "Bad fill pointer ~s" fill)))
          (setq flags (bitset $arh_fill_bit flags))))
      ; If displaced-to is an array or vector header and is either
      ; adjustable or its target is a header, then we need to set the
      ; $arh_disp_bit. If displaced-to is not adjustable, then our
      ; target can be its target instead of itself.
      (when (or (eql vect-subtype ppc32::subtag-arrayH)
                (eql vect-subtype ppc32::subtag-vectorH))
        (let ((dflags (%svref displaced-to ppc32::arrayH.flags-cell)))
          (declare (fixnum dflags))
          (when (or (logbitp $arh_adjp_bit dflags)
                    (progn
                      (setq target (%svref displaced-to ppc32::arrayH.data-vector-cell)
                            real-offset (+ offset (%svref displaced-to ppc32::arrayH.displacement-cell)))
                      (logbitp $arh_disp_bit dflags)))
            (setq flags (bitset $arh_disp_bit flags))))
        (setq vect-subtype (%array-header-subtype displaced-to)))
      ; assumes flags is low byte
      (setq flags (dpb vect-subtype ppc32::arrayH.flags-cell-subtag-byte flags))
      (if (eq rank 1)
        (%gvector ppc32::subtag-vectorH 
                      (if (fixnump fill) fill new-size)
                      new-size
                      target
                      real-offset
                      flags)
        (let ((val (%alloc-misc (+ ppc32::arrayh.dim0-cell rank) ppc32::subtag-arrayH)))
          (setf (%svref val ppc32::arrayH.rank-cell) rank)
          (setf (%svref val ppc32::arrayH.physsize-cell) new-size)
          (setf (%svref val ppc32::arrayH.data-vector-cell) target)
          (setf (%svref val ppc32::arrayH.displacement-cell) real-offset)
          (setf (%svref val ppc32::arrayH.flags-cell) flags)
          (do* ((dims dimensions (cdr dims))
                (i 0 (1+ i)))              
               ((null dims))
            (declare (fixnum i)(list dims))
            (setf (%svref val (%i+ ppc32::arrayH.dim0-cell i)) (car dims)))
          val)))))





(defun vector-pop (vector)
  (let* ((fill (fill-pointer vector)))
    (declare (fixnum fill))
    (if (zerop fill)
      (error "Fill pointer of ~S is 0 ." vector)
      (progn
        (decf fill)
        (%set-fill-pointer vector fill)
        (aref vector fill)))))




(defun elt (sequence idx)
  (seq-dispatch
   sequence
   (let* ((cell (nthcdr idx sequence)))
     (declare (list cell))
     (if cell (car cell) (%err-disp $XACCESSNTH idx sequence)))
   (progn
     (unless (and (typep idx 'fixnum) (>= (the fixnum idx) 0))
       (report-bad-arg idx 'unsigned-byte))
     (locally 
       (if (>= idx (length sequence))
         (%err-disp $XACCESSNTH idx sequence)
         (aref sequence idx))))))




(defun set-elt (sequence idx value)
  (seq-dispatch
   sequence
   (let* ((cell (nthcdr idx sequence)))
     (if cell 
       (locally 
         (declare (cons cell))
         (setf (car cell) value))
       (%err-disp $XACCESSNTH idx sequence)))
   (progn
     (unless (and (typep idx 'fixnum) (>= (the fixnum idx) 0))
       (report-bad-arg idx 'unsigned-byte))
     (locally 
       (declare (fixnum idx))
       (if (>= idx (length sequence))
         (%err-disp $XACCESSNTH idx sequence)
         (setf (aref sequence idx) value))))))




(%fhave 'equalp #'equal)                ; bootstrapping

(defun copy-tree (tree)
  (if (atom tree)
    tree
    (locally (declare (type cons tree))
      (do* ((tail (cdr tree) (cdr tail))
            (result (cons (copy-tree (car tree)) nil))
            (ptr result (cdr ptr)))
           ((atom tail)
            (setf (cdr ptr) tail)
            result)
        (declare (type cons ptr result))
        (locally 
          (declare (type cons tail))
          (setf (cdr ptr) (cons (copy-tree (car tail)) nil)))))))




(defvar *periodic-task-interval* 0.3)
(defvar *periodic-task-seconds* 0)
(defvar *periodic-task-nanoseconds* 300000000)

(defun set-periodic-task-interval (n)
  (multiple-value-setq (*periodic-task-seconds* *periodic-task-nanoseconds*)
    (nanoseconds n))
  (setq *periodic-task-interval* n))

(defun periodic-task-interval ()
  *periodic-task-interval*)



(defun char-downcase (c)
  (let* ((code (char-code c)))
    (if (and (%i>= code (char-code #\A))(%i<= code (char-code #\Z)))
      (%code-char (%i+ code #.(- (char-code #\a)(char-code #\A))))
    c)))



(defun digit-char-p (char &optional radix)
  (let* ((code (char-code char))
         (r (if radix (if (and (typep radix 'fixnum)
                               (%i>= radix 2)
                               (%i<= radix 36))
                        radix
                        (%validate-radix radix)) 10))
         (weight (if (and (<= code (char-code #\9))
                          (>= code (char-code #\0)))
                   (the fixnum (- code (char-code #\0)))
                   (if (and (<= code (char-code #\Z))
                            (>= code (char-code #\A)))
                     (the fixnum (+ 10 (the fixnum (- code (char-code #\A)))))
                   (if (and (<= code (char-code #\z))
                            (>= code (char-code #\a)))
                     (the fixnum (+ 10 (the fixnum (- code (char-code #\a))))))))))
    (declare (fixnum code r))
    (and weight (< (the fixnum weight) r) weight)))





(defun char-upcase (c)
  (let* ((code (char-code c)))
    (if (and (%i>= code (char-code #\a))(%i<= code (char-code #\z)))
      (%code-char (%i- code #.(- (char-code #\a)(char-code #\A))))
      c)))

(defun chkbounds (arr start end)
  (flet ((are (a i)(error "Array index ~S out of bounds for ~S." a i)))
    (let ((len (length arr)))
      (if (and end (> end len))(are arr end))
      (if (and start (or (< start 0)(> start len)))(are arr start))
      (if (%i< (%i- (or end len)(or start 0)) 0)
        (error "Start ~S exceeds end ~S." start end)))))

(defun string-start-end (string start end)
  (setq string (string string))
  (let ((len (length (the string string))))
    (flet ((are (a i)(error "Array index ~S out of bounds for ~S." i a)))    
      (if (and end (> end len))(are string end))
      (if (and start (or (< start 0)(> start len)))(are string start))
      (setq start (or start 0) end (or end len))
      (if (%i> start end)
        (error "Start ~S exceeds end ~S." start end))
      (multiple-value-bind (str off)(array-data-and-offset string)
        (values str (%i+ off start)(%i+ off end))))))

(defun get-properties (place indicator-list)
  "Like GETF, except that Indicator-List is a list of indicators which will
  be looked for in the property list stored in Place.  Three values are
  returned, see manual for details."
  (do ((plist place (cddr plist)))
      ((null plist) (values nil nil nil))
    (cond ((atom (cdr plist))
	   (error "~S is a malformed proprty list."
		  place))
	  ((memq (car plist) indicator-list) ;memq defined in kernel
	   (return (values (car plist) (cadr plist) plist))))))

(defun string= (string1 string2 &key start1 end1 start2 end2)
    (locally (declare (optimize (speed 3)(safety 0)))
      (if (and (simple-string-p string1)(null start1)(null end1))
        (setq start1 0 end1 (length string1))
        (multiple-value-setq (string1 start1 end1)(string-start-end string1 start1 end1)))
      (if (and (simple-string-p string2)(null start2)(null end2))
        (setq start2 0 end2 (length string2))
        (multiple-value-setq (string2 start2 end2)(string-start-end string2 start2 end2)))    
      (%simple-string= string1 string2 start1 start2 end1 end2)))


(defun lfun-keyvect (lfun)
  (let ((bits (lfun-bits lfun)))
    (declare (fixnum bits))
    (and (logbitp $lfbits-keys-bit bits)
         (or (logbitp $lfbits-method-bit bits)
             (and (not (logbitp $lfbits-gfn-bit bits))
                  (not (logbitp $lfbits-cm-bit bits))))
         (if (typep lfun 'interpreted-function) ; patch needs interpreted-method-function too
           
           (nth 4 (evalenv-fnentry (%svref lfun 1))) ; gag puke
           (%svref lfun 1)))))



(defun function-lambda-expression (fn)
  ;(declare (values def env-p name))
  (let* ((bits (lfun-bits (setq fn (require-type fn 'function)))))
    (declare (fixnum bits))
    (if (logbitp $lfbits-trampoline-bit bits)
      (function-lambda-expression (%svref fn 1))
      (values (uncompile-function fn)
              (logbitp $lfbits-nonnullenv-bit bits)
              (function-name fn)))))

; env must be a lexical-environment or NIL.
; If env contains function or variable bindings or SPECIAL declarations, return t.
; Else return nil
(defun %non-empty-environment-p (env)
  (loop
    (when (or (null env) (istruct-typep env 'definition-environment))
      (return nil))
    (when (or (consp (lexenv.variables env))
              (consp (lexenv.functions env))
              (dolist (vdecl (lexenv.vdecls env))
                (when (eq (cadr vdecl) 'special)
                  (return t))))
      (return t))
    (setq env (lexenv.parent-env env))))

;(coerce object 'compiled-function)
(defun coerce-to-compiled-function (object)
  (setq object (coerce-to-function object))
  (unless (typep object 'compiled-function)
    (multiple-value-bind (def envp) (function-lambda-expression object)
      (when (or envp (null def))
        (%err-disp $xcoerce object 'compiled-function))
      (setq object (compile-user-function def nil))))
  object)



(defun %set-toplevel (&optional (fun nil fun-p))
  ;(setq fun (require-type fun '(or symbol function)))
  (let* ((tcr (%current-tcr)))
    (prog1 (%tcr-toplevel-function tcr)
      (when fun-p
	(%set-tcr-toplevel-function tcr fun)))))

; Look! GC in Lisp !


#+ppc-target
(defppclapfunction full-gccount ()
  (ref-global arg_z tenured-area)
  (cmpwi cr0 arg_z 0)
  (if :eq
    (ref-global arg_z gc-count)
    (lwz arg_z ppc32::area.gc-count arg_z))
  (blr))

#+sparc-target
(defsparclapfunction full-gccount ()
  (ref-global %arg_z tenured-area)
  (tst %arg_z)
  (bne done)
   (nop)
  (ref-global %arg_z gc-count)
  (ld (%arg_z ppc32::area.gc-count) %arg_z)
  done
  (retl)
   (nop))
  

(defun gccounts ()
  (let* ((total (%get-gc-count))
         (full (full-gccount))
         (g2-count 0)
         (g1-count 0)
         (g0-count 0))
    (when (egc-enabled-p)
      (let* ((a (%active-dynamic-area)))
        (setq g0-count (%fixnum-ref a ppc32::area.gc-count) a (%fixnum-ref a ppc32::area.older))
        (setq g1-count (%fixnum-ref a ppc32::area.gc-count) a (%fixnum-ref a ppc32::area.older))
        (setq g2-count (%fixnum-ref a ppc32::area.gc-count))))
    (values total full g2-count g1-count g0-count)))

      
#+ppc-target
(defppclapfunction gc ()
  (check-nargs 0)
  (li imm0 0)
  (twlgei allocptr 0)
  (li arg_z ppc32::nil-value)
  (blr))

#+ppc-target
(defppclapfunction egc ((arg arg_z))
  (check-nargs 1)
  (subi imm1 arg nil)
  (li imm0 32)
  (twlgei allocptr 0)
  (blr))

(defppclapfunction %configure-egc ((e0size arg_x)
				   (e1size arg_y)
				   (e2size arg_z))
  (check-nargs 3)
  (li imm0 64)
  (twlgei allocptr 0)
  (blr))
  

#+ppc-target
(defppclapfunction purify ()
  (li imm0 1)
  (twlgei allocptr 0)
  (li arg_z nil)
  (blr))


#+ppc-target
(defppclapfunction impurify ()
  (li imm0 2)
  (twlgei allocptr 0)
  (li arg_z nil)
  (blr))


#+ppc-target
(defppclapfunction lisp-heap-gc-threshold ()
  (check-nargs 0)
  (li imm0 16)
  (twlgei allocptr 0)
  (blr))

#+ppc-target
(defppclapfunction set-lisp-heap-gc-threshold ((new arg_z))
  (check-nargs 1)
  (li imm0 17)
  (unbox-fixnum imm1 arg_z)
  (twlgei allocptr 0)
  (blr))

#+ppc-target
(defppclapfunction use-lisp-heap-gc-threshold ()
  (check-nargs 0)
  (li imm0 18)
  (twlgei allocptr 0)
  (li arg_z nil)
  (blr))

(defglobal %pascal-functions%
  (make-array 4 :initial-element nil))


(defun gc-retain-pages (arg)
  (setq *gc-event-status-bits*
        (if arg
          (bitset $gc-retain-pages-bit *gc-event-status-bits*)
          (bitclr $gc-retain-pages-bit *gc-event-status-bits*)))
  (not (null arg)))

(defun gc-retaining-pages ()
  (logbitp $gc-retain-pages-bit *gc-event-status-bits*))  



(defun egc-active-p ()
  (and (egc-enabled-p)
       (not (eql 0 (%get-kernel-global 'oldest-ephemeral)))))

; this IS effectively a passive way of inquiring about enabled status.
(defun egc-enabled-p ()
  (not (eql 0 (%fixnum-ref (%active-dynamic-area) ppc32::area.older))))

(defun egc-configuration ()
  (let* ((ta (%get-kernel-global 'tenured-area))
         (g2 (%fixnum-ref ta ppc32::area.younger))
         (g1 (%fixnum-ref g2 ppc32::area.younger))
         (g0 (%fixnum-ref g1 ppc32::area.younger)))
    (values (ash (the fixnum (%fixnum-ref g0 ppc32::area.threshold)) -8)
            (ash (the fixnum (%fixnum-ref g1 ppc32::area.threshold)) -8)
            (ash (the fixnum (%fixnum-ref g2 ppc32::area.threshold)) -8))))


(defun configure-egc (e0size e1size e2size)
  (unless (egc-active-p)
    (setq e2size (logand (lognot #xffff) (+ #xffff (ash (require-type e2size '(unsigned-byte 18)) 10)))
          e1size (logand (lognot #xffff) (+ #xffff (ash (require-type e1size '(unsigned-byte 18)) 10)))
          e0size (logand (lognot #xffff) (+ #xffff (ash (require-type e0size '(integer 1 #.(ash 1 18))) 10))))
    (%configure-egc e0size e1size e2size)))



(defun macptr-flags (macptr)
  (if (eql (uvsize (setq macptr (require-type macptr 'macptr))) 1)
    0
    (uvref macptr PPC32::XMACPTR.FLAGS-CELL)))


; This doesn't really make the macptr be gcable (now has to be
; on linked list), but we might have other reasons for setting
; other flag bits.
(defun set-macptr-flags (macptr value) 
  (unless (eql (uvsize (setq macptr (require-type macptr 'macptr))) 1)
    (setf (%svref macptr PPC32::XMACPTR.FLAGS-CELL) value)
    value))

(defun %new-gcable-ptr (size &optional clear-p)
  (let ((p (make-gcable-macptr $flags_DisposPtr)))
    (%setf-macptr p (malloc size))
    (if clear-p
      (#_bzero p size))
    p))

;True for a-z.
(defun lower-case-p (c)
  (let ((code (char-code c)))
    (and (>= code (char-code #\a))
         (<= code (char-code #\z)))))

;True for a-z A-Z


(defun alpha-char-p (c)
  (let* ((code (char-code c)))
    (declare (fixnum code))
    (or (and (>= code (char-code #\A)) (<= code (char-code #\Z)))
        (and (>= code (char-code #\a)) (<= code (char-code #\z))))))


; def-accessors type-tracking stuff.  Used by inspector
(defvar *def-accessor-types* nil)

(defun add-accessor-types (types names)
  (dolist (type types)
    (let ((cell (or (assq type *def-accessor-types*)
                    (car (push (cons type nil) *def-accessor-types*)))))
      (setf (cdr cell) (if (vectorp names) names (%list-to-uvector nil names))))))


;;; Some simple explicit storage management for cons cells

(def-standard-initial-binding *cons-pool* (%cons-pool nil))

(defun cheap-cons (car cdr)
  (let* ((pool *cons-pool*)
         (cons (pool.data pool)))
    (if cons
      (locally (declare (type cons cons))
        (setf (pool.data pool) (cdr cons)
              (car cons) car
              (cdr cons) cdr)
        cons)
      (cons car cdr))))

(defun free-cons (cons)
  (when (consp cons)
    (locally (declare (type cons cons))
      (setf (car cons) nil
            (cdr cons) nil)
      (let* ((pool *cons-pool*)
             (freelist (pool.data pool)))
        (setf (pool.data pool) cons
              (cdr cons) freelist)))))

(defun cheap-copy-list (list)
  (let ((l list)
        res)
    (loop
      (when (atom l)
        (return (nreconc res l)))
      (setq res (cheap-cons (pop l) res)))))

(defun cheap-list (&rest args)
  (declare (dynamic-extent args))
  (cheap-copy-list args))

;;; Works for dotted lists
(defun cheap-free-list (list)
  (let ((l list)
        next-l)
    (loop
      (setq next-l (cdr l))
      (free-cons l)
      (when (atom (setq l next-l))
        (return)))))

(defmacro pop-and-free (place)
  (setq place (require-type place 'symbol))     ; all I need for now.
  (let ((list (gensym))
        (cdr (gensym)))
    `(let* ((,list ,place)
            (,cdr (cdr ,list)))
       (prog1
         (car ,list)
         (setf ,place ,cdr)
         (free-cons ,list)))))

;;; Support for defresource & using-resource macros
(defun make-resource (constructor &key destructor initializer)
  (%cons-resource constructor destructor initializer))

(defun allocate-resource (resource)
  (setq resource (require-type resource 'resource))
  (let ((pool (resource.pool resource))
        res)
    (without-interrupts
     (let ((data (pool.data pool)))
       (when data
         (setf res (car data)
               (pool.data pool) (cdr (the cons data)))
         (free-cons data))))
    (if res
      (let ((initializer (resource.initializer resource)))
        (when initializer
          (funcall initializer res)))
      (setq res (funcall (resource.constructor resource))))
    res))

(defun free-resource (resource instance)
  (setq resource (require-type resource 'resource))
  (let ((pool (resource.pool resource))
        (destructor (resource.destructor resource)))
    (when destructor
      (funcall destructor instance))
    (without-interrupts
     (setf (pool.data pool)
           (cheap-cons instance (pool.data pool)))))
  resource)




(defpackage "OS"
  (:nicknames "OPERATING-SYSTEM" 
	      #+linuxppc-target "LINUX"
	      #+darwinppc-target "DARWIN")
  (:use "COMMON-LISP")
  (:shadow "OPEN" "CLOSE" "READ" "WRITE" "SLEEP" "LISTEN" "FTRUNCATE" "SIGNAL" "DELETE"
           "WARN" "ERROR" "FLOOR" "SQRT" "LOG" "EXP" "ATANH" "ASINH"
           "ACOSH" "TANH" "SINH" "COSH" "TAN" "SIN" "COS" "ATAN" "ASIN"
           "ACOS" "MIN" "MAX" "GCD" "TRUNCATE" "TIME"))



