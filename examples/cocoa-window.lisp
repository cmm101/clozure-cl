;;;-*-Mode: LISP; Package: CCL -*-
;;;
;;;   Copyright (C) 2002-2003 Clozure Associates
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


(in-package "CCL")			; for now.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require "OBJC-SUPPORT")
  (require "COCOA-DEFAULTS")
  (require "COCOA-PREFS"))

(eval-when (:compile-toplevel :execute)
  (use-interface-dir #+apple-objc  :cocoa #+gnu-objc :gnustep))


(defun init-cocoa-application ()
  (with-autorelease-pool
      (let* ((bundle (open-main-bundle))
	     (dict (send bundle 'info-dictionary))
	     (classname (send dict :object-for-key #@"NSPrincipalClass"))
	     (mainnibname (send dict :object-for-key  #@"NSMainNibFile"))
	     (progname (send dict :object-for-key #@"CFBundleName")))
	(if (%null-ptr-p classname)
	  (error "problems loading bundle: can't determine class name"))
	(if (%null-ptr-p mainnibname)
	  (error "problems loading bundle: can't determine main nib name"))
	(unless (%null-ptr-p progname)
	  (send (send (@class ns-process-info) 'process-info)
		:set-process-name progname))
	(let* ((appclass (#_NSClassFromString classname))
	       (app (send appclass 'shared-application)))
	  (send (@class ns-bundle)
		:load-nib-named mainnibname
		:owner app)
	  app))))



#+apple-objc
(defun trace-dps-events (flag)
  (external-call "__DPSSetEventsTraced"
		 :unsigned-byte (if flag #$YES #$NO)
		 :void))

(defvar *appkit-process-interrupt-ids* (make-id-map))
(defun register-appkit-process-interrupt (thunk)
  (assign-id-map-id *appkit-process-interrupt-ids* thunk))
(defun appkit-interrupt-function (id)
  (id-map-free-object *appkit-process-interrupt-ids* id))

(defclass appkit-process (process) ())

(defconstant process-interrupt-event-subtype 17)




(defclass lisp-application (ns:ns-application)
    ((termp :foreign-type :<BOOL>))
  (:metaclass ns:+ns-object))


(define-objc-method ((:void :post-event-at-start e) ns:ns-application)
  (send self :post-event e :at-start t))

;;; Interrupt the AppKit event process, by enqueing an event (if the
;;; application event loop seems to be running.)  It's possible that
;;; the event loop will stop after the calling thread checks; in that
;;; case, the application's probably already in the process of
;;; exiting, and isn't that different from the case where asynchronous
;;; interrupts are used.  An attribute of the event is used to identify
;;; the thunk which the event handler needs to funcall.
(defmethod process-interrupt ((process appkit-process) function &rest args)
  (if (eq process *current-process*)
    (apply function args)
    (if (or (not *NSApp*) (not (send *NSApp* 'is-running)))
      (call-next-method)
      (let* ((e (send (@class ns-event)
		      :other-event-with-type #$NSApplicationDefined
		      :location (ns-make-point 0.0e0 0.0e0)
		      :modifier-flags 0
		      :timestamp 0.0d0
		      :window-number 0
		      :context (%null-ptr)
		      :subtype process-interrupt-event-subtype
		      :data1 (register-appkit-process-interrupt
			      #'(lambda () (apply function args)))
		      :data2 0)))
	(send e 'retain)
	(send *NSApp*
	      :perform-selector-on-main-thread (@selector
						"postEventAtStart:")
	      :with-object e
	      :wait-until-done t)))))

#+apple-objc
(define-objc-method ("_shouldTerminate" lisp-application)
  (:<BOOL>)
  (with-slots (termp) self
      (setq termp (objc-message-send-super (super) "_shouldTerminate" :<BOOL>))))

(define-objc-method ((:<BOOL> termp) lisp-application)
  (with-slots (termp) self
      termp))

(defloadvar *default-ns-application-proxy-class-name*
    "LispApplicationDelegate")

#+apple-objc
(defun enable-foreground ()
  (%stack-block ((psn 8))
    (external-call "_GetCurrentProcess" :address psn)
    (external-call "_CPSEnableForegroundOperation" :address psn)
    (eql 0 (external-call "_SetFrontProcess" :address psn :signed-halfword))))

;;; I'm not sure if there's another way to recognize events whose
;;; type is #$NSApplicationDefined.
(define-objc-method ((:void :send-event e)
		     lisp-application)
  (if (and (eql (send e 'type) #$NSApplicationDefined)
	   (eql (send e 'subtype) process-interrupt-event-subtype))
    ;;; The thunk to funcall is identified by the value
    ;;; of the event's data1 attribute.
    (funcall (appkit-interrupt-function (send e 'data1)))
    (send-super :send-event e)))

;;; This is a reverse-engineered version of most of -[NSApplication terminate],
;;; split off this way because we don't necessarily want to just do
;;  (#_exit 0) when we've shut down the Cocoa UI.
#+apple-objc
(define-objc-method ((:void shutdown)
		     lisp-application)
  (unless (eql (pref self :<NSA>pplication._app<F>lags._app<D>ying) #$YES)
    (if (eql #$NO (external-call "__runningOnAppKitThread" :<BOOL>))
      (send self
	    :perform-selector-on-main-thread (@selector "shutdown")
	    :with-object (%null-ptr)
	    :wait-until-done nil)
      (progn
	(setf (pref self :<NSA>pplication._app<F>lags._app<D>ying) #$YES)
	(send (send (@class ns-notification-center) 'default-center)
	      :post-notification-name #@"NSApplicationWillTerminateNotification"
	      :object self)
        ;; Remove self as the observer of all notifications (the
        ;; precise set of notifications for which it's registered
        ;; may vary from release to release
	(send (send (@class ns-notification-center) 'default-center)
	      :remove-observer self
	      :name (%null-ptr)
	      :object (%null-ptr))
	(objc-message-send (@class ns-menu) "_saveTornOffMenus" :void)
	(send (send (@class ns-user-defaults) 'standard-user-defaults)
	      'synchronize)
	(objc-message-send (@class ns-pasteboard) 
			   "_provideAllPromisedData" :void)
	(objc-message-send (send (@class ns-help-manager) 'shared-help-manager)
			   "_cleanupHelpForQuit" :void)
        ;; See what happens when you muck around in Things You Shouldn't
        ;; Know About ?
        (let* ((addr (or (foreign-symbol-address
                          "__NSKeyboardUIHotKeysUnregister")
                         (foreign-symbol-address
                          "__NSKeyboardUIHotKeysCleanup"))))
          (if addr (ff-call addr :void)))
	(send (the ns-application self) :stop (%null-ptr))))))

(define-objc-method ((:void :terminate sender)
		     lisp-application)
  (declare (ignore sender))
  (quit))

(define-objc-method ((:void :show-preferences sender) lisp-application)
  (declare (ignore sender))
  (send (send (find-class 'preferences-panel) 'shared-panel) 'show))


(defun nslog-condition (c)
  (let* ((rep (format nil "~a" c)))
    (with-cstrs ((str rep))
      (with-nsstr (nsstr str (length rep))
	(#_NSLog #@"Error in event loop: %@" :address nsstr)))))


#+apple-objc
(defmethod process-verify-quit ((process appkit-process))
  (let* ((app *NSApp*))
    (or
     (null app)
     (not (send app 'is-running))
     (eql (pref app :<NSA>pplication._app<F>lags._app<D>ying) #$YES)
     (eql (pref app
		:<NSA>pplication._app<F>lags._dont<S>end<S>hould<T>erminate)
	  #$YES)
     (progn
       (send
	app
	:perform-selector-on-main-thread (@selector "_shouldTerminate")
	:with-object (%null-ptr)
	:wait-until-done t)
       (send app 'termp)))))

#+apple-objc
(defmethod process-exit-application ((process appkit-process) thunk)
  (when (eq process *initial-process*)
    (prepare-to-quit)
    (%set-toplevel thunk)
    (send (the lisp-application *NSApp*) 'shutdown)
    ))

(defun run-event-loop ()
  (%set-toplevel nil)
  (let* ((app *NSApp*))
    (loop
	(handler-case (send (the ns-application app) 'run)
	  (error (c) (nslog-condition c)))
	(unless (send app 'is-running)
	  (return)))
    ;; This is a little funky (OK, it's a -lot- funky.) The
    ;; -[NSApplication _deallocHardCore:] method wants an autorelease
    ;; pool to be established when it's called, but one of the things
    ;; that it does is to release all autorelease pools.  So, we create
    ;; one, but don't worry about freeing it ...
    #+apple-objc
    (progn
      (create-autorelease-pool)
      (objc-message-send app "_deallocHardCore:" :<BOOL> #$YES :void))))


(change-class *cocoa-event-process* 'appkit-process)

(defun start-cocoa-application (&key
				(application-proxy-class-name
				 *default-ns-application-proxy-class-name*))
  
  (flet ((cocoa-startup ()
	   ;; Start up a thread to run periodic tasks.
	   ;; Under Linux/GNUstep, some of these might have to run in
	   ;; the main thread (because of PID/thread conflation.)
	   (process-run-function "housekeeping"
				 #'(lambda ()
				     (loop
					 (%nanosleep *periodic-task-seconds*
						     *periodic-task-nanoseconds*)
					 (housekeeping))))
	   
           (with-autorelease-pool
               (enable-foreground)
               (or *NSApp* (setq *NSApp* (init-cocoa-application)))
               (send *NSApp* :set-application-icon-image
                     (send (@class ns-image) :image-Named #@"NSApplicationIcon"))
               (setf (application-ui-object *application*) *NSApp*)

               (when application-proxy-class-name
                 (let* ((classptr (%objc-class-classptr
                                   (load-objc-class-descriptor application-proxy-class-name))))
                   (send *NSApp* :set-delegate
                         (send (send classptr 'alloc) 'init)))))
           (run-event-loop)))
    (process-interrupt *cocoa-event-process* #'(lambda ()
						 (%set-toplevel 
						  #'cocoa-startup)
						 (toplevel)))))

(def-cocoa-default *default-font-name* :string "Courier" "Name of font to use in editor windows")
(def-cocoa-default *default-font-size* :float 12.0f0 "Size of font to use in editor windows, as a positive SINGLE-FLOAT")

(defparameter *font-attribute-names*
  '((:bold . #.#$NSBoldFontMask)
    (:italic . #.#$NSItalicFontMask)
    (:small-caps . #.#$NSSmallCapsFontMask)))
    
;;; Try to find the specified font.  If it doesn't exist (or isn't
;;; fixed-pitch), try to find a fixed-pitch font of the indicated size.
(defun default-font (&key (name *default-font-name*)
			  (size *default-font-size*)
			  (attributes ()))
				
  (setq size (float size 0.0f0))
  (with-cstrs ((name name))
    (with-autorelease-pool
	(rletz ((matrix (:array :float 6)))
	  (setf (%get-single-float matrix 0) size
		(%get-single-float matrix 12) size)
          (let* ((fontname (send (@class ns-string) :string-with-c-string name))
		 (font (send (@class ns-font)
				  :font-with-name fontname :matrix matrix))
		 (implemented-attributes ()))
	    (if (or (%null-ptr-p font)
		    (and 
		     (not (send font 'is-fixed-pitch))
		     (not (eql #$YES (objc-message-send font "_isFakeFixedPitch" :<BOOL>)))))
	      (setq font (send (@class ns-font)
			       :user-fixed-pitch-font-of-size size)))
	    (when attributes
	      (dolist (attr-name attributes)
		(let* ((pair (assoc attr-name *font-attribute-names*))
		       (newfont))
		  (when pair
		    (setq newfont
			  (send
			   (send (@class "NSFontManager") 'shared-font-manager)
			   :convert-font font
			   :to-have-trait (cdr pair)))
		    (unless (eql font newfont)
		      (setq font newfont)
		      (push attr-name implemented-attributes))))))
	    (values font implemented-attributes))))))

(def-cocoa-default *tab-width* :int 8 "Width of editor tab stops, in characters" (integer 1 32))

;;; Create a paragraph style, mostly so that we can set tabs reasonably.
(defun create-paragraph-style (font line-break-mode)
  (let* ((p (make-objc-instance 'ns-mutable-paragraph-style))
	 (charwidth (send (send font 'screen-font)
			  :width-of-string #@" ")))
    (send p
	  :set-line-break-mode
	  (ecase line-break-mode
	    (:char #$NSLineBreakByCharWrapping)
	    (:word #$NSLineBreakByWordWrapping)
	    ;; This doesn't seem to work too well.
	    ((nil) #$NSLineBreakByClipping)))
    ;; Clear existing tab stops.
    (send p :set-tab-stops (send (@class ns-array) 'array))
    (do* ((i 1 (1+ i)))
	 ((= i 100) p)
      (let* ((tabstop (make-objc-instance
		       'ns-text-tab
		       :with-type #$NSLeftTabStopType
		       :location  (* (* i *tab-width*)
					charwidth))))
	(send p :add-tab-stop tabstop)
	(send tabstop 'release)))))
    
(defun create-text-attributes (&key (font (default-font))
				    (line-break-mode :char)
				    (color nil)
                                    (obliqueness nil)
                                    (stroke-width nil))
  (let* ((dict (make-objc-instance
		'ns-mutable-dictionary
		:with-capacity 5)))
    (send dict 'retain)
    (send dict
	  :set-object (create-paragraph-style font line-break-mode)
	  :for-key #?NSParagraphStyleAttributeName)
    (send dict :set-object font :for-key #?NSFontAttributeName)
    (when color
      (send dict :set-object color :for-key #?NSForegroundColorAttributeName))
    (when stroke-width
      (send dict :set-object (make-objc-instance 'ns:ns-number
                                                :with-float (float stroke-width))
            :for-key #?NSStrokeWidthAttributeName))
    (when obliqueness
      (send dict :set-object (make-objc-instance 'ns:ns-number
                                                :with-float (float obliqueness))
            :for-key #?NSObliquenessAttributeName))
    dict))


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

(defun new-cocoa-window (&key
                         (class (find-class 'ns:ns-window))
                         (title nil)
                         (x 200.0)
                         (y 200.0)
                         (height 200.0)
                         (width 500.0)
                         (closable t)
                         (iconifyable t)
                         (metal t)
                         (expandable t)
                         (backing :buffered)
                         (defer t)
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
	       class
	       :with-content-rect frame
	       :style-mask stylemask
	       :backing backing-type
	       :defer defer)))
      (setf (get-cocoa-window-flag w :accepts-mouse-moved-events)
            accepts-mouse-moved-events
            (get-cocoa-window-flag w :auto-display)
            auto-display)
      (when activate (activate-window w))
      (when title (send w :set-title (%make-nsstring title)))
      w)))




