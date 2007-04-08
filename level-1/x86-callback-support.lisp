;;;
;;;   Copyright (C) 2005-2006 Clozure Associates and contributors
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

(defstatic *callback-alloc-lock* (make-lock))

;;; 
(defun %make-executable-page ()
  (#_mmap (%null-ptr)
          (#_getpagesize)
          (logior #$PROT_READ #$PROT_WRITE #$PROT_EXEC)
          (logior #$MAP_PRIVATE #$MAP_ANON)
          -1
          0))

(defstatic *available-bytes-for-callbacks* 0)
(defstatic *current-callback-page* nil)

(defun reset-callback-storage ()
  (setq *available-bytes-for-callbacks* (#_getpagesize)
        *current-callback-page* (%make-executable-page)))

(defun %allocate-callback-pointer (n)
  (with-lock-grabbed (*callback-alloc-lock*)
    (when (< *available-bytes-for-callbacks* n)
      (reset-callback-storage))
    (decf *available-bytes-for-callbacks* n)
    (values (%inc-ptr *current-callback-page* *available-bytes-for-callbacks*))))


  
(defun make-callback-trampoline (index &optional monitor-exception-ports)
  (declare (ignorable monitor-exception-ports))
  (let* ((p (%allocate-callback-pointer 16))
         (addr #.(subprim-name->offset '.SPcallback)))
    (setf (%get-unsigned-byte p 0) #x41 ; movl $n,%r11d
          (%get-unsigned-byte p 1) #xc7
          (%get-unsigned-byte p 2) #xc3
          (%get-unsigned-byte p 3) (ldb (byte 8 0) index)
          (%get-unsigned-byte p 4) (ldb (byte 8 8) index)
          (%get-unsigned-byte p 5) (ldb (byte 8 16) index)
          (%get-unsigned-byte p 6) (ldb (byte 8 24) index)
          (%get-unsigned-byte p 7) #xff  ; jmp *
          (%get-unsigned-byte p 8) #x24
          (%get-unsigned-byte p 9) #x25
          (%get-unsigned-byte p 10) (ldb (byte 8 0) addr)
          (%get-unsigned-byte p 11) (ldb (byte 8 8) addr)
          (%get-unsigned-byte p 12) (ldb (byte 8 16) addr)
          (%get-unsigned-byte p 13) (ldb (byte 8 24) addr))
    p))
          
  
