;;;-*- Mode: Lisp; Package: CCL -*-
;;;
;;;   Copyright (C) 1994-2001 Digitool, Inc
;;;   Portions copyright (C) 2001-2003 Clozure Associates
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

(eval-when (:compile-toplevel :execute)
  (require "FASLENV" "ccl:xdump;faslenv")
  (require "PPC-LAP"))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require "XFASLOAD" "ccl:xdump;xfasload"))


(defun xload-ppc-lap-word (instruction-form)
  (uvref (uvref (compile nil
                         `(lambda (&lap 0)
                           (ppc-lap-function () ((?? 0))
                            ,instruction-form)))
                  0) #+ppc32-target 0 #+ppc64-target 1))

(defparameter *ppc-macro-apply-code*
  (let* ((code '((mflr loc-pc)
                 (bla .SPheap-rest-arg)
                 (mtlr loc-pc)
                 (vpop arg_z)
                 (mr arg_y fname)
                 (li arg_x '#.$xnotfun)
                 (set-nargs 3)
                 (ba .SPksignalerr))))
    (make-array (length code)
                :element-type '(unsigned-byte 32)
                :initial-contents
                (mapcar #'xload-ppc-lap-word code))))


(defun ppc-fixup-macro-apply-code ()
  (let* ((codev *ppc-macro-apply-code*))
    (setf (uvref codev 5)
          (logior (logand #xffff00000 (uvref *ppc-macro-apply-code* 5))
                  (target-arch-case
                   (:ppc32 (ash $xnotfun ppc32::fixnumshift))
                   (:ppc64 (ash $xnotfun ppc64::fixnumshift)))))
    codev))


(defparameter *ppc-closure-trampoline-code*
  (let* ((code '((ba .SPcall-closure))))
    (make-array (length code)
                :element-type '(unsigned-byte 32)
                :initial-contents
                (mapcar #'xload-ppc-lap-word code))))


;;; For now, do this with a UUO so that the kernel can catch it.
(defparameter *ppc-udf-code*
  (let* ((code '((uuo_interr #.arch::error-udf-call 0))))
    (make-array (length code)
                :element-type '(unsigned-byte 32)
                :initial-contents
                (mapcar #'xload-ppc-lap-word code))))


(defparameter *ppc32-xload-backend*
  (make-backend-xload-info
   :name #+darwinppc-target :darwinppc32 #+linuxppc-target :linuxppc32
   :macro-apply-code-function 'ppc-fixup-macro-apply-code
   :closure-trampoline-code *ppc-closure-trampoline-code*
   :udf-code *ppc-udf-code*
   :default-image-name
   #+linuxppc-target "ccl:ccl;ppc-boot"
   #+darwinppc-target "ccl:ccl;ppc-boot.image"
   :default-startup-file-name
   #+linuxppc-target "level-1.pfsl"
   #+darwinppc-target "level-1.dfsl"
   :subdirs '("ccl:level-0;PPC;PPC32;" "ccl:level-0;PPC;")
   :compiler-target-name
   #+linuxppc-target :linuxppc32
   #+darwinppc-target :darwinppc32
))

(add-xload-backend *ppc32-xload-backend*)

(defparameter *ppc64-xload-backend*
  (make-backend-xload-info
   :name #+darwinppc-target :darwinppc64 #+linuxppc-target :linuxppc64
   :macro-apply-code-function 'ppc-fixup-macro-apply-code
   :closure-trampoline-code *ppc-closure-trampoline-code*
   :udf-code *ppc-udf-code*
   :default-image-name
   #+linuxppc-target "ccl:ccl;ppc-boot64"
   #+darwinppc-target "ccl:ccl;ppc-boot64.image"
   :default-startup-file-name
   #+linuxppc-target "level-1.p64fsl"
   #+darwinppc-target "level-1.d64fsl"
   :subdirs '("ccl:level-0;PPC;PPC64;" "ccl:level-0;PPC;")
   :compiler-target-name
   #+linuxppc-target :linuxppc64
   #+darwinppc-target :darwinppc64
))
(add-xload-backend *ppc64-xload-backend*)

#+ppc32-target
(progn
(setq *xload-default-backend* *ppc32-xload-backend*)
)

#+ppc64-target
(progn

  (setq *xload-default-backend* *ppc64-xload-backend*))

(defun Xcompile-directory (dir &optional force)
  (target-xcompile-directory (backend-name *host-backend*) dir  force))

(defun Xcompile-level-0 (&optional force)
  (target-xcompile-level-0 (backend-name *host-backend*) force))

(defun xload-level-0 (&optional (recompile t))
  (target-xload-level-0 (backend-name *host-backend*) recompile))


