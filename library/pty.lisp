;;;-*-Mode: LISP; Package: CCL -*-
;;;
;;;   Copyright (C) 2002 Clozure Associates.
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

;;; (very) preliminary support for dealing with TTYs (and PTYs).

;;; Open a (connected) pair of pty file descriptors, such that anything
;;; written to one can be read from the other.
#+linuxppc-target
(eval-when (:load-toplevel :execute)
  (open-shared-library "libutil.so"))

(defun open-pty-pair ()
  (rlet ((alphap :unsigned-long 0)
	 (betap :unsigned-long 0))
    (let* ((status (#_openpty alphap betap (%null-ptr) (%null-ptr) (%null-ptr))))
      (if (eql status 0)
	(values (pref alphap :unsigned-long) (pref betap :unsigned-long))
	(%errno-disp (%get-errno))))))


(defun %get-tty-attributes (tty-fd &optional control-chars)
  (if (and control-chars
	   (not (and (typep control-chars 'simple-string)
		     (= (length control-chars) #$NCCS))))
    (report-bad-arg control-chars '(or null (simple-string #.#$NCCS))))
  (rlet ((attr :termios))
    (let* ((result (#_tcgetattr tty-fd attr)))
      (if (< result 0)
	(values nil nil nil nil nil nil nil)
	(progn
	  (if control-chars
	    (%copy-ptr-to-ivector (pref attr :termios.c_cc)
				  0
				  control-chars
				  0
				  #$NCCS))
	  (values
	   (pref attr :termios.c_iflag)
	   (pref attr :termios.c_oflag)
	   (pref attr :termios.c_cflag)
	   (pref attr :termios.c_lflag)
	   #+darwinppc-target 0
	   #-darwinppc-target
	   (pref attr :termios.c_line)
	   control-chars
	   (pref attr :termios.c_ispeed)
	   (pref attr :termios.c_ospeed)))))))

(defun %set-tty-attributes (tty &key
				input-modes
				output-modes
				control-modes
				local-modes
				control-chars
				input-speed
				output-speed)
  (if (and control-chars
	   (not (and (typep control-chars 'simple-string)
		     (= (length control-chars) #$NCCS))))
    (report-bad-arg control-chars '(or null (simple-string #.#$NCCS))))
  (rlet ((attr :termios))
	(let* ((get-ok (#_tcgetattr tty attr))
	       (write-back nil))
	  (when (eql 0 get-ok)
	    (when input-modes
	      (setf (pref attr :termios.c_iflag) input-modes)
	      (setq write-back t))
	    (when output-modes
	      (setf (pref attr :termios.c_oflag) output-modes)
	      (setq write-back t))
	    (when control-modes
	      (setf (pref attr :termios.c_cflag) control-modes)
	      (setq write-back t))
	    (when local-modes
	      (setf (pref attr :termios.c_lflag) local-modes)
	      (setq write-back t))
	    (when control-chars
	      (%copy-ivector-to-ptr control-chars
				    0
				    (pref attr :termios.c_cc)
				    0
				    #$NCCS)
	      (setq write-back t))
	    (when input-speed
	      (setf (pref attr :termios.c_ispeed) input-speed)
	      (setq write-back t))
	    (when output-speed
	      (setf (pref attr :termios.c_ospeed) output-speed)
	      (setq write-back t))
	    (and write-back
		 (eql 0 (#_tcsetattr tty #$TCSAFLUSH attr)))))))

(defun enable-tty-input-modes (tty mask)
  (let* ((old (nth-value 0 (%get-tty-attributes tty))))
    (when old
      (%set-tty-attributes tty :input-modes (logior old mask)))))

(defun disable-tty-input-modes (tty mask)
  (let* ((old (nth-value 0 (%get-tty-attributes tty))))
    (when old
      (%set-tty-attributes tty :input-modes (logand old (lognot mask))))))

(defun enable-tty-output-modes (tty mask)
  (let* ((old (nth-value 1 (%get-tty-attributes tty))))
    (when old
      (%set-tty-attributes tty :output-modes (logior old mask)))))

(defun disable-tty-output-modes (tty mask)
  (let* ((old (nth-value 1 (%get-tty-attributes tty))))
    (when old
      (%set-tty-attributes tty :output-modes (logand old (lognot mask))))))

(defun enable-tty-control-modes (tty mask)
  (let* ((old (nth-value 2 (%get-tty-attributes tty))))
    (when old
      (%set-tty-attributes tty :control-modes (logior old mask)))))

(defun disable-tty-control-modes (tty mask)
  (let* ((old (nth-value 2 (%get-tty-attributes tty))))
    (when old
      (%set-tty-attributes tty :control-modes (logand old (lognot mask))))))

(defun enable-tty-local-modes (tty mask)
  (let* ((old (nth-value 3 (%get-tty-attributes tty))))
    (when old
      (%set-tty-attributes tty :local-modes (logior old mask)))))

(defun disable-tty-local-modes (tty mask)
  (let* ((old (nth-value 3 (%get-tty-attributes tty))))
    (when old
      (%set-tty-attributes tty :local-modes (logand old (lognot mask))))))