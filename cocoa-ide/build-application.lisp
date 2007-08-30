;;;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp; Base: 10; Package: cl-user -*-
;;;; ***********************************************************************
;;;; FILE IDENTIFICATION
;;;;
;;;; Name:          build-application.lisp
;;;; Version:       0.9
;;;; Project:       Cocoa application builder
;;;; Purpose:       the in-process application builder
;;;;
;;;; ***********************************************************************

(require "builder-utilities")

(in-package :ccl)

;;; about copying nibfiles

;;; when building an app bundle, we copy nibfiles from the development
;;; environment appplication bundle into the newly-created application
;;; bundle. If user-supplied nibfiles are given the same names as
;;; nibfiles from the development environment, we signal an error and
;;; refuse to copy the user nibfiles. This treatment ensures that users
;;; will not accidentally clobber dev-environment nibfiles, but also
;;; means that they must give unique names to their own nibs in order
;;; to use them with their saved applications.

;;; in future, we may add options to suppress the copying of
;;; dev-environment nibfiles.

(defun build-application (&key
                          (name "MyApplication")
                          (type-string "APPL")
                          (creator-string "OMCL")
                          (directory (current-directory))
                          (nibfiles nil) ; a list of user-specified nibfiles
                                         ; to be copied into the app bundle
                          (main-nib-name); the name of the nib that is to be loaded
                                         ; as the app's main. this name gets written
                                         ; into the Info.plist on the "NSMainNibFile" key
                          (application-class 'cocoa-application)
                          (toplevel-function nil)
                          (swank-loader nil)
                          (autostart-swank-on-port nil))
  ;;; if the path to swank-loader.lisp is given, then load
  ;;; swank before building the application
  (when swank-loader
    (assert (probe-file swank-loader)(swank-loader)
            "Swank loader not found at path '~A'" swank-loader)
    (load swank-loader)
    ;; when autostart-swank-on-port is also given, setup
    ;; swank to start up on launch (still don't know how
    ;; we're actually going to do this)
    (when autostart-swank-on-port
      (assert (integerp autostart-swank-on-port)(autostart-swank-on-port)
              "The port for :autostart-swank-on-port must be an integer or nil, not '~S'"
              autostart-swank-on-port)
      ;; if we get this far, setup the swank autostart
      ;; (however we're going to do that...)
      ))
  ;;; build the application
  (let* ((ide-bundle (#/mainBundle ns:ns-bundle))
         (ide-bundle-path-nsstring (#/bundlePath ide-bundle))
         (ide-bundle-path (pathname 
                           (ensure-directory-pathname 
                            (lisp-string-from-nsstring ide-bundle-path-nsstring))))
         (app-bundle (make-application-bundle name type-string creator-string directory
                                              :main-nib-name main-nib-name))
         (image-path (namestring (path app-bundle "Contents" "MacOS" name))))
    ;; copy IDE resources into the application bundle
    (recursive-copy-directory (path ide-bundle-path "Contents" "Resources/")
                              (path app-bundle  "Contents" "Resources/"))
    ;; copy user-supplied nibfiles into the bundle
    (when nibfiles
      (let ((nib-paths (mapcar #'pathname nibfiles)))
        (assert (and (every #'probe-file nib-paths)
                     (every #'directoryp nib-paths))
                (nibfiles)
                "The nibfiles parameter must be a list of valid pathnames to existing directories")
        ;; for each input nibfile, construct the destination path and copy it to that path
        ;; checking first whether doing so would clobber an existing nib. if it would,
        ;; signal an error
        (dolist (n nib-paths)
          ;; TODO: handle cases where there are nibs for languages other than English
          (let ((dest (path app-bundle  "Contents" "Resources" "English.lproj/" (namestring (basename n)))))
            (if (probe-file dest)
                (error "The destination nibfile '~A' already exists" dest)
                (recursive-copy-directory n dest))))))
    ;; save the application image
    (save-application image-path
                      :application-class application-class
                      :toplevel-function toplevel-function
                      :prepend-kernel t)))



