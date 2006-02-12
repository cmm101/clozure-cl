;;;-*- Mode: Lisp; Package: (X8664 :use CL) -*-
;;;
;;;   Copyright (C) 2005, Clozure Associates and contributors.
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

(defpackage "X8664"
  (:use "CL")
  #+x8664-target
  (:nicknames "TARGET"))

(in-package "X8664")

(eval-when (:compile-toplevel :load-toplevel :execute)
(defparameter *x8664-symbolic-register-names*
  (make-hash-table :test #'equal)
  "For the disassembler, mostly")

;;; define integer constants which map to
;;; indices in the X86::*X8664-REGISTER-ENTRIES* array.
(ccl::defenum ()
  rax
  rcx
  rdx
  rbx
  rsp
  rbp
  rsi
  rdi
  r8
  r9
  r10
  r11
  r12
  r13
  r14
  r15
  ;; 32-bit registers
  eax
  ecx
  edx
  ebx
  esp
  ebp
  esi
  edi
  r8d
  r9d
  r10d
  r11d
  r12d
  r13d
  r14d
  r15d
  ;; 16-bit-registers
  ax
  cx
  dx
  bx
  sp
  bp
  si
  di
  r8w
  r9w
  r10w
  r11w
  r12w
  r13w
  r14w
  r15w
  ;; 8-bit registers
  al
  cl
  dl
  bl
  spl
  bpl
  sil
  dil
  r8b
  r9b
  r10b
  r11b
  r12b
  r13b
  r14b
  r15b
       ;;; xmm registers
  xmm0
  xmm1
  xmm2
  xmm3
  xmm4
  xmm5
  xmm6
  xmm7
  xmm8
  xmm9
  xmm10
  xmm11
  xmm12
  xmm13
  xmm14
  xmm15
  ;; MMX registers
  mm0
  mm1
  mm2
  mm3
  mm4
  mm5
  mm6
  mm7
  ;; x87 FP regs.  May or may not be useful.
  st[0]
  st[1]
  st[2]
  st[3]
  st[4]
  st[5]
  st[6]
  st[7]
  ;; Segment registers
  cs
  ds
  ss
  es
  fs
  gs
  )

(defmacro defx86reg (alias known)
  (let* ((known-entry (gensym)))
    `(let* ((,known-entry (gethash ,(string known) x86::*x86-registers*)))
      (unless ,known-entry
        (error "register ~a not defined" ',known))
      (setf (gethash ,(string alias) x86::*x86-registers*) ,known-entry)
      (unless (gethash ,(string-downcase (string known)) *x8664-symbolic-register-names*)
        (setf (gethash ,(string-downcase (string known)) *x8664-symbolic-register-names*)
              (string-downcase ,(string alias))))
      (defconstant ,alias ,known))))

(defx86reg imm0 rax)
(defx86reg imm0.l eax)
(defx86reg imm0.w ax)
(defx86reg imm0.b al)

(defx86reg temp0 rbx)
(defx86reg temp0.l ebx)
(defx86reg temp0.w bx)
(defx86reg temp0.b bl)

(defx86reg temp2 rcx)
(defx86reg temp2.l ecx)
(defx86reg nargs cx)
(defx86reg temp2.w cx)
(defx86reg temp2.b cl)
(defx86reg shift cl)

(defx86reg imm1 rdx)
(defx86reg imm1.l edx)
(defx86reg imm1.w dx)
(defx86reg imm1.b dl)

(defx86reg arg_z rsi)
(defx86reg arg_z.l esi)
(defx86reg arg_z.w si)
(defx86reg arg_z.b sil)

(defx86reg arg_y rdi)
(defx86reg arg_y.l edi)
(defx86reg arg_y.w di)
(defx86reg arg_y.b dil)

(defx86reg arg_x r8)
(defx86reg arg_x.l r8d)
(defx86reg arg_x.w r8w)
(defx86reg arg_x.b r8b)

(defx86reg temp1 r9)
(defx86reg temp1.l r9d)
(defx86reg temp1.w r9w)
(defx86reg temp1.b r9b)

(defx86reg ra0 r10)
(defx86reg ra0.l r10d)
(defx86reg ra0.w r10w)
(defx86reg ra0.b r10b)

(defx86reg save3 r11)
(defx86reg save3.l r11d)
(defx86reg save3.w r10w)
(defx86reg save3.b r10b)

(defx86reg save2 r12)
(defx86reg save2.l r12d)
(defx86reg save2.w r12w)
(defx86reg save2.b r12b)

(defx86reg fn r13)
(defx86reg fn.l r13d)
(defx86reg fn.w r13w)
(defx86reg fn.b r13b)

(defx86reg save1 r14)
(defx86reg save1.l r14d)
(defx86reg save1.w r14w)
(defx86reg save1.b r14b)

(defx86reg save0 r15)
(defx86reg save0.l r15d)
(defx86reg save0.w r15w)
(defx86reg save0.b r15b)

;;; Use xmm regs for floating-point.  (They can also hold integer values.)
(defx86reg fp0 xmm0)
(defx86reg fp1 xmm1)
(defx86reg fp2 xmm2)
(defx86reg fp3 xmm3)
(defx86reg fp4 xmm4)
(defx86reg fp5 xmm5)
(defx86reg fp6 xmm6)
(defx86reg fp7 xmm7)
(defx86reg fp8 xmm8)
(defx86reg fp9 xmm9)
(defx86reg fp10 xmm10)
(defx86reg fp11 xmm11)
(defx86reg fp12 xmm12)
(defx86reg fp13 xmm13)
(defx86reg fp14 xmm14)
(defx86reg fp15 xmm15)

;;; There are only 8 mmx registers, and they overlap the x87 FPU.
(defx86reg tsp mm7)
(defx86reg next-tsp mm6)
(defx86reg foreign-sp mm5)


;;; Using %fs to access the TCR may be Linux-specific.
(defx86reg rcontext fs)

;;; NEXT-METHOD-CONTEXT is passed from gf-dispatch code to the method
;;; functions that it funcalls.  FNAME is only meaningful when calling
;;; globally named functions through the function cell of a symbol.
;;; It appears that they're never live at the same time.
;;; (We can also consider passing next-method context on the stack.)
;;; Using a boxed register for nargs is intended to keep both imm0
;;; and imm1 free on function entry, to help with processing &optional/&key.
(defx86reg fname temp0)
(defx86reg next-method-context temp0)
;;; We rely one at least one of %ra0/%fn pointing to the current function
;;; (or to a TRA that references the function) at all times.  When we
;;; tail call something, we want %RA0 to point to our caller's TRA and
;;; %FN to point to the new function.  Unless we go out of line to
;;; do tail calls, we need some register not involved in the calling
;;; sequence to hold the current function, since it might get GCed otherwise.
;;; (The odds of this happening are low, but non-zero.)
(defx86reg xfn temp1)

(defx86reg ra1 fn)

(defx86reg allocptr temp0)

    
(defconstant nbits-in-word 64)
(defconstant nbits-in-byte 8)
(defconstant ntagbits 4)
(defconstant nlisptagbits 3)
(defconstant nfixnumtagbits 3)
(defconstant num-subtag-bits 8)
(defconstant fixnumshift 3)
(defconstant fixnum-shift 3)
(defconstant fulltagmask 15)
(defconstant tagmask 7)
(defconstant fixnummask 7)
(defconstant ncharcodebits 8)
(defconstant charcode-shift 8)
(defconstant word-shift 3)
(defconstant word-size-in-bytes 8)
(defconstant node-size word-size-in-bytes)
(defconstant dnode-size 16)
(defconstant dnode-align-bits 4)
(defconstant dnode-shift dnode-align-bits)
(defconstant bitmap-shift 6)

(defconstant fixnumone (ash 1 fixnumshift))
(defconstant fixnum-one fixnumone)
(defconstant fixnum1 fixnumone)

(defconstant target-most-negative-fixnum (ash -1 (1- (- nbits-in-word nfixnumtagbits))))
(defconstant target-most-positive-fixnum (1- (ash 1 (1- (- nbits-in-word nfixnumtagbits)))))

;;; 3-bit "lisptag" values

(defconstant tag-fixnum 0)
(defconstant tag-imm-0 1)               ;subtag-single-float ONLY
(defconstant tag-imm-1 2)               ;subtag-character, internal markers
(defconstant tag-list 3)                ;fulltag-cons or NIL
(defconstant tag-tra 4)                 ;tagged return-address
(defconstant tag-misc 5)                ;random uvector
(defconstant tag-symbol 6)              ;non-null symbol
(defconstant tag-function 7)            ;function entry point

(defconstant tag-single-float tag-imm-0)

;;; 4-bit "fulltag" values
(defconstant fulltag-even-fixnum 0)
(defconstant fulltag-imm-0 1)           ;subtag-single-float ONLY
(defconstant fulltag-imm-1 2)           ;characters, markers
(defconstant fulltag-cons 3)
(defconstant fulltag-tra-0 4)           ;tagged return address
(defconstant fulltag-nodeheader-0 5)
(defconstant fulltag-nodeheader-1 6)
(defconstant fulltag-immheader-0 7)
(defconstant fulltag-odd-fixnum 8)
(defconstant fulltag-immheader-1 9)
(defconstant fulltag-immheader-2 10)
(defconstant fulltag-nil 11)
(defconstant fulltag-tra-1 12)
(defconstant fulltag-misc 13)
(defconstant fulltag-symbol 14)
(defconstant fulltag-function 15)

(defconstant fulltag-single-float fulltag-imm-0)

(defmacro define-subtag (name tag value)
  `(defconstant ,(ccl::form-symbol "SUBTAG-" name) (logior ,tag (ash ,value ntagbits))))


(define-subtag arrayH fulltag-nodeheader-1 8)
(define-subtag vectorH fulltag-nodeheader-0 9)
(define-subtag simple-vector fulltag-nodeheader-1 9)
(defconstant min-vector-subtag  subtag-vectorH)
(defconstant min-array-subtag  subtag-arrayH)

(defconstant ivector-class-64-bit  fulltag-immheader-2)
(defconstant ivector-class-32-bit  fulltag-immheader-1)
(defconstant ivector-class-other-bit  fulltag-immheader-0)

(define-subtag s64-vector ivector-class-64-bit 13)
(define-subtag u64-vector ivector-class-64-bit 14)
(define-subtag double-float-vector ivector-class-64-bit 15)
	
(define-subtag s32-vector ivector-class-32-bit 13)
(define-subtag u32-vector ivector-class-32-bit 14)
(define-subtag single-float-vector ivector-class-32-bit 15)
	
(define-subtag s16-vector ivector-class-other-bit 10)
(define-subtag u16-vector ivector-class-other-bit 11)
(define-subtag simple-base-string ivector-class-other-bit 12)
(defconstant min-8-bit-ivector-subtag subtag-simple-base-string)
(define-subtag s8-vector ivector-class-other-bit 13)
(define-subtag u8-vector ivector-class-other-bit 14)
(define-subtag bit-vector ivector-class-other-bit 15)


;;; There's some room for expansion in non-array ivector space.
(define-subtag macptr ivector-class-64-bit 0)
(define-subtag dead-macptr ivector-class-64-bit 1)
(define-subtag bignum ivector-class-32-bit 0)
(define-subtag double-float ivector-class-32-bit 1)
(define-subtag xcode-vector ivector-class-32-bit 2)


        
;;; Note the difference between (e.g) fulltag-function - which
;;; defines what the low 4 bytes of a function pointer look like -
;;; and subtag-function - which describes what the subtag byte
;;; in a function header looks like.  (Likewise for fulltag-symbol
;;; and subtag-symbol)

(define-subtag function fulltag-nodeheader-0 0)
(define-subtag symbol fulltag-nodeheader-0 1)
(define-subtag catch-frame fulltag-nodeheader-0 2)
(define-subtag hash-vector fulltag-nodeheader-0 3)
(define-subtag pool fulltag-nodeheader-0 4)
(define-subtag weak fulltag-nodeheader-0 5)
(define-subtag package fulltag-nodeheader-0 6)
(define-subtag slot-vector fulltag-nodeheader-0 7)
(define-subtag lisp-thread fulltag-nodeheader-0 8)

(define-subtag ratio fulltag-nodeheader-1 0)
(define-subtag complex fulltag-nodeheader-1 1)
(define-subtag instance fulltag-nodeheader-1 2)
(define-subtag struct fulltag-nodeheader-1 3)
(define-subtag istruct fulltag-nodeheader-1 4)
(define-subtag value-cell fulltag-nodeheader-1 5)
(define-subtag xfunction fulltag-nodeheader-1 6)
(define-subtag lock fulltag-nodeheader-1 7)
	
(defconstant nil-value (+ #x2000 fulltag-nil))
(defconstant t-value (+ #x2020 fulltag-symbol))
(defconstant misc-bias fulltag-misc)
(defconstant cons-bias fulltag-cons)
(defconstant t-offset (- t-value nil-value))

(defconstant misc-header-offset (- fulltag-misc))
(defconstant misc-data-offset (+ misc-header-offset node-size))
(defconstant misc-subtag-offset misc-header-offset)
(defconstant misc-dfloat-offset misc-data-offset)

(define-subtag single-float fulltag-imm-0 0)

(define-subtag character fulltag-imm-1 0)

(define-subtag unbound fulltag-imm-1 1)
(defconstant unbound-marker subtag-unbound)
(defconstant undefined unbound-marker)
(define-subtag slot-unbound fulltag-imm-1 2)
(defconstant slot-unbound-marker subtag-slot-unbound)
(define-subtag illegal fulltag-imm-1 3)
(defconstant illegal-marker subtag-illegal)
(define-subtag no-thread-local-binding fulltag-imm-1 4)
(defconstant no-thread-local-binding-marker subtag-no-thread-local-binding)

(defconstant max-64-bit-constant-index (ash (+ #x7fffffff x8664::misc-dfloat-offset) -3))
(defconstant max-32-bit-constant-index (ash (+ #x7fffffff x8664::misc-data-offset) -2))
(defconstant max-16-bit-constant-index (ash (+ #x7fffffff x8664::misc-data-offset) -1))
(defconstant max-8-bit-constant-index (+ #x7fffffff x8664::misc-data-offset))
(defconstant max-1-bit-constant-index (ash (+ #x7fffffff x8664::misc-data-offset) 5))

)
(defmacro define-storage-layout (name origin &rest cells)
  `(progn
    (ccl::defenum (:start ,origin :step 8)
        ,@(mapcar #'(lambda (cell) (ccl::form-symbol name "." cell)) cells))
    (defconstant ,(ccl::form-symbol name ".SIZE") ,(* (length cells)
                                                      8))))

(defmacro define-lisp-object (name tagname &rest cells)
  `(define-storage-layout ,name ,(- (symbol-value tagname)) ,@cells))

(defmacro define-fixedsized-object (name (&optional (fulltag 'fulltag-misc))
                                         &rest non-header-cells)
  `(progn
     (define-lisp-object ,name ,fulltag header ,@non-header-cells)
     (ccl::defenum ()
       ,@(mapcar #'(lambda (cell) (ccl::form-symbol name "." cell "-CELL")) non-header-cells))
     (defconstant ,(ccl::form-symbol name ".ELEMENT-COUNT") ,(length non-header-cells))))

;;; Order of CAR and CDR doesn't seem to matter much - there aren't
;;; too many tricks to be played with predecrement/preincrement addressing.
;;; Keep them in the confusing MCL 3.0 order, to avoid confusion.
(define-lisp-object cons fulltag-cons 
  cdr 
  car)

(define-fixedsized-object ratio ()
  numer
  denom)

;;; It's slightly easier (for bootstrapping reasons)
;;; to view a DOUBLE-FLOAT as being UVECTOR with 2 32-bit elements
;;; (rather than 1 64-bit element).

(defconstant double-float.value misc-data-offset)
(defconstant double-float.value-cell 0)
(defconstant double-float.val-low double-float.value)
(defconstant double-float.val-low-cell 0)
(defconstant double-float.val-high (+ double-float.value 4))
(defconstant double-float.val-high-cell 1)
(defconstant double-float.element-count 2)
(defconstant double-float.size 16)

(define-fixedsized-object complex ()
  realpart
  imagpart
)

;;; There are two kinds of macptr; use the length field of the header if you
;;; need to distinguish between them
(define-fixedsized-object macptr ()
  address
  domain
  type
)

(define-fixedsized-object xmacptr ()
  address
  domain
  type
  flags
  link
)


;;; Need to think about catch frames on x8664.
(define-fixedsized-object catch-frame ()
  catch-tag                             ; #<unbound> -> unwind-protect, else catch
  link                                  ; tagged pointer to next older catch frame
  mvflag                                ; 0 if single-value, 1 if uwp or multiple-value
  csp                                   ; pointer to control stack
  db-link                               ; value of dynamic-binding link on thread entry.
  save-save3                            ; saved nvrs
  save-save2
  save-save1
  save-save0
  xframe                                ; exception-frame link
  tsp-segment                           ; mostly padding, for now.
)

(define-fixedsized-object lock ()
  _value                                ;finalizable pointer to kernel object
  kind                                  ; '0 = recursive-lock, '1 = rwlock
  writer				;tcr of owning thread or 0
  name
  )

(define-fixedsized-object lisp-thread ()
  tcr
  name
  cs-size
  vs-size
  ts-size
  initial-function.args
  interrupt-functions
  interrupt-lock
  startup-function
  state
  state-change-lock
)

;;; If we're pointing at the "symbol-vector", we can use these
(define-fixedsized-object symptr ()
  pname
  vcell
  fcell
  package-predicate
  flags
  plist
  binding-index
)

(define-fixedsized-object symbol (fulltag-symbol)
  pname
  vcell
  fcell
  package-predicate
  flags
  plist
  binding-index
)

(defconstant nilsym-offset (+ t-offset symbol.size))


(define-fixedsized-object vectorH ()
  logsize                               ; fillpointer if it has one, physsize otherwise
  physsize                              ; total size of (possibly displaced) data vector
  data-vector                           ; object this header describes
  displacement                          ; true displacement or 0
  flags                                 ; has-fill-pointer,displaced-to,adjustable bits; subtype of underlying simple vector.
)

(define-lisp-object arrayH fulltag-misc
  header                                ; subtag = subtag-arrayH
  rank                                  ; NEVER 1
  physsize                              ; total size of (possibly displaced) data vector
  data-vector                           ; object this header describes
  displacement                          ; true displacement or 0  
  flags                                 ; has-fill-pointer,displaced-to,adjustable bits; subtype of underlying simple vector.
 ;; Dimensions follow
)

(defconstant arrayH.rank-cell 0)
(defconstant arrayH.physsize-cell 1)
(defconstant arrayH.data-vector-cell 2)
(defconstant arrayH.displacement-cell 3)
(defconstant arrayH.flags-cell 4)
(defconstant arrayH.dim0-cell 5)

(defconstant arrayH.flags-cell-bits-byte (byte 8 0))
(defconstant arrayH.flags-cell-subtag-byte (byte 8 8))

(define-fixedsized-object value-cell ()
  value)


(define-storage-layout lisp-frame 0
  backptr
  return-address)

;;; The kernel uses these (rather generically named) structures
;;; to keep track of various memory regions it (or the lisp) is
;;; interested in.


(define-storage-layout area 0
  pred                                  ; pointer to preceding area in DLL
  succ                                  ; pointer to next area in DLL
  low                                   ; low bound on area addresses
  high                                  ; high bound on area addresses.
  active                                ; low limit on stacks, high limit on heaps
  softlimit                             ; overflow bound
  hardlimit                             ; another one
  code                                  ; an area-code; see below
  markbits                              ; bit vector for GC
  ndwords                               ; "active" size of dynamic area or stack
  older                                 ; in EGC sense
  younger                               ; also for EGC
  h                                     ; Handle or null pointer
  softprot                              ; protected_area structure pointer
  hardprot                              ; another one.
  owner                                 ; fragment (library) which "owns" the area
  refbits                               ; bitvector for intergenerational refernces
  threshold                             ; for egc
  gc-count                              ; generational gc count.
)


(define-storage-layout protected-area 0
  next
  start                                 ; first byte (page-aligned) that might be protected
  end                                   ; last byte (page-aligned) that could be protected
  nprot                                 ; Might be 0
  protsize                              ; number of bytes to protect
  why)

(eval-when (:compile-toplevel :load-toplevel :execute)
(defconstant tcr-bias 512)
)

(define-storage-layout tcr (- tcr-bias)
  prev					; in doubly-linked list 
  next					; in doubly-linked list
  single-float-convert                  ; faster to box/unbox through memory
  linear
  linear-end
  lisp-fpscr-high
  db-link				; special binding chain head 
  catch-top				; top catch frame 
  save-vsp				; SP when in foreign code 
  save-tsp				; TSP, at all times
  foreign-sp                            ; SP when in lisp code
  cs-area				; cstack area pointer 
  vs-area				; vstack area pointer 
  ts-area				; tstack area pointer 
  cs-limit				; cstack overflow limit
  total-bytes-allocated
  log2-allocation-quantum		; unboxed
  interrupt-pending			; fixnum
  xframe				; exception frame linked list
  errno-loc				; thread-private, maybe
  ffi-exception				; fpscr bits from ff-call.
  osid					; OS thread id 
  valence				; odd when in foreign code 
  foreign-exception-status
  native-thread-info
  native-thread-id
  last-allocptr
  save-allocptr
  save-allocbase
  reset-completion
  activate
  suspend-count
  suspend-context
  pending-exception-context
  suspend				; semaphore for suspension notify 
  resume				; sempahore for resumption notify
  flags					; foreign, being reset, ...
  gc-context
  termination-semaphore
  unwinding
  tlb-limit
  tlb-pointer
  shutdown-count
)

(defconstant tcr.single-float-convert.value (+ 4 tcr.single-float-convert))


(defconstant interrupt-level-binding-index (ash 1 fixnumshift))

(define-storage-layout lockptr 0
  avail
  owner
  count
  signal
  waiting
  malloced-ptr)

(defmacro define-header (name element-count subtag)
  `(defconstant ,name (logior (ash ,element-count num-subtag-bits) ,subtag)))

(define-header double-float-header double-float.element-count subtag-double-float)

;;; We could possibly have a one-digit bignum header when dealing
;;; with "small bignums" in some bignum code.  Like other cases of
;;; non-normalized bignums, they should never escape from the lab.
(define-header one-digit-bignum-header 1 subtag-bignum)
(define-header two-digit-bignum-header 2 subtag-bignum)
(define-header three-digit-bignum-header 3 subtag-bignum)
(define-header four-digit-bignum-header 4 subtag-bignum)
(define-header five-digit-bignum-header 5 subtag-bignum)
(define-header symbol-header symbol.element-count subtag-symbol)
(define-header value-cell-header value-cell.element-count subtag-value-cell)
(define-header macptr-header macptr.element-count subtag-macptr)

(defun %kernel-global (sym)
  (let* ((pos (position sym x86::*x86-kernel-globals* :test #'string=)))
    (if pos
      (- (+ fulltag-nil (* (1+ pos) node-size)))
      (error "Unknown kernel global : ~s ." sym))))

(defmacro kernel-global (sym)
  (let* ((pos (position sym x86::*x86-kernel-globals* :test #'string=)))
    (if pos
      (- (+ fulltag-nil (* (1+ pos) node-size)))
      (error "Unknown kernel global : ~s ." sym))))

(ccl::defenum (:prefix "KERNEL-IMPORT-" :start 0 :step node-size)
  fd-setsize-bytes
  do-fd-set
  do-fd-clr
  do-fd-is-set
  do-fd-zero
  MakeDataExecutable
  GetSharedLibrary
  FindSymbol
  malloc
  free
  allocate_tstack
  allocate_vstack
  register_cstack
  condemn-area
  metering-control
  restore-soft-stack-limit
  egc-control
  lisp-bug
  NewThread
  YieldToThread
  DisposeThread
  ThreadCurrentStackSpace
  usage-exit
  save-fp-context
  restore-fp-context
  put-altivec-registers
  get-altivec-registers
  new-semaphore
  wait-on-semaphore
  signal-semaphore
  destroy-semaphore
  new-recursive-lock
  lock-recursive-lock
  unlock-recursive-lock
  destroy-recursive-lock
  suspend-other-threads
  resume-other-threads
  suspend-tcr
  resume-tcr
  rwlock-new
  rwlock-destroy
  rwlock-rlock
  rwlock-wlock
  rwlock-unlock
  recursive-lock-trylock
  foreign-name-and-offset
)

(defmacro nrs-offset (name)
  (let* ((pos (position name x86::*x86-nilreg-relative-symbols* :test #'eq)))
    (if pos (* (1- pos) symbol.size))))

(defparameter *x8664-target-uvector-subtags*
  `((:bignum . ,subtag-bignum)
    (:ratio . ,subtag-ratio)
    (:single-float . ,subtag-single-float)
    (:double-float . ,subtag-double-float)
    (:complex . ,subtag-complex  )
    (:symbol . ,subtag-symbol)
    (:function . ,subtag-function )
    (:xcode-vector . ,subtag-xcode-vector)
    (:macptr . ,subtag-macptr )
    (:catch-frame . ,subtag-catch-frame)
    (:struct . ,subtag-struct )    
    (:istruct . ,subtag-istruct )
    (:pool . ,subtag-pool )
    (:population . ,subtag-weak )
    (:hash-vector . ,subtag-hash-vector )
    (:package . ,subtag-package )
    (:value-cell . ,subtag-value-cell)
    (:instance . ,subtag-instance )
    (:lock . ,subtag-lock )
    (:slot-vector . ,subtag-slot-vector)
    (:simple-string . ,subtag-simple-base-string )
    (:bit-vector . ,subtag-bit-vector )
    (:signed-8-bit-vector . ,subtag-s8-vector )
    (:unsigned-8-bit-vector . ,subtag-u8-vector )
    (:signed-16-bit-vector . ,subtag-s16-vector )
    (:unsigned-16-bit-vector . ,subtag-u16-vector )
    (:signed-32-bit-vector . ,subtag-s32-vector )
    (:unsigned-32-bit-vector . ,subtag-u32-vector )
    (:signed-64-bit-vector . ,subtag-s64-vector)
    (:unsigned-64-bit-vector . ,subtag-u64-vector)    
    (:single-float-vector . ,subtag-single-float-vector)
    (:double-float-vector . ,subtag-double-float-vector )
    (:simple-vector . ,subtag-simple-vector )
    (:vector-header . ,subtag-vectorH)
    (:array-header . ,subtag-arrayH)))

;;; This should return NIL unless it's sure of how the indicated
;;; type would be represented (in particular, it should return
;;; NIL if the element type is unknown or unspecified at compile-time.
(defun x8664-array-type-name-from-ctype (ctype)
  (when (typep ctype 'ccl::array-ctype)
    (let* ((element-type (ccl::array-ctype-element-type ctype)))
      (typecase element-type
        (ccl::class-ctype
         (let* ((class (ccl::class-ctype-class element-type)))
           (if (or (eq class ccl::*character-class*)
                   (eq class ccl::*base-char-class*)
                   (eq class ccl::*standard-char-class*))
             :simple-string
             :simple-vector)))
        (ccl::numeric-ctype
         (if (eq (ccl::numeric-ctype-complexp element-type) :complex)
           :simple-vector
           (case (ccl::numeric-ctype-class element-type)
             (integer
              (let* ((low (ccl::numeric-ctype-low element-type))
                     (high (ccl::numeric-ctype-high element-type)))
                (cond ((or (null low) (null high))
                       :simple-vector)
                      ((and (>= low 0) (<= high 1))
                       :bit-vector)
                      ((and (>= low 0) (<= high 255))
                       :unsigned-8-bit-vector)
                      ((and (>= low 0) (<= high 65535))
                       :unsigned-16-bit-vector)
                      ((and (>= low 0) (<= high #xffffffff))
                       :unsigned-32-bit-vector)
                      ((and (>= low 0) (<= high #xffffffffffffffff))
                       :unsigned-64-bit-vector)
                      ((and (>= low -128) (<= high 127))
                       :signed-8-bit-vector)
                      ((and (>= low -32768) (<= high 32767))
                       :signed-16-bit-vector)
                      ((and (>= low (ash -1 31)) (<= high (1- (ash 1 31))))
                       :signed-32-bit-vector)
                      ((and (>= low (ash -1 63)) (<= high (1- (ash 1 63))))
                       :signed-64-bit-vector)
                      (t :simple-vector))))
             (float
              (case (ccl::numeric-ctype-format element-type)
                ((double-float long-float) :double-float-vector)
                ((single-float short-float) :single-float-vector)
                (t :simple-vector)))
             (t :simple-vector))))
        (ccl::unknown-ctype)
        (ccl::named-ctype
         (if (eq element-type ccl::*universal-type*)
           :simple-vector))
        (t)))))

(defun x8664-misc-byte-count (subtag element-count)
  (declare (fixnum subtag))
  (if (logbitp (logand subtag fulltagmask)
               (logior (ash 1 fulltag-immheader-0)
                       (ash 1 fulltag-immheader-1)))
    (ash element-count 3)
    (case (logand subtag fulltagmask)
      (#.ivector-class-64-bit (ash element-count 3))
      (#.ivector-class-32-bit (ash element-count 2))
      (t
       (if (= subtag subtag-bit-vector)
         (ash (+ 7 element-count) -3)
         (if (>= subtag min-8-bit-ivector-subtag)
           element-count
           (ash element-count 1)))))))

(eval-when (:compile-toplevel :load-toplevel :execute)
(defparameter *x8664-subprims-shift* 3)
(defparameter *x8664-subprims-base* (ash 5 12) )
)

(declaim (special *x8664-subprims*))

;;; For now, nothing's nailed down and we don't say anything about
;;; registers clobbered.
(let* ((origin *x8664-subprims-base*)
       (step (ash 1 *x8664-subprims-shift*)))
  (flet ((define-x8664-subprim (name)
             (ccl::make-subprimitive-info :name (string name)
                                          :offset (prog1 origin
                                                    (incf origin step)))))
    (macrolet ((defx8664subprim (name)
                   `(define-x8664-subprim ',name)))
      (defparameter *x8664-subprims*
        (vector
         (defx8664subprim .SPjmpsym)
         (defx8664subprim .SPjmpnfn)
         (defx8664subprim .SPfuncall)
         (defx8664subprim .SPmkcatch1v)
         (defx8664subprim .SPmkunwind)
         (defx8664subprim .SPmkcatchmv)
         (defx8664subprim .SPthrow)
         (defx8664subprim .SPnthrowvalues)
         (defx8664subprim .SPnthrow1value)
         (defx8664subprim .SPbind)
         (defx8664subprim .SPbind-self)
         (defx8664subprim .SPbind-nil)
         (defx8664subprim .SPbind-self-boundp-check)
         (defx8664subprim .SPrplaca)
         (defx8664subprim .SPrplacd)
         (defx8664subprim .SPconslist)
         (defx8664subprim .SPconslist-star)
         (defx8664subprim .SPstkconslist)
         (defx8664subprim .SPstkconslist-star)
         (defx8664subprim .SPmkstackv)
         (defx8664subprim .SPsubtag-misc-ref)
         (defx8664subprim .SPsetqsym)
         (defx8664subprim .SPprogvsave)
         (defx8664subprim .SPstack-misc-alloc)
         (defx8664subprim .SPgvector)
         (defx8664subprim .SPnvalret)
         (defx8664subprim .SPmvpass)
         (defx8664subprim .SPfitvals)
         (defx8664subprim .SPnthvalue)
         (defx8664subprim .SPvalues)
         (defx8664subprim .SPdefault-optional-args)
         (defx8664subprim .SPopt-supplied-p)
         (defx8664subprim .SPheap-rest-arg)
         (defx8664subprim .SPreq-heap-rest-arg)
         (defx8664subprim .SPheap-cons-rest-arg)
         (defx8664subprim .SPsimple-keywords)
         (defx8664subprim .SPkeyword-args)
         (defx8664subprim .SPkeyword-bind)
         (defx8664subprim .SPpoweropen-ffcall)
         (defx8664subprim .SPunused-0)
         (defx8664subprim .SPksignalerr)
         (defx8664subprim .SPstack-rest-arg)
         (defx8664subprim .SPreq-stack-rest-arg)
         (defx8664subprim .SPstack-cons-rest-arg)
         (defx8664subprim .SPpoweropen-callbackX)
         (defx8664subprim .SPcall-closure)
         (defx8664subprim .SPgetXlong)
         (defx8664subprim .SPspreadargz)
         (defx8664subprim .SPtfuncallgen)
         (defx8664subprim .SPtfuncallslide)
         (defx8664subprim .SPtfuncallvsp)
         (defx8664subprim .SPtcallsymgen)
         (defx8664subprim .SPtcallsymslide)
         (defx8664subprim .SPtcallsymvsp)
         (defx8664subprim .SPtcallnfngen)
         (defx8664subprim .SPtcallnfnslide)
         (defx8664subprim .SPtcallnfnvsp)
         (defx8664subprim .SPmisc-ref)
         (defx8664subprim .SPmisc-set)
         (defx8664subprim .SPstkconsyz)
         (defx8664subprim .SPstkvcell0)
         (defx8664subprim .SPstkvcellvsp)
         (defx8664subprim .SPmakestackblock)
         (defx8664subprim .SPmakestackblock0)
         (defx8664subprim .SPmakestacklist)
         (defx8664subprim .SPstkgvector)
         (defx8664subprim .SPmisc-alloc)
         (defx8664subprim .SPpoweropen-ffcallX)
         (defx8664subprim .SPgvset)
         (defx8664subprim .SPmacro-bind)
         (defx8664subprim .SPdestructuring-bind)
         (defx8664subprim .SPdestructuring-bind-inner)
         (defx8664subprim .SPrecover-values)
         (defx8664subprim .SPvpopargregs)
         (defx8664subprim .SPinteger-sign)
         (defx8664subprim .SPsubtag-misc-set)
         (defx8664subprim .SPspread-lexpr-z)
         (defx8664subprim .SPstore-node-conditional)
         (defx8664subprim .SPreset)
         (defx8664subprim .SPmvslide)
         (defx8664subprim .SPsave-values)
         (defx8664subprim .SPadd-values)
         (defx8664subprim .SPpoweropen-callback)
         (defx8664subprim .SPmisc-alloc-init)
         (defx8664subprim .SPstack-misc-alloc-init)
         (defx8664subprim .SPset-hash-key)
         (defx8664subprim .SPunused-1)
         (defx8664subprim .SPcallbuiltin)
         (defx8664subprim .SPcallbuiltin0)
         (defx8664subprim .SPcallbuiltin1)
         (defx8664subprim .SPcallbuiltin2)
         (defx8664subprim .SPcallbuiltin3)
         (defx8664subprim .SPpopj)
         (defx8664subprim .SPrestorefullcontext)
         (defx8664subprim .SPsavecontextvsp)
         (defx8664subprim .SPsavecontext0)
         (defx8664subprim .SPrestorecontext)
         (defx8664subprim .SPlexpr-entry)
         (defx8664subprim .SPpoweropen-syscall)
         (defx8664subprim .SPbuiltin-plus)
         (defx8664subprim .SPbuiltin-minus)
         (defx8664subprim .SPbuiltin-times)
         (defx8664subprim .SPbuiltin-div)
         (defx8664subprim .SPbuiltin-eq)
         (defx8664subprim .SPbuiltin-ne)
         (defx8664subprim .SPbuiltin-gt)
         (defx8664subprim .SPbuiltin-ge)
         (defx8664subprim .SPbuiltin-lt)
         (defx8664subprim .SPbuiltin-le)
         (defx8664subprim .SPbuiltin-eql)
         (defx8664subprim .SPbuiltin-length)
         (defx8664subprim .SPbuiltin-seqtype)
         (defx8664subprim .SPbuiltin-assq)
         (defx8664subprim .SPbuiltin-memq)
         (defx8664subprim .SPbuiltin-logbitp)
         (defx8664subprim .SPbuiltin-logior)
         (defx8664subprim .SPbuiltin-logand)
         (defx8664subprim .SPbuiltin-ash)
         (defx8664subprim .SPbuiltin-negate)
         (defx8664subprim .SPbuiltin-logxor)
         (defx8664subprim .SPbuiltin-aref1)
         (defx8664subprim .SPbuiltin-aset1)
         (defx8664subprim .SPbreakpoint)
         (defx8664subprim .SPeabi-ff-call)
         (defx8664subprim .SPeabi-callback)
         (defx8664subprim .SPeabi-syscall)
         (defx8664subprim .SPgetu64)
         (defx8664subprim .SPgets64)
         (defx8664subprim .SPmakeu64)
         (defx8664subprim .SPmakes64)
         (defx8664subprim .SPspecref)
         (defx8664subprim .SPspecset)
         (defx8664subprim .SPspecrefcheck)
         (defx8664subprim .SPrestoreintlevel)
         (defx8664subprim .SPmakes32)
         (defx8664subprim .SPmakeu32)
         (defx8664subprim .SPgets32)
         (defx8664subprim .SPgetu32)
         (defx8664subprim .SPfix-overflow)
         (defx8664subprim .SPmvpasssym)
         (defx8664subprim .SPunused-2)
         (defx8664subprim .SPunused-3)
         (defx8664subprim .SPunused-4)
         (defx8664subprim .SPunused-5)
         (defx8664subprim .SPunused-6)
         (defx8664subprim .SPunbind-interrupt-level)
         (defx8664subprim .SPunbind)
         (defx8664subprim .SPunbind-n)
         (defx8664subprim .SPunbind-to)
         (defx8664subprim .SPbind-interrupt-level-m1)
         (defx8664subprim .SPbind-interrupt-level)
         (defx8664subprim .SPbind-interrupt-level-0)
         (defx8664subprim .SPprogvrestore)
         )))))

(defparameter *x8664-target-arch*
  (arch::make-target-arch :name :x8664
                          :lisp-node-size 8
                          :nil-value nil-value
                          :fixnum-shift fixnumshift
                          :most-positive-fixnum (1- (ash 1 (1- (- 64 fixnumshift))))
                          :most-negative-fixnum (- (ash 1 (1- (- 64 fixnumshift))))
                          :misc-data-offset misc-data-offset
                          :misc-dfloat-offset misc-dfloat-offset
                          :nbits-in-word 64
                          :ntagbits 4
                          :nlisptagbits 3
                          :uvector-subtags *x8664-target-uvector-subtags*
                          :max-64-bit-constant-index max-64-bit-constant-index
                          :max-32-bit-constant-index max-32-bit-constant-index
                          :max-16-bit-constant-index max-16-bit-constant-index
                          :max-8-bit-constant-index max-8-bit-constant-index
                          :max-1-bit-constant-index max-1-bit-constant-index
                          :word-shift 3
                          :code-vector-prefix '(#$"CODE")
                          :gvector-types '(:ratio :complex :symbol :function
                                           :catch-frame :structure :istruct
                                           :pool :population :hash-vector
                                           :package :value-cell :instance
                                           :lock :slot-vector
                                           :simple-vector)
                          :1-bit-ivector-types '(:bit-vector)
                          :8-bit-ivector-types '(:signed-8-bit-vector
                                                 :unsigned-8-bit-vector
                                                 :simple-string)
                          :16-bit-ivector-types '(:signed-16-bit-vector
                                                  :unsigned-16-bit-vector)
                          :32-bit-ivector-types '(:signed-32-bit-vector
                                                  :unsigned-32-bit-vector
                                                  :single-float-vector
                                                  :double-float
                                                  :bignum)
                          :64-bit-ivector-types '(:double-float-vector
                                                  :unsigned-64-bit-vector
                                                  :signed-64-bit-vector)
                          :array-type-name-from-ctype-function
                          #'x8664-array-type-name-from-ctype
                          :package-name "X8664"
                          :t-offset t-offset
                          :array-data-size-function #'x8664-misc-byte-count
                          :numeric-type-name-to-typecode-function
                          #'(lambda (type-name)
                              (ecase type-name
                                (fixnum tag-fixnum)
                                (bignum subtag-bignum)
                                ((short-float single-float) subtag-single-float)
                                ((long-float double-float) subtag-double-float)
                                (ratio subtag-ratio)
                                (complex subtag-complex)))
                          :subprims-base x8664::*x8664-subprims-base*
                          :subprims-shift x8664::*x8664-subprims-shift*
                          :subprims-table x8664::*x8664-subprims*
                          :primitive->subprims `(((0 . 23) . ,(ccl::%subprim-name->offset '.SPbuiltin-plus x8664::*x8664-subprims*)))
                          :unbound-marker-value unbound-marker
                          :slot-unbound-marker-value slot-unbound-marker
                          :fixnum-tag tag-fixnum
                          :single-float-tag subtag-single-float
                          :single-float-tag-is-subtag nil
                          :double-float-tag subtag-double-float
                          :cons-tag fulltag-cons
                          :null-tag fulltag-nil
                          :symbol-tag fulltag-symbol
                          :symbol-tag-is-subtag nil
                          :function-tag fulltag-function
                          :function-tag-is-subtag nil
                          ))
