;;;-*- Mode: LISP; Package: CCL -*-


(in-package "CCL")

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require "COCOA-WINDOW")
  (require "HEMLOCK"))

(eval-when (:compile-toplevel :execute)
  (use-interface-dir :cocoa))

;;; In the double-float case, this is probably way too small.
;;; Traditionally, it's (approximately) the point at which
;;; a single-float stops being able to accurately represent
;;; integral values.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defconstant large-number-for-text (float 1.0f7 +cgfloat-zero+)))

(def-cocoa-default *editor-rows* :int 24 "Initial height of editor windows, in characters")
(def-cocoa-default *editor-columns* :int 80 "Initial width of editor windows, in characters")

(def-cocoa-default *editor-background-color* :color '(1.0 1.0 1.0 1.0) "Editor background color")

(defmacro nsstring-encoding-to-nsinteger (n)
  (target-word-size-case
   (32 `(u32->s32 ,n))
   (64 n)))

(defmacro nsinteger-to-nsstring-encoding (n)
  (target-word-size-case
   (32 `(s32->u32 ,n))
   (64 n)))

(defun make-editor-style-map ()
  (let* ((font-name *default-font-name*)
	 (font-size *default-font-size*)
         (font (default-font :name font-name :size font-size))
         (bold-font (let* ((f (default-font :name font-name :size font-size :attributes '(:bold))))
                      (unless (eql f font) f)))
         (oblique-font (let* ((f (default-font :name font-name :size font-size :attributes '(:italic))))
                      (unless (eql f font) f)))
         (bold-oblique-font (let* ((f (default-font :name font-name :size font-size :attributes '(:bold :italic))))
                      (unless (eql f font) f)))
	 (color-class (find-class 'ns:ns-color))
	 (colors (vector (#/blackColor color-class)))
	 (styles (make-instance 'ns:ns-mutable-array
                                :with-capacity (the fixnum (* 4 (length colors)))))
         (bold-stroke-width -10.0f0)
         (fonts (vector font (or bold-font font) (or oblique-font font) (or bold-oblique-font font)))
         (real-fonts (vector font bold-font oblique-font bold-oblique-font))
	 (s 0))
    (declare (dynamic-extent fonts real-fonts colors))
    (dotimes (c (length colors))
      (dotimes (i 4)
        (let* ((mask (logand i 3)))
          (#/addObject: styles
                        (create-text-attributes :font (svref fonts mask)
                                                :color (svref colors c)
                                                :obliqueness
                                                (if (logbitp 1 i)
                                                  (unless (svref real-fonts mask)
                                                    0.15f0))
                                                :stroke-width
                                                (if (logbitp 0 i)
                                                  (unless (svref real-fonts mask)
                                                    bold-stroke-width)))))
	(incf s)))
    (#/retain styles)))

(defun make-hemlock-buffer (&rest args)
  (let* ((buf (apply #'hi::make-buffer args)))
    (if buf
      (progn
	(setf (hi::buffer-gap-context buf) (hi::make-buffer-gap-context))
	buf)
      (progn
	(format t "~& couldn't make hemlock buffer with args ~s" args)
	;;(dbg)
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
  workline-start-font-index		; current font index at start of workline
  )

;;; Initialize (or reinitialize) a buffer cache, so that it points
;;; to the buffer's first line (which is the only line whose
;;; absolute position will never change).  Code which modifies the
;;; buffer generally has to call this, since any cached information
;;; might be invalidated by the modification.

(defun reset-buffer-cache (d &optional (buffer (buffer-cache-buffer d)
						buffer-p))
  (when buffer-p (setf (buffer-cache-buffer d) buffer))
  (let* ((hi::*buffer-gap-context* (hi::buffer-gap-context buffer))
         (workline (hi::mark-line
		    (hi::buffer-start-mark buffer))))
    (setf (buffer-cache-buflen d) (hemlock-buffer-length buffer)
	  (buffer-cache-workline-offset d) 0
	  (buffer-cache-workline d) workline
	  (buffer-cache-workline-length d) (hi::line-length workline)
	  (buffer-cache-workline-start-font-index d) 0)
    d))


(defun adjust-buffer-cache-for-insertion (display pos n)
  (if (buffer-cache-workline display)
    (let* ((hi::*buffer-gap-context* (hi::buffer-gap-context (buffer-cache-buffer display))))
      (if (> (buffer-cache-workline-offset display) pos)
        (incf (buffer-cache-workline-offset display) n)
        (when (>= (+ (buffer-cache-workline-offset display)
                     (buffer-cache-workline-length display))
                  pos)
          (setf (buffer-cache-workline-length display)
                (hi::line-length (buffer-cache-workline display)))))
      (incf (buffer-cache-buflen display) n))
    (reset-buffer-cache display)))

          
           

;;; Update the cache so that it's describing the current absolute
;;; position.

(defun update-line-cache-for-index (cache index)
  (let* ((buffer (buffer-cache-buffer cache))
         (hi::*buffer-gap-context* (hi::buffer-gap-context buffer))
         (line (or
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
	(setq line (hi::line-previous line)
	      len (hi::line-length line)
	      pos (1- (- pos len)))
	(setq line (hi::line-next line)
	      pos (1+ (+ pos len))
	      len (hi::line-length line))))))

;;; Ask Hemlock to count the characters in the buffer.
(defun hemlock-buffer-length (buffer)
  (let* ((hi::*buffer-gap-context* (hi::buffer-gap-context buffer)))
    (hemlock::count-characters (hemlock::buffer-region buffer))))

;;; Find the line containing (or immediately preceding) index, which is
;;; assumed to be less than the buffer's length.  Return the character
;;; in that line or the trailing #\newline, as appropriate.
(defun hemlock-char-at-index (cache index)
  (let* ((hi::*buffer-gap-context*
          (hi::buffer-gap-context (buffer-cache-buffer cache))))
    (multiple-value-bind (line idx) (update-line-cache-for-index cache index)
      (let* ((len (hemlock::line-length line)))
        (if (< idx len)
          (hemlock::line-character line idx)
          #\newline)))))

;;; Given an absolute position, move the specified mark to the appropriate
;;; offset on the appropriate line.
(defun move-hemlock-mark-to-absolute-position (mark cache abspos)
  (let* ((hi::*buffer-gap-context*
          (hi::buffer-gap-context (buffer-cache-buffer cache))))
    (multiple-value-bind (line idx) (update-line-cache-for-index cache abspos)
      #+debug
      (#_NSLog #@"Moving point from current pos %d to absolute position %d"
               :int (mark-absolute-position mark)
               :int abspos)
      (hemlock::move-to-position mark idx line)
      #+debug
      (#_NSLog #@"Moved mark to %d" :int (mark-absolute-position mark)))))

;;; Return the absolute position of the mark in the containing buffer.
;;; This doesn't use the caching mechanism, so it's always linear in the
;;; number of preceding lines.
(defun mark-absolute-position (mark)
  (let* ((pos (hi::mark-charpos mark))
         (hi::*buffer-gap-context*
          (hi::buffer-gap-context (hi::line-%buffer (hi::mark-line mark)))))
    (+ (hi::get-line-origin (hi::mark-line mark)) pos)))

;;; Return the length of the abstract string, i.e., the number of
;;; characters in the buffer (including implicit newlines.)
(objc:defmethod (#/length :<NSUI>nteger) ((self hemlock-buffer-string))
  (let* ((cache (hemlock-buffer-string-cache self)))
    (or (buffer-cache-buflen cache)
        (setf (buffer-cache-buflen cache)
              (let* ((buffer (buffer-cache-buffer cache)))
		(hemlock-buffer-length buffer))))))



;;; Return the character at the specified index (as a :unichar.)

(objc:defmethod (#/characterAtIndex: :unichar)
    ((self hemlock-buffer-string) (index :<NSUI>nteger))
  #+debug
  (#_NSLog #@"Character at index: %d" :<NSUI>nteger index)
  (char-code (hemlock-char-at-index (hemlock-buffer-string-cache self) index)))

(objc:defmethod (#/getCharacters:range: :void)
    ((self hemlock-buffer-string)
     (buffer (:* :unichar))
     (r :<NSR>ange))
  (let* ((cache (hemlock-buffer-string-cache self))
         (index (ns:ns-range-location r))
         (length (ns:ns-range-length r))
         (hi::*buffer-gap-context*
          (hi::buffer-gap-context (buffer-cache-buffer cache))))
    #+debug
    (#_NSLog #@"get characters: %d/%d"
             :<NSUI>nteger index
             :<NSUI>nteger length)
    (multiple-value-bind (line idx) (update-line-cache-for-index cache index)
      (let* ((len (hemlock::line-length line)))
        (do* ((i 0 (1+ i)))
             ((= i length))
          (cond ((< idx len)
                 (setf (paref buffer (:* :unichar) i)
                       (char-code (hemlock::line-character line idx)))
                 (incf idx))
                (t
                 (setf (paref buffer (:* :unichar) i)
                       (char-code #\Newline)
                       line (hi::line-next line)
                       len (if line (hi::line-length line) 0)
                       idx 0))))))))

(objc:defmethod (#/getLineStart:end:contentsEnd:forRange: :void)
    ((self hemlock-buffer-string)
     (startptr (:* :<NSUI>nteger))
     (endptr (:* :<NSUI>nteger))
     (contents-endptr (:* :<NSUI>nteger))
     (r :<NSR>ange))
  (let* ((cache (hemlock-buffer-string-cache self))
         (index (pref r :<NSR>ange.location))
         (length (pref r :<NSR>ange.length))
         (hi::*buffer-gap-context*
	  (hi::buffer-gap-context (buffer-cache-buffer cache))))
    #+debug
    (#_NSLog #@"get line start: %d/%d"
             :unsigned index
             :unsigned length)
    (update-line-cache-for-index cache index)
    (unless (%null-ptr-p startptr)
      ;; Index of the first character in the line which contains
      ;; the start of the range.
      (setf (pref startptr :<NSUI>nteger)
            (buffer-cache-workline-offset cache)))
    (unless (%null-ptr-p endptr)
      ;; Index of the newline which terminates the line which
      ;; contains the start of the range.
      (setf (pref endptr :<NSUI>nteger)
            (+ (buffer-cache-workline-offset cache)
               (buffer-cache-workline-length cache))))
    (unless (%null-ptr-p contents-endptr)
      ;; Index of the newline which terminates the line which
      ;; contains the start of the range.
      (unless (zerop length)
        (update-line-cache-for-index cache (+ index length)))
      (setf (pref contents-endptr :<NSUI>nteger)
            (1+ (+ (buffer-cache-workline-offset cache)
                   (buffer-cache-workline-length cache)))))))

                     



;;; For debugging, mostly: make the printed representation of the string
;;; referenence the named Hemlock buffer.
(objc:defmethod #/description ((self hemlock-buffer-string))
  (let* ((cache (hemlock-buffer-string-cache self))
	 (b (buffer-cache-buffer cache)))
    (with-cstrs ((s (format nil "~a" b)))
      (#/stringWithFormat: ns:ns-string #@"<%s for %s>" (#_object_getClassName self) s))))



;;; hemlock-text-storage objects
(defclass hemlock-text-storage (ns:ns-text-storage)
    ((string :foreign-type :id)
     (hemlock-string :foreign-type :id)
     (edit-count :foreign-type :int)
     (mirror :foreign-type :id)
     (styles :foreign-type :id)
     (selection-set-by-search :foreign-type :<BOOL>))
  (:metaclass ns:+ns-object))


;;; This is only here so that calls to it can be logged for debugging.
#+debug
(objc:defmethod (#/lineBreakBeforeIndex:withinRange: :<NSUI>nteger)
    ((self hemlock-text-storage)
     (index :<NSUI>nteger)
     (r :<NSR>ange))
  (#_NSLog #@"Line break before index: %d within range: %@"
           :unsigned index
           :id (#_NSStringFromRange r))
  (call-next-method index r))




;;; Return true iff we're inside a "beginEditing/endEditing" pair
(objc:defmethod (#/editingInProgress :<BOOL>) ((self hemlock-text-storage))
  ;; This is meaningless outside the event thread, since you can't tell what
  ;; other edit-count changes have already been queued up for execution on
  ;; the event thread before it gets to whatever you might queue up next.
  (assume-cocoa-thread)
  (> (slot-value self 'edit-count) 0))

(defmethod assume-not-editing ((ts hemlock-text-storage))
  #+debug (assert (eql (slot-value ts 'edit-count) 0)))

(defun textstorage-note-insertion-at-position (self pos n)
  (ns:with-ns-range (r pos 0)
    (#/edited:range:changeInLength: self #$NSTextStorageEditedAttributes r n)
    (setf (ns:ns-range-length r) n)
    (#/edited:range:changeInLength: self #$NSTextStorageEditedCharacters r 0)))


;;; This runs on the main thread; it synchronizes the "real" NSMutableAttributedString
;;; with the hemlock string and informs the textstorage of the insertion.
(objc:defmethod (#/noteHemlockInsertionAtPosition:length: :void) ((self hemlock-text-storage)
                                                                  (pos :<NSI>nteger)
                                                                  (n :<NSI>nteger)
                                                                  (extra :<NSI>nteger))
  (declare (ignorable extra))
  (assume-cocoa-thread)
  (let* ((mirror (#/mirror self))
         (hemlock-string (#/hemlockString self))
         (display (hemlock-buffer-string-cache hemlock-string))
         (buffer (buffer-cache-buffer display))
         (hi::*buffer-gap-context* (hi::buffer-gap-context buffer))
         (font (buffer-active-font buffer))
         (document (#/document self))
	 (undo-mgr (and document (#/undoManager document))))
    #+debug 
    (#_NSLog #@"insert: pos = %ld, n = %ld" :long pos :long n)
    ;; We need to update the hemlock string mirror here so that #/substringWithRange:
    ;; will work on the hemlock buffer string.
    (adjust-buffer-cache-for-insertion display pos n)
    (update-line-cache-for-index display pos)
    (let* ((replacestring (#/substringWithRange: hemlock-string (ns:make-ns-range pos n))))
      (ns:with-ns-range (replacerange pos 0)
        (#/replaceCharactersInRange:withString:
         mirror replacerange replacestring))
      (when (and undo-mgr (not (#/isUndoing undo-mgr)))
        (#/replaceCharactersAtPosition:length:withString:
	 (#/prepareWithInvocationTarget: undo-mgr self)
	 pos n #@"")))
    (#/setAttributes:range: mirror font (ns:make-ns-range pos n))    
    (textstorage-note-insertion-at-position self pos n)))

(objc:defmethod (#/noteHemlockDeletionAtPosition:length: :void) ((self hemlock-text-storage)
                                                                 (pos :<NSI>nteger)
                                                                 (n :<NSI>nteger)
                                                                 (extra :<NSI>nteger))
  (declare (ignorable extra))
  #+debug
  (#_NSLog #@"delete: pos = %ld, n = %ld" :long pos :long n)
  (ns:with-ns-range (range pos n)
    (let* ((mirror (#/mirror self))
	   (deleted-string (#/substringWithRange: (#/string mirror) range))
	   (document (#/document self))
	   (undo-mgr (and document (#/undoManager document)))
	   (display (hemlock-buffer-string-cache (#/hemlockString self))))
      ;; It seems to be necessary to call #/edited:range:changeInLength: before
      ;; deleting from the mirror attributed string.  It's not clear whether this
      ;; is also true of insertions and modifications.
      (#/edited:range:changeInLength: self (logior #$NSTextStorageEditedCharacters
						   #$NSTextStorageEditedAttributes)
				      range (- n))
      (#/deleteCharactersInRange: mirror range)
      (when (and undo-mgr (not (#/isUndoing undo-mgr)))
        (#/replaceCharactersAtPosition:length:withString:
	 (#/prepareWithInvocationTarget: undo-mgr self)
	 pos 0 deleted-string))
      (reset-buffer-cache display)
      (update-line-cache-for-index display pos))))

(objc:defmethod (#/noteHemlockModificationAtPosition:length: :void) ((self hemlock-text-storage)
                                                                     (pos :<NSI>nteger)
                                                                     (n :<NSI>nteger)
                                                                     (extra :<NSI>nteger))
  (declare (ignorable extra))
  #+debug
  (#_NSLog #@"modify: pos = %ld, n = %ld" :long pos :long n)
  (ns:with-ns-range (range pos n)
    (let* ((hemlock-string (#/hemlockString self))
	   (mirror (#/mirror self))
	   (deleted-string (#/substringWithRange: (#/string mirror) range))
	   (document (#/document self))
	   (undo-mgr (and document (#/undoManager document))))
      (#/replaceCharactersInRange:withString:
       mirror range (#/substringWithRange: hemlock-string range))
      (#/edited:range:changeInLength: self (logior #$NSTextStorageEditedCharacters
                                                   #$NSTextStorageEditedAttributes) range 0)
      (when (and undo-mgr (not (#/isUndoing undo-mgr)))
        (#/replaceCharactersAtPosition:length:withString:
	 (#/prepareWithInvocationTarget: undo-mgr self)
	 pos n deleted-string)))))

(objc:defmethod (#/noteHemlockAttrChangeAtPosition:length: :void) ((self hemlock-text-storage)
                                                                   (pos :<NSI>nteger)
                                                                   (n :<NSI>nteger)
                                                                   (fontnum :<NSI>nteger))
  (ns:with-ns-range (range pos n)
    (#/setAttributes:range: (#/mirror self) (#/objectAtIndex: (#/styles self) fontnum) range)
    (#/edited:range:changeInLength: self #$NSTextStorageEditedAttributes range 0)))

(defloadvar *buffer-change-invocation*
    (with-autorelease-pool
        (#/retain
                   (#/invocationWithMethodSignature: ns:ns-invocation
                                                     (#/instanceMethodSignatureForSelector:
                                                      hemlock-text-storage
                                            (@selector #/noteHemlockInsertionAtPosition:length:))))))

(defstatic *buffer-change-invocation-lock* (make-lock))

         
         
(objc:defmethod (#/beginEditing :void) ((self hemlock-text-storage))
  (assume-cocoa-thread)
  (with-slots (edit-count) self
    #+debug
    (#_NSLog #@"begin-editing")
    (incf edit-count)
    #+debug
    (#_NSLog #@"after beginEditing on %@ edit-count now = %d" :id self :int edit-count)
    (call-next-method)))

(objc:defmethod (#/endEditing :void) ((self hemlock-text-storage))
  (assume-cocoa-thread)
  (with-slots (edit-count) self
    #+debug
    (#_NSLog #@"end-editing")
    (call-next-method)
    (assert (> edit-count 0))
    (decf edit-count)
    #+debug
    (#_NSLog #@"after endEditing on %@, edit-count now = %d" :id self :int edit-count)))



  

;;; Access the string.  It'd be nice if this was a generic function;
;;; we could have just made a reader method in the class definition.



(objc:defmethod #/string ((self hemlock-text-storage))
  (slot-value self 'string))

(objc:defmethod #/mirror ((self hemlock-text-storage))
  (slot-value self 'mirror))

(objc:defmethod #/hemlockString ((self hemlock-text-storage))
  (slot-value self 'hemlock-string))

(objc:defmethod #/styles ((self hemlock-text-storage))
  (slot-value self 'styles))

(objc:defmethod #/document ((self hemlock-text-storage))
  (or
   (let* ((string (#/hemlockString self)))
     (unless (%null-ptr-p string)
       (let* ((cache (hemlock-buffer-string-cache string)))
         (when cache
           (let* ((buffer (buffer-cache-buffer cache)))
             (when buffer
               (hi::buffer-document buffer)))))))
   +null-ptr+))

(objc:defmethod #/initWithString: ((self hemlock-text-storage) s)
  (setq s (%inc-ptr s 0))
  (let* ((newself (#/init self))
         (styles (make-editor-style-map))
         (mirror (#/retain (make-instance ns:ns-mutable-attributed-string
                                   :with-string s
                                   :attributes (#/objectAtIndex: styles 0)))))
    (declare (type hemlock-text-storage newself))
    (setf (slot-value newself 'styles) styles)
    (setf (slot-value newself 'hemlock-string) s)
    (setf (slot-value newself 'mirror) mirror)
    (setf (slot-value newself 'string) (#/retain (#/string mirror)))
    newself))

;;; Should generally only be called after open/revert.
(objc:defmethod (#/updateMirror :void) ((self hemlock-text-storage))
  (with-slots (hemlock-string mirror styles) self
    (#/replaceCharactersInRange:withString: mirror (ns:make-ns-range 0 (#/length mirror)) hemlock-string)
    (#/setAttributes:range: mirror (#/objectAtIndex: styles 0) (ns:make-ns-range 0 (#/length mirror)))))

;;; This is the only thing that's actually called to create a
;;; hemlock-text-storage object.  (It also creates the underlying
;;; hemlock-buffer-string.)
(defun make-textstorage-for-hemlock-buffer (buffer)
  (make-instance 'hemlock-text-storage
                 :with-string
                 (make-instance
                  'hemlock-buffer-string
                  :cache
                  (reset-buffer-cache
                   (make-buffer-cache)
                   buffer))))

(objc:defmethod #/attributesAtIndex:effectiveRange:
    ((self hemlock-text-storage) (index :<NSUI>nteger) (rangeptr (* :<NSR>ange)))
  #+debug
  (#_NSLog #@"Attributes at index: %lu storage %@" :<NSUI>nteger index :id self)
  (with-slots (mirror styles) self
    (when (>= index (#/length mirror))
      (#_NSLog #@"Attributes at index: %lu  edit-count: %d mirror: %@ layout: %@" :<NSUI>nteger index ::unsigned (slot-value self 'edit-count) :id mirror :id (#/objectAtIndex: (#/layoutManagers self) 0))
      (for-each-textview-using-storage self
                                       (lambda (tv)
                                         (let* ((w (#/window tv))
                                                (proc (slot-value w 'command-thread)))
                                           (process-interrupt proc #'dbg))))
      (dbg))
    (let* ((attrs (#/attributesAtIndex:effectiveRange: mirror index rangeptr)))
      (when (eql 0 (#/count attrs))
        (#_NSLog #@"No attributes ?")
        (ns:with-ns-range (r)
          (#/attributesAtIndex:longestEffectiveRange:inRange:
           mirror index r (ns:make-ns-range 0 (#/length mirror)))
          (setq attrs (#/objectAtIndex: styles 0))
          (#/setAttributes:range: mirror attrs r)))
      attrs)))

(objc:defmethod (#/replaceCharactersAtPosition:length:withString: :void)
    ((self hemlock-text-storage) (pos <NSUI>nteger) (len <NSUI>nteger) string)
  (ns:with-ns-range (r pos len)
    (#/replaceCharactersInRange:withString: self r string)))

(objc:defmethod (#/replaceCharactersInRange:withString: :void)
    ((self hemlock-text-storage) (r :<NSR>ange) string)
  #+debug (#_NSLog #@"Replace in range %ld/%ld with %@"
                    :<NSI>nteger (pref r :<NSR>ange.location)
                    :<NSI>nteger (pref r :<NSR>ange.length)
                    :id string)
  (let* ((cache (hemlock-buffer-string-cache (#/hemlockString  self)))
	 (buffer (if cache (buffer-cache-buffer cache)))
         (hi::*buffer-gap-context* (hi::buffer-gap-context buffer))
         (location (pref r :<NSR>ange.location))
	 (length (pref r :<NSR>ange.length))
	 (point (hi::buffer-point buffer)))
    (let* ((lisp-string (if (> (#/length string) 0) (lisp-string-from-nsstring string)))
           (document (if buffer (hi::buffer-document buffer)))
           (textstorage (if document (slot-value document 'textstorage))))
      #+gz (unless (eql textstorage self) (break "why is self.ne.textstorage?"))
      (when textstorage
	(assume-cocoa-thread)
	(#/beginEditing textstorage))
      (setf (hi::buffer-region-active buffer) nil)
      (hi::with-mark ((start point :right-inserting))
        (move-hemlock-mark-to-absolute-position start cache location)
        (unless (zerop length)
          (hi::delete-characters start length))
        (when lisp-string
          (hi::insert-string start lisp-string)))
      (when textstorage
        (#/endEditing textstorage)
        (for-each-textview-using-storage
         textstorage
         (lambda (tv)
           (hi::disable-self-insert
            (hemlock-frame-event-queue (#/window tv)))))
        (#/ensureSelectionVisible textstorage)))))


(objc:defmethod (#/setAttributes:range: :void) ((self hemlock-text-storage)
                                                attributes
                                                (r :<NSR>ange))
  #+debug
  (#_NSLog #@"Set attributes: %@ at %d/%d" :id attributes :int (pref r :<NSR>ange.location) :int (pref r :<NSR>ange.length))
  (with-slots (mirror) self
    (#/setAttributes:range: mirror attributes r)
      #+debug
      (#_NSLog #@"Assigned attributes = %@" :id (#/attributesAtIndex:effectiveRange: mirror (pref r :<NSR>ange.location) +null-ptr+))))

(defun for-each-textview-using-storage (textstorage f)
  (let* ((layouts (#/layoutManagers textstorage)))
    (unless (%null-ptr-p layouts)
      (dotimes (i (#/count layouts))
	(let* ((layout (#/objectAtIndex: layouts i))
	       (containers (#/textContainers layout)))
	  (unless (%null-ptr-p containers)
	    (dotimes (j (#/count containers))
	      (let* ((container (#/objectAtIndex: containers j))
		     (tv (#/textView container)))
		(funcall f tv)))))))))

;;; Again, it's helpful to see the buffer name when debugging.
(objc:defmethod #/description ((self hemlock-text-storage))
  (#/stringWithFormat: ns:ns-string #@"%s : string %@" (#_object_getClassName self) (slot-value self 'hemlock-string)))

;;; This needs to happen on the main thread.
(objc:defmethod (#/ensureSelectionVisible :void) ((self hemlock-text-storage))
  (assume-cocoa-thread)
  (for-each-textview-using-storage
   self
   #'(lambda (tv)
       (assume-not-editing tv)
       (#/scrollRangeToVisible: tv (#/selectedRange tv)))))


(defun close-hemlock-textstorage (ts)
  (declare (type hemlock-text-storage ts))
  (with-slots (styles) ts
    (#/release styles)
    (setq styles +null-ptr+))
  (let* ((hemlock-string (slot-value ts 'hemlock-string)))
    (setf (slot-value ts 'hemlock-string) +null-ptr+)
    
    (unless (%null-ptr-p hemlock-string)
      (let* ((cache (hemlock-buffer-string-cache hemlock-string))
             (buffer (if cache (buffer-cache-buffer cache))))
        (when buffer
          (setf (buffer-cache-buffer cache) nil
                (slot-value hemlock-string 'cache) nil
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


;;; Mostly experimental, so that we can see what happens when a 
;;; real typesetter is used.
(defclass hemlock-ats-typesetter (ns:ns-ats-typesetter)
    ()
  (:metaclass ns:+ns-object))

(objc:defmethod (#/layoutGlyphsInLayoutManager:startingAtGlyphIndex:maxNumberOfLineFragments:nextGlyphIndex: :void)
    ((self hemlock-ats-typesetter)
     layout-manager
     (start-index :<NSUI>nteger)
     (max-lines :<NSUI>nteger)
     (next-index (:* :<NSUI>nteger)))
  (#_NSLog #@"layoutGlyphs: start = %d, maxlines = %d" :int start-index :int max-lines)
  (call-next-method layout-manager start-index max-lines next-index))


;;; An abstract superclass of the main and echo-area text views.
(defclass hemlock-textstorage-text-view (ns::ns-text-view)
    ((blink-location :foreign-type :unsigned :accessor text-view-blink-location)
     (blink-color-attribute :foreign-type :id :accessor text-view-blink-color)
     (blink-enabled :foreign-type :<BOOL> :accessor text-view-blink-enabled)
     (peer :foreign-type :id))
  (:metaclass ns:+ns-object))


(defmethod assume-not-editing ((tv hemlock-textstorage-text-view))
  (assume-not-editing (#/textStorage tv)))

(objc:defmethod (#/changeColor: :void) ((self hemlock-textstorage-text-view)
                                        sender)
  (declare (ignorable sender))
  #+debug (#_NSLog #@"Change color to = %@" :id (#/color sender)))

(def-cocoa-default *layout-text-in-background* :bool t "When true, do text layout when idle.")

(objc:defmethod (#/layoutManager:didCompleteLayoutForTextContainer:atEnd: :void)
    ((self hemlock-textstorage-text-view) layout cont (flag :<BOOL>))
  (declare (ignorable cont flag))
  #+debug (#_NSLog #@"layout complete: container = %@, atend = %d" :id cont :int (if flag 1 0))
  (unless *layout-text-in-background*
    (#/setDelegate: layout +null-ptr+)
    (#/setBackgroundLayoutEnabled: layout nil)))
    
;;; Note changes to the textview's background color; record them
;;; as the value of the "temporary" foreground color (for blinking).
(objc:defmethod (#/setBackgroundColor: :void)
    ((self hemlock-textstorage-text-view) color)
  #+debug (#_NSLog #@"Set background color: %@" :id color)
  (let* ((old (text-view-blink-color self)))
    (unless (%null-ptr-p old)
      (#/release old)))
  (setf (text-view-blink-color self) (#/retain color))
  (call-next-method color))

;;; Maybe cause 1 character in the textview to blink (by drawing an empty
;;; character rectangle) in synch with the insertion point.

(objc:defmethod (#/drawInsertionPointInRect:color:turnedOn: :void)
    ((self hemlock-textstorage-text-view)
     (r :<NSR>ect)
     color
     (flag :<BOOL>))
  (unless (#/editingInProgress (#/textStorage self))
    (unless (eql #$NO (text-view-blink-enabled self))
      (let* ((layout (#/layoutManager self))
             (container (#/textContainer self))
             (blink-color (text-view-blink-color self)))
        ;; We toggle the blinked character "off" by setting its
        ;; foreground color to the textview's background color.
        ;; The blinked character should be "off" whenever the insertion
        ;; point is drawn as "on".  (This means that when this method
        ;; is invoked to tunr off the insertion point - as when a
        ;; view loses keyboard focus - the matching paren character
        ;; is drawn.
        (ns:with-ns-range  (char-range (text-view-blink-location self) 1)
          (let* ((glyph-range (#/glyphRangeForCharacterRange:actualCharacterRange:
                               layout
                               char-range
                               +null-ptr+)))
            #+debug (#_NSLog #@"Flag = %d, location = %d" :<BOOL> (if flag #$YES #$NO) :int (text-view-blink-location self))
            (let* ((rect (#/boundingRectForGlyphRange:inTextContainer:
                          layout
                          glyph-range
                          container)))
              (#/set blink-color)
              (#_NSRectFill rect))
          (unless flag
            (#/drawGlyphsForGlyphRange:atPoint: layout glyph-range (#/textContainerOrigin self))))))))
  (call-next-method r color flag))


(defmethod disable-blink ((self hemlock-textstorage-text-view))
  (when (eql (text-view-blink-enabled self) #$YES)
    (setf (text-view-blink-enabled self) #$NO)
    (ns:with-ns-range  (char-range (text-view-blink-location self) 1)
      (let* ((layout (#/layoutManager self))
             (glyph-range (#/glyphRangeForCharacterRange:actualCharacterRange:
                               layout
                               char-range
                               +null-ptr+)))
        (#/lockFocus self)
        (#/drawGlyphsForGlyphRange:atPoint: layout glyph-range (#/textContainerOrigin self))
        (#/unlockFocus self)))))


(defmethod update-blink ((self hemlock-textstorage-text-view))
  (disable-blink self)
  (let* ((d (hemlock-buffer-string-cache (#/hemlockString (#/textStorage self))))
         (buffer (buffer-cache-buffer d)))
    (when (and buffer (string= (hi::buffer-major-mode buffer) "Lisp"))
      (let* ((hi::*buffer-gap-context* (hi::buffer-gap-context buffer))
             (point (hi::buffer-point buffer)))
        #+debug (#_NSLog #@"Syntax check for blinking")
        (update-buffer-package (hi::buffer-document buffer) buffer)
        (cond ((eql (hi::next-character point) #\()
               (hemlock::pre-command-parse-check point)
               (when (hemlock::valid-spot point t)
                 (hi::with-mark ((temp point))
                   (when (hemlock::list-offset temp 1)
                     #+debug (#_NSLog #@"enable blink, forward")
                     (setf (text-view-blink-location self)
                           (1- (mark-absolute-position temp))
                           (text-view-blink-enabled self) #$YES)))))
              ((eql (hi::previous-character point) #\))
               (hemlock::pre-command-parse-check point)
               (when (hemlock::valid-spot point nil)
                 (hi::with-mark ((temp point))
                   (when (hemlock::list-offset temp -1)
                     #+debug (#_NSLog #@"enable blink, backward")
                     (setf (text-view-blink-location self)
                           (mark-absolute-position temp)
                           (text-view-blink-enabled self) #$YES))))))))))

;;; Set and display the selection at pos, whose length is len and whose
;;; affinity is affinity.  This should never be called from any Cocoa
;;; event handler; it should not call anything that'll try to set the
;;; underlying buffer's point and/or mark

(objc:defmethod (#/updateSelection:length:affinity: :void)
		((self hemlock-textstorage-text-view)
		 (pos :int)
		 (length :int)
		 (affinity :<NSS>election<A>ffinity))
  (assume-cocoa-thread)
  (when (eql length 0)
    (update-blink self))
  (rlet ((range :ns-range :location pos :length length))
	(%call-next-objc-method self
				hemlock-textstorage-text-view
				(@selector #/setSelectedRange:affinity:stillSelecting:)
				'(:void :<NSR>ange :<NSS>election<A>ffinity :<BOOL>)
				range
				affinity
				nil)
	(assume-not-editing self)
	(#/scrollRangeToVisible: self range)
	(when (> length 0)
	  (let* ((ts (#/textStorage self)))
	    (with-slots (selection-set-by-search) ts
	      (when (prog1 (eql #$YES selection-set-by-search)
		      (setq selection-set-by-search #$NO))
		(highlight-search-selection self pos length)))))
))

(defloadvar *can-use-show-find-indicator-for-range*
    (#/instancesRespondToSelector: ns:ns-text-view (@selector "showFindIndicatorForRange:")))

;;; Add transient highlighting to a selection established via a search
;;; primitive, if the OS supports it.
(defun highlight-search-selection (tv pos length)
  (when *can-use-show-find-indicator-for-range*
    (ns:with-ns-range (r pos length)
      (objc-message-send tv "showFindIndicatorForRange:" :<NSR>ange r :void))))
  
;;; A specialized NSTextView. The NSTextView is part of the "pane"
;;; object that displays buffers.
(defclass hemlock-text-view (hemlock-textstorage-text-view)
    ((pane :foreign-type :id :accessor text-view-pane)
     (char-width :foreign-type :<CGF>loat :accessor text-view-char-width)
     (char-height :foreign-type :<CGF>loat :accessor text-view-char-height))
  (:metaclass ns:+ns-object))






(defloadvar *text-view-context-menu* ())

(defun text-view-context-menu ()
  (or *text-view-context-menu*
      (setq *text-view-context-menu*
            (#/retain
             (let* ((menu (make-instance 'ns:ns-menu :with-title #@"Menu")))
               (#/addItemWithTitle:action:keyEquivalent:
                menu #@"Cut" (@selector #/cut:) #@"")
               (#/addItemWithTitle:action:keyEquivalent:
                menu #@"Copy" (@selector #/copy:) #@"")
               (#/addItemWithTitle:action:keyEquivalent:
                menu #@"Paste" (@selector #/paste:) #@"")
               ;; Separator
               (#/addItem: menu (#/separatorItem ns:ns-menu-item))
               (#/addItemWithTitle:action:keyEquivalent:
                menu #@"Background Color ..." (@selector #/changeBackgroundColor:) #@"")
               (#/addItemWithTitle:action:keyEquivalent:
                menu #@"Text Color ..." (@selector #/changeTextColor:) #@"")

               menu)))))





(objc:defmethod (#/changeBackgroundColor: :void)
    ((self hemlock-text-view) sender)
  (let* ((colorpanel (#/sharedColorPanel ns:ns-color-panel))
         (color (#/backgroundColor self)))
    (#/close colorpanel)
    (#/setAction: colorpanel (@selector #/updateBackgroundColor:))
    (#/setColor: colorpanel color)
    (#/setTarget: colorpanel self)
    (#/setContinuous: colorpanel nil)
    (#/orderFrontColorPanel: *NSApp* sender)))



(objc:defmethod (#/updateBackgroundColor: :void)
    ((self hemlock-text-view) sender)
  (when (#/isVisible sender)
    (let* ((color (#/color sender)))
      (unless (typep self 'echo-area-view)
        (let* ((window (#/window self))
               (echo-view (unless (%null-ptr-p window)
                            (slot-value window 'echo-area-view))))
          (when echo-view (#/setBackgroundColor: echo-view color))))
      #+debug (#_NSLog #@"Updating backgroundColor to %@, sender = %@" :id color :id sender)
      (#/setBackgroundColor: self color))))

(objc:defmethod (#/changeTextColor: :void)
    ((self hemlock-text-view) sender)
  (let* ((colorpanel (#/sharedColorPanel ns:ns-color-panel))
         (textstorage (#/textStorage self))
         (color (#/objectForKey:
                 (#/objectAtIndex: (slot-value textstorage 'styles) 0)
                 #&NSForegroundColorAttributeName)))
    (#/close colorpanel)
    (#/setAction: colorpanel (@selector #/updateTextColor:))
    (#/setColor: colorpanel color)
    (#/setTarget: colorpanel self)
    (#/setContinuous: colorpanel nil)
    (#/orderFrontColorPanel: *NSApp* sender)))






   
(objc:defmethod (#/updateTextColor: :void)
    ((self hemlock-textstorage-text-view) sender)
  (unwind-protect
      (progn
	(#/setUsesFontPanel: self t)
	(%call-next-objc-method
	 self
	 hemlock-textstorage-text-view
         (@selector #/changeColor:)
         '(:void :id)
         sender))
    (#/setUsesFontPanel: self nil))
  (#/setNeedsDisplay: self t))
   
(objc:defmethod (#/updateTextColor: :void)
    ((self hemlock-text-view) sender)
  (let* ((textstorage (#/textStorage self))
         (styles (slot-value textstorage 'styles))
         (newcolor (#/color sender)))
    (dotimes (i 4)
      (let* ((dict (#/objectAtIndex: styles i)))
        (#/setValue:forKey: dict newcolor #&NSForegroundColorAttributeName)))
    (call-next-method sender)))




;;; Access the underlying buffer in one swell foop.
(defmethod text-view-buffer ((self hemlock-text-view))
  (buffer-cache-buffer (hemlock-buffer-string-cache (#/hemlockString (#/textStorage self)))))




(objc:defmethod (#/selectionRangeForProposedRange:granularity: :ns-range)
    ((self hemlock-textstorage-text-view)
     (proposed :ns-range)
     (g :<NSS>election<G>ranularity))
  #+debug
  (#_NSLog #@"Granularity = %d" :int g)
  (objc:returning-foreign-struct (r)
     (block HANDLED
       (let* ((index (ns:ns-range-location proposed))             
              (length (ns:ns-range-length proposed)))
         (when (and (eql 0 length)      ; not extending existing selection
                    (not (eql g #$NSSelectByCharacter)))
           (let* ((textstorage (#/textStorage self))
                  (cache (hemlock-buffer-string-cache (#/hemlockString textstorage)))
                  (buffer (if cache (buffer-cache-buffer cache))))
             (when (and buffer (string= (hi::buffer-major-mode buffer) "Lisp"))
               (let* ((hi::*buffer-gap-context* (hi::buffer-gap-context buffer)))
                 (hi::with-mark ((m1 (hi::buffer-point buffer)))
                   (move-hemlock-mark-to-absolute-position m1 cache index)
                   (hemlock::pre-command-parse-check m1)
                   (when (hemlock::valid-spot m1 nil)
                     (cond ((eql (hi::next-character m1) #\()
                            (hi::with-mark ((m2 m1))
                              (when (hemlock::list-offset m2 1)
                                (ns:init-ns-range r index (- (mark-absolute-position m2) index))
                                (return-from HANDLED r))))
                           ((eql (hi::previous-character m1) #\))
                            (hi::with-mark ((m2 m1))
                              (when (hemlock::list-offset m2 -1)
                                (ns:init-ns-range r (mark-absolute-position m2) (- index (mark-absolute-position m2)))
                                (return-from HANDLED r))))))))))))
       (call-next-method proposed g)
       #+debug
       (#_NSLog #@"range = %@, proposed = %@, granularity = %d"
                :address (#_NSStringFromRange r)
                :address (#_NSStringFromRange proposed)
                :<NSS>election<G>ranularity g))))



  


;;; Translate a keyDown NSEvent to a Hemlock key-event.
(defun nsevent-to-key-event (nsevent &optional quoted)
  (let* ((modifiers (#/modifierFlags nsevent)))
    (unless (logtest #$NSCommandKeyMask modifiers)
      (let* ((chars (if quoted
                      (#/characters nsevent)
                      (#/charactersIgnoringModifiers nsevent)))
             (n (if (%null-ptr-p chars)
                  0
                  (#/length chars)))
             (c (if (eql n 1)
                  (#/characterAtIndex: chars 0))))
        (when c
          (let* ((bits 0)
                 (useful-modifiers (logandc2 modifiers
                                             (logior ;#$NSShiftKeyMask
                                                     #$NSAlphaShiftKeyMask))))
            (unless quoted
              (dolist (map hemlock-ext::*modifier-translations*)
                (when (logtest useful-modifiers (car map))
                  (setq bits (logior bits (hemlock-ext::key-event-modifier-mask
                                         (cdr map)))))))
            (let* ((char (code-char c)))
              (when (and char (standard-char-p char))
                (setq bits (logandc2 bits hi::+shift-event-mask+))))
            (hemlock-ext::make-key-event c bits)))))))

(defun pass-key-down-event-to-hemlock (self event q)
  #+debug
  (#_NSLog #@"Key down event = %@" :address event)
  (let* ((buffer (text-view-buffer self)))
    (when buffer
      (let* ((hemlock-event (nsevent-to-key-event event (hi::frame-event-queue-quoted-insert q ))))
        (when hemlock-event
          (hi::enqueue-key-event q hemlock-event))))))

(defun hi::enqueue-buffer-operation (buffer thunk)
  (dolist (w (hi::buffer-windows buffer))
    (let* ((q (hemlock-frame-event-queue (#/window w)))
           (op (hi::make-buffer-operation :thunk thunk)))
      (hi::event-queue-insert q op))))

  
;;; Process a key-down NSEvent in a Hemlock text view by translating it
;;; into a Hemlock key event and passing it into the Hemlock command
;;; interpreter. 

(defun handle-key-down (self event)
  (let* ((q (hemlock-frame-event-queue (#/window self))))
    (if (or (and (zerop (#/length (#/characters event)))
                 (hi::frame-event-queue-quoted-insert q))
            (#/hasMarkedText self))
      nil
      (progn
        (pass-key-down-event-to-hemlock self event q)
        t))))
  

(objc:defmethod (#/keyDown: :void) ((self hemlock-text-view) event)
  (or (handle-key-down self event)
      (call-next-method event)))

(objc:defmethod (#/mouseDown: :void) ((self hemlock-text-view) event)
  (let* ((q (hemlock-frame-event-queue (#/window self))))
    (hi::enqueue-key-event q #k"leftdown"))
  (call-next-method event))

;;; Update the underlying buffer's point (and "active region", if appropriate.
;;; This is called in response to a mouse click or other event; it shouldn't
;;; be called from the Hemlock side of things.

(objc:defmethod (#/setSelectedRange:affinity:stillSelecting: :void)
    ((self hemlock-text-view)
     (r :<NSR>ange)
     (affinity :<NSS>election<A>ffinity)
     (still-selecting :<BOOL>))
  #+debug 
  (#_NSLog #@"Set selected range called: location = %d, length = %d, affinity = %d, still-selecting = %d"
           :int (pref r :<NSR>ange.location)
           :int (pref r :<NSR>ange.length)
           :<NSS>election<A>ffinity affinity
           :<BOOL> (if still-selecting #$YES #$NO))
  #+debug
  (#_NSLog #@"text view string = %@, textstorage string = %@"
           :id (#/string self)
           :id (#/string (#/textStorage self)))
  (unless (#/editingInProgress (#/textStorage self))
    (let* ((d (hemlock-buffer-string-cache (#/hemlockString (#/textStorage self))))
           (buffer (buffer-cache-buffer d))
           (hi::*buffer-gap-context* (hi::buffer-gap-context buffer))
           (point (hi::buffer-point buffer))
           (location (pref r :<NSR>ange.location))
           (len (pref r :<NSR>ange.length)))
      (cond ((eql len 0)
             #+debug
             (#_NSLog #@"Moving point to absolute position %d" :int location)
             (setf (hi::buffer-region-active buffer) nil)
             (move-hemlock-mark-to-absolute-position point d location)
             (update-blink self))
            (t
             ;; We don't get much information about which end of the
             ;; selection the mark's at and which end point is at, so
             ;; we have to sort of guess.  In every case I've ever seen,
             ;; selection via the mouse generates a sequence of calls to
             ;; this method whose parameters look like:
             ;; a: range: {n0,0} still-selecting: false  [ rarely repeats ]
             ;; b: range: {n0,0) still-selecting: true   [ rarely repeats ]
             ;; c: range: {n1,m} still-selecting: true   [ often repeats ]
             ;; d: range: {n1,m} still-selecting: false  [ rarely repeats ]
             ;;
             ;; (Sadly, "affinity" doesn't tell us anything interesting.)
             ;; We've handled a and b in the clause above; after handling
             ;; b, point references buffer position n0 and the
             ;; region is inactive.
             ;; Let's ignore c, and wait until the selection's stabilized.
             ;; Make a new mark, a copy of point (position n0).
             ;; At step d (here), we should have either
             ;; d1) n1=n0.  Mark stays at n0, point moves to n0+m.
             ;; d2) n1+m=n0.  Mark stays at n0, point moves to n0-m.
             ;; If neither d1 nor d2 apply, arbitrarily assume forward
             ;; selection: mark at n1, point at n1+m.
             ;; In all cases, activate Hemlock selection.
             (unless still-selecting
                (let* ((pointpos (mark-absolute-position point))
                       (selection-end (+ location len))
                       (mark (hi::copy-mark point :right-inserting)))
                   (cond ((eql pointpos location)
                          (move-hemlock-mark-to-absolute-position point
                                                                  d
                                                                  selection-end))
                         ((eql pointpos selection-end)
                          (move-hemlock-mark-to-absolute-position point
                                                                  d
                                                                  location))
                         (t
                          (move-hemlock-mark-to-absolute-position mark
                                                                  d
                                                                  location)
                          (move-hemlock-mark-to-absolute-position point
                                                                  d
                                                                  selection-end)))
                   (hemlock::%buffer-push-buffer-mark buffer mark t)))))))
  (call-next-method r affinity still-selecting))



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

(def-cocoa-default *modeline-font-name* :string "Courier New Bold Italic"
                   "Name of font to use in modelines")
(def-cocoa-default  *modeline-font-size* :float 10.0 "Size of font to use in modelines")


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
(defun draw-modeline-string (the-modeline-view)
  (let* ((pane (modeline-view-pane the-modeline-view))
         (buffer (buffer-for-modeline-view the-modeline-view)))
    (when buffer
      ;; You don't want to know why this is done this way.
      (unless *modeline-text-attributes*
	(setq *modeline-text-attributes*
	      (create-text-attributes :color (#/blackColor ns:ns-color)
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
        (#/drawAtPoint:withAttributes: (%make-nsstring string)
                                       (ns:make-ns-point 0 0)
                                       *modeline-text-attributes*)))))

;;; Draw the underlying buffer's modeline string on a white background
;;; with a bezeled border around it.
(objc:defmethod (#/drawRect: :void) ((self modeline-view) (rect :<NSR>ect))
  (declare (ignorable rect))
  (let* ((frame (#/bounds self)))
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

(objc:defmethod #/initWithFrame: ((self modeline-scroll-view) (frame :<NSR>ect))
    (let* ((v (call-next-method frame)))
      (when v
        (let* ((modeline (make-instance 'modeline-view)))
          (#/addSubview: v modeline)
          (setf (scroll-view-modeline v) modeline)))
      v))

;;; Scroll views use the "tile" method to lay out their subviews.
;;; After the next-method has done so, steal some room in the horizontal
;;; scroll bar and place the modeline view there.

(objc:defmethod (#/tile :void) ((self modeline-scroll-view))
  (call-next-method)
  (let* ((modeline (scroll-view-modeline self)))
    (when (and (#/hasHorizontalScroller self)
               (not (%null-ptr-p modeline)))
      (let* ((hscroll (#/horizontalScroller self))
             (scrollbar-frame (#/frame hscroll))
             (modeline-frame (#/frame hscroll)) ; sic
             (modeline-width (* (pref modeline-frame
                                      :<NSR>ect.size.width)
                                0.75f0)))
        (declare (type cgfloat modeline-width))
        (setf (pref modeline-frame :<NSR>ect.size.width)
              modeline-width
              (the cgfloat
                (pref scrollbar-frame :<NSR>ect.size.width))
              (- (the cgfloat
                   (pref scrollbar-frame :<NSR>ect.size.width))
                 modeline-width)
              (the cg-float
                (pref scrollbar-frame :<NSR>ect.origin.x))
              (+ (the cgfloat
                   (pref scrollbar-frame :<NSR>ect.origin.x))
                 modeline-width))
        (#/setFrame: hscroll scrollbar-frame)
        (#/setFrame: modeline modeline-frame)))))





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
  (#/setNeedsDisplay: (text-pane-mode-line pane) t))

(def-cocoa-default *text-pane-margin-width* :float 0.0f0 "width of indented margin around text pane")
(def-cocoa-default *text-pane-margin-height* :float 0.0f0 "height of indented margin around text pane")


(objc:defmethod #/initWithFrame: ((self text-pane) (frame :<NSR>ect))
  (let* ((pane (call-next-method frame)))
    (unless (%null-ptr-p pane)
      (#/setAutoresizingMask: pane (logior
                                    #$NSViewWidthSizable
                                    #$NSViewHeightSizable))
      (#/setBoxType: pane #$NSBoxPrimary)
      (#/setBorderType: pane #$NSNoBorder)
      (#/setContentViewMargins: pane (ns:make-ns-size *text-pane-margin-width*  *text-pane-margin-height*))
      (#/setTitlePosition: pane #$NSNoTitle))
    pane))

(objc:defmethod #/defaultMenu ((class +hemlock-text-view))
  (text-view-context-menu))

;;; If we don't override this, NSTextView will start adding Google/
;;; Spotlight search options and dictionary lookup when a selection
;;; is active.
(objc:defmethod #/menuForEvent: ((self hemlock-text-view) event)
  (declare (ignore event))
  (#/menu self))

(defun make-scrolling-text-view-for-textstorage (textstorage x y width height tracks-width color style)
  (let* ((scrollview (#/autorelease
                      (make-instance
                       'modeline-scroll-view
                       :with-frame (ns:make-ns-rect x y width height)))))
    (#/setBorderType: scrollview #$NSNoBorder)
    (#/setHasVerticalScroller: scrollview t)
    (#/setHasHorizontalScroller: scrollview t)
    (#/setRulersVisible: scrollview nil)
    (#/setAutoresizingMask: scrollview (logior
                                        #$NSViewWidthSizable
                                        #$NSViewHeightSizable))
    (#/setAutoresizesSubviews: (#/contentView scrollview) t)
    (let* ((layout (make-instance 'ns:ns-layout-manager)))
      #+suffer
      (#/setTypesetter: layout (make-instance 'hemlock-ats-typesetter))
      (#/addLayoutManager: textstorage layout)
      (#/setUsesScreenFonts: layout t)
      (#/release layout)
      (let* ((contentsize (#/contentSize scrollview)))
        (ns:with-ns-size (containersize large-number-for-text large-number-for-text)
          (ns:with-ns-rect (tv-frame 0 0 (ns:ns-size-width contentsize) (ns:ns-size-height contentsize))
            (ns:init-ns-size containersize large-number-for-text large-number-for-text)
            (ns:init-ns-rect tv-frame 0 0 (ns:ns-size-width contentsize) (ns:ns-size-height contentsize))
            (let* ((container (#/autorelease (make-instance
                                              'ns:ns-text-container
                                              :with-container-size containersize))))
              (#/addTextContainer: layout  container)
              (let* ((tv (#/autorelease (make-instance 'hemlock-text-view
                                                       :with-frame tv-frame
                                                       :text-container container))))
                (#/setDelegate: layout tv)
                (#/setMinSize: tv (ns:make-ns-size 0 (ns:ns-size-height contentsize)))
                (#/setMaxSize: tv (ns:make-ns-size large-number-for-text large-number-for-text))
                (#/setRichText: tv nil)
                (#/setHorizontallyResizable: tv t)
                (#/setVerticallyResizable: tv t) 
                (#/setAutoresizingMask: tv #$NSViewWidthSizable)
                (#/setBackgroundColor: tv color)
                (#/setTypingAttributes: tv (#/objectAtIndex: (#/styles textstorage) style))
                (#/setSmartInsertDeleteEnabled: tv nil)
                (#/setAllowsUndo: tv nil) ; don't want NSTextView undo
                (#/setUsesFindPanel: tv t)
                (#/setUsesFontPanel: tv nil)
                (#/setMenu: tv (text-view-context-menu))
                (#/setWidthTracksTextView: container tracks-width)
                (#/setHeightTracksTextView: container nil)
                (#/setDocumentView: scrollview tv)	      
                (values tv scrollview)))))))))

(defun make-scrolling-textview-for-pane (pane textstorage track-width color style)
  (let* ((contentrect (#/frame (#/contentView pane))))
    (multiple-value-bind (tv scrollview)
	(make-scrolling-text-view-for-textstorage
	 textstorage
         (ns:ns-rect-x contentrect)
         (ns:ns-rect-y contentrect)
         (ns:ns-rect-width contentrect)
         (ns:ns-rect-height contentrect)
	 track-width
         color
         style)
      (#/setContentView: pane scrollview)
      (setf (slot-value pane 'scroll-view) scrollview
            (slot-value pane 'text-view) tv
            (slot-value tv 'pane) pane
            (slot-value scrollview 'pane) pane)
      (let* ((modeline  (scroll-view-modeline scrollview)))
        (setf (slot-value pane 'mode-line) modeline
              (slot-value modeline 'pane) pane))
      tv)))


(objc:defmethod (#/activateHemlockView :void) ((self text-pane))
  (let* ((the-hemlock-frame (#/window self))
	 (text-view (text-pane-text-view self)))
    #+debug (#_NSLog #@"Activating text pane")
    (with-slots ((echo peer)) text-view
      (deactivate-hemlock-view echo))
    (#/setEditable: text-view t)
    (#/makeFirstResponder: the-hemlock-frame text-view)))

(defmethod hi::activate-hemlock-view ((view text-pane))
  (#/performSelectorOnMainThread:withObject:waitUntilDone:
   view
   (@selector #/activateHemlockView)
   +null-ptr+
   t))



(defmethod deactivate-hemlock-view ((self hemlock-text-view))
  #+debug (#_NSLog #@"deactivating text view")
  (#/setSelectable: self nil))

(defclass echo-area-view (hemlock-textstorage-text-view)
    ()
  (:metaclass ns:+ns-object))

(objc:defmethod (#/activateHemlockView :void) ((self echo-area-view))
  (assume-cocoa-thread)
  (let* ((the-hemlock-frame (#/window self)))
    #+debug
    (#_NSLog #@"Activating echo area")
    (with-slots ((pane peer)) self
      (deactivate-hemlock-view pane))
    (#/setEditable: self t)
  (#/makeFirstResponder: the-hemlock-frame self)))

(defmethod hi::activate-hemlock-view ((view echo-area-view))
  (#/performSelectorOnMainThread:withObject:waitUntilDone:
   view
   (@selector #/activateHemlockView)
   +null-ptr+
   t))

(defmethod deactivate-hemlock-view ((self echo-area-view))
  (assume-cocoa-thread)
  #+debug (#_NSLog #@"deactivating echo area")
  (let* ((ts (#/textStorage self)))
    #+debug 0
    (when (#/editingInProgress ts)
      (#_NSLog #@"deactivating %@, edit-count = %d" :id self :int (slot-value ts 'edit-count)))
    (do* ()
         ((not (#/editingInProgress ts)))
      (#/endEditing ts))

    (#/setSelectable: self nil)))


(defmethod text-view-buffer ((self echo-area-view))
  (buffer-cache-buffer (hemlock-buffer-string-cache (#/hemlockString (#/textStorage self)))))

;;; The "document" for an echo-area isn't a real NSDocument.
(defclass echo-area-document (ns:ns-object)
    ((textstorage :foreign-type :id))
  (:metaclass ns:+ns-object))

(objc:defmethod (#/undoManager :<BOOL>) ((self echo-area-document))
  nil) ;For now, undo is not supported for echo-areas

(defmethod update-buffer-package ((doc echo-area-document) buffer)
  (declare (ignore buffer)))

(objc:defmethod (#/close :void) ((self echo-area-document))
  (let* ((ts (slot-value self 'textstorage)))
    (unless (%null-ptr-p ts)
      (setf (slot-value self 'textstorage) (%null-ptr))
      (close-hemlock-textstorage ts))))

(objc:defmethod (#/updateChangeCount: :void)
    ((self echo-area-document)
     (change :<NSD>ocument<C>hange<T>ype))
  (declare (ignore change)))

(objc:defmethod (#/documentChangeCleared :void) ((self echo-area-document)))

(objc:defmethod (#/keyDown: :void) ((self echo-area-view) event)
  (or (handle-key-down self event)
      (call-next-method event)))


(defloadvar *hemlock-frame-count* 0)

(defun make-echo-area (the-hemlock-frame x y width height gap-context color)
  (let* ((box (make-instance 'ns:ns-view :with-frame (ns:make-ns-rect x y width height))))
    (#/setAutoresizingMask: box #$NSViewWidthSizable)
    (let* ((box-frame (#/bounds box))
           (containersize (ns:make-ns-size large-number-for-text (ns:ns-rect-height box-frame)))
           (clipview (make-instance 'ns:ns-clip-view
                                    :with-frame box-frame)))
      (#/setAutoresizingMask: clipview (logior #$NSViewWidthSizable
                                               #$NSViewHeightSizable))
      (#/setBackgroundColor: clipview color)
      (#/addSubview: box clipview)
      (#/setAutoresizesSubviews: box t)
      (#/release clipview)
      (let* ((buffer (hi:make-buffer (format nil "Echo Area ~d"
                                             (prog1
                                                 *hemlock-frame-count*
                                               (incf *hemlock-frame-count*)))
                                     :modes '("Echo Area")))
             (textstorage
              (progn
                (setf (hi::buffer-gap-context buffer) gap-context)
                (make-textstorage-for-hemlock-buffer buffer)))
             (doc (make-instance 'echo-area-document))
             (layout (make-instance 'ns:ns-layout-manager))
             (container (#/autorelease
                         (make-instance 'ns:ns-text-container
                                        :with-container-size
                                        containersize))))
        (#/addLayoutManager: textstorage layout)
        (#/addTextContainer: layout container)
        (#/release layout)
        (let* ((echo (make-instance 'echo-area-view
                                    :with-frame box-frame
                                    :text-container container)))
          (#/setMinSize: echo (pref box-frame :<NSR>ect.size))
          (#/setMaxSize: echo (ns:make-ns-size large-number-for-text large-number-for-text))
          (#/setRichText: echo nil)
          (#/setUsesFontPanel: echo nil)
          (#/setHorizontallyResizable: echo t)
          (#/setVerticallyResizable: echo nil)
          (#/setAutoresizingMask: echo #$NSViewNotSizable)
          (#/setBackgroundColor: echo color)
          (#/setWidthTracksTextView: container nil)
          (#/setHeightTracksTextView: container nil)
          (#/setMenu: echo +null-ptr+)
          (setf (hemlock-frame-echo-area-buffer the-hemlock-frame) buffer
                (slot-value doc 'textstorage) textstorage
                (hi::buffer-document buffer) doc)
          (#/setDocumentView: clipview echo)
          (#/setAutoresizesSubviews: clipview nil)
          (#/sizeToFit echo)
          (values echo box))))))
		    
(defun make-echo-area-for-window (w gap-context-for-echo-area-buffer color)
  (let* ((content-view (#/contentView w))
	 (bounds (#/bounds content-view)))
    (multiple-value-bind (echo-area box)
			 (make-echo-area w
					 0.0f0
					 0.0f0
					 (- (ns:ns-rect-width bounds) 16.0f0)
					 20.0f0
					 gap-context-for-echo-area-buffer
					 color)
      (#/addSubview: content-view box)
      echo-area)))
               
(defclass hemlock-frame (ns:ns-window)
    ((echo-area-view :foreign-type :id)
     (pane :foreign-type :id)
     (event-queue :initform (ccl::init-dll-header (hi::make-frame-event-queue))
                  :reader hemlock-frame-event-queue)
     (command-thread :initform nil)
     (echo-area-buffer :initform nil :accessor hemlock-frame-echo-area-buffer)
     (echo-area-stream :initform nil :accessor hemlock-frame-echo-area-stream))
  (:metaclass ns:+ns-object))

(defun double-%-in (string)
  ;; Replace any % characters in string with %%, to keep them from
  ;; being treated as printf directives.
  (let* ((%pos (position #\% string)))
    (if %pos
      (concatenate 'string (subseq string 0 %pos) "%%" (double-%-in (subseq string (1+ %pos))))
      string)))

(defun nsstring-for-lisp-condition (cond)
  (%make-nsstring (double-%-in (princ-to-string cond))))

(objc:defmethod (#/runErrorSheet: :void) ((self hemlock-frame) info)
  (let* ((message (#/objectAtIndex: info 0))
         (signal (#/objectAtIndex: info 1)))
    #+debug (#_NSLog #@"runErrorSheet: signal = %@" :id signal)
    (#_NSBeginAlertSheet #@"Error in Hemlock command processing" ;title
                         (if (logbitp 0 (random 2))
                           #@"Not OK, but what can you do?"
                           #@"The sky is falling. FRED never did this!")
                         +null-ptr+
                         +null-ptr+
                         self
                         self
                         (@selector #/sheetDidEnd:returnCode:contextInfo:)
                         (@selector #/sheetDidDismiss:returnCode:contextInfo:)
                         signal
                         message)))

(objc:defmethod (#/sheetDidEnd:returnCode:contextInfo: :void) ((self hemlock-frame))
 (declare (ignore sheet code info))
  #+debug
  (#_NSLog #@"Sheet did end"))

(objc:defmethod (#/sheetDidDismiss:returnCode:contextInfo: :void)
    ((self hemlock-frame) sheet code info)
  (declare (ignore sheet code))
  #+debug (#_NSLog #@"dismiss sheet: semaphore = %lx" :unsigned-doubleword (#/unsignedLongValue info))
  (ccl::%signal-semaphore-ptr (%int-to-ptr (#/unsignedLongValue info))))
  
(defun report-condition-in-hemlock-frame (condition frame)
  (let* ((semaphore (make-semaphore))
         (message (nsstring-for-lisp-condition condition))
         (sem-value (make-instance 'ns:ns-number
                                   :with-unsigned-long (%ptr-to-int (semaphore.value semaphore)))))
    #+debug
    (#_NSLog #@"created semaphore with value %lx" :address (semaphore.value semaphore))
    (rlet ((paramptrs (:array :id 2)))
      (setf (paref paramptrs (:array :id) 0) message
            (paref paramptrs (:array :id) 1) sem-value)
      (let* ((params (make-instance 'ns:ns-array
                                    :with-objects paramptrs
                                    :count 2))
             #|(*debug-io* *typeout-stream*)|#)
        (stream-clear-output *debug-io*)
        (ignore-errors (print-call-history :detailed-p t))
        (#/performSelectorOnMainThread:withObject:waitUntilDone:
         frame (@selector #/runErrorSheet:) params t)
        (wait-on-semaphore semaphore)))))

(defun hi::report-hemlock-error (condition)
  (report-condition-in-hemlock-frame condition (#/window (hi::current-window))))
                       
                       
(defun hemlock-thread-function (q buffer pane echo-buffer echo-window)
  (let* ((hi::*real-editor-input* q)
         (hi::*editor-input* q)
         (hi::*current-buffer* hi::*current-buffer*)
         (hi::*current-window* pane)
         (hi::*echo-area-window* echo-window)
         (hi::*echo-area-buffer* echo-buffer)
         (region (hi::buffer-region echo-buffer))
         (hi::*echo-area-region* region)
         (hi::*echo-area-stream* (hi::make-hemlock-output-stream
                              (hi::region-end region) :full))
	 (hi::*parse-starting-mark*
	  (hi::copy-mark (hi::buffer-point hi::*echo-area-buffer*)
			 :right-inserting))
	 (hi::*parse-input-region*
	  (hi::region hi::*parse-starting-mark*
		      (hi::region-end region)))
         (hi::*cache-modification-tick* -1)
         (hi::*disembodied-buffer-counter* 0)
         (hi::*in-a-recursive-edit* nil)
         (hi::*last-key-event-typed* nil)
         (hi::*input-transcript* nil)
         (hi::*buffer-gap-context* (hi::buffer-gap-context buffer))
         (hemlock::*target-column* 0)
         (hemlock::*last-comment-start* " ")
         (hi::*translate-key-temp* (make-array 10 :fill-pointer 0 :adjustable t))
         (hi::*current-command* (make-array 10 :fill-pointer 0 :adjustable t))
         (hi::*current-translation* (make-array 10 :fill-pointer 0 :adjustable t))
         #+no
         (hemlock::*last-search-string* ())
         #+no
         (hemlock::*last-search-pattern*
            (hemlock::new-search-pattern :string-insensitive :forward ""))
         (hi::*prompt-key* (make-array 10 :adjustable t :fill-pointer 0))
         (hi::*command-key-event-buffer* buffer))
    
    (setf (hi::current-buffer) buffer)
    (unwind-protect
         (loop
           (catch 'hi::editor-top-level-catcher
             (handler-bind ((error #'(lambda (condition)
                                       (hi::lisp-error-error-handler condition
                                                                     :internal))))
               (hi::invoke-hook hemlock::abort-hook)
               (hi::%command-loop))))
      (hi::invoke-hook hemlock::exit-hook))))


(objc:defmethod (#/close :void) ((self hemlock-frame))
  (let* ((content-view (#/contentView self))
         (subviews (#/subviews content-view)))
    (do* ((i (1- (#/count subviews)) (1- i)))
         ((< i 0))
      (#/removeFromSuperviewWithoutNeedingDisplay (#/objectAtIndex: subviews i))))
  (let* ((proc (slot-value self 'command-thread)))
    (when proc
      (setf (slot-value self 'command-thread) nil)
      (process-kill proc)))
  (let* ((buf (hemlock-frame-echo-area-buffer self))
         (echo-doc (if buf (hi::buffer-document buf))))
    (when echo-doc
      (setf (hemlock-frame-echo-area-buffer self) nil)
      (#/close echo-doc)))
  (release-canonical-nsobject self)
  (call-next-method))
  
(defun new-hemlock-document-window (class)
  (let* ((w (new-cocoa-window :class class
                              :activate nil)))
      (values w (add-pane-to-window w :reserve-below 20.0))))



(defun add-pane-to-window (w &key (reserve-above 0.0f0) (reserve-below 0.0f0))
  (let* ((window-content-view (#/contentView w))
	 (window-frame (#/frame window-content-view)))
    (ns:with-ns-rect (pane-rect  0 reserve-below (ns:ns-rect-width window-frame) (- (ns:ns-rect-height window-frame) (+ reserve-above reserve-below)))
       (let* ((pane (make-instance 'text-pane :with-frame pane-rect)))
	 (#/addSubview: window-content-view pane)
	 pane))))

(defun textpane-for-textstorage (class ts ncols nrows container-tracks-text-view-width color style)
  (let* ((pane (nth-value
                1
                (new-hemlock-document-window class))))
    (make-scrolling-textview-for-pane pane ts container-tracks-text-view-width color style)
    (multiple-value-bind (height width)
        (size-of-char-in-font (default-font))
      (size-text-pane pane height width nrows ncols))
    pane))




(defun hemlock-buffer-from-nsstring (nsstring name &rest modes)
  (let* ((buffer (make-hemlock-buffer name :modes modes)))
    (nsstring-to-buffer nsstring buffer)))

(defun %nsstring-to-mark (nsstring mark)
  "returns line-termination of string"
  (let* ((string (lisp-string-from-nsstring nsstring))
         (lfpos (position #\linefeed string))
         (crpos (position #\return string))
         (line-termination (if crpos
                             (if (eql lfpos (1+ crpos))
                               :cp/m
                               :macos)
                             :unix)))
    (hi::insert-string mark
                           (case line-termination
                             (:cp/m (remove #\return string))
                             (:macos (nsubstitute #\linefeed #\return string))
                             (t string)))
    line-termination))
  
(defun nsstring-to-buffer (nsstring buffer)
  (let* ((document (hi::buffer-document buffer))
         (hi::*buffer-gap-context* (hi::buffer-gap-context buffer))
         (region (hi::buffer-region buffer)))
    (setf (hi::buffer-document buffer) nil)
    (unwind-protect
	 (progn
	   (hi::delete-region region)
	   (hi::modifying-buffer buffer
                                 (hi::with-mark ((mark (hi::buffer-point buffer) :left-inserting))
                                   (setf (hi::buffer-line-termination buffer)
                                         (%nsstring-to-mark nsstring mark)))
                                 (setf (hi::buffer-modified buffer) nil)
                                 (hi::buffer-start (hi::buffer-point buffer))
                                 (hi::renumber-region region)
                                 buffer))
      (setf (hi::buffer-document buffer) document))))



(setq hi::*beep-function* #'(lambda (stream)
			      (declare (ignore stream))
			      (#_NSBeep)))


;;; This function must run in the main event thread.
(defun %hemlock-frame-for-textstorage (class ts ncols nrows container-tracks-text-view-width color style)
  (assume-cocoa-thread)
  (let* ((pane (textpane-for-textstorage class ts ncols nrows container-tracks-text-view-width color style))
         (frame (#/window pane))
         (buffer (text-view-buffer (text-pane-text-view pane)))
         (echo-area (make-echo-area-for-window frame (hi::buffer-gap-context buffer) color))
         (tv (text-pane-text-view pane)))
    (with-slots (peer) tv
      (setq peer echo-area))
    (with-slots (peer) echo-area
      (setq peer tv))
    (hi::activate-hemlock-view pane)
    (setf (slot-value frame 'echo-area-view)
          echo-area
          (slot-value frame 'pane)
          pane
          (slot-value frame 'command-thread)
          (process-run-function (format nil "Hemlock window thread for ~s"
					(hi::buffer-name buffer))
                                #'(lambda ()
                                    (hemlock-thread-function
                                     (hemlock-frame-event-queue frame)
                                     buffer
                                     pane
                                     (hemlock-frame-echo-area-buffer frame)
                                     (slot-value frame 'echo-area-view)))))
    frame))
         
    


(defun hemlock-frame-for-textstorage (class ts ncols nrows container-tracks-text-view-width color style)
  (process-interrupt *cocoa-event-process*
                     #'%hemlock-frame-for-textstorage
                     class ts  ncols nrows container-tracks-text-view-width color style))



(defun hi::lock-buffer (b)
  (grab-lock (hi::buffer-gap-context-lock (hi::buffer-gap-context b))))

(defun hi::unlock-buffer (b)
  (release-lock (hi::buffer-gap-context-lock (hi::buffer-gap-context b)))) 

(defun hi::document-begin-editing (document)
  (#/performSelectorOnMainThread:withObject:waitUntilDone:
   (slot-value document 'textstorage)
   (@selector #/beginEditing)
   +null-ptr+
   t))

(defun document-edit-level (document)
  (assume-cocoa-thread) ;; see comment in #/editingInProgress
  (slot-value (slot-value document 'textstorage) 'edit-count))

(defun hi::document-end-editing (document)
  (#/performSelectorOnMainThread:withObject:waitUntilDone:
   (slot-value document 'textstorage)
   (@selector #/endEditing)
   +null-ptr+
   t))

(defun hi::document-set-point-position (document)
  (declare (ignorable document))
  #+debug
  (#_NSLog #@"Document set point position called")
  (let* ((textstorage (slot-value document 'textstorage)))
    (#/performSelectorOnMainThread:withObject:waitUntilDone:
     textstorage (@selector #/updateHemlockSelection) +null-ptr+ t)))



(defun perform-edit-change-notification (textstorage selector pos n &optional (extra 0))
  (with-lock-grabbed (*buffer-change-invocation-lock*)
    (let* ((invocation *buffer-change-invocation*))
      (rlet ((ppos :<NSI>nteger pos)
             (pn :<NSI>nteger n)
             (pextra :<NSI>nteger extra))
        (#/setTarget: invocation textstorage)
        (#/setSelector: invocation selector)
        (#/setArgument:atIndex: invocation ppos 2)
        (#/setArgument:atIndex: invocation pn 3)
        (#/setArgument:atIndex: invocation pextra 4))
      (#/performSelectorOnMainThread:withObject:waitUntilDone:
       invocation
       (@selector #/invoke)
       +null-ptr+
       t))))

(defun textstorage-note-insertion-at-position (textstorage pos n)
  #+debug
  (#_NSLog #@"insertion at position %d, len %d" :int pos :int n)
  (#/edited:range:changeInLength:
   textstorage #$NSTextStorageEditedAttributes (ns:make-ns-range pos 0) n)
  (#/edited:range:changeInLength:
   textstorage  #$NSTextStorageEditedCharacters (ns:make-ns-range pos n) 0))


(defun hi::buffer-note-font-change (buffer region font)
  (when (hi::bufferp buffer)
    (let* ((document (hi::buffer-document buffer))
	   (textstorage (if document (slot-value document 'textstorage)))
           (pos (mark-absolute-position (hi::region-start region)))
           (n (- (mark-absolute-position (hi::region-end region)) pos)))
      (perform-edit-change-notification textstorage
                                        (@selector #/noteHemlockAttrChangeAtPosition:length:)
                                        pos
                                        n
                                        font))))

(defun buffer-active-font (buffer)
  (let* ((style 0)
         (region (hi::buffer-active-font-region buffer))
         (textstorage (slot-value (hi::buffer-document buffer) 'textstorage))
         (styles (#/styles textstorage)))
    (when region
      (let* ((start (hi::region-end region)))
        (setq style (hi::font-mark-font start))))
    (#/objectAtIndex: styles style)))
      
(defun hi::buffer-note-insertion (buffer mark n)
  (when (hi::bufferp buffer)
    (let* ((document (hi::buffer-document buffer))
	   (textstorage (if document (slot-value document 'textstorage))))
      (when textstorage
        (let* ((pos (mark-absolute-position mark)))
          (unless (eq (hi::mark-%kind mark) :right-inserting)
            (decf pos n))
          (perform-edit-change-notification textstorage
                                            (@selector #/noteHemlockInsertionAtPosition:length:)
                                            pos
                                            n))))))

(defun hi::buffer-note-modification (buffer mark n)
  (when (hi::bufferp buffer)
    (let* ((document (hi::buffer-document buffer))
	   (textstorage (if document (slot-value document 'textstorage))))
      (when textstorage
            (perform-edit-change-notification textstorage
                                              (@selector #/noteHemlockModificationAtPosition:length:)
                                              (mark-absolute-position mark)
                                              n)))))
  

(defun hi::buffer-note-deletion (buffer mark n)
  (when (hi::bufferp buffer)
    (let* ((document (hi::buffer-document buffer))
	   (textstorage (if document (slot-value document 'textstorage))))
      (when textstorage
        (let* ((pos (mark-absolute-position mark)))
          (perform-edit-change-notification textstorage
                                            (@selector #/noteHemlockDeletionAtPosition:length:)
                                            pos
                                            (abs n)))))))



(defun hi::set-document-modified (document flag)
  (unless flag
    (#/performSelectorOnMainThread:withObject:waitUntilDone:
     document
     (@selector #/documentChangeCleared)
     +null-ptr+
     t)))


(defmethod hi::document-panes ((document t))
  )



    

(defun size-of-char-in-font (f)
  (let* ((sf (#/screenFont f))
         (screen-p t))
    (if (%null-ptr-p sf) (setq sf f screen-p nil))
    (let* ((layout (#/autorelease (#/init (#/alloc ns:ns-layout-manager)))))
      (#/setUsesScreenFonts: layout screen-p)
      (values (fround (#/defaultLineHeightForFont: layout sf))
              (fround (ns:ns-size-width (#/advancementForGlyph: sf (#/glyphWithName: sf #@" "))))))))
         


(defun size-text-pane (pane char-height char-width nrows ncols)
  (let* ((tv (text-pane-text-view pane))
         (height (fceiling (* nrows char-height)))
	 (width (fceiling (* ncols char-width)))
	 (scrollview (text-pane-scroll-view pane))
	 (window (#/window scrollview))
         (has-horizontal-scroller (#/hasHorizontalScroller scrollview))
         (has-vertical-scroller (#/hasVerticalScroller scrollview)))
    (ns:with-ns-size (tv-size
                      (+ width (* 2 (#/lineFragmentPadding (#/textContainer tv))))
                      height)
      (when has-vertical-scroller 
	(#/setVerticalLineScroll: scrollview char-height)
	(#/setVerticalPageScroll: scrollview +cgfloat-zero+ #|char-height|#))
      (when has-horizontal-scroller
	(#/setHorizontalLineScroll: scrollview char-width)
	(#/setHorizontalPageScroll: scrollview +cgfloat-zero+ #|char-width|#))
      (let* ((sv-size (#/frameSizeForContentSize:hasHorizontalScroller:hasVerticalScroller:borderType: ns:ns-scroll-view tv-size has-horizontal-scroller has-vertical-scroller (#/borderType scrollview)))
             (pane-frame (#/frame pane))
             (margins (#/contentViewMargins pane)))
        (incf (ns:ns-size-height sv-size)
              (+ (ns:ns-rect-y pane-frame)
                 (* 2 (ns:ns-size-height  margins))))
        (incf (ns:ns-size-width sv-size)
              (ns:ns-size-width margins))
        (#/setContentSize: window sv-size)
        (setf (slot-value tv 'char-width) char-width
              (slot-value tv 'char-height) char-height)
        (#/setResizeIncrements: window
                                (ns:make-ns-size char-width char-height))))))
				    
  
(defclass hemlock-editor-window-controller (ns:ns-window-controller)
    ()
  (:metaclass ns:+ns-object))


;;; Map *default-file-character-encoding* to an :<NSS>tring<E>ncoding
(defun get-default-encoding ()
  (let* ((string (string (or *default-file-character-encoding*
                                 "ISO-8859-1")))
         (len (length string)))
    (with-cstrs ((cstr string))
      (with-nsstr (nsstr cstr len)
        (let* ((cf (#_CFStringConvertIANACharSetNameToEncoding nsstr)))
          (if (= cf #$kCFStringEncodingInvalidId)
            (setq cf (#_CFStringGetSystemEncoding)))
          (let* ((ns (#_CFStringConvertEncodingToNSStringEncoding cf)))
            (if (= ns #$kCFStringEncodingInvalidId)
              (#/defaultCStringEncoding ns:ns-string)
              ns)))))))

;;; The HemlockEditorDocument class.


(defclass hemlock-editor-document (ns:ns-document)
    ((textstorage :foreign-type :id)
     (encoding :foreign-type :<NSS>tring<E>ncoding :initform (get-default-encoding)))
  (:metaclass ns:+ns-object))

(objc:defmethod (#/documentChangeCleared :void) ((self hemlock-editor-document))
  (#/updateChangeCount: self #$NSChangeCleared))

(defmethod assume-not-editing ((doc hemlock-editor-document))
  (assume-not-editing (slot-value doc 'textstorage)))

(defmethod update-buffer-package ((doc hemlock-editor-document) buffer)
  (let* ((name (hemlock::package-at-mark (hi::buffer-point buffer))))
    (when name
      (let* ((pkg (find-package name)))
        (if pkg
          (setq name (shortest-package-name pkg))))
      (let* ((curname (hi::variable-value 'hemlock::current-package :buffer buffer)))
        (if (or (null curname)
                (not (string= curname name)))
          (setf (hi::variable-value 'hemlock::current-package :buffer buffer) name))))))

(defun hi::document-note-selection-set-by-search (doc)
  (with-slots (textstorage) doc
    (when textstorage
      (with-slots (selection-set-by-search) textstorage
	(setq selection-set-by-search #$YES)))))

(objc:defmethod (#/validateMenuItem: :<BOOL>)
    ((self hemlock-text-view) item)
  (let* ((action (#/action item)))
    #+debug (#_NSLog #@"action = %s" :address action)
    (cond ((eql action (@selector #/hyperSpecLookUp:))
           ;; For now, demand a selection.
           (and *hyperspec-root-url*
                (not (eql 0 (ns:ns-range-length (#/selectedRange self))))))
          ((eql action (@selector #/cut:))
           (let* ((selection (#/selectedRange self)))
             (and (> (ns:ns-range-length selection))
                  (#/shouldChangeTextInRange:replacementString: self selection #@""))))
          (t (call-next-method item)))))

(defmethod user-input-style ((doc hemlock-editor-document))
  0)

(defvar *encoding-name-hash* (make-hash-table))

(defmethod hi::document-encoding-name ((doc hemlock-editor-document))
  (with-slots (encoding) doc
    (if (eql encoding 0)
      "Automatic"
      (or (gethash encoding *encoding-name-hash*)
          (setf (gethash encoding *encoding-name-hash*)
                (lisp-string-from-nsstring (nsstring-for-nsstring-encoding encoding)))))))


(defmethod textview-background-color ((doc hemlock-editor-document))
  *editor-background-color*)


(objc:defmethod (#/setTextStorage: :void) ((self hemlock-editor-document) ts)
  (let* ((doc (%inc-ptr self 0))        ; workaround for stack-consed self
         (string (#/hemlockString ts))
         (cache (hemlock-buffer-string-cache string))
         (buffer (buffer-cache-buffer cache)))
    (unless (%null-ptr-p doc)
      (setf (slot-value doc 'textstorage) ts
            (hi::buffer-document buffer) doc))))

;; This runs on the main thread.
(objc:defmethod (#/revertToSavedFromFile:ofType: :<BOOL>)
    ((self hemlock-editor-document) filename filetype)
  (declare (ignore filetype))
  (assume-cocoa-thread)
  #+debug
  (#_NSLog #@"revert to saved from file %@ of type %@"
           :id filename :id filetype)
  (let* ((encoding (slot-value self 'encoding))
         (nsstring (make-instance ns:ns-string
                                  :with-contents-of-file filename
                                  :encoding encoding
                                  :error +null-ptr+))
         (buffer (hemlock-document-buffer self))
         (old-length (hemlock-buffer-length buffer))
         (hi::*buffer-gap-context* (hi::buffer-gap-context buffer))
         (textstorage (slot-value self 'textstorage))
         (point (hi::buffer-point buffer))
         (pointpos (mark-absolute-position point)))
    (#/beginEditing textstorage)
    (#/edited:range:changeInLength:
     textstorage #$NSTextStorageEditedCharacters (ns:make-ns-range 0 old-length) (- old-length))
    (nsstring-to-buffer nsstring buffer)
    (let* ((newlen (hemlock-buffer-length buffer)))
      (#/edited:range:changeInLength: textstorage  #$NSTextStorageEditedAttributes (ns:make-ns-range 0 0) newlen)
      (#/edited:range:changeInLength: textstorage #$NSTextStorageEditedCharacters (ns:make-ns-range 0 newlen) 0)
      (let* ((ts-string (#/hemlockString textstorage))
             (display (hemlock-buffer-string-cache ts-string)))
        (reset-buffer-cache display) 
        (update-line-cache-for-index display 0)
        (move-hemlock-mark-to-absolute-position point
                                                display
                                                (min newlen pointpos))))
    (#/updateMirror textstorage)
    (#/endEditing textstorage)
    (hi::document-set-point-position self)
    (setf (hi::buffer-modified buffer) nil)
    (hi::queue-buffer-change buffer)
    t))
         
            
  
(objc:defmethod #/init ((self hemlock-editor-document))
  (let* ((doc (call-next-method)))
    (unless  (%null-ptr-p doc)
      (#/setTextStorage: doc (make-textstorage-for-hemlock-buffer
                              (make-hemlock-buffer
                               (lisp-string-from-nsstring
                                (#/displayName doc))
                               :modes '("Lisp" "Editor")))))
    doc))

  
(objc:defmethod (#/readFromURL:ofType:error: :<BOOL>)
    ((self hemlock-editor-document) url type (perror (:* :id)))
  (declare (ignorable type))
  (rlet ((pused-encoding :<NSS>tring<E>ncoding 0))
    (let* ((pathname
            (lisp-string-from-nsstring
             (if (#/isFileURL url)
               (#/path url)
               (#/absoluteString url))))
           (buffer-name (hi::pathname-to-buffer-name pathname))
           (buffer (or
                    (hemlock-document-buffer self)
                    (let* ((b (make-hemlock-buffer buffer-name)))
                      (setf (hi::buffer-pathname b) pathname)
                      (setf (slot-value self 'textstorage)
                            (make-textstorage-for-hemlock-buffer b))
                      b)))
           (hi::*buffer-gap-context* (hi::buffer-gap-context buffer))
           (selected-encoding (slot-value (#/sharedDocumentController (find-class 'hemlock-document-controller)) 'last-encoding))
           (string
            (if (zerop selected-encoding)
              (#/stringWithContentsOfURL:usedEncoding:error:
               ns:ns-string
               url
               pused-encoding
               perror)
              +null-ptr+)))
      (if (%null-ptr-p string)
        (progn
          (if (zerop selected-encoding)
            (setq selected-encoding (get-default-encoding)))
          (setq string (#/stringWithContentsOfURL:encoding:error:
                        ns:ns-string
                        url
                        selected-encoding
                        perror)))
        (setq selected-encoding (pref pused-encoding :<NSS>tring<E>ncoding)))
      (unless (%null-ptr-p string)
        (with-slots (encoding) self (setq encoding selected-encoding))
        (hi::queue-buffer-change buffer)
        (hi::document-begin-editing self)
        (nsstring-to-buffer string buffer)
        (let* ((textstorage (slot-value self 'textstorage))
               (display (hemlock-buffer-string-cache (#/hemlockString textstorage))))
          (reset-buffer-cache display) 
          (#/updateMirror textstorage)
          (update-line-cache-for-index display 0)
          (textstorage-note-insertion-at-position
           textstorage
           0
           (hemlock-buffer-length buffer)))
        (hi::document-end-editing self)
        (setf (hi::buffer-modified buffer) nil)
        (hi::process-file-options buffer pathname)
        t))))





(def-cocoa-default *editor-keep-backup-files* :bool t "maintain backup files")

(objc:defmethod (#/keepBackupFile :<BOOL>) ((self hemlock-editor-document))
  ;;; Don't use the NSDocument backup file scheme.
  nil)

(objc:defmethod (#/writeSafelyToURL:ofType:forSaveOperation:error: :<BOOL>)
    ((self hemlock-editor-document)
     absolute-url
     type
     (save-operation :<NSS>ave<O>peration<T>ype)
     (error (:* :id)))
  (when (and *editor-keep-backup-files*
             (eql save-operation #$NSSaveOperation))
    (write-hemlock-backup-file (#/fileURL self)))
  (call-next-method absolute-url type save-operation error))

(defun write-hemlock-backup-file (url)
  (unless (%null-ptr-p url)
    (when (#/isFileURL url)
      (let* ((path (#/path url)))
        (unless (%null-ptr-p path)
          (let* ((newpath (#/stringByAppendingString: path #@"~"))
                 (fm (#/defaultManager ns:ns-file-manager)))
            ;; There are all kinds of ways for this to lose.
            ;; In order for the copy to succeed, the destination can't exist.
            ;; (It might exist, but be a directory, or there could be
            ;; permission problems ...)
            (#/removeFileAtPath:handler: fm newpath +null-ptr+)
            (#/copyPath:toPath:handler: fm path newpath +null-ptr+)))))))

             

(defmethod hemlock-document-buffer (document)
  (let* ((string (#/hemlockString (slot-value document 'textstorage))))
    (unless (%null-ptr-p string)
      (let* ((cache (hemlock-buffer-string-cache string)))
	(when cache (buffer-cache-buffer cache))))))

(defmethod hi::document-panes ((document hemlock-editor-document))
  (let* ((ts (slot-value document 'textstorage))
	 (panes ()))
    (for-each-textview-using-storage
     ts
     #'(lambda (tv)
	 (let* ((pane (text-view-pane tv)))
	   (unless (%null-ptr-p pane)
	     (push pane panes)))))
    panes))

(objc:defmethod (#/noteEncodingChange: :void) ((self hemlock-editor-document)
                                               popup)
  (with-slots (encoding) self
    (setq encoding (nsinteger-to-nsstring-encoding (#/selectedTag popup)))
    ;; Force modeline update.
    (hi::queue-buffer-change (hemlock-document-buffer self))))

(objc:defmethod (#/prepareSavePanel: :<BOOL>) ((self hemlock-editor-document)
                                               panel)
  (with-slots (encoding) self
    (let* ((popup (build-encodings-popup (#/sharedDocumentController ns:ns-document-controller) encoding)))
      (#/setAction: popup (@selector #/noteEncodingChange:))
      (#/setTarget: popup self)
      (#/setAccessoryView: panel popup)))
  (#/setExtensionHidden: panel nil)
  (#/setCanSelectHiddenExtension: panel nil)
  (call-next-method panel))


(defloadvar *ns-cr-string* (%make-nsstring (string #\return)))
(defloadvar *ns-lf-string* (%make-nsstring (string #\linefeed)))
(defloadvar *ns-crlf-string* (with-autorelease-pool (#/retain (#/stringByAppendingString: *ns-cr-string* *ns-lf-string*))))

(objc:defmethod (#/writeToURL:ofType:error: :<BOOL>)
    ((self hemlock-editor-document) url type (error (:* :id)))
  (declare (ignore type))
  (with-slots (encoding textstorage) self
    (let* ((string (#/string textstorage))
           (buffer (hemlock-document-buffer self)))
      (case (when buffer (hi::buffer-line-termination buffer))
        (:cp/m (unless (typep string 'ns:ns-mutable-string)
                 (setq string (make-instance 'ns:ns-mutable-string :with string string))
               (#/replaceOccurrencesOfString:withString:options:range:
                string *ns-lf-string* *ns-crlf-string* #$NSLiteralSearch (ns:make-ns-range 0 (#/length string)))))
        (:macos (setq string (if (typep string 'ns:ns-mutable-string)
                              string
                              (make-instance 'ns:ns-mutable-string :with string string)))
                (#/replaceOccurrencesOfString:withString:options:range:
                string *ns-lf-string* *ns-cr-string* #$NSLiteralSearch (ns:make-ns-range 0 (#/length string)))))
      (when (#/writeToURL:atomically:encoding:error:
             string url t encoding error)
        (when buffer
          (setf (hi::buffer-modified buffer) nil))
        t))))




;;; Shadow the setFileURL: method, so that we can keep the buffer
;;; name and pathname in synch with the document.
(objc:defmethod (#/setFileURL: :void) ((self hemlock-editor-document)
                                        url)
  (call-next-method url)
  (let* ((buffer (hemlock-document-buffer self)))
    (when buffer
      (let* ((new-pathname (lisp-string-from-nsstring (#/path url))))
	(setf (hi::buffer-name buffer) (hi::pathname-to-buffer-name new-pathname))
	(setf (hi::buffer-pathname buffer) new-pathname)))))


(def-cocoa-default *initial-editor-x-pos* :float 20.0f0 "X position of upper-left corner of initial editor")

(def-cocoa-default *initial-editor-y-pos* :float -20.0f0 "Y position of upper-left corner of initial editor")

(defloadvar *next-editor-x-pos* nil) ; set after defaults initialized
(defloadvar *next-editor-y-pos* nil)

(defun x-pos-for-window (window x)
  (let* ((frame (#/frame window))
         (screen (#/screen window)))
    (if (%null-ptr-p screen) (setq screen (#/mainScreen ns:ns-screen)))
    (let* ((screen-rect (#/visibleFrame screen)))
      (if (>= x 0)
        (+ x (ns:ns-rect-x screen-rect))
        (- (+ (ns:ns-rect-width screen-rect) x) (ns:ns-rect-width frame))))))

(defun y-pos-for-window (window y)
  (let* ((frame (#/frame window))
         (screen (#/screen window)))
    (if (%null-ptr-p screen) (setq screen (#/mainScreen ns:ns-screen)))
    (let* ((screen-rect (#/visibleFrame screen)))
      (if (>= y 0)
        (+ y (ns:ns-rect-y screen-rect) (ns:ns-rect-height frame))
        (+ (ns:ns-rect-height screen-rect) y)))))

(objc:defmethod (#/makeWindowControllers :void) ((self hemlock-editor-document))
  #+debug
  (#_NSLog #@"Make window controllers")
  (let* ((textstorage  (slot-value self 'textstorage))
         (window (%hemlock-frame-for-textstorage
                  hemlock-frame
                  textstorage
                  *editor-columns*
                  *editor-rows*
                  nil
                  (textview-background-color self)
                  (user-input-style self)))
         (controller (make-instance
		      'hemlock-editor-window-controller
		      :with-window window)))
    (#/setDelegate: (text-pane-text-view (slot-value window 'pane)) self)
    (#/addWindowController: self controller)
    (#/release controller)
    (ns:with-ns-point  (current-point
                        (or *next-editor-x-pos*
                            (x-pos-for-window window *initial-editor-x-pos*))
                        (or *next-editor-y-pos*
                            (y-pos-for-window window *initial-editor-y-pos*)))
      (let* ((new-point (#/cascadeTopLeftFromPoint: window current-point)))
        (setq *next-editor-x-pos* (ns:ns-point-x new-point)
              *next-editor-y-pos* (ns:ns-point-y new-point))))))


(objc:defmethod (#/close :void) ((self hemlock-editor-document))
  #+debug
  (#_NSLog #@"Document close: %@" :id self)
  (let* ((textstorage (slot-value self 'textstorage)))
    (unless (%null-ptr-p textstorage)
      (setf (slot-value self 'textstorage) (%null-ptr))
      (for-each-textview-using-storage
       textstorage
       #'(lambda (tv)
           (let* ((layout (#/layoutManager tv)))
             (#/setBackgroundLayoutEnabled: layout nil))))
      (close-hemlock-textstorage textstorage)))
  (call-next-method))

(defun window-visible-range (text-view)
  (let* ((rect (#/visibleRect text-view))
	 (layout (#/layoutManager text-view))
	 (text-container (#/textContainer text-view))
	 (container-origin (#/textContainerOrigin text-view)))
    ;; Convert from view coordinates to container coordinates
    (decf (pref rect :<NSR>ect.origin.x) (pref container-origin :<NSP>oint.x))
    (decf (pref rect :<NSR>ect.origin.y) (pref container-origin :<NSP>oint.y))
    (let* ((glyph-range (#/glyphRangeForBoundingRect:inTextContainer:
			 layout rect text-container))
	   (char-range (#/characterRangeForGlyphRange:actualGlyphRange:
			layout glyph-range +null-ptr+)))
      (values (pref char-range :<NSR>ange.location)
	      (pref char-range :<NSR>ange.length)))))
    
(defun hi::scroll-window (textpane n)
  (when n
    (let* ((sv (text-pane-scroll-view textpane))
	   (tv (text-pane-text-view textpane))
	   (char-height (text-view-char-height tv))
	   (sv-height (ns:ns-size-height (#/contentSize sv)))
	   (nlines (floor sv-height char-height))
	   (count (case n
		    (:page-up (- nlines))
		    (:page-down nlines)
		    (t n))))
      (multiple-value-bind (pages lines) (floor (abs count) nlines)
	(dotimes (i pages)
	  (if (< count 0)
	      (#/performSelectorOnMainThread:withObject:waitUntilDone:
	       tv
	       (@selector #/scrollPageUp:)
	       +null-ptr+
	       t)
	      (#/performSelectorOnMainThread:withObject:waitUntilDone:
	       tv
	       (@selector #/scrollPageDown:)
	       +null-ptr+
	       t)))
	(dotimes (i lines)
	  (if (< count 0)
	      (#/performSelectorOnMainThread:withObject:waitUntilDone:
	       tv
	       (@selector #/scrollLineUp:)
	       +null-ptr+
	       t)
	      (#/performSelectorOnMainThread:withObject:waitUntilDone:
	       tv
	       (@selector #/scrollLineDown:)
	       +null-ptr+
	       t))))
      ;; If point is not on screen, move it.
      (let* ((point (hi::current-point))
	     (point-pos (mark-absolute-position point)))
	(multiple-value-bind (win-pos win-len) (window-visible-range tv)
	  (unless (and (<= win-pos point-pos) (< point-pos (+ win-pos win-len)))
	    (let* ((point (hi::current-point-collapsing-selection))
		   (cache (hemlock-buffer-string-cache
			   (#/hemlockString (#/textStorage tv)))))
	      (move-hemlock-mark-to-absolute-position point cache win-pos)
	      ;; We should be done, but unfortunately, well, we're not.
	      ;; Something insists on recentering around point, so fake it out
	      #-work-around-overeager-centering
	      (or (hi::line-offset point (floor nlines 2))
		  (if (< count 0)
		      (hi::buffer-start point)
		      (hi::buffer-end point))))))))))


(defmethod hemlock::center-text-pane ((pane text-pane))
  (#/performSelectorOnMainThread:withObject:waitUntilDone:
   (text-pane-text-view pane)
   (@selector #/centerSelectionInVisibleArea:)
   +null-ptr+
   t))


(defclass hemlock-document-controller (ns:ns-document-controller)
    ((last-encoding :foreign-type :<NSS>tring<E>ncoding))
  (:metaclass ns:+ns-object))

(defloadvar *hemlock-document-controller* nil "Shared document controller")

(objc:defmethod #/sharedDocumentController ((self +hemlock-document-controller))
  (or *hemlock-document-controller*
      (setq *hemlock-document-controller* (#/init (#/alloc self)))))

(objc:defmethod #/init ((self hemlock-document-controller))
  (if *hemlock-document-controller*
    (progn
      (#/release self)
      *hemlock-document-controller*)
    (prog1
      (setq *hemlock-document-controller* (call-next-method))
      (setf (slot-value *hemlock-document-controller* 'last-encoding) 0))))

(defun iana-charset-name-of-nsstringencoding (ns)
  (#_CFStringConvertEncodingToIANACharSetName
   (#_CFStringConvertNSStringEncodingToEncoding ns)))
    

(defun nsstring-for-nsstring-encoding (ns)
  (let* ((iana (iana-charset-name-of-nsstringencoding ns)))
    (if (%null-ptr-p iana)
      (#/stringWithFormat: ns:ns-string #@"{%@}"
                           (#/localizedNameOfStringEncoding: ns:ns-string ns))
      iana)))
      
;;; Return a list of :<NSS>tring<E>ncodings, sorted by the
;;; (localized) name of each encoding.
(defun supported-nsstring-encodings ()
  (collect ((ids))
    (let* ((ns-ids (#/availableStringEncodings ns:ns-string)))
      (unless (%null-ptr-p ns-ids)
        (do* ((i 0 (1+ i)))
             ()
          (let* ((id (paref ns-ids (:* :<NSS>tring<E>ncoding) i)))
            (if (zerop id)
              (return (sort (ids)
                            #'(lambda (x y)
                                (= #$NSOrderedAscending
                                   (#/localizedCompare:
                                    (nsstring-for-nsstring-encoding x)
                                    (nsstring-for-nsstring-encoding y))))))
              (ids id))))))))





;;; TexEdit.app has support for allowing the encoding list in this
;;; popup to be customized (e.g., to suppress encodings that the
;;; user isn't interested in.)
(defmethod build-encodings-popup ((self hemlock-document-controller)
                                  &optional (preferred-encoding (get-default-encoding)))
  (let* ((id-list (supported-nsstring-encodings))
         (popup (make-instance 'ns:ns-pop-up-button)))
    ;;; Add a fake "Automatic" item with tag 0.
    (#/addItemWithTitle: popup #@"Automatic")
    (#/setTag: (#/itemAtIndex: popup 0) 0)
    (dolist (id id-list)
      (#/addItemWithTitle: popup (nsstring-for-nsstring-encoding id))
      (#/setTag: (#/lastItem popup) (nsstring-encoding-to-nsinteger id)))
    (when preferred-encoding
      (#/selectItemWithTag: popup (nsstring-encoding-to-nsinteger preferred-encoding)))
    (#/sizeToFit popup)
    popup))


(objc:defmethod (#/runModalOpenPanel:forTypes: :<NSI>nteger)
    ((self hemlock-document-controller) panel types)
  (let* ((popup (build-encodings-popup self #|preferred|#)))
    (#/setAccessoryView: panel popup)
    (let* ((result (call-next-method panel types)))
      (when (= result #$NSOKButton)
        (with-slots (last-encoding) self
          (setq last-encoding (nsinteger-to-nsstring-encoding (#/tag (#/selectedItem popup))))))
      result)))
  
(defun hi::open-document ()
  (#/performSelectorOnMainThread:withObject:waitUntilDone:
   (#/sharedDocumentController hemlock-document-controller)
   (@selector #/openDocument:) +null-ptr+ t))
  
(defmethod hi::save-hemlock-document ((self hemlock-editor-document))
  (#/performSelectorOnMainThread:withObject:waitUntilDone:
   self (@selector #/saveDocument:) +null-ptr+ t))


(defmethod hi::save-hemlock-document-as ((self hemlock-editor-document))
  (#/performSelectorOnMainThread:withObject:waitUntilDone:
   self (@selector #/saveDocumentAs:) +null-ptr+ t))

(defun initialize-user-interface ()
  (#/sharedDocumentController hemlock-document-controller)
  (#/sharedPanel lisp-preferences-panel)
  (make-editor-style-map))

;;; This needs to run on the main thread.
(objc:defmethod (#/updateHemlockSelection :void) ((self hemlock-text-storage))
  (assume-cocoa-thread)
  (let* ((string (#/hemlockString self))
         (buffer (buffer-cache-buffer (hemlock-buffer-string-cache string)))
         (hi::*buffer-gap-context* (hi::buffer-gap-context buffer))
         (point (hi::buffer-point buffer))
         (pointpos (mark-absolute-position point))
         (location pointpos)
         (len 0))
    (when (hemlock::%buffer-region-active-p buffer)
      (let* ((mark (hi::buffer-%mark buffer)))
        (when mark
          (let* ((markpos (mark-absolute-position mark)))
            (if (< markpos pointpos)
              (setq location markpos len (- pointpos markpos))
              (if (< pointpos markpos)
                (setq location pointpos len (- markpos pointpos))))))))
    #+debug
    (#_NSLog #@"update Hemlock selection: charpos = %d, abspos = %d"
             :int (hi::mark-charpos point) :int pointpos)
    (for-each-textview-using-storage
     self
     #'(lambda (tv)
         (#/updateSelection:length:affinity: tv location len (if (eql location 0) #$NSSelectionAffinityUpstream #$NSSelectionAffinityDownstream))))))


(defun hi::allocate-temporary-object-pool ()
  (create-autorelease-pool))

(defun hi::free-temporary-objects (pool)
  (release-autorelease-pool pool))


(defloadvar *general-pasteboard* nil)

(defun general-pasteboard ()
  (or *general-pasteboard*
      (setq *general-pasteboard*
            (#/retain (#/generalPasteboard ns:ns-pasteboard)))))

(defloadvar *string-pasteboard-types* ())

(defun string-pasteboard-types ()
  (or *string-pasteboard-types*
      (setq *string-pasteboard-types*
            (#/retain (#/arrayWithObject: ns:ns-array #&NSStringPboardType)))))


(objc:defmethod (#/stringToPasteBoard:  :void)
    ((self lisp-application) string)
  (let* ((pb (general-pasteboard)))
    (#/declareTypes:owner: pb (string-pasteboard-types) nil)
    (#/setString:forType: pb string #&NSStringPboardType)))
    
(defun hi::string-to-clipboard (string)
  (when (> (length string) 0)
    (#/performSelectorOnMainThread:withObject:waitUntilDone:
     *nsapp* (@selector #/stringToPasteBoard:) (%make-nsstring string) t)))

;;; The default #/paste method seems to want to set the font to
;;; something ... inappropriate.  If we can figure out why it
;;; does that and persuade it not to, we wouldn't have to do
;;; this here.
;;; (It's likely to also be the case that Carbon applications
;;; terminate lines with #\Return when writing to the clipboard;
;;; we may need to continue to override this method in order to
;;; fix that.)
(objc:defmethod (#/paste: :void) ((self hemlock-text-view) sender)
  (declare (ignorable sender))
  #+debug (#_NSLog #@"Paste: sender = %@" :id sender)
  (let* ((pb (general-pasteboard))
         (string (progn (#/types pb) (#/stringForType: pb #&NSStringPboardType))))
    (unless (%null-ptr-p string)
      (unless (zerop (ns:ns-range-length (#/rangeOfString: string *ns-cr-string*)))
        (setq string (make-instance 'ns:ns-mutable-string :with-string string))
        (#/replaceOccurrencesOfString:withString:options:range:
                string *ns-cr-string* *ns-lf-string* #$NSLiteralSearch (ns:make-ns-range 0 (#/length string))))
      (let* ((textstorage (#/textStorage self)))
        (unless (#/shouldChangeTextInRange:replacementString: self (#/selectedRange self) string)
          (#/setSelectedRange: self (ns:make-ns-range (#/length textstorage) 0)))
	(let* ((selectedrange (#/selectedRange self)))
	  (#/replaceCharactersInRange:withString: textstorage selectedrange string))))))


(objc:defmethod (#/hyperSpecLookUp: :void)
    ((self hemlock-text-view) sender)
  (declare (ignore sender))
  (let* ((range (#/selectedRange self)))
    (unless (eql 0 (ns:ns-range-length range))
      (let* ((string (nstring-upcase (lisp-string-from-nsstring (#/substringWithRange: (#/string (#/textStorage self)) range)))))
        (multiple-value-bind (symbol win) (find-symbol string "CL")
          (when win
            (lookup-hyperspec-symbol symbol self)))))))


(defun hi::edit-definition (name)
  (let* ((info (get-source-files-with-types&classes name)))
    (if info
      (if (cdr info)
        (edit-definition-list name info)
        (edit-single-definition name (car info))))))


(defun find-definition-in-document (name indicator document)
  (let* ((buffer (hemlock-document-buffer document))
         (hi::*buffer-gap-context* (hi::buffer-gap-context buffer)))
    (hemlock::find-definition-in-buffer buffer name indicator)))


(defstatic *edit-definition-id-map* (make-id-map))

;;; Need to force things to happen on the main thread.
(defclass cocoa-edit-definition-request (ns:ns-object)
    ((name-id :foreign-type :int)
     (info-id :foreign-type :int))
  (:metaclass ns:+ns-object))

(objc:defmethod #/initWithName:info:
    ((self cocoa-edit-definition-request)
     (name :int) (info :int))
  (#/init self)
  (setf (slot-value self 'name-id) name
        (slot-value self 'info-id) info)
  self)

(objc:defmethod (#/editDefinition: :void)
    ((self hemlock-document-controller) request)
  (let* ((name (id-map-free-object *edit-definition-id-map* (slot-value request 'name-id)))
         (info (id-map-free-object *edit-definition-id-map* (slot-value request 'info-id))))
    (destructuring-bind (indicator . pathname) info
      (let* ((namestring (native-translated-namestring pathname))
             (url (#/initFileURLWithPath:
                   (#/alloc ns:ns-url)
                   (%make-nsstring namestring)))
             (document (#/openDocumentWithContentsOfURL:display:error:
                        self
                        url
                        nil
                        +null-ptr+)))
        (unless (%null-ptr-p document)
          (if (= (#/count (#/windowControllers document)) 0)
            (#/makeWindowControllers document))
          (find-definition-in-document name indicator document)
          (#/updateHemlockSelection (slot-value document 'textstorage))
          (#/showWindows document))))))

(defun edit-single-definition (name info)
  (let* ((request (make-instance 'cocoa-edit-definition-request
                                 :with-name (assign-id-map-id *edit-definition-id-map* name)
                                 :info (assign-id-map-id *edit-definition-id-map* info))))
    (#/performSelectorOnMainThread:withObject:waitUntilDone:
     (#/sharedDocumentController ns:ns-document-controller)
     (@selector #/editDefinition:)
     request
     t)))

                                        
(defun edit-definition-list (name infolist)
  (make-instance 'sequence-window-controller
                 :sequence infolist
                 :result-callback #'(lambda (info)
                                      (edit-single-definition name info))
                 :display #'(lambda (item stream)
                              (prin1 (car item) stream))
                 :title (format nil "Definitions of ~s" name)))

                                       
(objc:defmethod (#/documentClassForType: :<C>lass) ((self hemlock-document-controller)
						    type)
  (if (#/isEqualToString: type #@"html")
      display-document
      (call-next-method type)))
      

(objc:defmethod #/newDisplayDocumentWithTitle:content:
		((self hemlock-document-controller)
		 title
		 string)
  (assume-cocoa-thread)
  (let* ((doc (#/makeUntitledDocumentOfType:error: self #@"html" +null-ptr+)))
    (unless (%null-ptr-p doc)
      (#/addDocument: self doc)
      (#/makeWindowControllers doc)
      (let* ((window (#/window (#/objectAtIndex: (#/windowControllers doc) 0))))
	(#/setTitle: window title)
	(let* ((tv (slot-value doc 'text-view))
	       (lm (#/layoutManager tv))
	       (ts (#/textStorage lm)))
	  (#/beginEditing ts)
	  (#/replaceCharactersInRange:withAttributedString:
	   ts
	   (ns:make-ns-range 0 (#/length ts))
	   string)
	  (#/endEditing ts))
	(#/makeKeyAndOrderFront:
	 window
	 self)))))

(defun hi::revert-document (doc)
  (#/performSelectorOnMainThread:withObject:waitUntilDone:
   doc
   (@selector #/revertDocumentToSaved:)
   +null-ptr+
   t))


;;; Enable CL:ED
(defun cocoa-edit (&optional arg)
  (let* ((document-controller (#/sharedDocumentController ns:ns-document-controller)))
    (cond ((null arg)
           (#/performSelectorOnMainThread:withObject:waitUntilDone:
            document-controller
            (@selector #/newDocument:)
            +null-ptr+
            t))
          ((or (typep arg 'string)
               (typep arg 'pathname))
           (unless (probe-file arg)
             (touch arg))
           (with-autorelease-pool
             (let* ((url (pathname-to-url arg))
                    (signature (#/methodSignatureForSelector:
                                document-controller
                                (@selector #/openDocumentWithContentsOfURL:display:error:)))
                    (invocation (#/invocationWithMethodSignature: ns:ns-invocation
                                                                  signature)))
             
               (#/setTarget: invocation document-controller)
               (#/setSelector: invocation (@selector #/openDocumentWithContentsOfURL:display:error:))
               (rlet ((p :id)
                      (q :<BOOL>)
                      (perror :id +null-ptr+))
                 (setf (pref p :id) url
                       (pref q :<BOOL>) #$YES)
                 (#/setArgument:atIndex: invocation p 2)
                 (#/setArgument:atIndex: invocation q 3)
                 (#/setArgument:atIndex: invocation perror 4)
                 (#/performSelectorOnMainThread:withObject:waitUntilDone:
                  invocation
                  (@selector #/invoke)
                  +null-ptr+
                  t)))))
          ((valid-function-name-p arg)
           (hi::edit-definition arg))
          (t (report-bad-arg arg '(or null string pathname (satisifies valid-function-name-p)))))
    t))

(setq ccl::*resident-editor-hook* 'cocoa-edit)

(provide "COCOA-EDITOR")
