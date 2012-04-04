(in-package "CCL")

(export '(with-cfstring %get-cfstring with-cfurl))

;;; We could use something like ccl:with-pointer-to-ivector to get a
;;; pointer to the lisp string's underlying vector of UTF-32 code
;;; points to pass to #_CFStringCreateWithBytes.  This would avoid
;;; making an extra copy of the string data, and might be a win when
;;; the strings are large.
(defun %make-cfstring (string)
  (with-encoded-cstrs :utf-8 ((cstr string))
    (#_CFStringCreateWithCString +null-ptr+ cstr #$kCFStringEncodingUTF8)))

(defmacro with-cfstring ((sym string) &body body)
  `(let* ((,sym (%make-cfstring ,string)))
     (unwind-protect
	  (progn ,@body)
       (unless (%null-ptr-p ,sym)
         (external-call "CFRelease" :address ,sym :void)))))

(defun %get-cfstring (cfstring)
  (let* ((len (#_CFStringGetLength cfstring))
	 (noctets (* len 2))
	 (p (#_CFStringGetCharactersPtr cfstring)))
    (if (not (%null-ptr-p p))
      (get-encoded-string #+little-endian-target :utf-16le
			  #-little-endian-target :utf-16be
			  p noctets)
      (rlet ((range #>CFRange))
	(setf (pref range #>CFRange.location) 0
	      (pref range #>CFRange.length) len)
	(%stack-block ((buf noctets))
	  (#_CFStringGetCharacters cfstring range buf)
	  (get-encoded-string #+little-endian-target :utf-16le
			      #-little-endian-target :utf-16be
			      buf noctets))))))
	
(defun %make-cfurl (pathname)
  (let* ((namestring (native-translated-namestring pathname))
	 (noctets (string-size-in-octets namestring :external-format :utf-8))
	 (dir-p (if (directoryp pathname) #$true #$false)))
    (with-encoded-cstrs :utf-8 ((s namestring))
      (#_CFURLCreateFromFileSystemRepresentation +null-ptr+ s noctets dir-p))))

(defmacro with-cfurl ((sym pathname) &body body)
  `(let ((,sym (%make-cfurl ,pathname)))
     (unwind-protect
	  (progn ,@body)
       (unless (%null-ptr-p ,sym)
	 (external-call "CFRelease" :address ,sym :void)))))
