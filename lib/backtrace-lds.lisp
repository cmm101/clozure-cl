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



; backtrace-lds.lisp
; low-level support for stack-backtrace dialog (Lisp Development System)

(in-package :ccl)

(eval-when (eval compile #-bccl load)
  (require 'streams))

(eval-when (eval compile)
  (require 'lispequ)
  (require 'backquote)
)


; Act as if VSTACK-INDEX points somewhere where DATA could go & put it there.
(defun set-lisp-data (vstack-index data)
  (let* ((old (%access-lisp-data vstack-index)))
    (if (closed-over-value-p old)
      (set-closed-over-value old data)
      (%store-lisp-data vstack-index data))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;extensions to let user access and modify values



; Returns five values: (ARGS TYPES NAMES COUNT NCLOSED)
; ARGS is a list of the args supplied to the function
; TYPES is a list of the types of the args.
; NAMES is a list of the names of the args.
;       TYPES & NAMES will hae entries only for closed-over, required, & optional args.
; COUNT is the number of known-correct elements of ARGS, or T if they're all correct.
;       ARGS will be filled with NIL up to the number of required args to lfun
; NCLOSED is the number of closed-over values that are in the prefix of ARGS
;       If COUNT < NCLOSED, it is not safe to restart the function.
(defun frame-supplied-args (frame lfun pc child tcr)
  (declare (ignore child))
  (multiple-value-bind (req opt restp keys allow-other-keys optinit lexprp ncells nclosed)
                       (function-args lfun)
    (declare (ignore allow-other-keys lexprp ncells))
    (let* ((vsp (1- (frame-vsp (parent-frame frame tcr))))
           (child-vsp (1- (frame-vsp frame)))
           (frame-size (- vsp child-vsp))
           (res nil)
           (types nil)
           (names nil))
      (flet ((push-type&name (cellno)
               (multiple-value-bind (type name) (find-local-name cellno lfun pc)
                 (push type types)
                 (push name names))))
        (declare (dynamic-extent #'push-type&name))
        (if (or
                (<= frame-size 0))
          ; Can't parse the frame, but all but the last 3 args are on the stack
          (let* ((nargs (+ nclosed req))
                 (vstack-args (max 0 (min frame-size (- nargs 3)))))
            (dotimes (i vstack-args)
              (declare (fixnum i))
              (push (access-lisp-data vsp) res)
              (push-type&name i)
              (decf vsp))
            (values (nreconc res (make-list (- nargs vstack-args)))
                    (nreverse types)
                    (nreverse names)
                    vstack-args
                    nclosed))
          ; All args were vpushed.
          (let* ((might-be-rest (> frame-size (+ req opt)))
                 (rest (and restp might-be-rest (access-lisp-data (- vsp req opt))))
                 (cellno -1))
            (declare (fixnum cellno))
            (when (and keys might-be-rest (null rest))
              (let ((vsp (- vsp req opt))
                    (keyvect (lfun-keyvect lfun))
                    (res nil))
                (dotimes (i keys)
                  (declare (fixnum i))
                  (when (access-lisp-data (1- vsp))   ; key-supplied-p
                    (push (aref keyvect i) res)
                    (push (access-lisp-data vsp) res))
                  (decf vsp 2))
                (setq rest (nreverse res))))
            (dotimes (i nclosed)
              (declare (fixnum i))
              (when (<= vsp child-vsp) (return))
              (push (access-lisp-data vsp) res)
              (push-type&name (incf cellno))
              (decf vsp))
            (dotimes (i req)
              (declare (fixnum i))
              (when (<= vsp child-vsp) (return))
              (push (access-lisp-data vsp) res)
              (push-type&name (incf cellno))
              (decf vsp))
            (if rest
              (dotimes (i opt)              ; all optionals were specified
                (declare (fixnum i))
                (when (<= vsp child-vsp) (return))
                (push (access-lisp-data vsp) res)
                (push-type&name (incf cellno))
                (decf vsp))
              (let ((offset (+ opt (if restp 1 0) (if keys (+ keys keys) 0)))
                    (optionals nil))
                (dotimes (i opt)            ; some optionals may have been omitted
                  (declare (fixnum i))
                  (when (<= vsp child-vsp) (return))
                  (let ((value (access-lisp-data vsp)))
                    (if optinit
                      (if (access-lisp-data (- vsp offset))
                        (progn
                          (push value optionals)
                          (push-type&name (incf cellno))
                          (return)))
                      (progn (push value optionals)
                             (push-type&name (incf cellno))))
                    (decf vsp)))
                (unless optinit
                  ; assume that null optionals were not passed.
                  (while (and optionals (null (car optionals)))
                    (pop optionals)
                    (pop types)
                    (pop names)))
                (setq rest (nreconc optionals rest))))
            (values (nreconc res rest) (nreverse types) (nreverse names)
                    t nclosed)))))))

; nth-frame-info, set-nth-frame-info, & frame-lfun are in "inspector;new-backtrace"


(defun last-catch-since (sp tcr)
  (let ((catch (%catch-top tcr))
        (last-catch nil))
    (loop
      (unless catch (return last-catch))
      (let ((csp (uvref catch arch::catch-frame.csp-cell)))
        (when (%stack< sp csp tcr) (return last-catch))
        (setq last-catch catch
              catch (next-catch catch))))))

(defparameter *saved-register-count*
  #+sparc-target 6
  #+ppc-target 8)

(defparameter *saved-register-count+1*
  (1+ *saved-register-count*))

(defparameter *saved-register-names*
  #+sparc-target #(save5 save4 save3 save2 save1 save0)
  #+ppc-target #(save7 save6 save5 save4 save3 save2 save1 save0))

(defparameter *saved-register-numbers*
  #+sparc-target #(wrong)
  #+ppc-target #(31 30 29 28 27 26 25 24))

; Don't do unbound checks in compiled code
(declaim (type t *saved-register-count* *saved-register-count+1*
               *saved-register-names* *saved-register-numbers*))

(defmacro %cons-saved-register-vector ()
  `(make-array (the fixnum *saved-register-count+1*) :initial-element nil))

(defun copy-srv (from-srv &optional to-srv)
  (if to-srv
    (if (eq from-srv to-srv)
      to-srv
      (dotimes (i (uvsize from-srv) to-srv)
        (setf (uvref to-srv i) (uvref from-srv i))))
    (copy-uvector from-srv)))

(defmacro srv.unresolved (saved-register-vector)
  `(svref ,saved-register-vector 0))

(defmacro srv.register-n (saved-register-vector n)
  `(svref ,saved-register-vector (1+ ,n)))

; This isn't quite right - has to look at all functions on stack, not just those that saved VSPs.


(defun frame-restartable-p (target &optional (tcr (%current-tcr)))
  (multiple-value-bind (frame last-catch srv) (last-catch-since-saved-vars target tcr)
    (when frame
      (loop
        (when (null frame)
          (return-from frame-restartable-p nil))
        (when (eq frame target) (return))
        (multiple-value-setq (frame last-catch srv)
          (ccl::parent-frame-saved-vars tcr frame last-catch srv srv)))
      (when (and srv (eql 0 (srv.unresolved srv)))
        (setf (srv.unresolved srv) last-catch)
        srv))))


; get the saved register addresses for this frame
; still need to worry about this unresolved business
; could share some code with parent-frame-saved-vars
(defun my-saved-vars (frame &optional (srv-out (%cons-saved-register-vector)))
  (let ((unresolved 0))
    (multiple-value-bind (lfun pc) (cfp-lfun frame)
        (if lfun
          (multiple-value-bind (mask where) (registers-used-by lfun pc)
            (when mask
              (if (not where) 
                (setq unresolved (%ilogior unresolved mask))
                (let ((vsp (- (frame-vsp frame) where (1- (logcount mask))))
                      (j *saved-register-count*))
                  (declare (fixnum j))
                  (dotimes (i j)
                    (declare (fixnum i))
                    (when (%ilogbitp (decf j) mask)
                      (setf (srv.register-n srv-out i) vsp
                            vsp (1+ vsp)
                            unresolved (%ilogand unresolved (%ilognot (%ilsl j 1))))))))))
          (setq unresolved (1- (ash 1 *saved-register-count*)))))
    (setf (srv.unresolved srv-out) unresolved)
    srv-out))

(defun parent-frame-saved-vars 
       (tcr frame last-catch srv &optional (srv-out (%cons-saved-register-vector)))
  (copy-srv srv srv-out)
  (let* ((parent (and frame (parent-frame frame tcr)))
         (grand-parent (and parent (parent-frame parent tcr))))
    (when grand-parent
      (loop (let ((next-catch (and last-catch (next-catch last-catch))))
              ;(declare (ignore next-catch))
              (if (and next-catch (%stack< (catch-frame-sp next-catch) grand-parent tcr))
                (progn
                  (setf last-catch next-catch
                        (srv.unresolved srv-out) 0)
                  (dotimes (i *saved-register-count*)
                    (setf (srv.register-n srv i) nil)))
                (return))))
      (lookup-registers parent tcr grand-parent srv-out)
      (values parent last-catch srv-out))))

(defun lookup-registers (parent tcr grand-parent srv-out)
  (unless (or (eql (frame-vsp grand-parent) 0)
              (let ((gg-parent (parent-frame grand-parent tcr)))
                (eql (frame-vsp gg-parent) 0)))
    (multiple-value-bind (lfun pc) (cfp-lfun parent)
      (when lfun
        (multiple-value-bind (mask where) (registers-used-by lfun pc)
          (when mask
            (locally (declare (fixnum mask))
              (if (not where) 
                (setf (srv.unresolved srv-out) (%ilogior (srv.unresolved srv-out) mask))
                (let* ((parent-vsp (frame-vsp parent))
                       (grand-parent-vsp (frame-vsp grand-parent))
                       (parent-area (%active-area (%fixnum-ref tcr arch::tcr.vs-area)  parent-vsp)))
                  (unless (%ptr-in-area-p  grand-parent-vsp parent-area)
                    (setq grand-parent-vsp (%fixnum-ref parent-area arch::area.high)))
                  (let ((vsp (- grand-parent-vsp where 1))
                        (j *saved-register-count*))
                    (declare (fixnum j))
                    (dotimes (i j)
                      (declare (fixnum i))
                      (when (%ilogbitp (decf j) mask)
                        (setf (srv.register-n srv-out i) vsp
                              vsp (1- vsp)
                              (srv.unresolved srv-out)
                              (%ilogand (srv.unresolved srv-out) (%ilognot (%ilsl j 1))))))))))))))))

; initialization for looping on parent-frame-saved-vars
(defun last-catch-since-saved-vars (frame tcr)
  (let* ((parent (parent-frame frame tcr))
         (last-catch (and parent (last-catch-since parent tcr))))
    (when last-catch
      (let ((frame (catch-frame-sp last-catch))
            (srv (%cons-saved-register-vector)))
        (setf (srv.unresolved srv) 0)
        (let* ((parent (parent-frame frame tcr))
               (child (and parent (child-frame parent tcr))))
          (when child
            (lookup-registers child tcr parent srv))
          (values child last-catch srv))))))

; Returns 2 values:
; mask srv
; The mask says which registers are used at PC in LFUN.
; srv is a saved-register-vector whose register contents are the register values
; registers whose bits are not set in MASK or set in UNRESOLVED will
; be returned as NIL.

(defun saved-register-values 
       (lfun pc child last-catch srv &optional (srv-out (%cons-saved-register-vector)))
  (declare (ignore child))
  (cond ((null srv-out) (setq srv-out (copy-uvector srv)))
        ((eq srv-out srv))
        (t (dotimes (i (the fixnum (uvsize srv)))
             (setf (uvref srv-out i) (uvref srv i)))))
  (let ((mask (or (registers-used-by lfun pc) 0))
        (unresolved (srv.unresolved srv))
        (j *saved-register-count*))
    (declare (fixnum j))
    (dotimes (i j)
      (declare (fixnum i))
      (setf (srv.register-n srv-out i)
            (and (%ilogbitp (setq j (%i- j 1)) mask)
                 (not (%ilogbitp j unresolved))
                 (safe-cell-value (get-register-value (srv.register-n srv i) last-catch j)))))
    (setf (srv.unresolved srv-out) mask)
    (values mask srv-out)))

; Set the nth saved register to value.
(defun set-saved-register (value n lfun pc child last-catch srv)
  (declare (ignore lfun pc child) (dynamic-extent saved-register-values))
  (let ((j (- 4 n))
        (unresolved (srv.unresolved srv))
        (addr (srv.register-n srv n)))
    (when (logbitp j unresolved)
      (error "Can't set register ~S to ~S" n value))
    (set-register-value value addr last-catch j))
  value)



(defun get-register-value (address last-catch index)
  (if address
    (%fixnum-ref address)
    (uvref last-catch (+ index arch::catch-frame.save-save7-cell))))

; Inverse of get-register-value

(defun set-register-value (value address last-catch index)
  (if address
    (%fixnum-set address value)
    (setf (uvref last-catch (+ index arch::catch-frame.save-save7-cell)) value)))

(defun return-from-nth-frame (n &rest values)
  (apply-in-nth-frame n #'values values))

(defun apply-in-nth-frame (n fn arglist)
  (let* ((bt-info (car *backtrace-dialogs*)))
    (and bt-info
         (let* ((frame (nth-frame nil (bt.youngest bt-info) n)))
           (and frame (apply-in-frame frame fn arglist)))))
  (format t "Can't return to frame ~d ." n))

; This method is shadowed by one for the backtrace window.
(defmethod nth-frame (w target n &aux (tcr (%current-tcr)))
  (declare (ignore w))
  (and target (dotimes (i n target)
                (declare (fixnum i))
                (unless (setq target (parent-frame target tcr)) (return nil)))))

; If this returns at all, it's because the frame wasn't restartable.
(defun apply-in-frame (frame fn arglist &optional (tcr (%current-tcr)))
  (let* ((srv (frame-restartable-p frame tcr))
         (target-sp (and srv (srv.unresolved srv))))
    (if target-sp
      (apply-in-frame-internal tcr frame fn arglist srv))))

(defun apply-in-frame-internal (tcr frame fn arglist srv)
  (if (eq tcr (%current-tcr))
    (%apply-in-frame frame fn arglist srv)
    (let ((process (tcr->process tcr)))
      (if process
        (process-interrupt
         process
         #'%apply-in-frame
         frame fn arglist srv)
        (error "Can't find active process for ~s" tcr)))))




; (srv.unresolved srv) is the last catch frame, left there by frame-restartable-p
; The registers in srv are locations of variables saved between frame and that catch frame.
(defun %apply-in-frame (frame fn arglist srv)
  (declare (fixnum frame))
  (let* ((catch (srv.unresolved srv))
         (tsp-count 0)
         (tcr (%current-tcr))
         (parent (parent-frame frame tcr))
         (vsp (frame-vsp parent))
         (catch-top (%catch-top tcr))
         (db-link (%svref catch arch::catch-frame.db-link-cell))
         (catch-count 0))
    (declare (fixnum parent vsp db-link catch-count))
    ; Figure out how many catch frames to throw through
    (loop
      (unless catch-top
        (error "Didn't find catch frame"))
      (incf catch-count)
      (when (eq catch-top catch)
        (return))
      (setq catch-top (next-catch catch-top)))
    ; Figure out where the db-link should be
    (loop
      (when (or (eql db-link 0) (>= db-link vsp))
        (return))
      (setq db-link (%fixnum-ref db-link)))
    ; Figure out how many TSP frames to pop after throwing.
    (let ((sp (catch-frame-sp catch)))
      (loop
        (multiple-value-bind (f pc) (cfp-lfun sp)
          (when f (incf tsp-count (active-tsp-count f pc))))
        (setq sp (parent-frame sp tcr))
        (when (eql sp parent) (return))
        (unless sp (error "Didn't find frame: ~s" frame))))
    #+debug
    (cerror "Continue" "(apply-in-frame ~s ~s ~s ~s ~s ~s ~s)"
            catch-count srv tsp-count db-link parent fn arglist)
    (%%apply-in-frame catch-count srv tsp-count db-link parent fn arglist)))

#+ppc-target
(defppclapfunction %%apply-in-frame ((catch-count imm0) (srv temp0) (tsp-count imm0) (db-link imm0)
                                     (parent arg_x) (function arg_y) (arglist arg_z))
  (check-nargs 7)

  ; Throw through catch-count catch frames
  (lwz imm0 12 vsp)                      ; catch-count
  (vpush parent)
  (vpush function)
  (vpush arglist)
  (bla .SPnthrowvalues)

  ; Pop tsp-count TSP frames
  (lwz tsp-count 16 vsp)
  (cmpi cr0 tsp-count 0)
  (b @test)
@loop
  (subi tsp-count tsp-count '1)
  (cmpi cr0 tsp-count 0)
  (lwz tsp 0 tsp)
@test
  (bne cr0 @loop)

  ; Pop dynamic bindings until we get to db-link
  (lwz imm0 12 vsp)                     ; db-link
  (lwz imm1 arch::tcr.db-link rcontext)
  (cmp cr0 imm0 imm1)
  (beq cr0 @restore-regs)               ; .SPsvar-unbind-to expects there to be something to do
  (bla .SPsvar-unbind-to)

@restore-regs
  ; restore the saved registers from srv
  (lwz srv 20 vsp)
@get0
  (svref imm0 1 srv)
  (cmpwi cr0 imm0 ppc::nil-value)
  (beq @get1)
  (lwz save0 0 imm0)
@get1
  (svref imm0 2 srv)
  (cmpwi cr0 imm0 ppc::nil-value)
  (beq @get2)
  (lwz save1 0 imm0)
@get2
  (svref imm0 3 srv)
  (cmpwi cr0 imm0 ppc::nil-value)
  (beq @get3)
  (lwz save2 0 imm0)
@get3
  (svref imm0 4 srv)
  (cmpwi cr0 imm0 ppc::nil-value)
  (beq @get4)
  (lwz save3 0 imm0)
@get4
  (svref imm0 5 srv)
  (cmpwi cr0 imm0 ppc::nil-value)
  (beq @get5)
  (lwz save4 0 imm0)
@get5
  (svref imm0 6 srv)
  (cmpwi cr0 imm0 ppc::nil-value)
  (beq @get6)
  (lwz save5 0 imm0)
@get6
  (svref imm0 7 srv)
  (cmpwi cr0 imm0 ppc::nil-value)
  (beq @get7)
  (lwz save6 0 imm0)
@get7
  (svref imm0 8 srv)
  (cmpwi cr0 imm0 ppc::nil-value)
  (beq @got)
  (lwz save7 0 imm0)
@got

  (vpop arg_z)                          ; arglist
  (vpop temp0)                          ; function
  (vpop parent)                         ; parent
  (extract-lisptag imm0 parent)
  (cmpi cr0 imm0 arch::tag-fixnum)
  (if (:cr0 :ne)
    ; Parent is a fake-stack-frame. Make it real
    (progn
      (svref sp %fake-stack-frame.sp parent)
      (stwu sp (- ppc::lisp-frame.size) sp)
      (svref fn %fake-stack-frame.fn parent)
      (stw fn ppc::lisp-frame.savefn sp)
      (svref temp1 %fake-stack-frame.vsp parent)
      (stw temp1 ppc::lisp-frame.savevsp sp)
      (svref temp1 %fake-stack-frame.lr parent)
      (extract-lisptag imm0 temp1)
      (cmpi cr0 imm0 arch::tag-fixnum)
      (if (:cr0 :ne)
        ; must be a macptr encoding the actual link register
        (macptr-ptr loc-pc temp1)
        ; Fixnum is offset from start of function vector
        (progn
          (svref temp2 0 fn)        ; function vector
          (unbox-fixnum temp1 temp1)
          (add loc-pc temp2 temp1)))
      (stw loc-pc ppc::lisp-frame.savelr sp))
    ; Parent is a real stack frame
    (mr sp parent))
  (set-nargs 0)
  (bla .SPspreadargz)
  (ba .SPtfuncallgen))

;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Code to determine how many tsp frames to pop.
;;; This is done by parsing the code.
;;; active-tsp-count is the entry point below.
;;;

#+ppc-target
(progn

(defstruct (branch-tree (:print-function print-branch-tree))
  first-instruction
  last-instruction
  branch-target     ; a branch-tree or nil
  fall-through)     ; a branch-tree or nil

(defun print-branch-tree (tree stream print-level)
  (declare (ignore print-level))
  (print-unreadable-object (tree stream :type t :identity t)
    (format stream "~s-~s"
            (branch-tree-first-pc tree)
            (branch-tree-last-pc tree))))

(defun branch-tree-first-pc (branch-tree)
  (let ((first (branch-tree-first-instruction branch-tree)))
    (and first (instruction-element-address first))))

(defun branch-tree-last-pc (branch-tree)
  (let ((last (branch-tree-last-instruction branch-tree)))
    (if last
      (instruction-element-address last)
      (branch-tree-first-pc branch-tree))))

(defun branch-tree-contains-pc-p (branch-tree pc)
  (<= (branch-tree-first-pc branch-tree)
      pc
      (branch-tree-last-pc branch-tree)))

(defvar *branch-tree-hash*
  (make-hash-table :test 'eq :weak :value))

(defun get-branch-tree (function)
  (or (gethash function *branch-tree-hash*)
      (let* ((dll (function-to-dll-header function))
             (tree (dll-to-branch-tree dll)))
        (setf (gethash function *branch-tree-hash*) tree))))         

; Return the number of TSP frames that will be active after throwing out
; of all the active catch frames in function at pc.
; PC is a byte address, a multiple of 4.
(defun active-tsp-count (function pc)
  (setq function
        (require-type
         (if (symbolp function)
           (symbol-function function)
           function)
         'compiled-function))
  (let* ((tree (get-branch-tree function))
         (visited nil))
    (labels ((find-pc (branch path)
               (unless (memq branch visited)
                 (push branch path)
                 (if (branch-tree-contains-pc-p branch pc)
                   path
                   (let ((target (branch-tree-branch-target branch))
                         (fall-through (branch-tree-fall-through branch)))
                     (push branch visited)
                     (if fall-through
                       (or (and target (find-pc target path))
                           (find-pc fall-through path))
                       (and target (find-pc target path))))))))
      (let* ((path (nreverse (find-pc tree nil)))
             (last-tree (car (last path)))
             (catch-count 0)
             (tsp-count 0))
        (unless path
          (error "Can't find path to pc: ~s in ~s" pc function))
        (dolist (tree path)
          (let ((next (branch-tree-first-instruction tree))
                (last (branch-tree-last-instruction tree)))
            (loop
              (when (and (eq tree last-tree)
                         (eql pc (instruction-element-address next)))
                ; If the instruction before the current one is an ff-call,
                ; then callback pushed a TSP frame.
                #| ; Not any more
                (when (ff-call-instruction-p (dll-node-pred next))
                  (incf tsp-count))
                |#
                (return))
              (multiple-value-bind (type target fall-through count) (categorize-instruction next)
                (declare (ignore target fall-through))
                (case type
                  (:tsp-push
                   (when (eql catch-count 0)
                     (incf tsp-count count)))
                  (:tsp-pop
                   (when (eql catch-count 0)
                     (decf tsp-count count)))
                  ((:catch :unwind-protect)
                   (incf catch-count))
                  (:throw
                   (decf catch-count count))))
              (when (eq next last)
                (return))
              (setq next (dll-node-succ next)))))
        tsp-count))))
        

(defun dll-to-branch-tree (dll)
  (let* ((hash (make-hash-table :test 'eql))    ; start-pc -> branch-tree
         (res (collect-branch-tree (dll-header-first dll) dll hash))
         (did-something nil))
    (loop
      (setq did-something nil)
      (let ((mapper #'(lambda (key value)
                        (declare (ignore key))
                        (flet ((maybe-collect (pc)
                                 (when (integerp pc)
                                   (let ((target-tree (gethash pc hash)))
                                     (if target-tree
                                       target-tree
                                       (progn
                                         (collect-branch-tree (dll-pc->instr dll pc) dll hash)
                                         (setq did-something t)
                                         nil))))))
                          (declare (dynamic-extent #'maybe-collect))
                          (let ((target-tree (maybe-collect (branch-tree-branch-target value))))
                            (when target-tree (setf (branch-tree-branch-target value) target-tree)))
                          (let ((target-tree (maybe-collect (branch-tree-fall-through value))))
                            (when target-tree (setf (branch-tree-fall-through value) target-tree)))))))
        (declare (dynamic-extent mapper))
        (maphash mapper hash))
      (unless did-something (return)))
    ; To be totally correct, we should fix up the trees containing
    ; the BLR instruction for unwind-protect cleanups, but none
    ; of the users of this code yet care that it appears that the code
    ; stops there.
    res))

(defun collect-branch-tree (instr dll hash)
  (unless (eq instr dll)
    (let ((tree (make-branch-tree :first-instruction instr))
          (pred nil)
          (next instr))
      (setf (gethash (instruction-element-address instr) hash)
            tree)
      (loop
        (when (eq next dll)
          (setf (branch-tree-last-instruction tree) pred)
          (return))
        (multiple-value-bind (type target fall-through) (categorize-instruction next)
          (case type
            (:label
             (when pred
               (setf (branch-tree-last-instruction tree) pred
                     (branch-tree-fall-through tree) (instruction-element-address next))
               (return)))
            ((:branch :catch :unwind-protect)
             (setf (branch-tree-last-instruction tree) next
                   (branch-tree-branch-target tree) target
                   (branch-tree-fall-through tree) fall-through)
             (return))))
        (setq pred next
              next (dll-node-succ next)))
      tree)))

; Returns 4 values:
; 1) type: one of :regular, :label, :branch, :catch, :unwind-protect, :throw, :tsp-push, :tsp-pop
; 2) branch target (or catch or unwind-protect cleanup)
; 3) branch-fallthrough (or catch or unwind-protect body)
; 4) Count for throw, tsp-push, tsp-pop
#+ppc-target
(defun categorize-instruction (instr)
  (etypecase instr
    (lap-label :label)
    (lap-instruction
     (let* ((opcode (lap-instruction-opcode instr))
            (opcode-p (typep opcode 'arch::opcode))
            (name (if opcode-p (arch::opcode-name opcode) opcode))
            (pc (lap-instruction-address instr))
            (operands (lap-instruction-parsed-operands instr)))
       (cond ((equalp name "bla")
              (let ((subprim (car operands)))
                (case subprim
                  (.SPmkunwind
                   (values :unwind-protect (+ pc 4) (+ pc 8)))
                  ((.SPmkcatch1v .SPmkcatchmv)
                   (values :catch (+ pc 4) (+ pc 8)))
                  (.SPthrow
                   (values :branch nil nil))
                  ((.SPnthrowvalues .SPnthrow1value)
                   (let* ((prev-instr (require-type (lap-instruction-pred instr)
                                                    'lap-instruction))
                          (prev-name (arch::opcode-name (lap-instruction-opcode prev-instr)))
                          (prev-operands (lap-instruction-parsed-operands prev-instr)))
                     ; Maybe we should recognize the other possible outputs of ppc2-lwi, but I
                     ; can't imagine we'll ever see them
                     (unless (and (equalp prev-name "li")
                                  (equalp (car prev-operands) "imm0"))
                       (error "Can't determine throw count for ~s" instr))
                     (values :throw nil (+ pc 4) (ash (cadr prev-operands) (- arch::fixnum-shift)))))
                  ((.SPprogvsave
                    .SPstack-rest-arg .SPreq-stack-rest-arg .SPstack-cons-rest-arg
                    .SPmakestackblock .SPmakestackblock0 .SPmakestacklist .SPstkgvector
                    .SPstkconslist .SPstkconslist-star
                    .SPmkstackv .SPstack-misc-alloc .SPstack-misc-alloc-init
                    .SPstkvcell0 .SPstkvcellvsp
                    .SPsave-values)
                   (values :tsp-push nil nil 1))
                  (.SPrecover-values
                   (values :tsp-pop nil nil 1))
                  (t :regular))))
             ((or (equalp name "lwz") (equalp name "addi"))
              (if (equalp (car operands) "tsp")
                (values :tsp-pop nil nil 1)
                :regular))
             ((equalp name "stwu")
              (if (equalp (car operands) "tsp")
                (values :tsp-push nil nil 1)
                :regular))
             ((member name '("ba" "blr" "bctr") :test 'equalp)
              (values :branch nil nil))
             ; It would probably be faster to determine the branch address by adding the PC and the offset.
             ((equalp name "b")
              (values :branch (branch-label-address instr (car (last operands))) nil))
             ((and opcode-p (eql (arch::opcode-majorop opcode) 16))
              (values :branch (branch-label-address instr (car (last operands))) (+ pc 4)))
             (t :regular))))))

(defun branch-label-address (instr label-name &aux (next instr))
  (loop
    (setq next (dll-node-succ next))
    (when (eq next instr)
      (error "Couldn't find label ~s" label-name))
    (when (and (typep next 'lap-label)
               (eq (lap-label-name next) label-name))
      (return (instruction-element-address next)))))

(defun dll-pc->instr (dll pc)
  (let ((next (dll-node-succ dll)))
    (loop
      (when (eq next dll)
        (error "Couldn't find pc: ~s in ~s" pc dll))
      (when (eql (instruction-element-address next) pc)
        (return next))
      (setq next (dll-node-succ next)))))

)  ; end of #+ppc-target progn

#|
(setq *save-local-symbols* t)

(defun test (flip flop &optional bar)
  (let ((another-one t)
        (bar 'quux))
    (break)))

(test '(a b c d) #\a)

(defun closure-test (flim flam)
  (labels ((inner (x)
              (let ((ret (list x flam)))
                (break))))
    (inner flim)
    (break)))

(closure-test '(a b c) 'quux)

(defun set-test (a b)
  (break)
  (+ a b))

(set-test 1 'a)

|#


(provide 'backtrace)

; End of backtrace-lds.lisp
