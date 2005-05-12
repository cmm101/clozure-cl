;;;-*- Mode: Lisp; Package: CCL -*-
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

;;; ppc-callback-support.lisp
;;;
;;; Support for PPC callbacks



;; This is machine-dependent (it conses up a piece of "trampoline" code
;; which calls a subprim in the lisp kernel.)
(defun make-callback-trampoline (index &optional monitor-exception-ports)
  (declare (ignorable monitor-exception-ports))
  (macrolet ((ppc-lap-word (instruction-form)
               (uvref (uvref (compile nil `(lambda (&lap 0) (ppc-lap-function () ((?? 0)) ,instruction-form))) 0) 0)))
    (let* ((subprim
	    #+eabi-target
	     #.(subprim-name->offset '.SPeabi-callback)
	     #-eabi-target
	     (if monitor-exception-ports
	       #.(subprim-name->offset '.SPcallbackX)
	       #.(subprim-name->offset '.SPcallback)))
           (p (malloc 12)))
      (setf (%get-long p 0) (logior (ldb (byte 8 16) index)
                                    (ppc-lap-word (lis 11 ??)))   ; unboxed index
            (%get-long p 4) (logior (ldb (byte 16 0) index)
                                    (ppc-lap-word (ori 11 11 ??)))
                                   
	    (%get-long p 8) (logior subprim
                                    (ppc-lap-word (ba ??))))
      (ff-call (%kernel-import #.ppc32::kernel-import-makedataexecutable) 
               :address p 
               :unsigned-fullword 12
               :void)
      p)))
