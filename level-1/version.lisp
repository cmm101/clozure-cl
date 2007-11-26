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

(defparameter *openmcl-major-version* 1)
(defparameter *openmcl-minor-version* 2)
(defparameter *openmcl-revision* 0)
;;; May be set by xload-level-0
(defvar *openmcl-svn-revision* nil)
(defparameter *openmcl-dev-level* nil)

(defparameter *openmcl-version* (format nil "~d.~d~@[.~d~]~@[-r~a~] (~@[~A: ~]~~A)"
					*openmcl-major-version*
					*openmcl-minor-version*
					(unless (zerop *openmcl-revision*)
					  *openmcl-revision*)
					*openmcl-svn-revision*
                                        *openmcl-dev-level*))




;;; end
