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

; streams.lisp
;;;General io-functions

(in-package "CCL")

(eval-when (:execute :compile-toplevel)
  (require :level-2)
  (require :streams)
  (require :backquote)

  )






(defun read-line (&optional input-stream (eof-error-p t) eof-value recursive-p)
  (declare (ignore recursive-p))
  (let* ((input-stream (designated-input-stream input-stream)))
    (multiple-value-bind (string eof) (stream-read-line input-stream)
      (if eof
	(if (= (length string) 0)
	  (if eof-error-p
	    (signal-eof-error input-stream)
	    (values eof-value t))
	  (values string t))
	(values string nil)))))

(defun read-char (&optional input-stream (eof-error-p t) eof-value recursive-p)
  (declare (ignore recursive-p)
           (optimize (speed 3) (space 0)))
  (setq input-stream (designated-input-stream input-stream))
  (if (typep input-stream 'basic-stream)
    (let* ((ioblock (basic-stream.state input-stream)))
      (if ioblock
        (check-eof
         (funcall (ioblock-read-char-function ioblock) ioblock)
         input-stream eof-error-p eof-value)
        (stream-is-closed input-stream)))
    (check-eof (stream-read-char input-stream)
               input-stream
               eof-error-p
               eof-value)))

(defun unread-char (char &optional input-stream)
  (let* ((input-stream (designated-input-stream input-stream)))
    (stream-unread-char input-stream char)
    nil))

(defun peek-char (&optional peek-type input-stream
                            (eof-error-p t) eof-value recursive-p)
  (declare (ignore recursive-p))
  (let* ((input-stream (designated-input-stream input-stream)))
    (cond ((null peek-type)
           (check-eof (stream-peek-char input-stream) input-stream eof-error-p eof-value))
          (t
           (do* ((value (stream-peek-char input-stream) (stream-peek-char input-stream)))
                ((eq value :eof)
                 (return (check-eof value input-stream eof-error-p eof-value)))
             (if (eq peek-type t)
               (unless (whitespacep value)
                 (return value))
               (if (characterp peek-type)
                 (if (eql peek-type value)
                   (return value))
                 (report-bad-arg peek-type '(or character (member nil t)))))
             (stream-read-char input-stream))))))

(defun read-char-no-hang (&optional input-stream (eof-error-p t) eof-value recursive-p)
  (declare (ignore recursive-p))
  (setq input-stream (designated-input-stream input-stream))
  (check-eof (stream-read-char-no-hang input-stream) input-stream eof-error-p eof-value))

(defun read-byte (stream &optional (eof-error-p t) eof-value)
  (if (typep stream 'basic-stream)
    (let* ((ioblock (basic-stream.state stream)))
      (if ioblock
        (check-eof (funcall (ioblock-read-byte-function ioblock) ioblock)
                   stream
                   eof-error-p
                   eof-value)
        (stream-is-closed ioblock)))
    (check-eof
     (stream-read-byte stream)
     stream
     eof-error-p
     eof-value)))

;;;;;;;;;;;; OUTPUT STREAMS

(defun clear-output (&optional stream)
  (let* ((stream (real-print-stream stream)))
    (stream-clear-output stream)
    nil))

(defun finish-output (&optional stream)
  (let* ((stream (real-print-stream stream)))
    (stream-finish-output stream)
    nil))



(defun line-length (stream)
  (declare (ignore stream))
  80)

(defun write-byte (byte stream)
  "Write one byte, BYTE, to STREAM."
  (stream-write-byte stream byte)
  byte)


;;;General stream functions



(defmacro with-open-stream ((var stream) &body body &aux (svar (gensym)))
  "Perform a series of operations on stream, return a value, and then
close the stream.  VAR is bound to the value of STREAM, and then BODY is
executed as an implicit progn. STREAM is automatically closed on exit
from with-open-stream, no matter whether the exit is normal or abnormal.
The stream has dynamic extent; its extent ends when the form is exited."
  `(let (,svar)
     (unwind-protect
       (let ((,var (setq ,svar ,stream)))
         ,@body)
       (when ,svar (close ,svar)))))




;;

;;; from i/o chapter of steele
;;; Ever notice that -much- of this code is from the i/o chapter
;;; of steele ?  Strange but true ...

(defun read-from-string (string &optional (eof-error-p t) eof-value
                                &key (start 0) end preserve-whitespace
                                &aux idx)
  "The characters of string are successively given to the lisp reader
   and the lisp object built by the reader is returned. Macro chars
   will take effect."
  (values
   (with-input-from-string (stream string :index idx :start start :end end)
     (if preserve-whitespace
       (read-preserving-whitespace stream eof-error-p eof-value)
       (read stream eof-error-p eof-value)))
   idx))


;;;File Stuff here

(let* ((dribble-stream nil)
       (old-standard-input nil)
       (old-standard-output nil)
       (old-error-output nil))
  (defun undribble ()
    (when dribble-stream
      (close dribble-stream)
      (setq dribble-stream nil
	    *standard-output* old-standard-output
	    old-standard-output nil
	    *standard-input* old-standard-input
	    old-standard-input nil
	    *error-output* old-error-output
	    old-error-output nil)))
  (defun dribble (&optional filename)
    "With a file name as an argument, dribble opens the file and sends a
     record of further I/O to that file. Without an argument, it closes
     the dribble file, and quits logging."
    (undribble)
    (when filename
      (setq dribble-stream
	    (open filename :direction :output :if-exists :append 
		  :if-does-not-exist :create)
	    old-standard-input *standard-input*
	    *standard-input* (make-echo-stream
			      old-standard-input dribble-stream)
	    old-standard-output *standard-output*
	    *standard-output* (make-broadcast-stream
			       old-standard-output dribble-stream)
	    old-error-output *error-output*
	    *error-output* (make-broadcast-stream
			    old-error-output dribble-stream)))))

