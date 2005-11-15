/*
   Copyright (C) 1994-2001 Digitool, Inc
   This file is part of OpenMCL.  

   OpenMCL is licensed under the terms of the Lisp Lesser GNU Public
   License , known as the LLGPL and distributed with OpenMCL as the
   file "LICENSE".  The LLGPL consists of a preamble and the LGPL,
   which is distributed with OpenMCL as the file "LGPL".  Where these
   conflict, the preamble takes precedence.  

   OpenMCL is referenced in the preamble as the "LIBRARY."

   The LLGPL is also available online at
   http://opensource.franz.com/preamble.html
*/

#ifndef __lisp_exceptions_h__
#define __lisp_exceptions_h__ 1


#include <stdlib.h>
#include "memprotect.h"
#include "gc.h"

typedef enum {
  kDebugger,
  kContinue,
  kExit
} ErrAction;



void
zero_page(BytePtr);

void
zero_heap_segment(BytePtr);

extern protected_area_ptr AllProtectedAreas;

protected_area_ptr find_protected_area(BytePtr);

OSStatus
lisp_Debugger(ExceptionInformation *, siginfo_t *, int, char *, ...);

OSStatus
handle_protection_violation(ExceptionInformation *, siginfo_t *);

protected_area_ptr 
new_protected_area(BytePtr, BytePtr, lisp_protection_kind, natural, Boolean);

void
unprotect_area_prefix(protected_area_ptr, size_t);

void
protect_area_prefix(protected_area_ptr, size_t);

void
protect_area(protected_area_ptr);


Boolean
resize_dynamic_heap(BytePtr, natural);

OSStatus
PMCL_exception_handler(int, ExceptionInformation *, TCR *, siginfo_t *);

TCR*
get_tcr(Boolean);

ErrAction
error_action( void );

void
install_pmcl_exception_handlers();

void
unprotect_all_areas(void);

void
exception_cleanup(void);

void
exception_init();


#define debug_entry_exception 0
#define debug_entry_bug -1
#define debug_entry_dbg -2

#define ALLOW_EXCEPTIONS(context) \
  pthread_sigmask(SIG_SETMASK, &context->uc_sigmask, NULL);


void
Fatal(StringPtr, StringPtr);


Ptr
allocate(natural);

Ptr
zalloc(natural);

void
deallocate(Ptr);

void 
pc_luser_xp(ExceptionInformation *, TCR *);


void
non_fatal_error( char * );

void Bug(ExceptionInformation *, const char *format_string, ...);
int gc_from_xp(ExceptionInformation *);
int purify_from_xp(ExceptionInformation *);
int impurify_from_xp(ExceptionInformation *);


void
adjust_exception_pc(ExceptionInformation *, int);

size_t
symbol_name( unsigned, char *, size_t );


size_t
exception_fn_name( ExceptionInformation *, int, char *, size_t );


#ifdef PPC
#include "ppc-exceptions.h"
#endif

#ifdef X86
#include "x86-exceptions.h"
#endif


#endif /* __lisp_exceptions_h__ */

