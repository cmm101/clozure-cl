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

(in-package "CCL")

(eval-when (:compile-toplevel :execute)
  #+linuxppc-target
  (require "PPC-LINUX-SYSCALLS")
  #+linuxx8664-target
  (require "X8664-LINUX-SYSCALLS")
  #+darwinppc-target
  (require "DARWINPPC-SYSCALLS")
  #+darwinx8664-target
  (require "DARWINX8664-SYSCALLS")
  #+(and freebsd-target x8664-target)
  (require "X8664-FREEBSD-SYSCALLS")
  )


(defun nanoseconds (n)
  (unless (and (typep n 'fixnum)
               (>= (the fixnum n) 0))
    (check-type n (real 0 #xffffffff)))
  (multiple-value-bind (q r)
      (floor n)
    (if (zerop r)
      (setq r 0)
      (setq r (floor (* r 1000000000))))
    (values q r)))

(defun milliseconds (n)
  (unless (and (typep n 'fixnum)
               (>= (the fixnum n) 0))
    (check-type n (real 0 #xffffffff)))
  (multiple-value-bind (q r)
      (floor n)
    (if (zerop r)
      (setq r 0)
      (setq r (floor (* r 1000))))
    (values q r)))

(defun semaphore-value (s)
  (if (istruct-typep s 'semaphore)
    (semaphore.value s)
    (semaphore-value (require-type s 'semaphore))))

(defun %wait-on-semaphore-ptr (s seconds milliseconds &optional flag)
  (if flag
    (if (istruct-typep flag 'semaphore-notification)
      (setf (semaphore-notification.status flag) nil)
      (report-bad-arg flag 'semaphore-notification)))
  (without-interrupts
   (let* ((status (ff-call
                   (%kernel-import target::kernel-import-wait-on-semaphore)
                   :address s
                   :unsigned seconds
                   :unsigned milliseconds
                   :signed))
          (result (zerop status)))     
     (declare (fixnum status))
     (when flag (setf (semaphore-notification.status flag) result))
     (values result status))))

(defun %process-wait-on-semaphore-ptr (s seconds milliseconds &optional
                                         (whostate "semaphore wait") flag)
  (or (%wait-on-semaphore-ptr s 0 0 flag)
      (with-process-whostate  (whostate)
        (loop
          (when (%wait-on-semaphore-ptr s seconds milliseconds flag)
            (return))))))

  
(defun wait-on-semaphore (s &optional flag (whostate "semaphore wait"))
  "Wait until the given semaphore has a positive count which can be
atomically decremented."
  (%process-wait-on-semaphore-ptr (semaphore-value s) #xffffff 0 whostate flag)
  t)


(defun %timed-wait-on-semaphore-ptr (semptr duration notification)
  (or (%wait-on-semaphore-ptr semptr 0 0 notification)
      (with-process-whostate ("Semaphore timed wait")
        (multiple-value-bind (secs millis) (milliseconds duration)
          (let* ((now (get-internal-real-time))
                 (stop (+ now
                          (* secs 1000)
                          millis)))
            (loop
              (multiple-value-bind (success err)
                  (progn
                    (%wait-on-semaphore-ptr semptr secs millis notification))
                (when success
                  (return t))
                (when (or (not (eql err #$EINTR))
                          (>= (setq now (get-internal-real-time)) stop))
                  (return nil))
                (unless (zerop duration)
                  (let* ((diff (- stop now)))
                    (multiple-value-bind (remaining-seconds remaining-millis)
                        (floor diff 1000)
                      (setq secs remaining-seconds
                            millis remaining-millis)))))))))))

(defun timed-wait-on-semaphore (s duration &optional notification)
  "Wait until the given semaphore has a postive count which can be
atomically decremented, or until a timeout expires."
  (%timed-wait-on-semaphore-ptr (semaphore-value s) duration notification))


(defun %signal-semaphore-ptr (p)
  (ff-call
   (%kernel-import target::kernel-import-signal-semaphore)
   :address p
   :signed-fullword))

(defun signal-semaphore (s)
  "Atomically increment the count of a given semaphore."
  (%signal-semaphore-ptr (semaphore-value s)))

(defun %os-getcwd (buf bufsize)
  ;; Return N < 0, if error
  ;;        N < bufsize: success, string is of length n
  ;;        N > bufsize: buffer needs to be larger.
  (let* ((p (#_getcwd buf bufsize)))
    (declare (dynamic-extent p))
    (if (%null-ptr-p p)
      (let* ((err (%get-errno)))
	(if (eql err (- #$ERANGE))
	  (+ bufsize bufsize)
	  err))
      (dotimes (i bufsize (+ bufsize bufsize))
	(when (eql 0 (%get-byte buf i))
	  (return i))))))
    
    
(defun current-directory-name ()
  "Look up the current working directory of the OpenMCL process; unless
it has been changed, this is the directory OpenMCL was started in."
  (flet ((try-getting-dirname (bufsize)
	   (%stack-block ((buf bufsize))
	     (let* ((len (%os-getcwd buf bufsize)))
	       (cond ((< len 0) (%errno-disp len bufsize))
		     ((< len bufsize)
		      (setf (%get-unsigned-byte buf len) 0)
		      (values (%get-cstring buf) len))
		     (t (values nil len)))))))
    (do* ((string nil)
	  (len 64)
	  (bufsize len len))
	 ((multiple-value-setq (string len) (try-getting-dirname bufsize))
	  string))))


(defun current-directory ()
  (mac-default-directory))

(defun (setf current-directory) (path)
  (cwd path)
  path)

(defun cd (path)
  (cwd path))

(defun %chdir (dirname)
  (with-cstrs ((dirname dirname))
    (syscall syscalls::chdir dirname)))

(defun %mkdir (name mode)
  (let* ((last (1- (length name))))
    (with-cstrs ((name name))
      (when (and (>= last 0)
		 (eql (%get-byte name last) (char-code #\/)))
	(setf (%get-byte name last) 0))
    (syscall syscalls::mkdir name mode))))

(defun getenv (key)
  "Look up the value of the environment variable named by name, in the
OS environment."
  (with-cstrs ((key (string key)))
    (let* ((env-ptr (%null-ptr)))
      (declare (dynamic-extent env-ptr))
      (%setf-macptr env-ptr (#_getenv key))
      (unless (%null-ptr-p env-ptr)
	(%get-cstring env-ptr))))
  )

(defun setenv (key value &optional (overwrite t))
  "Set the value of the environment variable named by name, in the OS
environment. If there is no such environment variable, create it."
  (with-cstrs ((ckey key)
	       (cvalue value))
    (#_setenv ckey cvalue (if overwrite 1 0))))

(defun setuid (uid)
  "Attempt to change the current user ID (both real and effective);
fails unless the OpenMCL process has super-user privileges or the ID
given is that of the current user."
  (syscall syscalls::setuid uid))

(defun setgid (uid)
  "Attempt to change the current group ID (both real and effective);
fails unless the OpenMCL process has super-user privileges or the ID
given is that of a group to which the current user belongs."
  (syscall syscalls::setgid uid))
  

;;; On Linux, "stat" & friends are implemented in terms of deeper,
;;; darker things that need to know what version of the stat buffer
;;; they're talking about.

(defun %stat-values (result stat)
  (if (eql 0 (the fixnum result)) 
      (values
       t
       (pref stat :stat.st_mode)
       (pref stat :stat.st_size)
       #+linux-target
       (pref stat :stat.st_mtim.tv_sec)
       #-linux-target
       (pref stat :stat.st_mtimespec.tv_sec)
       (pref stat :stat.st_ino)
       (pref stat :stat.st_uid)
       (pref stat :stat.st_blksize))
      (values nil nil nil nil nil nil nil)))


(defun %%stat (name stat)
  (with-cstrs ((cname name))
    (%stat-values
     #+linux-target
     (#_ __xstat #$_STAT_VER_LINUX cname stat)
     #-linux-target
     (syscall syscalls::stat cname stat)
     stat)))

(defun %%fstat (fd stat)
  (%stat-values
   #+linux-target
   (#_ __fxstat #$_STAT_VER_LINUX fd stat)
   #-linux-target
   (syscall syscalls::fstat fd stat)
   stat))

(defun %%lstat (name stat)
  (with-cstrs ((cname name))
    (%stat-values
     #+linux-target
     (#_ __lxstat #$_STAT_VER_LINUX cname stat)
     #-linux-target
     (syscall syscalls::lstat cname stat)
     stat)))


;;; Returns: (values t mode size mtime inode uid) on success,
;;;          (values nil nil nil nil nil nil) otherwise
(defun %stat (name &optional link-p)
  (rlet ((stat :stat))
    (if link-p
      (%%lstat name stat)
      (%%stat name stat))))

(defun %fstat (fd)
  (rlet ((stat :stat))
    (%%fstat fd stat)))


(defun %file-kind (mode)
  (when mode
    (let* ((kind (logand mode #$S_IFMT)))
      (cond ((eql kind #$S_IFDIR) :directory)
	    ((eql kind #$S_IFREG) :file)
	    ((eql kind #$S_IFLNK) :link)
	    ((eql kind #$S_IFIFO) :pipe)
	    ((eql kind #$S_IFSOCK) :socket)
	    ((eql kind #$S_IFCHR) :character-special)
	    (t :special)))))

(defun %unix-file-kind (path &optional check-for-link)
  (%file-kind (nth-value 1 (%stat path check-for-link))))

(defun %unix-fd-kind (fd)
  (if (isatty fd)
    :tty
    (%file-kind (nth-value 1 (%fstat fd)))))

(defun %uts-string (result idx buf)
  (if (eql 0 result)
    (%get-cstring (%inc-ptr buf (* #+linux-target #$_UTSNAME_LENGTH
				   #+darwin-target #$_SYS_NAMELEN
                                   #+freebsd-target #$SYS_NMLN idx)))
    "unknown"))


#+linux-target
(defun %uname (idx)
  (%stack-block ((buf (* #$_UTSNAME_LENGTH 6)))  
    (%uts-string (syscall syscalls::uname buf) idx buf)))

#+darwin-target
(defun %uname (idx)
  (%stack-block ((buf (* #$_SYS_NAMELEN 5)))
    (%uts-string (#_uname buf) idx buf)))

#+freebsd-target
(defun %uname (idx)
  (%stack-block ((buf (* #$SYS_NMLN 5)))
    (%uts-string (#___xuname #$SYS_NMLN buf) idx buf)))

(defun fd-dup (fd)
  (syscall syscalls::dup fd))

(defun fd-fsync (fd)
  (syscall syscalls::fsync fd))

(defun fd-get-flags (fd)
  (syscall syscalls::fcntl fd #$F_GETFL))

(defun fd-set-flags (fd new)
  (syscall syscalls::fcntl fd #$F_SETFL new))

(defun fd-set-flag (fd mask)
  (let* ((old (fd-get-flags fd)))
    (if (< old 0)
      old
      (fd-set-flags fd (logior old mask)))))

(defun fd-clear-flag (fd mask)
  (let* ((old (fd-get-flags fd)))
    (if (< old 0) 
      old
      (fd-set-flags fd (logandc2 old mask)))))


;;; Assume that any quoting's been removed already.
(defun tilde-expand (namestring)
  (let* ((len (length namestring)))
    (if (or (zerop len)
            (not (eql (schar namestring 0) #\~)))
      namestring
      (if (or (= len 1)
              (eql (schar namestring 1) #\/))
        (concatenate 'string (get-user-home-dir (getuid)) (if (= len 1) "/" (subseq namestring 1)))
        (let* ((slash-pos (position #\/ namestring))
               (user-name (subseq namestring 1 slash-pos))
               (uid (or (get-uid-from-name user-name)
                        (error "Unknown user ~s in namestring ~s" user-name namestring))))
          (concatenate 'string (get-user-home-dir uid) (if slash-pos (subseq namestring slash-pos) "/")))))))

                     
    
;;; This doesn't seem to exist on VxWorks.  It's a POSIX
;;; function AFAIK, so the source should be somewhere ...

(defun %realpath (namestring)
  (when (zerop (length namestring))
    (setq namestring (current-directory-name)))
  (%stack-block ((resultbuf #$PATH_MAX))
    (with-cstrs ((name (tilde-expand namestring)))
      (let* ((result (#_realpath name resultbuf)))
        (declare (dynamic-extent result))
        (unless (%null-ptr-p result)
          (%get-cstring result))))))

;;; Return fully resolved pathname & file kind, or (values nil nil)

(defun %probe-file-x (namestring)
  (let* ((realpath (%realpath namestring))
	 (kind (if realpath (%unix-file-kind realpath))))
    (if kind
      (values realpath kind)
      (values nil nil))))

(defun timeval->milliseconds (tv)
    (+ (* 1000 (pref tv :timeval.tv_sec)) (round (pref tv :timeval.tv_usec) 1000)))


(defun %add-timevals (result a b)
  (let* ((seconds (+ (pref a :timeval.tv_sec) (pref b :timeval.tv_sec)))
	 (micros (+ (pref a :timeval.tv_usec) (pref b :timeval.tv_usec))))
    (if (>= micros 1000000)
      (setq seconds (1+ seconds) micros (- micros 1000000)))
    (setf (pref result :timeval.tv_sec) seconds
	  (pref result :timeval.tv_usec) micros)
    result))

(defun %sub-timevals (result a b)
  (let* ((seconds (- (pref a :timeval.tv_sec) (pref b :timeval.tv_sec)))
	 (micros (- (pref a :timeval.tv_usec) (pref b :timeval.tv_usec))))
    (if (< micros 0)
      (setq seconds (1- seconds) micros (+ micros 1000000)))
    (setf (pref result :timeval.tv_sec) seconds
	  (pref result :timeval.tv_usec) micros)
    result))


(defun %%rusage (usage &optional (who #$RUSAGE_SELF))
  (syscall syscalls::getrusage who usage))



(defconstant unix-to-universal-time 2208988800)

(defun %file-write-date (namestring)
  (let* ((date (nth-value 3 (%stat namestring))))
    (if date
      (+ date unix-to-universal-time))))

(defun %file-author (namestring)
  (let* ((uid (nth-value 5 (%stat namestring))))
    (if uid
      (with-macptrs ((pw (#_getpwuid uid)))
        (unless (%null-ptr-p pw)
          (without-interrupts
           (%get-cstring (pref pw :passwd.pw_name))))))))

(defun %utimes (namestring)
  (with-cstrs ((cnamestring namestring))
    (let* ((err (#_utimes cnamestring (%null-ptr))))
      (declare (fixnum err))
      (or (eql err 0)
          (%errno-disp err namestring)))))
         

(defun get-uid-from-name (name)
  (with-cstrs ((name name))
    (let* ((pwent (#_getpwnam name)))
      (unless (%null-ptr-p pwent)
        (pref pwent :passwd.pw_uid)))))

    
(defun isatty (fd)
  (= 1 (#_isatty fd)))

(defun %open-dir (namestring)
  (with-cstrs ((name namestring))
    (let* ((DIR (#_opendir name)))
      (unless (%null-ptr-p DIR)
	DIR))))

(defun close-dir (dir)
  (#_closedir DIR))

(defun %read-dir (dir)
  (let* ((res (#_readdir dir)))
    (unless (%null-ptr-p res)	     
      (%get-cstring (pref res :dirent.d_name)))))

(defun tcgetpgrp (fd)
  (#_tcgetpgrp fd))

(defun getpid ()
  "Return the ID of the OpenMCL OS process."
  (syscall syscalls::getpid))

(defun getuid ()
  "Return the (real) user ID of the current user."
  (syscall syscalls::getuid))

(defun get-user-home-dir (userid)
  "Look up and return the defined home directory of the user identified
by uid. This value comes from the OS user database, not from the $HOME
environment variable. Returns NIL if there is no user with the ID uid."
  (rlet ((pwd :passwd)
         (result :address))
    (do* ((buflen 512 (* 2 buflen)))
         ()
      (%stack-block ((buf buflen))
        (let* ((err (#_getpwuid_r userid pwd buf buflen result)))
          (if (eql 0 err)
            (return (%get-cstring (pref pwd :passwd.pw_dir)))
            (unless (eql err #$ERANGE)
              (return nil))))))))

(defun %delete-file (name)
  (with-cstrs ((n name))
    (syscall syscalls::unlink n)))

(defun os-command (string)
  "Invoke the Posix function system(), which invokes the user's default
system shell (such as sh or tcsh) as a new process, and has that shell
execute command-line.

If the shell was able to find the command specified in command-line, then
exit-code is the exit code of that command. If not, it is the exit code
of the shell itself."
  (with-cstrs ((s string))
    (#_system s)))

(defun %strerror (errno)
  (declare (fixnum errno))
  (if (< errno 0)
    (setq errno (- errno)))
  (with-macptrs (p)
    (%setf-macptr p (#_strerror errno))
    (if (%null-ptr-p p)
      (format nil "OS Error %d" errno)
      (%get-cstring p))))

;;; Kind of has something to do with files, and doesn't work in level-0.
#+linux-target
(defun close-shared-library (lib &key (completely t))
  "If completely is T, set the reference count of library to 0. Otherwise,
decrements it by 1. In either case, if the reference count becomes 0,
close-shared-library frees all memory resources consumed library and causes
any EXTERNAL-ENTRY-POINTs known to be defined by it to become unresolved."
  (let* ((lib (if (typep lib 'string)
		(or (shared-library-with-name lib)
		    (error "Shared library ~s not found." lib))
		(require-type lib 'shlib)))
	 (map (shlib.map lib)))
    (unless (shlib.opened-by-lisp-kernel lib)
      (when map
	(let* ((found nil)
	       (base (shlib.base lib)))
	  (do* ()
	       ((progn		  
		  (#_dlclose map)
		  (or (not (setq found (shlib-containing-address base)))
		      (not completely)))))
	  (when (not found)
	    (setf (shlib.pathname lib) nil
	      (shlib.base lib) nil
	      (shlib.map lib) nil)
            (unload-foreign-variables lib)
	    (unload-library-entrypoints lib)))))))

#+darwin-target
;; completely specifies whether to remove it totally from our list
(defun close-shared-library (lib &key (completely nil))
  "If completely is T, set the reference count of library to 0. Otherwise,
decrements it by 1. In either case, if the reference count becomes 0,
close-shared-library frees all memory resources consumed library and causes
any EXTERNAL-ENTRY-POINTs known to be defined by it to become unresolved."
  (let* ((lib (if (typep lib 'string)
		  (or (shared-library-with-name lib)
		      (error "Shared library ~s not found." lib))
		(require-type lib 'shlib))))
    ;; no possible danger closing libsystem since dylibs can't be closed
    (cond
     ((or (not (shlib.map lib)) (not (shlib.base lib)))
      (error "Shared library ~s uninitialized." (shlib.soname lib)))
     ((and (not (%null-ptr-p (shlib.map lib)))
	   (%null-ptr-p (shlib.base lib)))
      (warn "Dynamic libraries cannot be closed on Darwin."))
     ((and (%null-ptr-p (shlib.map lib))
	   (not (%null-ptr-p (shlib.base lib))))
      ;; we have a bundle type library not sure what to do with the
      ;; completely flag when we open the same bundle more than once,
      ;; Darwin gives back a new module address, so we have multiple
      ;; entries on *shared-libraries* the best we can do is unlink
      ;; the module asked for (or our best guess based on name) and
      ;; invalidate any entries which refer to this container
      (if (= 0 (#_NSUnLinkModule (shlib.base lib) #$NSUNLINKMODULE_OPTION_NONE))
	  (error "Unable to close shared library, NSUnlinkModule failed.")
	(progn
	  (setf (shlib.map lib) nil
		(shlib.base lib) nil)
	  (unload-library-entrypoints lib)
	  (when completely
	    (setq *shared-libraries* (delete lib *shared-libraries*)))))))))



;;; Foreign (unix) processes.

(defun call-with-string-vector (function strings)
  (let ((bufsize (reduce #'+ strings
			 :key #'(lambda (s) (1+ (length (string s))))))
	(argvsize (ash (1+ (length strings)) target::word-shift))
	(bufpos 0)
	(argvpos 0))
    (%stack-block ((buf bufsize) (argv argvsize))
      (flet ((init (s)
	     (multiple-value-bind (sstr start end) (get-sstring s)
               (declare (fixnum start end))
	       (let ((len (- end start)))
                 (declare (fixnum len))
                 (do* ((i 0 (1+ i))
                       (start start (1+ start))
                       (bufpos bufpos (1+ bufpos)))
                      ((= i len))
                   (setf (%get-unsigned-byte buf bufpos)
                         (logand #xff (%scharcode sstr start))))
		 (setf (%get-byte buf (%i+ bufpos len)) 0)
		 (setf (%get-ptr argv argvpos) (%inc-ptr buf bufpos))
		 (setq bufpos (%i+ bufpos len 1))
		 (setq argvpos (%i+ argvpos target::node-size))))))
	(declare (dynamic-extent #'init))
	(map nil #'init strings))
      (setf (%get-ptr argv argvpos) (%null-ptr))
      (funcall function argv))))

(defmacro with-string-vector ((var &rest strings) &body body)
  `(call-with-string-vector #'(lambda (,var) ,@body) ,@strings))

(defloadvar *max-os-open-files* (#_getdtablesize))

(defun %execvp (argv)
  (#_execvp (%get-ptr argv) argv)
  (#_exit #$EX_OSERR))

(defun exec-with-io-redirection (new-in new-out new-err argv)
  (#_setpgid 0 0)
  (if new-in (#_dup2 new-in 0))
  (if new-out (#_dup2 new-out 1))
  (if new-err (#_dup2 new-err 2))
  (do* ((fd 3 (1+ fd)))
       ((= fd *max-os-open-files*) (%execvp argv))
    (declare (fixnum fd))
    (#_close fd)))



#+linux-target
(defun pipe ()
  (%stack-block ((pipes 8))
    (let* ((status (syscall syscalls::pipe pipes)))
      (if (= 0 status)
	(values (%get-long pipes 0) (%get-long pipes 4))
	(%errno-disp status)))))


;;; I believe that the Darwin/FreeBSD syscall infterface is rather ... odd.
;;; Use libc's interface.
#+(or darwin-target freebsd-target)
(defun pipe ()
  (%stack-block ((filedes 8))
    (let* ((status (#_pipe filedes)))
      (if (zerop status)
        (values (paref filedes (:array :int)  0) (paref filedes (:array :int)  1))
        (%errno-disp (%get-errno))))))



(defstruct external-process
  pid
  %status
  %exit-code
  pty
  input
  output
  error
  status-hook
  plist
  token
  core
  args
  (signal (make-semaphore))
  (completed (make-semaphore))
  watched-fd
  watched-stream
  )

(defmethod print-object ((p external-process) stream)
  (print-unreadable-object (p stream :type t :identity t)
    (let* ((status (external-process-%status p)))
      (let* ((*print-length* 3))
	(format stream "~a" (external-process-args p)))
      (format stream "[~d] (~a" (external-process-pid p) status)
      (unless (eq status :running)
	(format stream " : ~d" (external-process-%exit-code p)))
      (format stream ")"))))

(defun get-descriptor-for (object proc close-in-parent close-on-error
				  &rest keys &key direction
				  &allow-other-keys)
  (etypecase object
    ((eql t)
     (values nil nil close-in-parent close-on-error))
    (null
     (let* ((fd (fd-open "/dev/null" (case direction
				       (:input #$O_RDONLY)
				       (:output #$O_WRONLY)
				       (t #$O_RDWR)))))
       (if (< fd 0)
	 (signal-file-error fd "/dev/null"))
       (values fd nil (cons fd close-in-parent) (cons fd close-on-error))))
    ((eql :stream)
     (multiple-value-bind (read-pipe write-pipe) (pipe)
       (case direction
	 (:input
	  (values read-pipe
		  (make-fd-stream write-pipe
				  :direction :output
				  :interactive nil)
		  (cons read-pipe close-in-parent)
		  (cons write-pipe close-on-error)))
	 (:output
	  (values write-pipe
		  (make-fd-stream read-pipe
				  :direction :input
				  :interactive nil)
		  (cons write-pipe close-in-parent)
		  (cons read-pipe close-on-error)))
	 (t
	  (fd-close read-pipe)
	  (fd-close write-pipe)
	  (report-bad-arg direction '(member :input :output))))))
    ((or pathname string)
     (with-open-stream (file (apply #'open object keys))
       (let* ((fd (fd-dup (ioblock-device (stream-ioblock file t)))))
         (values fd
                 nil
                 (cons fd close-in-parent)
                 (cons fd close-on-error)))))
    (fd-stream
     (let ((fd (fd-dup (ioblock-device (stream-ioblock object t)))))
       (values fd
	       nil
	       (cons fd close-in-parent)
	       (cons fd close-on-error))))
    (stream
     (ecase direction
       (:input
	(with-cstrs ((template "lisp-tempXXXXXX"))
	  (let* ((fd (#_mkstemp template)))
	    (if (< fd 0)
	      (%errno-disp fd))
	    (#_unlink template)
	    (loop
              (multiple-value-bind (line no-newline)
                  (read-line object nil nil)
                (unless line
                  (return))
                (let* ((len (length line)))
                  (%stack-block ((buf (1+ len)))
                    (%cstr-pointer line buf)
                    (fd-write fd buf len)
                    (if no-newline
                      (return))
                    (setf (%get-byte buf) (char-code #\newline))
                    (fd-write fd buf 1)))))
	    (fd-lseek fd 0 #$SEEK_SET)
	    (values fd nil (cons fd close-in-parent) (cons fd close-on-error)))))
       (:output
	(multiple-value-bind (read-pipe write-pipe) (pipe)
          (setf (external-process-watched-fd proc) read-pipe
                (external-process-watched-stream proc) object)
          (incf (car (external-process-token proc)))
	  (values write-pipe
		  nil
		  (cons write-pipe close-in-parent)
		  (cons read-pipe close-on-error))))))))

(let* ((external-processes ())
       (external-processes-lock (make-lock)))
  (defun add-external-process (p)
    (with-lock-grabbed (external-processes-lock)
      (push p external-processes)))
  (defun remove-external-process (p)
    (with-lock-grabbed (external-processes-lock)
      (setq external-processes (delete p external-processes))))
  ;; Likewise
  (defun external-processes ()
    (with-lock-grabbed (external-processes-lock)
      (copy-list external-processes)))
  )



(defun monitor-external-process (p)
  (let* ((in-fd (external-process-watched-fd p))
         (out-stream (external-process-watched-stream p))
         (token (external-process-token p))
         (terminated))
    (loop
      (when (and terminated (null in-fd))
        (signal-semaphore (external-process-completed p))
        (return))
      (if in-fd
        (when (fd-input-available-p in-fd *ticks-per-second*)
          (%stack-block ((buf 1024))
            (let* ((n (fd-read in-fd buf 1024)))
              (declare (fixnum n))
              (if (<= n 0)
                (progn
                  (without-interrupts
                   (decf (car token))
                   (fd-close in-fd)
                   (setq in-fd nil)))
                (let* ((string (make-string 1024)))
                  (declare (dynamic-extent string))
                  (%str-from-ptr buf n string)
                  (write-sequence string out-stream :end n)))))))
      (let* ((statusflags (check-pid (external-process-pid p)
                                     (logior
                                      (if in-fd #$WNOHANG 0)
                                      #$WUNTRACED)))
             (oldstatus (external-process-%status p)))
        (cond ((null statusflags)
               (remove-external-process p)
               (setq terminated t))
              ((eq statusflags t))	; Running.
              (t
               (multiple-value-bind (status code core)
                   (cond ((wifstopped statusflags)
                          (values :stopped (wstopsig statusflags)))
                         ((wifexited statusflags)
                          (values :exited (wexitstatus statusflags)))
                         (t
                          (let* ((signal (wtermsig statusflags)))
                            (declare (fixnum signal))
                            (values
                             (if (or (= signal #$SIGSTOP)
                                     (= signal #$SIGTSTP)
                                     (= signal #$SIGTTIN)
                                     (= signal #$SIGTTOU))
                               :stopped
                               :signaled)
                             signal
                             (logtest #$WCOREFLAG statusflags)))))
                 (setf (external-process-%status p) status
                       (external-process-%exit-code p) code
                       (external-process-core p) core)
                 (let* ((status-hook (external-process-status-hook p)))
                   (when (and status-hook (not (eq oldstatus status)))
                     (funcall status-hook p)))
                 (when (or (eq status :exited)
                           (eq status :signaled))
                   (remove-external-process p)
                   (setq terminated t)))))))))
      
(defun run-external-process (proc in-fd out-fd error-fd)
  (call-with-string-vector
   #'(lambda (argv)
       (let* ((child-pid (#_fork)))
	 (declare (fixnum child-pid))
	 (cond ((zerop child-pid)
		;; Running in the child; do an exec
		(without-interrupts
		 (exec-with-io-redirection
		  in-fd out-fd error-fd argv)))
	       ((> child-pid 0)
		;; Running in the parent: success
		(setf (external-process-pid proc) child-pid)
		(add-external-process proc)
		(signal-semaphore (external-process-signal proc))
                (monitor-external-process proc)))))
   (external-process-args proc)))

		
(defun run-program (program args &key
			    (wait t) pty
			    input if-input-does-not-exist
			    output (if-output-exists :error)
			    (error :output) (if-error-exists :error)
			    status-hook)
  "Invoke an external program as an OS subprocess of lisp."
  (declare (ignore pty))
  (unless (every #'(lambda (a) (typep a 'simple-string)) args)
    (error "Program args must all be simple strings : ~s" args))
  (push (native-translated-namestring program) args)
  (let* ((token (list 0))
	 (in-fd nil)
	 (in-stream nil)
	 (out-fd nil)
	 (out-stream nil)
	 (error-fd nil)
	 (error-stream nil)
	 (close-in-parent nil)
	 (close-on-error nil)
	 (proc
          (make-external-process
           :pid nil
           :args args
           :%status :running
           :input nil
           :output nil
           :error nil
           :token token
           :status-hook status-hook)))
    (unwind-protect
	 (progn
	   (multiple-value-setq (in-fd in-stream close-in-parent close-on-error)
	     (get-descriptor-for input proc  nil nil :direction :input
				 :if-does-not-exist if-input-does-not-exist))
	   (multiple-value-setq (out-fd out-stream close-in-parent close-on-error)
	     (get-descriptor-for output proc close-in-parent close-on-error
				 :direction :output
				 :if-exists if-output-exists))
	   (multiple-value-setq (error-fd error-stream close-in-parent close-on-error)
	     (if (eq error :output)
	       (values out-fd out-stream close-in-parent close-on-error)
	       (get-descriptor-for error proc close-in-parent close-on-error
				   :direction :output
				   :if-exists if-error-exists)))
	   (setf (external-process-input proc) in-stream
                 (external-process-output proc) out-stream
                 (external-process-error proc) error-stream)
           (process-run-function
            (format nil "Monitor thread for external process ~a" args)
                    
            #'run-external-process proc in-fd out-fd error-fd)
           (wait-on-semaphore (external-process-signal proc))
           )
      (dolist (fd close-in-parent) (fd-close fd))
      (unless (external-process-pid proc)
        (dolist (fd close-on-error) (fd-close fd)))
      (when (and wait (external-process-pid proc))
        (with-interrupts-enabled
            (wait-on-semaphore (external-process-completed proc)))))
    (and (external-process-pid proc) proc)))


(defmacro wtermsig (status)
  `(ldb (byte 7 0) ,status))

(defmacro wexitstatus (status)
  `(ldb (byte 8 8) (the fixnum ,status)))

(defmacro wstopsig (status)
  `(wexitstatus ,status))

(defmacro wifexited (status)
  `(eql (wtermsig ,status) 0))

(defmacro wifstopped (status)
  `(eql #x7f (ldb (byte 7 0) (the fixnum ,status))))

(defmacro wifsignaled (status)
  (let* ((statname (gensym)))
    `(let* ((,statname ,status))
      (and (not (wifstopped ,statname)) (not (wifexited ,statname))))))


(defun check-pid (pid &optional (flags (logior  #$WNOHANG #$WUNTRACED)))
  (declare (fixnum pid))
  (rlet ((status :signed))
    (let* ((retval (#_waitpid pid status flags)))
      (declare (fixnum retval))
      (if (= retval pid)
	(pref status :signed)
	(zerop retval)))))





(defun external-process-wait (proc &optional check-stopped)
  (process-wait "external-process-wait"
		#'(lambda ()
		    (case (external-process-%status proc)
		      (:running)
		      (:stopped
		       (when check-stopped
			 t))
		      (t
		       (when (zerop (car (external-process-token proc)))
			 t))))))

(defun external-process-status (proc)
  "Return information about whether an OS subprocess is running; or, if
not, why not; and what its result code was if it completed."
  (require-type proc 'external-process)
  (values (external-process-%status proc)
	  (external-process-%exit-code proc)))

(defun external-process-input-stream (proc)
  "Return the lisp stream which is used to write input to a given OS
subprocess, if it has one."
  (require-type proc 'external-process)
  (external-process-input proc))

(defun external-process-output-stream (proc)
  "Return the lisp stream which is used to read output from a given OS
subprocess, if there is one."
  (require-type proc 'external-process)
  (external-process-output proc))

(defun external-process-error-stream (proc)
  "Return the stream which is used to read error output from a given OS
subprocess, if it has one."
  (require-type proc 'external-process)
  (external-process-error proc))

(defun external-process-id (proc)
  "Return the process id of an OS subprocess, a positive integer which
identifies it."
  (require-type proc 'external-process)
  (external-process-pid proc))
  
(defun signal-external-process (proc signal)
  "Send the specified signal to the specified external process.  (Typically,
it would only be useful to call this function if the EXTERNAL-PROCESS was
created with :WAIT NIL.) Return T if successful; signal an error otherwise."
  (require-type proc 'external-process)
  (let* ((pid (external-process-pid proc))
	 (error (syscall syscalls::kill pid signal)))
    (or (eql error 0)
	(%errno-disp error))))

;;; EOF on a TTY is transient, but I'm less sure of other cases.
(defun eof-transient-p (fd)
  (case (%unix-fd-kind fd)
    (:tty t)
    (t nil)))


(defstruct (shared-resource (:constructor make-shared-resource (name)))
  (name)
  (lock (make-lock))
  (primary-owner *current-process*)
  (primary-owner-notify (make-semaphore))
  (current-owner nil)
  (requestors (make-dll-header)))

(defstruct (shared-resource-request
	     (:constructor make-shared-resource-request (process))
	     (:include dll-node))
  process
  (signal (make-semaphore)))
	     

;; Returns NIL if already owned by calling thread, T otherwise
(defun %acquire-shared-resource (resource  &optional verbose)
  (let* ((current *current-process*))
    (with-lock-grabbed ((shared-resource-lock resource))
      (let* ((secondary (shared-resource-current-owner resource)))
	(if (or (eq current secondary)
		(and (null secondary)
		     (eq current (shared-resource-primary-owner resource))))
	  (return-from %acquire-shared-resource nil))))
    (let* ((request (make-shared-resource-request *current-process*)))
      (when verbose
	(format t "~%~%;;;~%;;; ~a requires access to ~a~%;;;~%~%"
		*current-process* (shared-resource-name resource)))
      (with-lock-grabbed ((shared-resource-lock resource))
	(append-dll-node request (shared-resource-requestors resource)))
      (wait-on-semaphore (shared-resource-request-signal request))
      (assert (eq current (shared-resource-current-owner resource)))
      (when verbose
	(format t "~%~%;;;~%;;; ~a is now owned by ~a~%;;;~%~%"
		(shared-resource-name resource) current))
      t)))

;;; If we're the primary owner and there is no secondary owner, do nothing.
;;; If we're the secondary owner, cease being the secondary owner.
(defun %release-shared-resource (r)
  (let* ((not-any-owner ()))
    (with-lock-grabbed ((shared-resource-lock r))
      (let* ((current *current-process*)
	     (primary (shared-resource-primary-owner r))
	     (secondary (shared-resource-current-owner r)))
	(unless (setq not-any-owner
		      (not (or (eq current secondary)
                               (and (null secondary)
                                    (eq current primary)))))
	  (when (eq current secondary)
	    (setf (shared-resource-current-owner r) nil)
	    (signal-semaphore (shared-resource-primary-owner-notify r))))))
    (when not-any-owner
      (signal-program-error "Process ~a does not own ~a" *current-process*
			    (shared-resource-name r)))))

;;; The current thread should be the primary owner; there should be
;;; no secondary owner.  Wakeup the specified (or first) requesting
;;; process, then block on our semaphore 
(defun %yield-shared-resource (r &optional to)
  (let* ((request nil))
    (with-lock-grabbed ((shared-resource-lock r))
      (let* ((current *current-process*)
	     (primary (shared-resource-primary-owner r)))
	(when (and (eq current primary)
		   (null (shared-resource-current-owner r)))
	  (setq request
		(let* ((header (shared-resource-requestors r)))
		  (if to 
		    (do-dll-nodes (node header)
		      (when (eq to (shared-resource-request-process node))
			(return node)))
		    (let* ((first (dll-header-first header)))
		      (unless (eq first header)
			first)))))
	  (when request
	    (remove-dll-node request)
            (setf (shared-resource-current-owner r)
                  (shared-resource-request-process request))
	    (signal-semaphore (shared-resource-request-signal request))))))
    (when request
      (wait-on-semaphore (shared-resource-primary-owner-notify r))
      (format t "~%;;;~%;;;control of ~a restored to ~a~%;;;~&"
	      (shared-resource-name r)
	      *current-process*))))


      

(defun %shared-resource-requestor-p (r proc)
  (with-lock-grabbed ((shared-resource-lock r))
    (do-dll-nodes (node (shared-resource-requestors r))
      (when (eq proc (shared-resource-request-process node))
	(return t)))))

(defparameter *resident-editor-hook* nil
  "If non-NIL, should be a function that takes an optional argument
   (like ED) and invokes a \"resident\" editor.")

(defun ed (&optional arg)
  (if *resident-editor-hook*
    (funcall *resident-editor-hook* arg)
    (error "This implementation doesn't provide a resident editor.")))

(defun running-under-emacs-p ()
  (not (null (getenv "EMACS"))))

(defloadvar *cpu-count* nil)

(defun cpu-count ()
  (or *cpu-count*
      (setq *cpu-count*
            #+darwin-target
            (rlet ((info :host_basic_info)
                   (count :mach_msg_type_number_t #$HOST_BASIC_INFO_COUNT))
              (if (eql #$KERN_SUCCESS (#_host_info (#_mach_host_self)
                                                   #$HOST_BASIC_INFO
                                                   info
                                                   count))
                (pref info :host_basic_info.max_cpus)
                1))
            #+linux-target
            (or
             (let* ((n (#_sysconf #$_SC_NPROCESSORS_ONLN)))
               (declare (fixnum n))
               (if (> n 0) n))
             (ignore-errors
               (with-open-file (p "/proc/cpuinfo")
                 (let* ((ncpu 0)
                        (match "processor")
                        (matchlen (length match)))
                   (do* ((line (read-line p nil nil) (read-line p nil nil)))
                        ((null line) ncpu)
                     (let* ((line-length (length line)))
                       (when (and
                              (> line-length matchlen)
                              (string= match line
                                       :end2 matchlen)
                              (whitespacep (schar line matchlen)))
                         (incf ncpu)))))))
             1)
            #+freebsd-target
            (rlet ((ret :uint))
              (%stack-block ((mib (* (record-length :uint) 2)))
              (setf (paref mib (:array :uint) 0)
                    #$CTL_HW
                    (paref mib (:array :uint) 1)
                    #$HW_NCPU)
              (rlet ((oldsize :uint (record-length :uint)))
                (if (eql 0 (#_sysctl mib 2 ret oldsize (%null-ptr) 0))
                  (pref ret :uint)
                  1))))
            )))

(def-load-pointers spin-count ()
  (if (eql 1 (cpu-count))
    (%defglobal '*spin-lock-tries* 1)
    (%defglobal '*spin-lock-tries* 1024)))

(defun yield ()
  (#_sched_yield))

(defloadvar *host-page-size* (#_getpagesize))

;;(assert (= (logcount *host-page-size*) 1))

(defun map-file-to-ivector (pathname element-type)
  (let* ((upgraded-type (upgraded-array-element-type element-type))
         (upgraded-ctype (specifier-type upgraded-type)))
    (unless (and (typep upgraded-ctype 'numeric-ctype)
                 (eq 'integer (numeric-ctype-class upgraded-ctype)))
      (error "Invalid element-type: ~s" element-type))
    (let* ((bits-per-element (integer-length (- (numeric-ctype-high upgraded-ctype)
                                                (numeric-ctype-low upgraded-ctype))))
           (fd (fd-open (native-translated-namestring pathname) #$O_RDONLY)))
      (if (< fd 0)
        (signal-file-error fd pathname)
        (let* ((len (fd-size fd)))
          (if (< len 0)
            (signal-file-error fd pathname)
            (let* ((nbytes (+ *host-page-size*
                              (logandc2 (+ len
                                           (1- *host-page-size*))
                                        (1- *host-page-size*))))

                   (ndata-elements
                    (ash len
                         (ecase bits-per-element
                           (1 3)
                           (8 0)
                           (16 -1)
                           (32 -2)
                           (64 -3))))
                   (nalignment-elements
                    (ash target::nbits-in-word
                         (ecase bits-per-element
                           (1 0)
                           (8 -3)
                           (16 -4)
                           (32 -5)
                           (64 -6)))))
              (if (>= (+ ndata-elements nalignment-elements)
                      array-total-size-limit)
                (progn
                  (fd-close fd)
                  (error "Can't make a vector with ~s elements in this implementation." (+ ndata-elements nalignment-elements)))
                (let* ((addr (#_mmap +null-ptr+
                                     nbytes
                                     #$PROT_NONE
                                     (logior #$MAP_ANON #$MAP_PRIVATE)
                                     -1
                                     0)))              
                  (if (eql addr (%int-to-ptr (1- (ash 1 target::nbits-in-word)))) ; #$MAP_FAILED
                    (let* ((errno (%get-errno)))
                      (fd-close fd)
                      (error "Can't map ~d bytes: ~a" nbytes (%strerror errno)))
              ;;; Remap the first page so that we can put a vector header
              ;;; there; use the first word on the first page to remember
              ;;; the file descriptor.
                    (progn
                      (#_mmap addr
                              *host-page-size*
                              (logior #$PROT_READ #$PROT_WRITE)
                              (logior #$MAP_ANON #$MAP_PRIVATE #$MAP_FIXED)
                              -1
                              0)
                      (setf (pref addr :int) fd)
                      (let* ((header-addr (%inc-ptr addr (- *host-page-size*
                                                            (* 2 target::node-size)))))
                        (setf (pref header-addr :unsigned-long)
                              (logior (element-type-subtype upgraded-type)
                                      (ash (+ ndata-elements nalignment-elements) target::num-subtag-bits)))
                        (when (> len 0)
                          (let* ((target-addr (%inc-ptr header-addr (* 2 target::node-size))))
                            (unless (eql target-addr
                                         (#_mmap target-addr
                                                 len
                                                 #$PROT_READ
                                                 (logior #$MAP_PRIVATE #$MAP_FIXED)
                                                 fd
                                                 0))
                              (let* ((errno (%get-errno)))
                                (fd-close fd)
                                (#_munmap addr nbytes)
                                (error "Mapping failed: ~a" (%strerror errno))))))
                        (with-macptrs ((v (%inc-ptr header-addr target::fulltag-misc)))
                          (let* ((vector (rlet ((p :address v)) (%get-object p 0))))
                            ;; Tell some parts of OpenMCL - notably the
                            ;; printer - that this thing off in foreign
                            ;; memory is a real lisp object and not
                            ;; "bogus".
                            (with-lock-grabbed (*heap-ivector-lock*)
                              (push vector *heap-ivectors*))
                            (make-array ndata-elements
                                        :element-type upgraded-type
                                        :displaced-to vector
                                        :adjustable t
                                        :displaced-index-offset nalignment-elements)))))))))))))))

(defun map-file-to-octet-vector (pathname)
  (map-file-to-ivector pathname '(unsigned-byte 8)))

(defun mapped-vector-data-address-and-size (displaced-vector)
  (let* ((v (array-displacement displaced-vector))
         (element-type (array-element-type displaced-vector)))
    (if (or (eq v displaced-vector)
            (not (with-lock-grabbed (*heap-ivector-lock*)
                   (member v *heap-ivectors*))))
      (error "~s doesn't seem to have been allocated via ~s and not yet unmapped" displaced-vector 'map-file-to-ivector))
    (let* ((pv (rlet ((x :address)) (%set-object x 0 v) (pref x :address)))
           (ctype (specifier-type element-type))
           (arch (backend-target-arch *target-backend*)))
      (values (%inc-ptr pv (- (* 2 target::node-size) target::fulltag-misc))
              (- (funcall (arch::target-array-data-size-function arch)
                          (ctype-subtype ctype)
                          (length v))
                 target::node-size)))))

  
;;; Argument should be something returned by MAP-FILE-TO-IVECTOR;
;;; this should be called at most once for any such object.
(defun unmap-ivector (displaced-vector)
  (multiple-value-bind (data-address size-in-octets)
      (mapped-vector-data-address-and-size displaced-vector)
  (let* ((v (array-displacement displaced-vector))
         (base-address (%inc-ptr data-address (- *host-page-size*)))
         (fd (pref base-address :int)))
      (let* ((element-type (array-element-type displaced-vector)))
        (adjust-array displaced-vector 0
                      :element-type element-type
                      :displaced-to (make-array 0 :element-type element-type)
                      :displaced-index-offset 0))
      (with-lock-grabbed (*heap-ivector-lock*)
        (setq *heap-ivectors* (delete v *heap-ivectors*)))
      (#_munmap base-address (+ size-in-octets *host-page-size*))      
      (fd-close fd)
      t)))

(defun unmap-octet-vector (v)
  (unmap-ivector v))

(defun lock-mapped-vector (v)
  (multiple-value-bind (address nbytes)
      (mapped-vector-data-address-and-size v)
    (eql 0 (#_mlock address nbytes))))

(defun unlock-mapped-vector (v)
  (multiple-value-bind (address nbytes)
      (mapped-vector-data-address-and-size v)
    (eql 0 (#_munlock address nbytes))))

(defun bitmap-for-mapped-range (address nbytes)
  (let* ((npages (ceiling nbytes *host-page-size*)))
    (%stack-block ((vec npages))
      (when (eql 0 (#_mincore address nbytes vec))
        (let* ((bits (make-array npages :element-type 'bit)))
          (dotimes (i npages bits)
            (setf (sbit bits i)
                  (logand 1 (%get-unsigned-byte vec i)))))))))

(defun percentage-of-resident-pages (address nbytes)
  (let* ((npages (ceiling nbytes *host-page-size*)))
    (%stack-block ((vec npages))
      (when (eql 0 (#_mincore address nbytes vec))
        (let* ((nresident 0))
          (dotimes (i npages (* 100.0 (/ nresident npages)))
            (when (logbitp 0 (%get-unsigned-byte vec i))
              (incf nresident))))))))

(defun mapped-vector-resident-pages (v)
  (multiple-value-bind (address nbytes)
      (mapped-vector-data-address-and-size v)
    (bitmap-for-mapped-range address nbytes)))

(defun mapped-vector-resident-pages-percentage (v)
  (multiple-value-bind (address nbytes)
      (mapped-vector-data-address-and-size v)
    (percentage-of-resident-pages address nbytes)))
  
