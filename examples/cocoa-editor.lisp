;;;-*- Mode: LISP; Package: CCL -*-


(in-package "CCL")

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require "COCOA-WINDOW")
  (require "HEMLOCK"))

(eval-when (:compile-toplevel :execute)
  (use-interface-dir :cocoa))

(def-cocoa-default *editor-rows* :int 24)
(def-cocoa-default *editor-columns* :int 80)

;;; At runtime, this'll be a vector of character attribute dictionaries.
(defloadvar *styles* ())

(defun make-editor-style-map ()
  (let* ((font-name *default-font-name*)
	 (font-size *default-font-size*)
	 (fonts (vector (default-font :name font-name :size font-size
				      :attributes ())
			(default-font :name font-name :size font-size
				      :attributes '(:bold))
			(default-font  :name font-name :size font-size
				      :attributes '(:italic))
			(default-font :name font-name :size font-size
				      :attributes '(:bold :italic))))
	 (color-class (find-class 'ns:ns-color))
	 (colors (vector (send color-class 'black-color)
			 (send color-class 'white-color)
			 (send color-class 'dark-gray-color)
			 (send color-class 'light-gray-color)
			 (send color-class 'red-color)
			 (send color-class 'blue-color)
			 (send color-class 'green-color)
			 (send color-class 'yellow-color)))
	 (styles (make-array (the fixnum (* (length fonts) (length colors)))))
	 (s 0))
    (declare (dynamic-extent fonts colors))
    (dotimes (c (length colors))
      (dotimes (f (length fonts))
	(setf (svref styles s) (create-text-attributes :font (svref fonts f)
						       :color (svref colors c)))
	(incf s)))
    (setq *styles* styles)))

(defun make-hemlock-buffer (&rest args)
  (let* ((buf (apply #'hi::make-buffer args)))
    (or buf
	(progn
	  (format t "~& couldn't make hemlock buffer with args ~s" args)
	  (dbg)
	  nil))))
	 
;;; Define some key event modifiers.

;;; HEMLOCK-EXT::DEFINE-CLX-MODIFIER is kind of misnamed; we can use
;;; it to map NSEvent modifier keys to key-event modifiers.

(hemlock-ext::define-clx-modifier #$NSShiftKeyMask "Shift")
(hemlock-ext::define-clx-modifier #$NSControlKeyMask "Control")
(hemlock-ext::define-clx-modifier #$NSAlternateKeyMask "Meta")
(hemlock-ext::define-clx-modifier #$NSAlphaShiftKeyMask "Lock")


;;; We want to display a Hemlock buffer in a "pane" (an on-screen
;;; view) which in turn is presented in a "frame" (a Cocoa window).  A
;;; 1:1 mapping between frames and panes seems to fit best into
;;; Cocoa's document architecture, but we should try to keep the
;;; concepts separate (in case we come up with better UI paradigms.)
;;; Each pane has a modeline (which describes attributes of the
;;; underlying document); each frame has an echo area (which serves
;;; to display some commands' output and to provide multi-character
;;; input.)


;;; I'd pretty much concluded that it wouldn't be possible to get the
;;; Cocoa text system (whose storage model is based on NSString
;;; NSMutableAttributedString, NSTextStorage, etc.) to get along with
;;; Hemlock, and (since the whole point of using Hemlock was to be
;;; able to treat an editor buffer as a rich lisp data structure) it
;;; seemed like it'd be necessary to toss the higher-level Cocoa text
;;; system and implement our own scrolling, redisplay, selection
;;; ... code.
;;;
;;; Mikel Evins pointed out that NSString and friends were
;;; abstract classes and that there was therefore no reason (in
;;; theory) not to implement a thin wrapper around a Hemlock buffer
;;; that made it act like an NSString.  As long as the text system can
;;; ask a few questions about the NSString (its length and the
;;; character and attributes at a given location), it's willing to
;;; display the string in a scrolling, mouse-selectable NSTextView;
;;; as long as Hemlock tells the text system when and how the contents
;;; of the abstract string changes, Cocoa will handle the redisplay
;;; details.
;;;


;;; Hemlock-buffer-string objects:

(defclass hemlock-buffer-string (ns:ns-string)
    ((cache :initform nil :initarg :cache :accessor hemlock-buffer-string-cache))
  (:metaclass ns:+ns-object))

;;; Cocoa wants to treat the buffer as a linear array of characters;
;;; Hemlock wants to treat it as a doubly-linked list of lines, so
;;; we often have to map between an absolute position in the buffer
;;; and a relative position on a line.  We can certainly do that
;;; by counting the characters in preceding lines every time that we're
;;; asked, but we're often asked to map a sequence of nearby positions
;;; and wind up repeating a lot of work.  Caching the results of that
;;; work seems to speed things up a bit in many cases; this data structure
;;; is used in that process.  (It's also the only way to get to the
;;; actual underlying Lisp buffer from inside the network of text-system
;;; objects.)

(defstruct buffer-cache 
  buffer				; the hemlock buffer
  buflen				; length of buffer, if known
  workline				; cache for character-at-index
  workline-offset			; cached offset of workline
  workline-length			; length of cached workline
  workline-start-font-index		; current font index at start of worklin
  )

;;; Initialize (or reinitialize) a buffer cache, so that it points
;;; to the buffer's first line (which is the only line whose
;;; absolute position will never change).  Code which modifies the
;;; buffer generally has to call this, since any cached information
;;; might be invalidated by the modification.
(defun reset-buffer-cache (d &optional (buffer (buffer-cache-buffer d)
						buffer-p))
  (when buffer-p (setf (buffer-cache-buffer d) buffer))
  (let* ((workline (hemlock::mark-line
		    (hemlock::buffer-start-mark buffer))))
    (setf (buffer-cache-buflen d) (hemlock-buffer-length buffer)
	  (buffer-cache-workline-offset d) 0
	  (buffer-cache-workline d) workline
	  (buffer-cache-workline-length d) (hemlock::line-length workline)
	  (buffer-cache-workline-start-font-index d) 0)
    d))


;;; Update the cache so that it's describing the current absolute
;;; position.
(defun update-line-cache-for-index (cache index)
  (let* ((line (or
		(buffer-cache-workline cache)
		(progn
		  (reset-buffer-cache cache)
		  (buffer-cache-workline cache))))
	 (pos (buffer-cache-workline-offset cache))
	 (len (buffer-cache-workline-length cache))
	 (moved nil))
    (loop
      (when (and (>= index pos)
		   (< index (1+ (+ pos len))))
	  (let* ((idx (- index pos)))
	    (when moved
	      (setf (buffer-cache-workline cache) line
		    (buffer-cache-workline-offset cache) pos
		    (buffer-cache-workline-length cache) len))
	    (return (values line idx))))
	(setq moved t)
      (if (< index pos)
	(setq line (hemlock::line-previous line)
	      len (hemlock::line-length line)
	      pos (1- (- pos len)))
	(setq line (hemlock::line-next line)
	      pos (1+ (+ pos len))
	      len (hemlock::line-length line))))))

;;; Ask Hemlock to count the characters in the buffer.
(defun hemlock-buffer-length (buffer)
  (hemlock::count-characters (hemlock::buffer-region buffer)))

;;; Find the line containing (or immediately preceding) index, which is
;;; assumed to be less than the buffer's length.  Return the character
;;; in that line or the trailing #\newline, as appropriate.
(defun hemlock-char-at-index (cache index)
  (multiple-value-bind (line idx) (update-line-cache-for-index cache index)
    (let* ((len (hemlock::line-length line)))
      (if (< idx len)
	(hemlock::line-character line idx)
	#\newline))))

;;; Given an absolute position, move the specified mark to the appropriate
;;; offset on the appropriate line.
(defun move-hemlock-mark-to-absolute-position (mark cache abspos)
  (multiple-value-bind (line idx) (update-line-cache-for-index cache abspos)
    (hemlock::move-to-position mark idx line)))

;;; Return the absolute position of the mark in the containing buffer.
;;; This doesn't use the caching mechanism, so it's always linear in the
;;; number of preceding lines.
(defun mark-absolute-position (mark)
  (let* ((pos (hemlock::mark-charpos mark)))
    (do* ((line (hemlock::line-previous (hemlock::mark-line mark))
		(hemlock::line-previous line)))
	 ((null line) pos)
      (incf pos (1+ (hemlock::line-length line))))))

;;; Return the length of the abstract string, i.e., the number of
;;; characters in the buffer (including implicit newlines.)
(define-objc-method ((:unsigned length)
		     hemlock-buffer-string)
  (let* ((cache (hemlock-buffer-string-cache self)))
    (force-output)
    (or (buffer-cache-buflen cache)
        (setf (buffer-cache-buflen cache)
              (hemlock-buffer-length (buffer-cache-buffer cache))))))


;;; Return the character at the specified index (as a :unichar.)
(define-objc-method ((:unichar :character-at-index (unsigned index))
		     hemlock-buffer-string)
  (char-code (hemlock-char-at-index (hemlock-buffer-string-cache self) index)))


;;; Return an NSData object representing the bytes in the string.  If
;;; the underlying buffer uses #\linefeed as a line terminator, we can
;;; let the superclass method do the work; otherwise, we have to
;;; ensure that each line is terminated according to the buffer's
;;; conventions.
(define-objc-method ((:id :data-using-encoding (:<NSS>tring<E>ncoding encoding)
			  :allow-lossy-conversion (:<BOOL> flag))
		     hemlock-buffer-string)
  (let* ((buffer (buffer-cache-buffer (hemlock-buffer-string-cache self)))
	 (external-format (if buffer (hi::buffer-external-format buffer )))
	 (raw-length (if buffer (hemlock-buffer-length buffer) 0)))
    (if (eql 0 raw-length)
      (make-objc-instance 'ns:ns-mutable-data :with-length 0)
      (case external-format
	((:unix nil)
	 (send-super :data-using-encoding encoding :allow-lossy-conversion flag))
	((:macos :cp/m)
	 (let* ((cp/m-p (eq external-format :cp/m)))
	   (when cp/m-p
	 ;; This may seem like lot of fuss about an ancient OS and its
	 ;; odd line-termination conventions.  Of course, I'm actually
	 ;; referring to CP/M-86.
	     (do* ((line (hi::mark-line (hi::buffer-start-mark buffer))
			 next)
		   (next (hi::line-next line) (hi::line-next line)))
		  ((null line))
	       (when next (incf raw-length))))
	   (let* ((pos 0)
		  (data (make-objc-instance 'ns:ns-mutable-data
					    :with-length raw-length))
		  (bytes (send data 'mutable-bytes)))
	     (do* ((line (hi::mark-line (hi::buffer-start-mark buffer))
			 next)
		   (next (hi::line-next line) (hi::line-next line)))
		  ((null line) data)
	       (let* ((chars (hi::line-chars line))
		      (len (length chars)))
		 (unless (zerop len)
		   (%copy-ivector-to-ptr chars 0 bytes pos len)
		   (incf pos len))
		 (when next
		   (setf (%get-byte bytes pos) (char-code #\return))
		   (when cp/m-p
		     (incf pos)
		   (setf (%get-byte bytes pos) (char-code #\linefeed))  
		   (incf pos))))))))))))


;;; For debugging, mostly: make the printed representation of the string
;;; referenence the named Hemlock buffer.
(define-objc-method ((:id description)
		     hemlock-buffer-string)
  (let* ((cache (hemlock-buffer-string-cache self))
	 (b (buffer-cache-buffer cache)))
    (with-cstrs ((s (format nil "~a" b)))
      (send (@class ns-string) :string-with-format #@"<%s for %s>"
	(:address (#_object_getClassName self) :address s)))))



;;; Lisp-text-storage objects
(defclass lisp-text-storage (ns:ns-text-storage)
    ((string :foreign-type :id))
  (:metaclass ns:+ns-object))

;;; Access the string.  It'd be nice if this was a generic function;
;;; we could have just made a reader method in the class definition.
(define-objc-method ((:id string) lisp-text-storage)
  (slot-value self 'string))

(define-objc-method ((:id :init-with-string s) lisp-text-storage)
  (let* ((newself (send-super 'init)))
    (setf (slot-value newself 'string) s)
    newself))

;;; This is the only thing that's actually called to create a
;;; lisp-text-storage object.  (It also creates the underlying
;;; hemlock-buffer-string.)
(defun make-textstorage-for-hemlock-buffer (buffer)
  (make-objc-instance 'lisp-text-storage
		      :with-string
		      (make-instance
		       'hemlock-buffer-string
		       :cache
		       (reset-buffer-cache
			(make-buffer-cache)
			buffer))))

;;; So far, we're ignoring Hemlock's font-marks, so all characters in
;;; the buffer are presumed to have default attributes.
(define-objc-method ((:id :attributes-at-index (:unsigned index)
			  :effective-range ((* :<NSR>ange) rangeptr))
		     lisp-text-storage)
  (declare (ignorable index))
  (let* ((buffer-cache (hemlock-buffer-string-cache (slot-value self 'string)))
	 (len (buffer-cache-buflen buffer-cache)))
    (unless (%null-ptr-p rangeptr)
      (setf (pref rangeptr :<NSR>ange.location) 0
	    (pref rangeptr :<NSR>ange.length) len))
    (svref *styles* 0)))

;;; The range's origin should probably be the buffer's point; if
;;; the range has non-zero length, we probably need to think about
;;; things harder.
(define-objc-method ((:void :replace-characters-in-range (:<NSR>ange r)
			    :with-string string)
		     lisp-text-storage)
  (#_NSLog #@"replace-characters-in-range (%d %d) with-string %@"
	   :unsigned (pref r :<NSR>ange.location)
	   :unsigned (pref r :<NSR>ange.length)
	   :id string))

;;; I'm not sure if we want the text system to be able to change
;;; attributes in the buffer.
(define-objc-method ((:void :set-attributes attributes
			    :range (:<NSR>ange r))
		     lisp-text-storage)
  (#_NSLog #@"set-attributes %@ range (%d %d)"
	   :id attributes
	   :unsigned (pref r :<NSR>ange.location)
	   :unsigned (pref r :<NSR>ange.length)))


;;; Again, it's helpful to see the buffer name when debugging.
(define-objc-method ((:id description)
		     lisp-text-storage)
  (send (@class ns-string) :string-with-format #@"%s : string %@"
	(:address (#_object_getClassName self) :id (slot-value self 'string))))

(defun close-hemlock-textstorage (ts)
  (let* ((string (slot-value ts 'string)))
    (setf (slot-value ts 'string) (%null-ptr))
    (unless (%null-ptr-p string)
      (let* ((cache (hemlock-buffer-string-cache string))
	     (buffer (if cache (buffer-cache-buffer cache))))
	(when buffer
	  (setf (buffer-cache-buffer cache) nil
		(slot-value string 'cache) nil
		(hi::buffer-document buffer) nil)
	  (let* ((p (hi::buffer-process buffer)))
	    (when p
	      (setf (hi::buffer-process buffer) nil)
	      (process-kill p)))
	  (when (eq buffer hi::*current-buffer*)
	    (setf (hi::current-buffer)
		  (car (last hi::*buffer-list*))))
	  (hi::invoke-hook (hi::buffer-delete-hook buffer) buffer)
	  (hi::invoke-hook hemlock::delete-buffer-hook buffer)
	  (setq hi::*buffer-list* (delq buffer hi::*buffer-list*))
	  (hi::delete-string (hi::buffer-name buffer) hi::*buffer-names*))))))

      



;;; A specialized NSTextView.  Some of the instance variables are intended
;;; to support paren highlighting by blinking, but that doesn't work yet.
;;; The NSTextView is part of the "pane" object that displays buffers.
(defclass hemlock-text-view (ns:ns-text-view)
    ((timer :foreign-type :id :accessor blink-timer)
     (blink-pos :foreign-type :int :accessor blink-pos)
     (blink-phase :foreign-type :<BOOL> :accessor blink-phase)
     (blink-char :foreign-type :int :accessor blink-char)
     (pane :foreign-type :id :accessor text-view-pane))
  (:metaclass ns:+ns-object))

;;; Access the underlying buffer in one swell foop.
(defmethod text-view-buffer ((self hemlock-text-view))
  (buffer-cache-buffer (hemlock-buffer-string-cache (send (send self 'text-storage) 'string))))

;;; Translate a keyDown NSEvent to a Hemlock key-event.
(defun nsevent-to-key-event (nsevent)
  (let* ((unmodchars (send nsevent 'characters-ignoring-modifiers))
	 (n (if (%null-ptr-p unmodchars)
	      0
	      (send unmodchars 'length)))
	 (c (if (eql n 1)
	      (send unmodchars :character-at-index 0))))
    (when c
      (let* ((bits 0)
	     (modifiers (send nsevent 'modifier-flags))
             (useful-modifiers (logandc2 modifiers
                                         (logior #$NSShiftKeyMask
                                                 #$NSAlphaShiftKeyMask))))
	(dolist (map hemlock-ext::*modifier-translations*)
	  (when (logtest useful-modifiers (car map))
	    (setq bits (logior bits (hemlock-ext::key-event-modifier-mask
				     (cdr map))))))
	(hemlock-ext::make-key-event c bits)))))

;;; Process a key-down NSEvent in a lisp text view by translating it
;;; into a Hemlock key event and passing it into the Hemlock command
;;; interpreter.  The underlying buffer becomes Hemlock's current buffer
;;; and the containing pane becomes Hemlock's current window when the
;;; command is processed.  Use the frame's command state object.

(define-objc-method ((:void :key-down event)
		     hemlock-text-view)
  #+debug
  (#_NSLog #@"Key down event = %@" :address event)
  (let* ((buffer (text-view-buffer self)))
    (when buffer
      (let* ((info (hemlock-frame-command-info (send self 'window))))
	(when info
	  (let* ((key-event (nsevent-to-key-event event)))
	    (when event
	      (unless (eq buffer hi::*current-buffer*)
		(setf (hi::current-buffer) buffer))
	      (let* ((pane (text-view-pane self)))
		(unless (eql pane (hi::current-window))
		  (setf (hi::current-window) pane)))
	      #+debug 
	      (format t "~& key-event = ~s" key-event)
	      (hi::interpret-key-event key-event info))))))))

;;; Update the underlying buffer's point.  Should really set the
;;; active region (in Hemlock terms) as well.
(define-objc-method ((:void :set-selected-range (:<NSR>ange r)
			    :affinity (:<NSS>election<A>ffinity affinity)
			    :still-selecting (:<BOOL> still-selecting))
		     hemlock-text-view)
  (let* ((d (hemlock-buffer-string-cache (send self 'string)))
	 (point (hemlock::buffer-point (buffer-cache-buffer d)))
	 (location (pref r :<NSR>ange.location))
	 (len (pref r :<NSR>ange.length)))
    (when (eql len 0)
      (move-hemlock-mark-to-absolute-position point d location))
    (send-super :set-selected-range r
		:affinity affinity
		:still-selecting still-selecting)))



;;; Modeline-view

;;; The modeline view is embedded in the horizontal scroll bar of the
;;; scrollview which surrounds the textview in a pane.  (A view embedded
;;; in a scrollbar like this is sometimes called a "placard").  Whenever
;;; the view's invalidated, its drawRect: method draws a string containing
;;; the current values of the buffer's modeline fields.

(defclass modeline-view (ns:ns-view)
    ((pane :foreign-type :id :accessor modeline-view-pane))
  (:metaclass ns:+ns-object))


;;; Attributes to use when drawing the modeline fields.  There's no
;;; simple way to make the "placard" taller, so using fonts larger than
;;; about 12pt probably wouldn't look too good.  10pt Courier's a little
;;; small, but allows us to see more of the modeline fields (like the
;;; full pathname) in more cases.

(defloadvar *modeline-text-attributes* nil)

(def-cocoa-default *modeline-font-name* :string "Courier New Bold Italic")
(def-cocoa-default  *modeline-font-size* :float 10.0)


;;; Find the underlying buffer.
(defun buffer-for-modeline-view (mv)
  (let* ((pane (modeline-view-pane mv)))
    (unless (%null-ptr-p pane)
      (let* ((tv (text-pane-text-view pane)))
        (unless (%null-ptr-p tv)
	  (text-view-buffer tv))))))

;;; Draw a string in the modeline view.  The font and other attributes
;;; are initialized lazily; apparently, calling the Font Manager too
;;; early in the loading sequence confuses some Carbon libraries that're
;;; used in the event dispatch mechanism,
(defun draw-modeline-string (modeline-view)
  (let* ((pane (modeline-view-pane modeline-view))
         (buffer (buffer-for-modeline-view modeline-view)))
    (when buffer
      ;; You don't want to know why this is done this way.
      (unless *modeline-text-attributes*
	(setq *modeline-text-attributes*
	      (create-text-attributes :color (send (@class "NSColor") 'black-color)
				      :font (default-font
					      :name *modeline-font-name*
					      :size *modeline-font-size*))))
      
      (let* ((string
              (apply #'concatenate 'string
                     (mapcar
                      #'(lambda (field)
                          (funcall (hi::modeline-field-function field)
                                   buffer pane))
                      (hi::buffer-modeline-fields buffer)))))
	(send (%make-nsstring string)
	      :draw-at-point (ns-make-point 0.0f0 0.0f0)
	      :with-attributes *modeline-text-attributes*)))))

;;; Draw the underlying buffer's modeline string on a white background
;;; with a bezeled border around it.
(define-objc-method ((:void :draw-rect (:<NSR>ect rect)) 
                     modeline-view)
  (declare (ignore rect))
  (slet ((frame (send self 'bounds)))
     (#_NSDrawWhiteBezel frame frame)
     (draw-modeline-string self)))

;;; Hook things up so that the modeline is updated whenever certain buffer
;;; attributes change.
(hi::%init-mode-redisplay)


;;; Modeline-scroll-view

;;; This is just an NSScrollView that draws a "placard" view (the modeline)
;;; in the horizontal scrollbar.  The modeline's arbitrarily given the
;;; leftmost 75% of the available real estate.
(defclass modeline-scroll-view (ns:ns-scroll-view)
    ((modeline :foreign-type :id :accessor scroll-view-modeline)
     (pane :foreign-type :id :accessor scroll-view-pane))
  (:metaclass ns:+ns-object))

;;; Making an instance of a modeline scroll view instantiates the
;;; modeline view, as well.

(define-objc-method ((:id :init-with-frame (:<NSR>ect frame))
                     modeline-scroll-view)
    (let* ((v (send-super :init-with-frame frame)))
      (when v
        (let* ((modeline (make-objc-instance 'modeline-view)))
          (send v :add-subview modeline)
          (setf (scroll-view-modeline v) modeline)))
      v))

;;; Scroll views use the "tile" method to lay out their subviews.
;;; After the next-method has done so, steal some room in the horizontal
;;; scroll bar and place the modeline view there.

(define-objc-method ((:void tile) modeline-scroll-view)
  (send-super 'tile)
  (let* ((modeline (scroll-view-modeline self)))
    (when (and (send self 'has-horizontal-scroller)
               (not (%null-ptr-p modeline)))
      (let* ((hscroll (send self 'horizontal-scroller)))
        (slet ((scrollbar-frame (send hscroll 'frame))
               (modeline-frame (send hscroll 'frame))) ; sic
           (let* ((modeline-width (* (pref modeline-frame
                                           :<NSR>ect.size.width)
                                     0.75e0)))
             (declare (single-float modeline-width))
             (setf (pref modeline-frame :<NSR>ect.size.width)
                   modeline-width
                   (the single-float
                     (pref scrollbar-frame :<NSR>ect.size.width))
                   (- (the single-float
                        (pref scrollbar-frame :<NSR>ect.size.width))
                      modeline-width)
                   (the single-float
                     (pref scrollbar-frame :<NSR>ect.origin.x))
                   (+ (the single-float
                        (pref scrollbar-frame :<NSR>ect.origin.x))
                      modeline-width))
             (send hscroll :set-frame scrollbar-frame)
             (send modeline :set-frame modeline-frame)))))))


;;; Text-pane

;;; The text pane is just an NSBox that (a) provides a draggable border
;;; around (b) encapsulates the text view and the mode line.

(defclass text-pane (ns:ns-box)
    ((text-view :foreign-type :id :accessor text-pane-text-view)
     (mode-line :foreign-type :id :accessor text-pane-mode-line)
     (scroll-view :foreign-type :id :accessor text-pane-scroll-view))
  (:metaclass ns:+ns-object))

;;; Mark the pane's modeline as needing display.  This is called whenever
;;; "interesting" attributes of a buffer are changed.

(defun hi::invalidate-modeline (pane)
  (send (text-pane-mode-line pane) :set-needs-display t))

(define-objc-method ((:id :init-with-frame (:<NSR>ect frame))
                     text-pane)
    (let* ((pane (send-super :init-with-frame frame)))
      (unless (%null-ptr-p pane)
        (send pane :set-autoresizing-mask (logior
                                           #$NSViewWidthSizable
                                           #$NSViewHeightSizable))
        (send pane :set-box-type #$NSBoxPrimary)
        (send pane :set-border-type #$NSLineBorder)
        (send pane :set-title-position #$NSNoTitle))
      pane))


(defun make-scrolling-text-view-for-textstorage (textstorage x y width height tracks-width)
  (slet ((contentrect (ns-make-rect x y width height)))
    (let* ((scrollview (send (make-objc-instance
			      'modeline-scroll-view
			      :with-frame contentrect) 'autorelease)))
      (send scrollview :set-border-type #$NSBezelBorder)
      (send scrollview :set-has-vertical-scroller t)
      (send scrollview :set-has-horizontal-scroller t)
      (send scrollview :set-rulers-visible nil)
      (send scrollview :set-autoresizing-mask (logior
					       #$NSViewWidthSizable
					       #$NSViewHeightSizable))
      (send (send scrollview 'content-view) :set-autoresizes-subviews t)
      (let* ((layout (make-objc-instance 'ns-layout-manager)))
	(send textstorage :add-layout-manager layout)
	(send layout 'release)
	(slet* ((contentsize (send scrollview 'content-size))
		(containersize (ns-make-size
				1.0f7
				1.0f7))
		(tv-frame (ns-make-rect
			   0.0f0
			   0.0f0
			   (pref contentsize :<NSS>ize.width)
			   (pref contentsize :<NSS>ize.height))))
          (let* ((container (send (make-objc-instance
				   'ns-text-container
				   :with-container-size containersize)
				  'autorelease)))
	    (send layout :add-text-container container)
	    (let* ((tv (send (make-objc-instance 'hemlock-text-view
						 :with-frame tv-frame
						 :text-container container)
			     'autorelease)))
	      (send tv :set-min-size (ns-make-size
				      0.0f0
				      (pref contentsize :<NSS>ize.height)))
	      (send tv :set-max-size (ns-make-size 1.0f7 1.0f7))
	      (send tv :set-rich-text nil)
	      (send tv :set-horizontally-resizable t)
	      (send tv :set-vertically-resizable t) 
	      (send tv :set-autoresizing-mask #$NSViewWidthSizable)
	      (send container :set-width-tracks-text-view tracks-width)
	      (send container :set-height-tracks-text-view nil)
	      (send scrollview :set-document-view tv)	      
	      (values tv scrollview))))))))

(defun make-scrolling-textview-for-pane (pane textstorage track-widht)
  (slet ((contentrect (send (send pane 'content-view) 'frame)))
    (multiple-value-bind (tv scrollview)
	(make-scrolling-text-view-for-textstorage
	 textstorage
	 (pref contentrect :<NSR>ect.origin.x)
	 (pref contentrect :<NSR>ect.origin.y)
	 (pref contentrect :<NSR>ect.size.width)
	 (pref contentrect :<NSR>ect.size.height)
	 track-widht)
      (send pane :set-content-view scrollview)
      (setf (slot-value pane 'scroll-view) scrollview
            (slot-value pane 'text-view) tv
            (slot-value tv 'pane) pane
            (slot-value scrollview 'pane) pane)
      (let* ((modeline  (scroll-view-modeline scrollview)))
        (setf (slot-value pane 'mode-line) modeline
              (slot-value modeline 'pane) pane))
      tv)))


(defmethod hemlock-frame-command-info ((w ns:ns-window))
  nil)


(defclass hemlock-frame (ns:ns-window)
    ((command-info :initform (hi::make-command-interpreter-info)
		   :accessor hemlock-frame-command-info))
  (:metaclass ns:+ns-object))


(defmethod shared-initialize :after ((w hemlock-frame)
				     slot-names
				     &key &allow-other-keys)
  (declare (ignore slot-names))
  (let ((info (hemlock-frame-command-info w)))
    (when info
      (setf (hi::command-interpreter-info-frame info) w))))


(defun get-cocoa-window-flag (w flagname)
  (case flagname
    (:accepts-mouse-moved-events
     (send w 'accepts-mouse-moved-events))
    (:cursor-rects-enabled
     (send w 'are-cursor-rects-enabled))
    (:auto-display
     (send w 'is-autodisplay))))



(defun (setf get-cocoa-window-flag) (value w flagname)
  (case flagname
    (:accepts-mouse-moved-events
     (send w :set-accepts-mouse-moved-events value))
    (:auto-display
     (send w :set-autodisplay value))))



(defun activate-window (w)
  ;; Make w the "key" and frontmost window.  Make it visible, if need be.
  (send w :make-key-and-order-front nil))

(defun new-hemlock-document-window (&key
                                    (x 200.0)
                                    (y 200.0)
                                    (height 200.0)
                                    (width 500.0)
                                    (closable t)
                                    (iconifyable t)
                                    (metal t)
                                    (expandable t)
                                    (backing :buffered)
                                    (defer nil)
                                    (accepts-mouse-moved-events nil)
                                    (auto-display t)
                                    (activate t))
  (rlet ((frame :<NSR>ect :origin.x (float x) :origin.y (float y) :size.width (float width) :size.height (float height)))
    (let* ((stylemask
            (logior #$NSTitledWindowMask
                    (if closable #$NSClosableWindowMask 0)
                    (if iconifyable #$NSMiniaturizableWindowMask 0)
                    (if expandable #$NSResizableWindowMask 0)
		    (if metal #$NSTexturedBackgroundWindowMask 0)))
           (backing-type
            (ecase backing
              ((t :retained) #$NSBackingStoreRetained)
              ((nil :nonretained) #$NSBackingStoreNonretained)
              (:buffered #$NSBackingStoreBuffered)))
           (w (make-instance
	       'hemlock-frame
	       :with-content-rect frame
	       :style-mask stylemask
	       :backing backing-type
	       :defer defer)))
      (setf (get-cocoa-window-flag w :accepts-mouse-moved-events)
            accepts-mouse-moved-events
            (get-cocoa-window-flag w :auto-display)
            auto-display)
      (when activate (activate-window w))
      (values w (add-pane-to-window w :reserve-below 20.0)))))



(defun add-pane-to-window (w &key (reserve-above 0.0f0) (reserve-below 0.0f0))
  (let* ((window-content-view (send w 'content-view)))
    (slet ((window-frame (send window-content-view 'frame)))
      (slet ((pane-rect (ns-make-rect 0.0f0
				      reserve-below
				      (pref window-frame :<NSR>ect.size.width)
				      (- (pref window-frame :<NSR>ect.size.height) (+ reserve-above reserve-below)))))
	(let* ((pane (make-objc-instance 'text-pane :with-frame pane-rect)))
	  (send window-content-view :add-subview pane)
	  pane)))))


	  
					
				      
(defun textpane-for-textstorage (ts ncols nrows container-tracks-text-view-width)
  (let* ((pane (nth-value
                1
                (new-hemlock-document-window :activate nil)))
         (tv (make-scrolling-textview-for-pane pane ts container-tracks-text-view-width)))
    (multiple-value-bind (height width)
        (size-of-char-in-font (default-font))
      (size-textview-containers tv height width nrows ncols))
    pane))


(defun read-file-to-hemlock-buffer (path)
  (hemlock::find-file-buffer path))

(defun hemlock-buffer-from-nsstring (nsstring name &rest modes)
  (let* ((buffer (make-hemlock-buffer name :modes modes)))
    (nsstring-to-buffer nsstring buffer)))

(defun nsstring-to-buffer (nsstring buffer)
  (let* ((document (hi::buffer-document buffer)))
    (setf (hi::buffer-document buffer) nil)
    (unwind-protect
	 (progn
	   (hi::delete-region (hi::buffer-region buffer))
	   (hi::modifying-buffer buffer)
	   (hi::with-mark ((mark (hi::buffer-point buffer) :left-inserting))
	     (let* ((string-len (send nsstring 'length))
		    (line-start 0)
		    (first-line-terminator ())
		    (first-line (hi::mark-line mark))
		    (previous first-line)
		    (buffer (hi::line-%buffer first-line)))
	       (slet ((remaining-range (ns-make-range 0 1)))
		 (rlet ((line-end-index :unsigned)
			(contents-end-index :unsigned))
		   (do* ((number (+ (hi::line-number first-line) hi::line-increment)
				 (+ number hi::line-increment)))
			((= line-start string-len)
			 (let* ((line (hi::mark-line mark)))
			   (hi::insert-string mark (make-string 0))
			   (setf (hi::line-next previous) line
				 (hi::line-previous line) previous))
			 nil)
		     (setf (pref remaining-range :<NSR>ange.location) line-start)
		     (send nsstring
			   :get-line-start (%null-ptr)
			   :end line-end-index
			   :contents-end contents-end-index
			   :for-range remaining-range)
		     (let* ((contents-end (pref contents-end-index :unsigned))
			    (line-end (pref line-end-index :unsigned))
			    (chars (make-string (- contents-end line-start))))
		       (do* ((i line-start (1+ i))
			     (j 0 (1+ j)))
			    ((= i contents-end))
			 (setf (schar chars j) (code-char (send nsstring :character-at-index i))))
		       (unless first-line-terminator
			 (let* ((terminator (code-char
					     (send nsstring :character-at-index
						   contents-end))))
			   (setq first-line-terminator
				 (case terminator
				   (#\return (if (= line-end (+ contents-end 2))
					       :cp/m
					       :macos))
				   (t :unix)))))
		       (if (eq previous first-line)
			 (progn
			   (hi::insert-string mark chars)
			   (hi::insert-character mark #\newline)
			   (setq first-line nil))
			 (if (eq string-len contents-end)
			   (hi::insert-string mark chars)
			   (let* ((line (hi::make-line
					 :previous previous
					 :%buffer buffer
					 :chars chars
					 :number number)))
			     (setf (hi::line-next previous) line)
			     (setq previous line))))
		       (setq line-start line-end)))))
	       (when first-line-terminator
		 (setf (hi::buffer-external-format buffer) first-line-terminator))))
	   (setf (hi::buffer-modified buffer) nil)
	   (hi::buffer-start (hi::buffer-point buffer))
	   buffer)
      (setf (hi::buffer-document buffer) document))))

(setq hi::*beep-function* #'(lambda (stream)
			      (declare (ignore stream))
			      (#_NSBeep)))


;;; This function must run in the main event thread.
(defun %hemlock-frame-for-textstorage (ts ncols nrows container-tracks-text-view-width)
  (let* ((pane (textpane-for-textstorage ts ncols nrows container-tracks-text-view-width)))
    (send pane 'window)))


(defun hemlock-frame-for-textstorage (ts ncols nrows container-tracks-text-view-width)
  (process-interrupt *cocoa-event-process*
                     #'%hemlock-frame-for-textstorage
                     ts  ncols nrows container-tracks-text-view-width))


(defun for-each-textview-using-storage (textstorage f)
  (let* ((layouts (send textstorage 'layout-managers)))
    (unless (%null-ptr-p layouts)
      (dotimes (i (send layouts 'count))
	(let* ((layout (send layouts :object-at-index i))
	       (containers (send layout 'text-containers)))
	  (unless (%null-ptr-p containers)
	    (dotimes (j (send containers 'count))
	      (let* ((container (send containers :object-at-index j))
		     (tv (send container 'text-view)))
		(funcall f tv)))))))))


  
(defun hi::document-begin-editing (document)
  (send (slot-value document 'textstorage) 'begin-editing))

(defun hi::document-end-editing (document)
  (let* ((textstorage (slot-value document 'textstorage)))
    (send textstorage 'end-editing)
    (for-each-textview-using-storage
     textstorage
     #'(lambda (tv)
         (send tv :scroll-range-to-visible (send tv 'selected-range))))))

(defun hi::document-set-point-position (document)
  (let* ((textstorage (slot-value document 'textstorage))
	 (string (send textstorage 'string))
	 (buffer (buffer-cache-buffer (hemlock-buffer-string-cache string)))
	 (point (hi::buffer-point buffer))
	 (pos (mark-absolute-position point)))
    (for-each-textview-using-storage
     textstorage
     #'(lambda (tv)
         (slet ((selection (ns-make-range pos 0)))
          (send tv :set-selected-range selection))))))


(defun textstorage-note-insertion-at-position (textstorage pos n)
  (send textstorage
	:edited #$NSTextStorageEditedAttributes
	:range (ns-make-range pos 0)
	:change-in-length n)
  (send textstorage
	:edited #$NSTextStorageEditedCharacters
	:range (ns-make-range pos n)
	:change-in-length 0))

(defun hi::buffer-note-insertion (buffer mark n)
  (when (hi::bufferp buffer)
    (let* ((document (hi::buffer-document buffer))
	   (textstorage (if document (slot-value document 'textstorage))))
      (when textstorage
        (let* ((pos (mark-absolute-position mark)))
          (unless (eq (hi::mark-%kind mark) :right-inserting)
            (decf pos n))
          #+debug
	  (format t "~&insert: pos = ~d, n = ~d" pos n)
          (let* ((display (hemlock-buffer-string-cache (send textstorage 'string))))
            (reset-buffer-cache display) 
            (update-line-cache-for-index display pos))
	  (textstorage-note-insertion-at-position textstorage pos n))))))

  

(defun hi::buffer-note-deletion (buffer mark n)
  (when (hi::bufferp buffer)
    (let* ((document (hi::buffer-document buffer))
	   (textstorage (if document (slot-value document 'textstorage))))
      (when textstorage
        (let* ((pos (mark-absolute-position mark)))
          (setq n (abs n))
          #+debug
          (format t "~& pos = ~d, n = ~d" pos n)
          (force-output)
	  (send textstorage
                :edited #$NSTextStorageEditedCharacters
                :range (ns-make-range pos n)
                :change-in-length (- n))
          (let* ((cache (hemlock-buffer-string-cache (send textstorage 'string))))
            (reset-buffer-cache cache) 
            (update-line-cache-for-index cache pos)))))))

(defun hi::set-document-modified (document flag)
  (send document
	:update-change-count (if flag #$NSChangeDone #$NSChangeCleared)))


(defun hi::document-panes (document)
  (let* ((ts (slot-value document 'textstorage))
	 (panes ()))
    (for-each-textview-using-storage
     ts
     #'(lambda (tv)
	 (let* ((pane (text-view-pane tv)))
	   (unless (%null-ptr-p pane)
	     (push pane panes)))))
    panes))

    

(defun size-of-char-in-font (f)
  (let* ((sf (send f 'screen-font)))
    (if (%null-ptr-p sf) (setq sf f))
    (values (send sf 'default-line-height-for-font)
	    (send sf :width-of-string #@" "))))
         
    
(defun get-size-for-textview (font nrows ncols)
  (multiple-value-bind (h w) (size-of-char-in-font font)
    (values (fceiling (* nrows h))
	    (fceiling (* ncols w)))))


(defun size-textview-containers (tv char-height char-width nrows ncols)
  (let* ((height (fceiling (* nrows char-height)))
	 (width (fceiling (* ncols char-width)))
	 (scrollview (send (send tv 'superview) 'superview))
	 (window (send scrollview 'window)))
    (rlet ((tv-size :<NSS>ize :height height
		    :width (+ width (* 2 (send (send tv 'text-container)
		      'line-fragment-padding)))))
      (when (send scrollview 'has-vertical-scroller)
	(send scrollview :set-vertical-line-scroll char-height)
	(send scrollview :set-vertical-page-scroll char-height))
      (slet ((sv-size
	      (send (@class ns-scroll-view)
		    :frame-size-for-content-size tv-size
		    :has-horizontal-scroller
		    (send scrollview 'has-horizontal-scroller)
		    :has-vertical-scroller
		    (send scrollview 'has-vertical-scroller)
		    :border-type (send scrollview 'border-type))))
	(slet ((sv-frame (send scrollview 'frame)))
	  (incf (pref sv-size :<NSS>ize.height)
		(pref sv-frame :<NSR>ect.origin.y))
	  (send window :set-content-size sv-size)
	  (send window :set-resize-increments
		(ns-make-size char-width char-height)))))))
				    
  
(defclass lisp-editor-window-controller (ns:ns-window-controller)
    ()
  (:metaclass ns:+ns-object))

    
;;; The LispEditorWindowController is the textview's "delegate": it
;;; gets consulted before certain actions are performed, and can
;;; perform actions on behalf of the textview.



;;; The LispEditorDocument class.


(defclass lisp-editor-document (ns:ns-document)
    ((textstorage :foreign-type :id))
  (:metaclass ns:+ns-object))

(define-objc-method ((:id init) lisp-editor-document)
  (let* ((doc (send-super 'init)))
    (unless (%null-ptr-p doc)
      (let* ((buffer (make-hemlock-buffer
		      (lisp-string-from-nsstring (send doc 'display-name))
		      :modes '("Lisp"))))
	(setf (slot-value doc 'textstorage)
	      (make-textstorage-for-hemlock-buffer buffer)
	      (hi::buffer-document buffer) doc)))
    doc))
                     

(define-objc-method ((:id :read-from-file filename
			  :of-type type)
		     lisp-editor-document)
  (declare (ignorable type))
  (let* ((pathname (lisp-string-from-nsstring filename))
	 (buffer-name (hi::pathname-to-buffer-name pathname))
	 (buffer (or
		  (hemlock-document-buffer self)
		  (let* ((b (make-hemlock-buffer buffer-name)))
		    (setf (hi::buffer-pathname b) pathname)
		    (setf (slot-value self 'textstorage)
			  (make-textstorage-for-hemlock-buffer b))
		    b)))
	 (data (make-objc-instance 'ns:ns-data
				   :with-contents-of-file filename))
	 (string (make-objc-instance 'ns:ns-string
				     :with-data data
				     :encoding #$NSASCIIStringEncoding)))
    (hi::document-begin-editing self)
    (nsstring-to-buffer string buffer)
    (let* ((textstorage (slot-value self 'textstorage))
	   (display (hemlock-buffer-string-cache (send textstorage 'string))))
      (reset-buffer-cache display) 
      (update-line-cache-for-index display 0)
      (textstorage-note-insertion-at-position
       textstorage
       0
       (hemlock-buffer-length buffer)))
    (hi::document-end-editing self)
    (setf (hi::buffer-modified buffer) nil)
    (hi::process-file-options buffer pathname)
    self))
    
  
(defmethod hemlock-document-buffer (document)
  (let* ((string (send (slot-value document 'textstorage) 'string)))
    (unless (%null-ptr-p string)
      (let* ((cache (hemlock-buffer-string-cache string)))
	(when cache (buffer-cache-buffer cache))))))

(define-objc-method ((:id :data-representation-of-type type)
		      lisp-editor-document)
  (declare (ignorable type))
  (let* ((buffer (hemlock-document-buffer self)))
    (when buffer
      (setf (hi::buffer-modified buffer) nil)))
  (send (send (slot-value self 'textstorage) 'string)
	:data-using-encoding #$NSASCIIStringEncoding
	:allow-lossy-conversion t))


;;; Shadow the setFileName: method, so that we can keep the buffer
;;; name and pathname in synch with the document.
(define-objc-method ((:void :set-file-name full-path)
		     lisp-editor-document)
  (send-super :set-file-name full-path)
  (let* ((buffer (hemlock-document-buffer self)))
    (when buffer
      (let* ((new-pathname (lisp-string-from-nsstring full-path)))
	(setf (hi::buffer-name buffer) (hi::pathname-to-buffer-name new-pathname))
	(setf (hi::buffer-pathname buffer) new-pathname)))))
  
(define-objc-method ((:void make-window-controllers) lisp-editor-document)
  (let* ((controller (make-objc-instance
		      'lisp-editor-window-controller
		      :with-window (%hemlock-frame-for-textstorage 
                                    (slot-value self 'textstorage)
				    *editor-columns*
				    *editor-rows*
				    nil))))
    (send self :add-window-controller controller)
    (send controller 'release)))	 

#|
(define-objc-method ((:void :window-controller-did-load-nib acontroller)
		     lisp-editor-document)
  (send-super :window-controller-did-load-nib  acontroller)
  ;; Apple/NeXT thinks that adding extra whitespace around cut & pasted
  ;; text is "smart".  Really, really smart insertion and deletion
  ;; would alphabetize the selection for you (byChars: or byWords:);
  ;; sadly, if you want that behavior you'll have to do it yourself.
  ;; Likewise with the extra spaces.
  (with-slots (text-view echoarea packagename filedata) self
    (send text-view :set-alignment  #$NSNaturalTextAlignment)
    (send text-view :set-smart-insert-delete-enabled nil)
    (send text-view :set-rich-text nil)
    (send text-view :set-uses-font-panel t)
    (send text-view :set-uses-ruler nil)
    (with-lock-grabbed (*open-editor-documents-lock*)
      (push (make-cocoa-editor-info
	     :document (%setf-macptr (%null-ptr) self)
	     :controller (%setf-macptr (%null-ptr) acontroller)
	     :listener nil)
	    *open-editor-documents*))
    (setf (slot-value acontroller 'textview) text-view
	  (slot-value acontroller 'echoarea) echoarea
	  (slot-value acontroller 'packagename) packagename)
    (send text-view :set-delegate acontroller)
    (let* ((font (default-font)))
      (multiple-value-bind (height width)
	  (size-of-char-in-font font)
	(size-textview-containers text-view height width 24 80))
      (send text-view
	    :set-typing-attributes
	    (create-text-attributes
	     :font font
	     :color (send (@class ns-color) 'black-color)))
      (unless (%null-ptr-p filedata)
	(send text-view
	      :replace-characters-in-range (ns-make-range 0 0)
	      :with-string (make-objc-instance
			    'ns-string
			    :with-data filedata
			    :encoding #$NSASCIIStringEncoding))
))))
|#

(define-objc-method ((:void close) lisp-editor-document)
  (let* ((textstorage (slot-value self 'textstorage)))
    (setf (slot-value self 'textstorage) (%null-ptr))
    (unless (%null-ptr-p textstorage)
      (close-hemlock-textstorage textstorage)))
    (send-super 'close))


(provide "COCOA-EDITOR")
