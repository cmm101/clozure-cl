;;; -*- Mode: Lisp; Package: Hemlock-Internals -*-
;;;
;;; **********************************************************************
;;; Hemlock was written as part of the CMU Common Lisp project at
;;; Carnegie Mellon University, and has been placed in the public domain.

(in-package :hemlock-internals)

(defstruct (frame-event-queue (:include ccl::locked-dll-header))
  (signal (ccl::make-semaphore)))

(defstruct (buffer-operation (:include ccl::dll-node))
  (thunk nil))


(defun enqueue-key-event (q event)
  (ccl::locked-dll-header-enqueue event q)
  (ccl::signal-semaphore (frame-event-queue-signal q)))

(defun dequeue-key-event (q)
  (ccl::wait-on-semaphore (frame-event-queue-signal q))
  (ccl::locked-dll-header-dequeue q))

(defun unget-key-event (event q)
  (ccl::with-locked-dll-header (q)
    (ccl::insert-dll-node-after event q))
  (ccl::signal-semaphore (frame-event-queue-signal q)))




  

(defun buffer-windows (buffer)
  (let* ((doc (buffer-document buffer)))
    (when doc
      (document-panes doc))))

(defvar *current-window* ())

(defvar *window-list* ())
(defun current-window ()
  "Return the current window.  The current window is specially treated by
  redisplay in several ways, the most important of which is that is does
  recentering, ensuring that the Buffer-Point of the current window's
  Window-Buffer is always displayed.  This may be set with Setf."
  *current-window*)

(defun %set-current-window (new-window)
  #+not-yet
  (invoke-hook hemlock::set-window-hook new-window)
  (activate-hemlock-view new-window)
  (setq *current-window* new-window))

;;; This is a public variable.
;;;
(defvar *last-key-event-typed* ()
  "This variable contains the last key-event typed by the user and read as
   input.")

(defvar *input-transcript* ())

(defun get-key-event (q &optional ignore-pending-aborts)
  (declare (ignore ignore-pending-aborts))
  (do* ((e (dequeue-key-event q) (dequeue-key-event q)))
       ((typep e 'hemlock-ext:key-event)
        (setq *last-key-event-typed* e))
    (if (typep e 'buffer-operation)
      (funcall (buffer-operation-thunk e)))))

(defun listen-editor-input (q)
  (ccl::with-locked-dll-header (q)
    (not (eq (ccl::dll-header-first q) q))))
