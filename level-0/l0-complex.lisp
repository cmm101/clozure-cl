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

(eval-when (:compile-toplevel)
  (require "NUMBER-MACROS"))

(defun coerce-to-complex-type (num type)
  (cond ((complexp num)
         (let ((real (%realpart num))
               (imag (%imagpart num)))
           (if (and (typep real type)
                    (typep imag type))
             num
             (complex (coerce real type)
                      (coerce imag type)))))
        (t (complex (coerce num type)))))

; end of l0-complex.lisp
