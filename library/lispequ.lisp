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

;; LispEqu.lisp

(in-package "CCL")

(defconstant $flags_Normal 0)
(defconstant $flags_DisposeRecursiveLock 1)
(defconstant $flags_DisposPtr 2)
(defconstant $flags_DisposeRwlock 3)
(defconstant $flags_DisposeSemaphore 4)

(defconstant $system-lock-type-recursive 0)
(defconstant $system-lock-type-rwlock 1)

;;; this stuff is really ppc specific at the moment
(defconstant $population_weak-list 0)
(defconstant $population_weak-alist 1)
(defconstant $population_termination-bit 16)

;;; type of 0 is a weak-list
;;; Note that this evals its args in the wrong order.
(defmacro %cons-population (data &optional (type 0) (termination? nil))
  (if termination?
    `(gvector :population 0 (logior (ash 1 $population_termination-bit) ,type) ,data nil)
    `(gvector :population 0 ,type ,data)))

(defmacro %cons-terminatable-alist (&optional data)
  `(%cons-population ,data $population_weak-alist t))

;;; The GC assumes that this structure is laid out exactly as below.
;;; It also assumes that if the $population_termination-bit is set in the
;;; population.type slot, the vector is of length 4, otherwise 3.
(def-accessors (population) %svref
  population.gclink
  population.type
  population.data
  population.termination-list)

(def-accessors () uvref
  nil
  nil
  population-data                      ; type-checked
  population-termination-list)

(defmacro %cons-pool (&optional data)
  `(gvector :pool ,data))

(def-accessors (pool) %svref
  pool.data)

(def-accessors (resource) %svref
  nil                                   ; 'resource
  resource.constructor
  resource.destructor
  resource.initializer
  resource.pool)

(defmacro gvector (type-keyword &rest initial-values)
  `(%gvector ,(type-keyword-code type-keyword) ,@initial-values))


(defmacro allocate-typed-vector (type-keyword elements &optional (init nil init-p))
  `(%alloc-misc ,elements ,(type-keyword-code type-keyword)
    ,@(if init-p `(,init))))
    

(def-accessors (semaphore) %svref
  nil					;'semaphore
  semaphore.value)


(defmacro %istruct (istruct-name &rest initial-values)
  `(gvector :ISTRUCT ,istruct-name ,@initial-values))


(defmacro %cons-resource (constructor &optional destructor initializer)
  `(%istruct 'resource ,constructor ,destructor ,initializer (%cons-pool)))



;;; Symbol [f,v]bits.

(defconstant $sym_bit_bound 0)		;Proclaimed bound.
(defconstant $sym_bit_const 1)
(defconstant $sym_bit_global 2)         ;Should never be lambda-bound.
(defconstant $sym_bit_special 4)
(defconstant $sym_vbit_typeppred 5)
(defconstant $sym_bit_indirect 6)
(defconstant $sym_bit_defunct 7)

(defconstant $sym_vbit_bound $sym_bit_bound)
(defconstant $sym_vbit_const $sym_bit_const)
(defconstant $sym_vbit_global $sym_bit_global)
(defconstant $sym_vbit_special $sym_bit_special)
(defconstant $sym_vbit_indirect $sym_bit_indirect)
(defconstant $sym_vbit_defunct $sym_bit_defunct)

(defconstant $sym_fbit_frozen (+ 8 $sym_bit_bound))
(defconstant $sym_fbit_special (+ 8 $sym_bit_special))
(defconstant $sym_fbit_indirect (+ 8 $sym_bit_indirect))
(defconstant $sym_fbit_defunct (+ 8 $sym_bit_defunct))

(defconstant $sym_fbit_constant_fold (+ 8 $sym_bit_const))
(defconstant $sym_fbit_fold_subforms (+ 8 $sym_bit_global))

(def-accessors () %svref
  nil					;'destructure-state
  destructure-state.current
  destructure-state.whole
  destructure-state.lambda
  )

;Lfun bits.
;Assumed to be a fixnum, so if you ever assign a bit number > 28,
;change lfun-bits and its callers.
(defconstant $lfbits-nonnullenv-bit 0)
(defconstant $lfbits-keys-bit 1)
(defconstant $lfbits-numopt (byte 5 2))
(defconstant $lfbits-restv-bit 7)
(defconstant $lfbits-numreq (byte 6 8))
(defconstant $lfbits-optinit-bit 14)
(defconstant $lfbits-rest-bit 15)
(defconstant $lfbits-aok-bit 16)
(defconstant $lfbits-numinh (byte 6 17))
(defconstant $lfbits-symmap-bit 23)
(defconstant $lfbits-trampoline-bit 24)
(defconstant $lfbits-evaluated-bit 25)
(defconstant $lfbits-cm-bit 26)         ; combined-method
(defconstant $lfbits-nextmeth-bit 26)   ; or call-next-method with method-bit
(defconstant $lfbits-gfn-bit 27)        ; generic-function
(defconstant $lfbits-nextmeth-with-args-bit 27)   ; or call-next-method-with-args with method-bit
(defconstant $lfbits-method-bit 28)     ; method function
(defconstant $lfbits-noname-bit 29)


(defconstant $lfbits-args-mask
  (%ilogior (dpb -1 $lfbits-numreq 0)
            (dpb -1 $lfbits-numopt 0)
            (%ilsl $lfbits-rest-bit 1)
            (%ilsl $lfbits-keys-bit 1)
            (%ilsl $lfbits-aok-bit 1)))

;Bits in $arh_bits.
(defconstant $arh_adjp_bit 7)		;adjustable-p
(defconstant $arh_fill_bit 6)		;fill-pointer-p
(defconstant $arh_disp_bit 5)		;displaced to another array header -p
(defconstant $arh_simple_bit 4)		;not adjustable, no fill-pointer and
					; not user-visibly displaced -p
(defconstant $arh_exp_disp_bit 3)	;explicitly-displaced -p

(def-accessors (lexical-environment) %svref
  ()					; 'lexical-environment
  lexenv.parent-env
  lexenv.functions
  lexenv.variables
  lexenv.fdecls				; function-binding decls, e.g., [NOT]INLINE, FTYPE
  lexenv.vdecls				; variable-binding decls, e.g., SPECIAL, TYPE
  lexenv.mdecls				; misc decls, e.g., OPTIMIZE
  lexenv.lambda				; unique id (e.g., afunc) of containing lambda expression.
  )

(def-accessors (definition-environment) %svref
  ()					; 'definition-environment
  defenv.type				; must be LIST, match lexenv.parent-env
  defenv.functions			; compile-time macros, same structure as lexenv.functions
  defenv.constants			; definition-time constants, shadows lexenv.variables
  defenv.fdecls				; shadows lexenv.fdecls
  defenv.vdecls				; shadows lexenv.vdecls
  defenv.mdecls				; shadows lexenv.mdecls
;;; extended info
  defenv.types				; compile-time deftype info, shadows lexenv.function
  defenv.defined			; functions defined in compilation unit.
  defenv.specials
  defenv.classes                        ; classed defined in compilation unit
  defenv.structrefs                     ; compile-time DEFSTRUCT accessor info
  defenv.structures                     ; compile-time DEFSTRUCT info
  defenv.symbol-macros			; compile-time SYMBOL-MACROS.
)

(def-accessors (var) %svref
  nil                                   ; 'var
  var-name                              ; symbol
  (var-bits var-parent)                 ; fixnum or ptr to parent
  (var-ea  var-expansion)               ; p2 address (or symbol-macro expansion)
  var-decls                             ; list of applicable decls
  var-inittype
  var-binding-info
  var-refs
)

(def-accessors (package) %svref
  pkg.itab
  pkg.etab
  pkg.used
  pkg.used-by
  pkg.names
  pkg.shadowed
  pkg.lock
  )

(defmacro package-deleted-marker ()
  (%unbound-marker))


(def-accessors (fake-stack-frame) %svref
  nil                           ; 'fake-stack-frame
  %fake-stack-frame.sp          ; fixnum. The stack pointer where this frame "should" be
  %fake-stack-frame.next-sp     ; Either sp or another fake-stack-frame
  %fake-stack-frame.fn          ; The current function
  %fake-stack-frame.lr          ; fixnum offset from fn (nil if fn is not functionp)
  %fake-stack-frame.vsp         ; The value stack pointer
  %fake-stack-frame.link        ; next in *fake-stack-frames* list
  )

(def-accessors () svref
  bt.dialog
  bt.youngest
  bt.oldest
  bt.tcr
  bt.restarts
  bt.top-catch
  bt.break-condition
  bt.current
  bt.fake-frames
  bt.db-link
  bt.break-level)

(defconstant bt.sg bt.tcr)
(setf (macro-function 'bt.sg) (macro-function 'bt.tcr))


(def-accessors (lock) %svref
  lock.value
  lock.name)






  
;contents of pkg.itab/pkg.etab.
(defmacro pkgtab-table (htab) `(car (the list ,htab)))
#|
(defmacro pkgtab-hcount (htab) `(car (the list (cdr (the list ,htab)))))                                            (mkint acc)))
(defmacro pkgtab-hlimit (htab) `(cdr (the list (cdr (the list ,htab)))))
|#



(def-accessors (pathname) %svref
  ()                                    ; 'pathname
  %pathname-directory
  %pathname-name
  %pathname-type)

(def-accessors (logical-pathname) %svref
  ()                                    ; 'logical-pathname
  %pathname-directory
  %pathname-name
  %pathname-type  
  %logical-pathname-host
  %logical-pathname-version)

(defmacro %cons-pathname (directory name type)
  `(%istruct 'pathname ,directory ,name ,type))
#|
  `(%gvector $v_istruct 'pathname ,directory ,name ,type))
|#

(defmacro %cons-logical-pathname (directory name type host version)
  `(%istruct 'logical-pathname ,directory ,name ,type ,host ,version))
#|
  `(%gvector $v_istruct 'logical-pathname ,directory ,name ,type ,host ,version))
|#

(def-accessors (restart) %svref
  ()                                    ; 'restart
  %restart-name
  %restart-action
  %restart-report
  %restart-interactive
  %restart-test)

;;; %cons-restart now in level-2.lisp


(def-accessors %svref
  nil                                   ; 'periodic-task
  ptask.state
  ptask.name
  ptask.function
)

;;;;;; CMU type system.



(def-accessors (type-class) %svref
  nil                                   ; 'type-class
  type-class-name                       ; name

  ;; Dyadic type methods.  If the classes of the two types are EQ, then we call
  ;; the SIMPLE-xxx method.  If the classes are not EQ, and either type's class
  ;; has a COMPLEX-xxx method, then we call it.
  ;;
  ;; Although it is undefined which method will get precedence when both types
  ;; have a complex method, the complex method can assume that the second arg
  ;; always is in its class, and the first always is not.  The arguments to
  ;; commutative operations will be swapped if the first argument has a complex
  ;; method.
  ;;
  ;; Since SUBTYPEP is not commutative, we have two complex methods.  the ARG1
  ;; method is only called when the first argument is in its class, and the
  ;; ARG2 method is only called when called when the second type is.  If either
  ;; is specified, both must be.
  type-class-simple-subtypep
  type-class-complex-subtypep-arg1
  type-class-complex-subtypep-arg2
  ;;
  ;; SIMPLE-UNION combines two types of the same class into a single type of
  ;; that class.  If the result is a two-type union, then return NIL.
  ;; VANILLA-UNION returns whichever argument is a supertype of the other, or
  ;; NIL.
  type-class-simple-union
  type-class-complex-union
  ;; The default intersection methods assume that if one type is a subtype of
  ;; the other, then that type is the intersection.
  type-class-simple-intersection
  type-class-complex-intersection
  ;;
  type-class-simple-=
  type-class-complex-=
  type-class-unparse
) 

;; This istruct (and its subtypes) are used to define types.
(def-accessors (ctype) %svref
  nil                                   ; 'ctype or a subtype
  ctype-class-info                       ; a type-class
  ;; True if this type has a fixed number of members, and as such could
  ;; possibly be completely specified in a MEMBER type.  This is used by the
  ;; MEMBER type methods.
  ctype-enumerable
)

;; args-ctype is a subtype of ctype
(def-accessors (args-ctype) %svref
  nil                                   ; 'args-ctype
  nil                                   ; ctype-class-info              
  nil                                   ; ctype-enumerable
  ;; Lists of the type for each required and optional argument.
  args-ctype-required
  args-ctype-optional
  ;;
  ;; The type for the rest arg.  NIL if there is no rest arg.
  args-ctype-rest
  ;; True if keyword arguments are specified.
  args-ctype-keyp
  ;; List of key-info structures describing the keyword arguments.
  args-ctype-keywords
  ;; True if other keywords are allowed.
  args-ctype-allowp
)

(def-accessors (key-info) %svref
  nil                                   ; 'key-info
  key-info-name                         ; Name of &key arg
  key-info-type                         ; type (ctype) of this &key arg
)

;;; VALUES-ctype is a subtype of ARGS-ctype.
(def-accessors (values-ctype) %svref
  nil                                   ; 'values-ctype
  nil                                   ; ctype-class-info           
  nil                                   ; ctype-enumerable
  ;; Lists of the type for each required and optional argument.
  values-ctype-required
  values-ctype-optional
  ;;
  ;; The type for the rest arg.  NIL if there is no rest arg.
  values-ctype-rest
  ;; True if keyword arguments are specified.
  values-ctype-keyp
  ;; List of key-info structures describing the keyword arguments.
  values-ctype-keywords
  ;; True if other keywords are allowed.
  values-ctype-allowp
)

;;; FUNCTION-ctype is a subtype of ARGS-ctype.
(def-accessors (args-ctype) %svref
  nil                                   ; 'function-ctype
  nil                                   ; ctype-class-info           
  nil                                   ; ctype-enumerable
  function-ctype-required               ; args-ctype-required
  function-ctype-optional               ; args-ctype-optional
  function-ctype-rest                   ; args-ctype-rest
  function-ctype-keyp                   ; args-ctype-keyp
  function-ctype-keywords               ; args-ctype-keywords
  function-ctype-allowp                 ; args-ctype-allowp
;; True if the arguments are unrestrictive, i.e. *.
  function-ctype-wild-args
  ;;
  ;; Type describing the return values.  This is a values type
  ;; when multiple values were specified for the return.
  function-ctype-returns
)

;;; The CONSTANT-ctype structure represents a use of the CONSTANT-ARGUMENT "type
;;; specifier", which is only meaningful in function argument type specifiers
;;; used within the compiler.
;;;


(def-accessors (constant-ctype) %svref
  nil                                   ; 'constant-ctype
  nil                                   ; ctype-class-info           
  nil                                   ; ctype-enumerable
  ;; The type which the argument must be a constant instance of for this type
  ;; specifier to win.
  constant-ctype-type
)

;;; The NAMED-ctype is used to represent *, T and NIL.  These types must be
;;; super or sub types of all types, not just classes and * & NIL aren't
;;; classes anyway, so it wouldn't make much sense to make them built-in
;;; classes.
;;;

(def-accessors (named-ctype) %svref
  nil                                   ; 'named-ctype
  nil                                   ; ctype-class-info           
  nil                                   ; ctype-enumerable
  named-ctype-name
)

;;; The Hairy-ctype represents anything too wierd to be described
;;; reasonably or to be useful, such as SATISFIES.  We just remember
;;; the original type spec.
;;;

(def-accessors (hairy-ctype) %svref
  nil                                   ; 'hairy-ctype
  nil                                   ; ctype-class-info           
  nil                                   ; ctype-enumerable
  ;; The type which the argument must be a constant instance of for this type
  ;; specifier to win.
  hairy-ctype-specifier
)

;;; An UNKNOWN-ctype is a type not known to the type system (not yet defined).
;;; We make this distinction since we don't want to complain about types that
;;; are hairy but defined.
;;;

;;; This means that UNKNOWN-ctype is a HAIRY-ctype.
(def-accessors (unknown-ctype) %svref
  nil                                   ; 'unknown-ctype
  nil                                   ; ctype-class-info           
  nil                                   ; ctype-enumerable
  unknown-ctype-specifier
)

;;; CONS-ctype is a subclass of CTYPE
(def-accessors (cons-ctype) %svref
  nil                                   ; 'cons-ctype
  nil                                   ; ctype-class-info
  nil                                   ; ctype-enumerable
  cons-ctype-car-ctype                  ; ctype of the car
  cons-ctype-cdr-ctype                  ; ctype of the cdr
  )

;;; NUMERIC-ctype is a subclass of CTYPE
(def-accessors (numeric-ctype) %svref
  nil                                   ; numeric-ctype
  nil                                   ; ctype-class-info           
  nil                                   ; ctype-enumerable
  ;;
  ;; The kind of numeric type we have.  NIL if not specified (just NUMBER or
  ;; COMPLEX).
  numeric-ctype-class
  ;; Format for a float type.  NIL if not specified or not a float.  Formats
  ;; which don't exist in a given implementation don't appear here.
  numeric-ctype-format
  ;; Is this a complex numeric type?  Null if unknown (only in NUMBER.)
  numeric-ctype-complexp
  ;; The upper and lower bounds on the value.  If null, there is no bound.  If
  ;; a list of a number, the bound is exclusive.  Integer types never have
  ;; exclusive bounds.
  numeric-ctype-low
  numeric-ctype-high
  numeric-ctype-predicate
)

;;; ARRAY-ctype is a subclass of CTYPE.
(def-accessors (array-ctype) %svref
  nil                                   ; 'array-ctype
  nil                                   ; ctype-class-info           
  nil                                   ; ctype-enumerable
  ;;
  ;; The dimensions of the array.  * if unspecified.  If a dimension is
  ;; unspecified, it is *.
  array-ctype-dimensions
  ;;
  ;; Is this not a simple array type?
  array-ctype-complexp
  ;;
  ;; The element type as originally specified.
  array-ctype-element-type
  ;;
  ;; The element type as it is specialized in this implementation.
  array-ctype-specialized-element-type
)

;;; MEMBER-ctype is a direct subclass of CTYPE.
(def-accessors (member-ctype) %svref
  nil                                   ; 'member-ctype
  nil                                   ; ctype-class-info           
  nil                                   ; ctype-enumerable
  ;;
  ;; The things in the set, with no duplications.
  member-ctype-members
)

;;; UNION-ctype is a direct subclass of CTYPE.
(def-accessors (union-ctype) %svref
  nil                                   ; 'union-ctype
  nil                                   ; ctype-class-info           
  nil                                   ; ctype-enumerable
  ;;
  ;; The types in the union.
  union-ctype-types
)

;;; INTERSECTION-ctype is a direct subclass of CTYPE.
(def-accessors (intersection-ctype) %svref
  nil                                   ; 'intersection-ctype
  nil                                   ; ctype-class-info           
  nil                                   ; ctype-enumerable
  ;;
  ;; The types in the intersection
  intersection-ctype-types
)

(def-accessors (negation-ctype) %svref
  nil                                   ; 'negation-ctype
  nil                                   ; ctype-class-info           
  nil                                   ; ctype-enumerable
  ;; The type of what we're not:
  negation-ctype-type
  )
  



;;; It'd be nice to integrate "foreign" types into the type system
(def-accessors (foreign-ctype) %svref
  nil                                   ; 'foreign-ctype
  nil                                   ; ctype-class-info           
  nil                                   ; ctype-enumerable
  foreign-ctype-foreign-type
)
  
;;; Most "real" CLOS objects have one of these in their %class.ctype slot

(def-accessors (class-ctype) %svref
  nil                                   ; 'class-ctype
  nil                                   ; ctype-class-info           
  nil                                   ; ctype-enumerable
  class-ctype-class                     ; backptr to class.
  class-ctype-translation               ; ctype for some built-in-classes.
)



;;;;;;;
;;
;; state for with-package-iterator
;;
(def-accessors %svref
  pkg-iter-step.pkg                     ; package
  pkg-iter-step.type                    ; keyword
  pkg-iter-step.table
  pkg-iter-step.shadowed
  pkg-iter-step.vector
  pkg-iter-step.index)

(def-accessors %svref
  pkg-iter.step                         ; current step
  pkg-iter.remaining-steps              ; steps to be processed
)


;;;;;;;;;;;;;

(defconstant $catch.tag 0)
(defconstant $catch.mvflag (+ $catch.tag 4))
(defconstant $catch.dblink (+ $catch.mvflag 4))
(defconstant $catch.vsp (+ $catch.dblink 4))
(defconstant $catch.regs (+ $catch.vsp 4))
(defconstant $catch.link (+ $catch.regs (* 4 5)))
(defconstant $catch.scgvll (+ $catch.link 4))
(defconstant $catch.cs_area (+ $catch.scgvll 4))
(defconstant $catch.pc (+ $catch.cs_area 4))
(defconstant $catchfsize (+ $catch.pc 4))


;;; Bits in *gc-event-status-bits*
(defconstant $gc-retain-pages-bit 0)
(defconstant $gc-integrity-check-bit 2)
(defconstant $gc-allow-stack-overflows-bit 5)
(defconstant $gc-postgc-pending-bit 26)



;;; Values for the flags arg to %install-periodic-task
(defconstant $ptask_draw-flag 1)       ; set for tasks that do drawing
(defconstant $ptask_event-dispatch-flag 2)      ; set for tasks that do event processing





(defconstant struct.type 0)
(defconstant istruct.type 0)

(def-accessors (readtable) %svref
  ()                                        ; 'readtable
  rdtab.ttab                                ; type table
  rdtab.alist                               ; macro-char alist
  rdtab.case)				    ; gratuitous braindeath

;character types in readtables
(defconstant $cht_ill 0)                ;Illegal char
(defconstant $cht_wsp 1)                ;Whitespace
(defconstant $cht_sesc 4)               ;Single escape (\)
(defconstant $cht_mesc 5)               ;Multiple escape (|)
(defconstant $cht_cnst 6)               ;Atom constituent
(defconstant $cht_tmac 8)               ;Terminating macro
(defconstant $cht_ntmac 9)              ;Non-terminating macro

(defconstant $cht_macbit 3)             ;This bit on in CHT_TMAC and CHT_NTMAC

;;; quantifiers

(defconstant $some 0)
(defconstant $notany 1)
(defconstant $every 2)
(defconstant $notevery 3)

;;; Error string constants.  As accurate as constants.i ...

(defconstant $XVUNBND 1)
(defconstant $XNOCDR 2)
(defconstant $XTMINPS 3)
(defconstant $XNEINPS 4)
(defconstant $XWRNGINP 5)
(defconstant $err-bad-input 5)
(defconstant $XFUNBND 6)
(defconstant $err-fundefined 6)
(defconstant $XNOCAR 7)
(defconstant $xcoerce 8)
(defconstant $xnomem 10)
(defconstant $xnotranslation 12)
(defconstant $XNOTFUN 13)
(defconstant $XNOTsymlam 14)
(defconstant $Xdeclpos 15)
(defconstant $Xsetconstant 16)
(defconstant $Xoddsetq 17)
(defconstant $Xbadsetq 18)
(defconstant $Xnotsym 19)
(defconstant $Xisconstant 20)
(defconstant $Xbadinit 21)
(defconstant $Xsmacspec 22)
(defconstant $X2manyargs 23)
(defconstant $XNolexvar 24)
(defconstant $XNolexfunc 25)
(defconstant $XNolextag 26)
(defconstant $XNolexblock 27)
(defconstant $XNotag 28)
(defconstant $Xduplicatetag 29)
(defconstant $XNoblock 30)
(defconstant $XBadLambdaList 31)
(defconstant $XBadLambda 32)
(defconstant $XNOCTAG 33)
(defconstant $XOBJBadType 34)
(defconstant $XFuncLexMacro 35)
(defconstant $xumrpr 41)
(defconstant $xnotsamevol 42)
(defconstant $xbadfilenamechar 43)
(defconstant $xillwild 44)
(defconstant $xnotfaslortext 45)
(defconstant $xrenamedir 46)
(defconstant $xdirnotfile 47)
(defconstant $xnocopydir 48)
(defconstant $XBADTOK 49)
(defconstant $err-long-pstr 49)
(defconstant $xnocreate 50)
(defconstant $XFLOVFL 64)
(defconstant $XDIVZRO 66)
(defconstant $XFLDZRO 66)
(defconstant $XSTKOVER 75)
(defconstant $XMEMFULL 76)
(defconstant $xarrlimit 77)
(defconstant $err-printer 94)
(defconstant $err-printer-load 95)
(defconstant $err-printer-params 96)
(defconstant $err-printer-start 97)
(defconstant $XFLEXC 98)
(defconstant $xfileof 111)
(defconstant $XARROOB 112)
(defconstant $err-arroob 112)
(defconstant $xunread 113)
(defconstant $xbadmac 114)
(defconstant $XCONST 115)
(defconstant $xillchr 116)
(defconstant $xbadsym 117)
(defconstant $xdoterr 118)
(defconstant $xbadrdx 119)
(defconstant $XNOSPREAD 120)
(defconstant $XFASLVERS 121)
(defconstant $XNOTFASL 122)
(defconstant $xudfcall 123)

(defconstant $xusecX 127)
(defconstant $ximprtcx 128)
(defconstant $xbadnum 129)	 ;Bad arg to #b/#o/#x/#r... 
(defconstant $XNOPKG 130)
(defconstant $xnoesym 131)
(defconstant $XBADFASL 132)
(defconstant $ximprtc 133)
(defconstant $xunintc 134)
(defconstant $XSYMACC 135)
(defconstant $XEXPRTC 136)
(defconstant $xusec 137)
(defconstant $xduppkg 138)
(defconstant $xrmactx 139)
(defconstant $xnordisp 140)
(defconstant $xrdnoarg 141)
(defconstant $xrdndarg 142)
(defconstant $xmacrdx 143)
(defconstant $xduprdlbl 144)
(defconstant $xnordlbl 145)
(defconstant $xrdfont 146)
(defconstant $xrdname 147)
(defconstant $XNDIMS 148)
(defconstant $err-disp-size 149)
(defconstant $XNARGS 150)
(defconstant $xdifdim 151)
(defconstant $xkeyconflict 152)
(defconstant $XBADKEYS 153)
(defconstant $xtoofew 154)
(defconstant $xtoomany 155)
(defconstant $XWRONGTYPE 157)
(defconstant $XBADSTRUCT 158)
(defconstant $XSTRUCTBOUNDS 159)
(defconstant $XCALLNOTLAMBDA 160)
(defconstant $XTEMPFLT 161)
(defconstant $xrdfeature 163)
(defconstant $err-no-file 164)
(defconstant $err-bad-named-arg 165)
(defconstant $err-bad-named-arg-2 166)
(defconstant $XCALLTOOMANY 167)
(defconstant $XCALLTOOFEW 168)
(defconstant $XCALLNOMATCH 169)
(defconstant $XIMPROPERLIST 170)
(defconstant $XNOFILLPTR 171)
(defconstant $XMALADJUST 172)
(defconstant $XACCESSNTH 173)
(defconstant $XNOTELT 174)
(defconstant $XSGEXHAUSTED 175)
(defconstant $XSGNARGS 176)
(defconstant $XTOOMANYVALUES 177)

(defconstant $cons-area.gspace-start 0)
(defconstant $cons-area.gspace-end 4)
(defconstant $cons-area.ispace-start 8)
(defconstant $cons-area.ispace-end 12)
(defconstant $cons-area.pgc-count 16)
(defconstant $cons-area.pgc-time 20)
(defconstant $cons-area.total 24)


;; Values returned by %number-check.

(defconstant $Num1Dfloat 0)
(defconstant $Num1Int 2)
(defconstant $Num1Sfloat 4)
(defconstant $Num1Ratio 6)
(defconstant $Num1CR 8)
(defconstant $Num1CF 10)
(defconstant $Num1CS 12)

(defconstant %numeric-type-names-alist% 
  `((double-float . ,$Num1Dfloat)
    (integer . ,$Num1Int)
    (short-float . ,$Num1Sfloat)
    (ratio . ,$Num1Ratio)
    ((complex rational) . ,$Num1CR)
    ((complex double-float) . ,$Num1CF)
    ((complex short-float) . ,$Num1CS)))
  
(defmacro numeric-dispatch (numform &body cases)
  (flet ((numtype (name)
           (if (memq name '(t otherwise))
             name
             (dolist (pair %numeric-type-names-alist% (error "Unknown numeric type name ~s" name))
               (when (subtypep name (car pair)) (return (cdr pair)))))))
    (flet ((numify (case)
             (destructuring-bind (types &body body) case
               (if (atom types)
                 `(,(numtype types) ,@body)
                 `(,(mapcar #'numtype types) ,@body)))))
      `(case (%number-check ,numform)
         ,@(mapcar #'numify cases)))))

(def-accessors (random-state) %svref
  ()
  random.seed-1
  random.seed-2)

;;; IEEE-floating-point constants.  Note that 68K MCL SHORT-FLOATs aren't IEEE SINGLE-FLOATS;
;;; some bits are stolen from the exponent of an IEEE single and used for tagging.

(defconstant IEEE-single-float-bias 126)
(defconstant IEEE-single-float-exponent-offset 23)
(defconstant IEEE-single-float-exponent-width 8)
(defconstant IEEE-single-float-mantissa-offset 0)
(defconstant IEEE-single-float-mantissa-width 23)
(defconstant IEEE-single-float-hidden-bit 23)
(defconstant IEEE-single-float-signalling-NAN-bit 22)
(defconstant IEEE-single-float-normal-exponent-min 1)
(defconstant IEEE-single-float-normal-exponent-max 254)
(defconstant IEEE-single-float-digits (1+ IEEE-single-float-mantissa-width))

;;; Double-floats are IEEE DOUBLE-FLOATs in both MCL implementations.

(defconstant IEEE-double-float-bias 1022)
(defconstant IEEE-double-float-exponent-offset 52)
(defconstant IEEE-double-float-exponent-width 11)
(defconstant IEEE-double-float-mantissa-offset 0)
(defconstant IEEE-double-float-mantissa-width 52)
(defconstant IEEE-double-float-hidden-bit 52)
(defconstant IEEE-double-float-signalling-NAN-bit 51)
(defconstant IEEE-double-float-normal-exponent-min 1)
(defconstant IEEE-double-float-normal-exponent-max 2046)
(defconstant IEEE-double-float-digits (1+ IEEE-double-float-mantissa-width))




(def-accessors (ptaskstate) %svref
  nil                                   ;ptaskstate
  ptaskstate.nexttick
  ptaskstate.interval
  ptaskstate.privatedata
  ptaskstate.flags)






;;;;;; clos instance and class layout.

;;; All standard-instances (classes, instances other than funcallable
;;; instances) consist of a vector of slot values and a pointer to the
;;; class wrapper.
(def-accessors (instance) %svref
  instance.hash				; a fixnum for EQ-based hashing
  instance.class-wrapper
  instance.slots			; a slot-vector
)
;;; Doing this via %SLOT-REF traps if the slot is unbound
(defmacro standard-instance-instance-location-access (instance location)
  `(%slot-ref (instance-slots ,instance) ,location))

;;; Get the "raw" contents of the slot, even if it's %SLOT-UNBOUND-MARKER.
(defmacro %standard-instance-instance-location-access (instance location)
  `(%svref (instance-slots ,instance) ,location))

(defmacro set-standard-instance-instance-location-access (instance location new)
  `(setf (%svref (instance-slots ,instance) ,location) ,new))

(defsetf standard-instance-instance-location-access
    set-standard-instance-instance-location-access)

(defmacro standard-generic-function-instance-location-access (sgf location)
  `(%slot-ref (gf.slots ,sgf) ,location))

(defmacro %standard-generic-function-instance-location-access (sgf location)
  `(%svref (gf.slots ,sgf) ,location))

(defmacro set-standard-generic-function-instance-location-access (sgf location new)
  `(setf (%svref (gf.slots ,sgf) ,location) ,new))

(defsetf standard-generic-function-instance-location-access
    set-standard-generic-function-instance-location-access)

;;; Slot vectors contain the instance they "belong" to (or NIL) in
;;; their 0th element, and the instance's slots in elements 1 .. n.

(def-accessors (slot-vector) %svref
  slot-vector.instance
  )

(def-accessors (class-wrapper) %svref
  nil                                   ; 'class-wrapper
  %wrapper-hash-index                   ; for generic-function dispatch tables
  %wrapper-class                        ; the class itself
  %wrapper-instance-slots               ; vector of instance slot names
  %wrapper-class-slots                  ; alist of (name . value-cell) pairs
  %wrapper-slot-id->slotd               ; map slot-id to slotd, or NIL
  %wrapper-slot-id-map                  ; (vector (mod nslots) next-slot-id-index)
  %wrapper-slot-definition-table        ; vector of nil || slot-definitions
  %wrapper-slot-id-value                ; "fast" SLOT-VALUE function
  %wrapper-set-slot-id-value            ; "fast" (SETF SLOT-VALUE) function
)

;; Use the wrapper-class-slots for info on obsolete & forwarded instances
;; Note: none of this xx-forwarding-xx or xx-forwarded-xx is valid unless
;; (%wrapper-instance-slots ...) is 0.
(defmacro %wrapper-forwarding-info (instance)
  `(%wrapper-class-slots ,instance))

(defmacro %forwarding-instance-slots (info)
  `(%car ,info))
(defmacro %forwarding-class-slots (info)
  `(%cdr ,info))


(defmacro %wrapper-forwarded-instance-slots (instance)
  `(%forwarding-instance-slots (%wrapper-forwarding-info ,instance)))
(defmacro %wrapper-forwarded-class-slots (instance)
  `(%forwarding-class-slots (%wrapper-forwarding-info ,instance)))


(defmacro %cons-forwarding-info (instance-slots class-slots)
  `(cons ,instance-slots ,class-slots))


(defmacro %cons-wrapper (class &optional 
                               (hash-index '(new-class-wrapper-hash-index)))
  `(%istruct 'class-wrapper ,hash-index ,class nil nil #'slot-id-lookup-no-slots nil nil #'%slot-id-ref-missing #'%slot-id-set-missing))


(defmacro %instance-class (instance)
  `(%wrapper-class (instance.class-wrapper ,instance)))

(def-accessors standard-instance-instance-location-access ;A specializer
    nil					; backptr
  specializer.direct-methods
)

(def-accessors (class) standard-instance-instance-location-access ;Slots of any class
  nil                                   ; backptr
  %class.direct-methods			; aka specializer.direct-methods
  %class.prototype			; prototype instance
  %class.name
  %class.cpl                            ; class-precedence-list
  %class.own-wrapper                    ; own wrapper (or nil)
  %class.local-supers                   ; class-direct-superclasses
  %class.subclasses                     ; class-direct-subclasses
  %class.dependents			; arbitrary dependents
  %class.ctype
)


(def-accessors () standard-instance-instance-location-access ; any standard class
  nil                                   ; slot-vector backptr
  nil                                   ; usual class stuff: direct-methods,
  nil					;   prototype,
  nil					;   name,
  nil					;   cpl,
  nil					;   own-wrapper,
  nil					;   local-supers,
  nil					;   subclasses,
  nil					;   dependents,
  nil					;   ctype.
  %class.direct-slots                   ; local slots
  %class.slots                          ; all slots
  %class.kernel-p			; true if a non-redefinable class
  %class.local-default-initargs         ; local default initargs alist
  %class.default-initargs               ; all default initargs if initialized.
  %class.alist                          ; other stuff about the class.
  %class.make-instance-initargs         ; (vector of) valid initargs to make-instance
  %class.reinit-initargs                ; valid initargs to reinitialize-instance
  %class.redefined-initargs             ; valid initargs to update-instance-for-redefined-class
  %class.changed-initargs               ; valid initargs to update-instance-for-changed-class
  )





(defmacro %instance-vector (wrapper &rest slots)
  (let ((instance (gensym))
	(slots-vector (gensym)))
    `(let* ((,instance (gvector :instance 0 ,wrapper nil))
	    (,slots-vector (gvector :slot-vector ,instance ,@slots)))
       (setf (instance.slots ,instance) ,slots-vector
	     (instance.hash ,instance) (strip-tag-to-fixnum ,instance))
       ,instance)))
 
(defmacro %cons-built-in-class (name)
  `(%instance-vector *built-in-class-wrapper* nil nil ,name nil nil nil nil nil nil))


(defmacro %cons-standard-class (name &optional
                                     (metaclass-wrapper '*standard-class-wrapper*))
  `(%instance-vector  ,metaclass-wrapper
                      nil nil ,name nil nil nil nil nil nil nil nil
                      nil nil nil nil nil nil nil nil)

)

(def-accessors () standard-instance-instance-location-access
  nil					; backptr
  standard-slot-definition.name
  standard-slot-definition.type
  standard-slot-definition.initfunction
  standard-slot-definition.initform
  standard-slot-definition.initargs
  standard-slot-definition.allocation
  standard-slot-definition.documentation
  standard-slot-definition.class
  )

(def-accessors () standard-instance-instance-location-access
  nil
  standard-effective-slot-definition.name
  standard-effective-slot-definition.type
  standard-effective-slot-definition.initfunction
  standard-effective-slot-definition.initform
  standard-effective-slot-definition.initargs
  standard-effective-slot-definition.allocation
  standard-effective-slot-definition.documentation
  standard-effective-slot-definition.class
  standard-effective-slot-definition.location
  standard-effective-slot-definition.slot-id
  standard-effective-slot-definition.type-predicate
  )


(def-accessors () standard-instance-instance-location-access
  nil
  standard-direct-slot-definition.name
  standard-direct-slot-definition.type
  standard-direct-slot-definition.initfunction
  standard-direct-slot-definition.initform
  standard-direct-slot-definition.initargs
  standard-direct-slot-definition.allocation
  standard-direct-slot-definition.documentation
  standard-direct-slot-definition.class
  standard-direct-slot-definition.readers
  standard-direct-slot-definition.writers  
  )

;; Methods
(defmacro %cons-method (name qualifiers specializers function &optional 
                             (class '*standard-method-class*))
  `(%instance-vector 
    (%class.own-wrapper ,class)
    ,qualifiers
    ,specializers
    ,function
    nil
    ,name))


(def-accessors standard-instance-instance-location-access ; method
  nil                                   ; backptr
  %method.qualifiers
  %method.specializers
  %method.function
  %method.gf
  %method.name
  %method.lambda-list)

;;; Painful, but seems to be necessary.
(def-accessors standard-instance-instance-location-access ; standard-accessor-method
  nil                                   ; backptr
  nil					;%method.qualifiers
  nil					;%method.specializers
  nil					;%method.function
  nil					;%method.gf
  nil					;%method.name
  nil					;%method.lambda-list
  %accessor-method.slot-definition)





;; Generic Function Dispatch tables.
;; These accessors are at the beginning of the table.
;; rest of the table is alternating wrappers & combined-methods.

(def-accessors %svref
    %gf-dispatch-table-methods		; List of methods
    %gf-dispatch-table-precedence-list	; List of argument numbers in precedence order
    %gf-dispatch-table-keyvect          ; keyword vector, set by E-G-F.
    %gf-dispatch-table-argnum		; argument number
    %gf-dispatch-table-gf		; back pointer to gf - NEW
    %gf-dispatch-table-mask		; mask for rest of table
    %gf-dispatch-table-first-data)	; offset to first data.  Must follow mask.
  
(defmacro %gf-dispatch-table-size (dt)
  `(%i- (uvsize ,dt) ,(+ 2 %gf-dispatch-table-first-data)))

(defmacro %gf-dispatch-table-ref (table index)
  `(svref ,table (%i+ ,index %gf-dispatch-table-first-data)))

(defmacro %cons-gf-dispatch-table (size)
  `(make-array (%i+ ,size ,(%i+ 2 %gf-dispatch-table-first-data))
               :initial-element nil))


;;; method-combination info
(def-accessors svref
  mci.class                             ; short-method-combination or long-method-combination
  mci.options                           ; short-form-options or long-form function
  mci.instances                         ; a population of instances
  mci.gfs                               ; a population of generic-functions
  )

(defmacro %cons-mci (&optional class options)
  `(vector ,class ,options (%cons-population nil) (%cons-population nil)))

;;; slot accessor info for primary classes
(def-accessors %svref
  %slot-accessor-info.class
  (%slot-accessor-info.accessor %slot-accessor-info.slot-name)
  %slot-accessor-info.offset
  )

(defmacro %cons-slot-accessor-info (class accessor-or-slot-name &optional offset)
  `(vector ,class ,accessor-or-slot-name ,offset))

(def-accessors (combined-method) %svref
  combined-method.code-vector		; trampoline code vector
  combined-method.thing			; arbitrary arg to dcode
  combined-method.dcode			; discriminator function
  combined-method.gf			; gf
  combined-method.bits			; lfun-bits
  )
;;; The structure of a generic-function object (funcallable instance).
(def-accessors (generic-function) %svref
  gf.code-vector			; trampoline code-vector
  gf.instance.class-wrapper		; instance class-wrapper
  gf.slots				; slots vector
  gf.dispatch-table			; effective-method cache
  gf.dcode				; discriminating code
  gf.hash				; hashing identity
  gf.bits				;
  )

;;; The slots of STANDARD-GENERIC-FUNCTION.
(def-accessors (standard-generic-function) standard-generic-function-instance-location-access
  nil					; backptr
  sgf.name				; generic-function-name
  sgf.method-combination		; generic-function-method-combination
  sgf.method-class			; generic-function-method-class
  sgf.methods				; generic-function-methods
  sgf.decls				; generic-function-declarations
  sgf.%lambda-list                      ; explicit lambda-list
  sgf.dependents			; dependents for MAP-DEPENDENTS et al.
  )

(def-accessors (slot-id) %svref
  nil                                   ;'slot-id
  slot-id.name                          ; slot name (symbol)
  slot-id.index                         ; index (integer)
  )

(def-accessors (foreign-object-domain) %svref
  nil					; foreign-object-domain
  foreign-object-domain-index		; 1..n
  foreign-object-domain-name		;
  foreign-object-domain-recognize	; function: is object one of ours ?
  foreign-object-domain-class-of	; function: returns class of object
  foreign-object-domain-classp		; function: true if object is a class
  foreign-object-domain-instance-class-wrapper ; function: returns wrapper of object's class
  foreign-object-domain-class-own-wrapper ; function: returns class own wrapper if class
  foreign-object-domain-slots-vector	; returns slots vector of object or nil
  )

;;; Hash table accessors.
(def-accessors (hash-table) %svref
    nil                                 ; 'HASH-TABLE
    nhash.rehashF                       ; function: rehashes if necessary
    nhash.keytransF                     ; transform key into (values primary addressp)
    nhash.compareF                      ; comparison function: 0 -> eq, -1 ->eql, else function
    nhash.rehash-bits                   ; bitset (array (unsigned-byte 32)) for rehash
    nhash.vector                        ; N <key,value> pairs; n relatively prime to & larger than all secondary keys
    nhash.lock                          ; fixnum: bits for grow and rehash
    nhash.count                         ; Number of entries
    nhash.owner                         ; tcr of "owning" thread, else NIL.
    nhash.fixnum                        ; fwdnum kernel-global
    nhash.gc-count                      ; gc-count kernel-global
    nhash.grow-threshold                ; Max # entries before grow
    nhash.rehash-ratio                  ; inverted rehash-threshold
    nhash.rehash-size			; rehash-size from user
    nhash.puthash-count                 ; number of times table has been rehashed or grown
    nhash.exclusion-lock                ; read-write lock for access
    nhash.rehash-lock                   ; exclusive lock for rehash
    nhash.iterator                      ; current hash-table iterator
    nhash.address-based                 ; hashes based on address
    nhash.find                          ; function: find vector-index
    nhash.find-new                      ; function: find vector-index on put
    )

(def-accessors (lock-acquisition) %svref
  nil                                   ; 'lock-acquisition
  lock-acquisition.status
  )

(defmacro make-lock-acquisition ()
  `(%istruct 'lock-acquisition nil))

(def-accessors (semaphore-notification) %svref
  nil                                   ; 'semaphore-notification
  semaphore-notification.status
  )

(defmacro make-semaphore-notification ()
  `(%istruct 'semaphore-notification nil))

(provide "LISPEQU")

;;; End of lispequ.lisp
