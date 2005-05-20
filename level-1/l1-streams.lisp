;;;-*-Mode: LISP; Package: CCL -*-
;;;
;;;   Copyright (C) 1994-2001 Digitool, Inc
;;;   Portions copyright (C) 2001 Clozure Associates
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

(eval-when (:compile-toplevel)
  #+linuxppc-target
  (require "LINUX-SYSCALLS")
  #+darwinppc-target
  (require "DARWIN-SYSCALLS"))

;;;

(defclass stream ()
  ((direction :initarg :direction :initform nil :reader stream-direction)
   (closed :initform nil)))

(defclass input-stream (stream)
  ((shared-resource :initform nil :accessor input-stream-shared-resource)))

(defclass output-stream (stream) ())

;;; The "direction" argument only helps us dispatch on two-way streams:
;;; it's legal to ask for the :output device of a stream that's only open
;;; for input, and one might get a non-null answer in that case.
(defmethod stream-device ((s stream) direction)
  (declare (ignore direction)))

;;; Some generic stream functions:
(defmethod stream-length ((x t) &optional new)
  (declare (ignore new))
  (report-bad-arg x 'stream))

(defmethod stream-position ((x t) &optional new)
  (declare (ignore new))
  (report-bad-arg x 'stream))

(defmethod stream-element-type ((x t))
  (report-bad-arg x 'stream))

;;; For input streams:

;; From Shannon Spires, slightly modified.
(defun generic-read-line (s)
  (let* ((str (make-array 20 :element-type 'base-char
			  :adjustable t :fill-pointer 0))
	 (eof nil))
    (do* ((ch (read-char s nil :eof) (read-char s nil :eof)))
	 ((or (eq ch #\newline) (setq eof (eq ch :eof)))
	  (values (ensure-simple-string str) eof))
      (vector-push-extend ch str))))

(defun generic-character-read-list (stream list count)
  (declare (fixnum count))
  (do* ((tail list (cdr tail))
	(i 0 (1+ i)))
       ((= i count) count)
    (declare (fixnum i))
    (let* ((ch (read-char stream nil :eof)))
      (if (eq ch :eof)
	(return i)
	(rplaca tail ch)))))

(defun generic-binary-read-list (stream list count)
  (declare (fixnum count))
  (do* ((tail list (cdr tail))
	(i 0 (1+ i)))
       ((= i count) count)
    (declare (fixnum i))
    (let* ((ch (stream-read-byte stream)))
      (if (eq ch :eof)
	(return i)
	(rplaca tail ch)))))

(defun generic-character-read-vector (stream vector start end)
  (declare (fixnum start end))
  (do* ((i start (1+ i)))
       ((= i end) end)
    (declare (fixnum i))
    (let* ((ch (stream-read-char stream)))
      (if (eq ch :eof)
	(return i)
	(setf (uvref vector i) ch)))))

(defun generic-binary-read-vector (stream vector start end)
  (declare (fixnum start end))
  (do* ((i start (1+ i)))
       ((= i end) end)
    (declare (fixnum i))
    (let* ((byte (stream-read-byte stream)))
      (if (eq byte :eof)
	(return i)
	(setf (uvref vector i) byte)))))


;;; For output streams:

(defun generic-advance-to-column (s col)
  (let* ((current (column s)))
    (unless (null current)
      (when (< current col)
	(do* ((i current (1+ i)))
	     ((= i col))
	  (write-char #\Space s)))
      t)))



(defun generic-stream-write-string (stream string start end)
  (setq end (check-sequence-bounds string start end))
  (locally (declare (fixnum start end))
    (multiple-value-bind (vect offset) (array-data-and-offset string)
      (declare (fixnum offset))
      (unless (zerop offset)
	(incf start offset)
	(incf end offset))
      (do* ((i start (1+ i)))
	   ((= i end) string)
	(declare (fixnum i))
	(write-char (schar vect i) stream)))))












(defloadvar *heap-ivectors* ())
(defvar *heap-ivector-lock* (make-lock))



(defun %make-heap-ivector (subtype size-in-bytes size-in-elts)
  (with-macptrs ((ptr (malloc (+ size-in-bytes (+ 4 2 7))))) ; 4 for header, 2 for delta, 7 for round up
    (let ((vect (fudge-heap-pointer ptr subtype size-in-elts))
          (p (%null-ptr)))
      (%vect-data-to-macptr vect p)
      (with-lock-grabbed (*heap-ivector-lock*)
        (push vect *heap-ivectors*))
      (values vect p))))

(defun %heap-ivector-p (v)
  (with-lock-grabbed (*heap-ivector-lock*)
    (not (null (member v *heap-ivectors* :test #'eq)))))


(defun dispose-heap-ivector (v)
  (if (%heap-ivector-p v)
    (with-macptrs (p)
      (with-lock-grabbed (*heap-ivector-lock*)
        (setq *heap-ivectors* (delq v *heap-ivectors*)))
      (%%make-disposable p v)
      (free p))))

(defun %dispose-heap-ivector (v)
  (dispose-heap-ivector v))

(defun make-heap-ivector (element-count element-type)
  (let* ((subtag (ccl::element-type-subtype element-type)))
    (unless
        #+ppc32-target
        (= (logand subtag ppc32::fulltagmask)
               ppc32::fulltag-immheader)
        #+ppc64-target
        (= (logand subtag ppc64::lowtagmask)
           ppc64::lowtag-immheader)
      (error "~s is not an ivector subtype." element-type))
    (let* ((size-in-octets (ccl::subtag-bytes subtag element-count)))
      (multiple-value-bind (pointer vector)
          (ccl::%make-heap-ivector subtag size-in-octets element-count)
        (values pointer vector size-in-octets)))))









(defvar *elements-per-buffer* 2048)  ; default buffer size for file io

(defmethod streamp ((x t))
  nil)

(defmethod streamp ((x stream))
  t)

(defmethod stream-io-error ((stream stream) error-number context)
  (error 'simple-stream-error :stream stream
	 :format-control (format nil "~a during ~a"
				 (%strerror error-number) context)))

(defmethod initialize-instance :after ((stream input-stream) &key)
  (let ((direction (slot-value stream 'direction)))
    (if (null direction)
      (set-slot-value stream 'direction :input)
      (if (eq direction :output)
        (set-slot-value stream 'direction :io)))))


(defmethod stream-write-char ((stream stream) char)
  (declare (ignore char))
  (error "stream ~S is not capable of output" stream))

(defun stream-write-entire-string (stream string)
  (stream-write-string stream string))


(defmethod stream-read-char ((x t))
  (report-bad-arg x 'stream))

(defmethod stream-read-char ((stream stream))
  (error "~s is not capable of input" stream))

(defmethod stream-unread-char ((x t) char)
  (declare (ignore char))
  (report-bad-arg x 'stream))

(defmethod stream-unread-char ((stream stream) char)
  (declare (ignore char))
  (error "stream ~S is not capable of input" stream))



(defmethod stream-force-output ((stream output-stream)) nil)
(defmethod stream-maybe-force-output ((stream stream))
  (stream-force-output stream))

(defmethod stream-finish-output ((stream output-stream)) nil)



(defmethod stream-clear-output ((stream output-stream)) nil)

(defmethod close ((stream stream) &key abort)
  (declare (ignore abort))
  (with-slots ((closed closed)) stream
    (unless closed
      (setf closed t))))



(defmethod open-stream-p ((x t))
  (report-bad-arg x 'stream))

(defmethod open-stream-p ((stream stream))
  (not (slot-value stream 'closed)))

(defmethod stream-fresh-line ((stream output-stream))
  (terpri stream)
  t)

(defmethod stream-line-length ((stream stream))
  "This is meant to be shadowed by particular kinds of streams,
   esp those associated with windows."
  80)

(defmethod interactive-stream-p ((x t))
  (report-bad-arg x 'stream))

(defmethod interactive-stream-p ((stream stream)) nil)

(defmethod stream-clear-input ((x t))
  (report-bad-arg x 'stream))
(defmethod stream-clear-input ((stream input-stream)) nil)

(defmethod stream-listen ((stream input-stream))
  (not (eofp stream)))

(defmethod stream-filename ((stream stream))
  (report-bad-arg stream 'file-stream))




;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;; For input streams, the IO-BUFFER-COUNT field denotes the number
;;; of elements read from the underlying input source (e.g., the
;;; file system.)  For output streams, it's the high-water mark of
;;; elements output to the buffer.

(defstruct io-buffer
  (buffer nil :type (or (simple-array * (*)) null))
  (bufptr nil :type (or macptr null))
  (size 0 :type fixnum)			; size (in octets) of buffer
  (idx 0 :type fixnum)			; index of next element
  (count 0 :type fixnum)		; count of active elements
  (limit 0 :type fixnum)		; size (in elements) of buffer
  )

(defmethod print-object ((buf io-buffer) out)
  (print-unreadable-object (buf out :identity t :type t)
    (let* ((buffer (io-buffer-buffer buf)))
      (when buffer (format out " ~s " (array-element-type buffer))))
    (format out "~d/~d/~d"
	    (io-buffer-idx buf)
	    (io-buffer-count buf)
	    (io-buffer-limit buf))))

(defstruct ioblock
  stream                                ; the stream being buffered
  untyi-char                            ; nil or last value passed to
                                        ;  stream-unread-char
  (inbuf nil :type (or null io-buffer))
  (outbuf nil :type (or null io-buffer))
  (element-type 'character)
  (element-shift 0 :type fixnum)        ;element shift count
  (charpos 0 :type (or nil fixnum))     ;position of cursor
  (device -1 :type fixnum)              ;file descriptor
  (advance-function 'ioblock-advance)
  (listen-function 'ioblock-listen)
  (eofp-function 'ioblock-eofp)
  (force-output-function 'ioblock-force-output)
  (close-function 'ioblock-close)
  (inbuf-lock nil)
  (eof nil)
  (interactive nil)
  (dirty nil)
  (outbuf-lock nil))


;;; Functions on ioblocks.  So far, we aren't saying anything
;;; about how streams use them.


(defun ioblock-octets-to-elements (ioblock octets)
  (let* ((shift (ioblock-element-shift ioblock)))
    (declare (fixnum shift))
    (if (zerop shift)
      octets
      (ash octets (- shift)))))

(defun ioblock-elements-to-octets (ioblock elements)
  (let* ((shift (ioblock-element-shift ioblock)))
    (declare (fixnum shift))
    (if (zerop shift)
      elements
      (ash elements shift))))



(defmacro with-ioblock-lock-grabbed ((lock)
                                       &body body)
  `(with-lock-grabbed (,lock)
    ,@body))

(defmacro with-ioblock-lock-grabbed-maybe ((lock)
					   &body body)
  `(with-lock-grabbed-maybe (,lock)
    ,@body))

; ioblock must really be an ioblock or you will crash
(defmacro with-ioblock-input-locked ((ioblock) &body body)
  `(with-ioblock-lock-grabbed ((locally (declare (optimize (speed 3) (safety 0)))
                                   (ioblock-inbuf-lock ,ioblock)))
     ,@body))
(defmacro with-ioblock-output-locked ((ioblock) &body body)
  `(with-ioblock-lock-grabbed ((locally (declare (optimize (speed 3) (safety 0)))
                                   (ioblock-outbuf-lock ,ioblock)))
     ,@body))

(defmacro with-ioblock-output-locked-maybe ((ioblock) &body body)
  `(with-ioblock-lock-grabbed-maybe ((locally (declare (optimize (speed 3) (safety 0)))
				       (ioblock-outbuf-lock ,ioblock)))
     ,@body))

(defun %ioblock-advance (ioblock read-p)
  (funcall (ioblock-advance-function ioblock)
           (ioblock-stream ioblock)
           ioblock
           read-p))
(declaim (inline %ioblock-read-byte))

;;; Should only be called with the ioblock locked
(defun %ioblock-read-byte (ioblock)
  (declare (optimize (speed 3) (safety 0)))
  (if (ioblock-untyi-char ioblock)
    (prog1 (%char-code (ioblock-untyi-char ioblock))
      (setf (ioblock-untyi-char ioblock) nil))
    (let* ((buf (ioblock-inbuf ioblock))
	   (idx (io-buffer-idx buf))
	   (limit (io-buffer-count buf)))
      (declare (fixnum idx limit))
      (when (= idx limit)
	(unless (%ioblock-advance ioblock t)
	  (return-from %ioblock-read-byte :eof))
	(setq idx (io-buffer-idx buf)
	      limit (io-buffer-count buf)))
      (let ((byte (uvref (io-buffer-buffer buf) idx)))
	(setf (io-buffer-idx buf) (the fixnum (1+ idx)))
	(if (characterp byte) (%char-code byte) byte)))))

(defun %ioblock-tyi (ioblock &optional (hang t))
  (if (ioblock-untyi-char ioblock)
    (prog1 (ioblock-untyi-char ioblock)
      (setf (ioblock-untyi-char ioblock) nil))
    (let* ((buf (ioblock-inbuf ioblock))
	   (idx (io-buffer-idx buf))
	   (limit (io-buffer-count buf)))
      (declare (fixnum idx limit))
      (when (= idx limit)
	(unless (%ioblock-advance ioblock hang)
	  (return-from %ioblock-tyi (if (ioblock-eof ioblock) :eof)))
	(setq idx (io-buffer-idx buf)
	      limit (io-buffer-count buf)))
      (let ((byte (uvref (io-buffer-buffer buf) idx)))
	(setf (io-buffer-idx buf) (the fixnum (1+ idx)))
	(if (characterp byte) byte (%code-char byte))))))

(defun %ioblock-peek-char (ioblock)
  (or (ioblock-untyi-char ioblock)
      (let* ((buf (ioblock-inbuf ioblock))
             (idx (io-buffer-idx buf))
             (limit (io-buffer-count buf)))
        (declare (fixnum idx limit))
        (when (= idx limit)
          (unless (%ioblock-advance ioblock t)
            (return-from %ioblock-peek-char :eof))
          (setq idx (io-buffer-idx buf)
                limit (io-buffer-count buf)))
	(let ((byte (uvref (io-buffer-buffer buf) idx)))
	  (if (characterp byte) byte (%code-char byte))))))

(defun %ioblock-clear-input (ioblock)    
    (let* ((buf (ioblock-inbuf ioblock)))
      (setf (io-buffer-count buf) 0
	    (io-buffer-idx buf) 0
	    (ioblock-untyi-char ioblock) nil)))

(defun %ioblock-untyi (ioblock char)
  (if (ioblock-untyi-char ioblock)
    (error "Two UNREAD-CHARs without intervening READ-CHAR on ~s"
	   (ioblock-stream ioblock))
    (setf (ioblock-untyi-char ioblock) char)))

(declaim (inline ioblock-inpos))

(defun ioblock-inpos (ioblock)
  (io-buffer-idx (ioblock-inbuf ioblock)))

(declaim (inline ioblock-outpos))

(defun ioblock-outpos (ioblock)
  (io-buffer-count (ioblock-outbuf ioblock)))

(declaim (inline %ioblock-force-output))

(defun %ioblock-force-output (ioblock finish-p)
  (funcall (ioblock-force-output-function ioblock)
           (ioblock-stream ioblock)
           ioblock
           (ioblock-outpos ioblock)
           finish-p))

;;; ivector should be an ivector.  The ioblock should have an
;;; element-shift of 0; start-octet and num-octets should of course
;;; be sane.  This is mostly to give the fasdumper a quick way to
;;; write immediate data.
(defun %ioblock-out-ivect (ioblock ivector start-octet num-octets)
  (unless (= 0 (the fixnum (ioblock-element-shift ioblock)))
    (error "Can't write vector to stream ~s" (ioblock-stream ioblock)))
  (let* ((written 0)
	 (out (ioblock-outbuf ioblock))
	 (bufsize (io-buffer-size out))
	 (buffer (io-buffer-buffer out)))
    (declare (fixnum written bufsize))
    (do* ((pos start-octet (+ pos written))
	  (left num-octets (- left written)))
	 ((= left 0) num-octets)
      (declare (fixnum pos left))
      (setf (ioblock-dirty ioblock) t)
      (let* ((index (io-buffer-idx out))
	     (count (io-buffer-count out))
	     (avail (- bufsize index)))
	(declare (fixnum index avail count))
	(cond
	  ((= (setq written avail) 0)
	   (%ioblock-force-output ioblock nil))
	  (t
	   (if (> written left)
	     (setq written left))
	   (%copy-ivector-to-ivector ivector pos buffer index written)
	   (setf (ioblock-dirty ioblock) t)
	   (incf index written)
	   (if (> index count)
	     (setf (io-buffer-count out) index))
	   (setf (io-buffer-idx out) index)
	   (if (= index  bufsize)
	     (%ioblock-force-output ioblock nil))))))))

(declaim (inline %ioblock-write-simple-string))

(defun %ioblock-write-simple-string (ioblock string start-octet num-octets)
  (declare (fixnum start-octet num-octets) (simple-string string))
  (let* ((written 0)
	 (col (ioblock-charpos ioblock))
	 (out (ioblock-outbuf ioblock))
	 (bufsize (io-buffer-size out))
	 (buffer (io-buffer-buffer out)))
    (declare (fixnum written bufsize col)
	     (simple-string buffer)
	     (optimize (speed 3) (safety 0)))
    (do* ((pos start-octet (+ pos written))
	  (left num-octets (- left written)))
	 ((= left 0) (setf (ioblock-charpos ioblock) col)  num-octets)
      (declare (fixnum pos left))
      (setf (ioblock-dirty ioblock) t)
      (let* ((index (io-buffer-idx out))
	     (count (io-buffer-count out))
	     (avail (- bufsize index)))
	(declare (fixnum index avail count))
	(cond
	  ((= (setq written avail) 0)
	   (%ioblock-force-output ioblock nil))
	  (t
	   (if (> written left)
	     (setq written left))
	   (do* ((p pos (1+ p))
		 (i index (1+ i))
		 (j 0 (1+ j)))
		((= j written))
	     (declare (fixnum p i j))
	     (let* ((ch (schar string p)))
	       (if (eql ch #\newline)
		 (setq col 0)
		 (incf col))
	       (setf (schar buffer i) ch)))
	   (setf (ioblock-dirty ioblock) t)
	   (incf index written)
	   (if (> index count)
	     (setf (io-buffer-count out) index))
	   (setf (io-buffer-idx out) index)
	   (if (= index  bufsize)
	     (%ioblock-force-output ioblock nil))))))))


(defun %ioblock-eofp (ioblock)
  (let* ((buf (ioblock-inbuf ioblock)))
   (and (eql (io-buffer-idx buf)
             (io-buffer-count buf))
         (locally (declare (optimize (speed 3) (safety 0)))
           (with-ioblock-input-locked (ioblock)
             (funcall (ioblock-eofp-function ioblock)
		      (ioblock-stream ioblock)
		      ioblock))))))

(defun %ioblock-listen (ioblock)
  (let* ((buf (ioblock-inbuf ioblock)))
    (or (< (the fixnum (io-buffer-idx buf))
           (the fixnum (io-buffer-count buf)))
	(funcall (ioblock-listen-function ioblock)
		 (ioblock-stream ioblock)
		 ioblock))))

(declaim (inline %ioblock-write-element))

(defun %ioblock-write-element (ioblock element)
  (declare (optimize (speed 3) (safety 0)))
  (let* ((buf (ioblock-outbuf ioblock))
         (idx (io-buffer-idx buf))
	 (count (io-buffer-count buf))
         (limit (io-buffer-limit buf)))
    (declare (fixnum idx limit count))
    (when (= idx limit)
      (%ioblock-force-output ioblock nil)
      (setq idx 0 count 0))
    (setf (aref (io-buffer-buffer buf) idx) element)
    (incf idx)
    (setf (io-buffer-idx buf) idx)
    (when (> idx count)
      (setf (io-buffer-count buf) idx))
    (setf (ioblock-dirty ioblock) t)
    element))

(defun %ioblock-write-char (ioblock char)
  (declare (optimize (speed 3) (safety 0)))
  (if (eq char #\linefeed)
    (setf (ioblock-charpos ioblock) 0)
    (incf (ioblock-charpos ioblock)))
  (unless (eq (typecode (io-buffer-buffer (ioblock-outbuf ioblock)))
	      ppc32::subtag-simple-base-string)
    (setq char (char-code char)))
  (%ioblock-write-element ioblock char))

(defun %ioblock-write-byte (ioblock byte)
  (declare (optimize (speed 3) (safety 0)))
  (when (eq (typecode (io-buffer-buffer (ioblock-outbuf ioblock)))
	    ppc32::subtag-simple-base-string)
    (setq byte (code-char byte)))
  (%ioblock-write-element ioblock byte))

  
(defun %ioblock-clear-output (ioblock)
  (let* ((buf (ioblock-outbuf ioblock)))                      
    (setf (io-buffer-count buf) 0
            (io-buffer-idx buf) 0)))

(defun %ioblock-read-line (ioblock)
  (let* ((string "")
	 (len 0)
	 (eof nil)
	 (inbuf (ioblock-inbuf ioblock))
	 (buf (io-buffer-buffer inbuf))
	 (newline (if (eq (typecode buf) ppc32::subtag-simple-base-string)
		    #\newline
		    (char-code #\newline))))
    (let* ((ch (ioblock-untyi-char ioblock)))
      (when ch
	(setf (ioblock-untyi-char ioblock) nil)
	(if (eql ch #\newline)
	  (return-from %ioblock-read-line 
	    (values string nil))
	  (progn
	    (setq string (make-string 1)
		  len 1)
	    (setf (schar string 0) ch)))))
    (loop
	(let* ((more 0)
	       (idx (io-buffer-idx inbuf))
	       (count (io-buffer-count inbuf)))
	  (declare (fixnum idx count more))
	  (if (= idx count)
	    (if eof
	      (return (values string t))
	      (progn
		(setq eof t)
		(%ioblock-advance ioblock t)))
	    (progn
	      (setq eof nil)
	      (let* ((pos (position newline buf :start idx :end count)))
		(when pos
		  (locally (declare (fixnum pos))
		    (setf (io-buffer-idx inbuf) (the fixnum (1+ pos)))
		    (setq more (- pos idx))
		    (unless (zerop more)
		      (setq string
			    (%extend-vector
			     0 string (the fixnum (+ len more)))))
		    (%copy-ivector-to-ivector
		     buf idx string len more)
		    (return (values string nil))))
		;; No #\newline in the buffer.  Read everything that's
		;; there into the string, and fill the buffer again.
		(setf (io-buffer-idx inbuf) count)
		(setq more (- count idx)
		      string (%extend-vector
			      0 string (the fixnum (+ len more))))
		(%copy-ivector-to-ivector
		 buf idx string len more)
		(incf len more))))))))
	 
(defun %ioblock-character-read-vector (ioblock vector start end)
  (do* ((i start)
	(in (ioblock-inbuf ioblock))
	(inbuf (io-buffer-buffer in))
	(need (- end start)))
       ((= i end) end)
    (declare (fixnum i need))
    (let* ((ch (%ioblock-tyi ioblock)))
      (if (eq ch :eof)
	(return i))
      (setf (schar vector i) ch)
      (incf i)
      (decf need)
      (let* ((idx (io-buffer-idx in))
	     (count (io-buffer-count in))
	     (avail (- count idx)))
	(declare (fixnum idx count avail))
	(unless (zerop avail)
	  (if (> avail need)
	    (setq avail need))
	  (%copy-ivector-to-ivector inbuf idx vector i avail)
	  (setf (io-buffer-idx in) (+ idx avail))
	  (incf i avail)
	  (decf need avail))))))

(defun %ioblock-binary-read-vector (ioblock vector start end)
  (declare (fixnum start end))
  (let* ((in (ioblock-inbuf ioblock))
	 (inbuf (io-buffer-buffer in)))
    (if (not (= (the fixnum (typecode inbuf))
		(the fixnum (typecode vector))))
      (do* ((i start (1+ i)))
	   ((= i end) i)
	(declare (fixnum i))
	(let* ((b (%ioblock-read-byte ioblock)))
	  (if (eq b :eof)
	    (return i)
	    (setf (uvref vector i) b))))
      (do* ((i start)
	    (need (- end start)))
	   ((= i end) end)
	(declare (fixnum i need))
	(let* ((ch (%ioblock-read-byte ioblock)))
	  (if (eq ch :eof)
	    (return i))
	  (setf (uvref vector i) ch)
	  (incf i)
	  (decf need)
	  (let* ((idx (io-buffer-idx in))
		 (count (io-buffer-count in))
		 (avail (- count idx)))
	    (declare (fixnum idx count avail))
	    (unless (zerop avail)
	      (if (> avail need)
		(setq avail need))
	      (%copy-ivector-to-ivector
	       inbuf
	       (ioblock-elements-to-octets ioblock idx)
	       vector
	       (ioblock-elements-to-octets ioblock i)
	       (ioblock-elements-to-octets ioblock avail))
	      (setf (io-buffer-idx in) (+ idx avail))
	      (incf i avail)
	      (decf need avail))))))))

;;; About the same, only less fussy about ivector's element-type.
;;; (All fussiness is about the stream's element-type ...).
;;; Whatever the element-type is, elements must be 1 octet in size.
(defun %ioblock-character-in-ivect (ioblock vector start nb)
  (declare (type (simple-array (unsigned-byte 8) (*)) vector)
	   (fixnum start nb)
	   (optimize (speed 3) (safety 0)))
  (unless (= 0 (the fixnum (ioblock-element-shift ioblock)))
    (error "Can't read vector from stream ~s" (ioblock-stream ioblock)))
  (do* ((i start)
	(in (ioblock-inbuf ioblock))
	(inbuf (io-buffer-buffer in))
	(need nb)
	(end (+ start nb)))
       ((= i end) end)
    (declare (fixnum i end need))
    (let* ((ch (%ioblock-tyi ioblock)))
      (if (eq ch :eof)
	(return (- i start)))
      (setf (aref vector i) (char-code ch))
      (incf i)
      (decf need)
      (let* ((idx (io-buffer-idx in))
	     (count (io-buffer-count in))
	     (avail (- count idx)))
	(declare (fixnum idx count avail))
	(unless (zerop avail)
	  (if (> avail need)
	    (setq avail need))
	  (%copy-ivector-to-ivector inbuf idx vector i avail)
	  (setf (io-buffer-idx in) (+ idx avail))
	  (incf i avail)
	  (decf need avail))))))

(defun %ioblock-binary-in-ivect (ioblock vector start nb)
  (declare (type (simple-array (unsigned-byte 8) (*)) vector)
	   (fixnum start nb)
	   (optimize (speed 3) (safety 0)))
  (unless (= 0 (the fixnum (ioblock-element-shift ioblock)))
    (error "Can't read vector from stream ~s" (ioblock-stream ioblock)))
  (do* ((i start)
	(in (ioblock-inbuf ioblock))
	(inbuf (io-buffer-buffer in))
	(need nb)
	(end (+ start nb)))
       ((= i end) nb)
    (declare (fixnum i end need))
    (let* ((b (%ioblock-read-byte ioblock)))
      (if (eq b :eof)
	(return (- i start)))
      (setf (uvref vector i) b)
      (incf i)
      (decf need)
      (let* ((idx (io-buffer-idx in))
	     (count (io-buffer-count in))
	     (avail (- count idx)))
	(declare (fixnum idx count avail))
	(unless (zerop avail)
	  (if (> avail need)
	    (setq avail need))
	  (%copy-ivector-to-ivector inbuf idx vector i avail)
	  (setf (io-buffer-idx in) (+ idx avail))
	  (incf i avail)
	  (decf need avail))))))

(defun %ioblock-close (ioblock)
  (let* ((stream (ioblock-stream ioblock)))
      (funcall (ioblock-close-function ioblock) stream ioblock)
      (setf (stream-ioblock stream) nil)
      (let* ((in-iobuf (ioblock-inbuf ioblock))
             (out-iobuf (ioblock-outbuf ioblock))
             (in-buffer (if in-iobuf (io-buffer-buffer in-iobuf)))
             (in-bufptr (if in-iobuf (io-buffer-bufptr in-iobuf)))
             (out-buffer (if out-iobuf (io-buffer-buffer out-iobuf)))
             (out-bufptr (if out-iobuf (io-buffer-bufptr out-iobuf))))
        (if (and in-buffer in-bufptr)
          (%dispose-heap-ivector in-buffer))
        (unless (eq in-buffer out-buffer)
          (if (and out-buffer out-bufptr)
            (%dispose-heap-ivector out-buffer)))
        (when in-iobuf
          (setf (io-buffer-buffer in-iobuf) nil
                (io-buffer-bufptr in-iobuf) nil
                (ioblock-inbuf ioblock) nil))
        (when out-iobuf
          (setf (io-buffer-buffer out-iobuf) nil
                (io-buffer-bufptr out-iobuf) nil
                (ioblock-outbuf ioblock) nil)))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;





(defun init-stream-ioblock (stream
                            &key
                            insize ; integer to allocate inbuf here, nil
                                        ; otherwise
                            outsize ; integer to allocate outbuf here, nil
                                        ; otherwise
                            share-buffers-p ; true if input and output
                                        ; share a buffer
                            element-type
                            device
                            advance-function
                            listen-function
                            eofp-function
                            force-output-function
                            close-function
                            element-shift
                            interactive
                            &allow-other-keys)
  (declare (ignorable element-shift))
  (let* ((ioblock (or (let* ((ioblock (stream-ioblock stream nil)))
                        (when ioblock
                          (setf (ioblock-stream ioblock) stream)
                          ioblock))
                      (stream-create-ioblock stream))))
    (when insize
      (unless (ioblock-inbuf ioblock)
        (multiple-value-bind (buffer ptr in-size-in-octets)
            (make-heap-ivector insize element-type)
          (setf (ioblock-inbuf ioblock)
                (make-io-buffer :buffer buffer
                                :bufptr ptr
                                :size in-size-in-octets
                                :limit insize))
          (setf (ioblock-inbuf-lock ioblock) (make-lock))
          (setf (ioblock-element-shift ioblock) (max 0 (ceiling (log  (/ in-size-in-octets insize) 2))))
          )))
    (if share-buffers-p
        (if insize
            (progn (setf (ioblock-outbuf ioblock)
                         (ioblock-inbuf ioblock))
                   (setf (ioblock-outbuf-lock ioblock)
                         (ioblock-inbuf-lock ioblock)))
          (error "Can't share buffers unless insize is non-zero and non-null"))
      
      (when outsize
        (unless (ioblock-outbuf ioblock)
          (multiple-value-bind (buffer ptr out-size-in-octets)
              (make-heap-ivector outsize element-type)
            (setf (ioblock-outbuf ioblock)
                  (make-io-buffer :buffer buffer
                                  :bufptr ptr
                                  :count 0
                                  :limit outsize
                                  :size out-size-in-octets))
            (setf (ioblock-outbuf-lock ioblock) (make-lock))
            (setf (ioblock-element-shift ioblock) (max 0 (ceiling (log (/ out-size-in-octets outsize) 2))))
            ))))
    (when element-type
      (setf (ioblock-element-type ioblock) element-type))
;    (when element-shift
;      (setf (ioblock-element-shift ioblock) element-shift))
    (when device
      (setf (ioblock-device ioblock) device))
    (when advance-function
      (setf (ioblock-advance-function ioblock) advance-function))
    (when listen-function
      (setf (ioblock-listen-function ioblock) listen-function))
    (when eofp-function
      (setf (ioblock-eofp-function ioblock) eofp-function))
    (when force-output-function
      (setf (ioblock-force-output-function ioblock) force-output-function))
    (when close-function
      (setf (ioblock-close-function ioblock) close-function))
    (when interactive
      (setf (ioblock-interactive ioblock) interactive))
    (setf (stream-ioblock stream) ioblock)))

;;; We can't define a MAKE-INSTANCE method on STRUCTURE-CLASS subclasses
;;; in MCL; of course, calling the structure-class's constructor does
;;; much the same thing (but note that MCL only keeps track of the
;;; default, automatically generated constructor.)
(defun make-ioblock-stream (class-name
			    &rest initargs
			    &key 
			    &allow-other-keys)
  (declare (dynamic-extent initargs))
  (let* ((class (find-class class-name))
	 (s   (apply #'make-instance class :allow-other-keys t initargs)))
    (apply #'init-stream-ioblock s initargs)
    s))
    


(defmethod select-stream-class ((s symbol) in-p out-p char-p)
  (select-stream-class (class-prototype (find-class s)) in-p out-p char-p))

(defmethod select-stream-class ((s structure-class) in-p out-p char-p)
  (select-stream-class (class-prototype s) in-p out-p char-p))

(defmethod select-stream-class ((s standard-class) in-p out-p char-p)
  (select-stream-class (class-prototype s) in-p out-p char-p))


(defun make-fd-stream (fd &key
			  (direction :input)
			  (interactive t)
			  (elements-per-buffer *elements-per-buffer*)
			  (element-type 'character)
			  (class 'fd-stream))
  (let* ((in-p (member direction '(:io :input)))
         (out-p (member direction '(:io :output)))
         (char-p (or (eq element-type 'character)
                     (subtypep element-type 'character)))
         (class-name (select-stream-class class in-p out-p char-p)))
    (make-ioblock-stream class-name
			 :insize (if in-p elements-per-buffer)
			 :outsize (if out-p elements-per-buffer)
			 :device fd
			 :interactive interactive
			 :element-type element-type
			 :advance-function (if in-p
					     (select-stream-advance-function class))
			 :listen-function (if in-p 'fd-stream-listen)
			 :eofp-function (if in-p 'fd-stream-eofp)
			 :force-output-function (if out-p
						  (select-stream-force-output-function class))
			 :close-function 'fd-stream-close)))
  
;;;  Fundamental streams.

(defclass fundamental-stream (stream)
    ())

(defclass fundamental-input-stream (fundamental-stream input-stream)
    ())

(defclass fundamental-output-stream (fundamental-stream output-stream)
    ())

(defmethod input-stream-p ((x t))
  (report-bad-arg x 'stream))
			   
(defmethod input-stream-p ((s fundamental-input-stream))
  t)

(defmethod output-stream-p ((x t))
  (report-bad-arg x 'stream))

(defmethod output-stream-p ((s fundamental-input-stream))
  (typep s 'fundamental-output-stream))

(defmethod output-stream-p ((s fundamental-output-stream))
  t)

(defmethod input-stream-p ((s fundamental-output-stream))
  (typep s 'fundamental-input-stream))

(defclass fundamental-character-stream (fundamental-stream)
    ())

(defmethod stream-element-type ((s fundamental-character-stream))
  'character)

(defclass fundamental-binary-stream (fundamental-stream)
    ())

(defclass fundamental-character-input-stream (fundamental-input-stream
                                              fundamental-character-stream)
    ())

(defmethod stream-read-char-no-hang ((s fundamental-character-input-stream))
  (stream-read-char s))

(defmethod stream-peek-char ((s fundamental-character-input-stream))
  (let* ((ch (stream-read-char s)))
    (unless (eq ch :eof)
      (stream-unread-char s ch))
    ch))

(defmethod stream-listen ((s fundamental-character-input-stream))
  (let* ((ch (stream-read-char-no-hang s)))
    (when (and ch (not (eq ch :eof)))
      (stream-unread-char s ch))
    ch))

(defmethod stream-clear-input ((s fundamental-character-input-stream))
  )

(defmethod stream-read-line ((s fundamental-character-input-stream))
  (generic-read-line s))

(defclass fundamental-character-output-stream (fundamental-output-stream
                                               fundamental-character-stream)
    ())

(defclass fundamental-binary-input-stream (fundamental-input-stream
                                           fundamental-binary-stream)
    ())

(defclass fundamental-binary-output-stream (fundamental-output-stream
                                            fundamental-binary-stream)
    ())


(defmethod stream-read-byte ((s t))
  (report-bad-arg s '(and input-stream fundamental-binary-stream)))

(defmethod stream-write-byte ((s t) b)
  (declare (ignore b))
  (report-bad-arg s '(and output-stream fundamental-binary-stream)))

(defmethod stream-length ((s stream) &optional new)
  (declare (ignore new)))

(defmethod stream-start-line-p ((s fundamental-character-output-stream))
  (eql 0 (stream-line-column s)))

(defmethod stream-terpri ((s fundamental-character-output-stream))
  (stream-write-char s #\Newline))

(defmethod stream-fresh-line ((s fundamental-character-output-stream))
  (unless (stream-start-line-p s)
    (stream-terpri s)
    t))

;;; The bad news is that this doesn't even bother to do the obvious
;;; (calling STREAM-WRITE-STRING with a longish string of spaces.)
;;; The good news is that this method is pretty useless to (format "~T" ...)
;;; anyhow.
(defmethod stream-advance-to-column ((s fundamental-character-output-stream)
				     col)
  (generic-advance-to-column s col))

(defmethod stream-write-string ((stream fundamental-character-output-stream) string &optional (start 0) end)
  (generic-stream-write-string stream string start end))

(defmethod stream-write-list ((stream fundamental-character-output-stream)
			      list count)
  (declare (fixnum count))
  (dotimes (i count)
    (stream-write-char stream (pop list))))

(defmethod stream-read-list ((stream fundamental-character-input-stream)
			     list count)
  (generic-character-read-list stream list count))

(defmethod stream-write-list ((stream fundamental-binary-output-stream)
			      list count)
  (declare (fixnum count))
  (dotimes (i count)
    (stream-write-byte stream (pop list))))

(defmethod stream-read-list ((stream fundamental-binary-input-stream)
			     list count)
  (declare (fixnum count))
  (do* ((tail list (cdr tail))
	(i 0 (1+ i)))
       ((= i count) count)
    (declare (fixnum i))
    (let* ((b (stream-read-byte stream)))
      (if (eq b :eof)
	(return i)
	(rplaca tail b)))))

;;; The read-/write-vector methods could be specialized for stream classes
;;; that expose the underlying buffering mechanism.
;;; They can assume that the 'vector' argument is a simple one-dimensional
;;; array and that the 'start' and 'end' arguments are sane.

(defmethod stream-write-vector ((stream fundamental-character-output-stream)
				vector start end)
  (declare (fixnum start end))
  (do* ((i start (1+ i)))
       ((= i end))
    (declare (fixnum i))
    (stream-write-char stream (uvref vector i))))

(defmethod stream-write-vector ((stream fundamental-binary-output-stream)
				vector start end)
  (declare (fixnum start end))
  (do* ((i start (1+ i)))
       ((= i end))
    (declare (fixnum i))
    (stream-write-byte stream (uvref vector i))))

(defmethod stream-read-vector ((stream fundamental-character-input-stream)
			       vector start end)
  (generic-character-read-vector stream vector start end))

(defmethod stream-read-vector ((stream fundamental-binary-input-stream)
			       vector start end)
  (declare (fixnum start end))
  (do* ((i start (1+ i)))
       ((= i end) end)
    (declare (fixnum i))
    (let* ((b (stream-read-byte stream)))
      (if (eq b :eof)
	(return i)
	(setf (uvref vector i) b)))))

;;; Synonym streams.

(defclass synonym-stream (fundamental-stream)
    ((symbol :initarg :symbol :reader synonym-stream-symbol)))

(defmethod print-object ((s synonym-stream) out)
  (print-unreadable-object (s out :type t :identity t)
    (format out "to ~s" (synonym-stream-symbol s))))

(macrolet ((synonym-method (name &rest args)
            (let* ((stream (make-symbol "STREAM")))
              `(defmethod ,name ((,stream synonym-stream) ,@args)
                (,name (symbol-value (synonym-stream-symbol ,stream)) ,@args)))))
           (synonym-method stream-read-char)
           (synonym-method stream-read-byte)
           (synonym-method stream-unread-char c)
           (synonym-method stream-read-char-no-hang)
           (synonym-method stream-peek-char)
           (synonym-method stream-listen)
           (synonym-method stream-eofp)
           (synonym-method stream-clear-input)
           (synonym-method stream-read-line)
           (synonym-method stream-read-list l c)
           (synonym-method stream-read-vector v start end)
           (synonym-method stream-write-char c)
           ;(synonym-method stream-write-string str &optional (start 0) end)
           (synonym-method stream-write-byte b)
           (synonym-method stream-clear-output)
           (synonym-method stream-line-column)
           (synonym-method stream-set-column new)
           (synonym-method stream-advance-to-column new)
           (synonym-method stream-start-line-p)
           (synonym-method stream-fresh-line)
           (synonym-method stream-terpri)
           (synonym-method stream-force-output)
           (synonym-method stream-finish-output)
           (synonym-method stream-write-list l c)
           (synonym-method stream-write-vector v start end)
           (synonym-method stream-element-type)
           (synonym-method input-stream-p)
           (synonym-method output-stream-p)
           (synonym-method interactive-stream-p)
           (synonym-method stream-direction)
	   (synonym-method stream-device direction))


(defmethod stream-write-string ((s synonym-stream) string &optional (start 0) end)
  (stream-write-string (symbol-value (synonym-stream-symbol s)) string start end))

(defmethod stream-length ((s synonym-stream) &optional new)
  (stream-length (symbol-value (synonym-stream-symbol s)) new))

(defmethod stream-position ((s synonym-stream) &optional new)
  (stream-position (symbol-value (synonym-stream-symbol s)) new))

(defun make-synonym-stream (symbol)
  (make-instance 'synonym-stream :symbol (require-type symbol 'symbol)))


;;; Two-way streams.
(defclass two-way-stream (fundamental-input-stream fundamental-output-stream)
    ((input-stream :initarg :input-stream :accessor two-way-stream-input-stream)
     (output-stream :initarg :output-stream :accessor two-way-stream-output-stream)))

(defmethod print-object ((s two-way-stream) out)
  (print-unreadable-object (s out :type t :identity t)
    (format out "input ~s, output ~s" 
            (two-way-stream-input-stream s)
            (two-way-stream-output-stream s))))

(macrolet ((two-way-input-method (name &rest args)
             (let* ((stream (make-symbol "STREAM")))
               `(defmethod ,name ((,stream two-way-stream) ,@args)
                 (,name (two-way-stream-input-stream ,stream) ,@args))))
           (two-way-output-method (name &rest args)
             (let* ((stream (make-symbol "STREAM")))
               `(defmethod ,name ((,stream two-way-stream) ,@args)
                 (,name (two-way-stream-output-stream ,stream) ,@args)))))
  (two-way-input-method stream-read-char)
  (two-way-input-method stream-read-byte)
  (two-way-input-method stream-unread-char c)
  (two-way-input-method stream-read-char-no-hang)
  (two-way-input-method stream-peek-char)
  (two-way-input-method stream-listen)
  (two-way-input-method stream-eofp)
  (two-way-input-method stream-clear-input)
  (two-way-input-method stream-read-line)
  (two-way-input-method stream-read-list l c)
  (two-way-input-method stream-read-vector v start end)
  (two-way-output-method stream-write-char c)
  (two-way-output-method stream-write-byte b)
  (two-way-output-method stream-clear-output)
  (two-way-output-method stream-line-column)
  (two-way-output-method stream-set-column new)
  (two-way-output-method stream-advance-to-column new)
  (two-way-output-method stream-start-line-p)
  (two-way-output-method stream-fresh-line)
  (two-way-output-method stream-terpri)
  (two-way-output-method stream-force-output)
  (two-way-output-method stream-finish-output)
  (two-way-output-method stream-write-list l c)
  (two-way-output-method stream-write-vector v start end))

(defmethod stream-device ((s two-way-stream) direction)
  (case direction
    (:input (stream-device (two-way-stream-input-stream s) direction))
    (:output (stream-device (two-way-stream-output-stream s) direction))))
    
(defmethod stream-write-string ((s two-way-stream) string &optional (start 0) end)
  (stream-write-string (two-way-stream-output-stream s) string start end))

(defmethod stream-element-type ((s two-way-stream))
  (let* ((in-type (stream-element-type (two-way-stream-input-stream s)))
         (out-type (stream-element-type (two-way-stream-output-stream s))))
    (if (equal in-type out-type)
      in-type
      `(and ,in-type ,out-type))))

(defun make-two-way-stream (in out)
  "Return a bidirectional stream which gets its input from INPUT-STREAM and
   sends its output to OUTPUT-STREAM."
  (unless (input-stream-p in)
    (require-type in 'input-stream))
  (unless (output-stream-p out)
    (require-type out 'output-stream))
  (make-instance 'two-way-stream :input-stream in :output-stream out))

;;; This is intended for use with things like *TERMINAL-IO*, where the
;;; OS echoes interactive input.  Whenever we read a character from
;;; the underlying input-stream of such a stream, we need to update
;;; our notion of the underlying output-stream's STREAM-LINE-COLUMN.

(defclass echoing-two-way-stream (two-way-stream)
    ())

(defmethod stream-read-char ((s echoing-two-way-stream))
  (let* ((out (two-way-stream-output-stream s))
         (in (two-way-stream-input-stream s)))
    (force-output out)
    (let* ((ch (stream-read-char in)))
      (unless (eq ch :eof)
        (if (eq ch #\newline)
          (stream-set-column out 0)
          (let* ((cur (stream-line-column out)))
            (when cur
              (stream-set-column out (1+ (the fixnum cur)))))))
      ch)))

(defun make-echoing-two-way-stream (in out)
  (make-instance 'echoing-two-way-stream :input-stream in :output-stream out))

;;;echo streams

(defclass echo-stream (two-way-stream)
    ((did-untyi :initform nil)))

(defmethod echo-stream-input-stream ((s echo-stream))
  (two-way-stream-input-stream s))

(defmethod echo-stream-output-stream ((s echo-stream))
  (two-way-stream-output-stream s))

(defmethod stream-read-char ((s echo-stream))
  (let* ((char (stream-read-char (echo-stream-input-stream s))))
    (unless (eq char :eof)
      (if (slot-value s 'did-untyi)
        (setf (slot-value s 'did-untyi) nil)
        (stream-write-char (echo-stream-output-stream s) char)))
    char))

(defmethod stream-unread-char ((s echo-stream) c)
  (call-next-method s c)
  (setf (slot-value s 'did-untyi) c))

(defmethod stream-read-char-no-hang ((s echo-stream))
  (let* ((char (stream-read-char-no-hang (echo-stream-input-stream s))))
    (unless (eq char :eof)
      (if (slot-value s 'did-untyi)
        (setf (slot-value s 'did-untyi) nil)
        (stream-write-char (echo-stream-output-stream s) char)))
    char))

(defmethod stream-clear-input ((s echo-stream))
  (call-next-method)
  (setf (slot-value s 'did-untyi) nil))

(defmethod stream-read-byte ((s echo-stream))
  (let* ((byte (stream-read-byte (echo-stream-input-stream s))))
    (unless (eq byte :eof)
      (stream-write-byte (echo-stream-output-stream s) byte))
    byte))

(defmethod stream-read-line ((s echo-stream))
  (generic-read-line s))

(defmethod stream-read-vector ((s echo-stream) vector start end)
  (if (subtypep (stream-element-type s) 'character)
      (generic-character-read-vector s vector start end)
    (generic-binary-read-vector s vector start end)))

(defun make-echo-stream (input-stream output-stream)
  "Return a bidirectional stream which gets its input from INPUT-STREAM and
   sends its output to OUTPUT-STREAM. In addition, all input is echoed to
   the output stream."
  (make-instance 'echo-stream
                 :input-stream input-stream
                 :output-stream output-stream))

;;;concatenated-streams

(defclass concatenated-stream (fundamental-input-stream)
    ((stream :initarg :streams :accessor concatenated-stream-streams)))

(defun concatenated-stream-current-input-stream (s)
  (car (concatenated-stream-streams s)))

(defun concatenated-stream-next-input-stream (s)
  (setf (concatenated-stream-streams s)
	(cdr (concatenated-stream-streams s)))
  (concatenated-stream-current-input-stream s))

(defmethod stream-element-type ((s concatenated-stream))
  (let* ((c (concatenated-stream-current-input-stream s)))
    (if c
      (stream-element-type c)
      nil)))



(defmethod stream-read-char ((s concatenated-stream))
  (do* ((c (concatenated-stream-current-input-stream s)
	   (concatenated-stream-next-input-stream s)))
       ((null c) :eof)
    (let* ((ch (stream-read-char c)))
      (unless (eq ch :eof)
	(return ch)))))

(defmethod stream-read-char-no-hang ((s concatenated-stream))
  (do* ((c (concatenated-stream-current-input-stream s)
	   (concatenated-stream-next-input-stream s)))
       ((null c) :eof)
    (let* ((ch (stream-read-char-no-hang c)))
      (unless (eq ch :eof)
	(return ch)))))

(defmethod stream-read-byte ((s concatenated-stream))
  (do* ((c (concatenated-stream-current-input-stream s)
	   (concatenated-stream-next-input-stream s)))
       ((null c) :eof)
    (let* ((b (stream-read-byte c)))
      (unless (eq b :eof)
	(return b)))))

(defmethod stream-peek-char ((s concatenated-stream))
  (do* ((c (concatenated-stream-current-input-stream s)
       (concatenated-stream-next-input-stream s)))
       ((null c) :eof)
    (let* ((ch (stream-peek-char c)))
      (unless (eq ch :eof)
        (return ch)))))

(defmethod stream-read-line ((s concatenated-stream))
  (generic-read-line s))

(defmethod stream-read-list ((s concatenated-stream) list count)
  (generic-character-read-list s list count))

(defmethod stream-read-vector ((s concatenated-stream) vector start end)
  (if (subtypep (stream-element-type s) 'character)
      (generic-character-read-vector s vector start end)
    (generic-binary-read-vector s vector start end)))

(defmethod stream-unread-char ((s concatenated-stream) char)
  (let* ((c (concatenated-stream-current-input-stream s)))
    (if c
      (stream-unread-char c char))))

(defmethod stream-listen ((s concatenated-stream))
  (do* ((c (concatenated-stream-current-input-stream s)
	   (concatenated-stream-next-input-stream s)))
       ((null c))
    (when (stream-listen c)
      (return t))))

(defmethod stream-eofp ((s concatenated-stream))
  (do* ((c (concatenated-stream-current-input-stream s)
	   (concatenated-stream-next-input-stream s)))
       ((null c) t)
    (when (stream-listen c)
      (return nil))))

(defmethod stream-clear-input ((s concatenated-stream))
  (let* ((c (concatenated-stream-current-input-stream s)))
    (when c (stream-clear-input c))))


(defun make-concatenated-stream (&rest streams)
  "Return a stream which takes its input from each of the streams in turn,
   going on to the next at EOF."
  (dolist (s streams (make-instance 'concatenated-stream :streams streams))
    (unless (input-stream-p s)
      (error "~S is not an input stream" s))))

;;;broadcast-streams



(defclass broadcast-stream (fundamental-output-stream)
    ((streams :initarg :streams :reader broadcast-stream-streams)))

(macrolet ((broadcast-method
	       (op (stream &rest others )
                   &optional
                   (args (cons stream others)))
	     (let* ((sub (gensym))
		    (result (gensym)))
               `(defmethod ,op ((,stream broadcast-stream) ,@others)
		 (let* ((,result nil))
		   (dolist (,sub (broadcast-stream-streams ,stream) ,result)
			     (setq ,result (,op ,@(cons sub (cdr args))))))))))
	     (broadcast-method stream-write-char (s c))
	     (broadcast-method stream-write-string
				      (s str &optional (start 0) end)
				      (s str start end))
	     (broadcast-method stream-write-byte (s b))
	     (broadcast-method stream-clear-output (s))
	     (broadcast-method stream-line-column (s))
	     (broadcast-method stream-set-column (s new))
	     (broadcast-method stream-advance-to-column (s new))
	     (broadcast-method stream-start-line-p (s))
	     (broadcast-method stream-terpri (s))
	     (broadcast-method stream-force-output (s))
	     (broadcast-method stream-finish-output (s))
	     (broadcast-method stream-stream-write-list (s l c))
	     (broadcast-method stream-write-vector (s v start end)))

(defun last-broadcast-stream (s)
  (car (last (broadcast-stream-streams s))))

(defmethod stream-fresh-line ((s broadcast-stream))
  (let* ((did-output-newline nil))
    (dolist (sub (broadcast-stream-streams s) did-output-newline)
      (setq did-output-newline (stream-fresh-line sub)))))

(defmethod stream-element-type ((s broadcast-stream))
  (let* ((last (last-broadcast-stream s)))
    (if last
      (stream-element-type last)
      t)))

(defmethod stream-length ((s broadcast-stream) &optional new)
  (unless new
    (let* ((last (last-broadcast-stream s)))
      (if last
	(stream-length last)
	0))))

(defmethod stream-position ((s broadcast-stream) &optional new)
  (unless new
    (let* ((last (last-broadcast-stream s)))
      (if last
	(stream-position last)
	0))))

(defun make-broadcast-stream (&rest streams)
  (dolist (s streams (make-instance 'broadcast-stream :streams streams))
    (unless (output-stream-p s)
      (error "~s is not an output stream." s))))



;;; String streams.
(defclass string-stream (fundamental-character-stream)
    ((string :initarg :string :initform nil :reader %string-stream-string)))

(defmethod string-stream-string ((s string-stream))
  (or (%string-stream-string s)
      (error "~s is closed" s)))

(defmethod close  ((s string-stream) &key abort)
  (declare (ignore abort))
  (when (slot-value s 'string)
    (setf (slot-value s 'string) nil)
    (call-next-method)
    t))

(defmethod print-object ((s string-stream) out)
  (print-unreadable-object (s out :type t :identity t)
    (let* ((closed (slot-value s 'closed)))
      (when closed (format out "~s" closed)))))

(defclass string-output-stream (string-stream fundamental-character-output-stream)
    ((column :initform 0 :accessor %stream-column)))

(defmethod stream-write-char ((s string-output-stream) c)
  (if (eq c #\newline)
    (setf (%stream-column s) 0)
    (incf (%stream-column s)))
  (vector-push-extend c (string-stream-string s)))

(defmethod stream-position ((s string-output-stream) &optional newpos)
  (let* ((string (string-stream-string s)))
    (if newpos
      (setf (fill-pointer string) newpos)
      (fill-pointer string))))

;;; If the stream's string is adjustable, it doesn't really have a meaningful
;;; "maximum size".
(defmethod stream-length ((s string-output-stream) &optional newlen)
  (unless newlen
    (array-total-size (string-stream-string s))))

(defmethod stream-line-column ((s string-output-stream))
  (%stream-column s))

(defmethod stream-set-column ((s string-output-stream) new)
  (setf (%stream-column s) new))

(defun %make-string-output-stream (string)
  (unless (and (typep string 'string)
               (array-has-fill-pointer-p string))
    (error "~S must be a string with a fill pointer."))
  (make-instance 'string-output-stream :string  string))

(defun make-string-output-stream (&key (element-type 'character element-type-p))
  "Return an output stream which will accumulate all output given it for
   the benefit of the function GET-OUTPUT-STREAM-STRING."
  (when (and element-type-p
             (not (member element-type '(base-character character
                                         standard-char))))
    (unless (subtypep element-type 'character)
      (error "~S argument ~S is not a subtype of ~S."
             :element-type element-type 'character)))
  (make-instance 'string-output-stream
                 :string (make-array 10 :element-type 'base-char
                                     :fill-pointer 0
                                     :adjustable t)))

;;;"Bounded" string output streams.
(defclass truncating-string-stream (string-output-stream)
    ((truncated :initform nil)))

(defun make-truncating-string-stream (len)
  (make-instance 'truncating-string-stream
		 :string (make-array len
				     :element-type 'character
				     :fill-pointer 0
				     :adjustable nil)))

(defmethod stream-write-char ((s truncating-string-stream) char)
  (or (vector-push char (string-stream-string s))
      (setf (slot-value s 'truncated) t))
  char)

(defmethod stream-write-string ((stream truncating-string-stream)
				string &optional (start 0) end)
  (setq end (check-sequence-bounds string start end))
  (locally (declare (fixnum start end))
    (multiple-value-bind (vect offset) (array-data-and-offset string)
      (declare (fixnum offset))
      (unless (zerop offset)
	(incf start offset)
	(incf end offset))
      (do* ((v (string-stream-string stream))
	    (i start (1+ i)))
	   ((= i end) string)
	(declare (fixnum i))
	(if (slot-value stream 'truncated)
	  (return string)
	  (or (vector-push (schar vect i) v)
	      (progn
		(setf (slot-value stream 'truncated) t)
		(return string))))))))

;;;One way to indent on newlines:

(defclass indenting-string-output-stream (string-output-stream)
    ((prefixchar :initform nil :initarg :prefixchar)
     (indent :initform nil :initarg :indent :accessor indenting-string-output-stream-indent)))

(defun make-indenting-string-output-stream (prefixchar indent)
  (make-instance 'indenting-string-output-stream
   :string (make-array 10
		     :element-type 'character
		     :fill-pointer 0
		     :adjustable t)
   :prefixchar prefixchar
   :indent indent))

(defmethod stream-write-char ((s indenting-string-output-stream) c)
  (call-next-method)
  (when (eq c #\newline)
    (let* ((indent (slot-value s 'indent))
           (prefixchar (slot-value s 'prefixchar))
           (prefixlen 0))
      (when prefixchar
        (if (typep prefixchar 'character)
          (progn
            (setq prefixlen 1)
            (call-next-method s prefixchar))
          (dotimes (i (setq prefixlen (length prefixchar)))
            (call-next-method s (schar prefixchar i)))))
      (when indent
        (dotimes (i (the fixnum (- indent prefixlen)))
          (call-next-method s #\Space)))))
  c)

(defun get-output-stream-string (s)
  (unless (typep s 'string-output-stream)
    (report-bad-arg s 'string-output-stream))
  (let* ((string (string-stream-string s)))
    (prog1 (coerce string 'simple-string)
      (setf (fill-pointer string) 0))))

;;; String input streams.
(defclass string-input-stream (string-stream fundamental-character-input-stream)
    ((start :initform 0 :initarg :start :accessor string-input-stream-start)
     (index :initarg :index :accessor string-input-stream-index)
     (end :initarg :end :accessor string-input-stream-end)))

(defmethod stream-read-char ((s string-input-stream))
  (let* ((string (string-stream-string s))
         (idx (string-input-stream-index s))
         (end (string-input-stream-end s)))
    (declare (fixnum idx end))
    (if (< idx end)
      (prog1 (char string idx) (setf (string-input-stream-index s) (1+ idx)))
      :eof)))

(defmethod stream-peek-char ((s string-input-stream))
  (let* ((string (string-stream-string s))
         (idx (string-input-stream-index s))
         (end (string-input-stream-end s)))
    (declare (fixnum idx end))
    (if (< idx end)
      (char string idx)
      :eof)))

(defmethod stream-unread-char ((s string-input-stream) c)
  (let* ((data (string-stream-string s))
	 (idx (string-input-stream-index s))
	 (start (string-input-stream-start s)))
    (declare (fixnum idx start))
    (unless (> idx start)
      (error "Nothing has been read from ~s yet." s))
    (decf idx)
    (unless (eq c (char data idx))
      (error "~a was not the last character read from ~s" c s))
    (setf (string-input-stream-index s) idx)
    c))



(defmethod stream-eofp ((s string-input-stream))
  (let* ((idx (string-input-stream-index s))
	 (end (string-input-stream-end s)))
    (declare (fixnum idx end))
    (>= idx end)))

(defmethod stream-listen ((s string-input-stream))
  (let* ((idx (string-input-stream-index s))
	 (end (string-input-stream-end s)))
    (declare (fixnum idx end))
    (< idx end)))

(defmethod stream-clear-input ((s string-input-stream))
  (setf (string-input-stream-index s)
	(string-input-stream-start s))
  nil)

(defmethod stream-position ((s string-input-stream) &optional newpos)
  (let* ((start (string-input-stream-start s))
	 (end (string-input-stream-end s))
	 (len (- end start)))
    (declare (fixnum start end len))
    (if newpos
      (if (and (>= newpos 0) (<= newpos len))
	(setf (string-input-stream-index s) (+ start newpos)))
      (- (string-input-stream-index s) start))))

(defmethod stream-length ((s string-input-stream) &optional newlen)
  (unless newlen
    (- (string-input-stream-end s) (string-input-stream-start s))))

(defun make-string-input-stream (string &optional (start 0)
                                        (end nil))
  "Return an input stream which will supply the characters of STRING between
  START and END in order."
  (setq end (check-sequence-bounds string start end))
  (make-instance 'string-input-stream
		 :string string
		 :start start
		 :index start
		 :end end))


;;; A mixin to be used with FUNDAMENTAL-STREAMs that want to use ioblocks
;;; to buffer I/O.

(defclass buffered-stream-mixin ()
  ((ioblock :reader %stream-ioblock :writer (setf stream-ioblock) :initform nil)
   (element-type :initarg :element-type :reader %buffered-stream-element-type)))

(defun stream-ioblock (stream &optional (error-if-nil t))
  (or (%stream-ioblock stream)
      (when error-if-nil
        (error "~s is closed" stream))))

(defmethod stream-device ((s buffered-stream-mixin) direction)
  (declare (ignore direction))
  (let* ((ioblock (stream-ioblock s nil)))
    (and ioblock (ioblock-device ioblock))))
  
(defmethod stream-element-type ((s buffered-stream-mixin))
  (%buffered-stream-element-type s))

(defmethod stream-create-ioblock ((stream buffered-stream-mixin) &rest args &key)
  (declare (dynamic-extent args))
  (apply #'make-ioblock :stream stream args))

(defclass buffered-input-stream-mixin
          (buffered-stream-mixin fundamental-input-stream)
  ())

(defclass buffered-output-stream-mixin
          (buffered-stream-mixin fundamental-output-stream)
  ())

(defclass buffered-io-stream-mixin
          (buffered-input-stream-mixin buffered-output-stream-mixin)
  ())

(defclass buffered-character-input-stream-mixin
          (buffered-input-stream-mixin fundamental-character-input-stream)
  ())

(defclass buffered-character-output-stream-mixin
          (buffered-output-stream-mixin fundamental-character-output-stream)
  ())

(defclass buffered-character-io-stream-mixin
          (buffered-character-input-stream-mixin buffered-character-output-stream-mixin)
  ())

(defclass buffered-binary-input-stream-mixin
          (buffered-input-stream-mixin fundamental-binary-input-stream)
  ())

(defclass buffered-binary-output-stream-mixin
          (buffered-output-stream-mixin fundamental-binary-output-stream)
  ())

(defclass buffered-binary-io-stream-mixin
          (buffered-binary-input-stream-mixin
           buffered-binary-output-stream-mixin)
  ())

(defmethod close :after ((stream buffered-stream-mixin) &key abort)
  (declare (ignore abort))
  (let* ((ioblock (stream-ioblock stream nil)))
    (when ioblock
      (%ioblock-close ioblock))))

(defmethod close :before ((stream buffered-output-stream-mixin) &key abort)
  (unless abort
    (when (open-stream-p stream)
      (stream-force-output stream))))

(defmethod interactive-stream-p ((stream buffered-stream-mixin))
  (let* ((ioblock (stream-ioblock stream nil)))
    (and ioblock (ioblock-interactive ioblock))))


#|
(defgeneric ioblock-advance (stream ioblock readp)
  (:documentation
   "Called when the current input buffer is empty (or non-existent).
    readp true means the caller expects to return a byte now.
    Return value is meaningless unless readp is true, in which case
    it means that there is input ready"))

(defgeneric ioblock-listen (stream ioblock)
  (:documentation
   "Called in response to stream-listen when the current
    input buffer is empty.
    Returns a boolean"))

(defgeneric ioblock-eofp (stream ioblock)
  (:documentation
   "Called in response to stream-eofp when the input buffer is empty.
    Returns a boolean."))

(defgeneric ioblock-force-output (stream ioblock count finish-p)
  (:documentation
   "Called in response to stream-force-output.
    Write count bytes from ioblock-outbuf.
    Finish the I/O if finish-p is true."))

(defgeneric ioblock-close (stream ioblock)
  (:documentation
   "May free some resources associated with the ioblock."))
|#

(defmethod ioblock-close ((stream buffered-stream-mixin) ioblock)
  (declare (ignore ioblock)))

(defmethod ioblock-force-output ((stream buffered-output-stream-mixin)
                                   ioblock
                                   count
                                   finish-p)
  (declare (ignore ioblock count finish-p)))



(defmacro with-stream-ioblock-input ((ioblock stream &key
                                             speedy)
                                  &body body)
  `(let ((,ioblock (stream-ioblock ,stream)))
     ,@(when speedy `((declare (optimize (speed 3) (safety 0)))))
     (with-ioblock-input-locked (,ioblock) ,@body)))

(defmacro with-stream-ioblock-output ((ioblock stream &key
                                             speedy)
                                  &body body)
  `(let ((,ioblock (stream-ioblock ,stream)))
     ,@(when speedy `((declare (optimize (speed 3) (safety 0)))))
     (with-ioblock-output-locked (,ioblock) ,@body)))

(defmacro with-stream-ioblock-output-maybe ((ioblock stream &key
						     speedy)
					    &body body)
  `(let ((,ioblock (stream-ioblock ,stream)))
    ,@(when speedy `((declare (optimize (speed 3) (safety 0)))))
    (with-ioblock-output-locked-maybe (,ioblock) ,@body)))

(defmethod stream-read-char ((stream buffered-character-input-stream-mixin))
  (with-stream-ioblock-input (ioblock stream :speedy t)
    (%ioblock-tyi ioblock)))

(defmethod stream-read-char-no-hang ((stream buffered-character-input-stream-mixin))
  (with-stream-ioblock-input (ioblock stream :speedy t)
    (%ioblock-tyi ioblock nil)))

(defmethod stream-peek-char ((stream buffered-character-input-stream-mixin))
  (with-stream-ioblock-input (ioblock stream :speedy t)
    (%ioblock-peek-char ioblock)))

(defmethod stream-clear-input ((stream buffered-input-stream-mixin))
  (with-stream-ioblock-input (ioblock stream :speedy t)
    (%ioblock-clear-input ioblock)))

(defmethod stream-unread-char ((stream buffered-character-input-stream-mixin) char)
  (with-stream-ioblock-input (ioblock stream :speedy t)
    (%ioblock-untyi ioblock char))
  char)

(defmethod stream-read-byte ((stream buffered-binary-input-stream-mixin))
  (with-stream-ioblock-input (ioblock stream :speedy t)
    (%ioblock-read-byte ioblock)))

(defmethod stream-eofp ((stream buffered-input-stream-mixin))
  (with-stream-ioblock-input (ioblock stream :speedy t)
    (%ioblock-eofp ioblock)))

(defmethod stream-listen ((stream buffered-input-stream-mixin))
  (with-stream-ioblock-input (ioblock stream :speedy t)
    (%ioblock-listen ioblock)))

(defun flush-ioblock (ioblock finish-p)
  (with-ioblock-output-locked (ioblock)
    (%ioblock-force-output ioblock finish-p)))

(defmethod stream-write-byte ((stream buffered-binary-output-stream-mixin)
                              byte)
  (with-stream-ioblock-output (ioblock stream :speedy t)
    (%ioblock-write-byte ioblock byte)))

(defmethod stream-write-char ((stream buffered-character-output-stream-mixin) char)
  (with-stream-ioblock-output (ioblock stream :speedy t)
    (%ioblock-write-char ioblock char)))

(defmethod stream-clear-output ((stream buffered-output-stream-mixin))
  (with-stream-ioblock-output (ioblock stream :speedy t)
    (%ioblock-clear-output ioblock))
  nil)

(defmethod stream-line-column ((stream buffered-character-output-stream-mixin))
  (let* ((ioblock (stream-ioblock stream nil)))
    (and ioblock (ioblock-charpos ioblock))))

(defmethod stream-set-column ((stream buffered-character-output-stream-mixin)
                              new)
  (let* ((ioblock (stream-ioblock stream nil)))
    (and ioblock (setf (ioblock-charpos ioblock) new))))

(defmethod stream-force-output ((stream buffered-output-stream-mixin))
  (with-stream-ioblock-output (ioblock stream :speedy t)
    (%ioblock-force-output ioblock nil)
    nil))

(defmethod maybe-stream-force-output ((stream buffered-output-stream-mixin))
  (with-stream-ioblock-output-maybe (ioblock stream :speedy t)
    (%ioblock-force-output ioblock nil)
    nil))

(defmethod stream-finish-output ((stream buffered-output-stream-mixin))
  (with-stream-ioblock-output (ioblock stream :speedy t)
    (%ioblock-force-output ioblock t)
    nil))

(defmethod stream-write-string ((stream buffered-character-output-stream-mixin)
				string &optional (start 0 start-p) end)
				
  (with-stream-ioblock-output (ioblock stream :speedy t)
    (if (and (typep string 'simple-string)
	     (not start-p))
      (%ioblock-write-simple-string ioblock string 0 (length string))
      (progn
	(setq end (check-sequence-bounds string start end))
	(locally (declare (fixnum start end))
	  (multiple-value-bind (arr offset)
	      (if (typep string 'simple-string)
		(values string 0)
		(array-data-and-offset (require-type string 'string)))
	    (unless (eql 0 offset)
	      (incf start offset)
	      (incf end offset))
	    (%ioblock-write-simple-string ioblock arr start (the fixnum (- end start)))))))))


(defmethod stream-write-ivector ((s buffered-output-stream-mixin)
				 iv start length)
  (with-stream-ioblock-output (ioblock s :speedy t)
    (%ioblock-out-ivect ioblock iv start length)))

(defmethod stream-read-ivector ((s buffered-character-input-stream-mixin)
				iv start nb)
  (with-stream-ioblock-input (ioblock s :speedy t)
    (%ioblock-character-in-ivect ioblock iv start nb)))

(defmethod stream-read-ivector ((s buffered-binary-input-stream-mixin)
				iv start nb)
  (with-stream-ioblock-input (ioblock s :speedy t)
    (%ioblock-binary-in-ivect ioblock iv start nb)))

(defmethod stream-write-vector ((stream buffered-character-output-stream-mixin)
				vector start end)
  (declare (fixnum start end))
  (if (not (typep vector 'simple-base-string))
    (call-next-method)
    (with-stream-ioblock-output (ioblock stream :speedy t)
      (let* ((total (- end start)))
	(declare (fixnum total))
	(%ioblock-out-ivect ioblock vector start total)
	(let* ((last-newline (position #\newline vector
				       :start start
				       :end end
				       :from-end t)))
	  (if last-newline
	    (setf (ioblock-charpos ioblock)
		  (- end last-newline 1))
	    (incf (ioblock-charpos ioblock) total)))))))

(defmethod stream-write-vector ((stream buffered-binary-output-stream-mixin)
				vector start end)
  (declare (fixnum start end))
  (with-stream-ioblock-output (ioblock stream :speedy t)
    (let* ((out (ioblock-outbuf ioblock))
	   (buf (io-buffer-buffer out))
	   (written 0)
	   (limit (io-buffer-limit out))
	   (total (- end start))
	   (buftype (typecode buf)))
      (declare (fixnum buftype written total limit))
      (if (not (= (the fixnum (typecode vector)) buftype))
	(do* ((i start (1+ i)))
	     ((= i end))
	  (let ((byte (uvref vector i)))
	    (when (characterp byte)
	      (setq byte (char-code byte)))
	    (%ioblock-write-byte ioblock byte)))
	(do* ((pos start (+ pos written))
	      (left total (- left written)))
	     ((= left 0))
	  (declare (fixnum pos left))
	  (setf (ioblock-dirty ioblock) t)
	  (let* ((index (io-buffer-idx out))
		 (count (io-buffer-count out))
		 (avail (- limit index)))
	    (declare (fixnum index avail count))
	    (cond
	      ((= (setq written avail) 0)
	       (%ioblock-force-output ioblock nil))
	      (t
	       (if (> written left)
		 (setq written left))
	       (%copy-ivector-to-ivector
		vector
		(ioblock-elements-to-octets ioblock pos)
		buf
		(ioblock-elements-to-octets ioblock index)
		(ioblock-elements-to-octets ioblock written))
	       (setf (ioblock-dirty ioblock) t)
	       (incf index written)
	       (if (> index count)
		 (setf (io-buffer-count out) index))
	       (setf (io-buffer-idx out) index)
	       (if (= index  limit)
		 (%ioblock-force-output ioblock nil))))))))))

(defmethod stream-read-vector ((stream buffered-character-input-stream-mixin)
			       vector start end)
  (declare (fixnum start end))
  (if (not (typep vector 'simple-base-string))
    (call-next-method)
    (with-stream-ioblock-input (ioblock stream :speedy t)
      (%ioblock-character-read-vector ioblock vector start end))))

(defmethod stream-read-vector ((stream buffered-binary-input-stream-mixin)
			       vector start end)
  (declare (fixnum start end))
  (if (typep vector 'simple-base-string)
    (call-next-method)
    (with-stream-ioblock-input (ioblock stream :speedy t)
      (%ioblock-binary-read-vector ioblock vector start end))))

(defloadvar *fd-set-size*
    (ff-call (%kernel-import ppc32::kernel-import-fd-setsize-bytes)
             :unsigned-fullword))

(defun unread-data-available-p (fd)
  (%stack-block ((arg 4))
    (setf (%get-long arg) 0)
    (when (zerop (syscall syscalls::ioctl fd #$FIONREAD arg))
      (let* ((avail (%get-long arg)))
	(and (> avail 0) avail)))))

;;; Read and discard any available unread input.
(defun %fd-drain-input (fd)
  (%stack-block ((buf 1024))
    (do* ((avail (unread-data-available-p fd) (unread-data-available-p fd)))
	 ((or (null avail) (eql avail 0)))
      (do* ((max (min avail 1024) (min avail 1024)))
	   ((zerop avail))
	(let* ((count (fd-read fd buf max)))
	  (if (< count 0)
	    (return)
	    (decf avail count)))))))

(defun fd-zero (fdset)
  (ff-call (%kernel-import ppc32::kernel-import-do-fd-zero)
           :address fdset
           :void))

(defun fd-set (fd fdset)
  (ff-call (%kernel-import ppc32::kernel-import-do-fd-set)
           :unsigned-fullword fd
           :address fdset
           :void))

(defun fd-clr (fd fdset)
  (ff-call (%kernel-import ppc32::kernel-import-do-fd-clr)
           :unsigned-fullword fd
           :address fdset
           :void))

(defun fd-is-set (fd fdset)
  (not (= 0 (the fixnum (ff-call (%kernel-import ppc32::kernel-import-do-fd-is-set)
                                 :unsigned-fullword fd
                                 :address fdset
                                 :unsigned-fullword)))))

(defun process-input-wait (fd &optional ticks)
  (let* ((wait-end (if ticks (+ (get-tick-count) ticks))))
    (loop
      (when (fd-input-available-p fd 0)
        (return t))
      (let* ((now (get-tick-count)))
        (if (and wait-end (>= now wait-end))
          (return))
        (fd-input-available-p fd (if ticks (- wait-end now)))))))



(defun process-output-wait (fd)
  (loop
    (when (fd-ready-for-output-p fd 0)
      (return t))
    (process-wait "output-wait" #'fd-ready-for-output-p fd *ticks-per-second*)))


  
;; Use this when it's possible that the fd might be in
;; a non-blocking state.  Body must return a negative of
;; the os error number on failure.
;; The use of READ-FROM-STRING below is certainly ugly, but macros
;; that expand into reader-macros don't generally trigger the reader-macro's
;; side-effects.  (Besides, the reader-macro might return a different
;; value when the macro function is expanded than it did when the macro
;; function was defined; this can happen during cross-compilation.)
(defmacro with-eagain (fd direction &body body)
  (let* ((res (gensym))
	 (eagain (symbol-value (read-from-string "#$EAGAIN"))))
   `(loop
      (let ((,res (progn ,@body)))
	(if (eql ,res (- ,eagain))
	  (,(ecase direction
	     (:input 'process-input-wait)
	     (:output 'process-output-wait))
	   ,fd)
	  (return ,res))))))


(defun ticks-to-timeval (ticks tv)
  (when ticks
    (let* ((total-us (* ticks (/ 1000000 *ticks-per-second*))))
      (multiple-value-bind (seconds us) (floor total-us 1000000)
	(setf (pref tv :timeval.tv_sec) seconds
	      (pref tv :timeval.tv_usec) us)))))

(defun fd-input-available-p (fd &optional ticks)
  (rletZ ((tv :timeval))
    (ticks-to-timeval ticks tv)
    (%stack-block ((infds *fd-set-size*)
		   (errfds *fd-set-size*))
      (fd-zero infds)
      (fd-zero errfds)
      (fd-set fd infds)
      (fd-set fd errfds)
      (let* ((res (syscall syscalls::select (1+ fd) infds (%null-ptr) errfds
                           (if ticks tv (%null-ptr)))))
        (> res 0)))))

(defun fd-ready-for-output-p (fd &optional ticks)
  (rletZ ((tv :timeval))
    (ticks-to-timeval ticks tv)
    (%stack-block ((outfds *fd-set-size*)
		   (errfds *fd-set-size*))
      (fd-zero outfds)
      (fd-zero errfds)
      (fd-set fd outfds)
      (fd-set fd errfds)
      (let* ((res (#_select (1+ fd) (%null-ptr) outfds errfds
			    (if ticks tv (%null-ptr)))))
        (> res 0)))))

(defun fd-urgent-data-available-p (fd &optional ticks)
  (rletZ ((tv :timeval))
    (ticks-to-timeval ticks tv)
    (%stack-block ((errfds *fd-set-size*))
      (fd-zero errfds)
      (fd-set fd errfds)
      (let* ((res (#_select (1+ fd) (%null-ptr) (%null-ptr)  errfds
			    (if ticks tv (%null-ptr)))))
        (> res 0)))))

;;; FD-streams, built on top of the ioblock mechanism.
(defclass fd-stream (buffered-stream-mixin fundamental-stream) ())


(defmethod select-stream-advance-function ((s symbol))
  (select-stream-advance-function (find-class s)))

(defmethod select-stream-advance-function ((c class))
  (select-stream-advance-function (class-prototype c)))

(defmethod select-stream-advance-function ((s fd-stream))
  'fd-stream-advance)

(defmethod select-stream-force-output-function ((s symbol))
  (select-stream-force-output-function (find-class s)))

(defmethod select-stream-force-output-function ((c class))
  (select-stream-force-output-function (class-prototype c)))

(defmethod select-stream-force-output-function ((f fd-stream))
  'fd-stream-force-output)

(defmethod print-object ((s fd-stream) out)
  (print-unreadable-object (s out :type t :identity t)
    (let* ((ioblock (stream-ioblock s nil))
           (fd (and ioblock (ioblock-device ioblock))))
      (if fd
        (format out "(~a/~d)" (%unix-fd-kind fd) fd)
        (format out "~s" :closed)))))

(defclass fd-input-stream (fd-stream buffered-input-stream-mixin)
    ())

(defclass fd-output-stream (fd-stream buffered-output-stream-mixin)
    ())

(defclass fd-io-stream (fd-stream buffered-io-stream-mixin)
    ())

(defclass fd-character-input-stream (fd-input-stream
                                     buffered-character-input-stream-mixin)
    ())

(defclass fd-character-output-stream (fd-output-stream
                                      buffered-character-output-stream-mixin)
    ())

(defclass fd-character-io-stream (fd-io-stream
                                  buffered-character-io-stream-mixin)
    ())

(defclass fd-binary-input-stream (fd-input-stream
                                  buffered-binary-input-stream-mixin)
    ())

(defclass fd-binary-output-stream (fd-output-stream
                                   buffered-binary-output-stream-mixin)
    ())

(defclass fd-binary-io-stream (fd-io-stream buffered-binary-io-stream-mixin)
    ())

(defun fd-stream-advance (s ioblock read-p)
  (let* ((fd (ioblock-device ioblock))
         (buf (ioblock-inbuf ioblock))
         (bufptr (io-buffer-bufptr buf))
         (size (io-buffer-size buf)))
    (setf (io-buffer-idx buf) 0
          (io-buffer-count buf) 0
          (ioblock-eof ioblock) nil)
    (let* ((avail nil))
      (when (or read-p (setq avail (stream-listen s)))
        (if (and (ioblock-interactive ioblock)
                 (not avail))
	  (process-input-wait fd))
        (let* ((n (with-eagain fd :input
		    (fd-read fd bufptr size))))
          (declare (fixnum n))
          (if (< n 0)
            (stream-io-error s (- n) "read")
            (if (> n 0)
              (setf (io-buffer-count buf)
		    (ioblock-octets-to-elements ioblock n))
              (progn (setf (ioblock-eof ioblock) t)
                     nil))))))))

(defun fd-stream-eofp (s ioblock)
  (declare (ignore s))
  (ioblock-eof ioblock))
  
(defun fd-stream-listen (s ioblock)
  (declare (ignore s))
  (unread-data-available-p (ioblock-device ioblock)))

(defun fd-stream-close (s ioblock)
  (when (ioblock-dirty ioblock)
    (stream-finish-output s))
  (let* ((fd (ioblock-device ioblock)))
    (when fd
      (setf (ioblock-device ioblock) nil)
      (fd-close fd))))

(defun fd-stream-force-output (s ioblock count finish-p)
  (when (or (ioblock-dirty ioblock) finish-p)
    (setf (ioblock-dirty ioblock) nil)
    (let* ((fd (ioblock-device ioblock))
	   (io-buffer (ioblock-outbuf ioblock))
	   (buf (%null-ptr))
	   (octets-to-write (ioblock-elements-to-octets ioblock count))
	   (octets octets-to-write))
      (declare (fixnum octets))
      (declare (dynamic-extent buf))
      (%setf-macptr buf (io-buffer-bufptr io-buffer))
      (setf (io-buffer-idx io-buffer) 0
	    (io-buffer-count io-buffer) 0)
      (do* ()
	   ((= octets 0)
	    (when finish-p
	      (case (%unix-fd-kind fd)
		(:file (fd-fsync fd))))
	    octets-to-write)
	(let* ((written (with-eagain fd :output
			  (fd-write fd buf octets))))
	  (declare (fixnum written))
	  (if (< written 0)
	    (stream-io-error s (- written) "write"))
	  (decf octets written)
	  (unless (zerop octets)
	    (%incf-ptr buf written)))))))

(defmethod stream-read-line ((s buffered-stream-mixin))
   (with-stream-ioblock-input (ioblock s :speedy t)
     (%ioblock-read-line ioblock)))

(defmethod stream-clear-input ((s fd-input-stream))
  (call-next-method)
  (with-stream-ioblock-input (ioblock s :speedy t)
    (let* ((fd (ioblock-device ioblock)))
      (when fd (%fd-drain-input fd)))))

(defmethod select-stream-class ((class (eql 'fd-stream)) in-p out-p char-p)
  (if char-p
    (if in-p
      (if out-p
	'fd-character-io-stream
	'fd-character-input-stream)
      'fd-character-output-stream)
    (if in-p
      (if out-p
	'fd-binary-io-stream
	'fd-binary-input-stream)
      'fd-character-output-stream)))

(defstruct (input-selection (:include dll-node))
  (package nil :type (or null string package))
  (source-file nil :type (or null string pathname))
  (string-stream nil :type (or null string-input-stream)))

(defstruct (input-selection-queue (:include locked-dll-header)))

(defclass selection-input-stream (fd-character-input-stream)
    ((selections :initform (init-dll-header (make-input-selection-queue))
                 :reader selection-input-stream-selections)
     (current-selection :initform nil
                        :accessor selection-input-stream-current-selection)
     (peer-fd  :reader selection-input-stream-peer-fd)))

(defmethod select-stream-class ((class (eql 'selection-input-stream))
                                in-p out-p char-p)
  (if (and in-p char-p (not out-p))
    'selection-input-stream
    (error "Can't create that type of stream.")))

(defun make-selection-input-stream (fd &key peer-fd (elements-per-buffer *elements-per-buffer*))
  (let* ((s (make-fd-stream fd
                            :elements-per-buffer elements-per-buffer
                            :class 'selection-input-stream)))
    (setf (slot-value s 'peer-fd) peer-fd)
    s))

(defmethod stream-clear-input ((s selection-input-stream))
  (call-next-method)
  (let* ((q (selection-input-stream-selections s)))
    (with-locked-dll-header (q)
      (do* ((first (dll-header-first q) (dll-header-first q)))
           ((eq first q))
        (remove-dll-node first))))
  (setf (selection-input-stream-current-selection s) nil))

(defmethod enqueue-input-selection ((stream selection-input-stream)
                                    (selection input-selection))
  (let* ((q (selection-input-stream-selections stream)))
    (with-locked-dll-header (q)
      (append-dll-node selection q)
      (%stack-block ((buf 1))
        (setf (%get-unsigned-byte buf)
              (logand (char-code #\d) #x1f))
        (fd-write (slot-value stream 'peer-fd)
                  buf
                  1)))))
              


(defresource *string-output-stream-pool*
  :constructor (make-string-output-stream)
  :initializer 'stream-clear-output)

;;;File streams.
(defparameter *use-new-file-streams* t)

(defparameter *default-file-stream-class* 'file-stream)

(defun open (filename &key (direction :input)
                      (element-type 'base-char)
                      (if-exists :error)
                      (if-does-not-exist (cond ((eq direction :probe)
                                                nil)
                                               ((or (eq direction :input)
                                                    (eq if-exists :overwrite)
                                                    (eq if-exists :append))
                                                :error)
                                               (t :create)))
                      (external-format :default)
		      (class *default-file-stream-class*)
                      (elements-per-buffer *elements-per-buffer*))
  "Return a stream which reads from or writes to FILENAME.
  Defined keywords:
   :DIRECTION - one of :INPUT, :OUTPUT, :IO, or :PROBE
   :ELEMENT-TYPE - the type of object to read or write, default BASE-CHAR
   :IF-EXISTS - one of :ERROR, :NEW-VERSION, :RENAME, :RENAME-AND-DELETE,
                       :OVERWRITE, :APPEND, :SUPERSEDE or NIL
   :IF-DOES-NOT-EXIST - one of :ERROR, :CREATE or NIL
  See the manual for details."
  (loop
    (restart-case
      (return
	(make-file-stream filename
			  direction
			  element-type
			  if-exists
			  if-does-not-exist
			  elements-per-buffer
			  class
			  external-format))
      (retry-open ()
                  :report (lambda (stream) (format stream "Retry opening ~s" filename))
                  nil))))





(defun gen-file-name (path)
  (let* ((date (file-write-date path))
         (tem-path (merge-pathnames (make-pathname :name (%integer-to-string date) :type "tem" :defaults nil) path)))
    (loop
      (when (not (probe-file tem-path)) (return tem-path))
      (setf (%pathname-name tem-path) (%integer-to-string (setq date (1+ date)))))))

(defun probe-file-x (path)
  (%probe-file-x (native-translated-namestring path)))

(defun file-length (stream)
  (etypecase stream
    ;; Don't use an OR type here
    (file-stream (stream-length stream))
    (synonym-stream (file-length
		     (symbol-value (synonym-stream-symbol stream))))
    (broadcast-stream (let* ((last (last-broadcast-stream stream)))
			(if last
			  (file-length last)
			  0)))))
  
(defun file-position (stream &optional position)
  (when position
    (if (eq position :start)
      (setq position 0)
      (if (eq position :end)
	(setq position (file-length stream))
	(unless (typep position 'unsigned-byte)
	  (report-bad-arg position '(or
				     null
				     (eql :start)
				     (eql :end)
				     unsigned-byte))))))
  (stream-position stream position))


(defun %request-terminal-input ()
  (let* ((shared-resource
	  (if (typep *terminal-io* 'two-way-stream)
	    (input-stream-shared-resource
	     (two-way-stream-input-stream *terminal-io*)))))
    (if shared-resource (%acquire-shared-resource shared-resource t))))




(defun %%yield-terminal-to (&optional process)
  (let* ((shared-resource
	  (if (typep *terminal-io* 'two-way-stream)
	    (input-stream-shared-resource
	     (two-way-stream-input-stream *terminal-io*)))))
    (when shared-resource (%yield-shared-resource shared-resource process))))

(defun %restore-terminal-input (&optional took-it)
  (let* ((shared-resource
	  (if took-it
	    (if (typep *terminal-io* 'two-way-stream)
	      (input-stream-shared-resource
	       (two-way-stream-input-stream *terminal-io*))))))
    (when shared-resource
      (%release-shared-resource shared-resource))))

;;; Initialize the global streams
; These are defparameters because they replace the ones that were in l1-init
; while bootstrapping.

(defparameter *terminal-io* nil "terminal I/O stream")
(defparameter *debug-io* nil "interactive debugging stream")
(defparameter *query-io* nil "query I/O stream")
(defparameter *error-output* nil "error output stream")
(defparameter *standard-input* nil "default input stream")
(defparameter *standard-output* nil "default output stream")
(defparameter *trace-output* nil "trace output stream")

(proclaim '(stream 
          *query-io* *debug-io* *error-output* *standard-input* 
          *standard-output* *trace-output*))

;;; Interaction with the REPL.  READ-TOPLEVEL-FORM should return 3
;;; values: a form, a (possibly null) pathname, and a boolean that
;;; indicates whether or not the result(s) of evaluating the form
;;; should be printed.  (The last value has to do with how selections
;;; that contain multiple forms are handled; see *VERBOSE-EVAL-SELECTION*
;;; and the SELECTION-INPUT-STREAM method below.)

(defmethod read-toplevel-form ((stream synonym-stream) eof-value)
  (read-toplevel-form (symbol-value (synonym-stream-symbol stream)) eof-value))

(defmethod read-toplevel-form ((stream two-way-stream) eof-value)
  (read-toplevel-form (two-way-stream-input-stream stream) eof-value))

(defmethod read-toplevel-form :after ((stream echoing-two-way-stream) eof-value)
  (declare (ignore eof-value))
  (stream-set-column (two-way-stream-output-stream stream) 0))

(defmethod read-toplevel-form ((stream input-stream)
                               eof-value)
  (loop
    (let* ((*in-read-loop* nil) 
           (form (read stream nil eof-value)))
      (if (eq form eof-value)
        (return (values form nil t))
        (progn
           (let ((ch))                 ;Trim whitespace
            (while (and (listen stream)
                        (setq ch (read-char stream nil nil))
                        (whitespacep cH))
              (setq ch nil))
            (when ch (unread-char ch stream)))
          (when *listener-indent* 
            (write-char #\space stream)
            (write-char #\space stream))
          (return (values (process-single-selection form) nil t)))))))

(defparameter *verbose-eval-selection* nil
  "When true, the results of evaluating all forms in an input selection
are printed.  When false, only the results of evaluating the last form
are printed.")

(defmethod read-toplevel-form ((stream selection-input-stream)
                               eof-value)
  ;; If we don't have a selection, try to get one.  Read from the
  ;; underlying input stream; if that yields an EOF, that -usually-
  ;; means that a selection's been posted.
  (do* ((selection (selection-input-stream-current-selection stream)))
       ()
    (when (null selection)
      (let* ((form (call-next-method)))
        (if (eq form eof-value)
          (setq selection
                (setf (selection-input-stream-current-selection stream)
                      (locked-dll-header-dequeue
                       (selection-input-stream-selections stream))))
          (return (values form nil t)))))
    (if (null selection)
      (return (values eof-value nil t))
      (let* ((*package* *package*)
             (string-stream (input-selection-string-stream selection))
             (selection-package (input-selection-package selection))
             (pkg (if selection-package (pkg-arg selection-package))))
        (when pkg (setq *package* pkg))
        (let* ((form (read-toplevel-form string-stream eof-value))
               (last-form-in-selection (eofp string-stream)))
          (when last-form-in-selection
            (setf (selection-input-stream-current-selection stream) nil))
          (return (values form
                          (input-selection-source-file selection)
                          (or last-form-in-selection *verbose-eval-selection*))))))))

                             
        


; end of L1-streams.lisp
