;;;-*-Mode: LISP; Package: CCL -*-
;;;
;;;   Copyright (C) 1994-2001 Digitool, Inc
;;;   Portions copyright (C) 2001 Clozure Associates
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

;;pathnames.lisp Pathnames for Coral Common LISP
(in-package "CCL")

(eval-when (eval compile)
  (require 'level-2)
  (require 'backquote)
)
;(defconstant $accessDenied -5000) ; put this with other errnos
(defconstant $afpAccessDenied -5000) ; which name to use?



;-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_
;ANSI CL logical pathnames


(defvar *pathname-translations-pathname*
  (make-pathname :host "ccl" :type "pathname-translations"))

(defun load-logical-pathname-translations (host)
  ;(setq host (verify-logical-host-name host))
  (when (not (%str-assoc host %logical-host-translations%))
    (setf (logical-pathname-translations host)
          (with-open-file (file (merge-pathnames (make-pathname :name host :defaults nil)
                                                 *pathname-translations-pathname*)
                                :element-type 'base-char)
            (read file)))
    T))

(defun back-translate-pathname (path &optional hosts)
  (let ((newpath (back-translate-pathname-1 path hosts)))
    (cond ((equalp path newpath)
	   ;; (fcomp-standard-source path)
	   (namestring (pathname path)))
          (t newpath))))


(defun back-translate-pathname-1 (path &optional hosts)
  (dolist (host %logical-host-translations%)
    (when (or (null hosts) (member (car host) hosts :test 'string-equal))
      (dolist (trans (cdr host))
        (when (pathname-match-p path (cadr trans))
          (let* (newpath)          
            (setq newpath (translate-pathname path (cadr trans) (car trans) :reversible t))
            (return-from back-translate-pathname-1 
              (if  (equalp path newpath) path (back-translate-pathname-1 newpath hosts))))))))
  path)



; must be after back-translate-pathname
(defun physical-pathname-p (path)
  (let* ((path (pathname path))
         (dir (pathname-directory path)))
    (and dir
         (or (not (logical-pathname-p path))
             (not (null (memq (pathname-host path) '(nil :unspecific))))))))



;-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_
;File or directory Manipulations

(defun unix-rename (old-name new-name)
  (with-cstrs ((old old-name)
               (new new-name))
    (let* ((res (#_rename old new)))
      (declare (fixnum res))
      (if (zerop res)
        (values t nil)
        (values nil (%get-errno))))))

(defun rename-file (file new-name &key (if-exists :error))
  "Rename FILE to have the specified NEW-NAME. If FILE is a stream open to a
  file, then the associated file is renamed."
  (let* ((original (truename file))
	 (original-namestring (native-translated-namestring original))
	 (new-name (merge-pathnames new-name original))
	 (new-namestring (native-translated-namestring new-name)))
    (unless new-namestring
      (error "~S can't be created." new-name))
    (unless (and (probe-file new-name)
		 (not (if-exists if-exists new-name)))
      (multiple-value-bind (res error)
	                   (unix-rename original-namestring
					new-namestring)
	(unless res
	  (error "Failed to rename ~A to ~A: ~A"
		 original new-name error))
	(when (streamp file)
	  (setf (file-stream-filename file)
		(namestring (native-to-pathname new-namestring))))
	(values new-name original (truename new-name))))))


(defun copy-file (source-path dest-path &key (if-exists :error)
			      (preserve-attributes nil))
  (let* ((original (truename source-path))
	 (original-namestring (native-translated-namestring original))
	 (new-name (merge-pathnames dest-path original))
	 (new-namestring (native-translated-namestring new-name))
	 (flags (if preserve-attributes "-pf" "-f")))
    (unless new-namestring
      (error "~S can't be created." new-name))
    (unless (and (probe-file new-name)
		 (not (if-exists if-exists new-name)))
      (let* ((proc (run-program "/bin/cp"
				`(,flags ,original-namestring ,new-namestring)
				:wait t))
	     (exit-code (external-process-%exit-code proc)))
	(unless (zerop exit-code)
	  (error "Error copying ~s to ~s: ~a"
		 source-path dest-path (%strerror exit-code)))
	(values new-name original (truename new-name))))))


;;; It's not clear that we can support anything stronger than
;;; "advisory" ("you pretend the file's locked & I will too") file
;;; locking under Darwin.


(defun lock-file (path)
  (break "lock-file ? ~s" path))

(defun unlock-file (path)
  (break "unlock-file ? ~s" path))

(defun create-directory (path &key (mode #o777))
  (let* ((pathname (translate-logical-pathname (merge-pathnames path)))
	 (created-p nil)
	 (parent-dirs (let* ((pd (pathname-directory pathname)))
			(if (eq (car pd) :relative)
			  (pathname-directory (merge-pathnames
					       pathname
					       (mac-default-directory)))
			  pd)))
	 (nparents (length parent-dirs)))
    (when (wild-pathname-p pathname)
      (error 'file-error :error-type "Inappropriate use of wild pathname ~s"
	     :pathname pathname))
    (do* ((i 1 (1+ i)))
	 ((> i nparents) (values pathname created-p))
      (declare (fixnum i))
      (let* ((parent (make-pathname
		      :name :unspecific
		      :type :unspecific
		      :host (pathname-host pathname)
		      :device (pathname-device pathname)
		      :directory (subseq parent-dirs 0 i)))
	     (parent-name (native-translated-namestring parent))
	     (parent-kind (%unix-file-kind parent-name)))

	(if parent-kind
	  (unless (eq parent-kind :directory)
	    (error 'simple-file-error
		   :error-type "Can't create directory ~s, since file ~a exists and is not a directory"
		   :pathname pathname
		   :format-arguments (list parent-name)))
	  (let* ((result (%mkdir parent-name mode)))
	    (declare (fixnum result))
	    (if (< result 0)
	      (signal-file-error result parent-name)
	      (setq created-p t))))))))


(defun ensure-directories-exist (pathspec &key verbose (mode #o777))
  "Test whether the directories containing the specified file
  actually exist, and attempt to create them if they do not.
  The MODE argument is an extension to control the Unix permission
  bits.  Portable programs should avoid using the :MODE keyword
  argument."
  (let* ((pathname (make-directory-pathname :directory (pathname-directory (translate-logical-pathname (merge-pathnames pathspec)))))
	 (created-p nil))
    (when (wild-pathname-p pathname)
      (error 'file-error
	     :error-type "Inappropriate use of wild pathname ~s"
	     :pathname pathname))
    (let ((dir (pathname-directory pathname)))
      (if (eq (car dir) :relative)
	(setq dir (pathname-directory (merge-pathnames
				       pathname
				       (mac-default-directory)))))
      (loop for i from 1 upto (length dir)
	    do (let ((newpath (make-pathname
			       :name :unspecific
			       :type :unspecific
			       :host (pathname-host pathname)
			       :device (pathname-device pathname)
			       :directory (subseq dir 0 i))))
		 (unless (probe-file newpath)
		   (let ((namestring (native-translated-namestring newpath)))
		     (when verbose
		       (format *standard-output* "~&Creating directory: ~A~%"
			       namestring))
		     (%mkdir namestring mode)
		     (unless (probe-file newpath)
		       (error 'file-error
			      :pathname namestring
			      :error-type "Can't create directory ~S."))
		     (setf created-p t)))))
      (values pathspec created-p))))

(defun dirpath-to-filepath (path)
  (setq path (translate-logical-pathname (merge-pathnames path)))
  (let* ((dir (pathname-directory path))
         (super (butlast dir))
         (name (car (last dir))))
    (when (eq name :up)
      (setq dir (remove-up (copy-list dir)))
      (setq super (butlast dir))
      (setq name (car (last dir))))
    (when (null super)
      (signal-file-error $xnocreate path))
    (setq path (make-pathname :directory super :name name :defaults nil))))

(defun filepath-to-dirpath (path)
  (let* ((dir (pathname-directory path))
         (rest (file-namestring path)))
    (make-pathname :directory (append dir (list rest)) :defaults nil)))
  


;Takes a pathname, returns the truename of the directory if the pathname
;names a directory, NIL if it names an ordinary file, error otherwise.
;E.g. (directoryp "ccl;:foo:baz") might return #P"hd:mumble:foo:baz:" if baz
;is a dir. - should we doc this - its exported?
(defun directoryp (path)
  (let* ((native (native-translated-namestring path))
	 (realpath (%realpath native)))
    (if realpath (eq (%unix-file-kind realpath) :directory))))
	 

;-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_
;Wildcards



 
;-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_-_
;Directory Traversing

(defmacro with-open-dir ((dirent dir) &body body)
  `(let ((,dirent (%open-dir ,dir)))
     (when ,dirent
       (unwind-protect
	   (progn ,@body)
	 (close-dir ,dirent)))))

(defun directory (path &key (directories nil) ;; include subdirectories
                            (files t)         ;; include files
			    (all t)           ;; include Unix dot files (other than dot and dot dot)
			    (directory-pathnames t) ;; return directories as directory-pathname-p's.
			    test              ;; Only return pathnames matching test
			    (follow-links t)) ;; return truename's of matching files.
  "Return a list of PATHNAMEs, each the TRUENAME of a file that matched the
   given pathname. Note that the interaction between this ANSI-specified
   TRUENAMEing and the semantics of the Unix filesystem (symbolic links..)
   means this function can sometimes return files which don't have the same
   directory as PATHNAME."
  (let* ((keys (list :directories directories ;list defaulted key values
		     :files files
		     :all all
		     :directory-pathnames directory-pathnames
		     :test test
		     :follow-links follow-links))
	 (path (full-pathname (merge-pathnames path) :no-error nil))
	 (dir (directory-namestring path)))
    (declare (dynamic-extent keys))
    (if (null (pathname-directory path))
      (setq dir (directory-namestring (setq path
					    (merge-pathnames path
							     (mac-default-directory))))))
    (assert (eq (car (pathname-directory path)) :absolute) ()
	    "full-pathname returned relative path ~s??" path)
    ;; return sorted in alphabetical order, target-Xload-level-0 depends
    ;; on this.
    (nreverse
     (delete-duplicates (%directory "/" dir path '(:absolute) keys) :test #'equal))))

(defun %directory (dir rest path so-far keys)
  (multiple-value-bind (sub-dir wild rest) (%split-dir rest)
    (%some-specific dir sub-dir wild rest path so-far keys)))

(defun %some-specific (dir sub-dir wild rest path so-far keys)
  (let* ((start 1)
	 (end (length sub-dir))
	 (full-dir (if (eq start end) dir (%str-cat dir (%substr sub-dir start end)))))
    (while (neq start end)
      (let ((pos (position #\/ sub-dir :start start :end end)))
	(push (%path-std-quotes (%substr sub-dir start pos) nil "/:;*") so-far)
	(setq start (%i+ 1 pos))))
    (cond ((null wild)
	   (%files-in-directory full-dir path so-far keys))
	  ((string= wild "**")
	   (%all-directories full-dir rest path so-far keys))
	  (t (%one-wild full-dir wild rest path so-far keys)))))

; for a * or *x*y
(defun %one-wild (dir wild rest path so-far keys)
  (let ((result ()) (all (getf keys :all)) name subdir)
    (with-open-dir (dirent dir)
      (while (setq name (%read-dir dirent))
	(when (and (or all (neq (%schar name 0) #\.))
		   (not (string= name "."))
		   (not (string= name ".."))
		   (%path-pstr*= wild name)
		   (eq (%unix-file-kind (setq subdir (%str-cat dir name)) t) :directory))
	  (let ((so-far (cons (%path-std-quotes name nil "/;:*") so-far)))
	    (declare (dynamic-extent so-far))
	    (setq result
		  (nconc (%directory (%str-cat subdir "/") rest path so-far keys) result))))))
    result))

(defun %files-in-directory (dir path so-far keys)
  (let ((name (pathname-name path))
        (type (pathname-type path))
	(directories (getf keys :directories))
	(files (getf keys :files))
	(directory-pathnames (getf keys :directory-pathnames))
	(test (getf keys :test))
	(follow-links (getf keys :follow-links))
	(all (getf keys :all))
        (result ())
        sub dir-list ans)
    (if (not (or name type))
      (when directories
	(setq ans (if directory-pathnames
		    (%cons-pathname (reverse so-far) nil nil)
		    (%cons-pathname (reverse (cdr so-far)) (car so-far) nil)))
	(when (and ans (or (null test) (funcall test ans)))
	  (setq result (list ans))))
      (with-open-dir (dirent dir)
	(while (setq sub (%read-dir dirent))
	  (when (and (or all (neq (%schar sub 0) #\.))
		     (not (string= sub "."))
		     (not (string= sub ".."))
		     (%file*= name type sub))
	    (setq ans
		  (if (eq (%unix-file-kind (%str-cat dir sub) t) :directory)
		    (when directories
		      (let* ((std-sub (%path-std-quotes sub nil "/;:*")))
			(if directory-pathnames
			  (%cons-pathname (reverse (cons std-sub so-far)) nil nil)
			  (%cons-pathname (or dir-list (setq dir-list (reverse so-far))) std-sub nil))))
		    (when files
		      (multiple-value-bind (name type) (%std-name-and-type sub)
			(%cons-pathname (or dir-list (setq dir-list (reverse so-far))) name type)))))
	    (when (and ans (or (null test) (funcall test ans)))
	      (push (if follow-links (or (probe-file ans) ans) ans) result))))))
    result))

; now for samson:**:*c*:**: we get samson:ccl:crap:barf: twice because
; it matches in two ways
; 1) **=ccl *c*=crap **=barf
; 2) **= nothing *c*=ccl **=crap:barf
; called to match a **
(defun %all-directories (dir rest path so-far keys)
  (let ((do-files nil)
        (do-dirs nil)
        (result nil)
        (name (pathname-name path))
        (type (pathname-type path))
	(all (getf keys :all))
	(test (getf keys :test))
	(directory-pathnames (getf keys :directory-pathnames))
	(follow-links (getf keys :follow-links))
	sub subfile dir-list ans)
    ;; First process the case that the ** stands for 0 components
    (multiple-value-bind (next-dir next-wild next-rest) (%split-dir rest)
      (while (and next-wild ; Check for **/**/ which is the same as **/
		  (string= next-dir "/")
		  (string= next-wild "**"))
        (setq rest next-rest)
        (multiple-value-setq (next-dir next-wild next-rest) (%split-dir rest)))
      (cond ((not (string= next-dir "/"))
	     (setq result
		   (%some-specific dir next-dir next-wild next-rest path so-far keys)))
	    (next-wild
	     (setq result
		   (%one-wild dir next-wild next-rest path so-far keys)))
	    ((or name type)
	     (when (getf keys :files) (setq do-files t))
	     (when (getf keys :directories) (setq do-dirs t)))
	    (t (when (getf keys :directories)
		 (setq sub (if directory-pathnames
			     (%cons-pathname (setq dir-list (reverse so-far)) nil nil)
			     (%cons-pathname (reverse (cdr so-far)) (car so-far) nil)))
		 (when (or (null test) (funcall test sub))
		   (setq result (list (if follow-links (truename sub) sub))))))))
    ; now descend doing %all-dirs on dirs and collecting files & dirs if do-x is t
    (with-open-dir (dirent dir)
      (while (setq sub (%read-dir dirent))
	(when (and (or all (neq (%schar sub 0) #\.))
		   (not (string= sub "."))
		   (not (string= sub "..")))
	  (if (eq (%unix-file-kind (setq subfile (%str-cat dir sub)) t) :directory)
	    (let* ((std-sub (%path-std-quotes sub nil "/;:*"))
		   (so-far (cons std-sub so-far))
		   (subdir (%str-cat subfile "/")))
	      (declare (dynamic-extent so-far))
	      (when (and do-dirs (%file*= name type sub))
		(setq ans (if directory-pathnames
			    (%cons-pathname (reverse so-far) nil nil)
			    (%cons-pathname (or dir-list (setq dir-list (reverse (cdr so-far))))
					    std-sub nil)))
		(when (or (null test) (funcall test ans))
		  (push (if follow-links (truename ans) ans) result)))
	      (setq result (nconc (%all-directories subdir rest path so-far keys) result)))
	    (when (and do-files (%file*= name type sub))
	      (multiple-value-bind (name type) (%std-name-and-type sub)
		(setq ans (%cons-pathname (or dir-list (setq dir-list (reverse so-far))) name type))
		(when (or (null test) (funcall test ans))
		  (push (if follow-links (truename ans) ans) result))))))))
    result))

(defun %split-dir (dir &aux pos)                 ; dir ends in a "/".
  ;"/foo/bar/../x*y/baz/../z*t/"  ->  "/foo/bar/../" "x*y" "/baz/../z*t/"
  (if (null (setq pos (%path-mem "*" dir)))
    (values dir nil nil)
    (let (epos (len (length dir)))
      (setq pos (if (setq pos (%path-mem-last "/" dir 0 pos)) (%i+ pos 1) 0)
            epos (%path-mem "/" dir pos len))
      (when (%path-mem-last-quoted "/" dir 0 pos)
	(signal-file-error $xbadfilenamechar dir #\/))
      (values (unless (%izerop pos) (namestring-unquote (%substr dir 0 pos)))
              (%substr dir pos epos)
              (%substr dir epos len)))))

(defun %path-pstr*= (pattern pstr &optional (p-start 0))
  (assert (eq p-start 0))
  (%path-str*= pstr pattern))

(defun %file*= (name-pat type-pat pstr)
  (when (and (null name-pat) (null type-pat))
    (return-from %file*= T))
  (let* ((end (length pstr))
	 (pos (position #\. pstr :from-end t))
	 (type (and pos (%substr pstr (%i+ pos 1) end)))
	 (name (unless (eq (or pos end) 0) (if pos (%substr pstr 0 pos) pstr))))
    (and (cond ((eq name-pat :unspecific) (null name))
	       ((null name-pat) T)
	       (t (%path-pstr*= name-pat (or name ""))))
	 (cond ((eq type-pat :unspecific) (null type))
	       ((null type-pat) T)
	       (t (%path-pstr*= type-pat (or type "")))))))

(provide "PATHNAMES")
