(in-package "CCL")

;;; We need to be able to point the CoreFoundation and Cocoa libraries
;;; at some bundle very early in the process.  If you want to use some
;;; other bundle path, you may need to change the call to FAKE-CFBUNDLE-PATH
;;; below.

#+darwinppc-target
(progn
(require "FAKE-CFBUNDLE-PATH")
(fake-cfbundle-path "ccl:OpenMCL.app;Contents;MacOS;dppccl"))





(require "OBJC-SUPPORT")
(require "COCOA-WINDOW")
(require "COCOA-LISTENER")
(require "COCOA-BACKTRACE")

  



;;; The application delegate gets notified of state changes in the
;;; application object.
(defclass lisp-application-delegate (ns:ns-object)
    ()
  (:metaclass ns:+ns-object))


(define-objc-method ((:void :application-will-finish-launching (:id notification))
		     lisp-application-delegate)
  (declare (ignore notification))
  (initialize-user-interface))

(define-objc-method ((:void :new-listener sender) lisp-application-delegate)
  (declare (ignore sender))
  (send (send (@class ns-document-controller) 'shared-document-controller)
	:open-untitled-document-of-type #@"Listener" :display t))

(defvar *cocoa-application-finished-launching* (make-semaphore)
  "Semaphore that's signaled when the application's finished launching ...")

(define-objc-method ((:void :application-did-finish-launching notification)
		     lisp-application-delegate)
  (declare (ignore notification))
  (signal-semaphore *cocoa-application-finished-launching*))


(define-objc-method ((:<BOOL> :application-open-untitled-file app)
		     lisp-application-delegate)
  (when (zerop *cocoa-listener-count*)
    (send self :new-listener app)
    t))


(defmethod ui-object-do-operation ((o ns:ns-application)
                                   operation &rest args)
  (case operation
    (:note-current-package (ui-object-note-package o (car args)))
    (:eval-selection (ui-object-eval-selection o (car args)))
    (:enter-backtrace-context
     (ui-object-enter-backtrace-context o (car args)))
    (:exit-backtrace-context
     (ui-object-exit-backtrace-context o (car args)))))


(start-cocoa-application)

