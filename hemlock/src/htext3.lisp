;;; -*- Log: hemlock.log; Package: Hemlock-Internals -*-
;;;
;;; **********************************************************************
;;; This code was written as part of the CMU Common Lisp project at
;;; Carnegie Mellon University, and has been placed in the public domain.
;;;
#+CMU (ext:file-comment
  "$Header$")
;;;
;;; **********************************************************************
;;;
;;; More Hemlock Text-Manipulation functions.
;;; Written by Skef Wholey.
;;;
;;; The code in this file implements the insert functions in the
;;; "Doing Stuff and Going Places" chapter of the Hemlock Design document.
;;;

(in-package :hemlock-internals)

;;; Return (and deactivate) the current region.
(defun %buffer-current-region (b)
  (when (and (typep b 'buffer)
             (variable-value 'hemlock::active-regions-enabled)
             (eql (buffer-signature b)
                  (buffer-region-active b)))
    (let* ((mark (buffer-%mark b))
           (point (buffer-point b)))
      (setf (buffer-region-active b) nil)
      (if (mark< mark point)
        (region mark point)
        (region point mark)))))
             

(defun insert-character (mark character)
  "Inserts the Character at the specified Mark."
  (declare (type base-char character))
  (let* ((line (mark-line mark))
	 (buffer (line-%buffer line))
         (region (%buffer-current-region buffer)))
    (when region
      (delete-region region))
    (modifying-buffer buffer
		      (modifying-line line mark)
                      (check-buffer-modification buffer mark)
		      (cond ((char= character #\newline)
			     (let* ((next (line-next line))
				    (new-chars (subseq (the simple-string *open-chars*)
						       0 *left-open-pos*))
				    (new-line (make-line :%buffer buffer
							 :chars (decf *cache-modification-tick*)
							 :previous line
							 :next next)))
			       (maybe-move-some-marks (charpos line new-line) *left-open-pos*
						      (- charpos *left-open-pos*))
			       (setf (line-%chars line) new-chars)
			       (setf (line-next line) new-line)
			       (if next (setf (line-previous next) new-line))
			       (number-line new-line)
			       (setq *open-line* new-line  *left-open-pos* 0)))
			    (t
			     (if (= *right-open-pos* *left-open-pos*)
			       (grow-open-chars))
	     
			     (maybe-move-some-marks (charpos line) *left-open-pos*
						    (1+ charpos))
	     
			     (cond
			       ((eq (mark-%kind mark) :right-inserting)
				(decf *right-open-pos*)
				(setf (char (the simple-string *open-chars*) *right-open-pos*)
				      character))
			       (t
				(setf (char (the simple-string *open-chars*) *left-open-pos*)
				      character)
				(incf *left-open-pos*)))))
		      (buffer-note-insertion buffer mark 1))))


(defun insert-string (mark string &optional (start 0) (end (length string)))
  "Inserts the String at the Mark.  Do not use Start and End unless you
  know what you're doing!"
  (let* ((line (mark-line mark))
	 (buffer (line-%buffer line))
	 (string (coerce string 'simple-string))
         (region (%buffer-current-region buffer)))
    (declare (simple-string string))
    (when region
      (delete-region region))
    (unless (zerop (- end start))
      (check-buffer-modification buffer mark)
      (if (%sp-find-character string start end #\newline)
	(with-mark ((mark mark :left-inserting))
	   (do ((left-index start (1+ right-index))
		(right-index
		 (%sp-find-character string start end #\newline)
		 (%sp-find-character string (1+ right-index) end #\newline)))
	       ((null right-index)
		(if (/= left-index end)
		  (insert-string mark string left-index end)))
	     (insert-string mark string left-index right-index)
	     (insert-character mark #\newline)))
	(modifying-buffer
	 buffer
	 (modifying-line line mark)
	 (let ((length (- end start)))
	   (if (<= *right-open-pos* (+ *left-open-pos* end))
	     (grow-open-chars (* (+ *line-cache-length* end) 2)))
	      
	   (maybe-move-some-marks (charpos line) *left-open-pos*
				  (+ charpos length))
	   (cond
	     ((eq (mark-%kind mark) :right-inserting)
	      (let ((new (- *right-open-pos* length)))
		(%sp-byte-blt string start *open-chars* new *right-open-pos*)
		(setq *right-open-pos* new)))
	     (t
	      (let ((new (+ *left-open-pos* length)))
		(%sp-byte-blt string start *open-chars* *left-open-pos* new)
		(setq *left-open-pos* new)))))
	 (buffer-note-insertion buffer mark (- end start)))))))


(defconstant line-number-interval-guess 8
  "Our first guess at how we should number an inserted region's lines.")

(defun insert-region (mark region)
  "Inserts the given Region at the Mark."
  (let* ((start (region-start region))
	 (end (region-end region))
	 (first-line (mark-line start))
	 (last-line (mark-line end))
	 (first-charpos (mark-charpos start))
	 (last-charpos (mark-charpos end))
         (nins (count-characters region)))
    (cond
     ((eq first-line last-line)
      ;; simple case -- just BLT the characters in with insert-string
      (if (eq first-line *open-line*) (close-line))
      (insert-string mark (line-chars first-line) first-charpos last-charpos))
     (t
      (close-line)
      (let* ((line (mark-line mark))
	     (next (line-next line))
	     (charpos (mark-charpos mark))
	     (buffer (line-%buffer line))
	     (old-chars (line-chars line)))
	(declare (simple-string old-chars))
	(modifying-buffer buffer
	  ;;hack marked line's chars
	  (let* ((first-chars (line-chars first-line))
		 (first-length (length first-chars))
		 (new-length (+ charpos (- first-length first-charpos)))
		 (new-chars (make-string new-length)))
	    (declare (simple-string first-chars new-chars))
	    (%sp-byte-blt old-chars 0 new-chars 0 charpos)
	    (%sp-byte-blt first-chars first-charpos new-chars charpos new-length)
	    (setf (line-chars line) new-chars))
	  
	  ;; Copy intervening lines.  We don't link the lines in until we are
	  ;; done in case the mark is within the region we are inserting.
	  (do* ((this-line (line-next first-line) (line-next this-line))
		(number (+ (line-number line) line-number-interval-guess)
			(+ number line-number-interval-guess))
		(first (%copy-line this-line  :previous line
				   :%buffer buffer  :number number))
		(previous first)
		(new-line first (%copy-line this-line  :previous previous
					    :%buffer buffer  :number number)))
	       ((eq this-line last-line)
		;;make last line
		(let* ((last-chars (line-chars new-line))
		       (old-length (length old-chars))
		       (new-length (+ last-charpos (- old-length charpos)))
		       (new-chars (make-string new-length)))
		  (%sp-byte-blt last-chars 0 new-chars 0 last-charpos)
		  (%sp-byte-blt old-chars charpos new-chars last-charpos
				new-length)
		  (setf (line-next line) first)
		  (setf (line-chars new-line) new-chars)
		  (setf (line-next previous) new-line)
		  (setf (line-next new-line) next)
		  (when next
		    (setf (line-previous next) new-line)
		    (if (<= (line-number next) number)
			(renumber-region-containing new-line)))
		  ;;fix up the marks
		  (maybe-move-some-marks (this-charpos line new-line) charpos
		    (+ last-charpos (- this-charpos charpos)))))
	    (setf (line-next previous) new-line  previous new-line))
          (buffer-note-insertion buffer  mark nins)))))))

(defun ninsert-region (mark region)
  "Inserts the given Region at the Mark, possibly destroying the Region.
  Region may not be a part of any buffer's region."
  (let* ((start (region-start region))
	 (end (region-end region))
	 (first-line (mark-line start))
	 (last-line (mark-line end))
	 (first-charpos (mark-charpos start))
	 (last-charpos (mark-charpos end))
         (nins (count-characters region)))
    (cond
     ((eq first-line last-line)
      ;; Simple case -- just BLT the characters in with insert-string.
      (if (eq first-line *open-line*) (close-line))
      (insert-string mark (line-chars first-line) first-charpos last-charpos))
     (t
      (when (bufferp (line-%buffer first-line))
	(error "Region is linked into Buffer ~S." (line-%buffer first-line)))
      (close-line)
      (let* ((line (mark-line mark))
	     (second-line (line-next first-line))
	     (next (line-next line))
	     (charpos (mark-charpos mark))
	     (buffer (line-%buffer line))
	     (old-chars (line-chars line)))
	(declare (simple-string old-chars))
	(modifying-buffer buffer
	  ;; Make new chars for first and last lines.
	  (let* ((first-chars (line-chars first-line))
		 (first-length (length first-chars))
		 (new-length (+ charpos (- first-length first-charpos)))
		 (new-chars (make-string new-length)))
	    (declare (simple-string first-chars new-chars))
	    (%sp-byte-blt old-chars 0 new-chars 0 charpos)
	    (%sp-byte-blt first-chars first-charpos new-chars charpos
			  new-length)
	    (setf (line-chars line) new-chars))
	  (let* ((last-chars (line-chars last-line))
		 (old-length (length old-chars))
		 (new-length (+ last-charpos (- old-length charpos)))
		 (new-chars (make-string new-length)))
	    (%sp-byte-blt last-chars 0 new-chars 0 last-charpos)
	    (%sp-byte-blt old-chars charpos new-chars last-charpos new-length)
	    (setf (line-chars last-line) new-chars))
	  
	  ;;; Link stuff together.
	  (setf (line-next last-line) next)
	  (setf (line-next line) second-line)
	  (setf (line-previous second-line) line)

	  ;;Number the inserted stuff and mash any marks.
	  (do ((line second-line (line-next line))
	       (number (+ (line-number line) line-number-interval-guess)
		       (+ number line-number-interval-guess)))
	      ((eq line next)
	       (when next
		 (setf (line-previous next) last-line)	       
		 (if (<= (line-number next) number)
		     (renumber-region-containing last-line))))
	    (when (line-marks line)
	      (dolist (m (line-marks line))
		(setf (mark-line m) nil))
	      (setf (line-marks line) nil))
	    (setf (line-number line) number  (line-%buffer line) buffer))
	  
	  ;; Fix up the marks in the line inserted into.
	  (maybe-move-some-marks (this-charpos line last-line) charpos
	    (+ last-charpos (- this-charpos charpos)))
          (buffer-note-insertion buffer mark nins)))))))
