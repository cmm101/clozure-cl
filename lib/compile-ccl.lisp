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

(require 'systems)

; Interim PPC support
; sequences is here since l1-typesys REQUIREs it
(defparameter *level-1-modules*
  '(level-1
    l1-cl-package
    l1-boot-1 l1-boot-2 l1-boot-3
    l1-utils l1-init l1-symhash l1-numbers l1-aprims 
    l1-sort l1-dcode l1-clos-boot l1-clos
    l1-streams l1-files l1-io 
    l1-format l1-readloop l1-reader
    l1-sysio l1-pathnames l1-events
    l1-boot-lds  l1-readloop-lds 
    l1-lisp-threads  l1-application l1-processes
    l1-typesys sysutils l1-error-system
    l1-error-signal version l1-callbacks
    l1-sockets linux-files

    ))

(defparameter *compiler-modules*
      '(nx optimizers dll-node arch vreg vinsn 
	reg subprims  backend))


(defparameter *ppc-compiler-modules*
  '(ppc32-arch
    ppc64-arch
    ppc-arch
    ppcenv
    ppc-asm
    risc-lap
    ppc-lap
    ppc-backend
))

(defparameter *x86-compiler-modules*
  '(x86-arch
    x86-asm
    x86-lap
    x8664-arch
    x8664env
    x86-backend
    )
  )

(defparameter *ppc32-compiler-backend-modules*
  '(ppc32-backend ppc32-vinsns))

(defparameter *ppc64-compiler-backend-modules*
  '(ppc64-backend ppc64-vinsns))

(defparameter *x8664-compiler-backend-modules*
  '(x8664-backend x8664-vinsns))

(defparameter *ppc-compiler-backend-modules*
  '(ppc2))

(defparameter *x86-compiler-backend-modules*
  '(x862))


(defparameter *x8632-compiler-backend-modules*
  '(x8632-backend x8632-vinsns))

(defparameter *x8664-compiler-backend-modules*
  '(x8664-backend x8664-vinsns))

(defparameter *x86-compiler-backend-modules*
  '(x862))




(defparameter *ppc-xload-modules* '(xppcfasload xfasload heap-image ))
(defparameter *x8664-xload-modules* '(xx8664fasload xfasload heap-image ))


;;; Not too OS-specific.
(defparameter *ppc-xdev-modules* '(ppc-lapmacros ))
(defparameter *x86-xdev-modules* '(x86-lapmacros ))

(defun target-xdev-modules (&optional (target
				       (backend-target-arch-name
					*host-backend*)))
  (case target
    ((:ppc32 :ppc64) *ppc-xdev-modules*)
    ((:x8632 :x8664) *x86-xdev-modules*)))

(defun target-xload-modules (&optional (target
					(backend-target-arch-name *host-backend*)))
  (case target
    ((:ppc32 :ppc64) *ppc-xload-modules*)
    (:x8664 *x8664-xload-modules*)))






(defparameter *env-modules*
  '(hash backquote lispequ  level-2 macros
    defstruct-macros lists chars setf setf-runtime
    defstruct defstruct-lds 
    foreign-types
    db-io
    nfcomp
    ))

(defun target-env-modules (&optional (target
				      (backend-target-arch-name
				       *host-backend*)))
  (declare (ignore target))
  *env-modules*)

(defun target-compiler-modules (&optional (target
					   (backend-target-arch-name
					    *host-backend*)))
  (case target
    (:ppc32 (append *ppc-compiler-modules*
                    *ppc32-compiler-backend-modules*
                    *ppc-compiler-backend-modules*))
    (:ppc64 (append *ppc-compiler-modules*
                    *ppc64-compiler-backend-modules*
                    *ppc-compiler-backend-modules*))
    (:x8664 (append *x86-compiler-modules*
                    *x8664-compiler-backend-modules*
                    *x86-compiler-backend-modules*))))

(defparameter *other-lib-modules*
  '(streams pathnames backtrace
    apropos
    numbers 
    dumplisp   source-files))

(defun target-other-lib-modules (&optional (target
					    (backend-target-arch-name
					     *host-backend*)))
  (append *other-lib-modules*
	  (case target
	    ((:ppc32 :ppc64) '(ppc-backtrace ppc-disassemble))
            (:x8664 '(x86-backtrace x86-disassemble)))))
	  

(defun target-lib-modules (&optional (target
				      (backend-target-arch-name *target-backend*)))
  (append (target-env-modules target) (target-other-lib-modules target)))


(defparameter *code-modules*
      '(encapsulate
        read misc  arrays-fry
        sequences sort 
        method-combination
        case-error pprint 
        format time 
;        eval step
        backtrace-lds  ccl-export-syms prepare-mcl-environment))



(defparameter *aux-modules*
      '(systems compile-ccl 
        lisp-package
        number-macros number-case-macro
        loop
	runtime
	mcl-compat
	arglist
	edit-callers
        hash-cons
        describe
	asdf
	defsystem
))







(defun target-level-1-modules (&optional (target (backend-name *host-backend*)))
  (append *level-1-modules*
	  (case target
	    ((:linuxppc32 :darwinppc32 :linuxppc64 :darwinppc64)
	     '(ppc-error-signal ppc-trap-support
	       ppc-threads-utils ppc-callback-support))
            ((:linuxx8664 :freebsd86664)
             '(x86-error-signal x86-trap-support
               x86-threads-utils x86-callback-support)))))

		  




;





; Needed to cross-dump an image



(unless (fboundp 'xload-level-0)
  (%fhave 'xload-level-0
          #'(lambda (&rest rest)
	      (in-development-mode
	       (require-modules (target-xload-modules)))
              (apply 'xload-level-0 rest))))

(defun find-module (module &optional (target (backend-name *host-backend*))  &aux data fasl sources)
  (if (setq data (assoc module *ccl-system*))
    (let* ((backend (or (find-backend target) *host-backend*)))
      (setq fasl (cadr data) sources (caddr data))      
      (setq fasl (merge-pathnames (backend-target-fasl-pathname
				   backend) fasl))
      (values fasl (if (listp sources) sources (list sources))))
    (error "Module ~S not defined" module)))

;compile if needed.
(defun target-compile-modules (modules target force-compile)
  (if (not (listp modules)) (setq modules (list modules)))
  (in-development-mode
   (dolist (module modules t)
     (multiple-value-bind (fasl sources) (find-module module target)
      (if (needs-compile-p fasl sources force-compile)
        (progn
          (require'nfcomp)
          (compile-file (car sources)
			:output-file fasl
			:verbose t
			:target target)))))))






(defun needs-compile-p (fasl sources force-compile)
  (if fasl
    (if (eq force-compile t)
      t
      (if (not (probe-file fasl))
        t
        (let ((fasldate (file-write-date fasl)))
          (if (if (integerp force-compile) (> force-compile fasldate))
            t
            (dolist (source sources nil)
              (if (> (file-write-date source) fasldate)
                (return t)))))))))



;compile if needed, load if recompiled.

(defun update-modules (modules &optional force-compile)
  (if (not (listp modules)) (setq modules (list modules)))
  (in-development-mode
   (dolist (module modules t)
     (multiple-value-bind (fasl sources) (find-module module)
       (if (needs-compile-p fasl sources force-compile)
	 (progn
	   (require'nfcomp)
	   (let* ((*warn-if-redefine* nil))
	     (compile-file (car sources) :output-file fasl :verbose t :load t))
	   (provide module)))))))

(defun compile-modules (modules &optional force-compile)
  (target-compile-modules modules (backend-name *host-backend*) force-compile)
)

(defun compile-ccl (&optional force-compile)
  (update-modules 'nxenv force-compile)
  (update-modules *compiler-modules* force-compile)
  (update-modules (target-compiler-modules) force-compile)
  (update-modules (target-xdev-modules) force-compile)
  (update-modules (target-xload-modules)  force-compile)
  (let* ((env-modules (target-env-modules))
	 (other-lib (target-other-lib-modules)))
    (require-modules env-modules)
    (update-modules env-modules force-compile)
    (compile-modules (target-level-1-modules)  force-compile)
    (update-modules other-lib force-compile)
    (require-modules other-lib)
    (require-update-modules *code-modules* force-compile))
  (compile-modules *aux-modules* force-compile))



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun require-env (&optional force-load)
  (require-modules  (target-env-modules)
                   force-load))

(defun compile-level-1 (&optional force-compile)
  (require-env)
  (compile-modules (target-level-1-modules (backend-name *host-backend*))
                   force-compile))





(defun compile-lib (&optional force-compile)
  (compile-modules (target-lib-modules)
                   force-compile))

(defun compile-code (&optional force-compile)
  (compile-modules *code-modules* force-compile))


;Compile but don't load

#+ppc-target
(defun xcompile-ccl (&optional force)
  (ppc-xcompile-ccl force))

(defun require-update-modules (modules &optional force-compile)
  (if (not (listp modules)) (setq modules (list modules)))
  (in-development-mode
    (dolist (module modules)
    (require-modules module)
    (update-modules module force-compile))))

(defun compile-level-1 (&optional force-compile)
  (compile-modules (target-level-1-modules (backend-name *host-backend*))
		   force-compile))

(defun compile-compiler (&optional force-compile)
  (update-modules 'ppcenv force-compile)
  (compile-modules 'nxenv force-compile)
  (compile-modules 'nx-base-app force-compile) ; for appgen
  (compile-modules *compiler-modules* force-compile)
  (compile-modules *ppc-compiler-modules* force-compile))

(defun ppc-xcompile-ccl (&optional force)
  (compile-modules 'nxenv force)
  (compile-modules *compiler-modules* force)
  (compile-modules (target-compiler-modules) force)
  (compile-modules (target-xdev-modules) force)
  (compile-modules (target-xload-modules) force)
  (let* ((env-modules (target-env-modules))
	 (other-lib (target-other-lib-modules)))
    (compile-modules env-modules force)
    (compile-modules (target-level-1-modules) force)
    (compile-modules other-lib force)
    (compile-modules *code-modules* force))
  (compile-modules *aux-modules* force))
  

(defun target-xcompile-ccl (target &optional force)
  (let* ((backend (or (find-backend target) *target-backend*))
	 (arch (backend-target-arch-name backend))
	 (*defstruct-share-accessor-functions* nil))
    (target-compile-modules 'nxenv target force)
    (target-compile-modules *compiler-modules* target force)
    (target-compile-modules (target-compiler-modules arch) target force)
    (target-compile-modules (target-level-1-modules target) target force)
    (target-compile-modules (target-lib-modules arch) target force)
    (target-compile-modules *aux-modules* target force)
    (target-compile-modules *code-modules* target force)
    (target-compile-modules (target-xdev-modules arch) target force)))

(defun cross-compile-ccl (target &optional force)
  (with-cross-compilation-target (target)
    (let* ((*target-backend* (find-backend target)))
      (target-xcompile-ccl target force))))


(defun ppc-require-module (module force-load)
  (multiple-value-bind (fasl source) (find-module module)
      (setq source (car source))
      (if (if fasl (probe-file fasl))
        (if force-load
          (progn
            (load fasl)
            (provide module))
          (require module fasl))
        (if (probe-file source)
          (progn
            (if fasl (format t "~&Can't find ~S so requiring ~S instead"
                             fasl source))
            (if force-load
              (progn
                (load source)
                (provide module))
              (require module source)))
          (error "Can't find ~S or ~S" fasl source)))))

(defun require-modules (modules &optional force-load)
  (if (not (listp modules)) (setq modules (list modules)))
  (let ((*package* (find-package :ccl)))
    (dolist (m modules t)
      (ppc-require-module m force-load))))


(defun target-xcompile-level-1 (target &optional force)
  (target-compile-modules (target-level-1-modules target) target force))

(defun standard-boot-image-name (&optional (target (backend-name *host-backend*)))
  (ecase target
    (:darwinppc32 "ppc-boot.image")
    (:linuxppc32 "ppc-boot")
    (:darwinppc64 "ppc-boot64.image")
    (:linuxppc64 "ppc-boot64")
    (:linuxx8664 "x86-boot64")))

(defun standard-kernel-name (&optional (target (backend-name *host-backend*)))
  (ecase target
    (:darwinppc32 "dppccl")
    (:linuxppc32 "ppccl")
    (:darwinppc64 "dppccl64")
    (:linuxppc64 "ppccl64")
    (:linuxx8664 "lx86cl64")))

(defun standard-image-name (&optional (target (backend-name *host-backend*)))
  (ecase target
    (:darwinppc32 "dppccl.image")
    (:linuxppc32 "PPCCL")
    (:darwinppc64 "dppccl64.image")
    (:linuxppc64 "PPCCL64")
    (:linuxx8664 "LX86CL64")))

(defun kernel-build-directory (&optional (target (backend-name *host-backend*)))
  (ecase target
    (:darwinppc32 "darwinppc")
    (:linuxppc32 "linuxppc")
    (:darwinppc64 "darwinppc64")
    (:linuxppc64 "linuxppc64")
    (:linuxx8664 "linuxx8664")))

(defun rebuild-ccl (&key full clean kernel force (reload t) exit reload-arguments)
  (when full
    (setq clean t kernel t reload t))
  (let* ((cd (current-directory)))
    (unwind-protect
         (progn
           (setf (current-directory) "ccl:")
           (when clean
             (dolist (f (directory
                         (merge-pathnames
                          (make-pathname :name :wild
                                         :type (pathname-type *.fasl-pathname*))
                          "ccl:**;")))
               (delete-file f)))
           (when kernel
             (when (or clean force)
               ;; Do a "make -k clean".
               (run-program "make"
                            (list "-k"
                                  "-C"
                                  (format nil "lisp-kernel/~a"
                                          (kernel-build-directory))
                                  "clean")))
             (format t "~&;Building lisp-kernel ...")
             (with-output-to-string (s)
               (multiple-value-bind
                   (status exit-code)
                   (external-process-status 
                    (run-program "make"
                                 (list "-k" "-C"
                                       (format nil "lisp-kernel/~a"
                                               (kernel-build-directory)))
                                 :output s
                                 :error s))
                 (if (and (eq :exited status) (zerop exit-code))
                   (progn  (format t "~&;Kernel built successfully.") (sleep 1))
                   (error "Error(s) during kernel compilation.~%~a"
                          (get-output-stream-string s))))))
           (compile-ccl (not (null force)))
           (if force (xload-level-0 :force) (xload-level-0))
           (when reload
             (with-input-from-string (cmd (format nil
                                                  "(save-application ~s)"
                                                  (standard-image-name)))
               (with-output-to-string (output)
                 (multiple-value-bind (status exit-code)
                     (external-process-status
                      (run-program
                       (format nil "./~a" (standard-kernel-name))
                       (list* "--image-name" (standard-boot-image-name)
                              reload-arguments)
                       :input cmd
                       :output output
                       :error output))
                   (if (and (eq status :exited)
                            (eql exit-code 0))
                     (format t "~&;Wrote heap image: ~s"
                             (truename (format nil "ccl:~a"
                                               (standard-image-name))))
                     (error "Errors (~s ~s) reloading boot image:~&~a"
                            status exit-code
                            (get-output-stream-string output)))))))
           (when exit
             (quit)))
      (setf (current-directory) cd))))
                                                  
               
