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


; l0-cfm-support.lisp











; Bootstrapping. Real version is in l1-aprims.
; Called by expansion of with-pstrs

(defun byte-length (string &optional script start end)
    (declare (ignore script))
    (when (or start end)
      (error "Don't support start or end args yet"))
    (if (base-string-p string)
      (length string)
      (error "Don't support non base-string yet.")))



(def-accessor-macros %svref
  nil                                 ; 'external-entry-point
  eep.address
  eep.name
  eep.container)

(defun %cons-external-entry-point (name &optional container)
  (%istruct 'external-entry-point nil name container))

(defun external-entry-point-p (x)
  (istruct-typep x 'external-entry-point))

(def-accessor-macros %svref
    nil                                 ;'foreign-variable
  fv.addr                               ; a MACPTR, or nil
  fv.name                               ; a string
  fv.type                               ; a foreign type
  fv.container                          ; containing library
  )

(defun %cons-foreign-variable (name type &optional container)
  (%istruct 'foreign-variable nil name type container))

(def-accessor-macros %svref
    nil					;'shlib
  shlib.soname
  shlib.pathname
  shlib.opened-by-lisp-kernel
  shlib.map
  shlib.base
  shlib.opencount)

(defun %cons-shlib (soname pathname map base)
  (%istruct 'shlib soname pathname nil map base 0))

(defvar *rtld-next*)
(defvar *rtld-default*)
(setq *rtld-next* (%int-to-ptr #xFFFFFFFF)
      *rtld-default* (%int-to-ptr 0))

#+linuxppc-target
(progn
;;; I can't think of a reason to change this.
(defvar *dlopen-flags* nil)
(setq *dlopen-flags* (logior #$RTLD_GLOBAL #$RTLD_NOW))
)

(defvar *eeps* nil)

(defvar *fvs* nil)

(defun eeps ()
  (or *eeps*
      (setq *eeps* (make-hash-table :test #'equal))))

(defun fvs ()
  (or *fvs*
      (setq *fvs* (make-hash-table :test #'equal))))

(defun unload-foreign-variables (lib)
  (let* ((fvs (fvs)))
    (when fvs
      (maphash #'(lambda (k fv)
                   (declare (ignore k))
                   (when (eq (fv.container fv) lib)
                     (setf (fv.addr fv) nil)))
               fvs))))

(defun generate-external-functions (path)
  (let* ((names ()))
    (maphash #'(lambda (k ignore)
		 (declare (ignore ignore))
		 (push k names)) (eeps))
    (with-open-file (stream path
			    :direction :output
			    :if-exists :supersede
			    :if-does-not-exist :create)
      (dolist (k names) (format stream "~&extern void * ~a();" k))
     
      (format stream "~&external_function external_functions[] = {")
      (dolist (k names) (format stream "~&~t{~s,~a}," k k))
      (format stream "~&~t{0,0}~&};"))))

    
(defvar *shared-libraries* nil)

#+linux-target
(progn

(defun soname-ptr-from-link-map (map)
  (with-macptrs ((dyn-strings)
		 (dynamic-entries (pref map :link_map.l_ld)))
    (let* ((soname-offset nil))
      ;;; Walk over the entries in the file's dynamic segment;
      ;;; the last such entry will have a tag of #$DT_NULL.
      ;;; Note the (loaded) address of the dynamic string table
      ;;; and the offset of the #$DT_SONAME string in that string
      ;;; table.
      (loop
	  (case (pref dynamic-entries :<E>lf32_<D>yn.d_tag)
	    (#. #$DT_NULL (return))
	    (#. #$DT_SONAME
		(setq soname-offset (pref dynamic-entries
					  :<E>lf32_<D>yn.d_un.d_val)))
	    (#. #$DT_STRTAB
		(%setf-macptr dyn-strings
			      (pref dynamic-entries
				    :<E>lf32_<D>yn.d_un.d_ptr))))
	  (%setf-macptr dynamic-entries
			(%inc-ptr dynamic-entries
				  (record-length :<E>lf32_<D>yn))))
      (if (and soname-offset
	       (not (%null-ptr-p dyn-strings)))
	(%inc-ptr dyn-strings soname-offset)
	;; Use the full pathname of the library.
	(pref map :link_map.l_name)))))

(defun shared-library-at (base)
  (dolist (lib *shared-libraries*)
    (when (eql (shlib.base lib) base)
      (return lib))))

(defun shared-library-with-name (name)
  (let* ((namelen (length name)))
    (dolist (lib *shared-libraries*)
      (let* ((libname (shlib.soname lib)))
	(when (%simple-string= name libname 0 0 namelen (length libname))
	  (return lib))))))

(defun shlib-from-map-entry (m)
  (let* ((base (%int-to-ptr (pref m :link_map.l_addr))))
    (or (let* ((existing-lib (shared-library-at base)))
	  (when (and existing-lib (null (shlib.map existing-lib)))
	    (setf (shlib.map existing-lib) m
		  (shlib.pathname existing-lib)
		  (%get-cstring (pref m :link_map.l_name))
		  (shlib.base existing-lib) base))
	  existing-lib)
        (let* ((soname-ptr (soname-ptr-from-link-map m))
               (soname (unless (%null-ptr-p soname-ptr) (%get-cstring soname-ptr)))
               (pathname (%get-cstring (pref m :link_map.l_name)))
	       (shlib (shared-library-with-name soname)))
	  (if shlib
	    (setf (shlib.map shlib) m
		  (shlib.base shlib) base
		  (shlib.pathname shlib) pathname)
	    (push (setq shlib (%cons-shlib soname pathname m base))
		  *shared-libraries*))
          shlib))))


(defun %link-map-address ()
  (let* ((r_debug (foreign-symbol-address "_r_debug")))
    (if r_debug
      (pref r_debug :r_debug.r_map)
      (let* ((p (or (foreign-symbol-address "_dl_loaded")
		    (foreign-symbol-address "_rtld_global"))))
	(if p
	  (%get-ptr p))))))

(defun %walk-shared-libraries (f)
  (let* ((loaded (%link-map-address)))
    (do* ((map (pref loaded :link_map.l_next) (pref map :link_map.l_next)))
         ((%null-ptr-p map))
      (funcall f map))))


(defun %dlopen-shlib (l)
  (with-cstrs ((n (shlib.soname l)))
    (ff-call (%kernel-import target::kernel-import-GetSharedLibrary)
	     :address n
	     :unsigned-fullword *dlopen-flags*
	     :void)))
  
(defun init-shared-libraries ()
  (when (null *shared-libraries*)
    (%walk-shared-libraries #'shlib-from-map-entry)
    (dolist (l *shared-libraries*)
      ;;; It seems to be necessary to open each of these libraries
      ;;; yet again, specifying the RTLD_GLOBAL flag.
      (%dlopen-shlib l)
      (setf (shlib.opened-by-lisp-kernel l) t))))

(init-shared-libraries)

;;; Walk over all registered entrypoints, invalidating any whose container
;;; is the specified library.  Return true if any such entrypoints were
;;; found.
(defun unload-library-entrypoints (lib)
  (let* ((count 0))
    (declare (fixnum count))
    (maphash #'(lambda (k eep)
		 (declare (ignore k))
		 (when (eq (eep.container eep) lib)
		   (setf (eep.address eep) nil)
		   (incf count)))
	     (eeps))    
    (not (zerop count))))


                     
                     

(defun open-shared-library (name)
  (let* ((link-map  (with-cstrs ((name name))
                      (ff-call
		       (%kernel-import target::kernel-import-GetSharedLibrary)
		       :address name
		       :unsigned-fullword *dlopen-flags*
		       :address))))
    (if (%null-ptr-p link-map)
      (error "Error opening shared library ~s: ~a" name (dlerror))
      (prog1 (let* ((lib (shlib-from-map-entry link-map)))
	       (incf (shlib.opencount lib))
	       lib)
	(%walk-shared-libraries
	 #'(lambda (map)
	     (unless (shared-library-at
		      (%int-to-ptr (pref map :link_map.l_addr)))
	       (let* ((new (shlib-from-map-entry map)))
		 (%dlopen-shlib new)))))))))

)


#+darwinppc-target
(progn

(defun shared-library-with-header (header)
  (dolist (lib *shared-libraries*)
    (when (eql (shlib.map lib) header)
      (return lib))))

(defun shared-library-with-module (module)
  (dolist (lib *shared-libraries*)
    (when (eql (shlib.base lib) module)
      (return lib))))

(defun shared-library-with-name (name &optional (is-unloaded nil))
  (let* ((namelen (length name)))
    (dolist (lib *shared-libraries*)
      (let* ((libname (shlib.soname lib)))
	(when (and (%simple-string= name libname 0 0 namelen (length libname))
		   (or (not is-unloaded) (and (null (shlib.map lib))
					      (null (shlib.base lib)))))
	  (return lib))))))

;;;    
;;; maybe we could fix this up name to get the "real name"
;;; this is might be possible for dylibs but probably not for modules
;;; for now soname and pathname are just the name that the user passed in
;;; if the library is "discovered" later, it is the name the system gave
;;; to it -- usually a full pathname
;;;
;;; header and module are ptr types
;;;
(defun shared-library-from-header-module-or-name (header module name)
  ;; first try to find the library based on its address
  (let ((found-lib (if (%null-ptr-p module)
		       (shared-library-with-header header)
		     (shared-library-with-module module))))
    
    (unless found-lib
      ;; check if the library name is still on our list but has been unloaded
      (setq found-lib (shared-library-with-name name t))
      (if found-lib
	(setf (shlib.map found-lib) header
	      (shlib.base found-lib) module)
	;; otherwise add it to the list
	(push (setq found-lib (%cons-shlib name name header module))
	      *shared-libraries*)))
    found-lib))


(defun open-shared-library (name)
  (rlet ((type :signed))
    (let ((result (with-cstrs ((cname name))
		    (ff-call (%kernel-import target::kernel-import-GetSharedLibrary)
			     :address cname
			     :address type
			     :address))))
	(cond
	 ((= 1 (pref type :signed))
	  ;; dylib
	  (shared-library-from-header-module-or-name result (%null-ptr) name))
	 ((= 2 (pref type :signed))
	  ;; bundle
	  (shared-library-from-header-module-or-name (%null-ptr) result name))
	 ((= 0 (pref type :signed))
	  ;; neither a dylib nor bundle was found
	  (error "Error opening shared library ~s: ~a" name
		 (%get-cstring result)))
	 (t (error "Unknown error opening shared library ~s." name))))))

;;; Walk over all registered entrypoints, invalidating any whose container
;;; is the specified library.  Return true if any such entrypoints were
;;; found.
;;;
;;; SAME AS LINUX VERSION
;;;
(defun unload-library-entrypoints (lib)
  (let* ((count 0))
    (declare (fixnum count))
    (maphash #'(lambda (k eep)
		 (declare (ignore k))
		 (when (eq (eep.container eep) lib)
		   (setf (eep.address eep) nil)
		   (incf count)))
	     (eeps))    
    (not (zerop count))))

;;;
;;; When restarting from a saved image
;;;
(defun reopen-user-libraries ()
  (dolist (lib *shared-libraries*)
    (setf (shlib.map lib) nil
	  (shlib.base lib) nil))
  (loop
      (let* ((win nil)
	     (lose nil))
	(dolist (lib *shared-libraries*)
	  (let* ((header (shlib.map lib))
		 (module (shlib.base lib)))
	    (unless (and header module)
	      (rlet ((type :signed))
		(let ((result (with-cstrs ((cname (shlib.soname lib)))
				(ff-call (%kernel-import target::kernel-import-GetSharedLibrary)
					 :address cname
					 :address type
					 :address))))
		  (cond
		   ((= 1 (pref type :signed))
		    ;; dylib
		    (setf (shlib.map lib) result
			  (shlib.base lib) (%null-ptr)
			  win t))
		   ((= 2 (pref type :signed))
		    ;; bundle
		    (setf (shlib.map lib) (%null-ptr)
			  (shlib.base lib) result
			  win t))
		   (t
		    ;; neither a dylib nor bundle was found
		    (setq lose t))))))))
	(when (or (not lose) (not win)) (return)))))

;;; end darwinppc-target
)  


(defun ensure-open-shlib (c force)
  (if (or (shlib.map c) (not force))
    *rtld-default*
    (error "Shared library not open: ~s" (shlib.soname c))))

(defun resolve-container (c force)
  (if c
    (ensure-open-shlib c force)
    *rtld-default*
    ))




;;; An "entry" is a fixnum (the low 2 bits are clear) which represents
;;; a 32-bit, word-aligned address.  This should probably only be used
;;; for function entrypoints, since it treats a return value of 0 as
;;; invalid.

(defun foreign-symbol-entry (name &optional (handle *rtld-default*))
  (with-cstrs ((n name))
    (with-macptrs (addr)      
      (%setf-macptr addr
		    (ff-call (%kernel-import target::kernel-import-FindSymbol)
			     :address handle
			     :address n
			     :address))
      (unless (%null-ptr-p addr)	; No function can have address 0
	(macptr->fixnum addr)))))

(defvar *statically-linked* nil)

#+linux-target
(progn
(defvar *dladdr-entry*)
(setq *dladdr-entry* (foreign-symbol-entry "dladdr"))

(defun shlib-containing-address (address &optional name)
  (declare (ignore name))
  (rletZ ((info :<D>l_info))
    (let* ((status (ff-call *dladdr-entry*
                            :address address
                            :address info :signed-fullword)))
      (declare (integer status))
      (unless (zerop status)
        (shared-library-at (pref info :<D>l_info.dli_fbase))))))


(defun shlib-containing-entry (entry &optional name)
  (unless *statically-linked*
    (with-macptrs (p)
      (%setf-macptr-to-object p entry)
      (shlib-containing-address p name))))
)

#+darwinppc-target
(progn
(defvar *dyld-image-count*)
(defvar *dyld-get-image-header*)
(defvar *dyld-get-image-name*)
(defvar *nslookup-symbol-in-image*)
(defvar *nsaddress-of-symbol*)
(defvar *nsmodule-for-symbol*)
(defvar *ns-is-symbol-name-defined-in-image*)

(defun setup-lookup-calls ()
  (setq *dyld-image-count* (foreign-symbol-entry "__dyld_image_count"))
  (setq *dyld-get-image-header* (foreign-symbol-entry "__dyld_get_image_header"))
  (setq *dyld-get-image-name* (foreign-symbol-entry "__dyld_get_image_name"))
  (setq *nslookup-symbol-in-image* (foreign-symbol-entry "_NSLookupSymbolInImage"))
  (setq *nsaddress-of-symbol* (foreign-symbol-entry "_NSAddressOfSymbol"))
  (setq *nsmodule-for-symbol* (foreign-symbol-entry "_NSModuleForSymbol"))
  (setq *ns-is-symbol-name-defined-in-image* (foreign-symbol-entry "_NSIsSymbolNameDefinedInImage")))

(setup-lookup-calls)

;;;
;;; given an entry address (a number) and a symbol name (lisp string)
;;; find the associated dylib or module
;;; if the dylib or module is not found in *shared-libraries* list it is added
;;; if not found in the OS list it returns nil
;;;
;;; got this error before putting in the call to NSIsObjectNameDefinedInImage
;;; dyld: /usr/local/lisp/ccl/dppccl dead lock (dyld operation attempted in a thread already doing a dyld operation)
;;;

(defun shlib-containing-address (addr name)
  (dotimes (i (ff-call *dyld-image-count* :unsigned-fullword))
      (let ((header (ff-call *dyld-get-image-header* :unsigned-fullword i :address)))
	(when (and (not (%null-ptr-p header))
		   (or (eql (pref header :mach_header.filetype) #$MH_DYLIB)
		       (eql (pref header :mach_header.filetype) #$MH_BUNDLE)))
	  ;; make sure the image is either a bundle or a dylib
	  ;; (otherwise we will crash, likely OS bug, tested OS X 10.1.5)
	  (with-cstrs ((cname name))
	  	    ;; also we must check is symbol name is defined in the image
	  	    ;; otherwise in certain cases there is a crash, another likely OS bug
	  	    ;; happens in the case where a bundle imports a dylib and then we
	  	    ;; call nslookupsymbolinimage on the bundle image
            (when (/= 0
		      (ff-call *ns-is-symbol-name-defined-in-image* :address header
			       :address cname :unsigned))
	      (let ((symbol (ff-call *nslookup-symbol-in-image* :address header :address cname
				     :unsigned-fullword #$NSLOOKUPSYMBOLINIMAGE_OPTION_RETURN_ON_ERROR
				     :address)))
		(unless (%null-ptr-p symbol)
		  ;; compare the found address to the address we are looking for
		  (let ((foundaddr (ff-call *nsaddress-of-symbol* :address symbol :address)))
		    ;; (format t "Foundaddr ~s~%" foundaddr)
		    ;; (format t "Compare to addr ~s~%" addr)
		    (when (eql foundaddr addr)
		      (let* ((imgname (ff-call *dyld-get-image-name* :unsigned-fullword i :address))
			     (libname (unless (%null-ptr-p imgname) (%get-cstring imgname)))
			     (libmodule (%int-to-ptr 0))
			     (libheader (%int-to-ptr 0)))
			(if (eql (pref header :mach_header.filetype) #$MH_BUNDLE)
			    (setf libmodule (ff-call *nsmodule-for-symbol* :address symbol :address))
			  (setf libheader header))
			;; make sure that this shared library is on *shared-libraries*
			(return (shared-library-from-header-module-or-name libheader libmodule libname)))))))))))))

(defun shlib-containing-entry (entry &optional name)
  (when (not name)
  	(error "shared library name must be non-NIL."))
  (with-macptrs (addr)
    (%setf-macptr-to-object addr entry)
    (shlib-containing-address addr name)))

;; end Darwin progn
)

#-(or linux-target darwinppc-target)
(defun shlib-containing-entry (entry &optional name)
  (declare (ignore entry name))
  *rtld-default*)


(defun resolve-eep (e &optional (require-resolution t))
  (or (eep.address e)
      (let* ((name (eep.name e))
	     (container (eep.container e))
             (handle (resolve-container container require-resolution))
	     (addr (foreign-symbol-entry name handle)))
	(if addr
	  (progn
	    (unless container
	      (setf (eep.container e) (shlib-containing-entry addr name)))
	    (setf (eep.address e) addr))
	  (if require-resolution
	    (error "Can't resolve foreign symbol ~s" name))))))



(defun foreign-symbol-address (name &optional (map *rtld-default*))
  (with-cstrs ((n name))
    (let* ((addr (ff-call (%kernel-import target::kernel-import-FindSymbol) :address map :address n :address)))
      (unless (%null-ptr-p addr)
        addr))))

(defun resolve-foreign-variable (fv &optional (require-resolution t))
  (or (fv.addr fv)
      (let* ((name (fv.name fv))
	     (container (fv.container fv))
             (handle (resolve-container container require-resolution))
	     (addr (foreign-symbol-address name handle)))
	(if addr
	  (progn
	    (unless container
	      (setf (fv.container fv) (shlib-containing-address addr name)))
	    (setf (fv.addr fv) addr))
	  (if require-resolution
	    (error "Can't resolve foreign symbol ~s" name))))))

(defun load-eep (name)
  (let* ((eep (or (gethash name (eeps)) (setf (gethash name *eeps*) (%cons-external-entry-point name)))))
    (resolve-eep eep nil)
    eep))

(defun load-fv (name type)
  (let* ((fv (or (gethash name (fvs)) (setf (gethash name *fvs*) (%cons-foreign-variable name type)))))
    (resolve-foreign-variable fv nil)
    fv))

         




#+linux-target
(progn
;;; It's assumed that the set of libraries that the OS has open
;;; (accessible via the _dl_loaded global variable) is a subset of
;;; the libraries on *shared-libraries*.

(defun revive-shared-libraries ()
  (dolist (lib *shared-libraries*)
    (setf (shlib.map lib) nil
	  (shlib.pathname lib) nil
	  (shlib.base lib) nil)
    (let* ((soname (shlib.soname lib)))
      (when soname
	(with-cstrs ((soname soname))
	  (let* ((map (block found
			(%walk-shared-libraries
			 #'(lambda (m)
			     (with-macptrs (libname)
			       (%setf-macptr libname
					     (soname-ptr-from-link-map m))
			       (unless (%null-ptr-p libname)
				 (when (%cstrcmp soname libname)
				   (return-from found  m)))))))))
	    (when map
	      ;;; Sigh.  We can't reliably lookup symbols in the library
	      ;;; unless we open the library (which is, of course,
	      ;;; already open ...)  ourselves, passing in the
	      ;;; #$RTLD_GLOBAL flag.
	      (ff-call (%kernel-import target::kernel-import-GetSharedLibrary)
		       :address soname
		       :unsigned-fullword *dlopen-flags*
		       :void)
	      (setf (shlib.base lib) (%int-to-ptr (pref map :link_map.l_addr))
		    (shlib.pathname lib) (%get-cstring
					  (pref map :link_map.l_name))
		    (shlib.map lib) map))))))))

;;; Repeatedly iterate over shared libraries, trying to open those
;;; that weren't already opened by the kernel.  Keep doing this until
;;; we reach stasis (no failures or no successes.)

(defun %reopen-user-libraries ()
  (loop
      (let* ((win nil)
	     (lose nil))
	(dolist (lib *shared-libraries*)
	  (let* ((map (shlib.map lib)))
	    (unless map
	      (with-cstrs ((soname (shlib.soname lib)))
		(setq map (ff-call
			   (%kernel-import target::kernel-import-GetSharedLibrary)
			   :address soname
			   :unsigned-fullword *dlopen-flags*
			   :address))
		(if (%null-ptr-p map)
		  (setq lose t)
		  (setf (shlib.pathname lib)
			(%get-cstring (pref map :link_map.l_name))
			(shlib.base lib)
			(%int-to-ptr (pref map :link_map.l_addr))
			(shlib.map lib) map
			win t))))))
	(when (or (not lose) (not win)) (return)))))
)


(defun refresh-external-entrypoints ()
  #+linuxppc-target
  (setq *statically-linked* (not (eql 0 (%get-kernel-global 'ppc::statically-linked))))
  (%revive-macptr *rtld-next*)
  (%revive-macptr *rtld-default*)
  #+linuxppc-target
  (unless *statically-linked*
    (setq *dladdr-entry* (foreign-symbol-entry "dladdr"))
    (revive-shared-libraries)
    (%reopen-user-libraries))
  #+darwinppc-target
  (progn
    (setup-lookup-calls)
    (reopen-user-libraries))
  (when *eeps*
    (without-interrupts 
     (maphash #'(lambda (k v) 
                  (declare (ignore k)) 
                  (setf (eep.address v) nil) 
                  (resolve-eep v nil))
              *eeps*)))
  (when *fvs*
    (without-interrupts
     (maphash #'(lambda (k v)
                  (declare (ignore k))
                  (setf (fv.addr v) nil)
                  (resolve-foreign-variable v nil))
              *fvs*))))


