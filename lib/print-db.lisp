; -*- Mode:Lisp; Package:CCL; -*-
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


(defmacro print-db (&rest forms &aux)
  `(multiple-value-prog1
     (progn ,@(print-db-aux forms))
     (terpri *trace-output*)))

(defun print-db-aux (forms)
   (when forms
     (cond ((stringp (car forms))
            `((print ',(car forms) *trace-output*)
              ,@(print-db-aux (cdr forms))))
           ((null (cdr forms))
            `((print ',(car forms) *trace-output*)
              (let ((values (multiple-value-list ,(car forms))))
                (prin1 (car values) *trace-output*)
                (apply #'values values))))
           (t `((print ',(car forms) *trace-output*)
                (prin1 ,(car forms) *trace-output*)
                ,@(print-db-aux (cdr forms)))))))


