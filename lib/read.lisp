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

(in-package "CCL")

(define-condition simple-reader-error (reader-error simple-error) ()
  (:report (lambda (c output-stream)
             (format output-stream "Reader error on stream ~S:~%~?"
                     (stream-error-stream c)
                     (simple-condition-format-control c)
                     (simple-condition-format-arguments c)))))

(defun signal-reader-error (input-stream format-string &rest format-args)
  (error 'simple-reader-error :stream input-stream
         :format-control format-string :format-arguments format-args))

#| ; Can't see any reason to leave this in
(defun read-file-to-list (file &aux result)
   ;(print-db (setq file (prepend-default-dir file)))   
   (with-open-file (stream file :direction :input)
       (setq result (read-file-to-list-aux stream)))
   result)

(defun read-file-to-list-aux (stream)
   (if (eofp stream)
        nil
       (let ((form (read stream nil *eof-value* nil)))
            ;(%print "just read " form)
           (if (eq form *eof-value*)
                nil
               (cons form (read-file-to-list-aux stream))))))
|#

(defun read-internal (input-stream)
   (read input-stream t nil t))


(set-dispatch-macro-character #\# #\*
 (qlfun |#*-reader| (input-stream sub-char int 
   &aux list list-length array array-length last-bit)
  (declare (ignore sub-char))
  (do* ((char (read-char input-stream nil nil t)
              (read-char input-stream nil nil t))
        (attr (%character-attribute char (rdtab.ttab *readtable*))
              (%character-attribute char (rdtab.ttab *readtable*))))
       ((or (null char)
            (= $cht_tmac attr)
            (= $cht_wsp attr))
        (if char (unread-char char input-stream)))
    (let ((number (- (char-code char) 48)))
      (if (or (<= 0 number 1) *read-suppress*)
          (setq list (cons number list))
          (signal-reader-error input-stream "reader macro #* got illegal character ~S" char))))
  (setq last-bit (car list))
  (setq list (nreverse list))
  (setq list-length (list-length list))
  (if (not (integerp int))
      (setq int list-length))
  (cond (*read-suppress* nil)
        ((and (= 0 list-length) (> int 0))
         (signal-reader-error input-stream "reader macro #~S* needs something" int))
        ((> list-length int)
         (signal-reader-error input-stream "reader macro #~S* can't fit ~S" int list))
        (t (setq array-length (if int int list-length))
           (setq array (make-array array-length :element-type 'bit))
           (do ((i 0 (1+ i))
                (bit-list list (cdr bit-list)))
               ((>= i array-length))
             (aset array i (if bit-list
                               (car bit-list)
                               last-bit)))
           array))))

(set-dispatch-macro-character #\# #\A
 (qlfun |#A-reader| (stream ignore dimensions)
  (declare (ignore ignore))
  (cond (*read-suppress*
	        (read stream () () t)
	        nil)
        ((not dimensions)
         (signal-reader-error stream "reader macro #A used without a rank integer"))
        ((eql dimensions 0) ;0 dimensional array
         (make-array nil :initial-contents (read-internal stream)))
        ((and (integerp dimensions) (> dimensions 0)) 
	         (let* ((dlist (make-list dimensions))
		               (init-list (read-internal stream)))
		              (if (not (listp init-list))
                    (signal-reader-error stream "The form following a #A reader macro should have been a list, but it was: ~S" init-list))                  
	              (do ((dl dlist (cdr dl))
		                  (il init-list (car il)))
	                   	;; I think the nreverse is causing the problem.
		                 ((null dl))
	                  (if (listp il)
		                     (rplaca dl (list-length il))
		                     (error
			                     "Initial contents for #A is inconsistent with ~
			                     dimensions: #~SA~S" dimensions init-list)))
	              (make-array dlist :initial-contents init-list)))
	       (t (signal-reader-error stream 
             "Dimensions argument to #A not a non-negative integer: ~S" 
		           dimensions)))))

(set-dispatch-macro-character #\# #\S
  (qlfun |#S-reader| (input-stream sub-char int &aux list sd)
     (declare (ignore sub-char int))
     (setq list (read-internal input-stream))
     (unless *read-suppress*
       (unless (and (consp list)
                    (symbolp (%car list))
                    (setq sd (gethash (%car list) %defstructs%))
		    (setq sd (sd-constructor sd)))
         (error "Can't initialize structure from ~S." list))
       (let ((args ()) (plist (cdr list)))
         (unless (plistp plist) (report-bad-arg plist '(satisfies plistp)))
         (while plist
           (push (make-keyword (pop plist)) args)
           (push (pop plist) args))
         (apply sd (nreverse args))))))

;from slisp reader2.lisp.
(defun parse-integer (string &key (start 0) end
                      (radix 10) junk-allowed)
  "Examine the substring of string delimited by start and end
  (default to the beginning and end of the string)  It skips over
  whitespace characters and then tries to parse an integer. The
  radix parameter must be between 2 and 36."
  (flet ((parse-integer-not-integer-string (s)
	   (error 'parse-integer-not-integer-string :string s)))
    (declare (inline not-integer-string-error))
    (when (null end)
      (setq end (length string)))
    (let ((index (do ((i start (1+ i)))
		     ((= i end)
		      (if junk-allowed
                        (return-from parse-integer (values nil end))
                        (parse-integer-not-integer-string string)))
                   (unless (whitespacep (char string i)) (return i))))
        (minusp nil)
        (found-digit nil)
        (result 0))
       (let ((char (char string index)))
            (cond ((char= char #\-)
                   (setq minusp t)
                   (setq index (1+ index)))
                  ((char= char #\+)
                    (setq index (1+ index))
                   )))
       (loop
        (when (= index end) (return nil))
        (let* ((char (char string index))
               (weight (digit-char-p char radix)))
              (cond (weight
                     (setq result (+ weight (* result radix))
                                  found-digit t))
                    (junk-allowed (return nil))
                    ((whitespacep char)
                     (until (eq (setq index (1+ index)) end)
                       (unless (whitespacep (char string index))
                         (parse-integer-not-integer-string string)))
                     (return nil))
                    (t
                     (parse-integer-not-integer-string string))))
         (setq index (1+ index)))
       (values
        (if found-digit
            (if minusp (- result) result)
            (if junk-allowed
                nil
                (parse-integer-not-integer-string string)))
        index))))


(set-dispatch-macro-character #\# #\#
  #'(lambda (stream char arg)
      (declare (ignore stream))
      (if *read-suppress* 
        nil
        (if arg
          (let ((pair (assoc arg %read-objects%))) ;Not assq, could be bignum!
            (if pair
              (cdr pair)
              (%err-disp $xnordlbl arg)))
          (%err-disp $xrdndarg char)))))

(set-dispatch-macro-character 
 #\# 
 #\=
 #'(lambda (stream char arg &aux lab form)
     (cond (*read-suppress* (values))
           ((null arg) (%err-disp $xrdndarg char))
           ((assoc arg %read-objects%)    ;Not assq, could be bignum!
            (%err-disp $xduprdlbl arg))
           (t (setq lab (cons arg nil))
              (push (%rplacd lab lab) %read-objects%)
              (setq form (read stream t nil t))
              (when (eq form lab)   ;#n= #n#.  No can do.
                (%err-disp $xnordlbl (%car lab)))
              (%rplacd lab form)
              (let ((scanned nil))
                  (labels ((circle-subst (tree)
                             (if (memq tree %read-objects%)
                               (progn
                                 (unless (memq tree scanned)
                                   (setq scanned (%temp-cons tree scanned))
                                   (circle-subst (cdr tree)))
                                 (cdr tree))
                               (let ((gvectorp (and (gvectorp tree)  (not (or (symbolp tree) (functionp tree))))))
                                 (unless (or (and (atom tree) (not gvectorp)) (memq tree scanned))
                                   (setq scanned (%temp-cons tree scanned))
                                   (if gvectorp
                                     (let* ((subtype  (typecode tree)))
                                       (dotimes (i (uvsize tree))
                                         (declare (fixnum i))
                                         (unless (and (eql i 0) (eql subtype target::subtag-instance))
                                           (setf (uvref tree i) (circle-subst (uvref tree i))))))
                                     (locally 
                                      (declare (type cons tree))
                                      (rplaca tree (circle-subst (car tree)))
                                      (rplacd tree (circle-subst (cdr tree))))))
                                 tree))))
                    (declare (dynamic-extent #'circle-subst))
                    (circle-subst form)))))))



