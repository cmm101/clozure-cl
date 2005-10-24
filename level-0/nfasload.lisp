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

(eval-when (:compile-toplevel :execute)

(require "FASLENV" "ccl:xdump;faslenv")
#+ppc-target
(require "PPC-LAPMACROS")



(defconstant $primsizes (make-array 23
                                    :element-type '(unsigned-byte 16)
                                    :initial-contents
                                    '(41 61 97 149 223 337 509 769 887 971 1153 1559 1733
                                      2609 2801 3917 5879 8819 13229 19843 24989 29789 32749)))
(defconstant $hprimes (make-array 8 
                                  :element-type '(unsigned-byte 16)
                                  :initial-contents '(5 7 11 13 17 19 23 29)))

;;; Symbol hash tables: (htvec . (hcount . hlimit))

(defmacro htvec (htab) `(%car ,htab))
(defmacro htcount (htab) `(%cadr ,htab))
(defmacro htlimit (htab) `(%cddr ,htab))
)

(eval-when (:execute :compile-toplevel)
  (assert (= 64 numfaslops)))

(defvar *fasl-dispatch-table* #64(%bad-fasl))

(defun %bad-fasl (s)
  (error "bad opcode near position ~d in FASL file ~s"
         (%fasl-get-file-pos s)
         (faslstate.faslfname s)))

(defun %cant-epush (s)
  (if (faslstate.faslepush s)
    (%bad-fasl s)))

(defun %epushval (s val)
  (setf (faslstate.faslval s) val)
  (when (faslstate.faslepush s)
    (setf (svref (faslstate.faslevec s) (faslstate.faslecnt s)) val)
    (incf (the fixnum (faslstate.faslecnt s))))
  val)

(defun %simple-fasl-read-buffer (s)
  (let* ((fd (faslstate.faslfd s))
         (buffer (faslstate.iobuffer s))
         (bufptr (%get-ptr buffer)))
    (declare (dynamic-extent bufptr)
             (type macptr buffer bufptr pb))
    (%setf-macptr bufptr (%inc-ptr buffer target::node-size))
    (setf (%get-ptr buffer) bufptr)
    (let* ((n (fd-read fd bufptr $fasl-buf-len)))
      (declare (fixnum n))
      (if (> n 0)
        (setf (faslstate.bufcount s) n)
        (error "Fix this: look at errno, EOF")))))

 
(defun %simple-fasl-read-byte (s)
  (loop
    (let* ((buffer (faslstate.iobuffer s))
           (bufptr (%get-ptr buffer)))
      (declare (dynamic-extent bufptr)
               (type macptr buffer bufptr))
      (if (>= (the fixnum (decf (the fixnum (faslstate.bufcount s))))
              0)
        (return
         (prog1
           (%get-unsigned-byte bufptr)
           (setf (%get-ptr buffer)
                 (%incf-ptr bufptr))))
        (%fasl-read-buffer s)))))

(defun %fasl-read-word (s)
  (the fixnum 
    (logior (the fixnum (ash (the fixnum (%fasl-read-byte s)) 8))
            (the fixnum (%fasl-read-byte s)))))


(defun %fasl-read-long (s)
  (logior (ash (%fasl-read-word s) 16) (%fasl-read-word s)))


(defun %fasl-read-count (s)
  (do* ((val 0)
        (shift 0 (+ shift 7))
        (done nil))
       (done val)
    (let* ((b (%fasl-read-byte s)))
      (declare (type (unsigned-byte 8) b))
      (setq done (logbitp 7 b) val (logior val (ash (logand b #x7f) shift))))))

(defun %simple-fasl-read-n-bytes (s ivector byte-offset n)
  (declare (fixnum byte-offset n))
  (do* ()
       ((= n 0))
    (let* ((count (faslstate.bufcount s))
           (buffer (faslstate.iobuffer s))
           (bufptr (%get-ptr buffer))
           (nthere (if (< count n) count n)))
      (declare (dynamic-extent bufptr)
               (type macptr buffer bufptr)
               (fixnum count nthere))
      (if (= nthere 0)
        (%fasl-read-buffer s)
        (progn
          (decf n nthere)
          (decf (the fixnum (faslstate.bufcount s)) nthere)
          (%copy-ptr-to-ivector bufptr 0 ivector byte-offset nthere)
          (incf byte-offset nthere)
          (setf (%get-ptr buffer)
                (%incf-ptr bufptr nthere)))))))
        

(defun %fasl-vreadstr (s)
  (let* ((nbytes (%fasl-read-count s))
         (copy t)
         (n nbytes)
         (str (faslstate.faslstr s)))
    (declare (fixnum n nbytes))
    (if (> n (length str))
        (setq str (make-string n :element-type 'base-char))
        (setq copy nil))
    (%fasl-read-n-bytes s str 0 nbytes)
    (values str n copy)))

(defun %fasl-copystr (str len)
  (declare (fixnum len))
  (let* ((new (make-string len :element-type 'base-char)))
    (declare (simple-base-string new))
    (declare (optimize (speed 3)(safety 0)))
    (dotimes (i len new)
      (setf (schar new i) (schar str i)))))

(defun %fasl-dispatch (s op)
  (declare (fixnum op))
  (setf (faslstate.faslepush s) (logbitp $fasl-epush-bit op))
  ;(format t "~& dispatch: op = ~d" (logand op (lognot (ash 1 $fasl-epush-bit))))
  (funcall (svref (faslstate.fasldispatch s) (logand op (lognot (ash 1 $fasl-epush-bit)))) 
           s))

(defun %fasl-expr (s)
  (%fasl-dispatch s (%fasl-read-byte s))
  (faslstate.faslval s))

(defun %fasl-expr-preserve-epush (s)
  (let* ((epush (faslstate.faslepush s))
         (val (%fasl-expr s)))
    (setf (faslstate.faslepush s) epush)
    val))


(defun %fasl-vmake-symbol (s &optional idx)
  (declare (fixnum subtype))
  (let* ((n (%fasl-read-count s))
         (str (make-string n :element-type 'base-char)))
    (declare (fixnum n))
    (%fasl-read-n-bytes s str 0 n)
    (let* ((sym (make-symbol str)))
      (when idx (ensure-binding-index sym))
      (%epushval s sym))))

(defun %fasl-vintern (s package &optional binding-index)
  (multiple-value-bind (str len new-p) (%fasl-vreadstr s)
    (with-package-lock (package)
      (multiple-value-bind (symbol access internal-offset external-offset)
          (%find-symbol str len package)
        (unless access
          (unless new-p (setq str (%fasl-copystr str len)))
          (setq symbol (%add-symbol str package internal-offset external-offset)))
        (when binding-index
          (ensure-binding-index symbol))
        (%epushval s symbol)))))

(defun find-package (name)
  (if (packagep name) 
    name
    (%find-pkg (string name))))

(defun set-package (name &aux (pkg (find-package name)))
  (if pkg
    (setq *package* pkg)
    (set-package (%kernel-restart $xnopkg name))))

  
(defun %find-pkg (name &optional (len (length name)))
  (with-package-list-read-lock
      (dolist (p %all-packages%)
        (if (dolist (pkgname (pkg.names p))
              (when (and (= (length pkgname) len)
                         (dotimes (i len t)
                           ;; Aref: allow non-simple strings
                           (unless (eq (aref name i) (schar pkgname i))
                             (return))))
                (return t)))
          (return p)))))



(defun pkg-arg (thing &optional deleted-ok)
  (let* ((xthing (cond ((or (symbolp thing) (typep thing 'character))
                        (string thing))
                       ((typep thing 'string)
                        (ensure-simple-string thing))
                       (t
                        thing))))
    (let* ((typecode (typecode xthing)))
        (declare (fixnum typecode))
        (cond ((= typecode target::subtag-package)
               (if (or deleted-ok (pkg.names xthing))
                 xthing
                 (error "~S is a deleted package ." thing)))
              ((= typecode target::subtag-simple-base-string)
               (or (%find-pkg xthing)
                   (%kernel-restart $xnopkg xthing)))
              (t (report-bad-arg thing 'simple-string))))))

(defun %fasl-vpackage (s)
  (multiple-value-bind (str len new-p) (%fasl-vreadstr s)
    (let* ((p (%find-pkg str len)))
      (%epushval s (or p (%kernel-restart $XNOPKG (if new-p str (%fasl-copystr str len))))))))

(defun %fasl-vlistX (s dotp)
  (let* ((len (%fasl-read-count s)))
    (declare (fixnum len))
    (let* ((val (%epushval s (cons nil nil)))
           (tail val))
      (declare (type cons val tail))
      (setf (car val) (%fasl-expr s))
      (dotimes (i len)
        (setf (cdr tail) (setq tail (cons (%fasl-expr s) nil))))
      (if dotp
        (setf (cdr tail) (%fasl-expr s)))
      (setf (faslstate.faslval s) val))))

(deffaslop $fasl-noop (s)
  (%cant-epush s))


(deffaslop $fasl-vetab-alloc (s)
  (%cant-epush s)
  (setf (faslstate.faslevec s) (make-array (the fixnum (%fasl-read-count s)))
        (faslstate.faslecnt s) 0))

(deffaslop $fasl-arch (s)
  (%cant-epush s)
  (let* ((arch (%fasl-expr s)))
    (declare (fixnum arch))
    #+linuxppc-target
    (progn
      #+ppc32-target
      (unless (= arch 1)
        (error "Not a LinuxPPC32 fasl file : ~s" (faslstate.faslfname s)))
      #+ppc64-target
      (unless (= arch (logior 64 1))
        (error "Not a LinuxPPC64 fasl file : ~s" (faslstate.faslfname s))))
    #+darwinppc-target
    (progn
      #+ppc32-target
      (unless (= arch 3)
        (error "Not a DarwinPPC32 fasl file : ~s" (faslstate.faslfname s)))
      #+ppc64-target
      (unless (= arch (logior 64 3))
        (error "Not a DarwinPPC64 fasl file : ~s" (faslstate.faslfname s))))
    ))


(deffaslop $fasl-veref (s)
  (let* ((idx (%fasl-read-count s)))
    (declare (fixnum idx))
    (if (>= idx (the fixnum (faslstate.faslecnt s)))
      (%bad-fasl s))
    (%epushval s (svref (faslstate.faslevec s) idx))))

(deffaslop $fasl-lfuncall (s)
  (let* ((fun (%fasl-expr-preserve-epush s)))
    ;(break "fun = ~s" fun)
     (%epushval s (funcall fun))))

(deffaslop $fasl-globals (s)
  (setf (faslstate.faslgsymbols s) (%fasl-expr s)))

(deffaslop $fasl-char (s)
  (%epushval s (code-char (%fasl-read-byte s))))

;;; Deprecated
(deffaslop $fasl-fixnum (s)
  (%epushval
   s
   (logior (the fixnum (ash (the fixnum (%word-to-int (%fasl-read-word s)))
                            16))
           (the fixnum (%fasl-read-word s))) ))

(deffaslop $fasl-s32 (s)
  (%stack-block ((buf 4))
    (setf (%get-unsigned-word buf 0) (%fasl-read-word s)
          (%get-unsigned-word buf 2) (%fasl-read-word s))
    (%epushval s (%get-signed-long buf))))

(deffaslop $fasl-s64 (s)
  (%stack-block ((buf 8))
    (setf (%get-unsigned-word buf 0) (%fasl-read-word s)
          (%get-unsigned-word buf 2) (%fasl-read-word s)
          (%get-unsigned-word buf 4) (%fasl-read-word s)
          (%get-unsigned-word buf 6) (%fasl-read-word s))
    (%epushval s (%%get-signed-longlong buf 0))))

(deffaslop $fasl-dfloat (s)
  ;; A double-float is a 3-element "misc" object.
  ;; Element 0 is always 0 and exists solely to keep elements 1 and 2
  ;; aligned on a 64-bit boundary.
  (%epushval s (double-float-from-bits (%fasl-read-long s) (%fasl-read-long s))))

(deffaslop $fasl-sfloat (s)
  (%epushval s (host-single-float-from-unsigned-byte-32 (%fasl-read-long s))))

(deffaslop $fasl-vstr (s)
  (let* ((n (%fasl-read-count s))
         (str (make-string (the fixnum n) :element-type 'base-char)))
    (%epushval s str)
    (%fasl-read-n-bytes s str 0 n)))

(deffaslop $fasl-word-fixnum (s)
  (%epushval s (%word-to-int (%fasl-read-word s))))

(deffaslop $fasl-vmksym (s)
  (%fasl-vmake-symbol s))

(deffaslop $fasl-vintern (s)
  (%fasl-vintern s *package*))

(deffaslop $fasl-vintern-special (s)
  (%fasl-vintern s *package* t))


(deffaslop $fasl-vpkg-intern (s)
  (let* ((pkg (%fasl-expr-preserve-epush s)))
    #+paranoia
    (setq pkg (pkg-arg pkg))
    (%fasl-vintern s pkg)))

(deffaslop $fasl-vpkg-intern-special (s)
  (let* ((pkg (%fasl-expr-preserve-epush s)))
    #+paranoia
    (setq pkg (pkg-arg pkg))
    (%fasl-vintern s pkg t)))

(deffaslop $fasl-vpkg (s)
  (%fasl-vpackage s))

(deffaslop $fasl-cons (s)
  (let* ((cons (%epushval s (cons nil nil))))
    (declare (type cons cons))
    (setf (car cons) (%fasl-expr s)
          (cdr cons) (%fasl-expr s))
    (setf (faslstate.faslval s) cons)))

(deffaslop $fasl-vlist (s)
  (%fasl-vlistX s nil))

(deffaslop $fasl-vlist* (s)
  (%fasl-vlistX s t))

(deffaslop $fasl-nil (s)
  (%epushval s nil))

(deffaslop $fasl-timm (s)
  (rlet ((p :long))
    (setf (%get-long p) (%fasl-read-long s))
    (%epushval s (%get-unboxed-ptr p))))

(deffaslop $fasl-symfn (s)
  (%epushval s (%function (%fasl-expr-preserve-epush s))))
    
(deffaslop $fasl-eval (s)
  (%epushval s (eval (%fasl-expr-preserve-epush s))))

;;; For bootstrapping. The real version is cheap-eval in l1-readloop
(when (not (fboundp 'eval))
  (defun eval (form)
    (if (and (listp form)
             (let ((f (%car form)))
               (and (symbolp f)
                    (functionp (fboundp f)))))
      (apply (%car form) (%cdr form))
      (error "Can't eval yet: ~s" form))))


(deffaslop $fasl-vivec (s)
  (let* ((subtag (%fasl-read-byte s))
         (element-count (%fasl-read-count s))
         (size-in-bytes (subtag-bytes subtag element-count))
         (vector (%alloc-misc element-count subtag))
         (byte-offset (or #+ppc32-target (if (= subtag ppc32::subtag-double-float-vector) 4) 0)))
    (declare (fixnum subtag element-count size-in-bytes))
    (%epushval s vector)
    (%fasl-read-n-bytes s vector byte-offset size-in-bytes)
    vector))

(defun fasl-read-ivector (s subtag)
  (let* ((element-count (%fasl-read-count s))
         (size-in-bytes (subtag-bytes subtag element-count))
         (vector (%alloc-misc element-count subtag)))
    (declare (fixnum subtag element-count size-in-bytes))
    (%epushval s vector)
    (%fasl-read-n-bytes s vector 0 size-in-bytes)
    vector))
  
(deffaslop $fasl-u8-vector (s)
  (fasl-read-ivector s target::subtag-u8-vector))

(deffaslop $fasl-s8-vector (s)
  (fasl-read-ivector s target::subtag-s8-vector))

(deffaslop $fasl-u16-vector (s)
  (fasl-read-ivector s target::subtag-u16-vector))

(deffaslop $fasl-s16-vector (s)
  (fasl-read-ivector s target::subtag-s16-vector))

(deffaslop $fasl-u32-vector (s)
  (fasl-read-ivector s target::subtag-u32-vector))

(deffaslop $fasl-s32-vector (s)
  (fasl-read-ivector s target::subtag-s32-vector))

#+ppc64-target
(deffaslop $fasl-u64-vector (s)
  (fasl-read-ivector s ppc64::subtag-u64-vector))

#+ppc64-target
(deffaslop $fasl-u64-vector (s)
  (fasl-read-ivector s ppc64::subtag-s64-vector))

(deffaslop $fasl-bit-vector (s)
  (fasl-read-ivector s target::subtag-bit-vector))

(deffaslop $fasl-bignum32 (s)
  (let* ((element-count (%fasl-read-count s))
         (size-in-bytes (* element-count 4))
         (num (%alloc-misc element-count target::subtag-bignum)))
    (declare (fixnum subtag element-count size-in-bytes))
    (%fasl-read-n-bytes s num 0 size-in-bytes)
    (setq num (%normalize-bignum-2 t num))
    (%epushval s num)
    num))

(deffaslop $fasl-single-float-vector (s)
  (fasl-read-ivector s target::subtag-single-float-vector))

(deffaslop $fasl-double-float-vector (s)
  #+ppc64-target
  (fasl-read-ivector s ppc64::subtag-double-float-vector)
  #+ppc32-target
  (let* ((element-count (%fasl-read-count s))
         (size-in-bytes (subtag-bytes ppc32::subtag-double-float-vector
                                      element-count))
         (vector (%alloc-misc element-count
                              ppc32::subtag-double-float-vector)))
    (declare (fixnum subtag element-count size-in-bytes))
    (%epushval s vector)
    (%fasl-read-n-bytes s vector (- ppc32::misc-dfloat-offset
                                    ppc32::misc-data-offset)
                        size-in-bytes)
    vector))



(deffaslop $fasl-code-vector (s)
  (let* ((element-count (%fasl-read-count s))
         (size-in-bytes (* 4 element-count))
         (vector (allocate-typed-vector :code-vector element-count)))
    (declare (fixnum subtag element-count size-in-bytes))
    (%epushval s vector)
    (%fasl-read-n-bytes s vector 0 size-in-bytes)
    (%make-code-executable vector)
    vector))

(defun fasl-read-gvector (s subtype)
  (let* ((n (%fasl-read-count s))
         (vector (%alloc-misc n subtype)))
    (declare (fixnum n subtype))
    (%epushval s vector)
    (dotimes (i n (setf (faslstate.faslval s) vector))
      (setf (%svref vector i) (%fasl-expr s)))))

(deffaslop $fasl-vgvec (s)
  (let* ((subtype (%fasl-read-byte s)))
    (fasl-read-gvector s subtype)))
  
(deffaslop $fasl-ratio (s)
  (let* ((r (%alloc-misc target::ratio.element-count target::subtag-ratio)))
    (%epushval s r)
    (setf (%svref r target::ratio.numer-cell) (%fasl-expr s)
          (%svref r target::ratio.denom-cell) (%fasl-expr s))
    (setf (faslstate.faslval s) r)))

(deffaslop $fasl-complex (s)
  (let* ((c (%alloc-misc target::complex.element-count
                         target::subtag-complex)))
    (%epushval s c)
    (setf (%svref c target::complex.realpart-cell) (%fasl-expr s)
          (%svref c target::complex.imagpart-cell) (%fasl-expr s))
    (setf (faslstate.faslval s) c)))

(deffaslop $fasl-t-vector (s)
  (fasl-read-gvector s target::subtag-simple-vector))

(deffaslop $fasl-function (s)
  (fasl-read-gvector s target::subtag-function))

(deffaslop $fasl-istruct (s)
  (fasl-read-gvector s target::subtag-istruct))

(deffaslop $fasl-vector-header (s)
  (fasl-read-gvector s target::subtag-vectorH))

(deffaslop $fasl-array-header (s)
  (fasl-read-gvector s target::subtag-arrayH))

(deffaslop $fasl-svar (s)
  (let* ((epush (faslstate.faslepush s))
         (ecount (faslstate.faslecnt s)))
    (when epush
      (%epushval s 0))
    (let* ((sym (%fasl-expr s))
           (vector (ensure-svar sym)))
      (when epush
        (setf (svref (faslstate.faslevec s) ecount) vector))
      (setf (faslstate.faslval s) vector))))

(deffaslop $fasl-defun (s)
  (%cant-epush s)
  (%defun (%fasl-expr s) (%fasl-expr s)))

(deffaslop $fasl-macro (s)
  (%cant-epush s)
  (%macro (%fasl-expr s) (%fasl-expr s)))

(deffaslop $fasl-defconstant (s)
  (%cant-epush s)
  (%defconstant (%fasl-expr s) (%fasl-expr s) (%fasl-expr s)))

(deffaslop $fasl-defparameter (s)
  (%cant-epush s)
  (let* ((sym (%fasl-expr s))
         (val (%fasl-expr s)))
    (%defvar sym (%fasl-expr s))
    (set sym val)))

;;; (defvar var)
(deffaslop $fasl-defvar (s)
  (%cant-epush s)
  (%defvar (%fasl-expr s)))

;;; (defvar var initfom doc)
(deffaslop $fasl-defvar-init (s)
  (%cant-epush s)
  (let* ((sym (%fasl-expr s))
         (val (%fasl-expr s)))
    (unless (%defvar sym (%fasl-expr s))
      (set sym val))))


(deffaslop $fasl-prog1 (s)
  (let* ((val (%fasl-expr s)))
    (%fasl-expr s)
    (setf (faslstate.faslval s) val)))



(deffaslop $fasl-src (s)
  (%cant-epush s)
  (let* ((source-file (%fasl-expr s)))
    ; (format t "~& source-file = ~s" source-file)
    (setq *loading-file-source-file* source-file)))

(defvar *modules* nil)

;;; Bootstrapping version
(defun provide (module-name)
  (push (string module-name) *modules*))

(deffaslop $fasl-provide (s)
  (provide (%fasl-expr s)))    


;;; The loader itself

(defun %simple-fasl-set-file-pos (s new)
  (let* ((fd (faslstate.faslfd s))
         (posoffset (fd-tell fd)))
    (if (>= (decf posoffset new) 0)
      (let* ((count (faslstate.bufcount s)))
        (if (>= (decf count posoffset ) 0)
          (progn
            (setf (faslstate.bufcount s) posoffset)
            (incf #+ppc32-target (%get-long (faslstate.iobuffer s))
                  #+ppc64-target (%%get-signed-longlong (faslstate.iobuffer s)
                                                        0)
                  count)
            (return-from %simple-fasl-set-file-pos nil)))))
    (progn
      (setf (faslstate.bufcount s) 0)
      (fd-lseek fd new #$SEEK_SET))))

(defun %simple-fasl-get-file-pos (s)
  (- (fd-tell (faslstate.faslfd s)) (faslstate.bufcount s)))

(defparameter *%fasload-verbose* t)

;;; the default fasl file opener sets up the fasl state and checks the header
(defun %simple-fasl-open (string s)
  (let* ((ok nil)
	 (fd (fd-open string #$O_RDONLY))
	 (err 0))
    (declare (fixnum fd))
    (if (>= fd 0)
      (if (< (fd-lseek fd 0 #$SEEK_END) 4)
        (setq err $xnotfasl)
        (progn
          (setq err 0)
          (setf (faslstate.bufcount s) 0
                (faslstate.faslfd s) fd)
          (fd-lseek fd 0 #$SEEK_SET)
          (multiple-value-setq (ok err) (%fasl-check-header s))))
      (setq err fd))
    (unless (eql err 0) (setf (faslstate.faslerr s) err))
    ok))

;;; once the fasl state is set up, this checks the fasl header and
;;; returns (values ok err)
(defun %fasl-check-header (s)
  (let* ((signature (%fasl-read-word s)))
    (declare (fixnum signature))
    (if (= signature $fasl-file-id)
	(values t 0)
      (if (= signature $fasl-file-id1)
	  (progn
	    (%fasl-set-file-pos s (%fasl-read-long s))
	    (values t 0))
	(values nil $xnotfasl)))))

(defun %simple-fasl-close (s)
  (let* ((fd (faslstate.faslfd s)))
    (when fd (fd-close fd))))

(defun %simple-fasl-init-buffer (s)
  (declare (ignore s))
  nil)

(defvar *fasl-api* nil)
(setf *fasl-api* (%istruct 'faslapi
			   #'%simple-fasl-open
			   #'%simple-fasl-close
			   #'%simple-fasl-init-buffer
			   #'%simple-fasl-set-file-pos
			   #'%simple-fasl-get-file-pos
			   #'%simple-fasl-read-buffer
			   #'%simple-fasl-read-byte
			   #'%simple-fasl-read-n-bytes))

(defun %fasl-open (string s)
  (funcall (faslapi.fasl-open *fasl-api*) string s))
(defun %fasl-close (s)
  (funcall (faslapi.fasl-close *fasl-api*) s))
(defun %fasl-init-buffer (s)
  (funcall (faslapi.fasl-init-buffer *fasl-api*) s))
(defun %fasl-set-file-pos (s new)
  (funcall (faslapi.fasl-set-file-pos *fasl-api*) s new))
(defun %fasl-get-file-pos (s)
  (funcall (faslapi.fasl-get-file-pos *fasl-api*) s))
(defun %fasl-read-buffer (s)
  (funcall (faslapi.fasl-read-buffer *fasl-api*) s))
(defun %fasl-read-byte (s)
  (funcall (faslapi.fasl-read-byte *fasl-api*) s))
(defun %fasl-read-n-bytes (s ivector byte-offset n)
  (funcall (faslapi.fasl-read-n-bytes *fasl-api*) s ivector byte-offset n))

(defun %fasload (string &optional (table *fasl-dispatch-table*))
  ;;(dbg string) 
  (when (and *%fasload-verbose*
	     (not *load-verbose*))
    (%string-to-stderr ";Loading ") (pdbg string))
  (let* ((s (%istruct
             'faslstate
             nil
             nil
             nil
             nil
             nil
             nil
             nil
             nil
             nil
             nil
             nil
             nil
             nil
             nil)))
    (declare (dynamic-extent s))
    (setf (faslstate.faslfname s) string)
    (setf (faslstate.fasldispatch s) table)
    (setf (faslstate.faslversion s) 0)
    (%stack-block ((buffer (+ target::node-size $fasl-buf-len)))
      (setf (faslstate.iobuffer s) buffer)
      (%fasl-init-buffer s)
      (let* ((parse-string (make-string 255 :element-type 'base-char)))
        (declare (dynamic-extent parse-string))
        (setf (faslstate.oldfaslstr s) nil
              (faslstate.faslstr s) parse-string)
	(unwind-protect
          (when (%fasl-open string s)
	    (let* ((nblocks (%fasl-read-word s)))
	      (declare (fixnum nblocks))
	      (unless (= nblocks 0)
		(let* ((pos (%fasl-get-file-pos s)))
		  (dotimes (i nblocks)
		    (%fasl-set-file-pos s pos)
		    (%fasl-set-file-pos s (%fasl-read-long s))
		    (incf pos 8)
		    (let* ((version (%fasl-read-word s)))
		      (declare (fixnum version))
		      (if (or (> version (+ #xff00 $fasl-vers))
			      (< version (+ #xff00 $fasl-min-vers)))
                          (%err-disp (if (>= version #xff00) $xfaslvers $xnotfasl))
			(progn
			  (setf (faslstate.faslversion s) version)
			  (%fasl-read-word s) 
			  (%fasl-read-word s)       ; Ignore kernel version stuff
			  (setf (faslstate.faslevec s) nil
				(faslstate.faslecnt s) 0)
			  (do* ((op (%fasl-read-byte s) (%fasl-read-byte s)))
			       ((= op $faslend))
			    (declare (fixnum op))
			    (%fasl-dispatch s op))))))))))
	  (%fasl-close s))
	(let* ((err (faslstate.faslerr s)))
	  (if err
	      (progn
		(when *%fasload-verbose*
		  (let* ((herald ";!!Error loading ")
			 (hlen (length herald))
			 (len (length string))
			 (msg (make-string (+ hlen len))))
		    (declare (dynamic-extent msg))
		    (%copy-ivector-to-ivector herald 0 msg 0 hlen)
		    (%copy-ivector-to-ivector string 0 msg hlen len)
		    (bug msg))
		  (values nil err)))
	    (values t nil)))))))


(defun %new-package-hashtable (size)
  (%initialize-htab (cons nil (cons 0 0)) size))

(defun %initialize-htab (htab size)
  (declare (fixnum size))
  ;; Ensure that "size" is relatively prime to all secondary hash values.
  ;; If it's small enough, pick the next highest known prime out of the
  ;; "primsizes" array.  Otherwize, iterate through all all of "hprimes"
  ;; until we find something relatively prime to all of them.
  (setq size
        (if (> size 32749)
          (do* ((nextsize (logior 1 size) (+ nextsize 2)))
               ()
            (declare (fixnum nextsize))
            (when (dotimes (i 8 t)
                    (unless (eql 1 (gcd nextsize (uvref #.$hprimes i)))
                      (return)))
              (return nextsize)))
          (dotimes (i (the fixnum (length #.$primsizes)))
            (let* ((psize (uvref #.$primsizes i)))
              (declare (fixnum psize))
              (if (>= psize size) 
                (return psize))))))
  (setf (htvec htab) (make-array size #|:initial-element 0|#))
  (setf (htcount htab) 0)
  (setf (htlimit htab) (the fixnum (- size (the fixnum (ash size -3)))))
  htab)


(defun %resize-htab (htab)
  (declare (optimize (speed 3) (safety 0)))  
  (without-interrupts
   (let* ((old-vector (htvec htab))
          (old-len (length old-vector)))
     (declare (fixnum old-len)
              (simple-vector old-vector))
     (let* ((nsyms 0))
       (declare (fixnum nsyms))
       (dovector (s old-vector)
         (when (symbolp s) (incf nsyms)))
       (%initialize-htab htab 
                         (the fixnum (+ 
                                      (the fixnum 
                                        (+ nsyms (the fixnum (ash nsyms -2))))
                                      2)))
       (let* ((new-vector (htvec htab))
              (nnew 0))
         (declare (fixnum nnew)
                  (simple-vector new-vector))
         (dotimes (i old-len (setf (htcount htab) nnew))
           (let* ((s (svref old-vector i)))
               (if (symbolp s)
                 (let* ((pname (symbol-name s)))
                   (setf (svref 
                          new-vector 
                          (nth-value 
                           2
                           (%get-htab-symbol 
                            pname
                            (length pname)
                            htab)))
                         s)
                   (incf nnew)))))
         htab)))))
        
(defun hash-pname (str len)
  (declare (optimize (speed 3) (safety 0)))
  (let* ((primary (%pname-hash str len)))
    (declare (fixnum primary))
    (values primary (aref (the (simple-array (unsigned-byte 16) (8)) $hprimes) (logand primary 7)))))
    


(defun %get-hashed-htab-symbol (str len htab primary secondary)
  (declare (optimize (speed 3) (safety 0))
           (fixnum primary secondary len))
  (let* ((vec (htvec htab))
         (vlen (length vec)))
    (declare (fixnum vlen))
    (do* ((idx (fast-mod primary vlen) (+ i secondary))
          (i idx (if (>= idx vlen) (- idx vlen) idx))
          (elt (svref vec i) (svref vec i)))
         ((eql elt 0) (values nil nil i))
      (declare (fixnum i idx))
      (when (symbolp elt)
        (let* ((pname (symbol-name elt)))
          (if (and 
               (= (the fixnum (length pname)) len)
               (dotimes (j len t)
                 (unless (eq (aref str j) (schar pname j))
                   (return))))
            (return (values t (%symptr->symbol elt) i))))))))

(defun %get-htab-symbol (string len htab)
  (declare (optimize (speed 3) (safety 0)))
  (multiple-value-bind (p s) (hash-pname string len)
    (%get-hashed-htab-symbol string len htab p s)))

(defun %find-symbol (string len package)
  (declare (optimize (speed 3) (safety 0)))
  (multiple-value-bind (found-p sym internal-offset)
                       (%get-htab-symbol string len (pkg.itab package))
    (if found-p
      (values sym :internal internal-offset nil)
      (multiple-value-bind (found-p sym external-offset)
                           (%get-htab-symbol string len (pkg.etab package))
        (if found-p
          (values sym :external internal-offset external-offset)
          (dolist (p (pkg.used package) (values nil nil internal-offset external-offset))
            (multiple-value-bind (found-p sym)
                                 (%get-htab-symbol string len (pkg.etab p))
              (when found-p
                (return (values sym :inherited internal-offset external-offset))))))))))
          
(defun %htab-add-symbol (symbol htab idx)
  (declare (optimize (speed 3) (safety 0)))
  (setf (svref (htvec htab) idx) (%symbol->symptr symbol))
  (if (>= (incf (the fixnum (htcount htab)))
          (the fixnum (htlimit htab)))
    (%resize-htab htab))
  symbol)

(defun %set-symbol-package (symbol package-or-nil)
  (declare (optimize (speed 3) (safety 0)))
  (let* ((symptr (%symbol->symptr symbol))
         (old-pp (%svref symptr target::symbol.package-predicate-cell)))
    (if (consp old-pp)
      (setf (car old-pp) package-or-nil)
      (setf (%svref symptr target::symbol.package-predicate-cell) package-or-nil))))


(let* ((force-export-packages (list *keyword-package*)))
  (defun force-export-packages ()
    force-export-packages)
  (defun package-force-export (p)
    (let* ((pkg (pkg-arg p)))
    (pushnew pkg force-export-packages)
    pkg)))


(defun %insert-symbol (symbol package internal-idx external-idx &optional force-export)
  (let* ((symptr (%symbol->symptr symbol))
         (package-predicate (%svref symptr target::symbol.package-predicate-cell))
         (keyword-package (eq package *keyword-package*)))
    ;; Set home package
    (if package-predicate
      (if (listp package-predicate)
        (unless (%car package-predicate) (%rplaca package-predicate package)))
      (setf (%svref symptr target::symbol.package-predicate-cell) package))
    (if (or force-export (memq package (force-export-packages)))
      (progn
        (%htab-add-symbol symbol (pkg.etab package) external-idx)
        (if keyword-package
          ;;(define-constant symbol symbol)
          (progn
            (%set-sym-global-value symbol symbol)
            (%symbol-bits symbol 
                          (logior (ash 1 $sym_vbit_special) 
                                  (ash 1 $sym_vbit_const)
                                  (the fixnum (%symbol-bits symbol)))))))
      (%htab-add-symbol symbol (pkg.itab package) internal-idx))
    symbol))

;;; PNAME must be a simple string!
(defun %add-symbol (pname package internal-idx external-idx &optional force-export)
  (let* ((sym (make-symbol pname)))
    (%insert-symbol sym package internal-idx external-idx force-export)))




;;; The initial %toplevel-function% sets %toplevel-function% to NIL;
;;; if the %fasload call fails, the lisp should exit (instead of
;;; repeating the process endlessly ...


(defvar %toplevel-function%
  #'(lambda ()
      (declare (special *xload-cold-load-functions*
                        *xload-cold-load-documentation*
                        *xload-startup-file*))
      (%set-tcr-toplevel-function (%current-tcr) nil) ; should get reset by l1-boot.
      ;; Need to make %ALL-PACKAGES-LOCK% early, so that we can casually
      ;; do SET-PACKAGE in cold load functions.
      (setq %all-packages-lock% (make-read-write-lock))
      (dolist (f (prog1 *xload-cold-load-functions* (setq *xload-cold-load-functions* nil)))
        (funcall f))
      (dolist (p %all-packages%)
        (%resize-htab (pkg.itab p))
        (%resize-htab (pkg.etab p)))
      (dolist (f (prog1 *xload-cold-load-documentation* (setq *xload-cold-load-documentation* nil)))
        (apply 'set-documentation f))
      ;; Can't bind any specials until this happens
      (%map-areas #'(lambda (o)
                      (when (eql (typecode o) target::subtag-svar)
                        (cold-load-svar o)))
                  ppc::area-dynamic
                  ppc::area-dynamic)
      (%fasload *xload-startup-file*)))

