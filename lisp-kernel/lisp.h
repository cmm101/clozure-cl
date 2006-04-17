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

#ifndef __lisp__
#define __lisp__



#include "lisptypes.h"

#ifdef PPC
#include "ppc-constants.h"
#endif
#ifdef X86
#include "x86-constants.h"
#endif
#include "macros.h"

Boolean use_mach_exception_handling;
Boolean running_under_rosetta;

int page_size, log2_page_size;

static inline unsigned long
_align_to_power_of_2(unsigned long n, unsigned power)
{
  unsigned long align = (1<<power) -1;

  return (n+align) & ~align;
}

#define align_to_power_of_2(n,p) _align_to_power_of_2(((unsigned long)(n)),p)

static inline unsigned long
_truncate_to_power_of_2(unsigned long n, unsigned power)
{
  return n & ~((1<<power) -1);
}

#define truncate_to_power_of_2(n,p) _truncate_to_power_of_2((unsigned long)(n),p)

LispObj start_lisp(TCR*, LispObj);

#include "kernel-globals.h"
#endif

#define PLATFORM_WORD_SIZE_32 0
#define PLATFORM_WORD_SIZE_64 64
#define PLATFORM_CPU_PPC (0<<3)
#define PLATFORM_CPU_SPARC (1<<3)
#define PLATFORM_CPU_X86 (2<<3)
#define PLATFORM_OS_VXWORKS 0
#define PLATFORM_OS_LINUX 1
#define PLATFORM_OS_SOLARIS 2
#define PLATFORM_OS_DARWIN 3
#define PLATFORM_OS_FREEBSD 4

#ifdef LINUX
#define PLATFORM_OS PLATFORM_OS_LINUX
#endif

#ifdef DARWIN
#define PLATFORM_OS PLATFORM_OS_DARWIN
#endif

#ifdef FREEBSD
#define PLATFORM_OS PLATFORM_OS_FREEBSD
#endif

#ifdef SOLARIS
#define PLATFORM_OS PLATFORM_OS_SOLARIS
#endif

#ifdef PPC
#define PLATFORM_CPU PLATFORM_CPU_PPC
#endif

#ifdef X86
#define PLATFORM_CPU PLATFORM_CPU_X86
#endif

#if (WORD_SIZE == 32)
#define PLATFORM_WORD_SIZE PLATFORM_WORD_SIZE_32
#endif

#if (WORD_SIZE == 64)
#define PLATFORM_WORD_SIZE PLATFORM_WORD_SIZE_64
#endif

#define PLATFORM (PLATFORM_OS|PLATFORM_CPU|PLATFORM_WORD_SIZE)

#ifdef X8664
#define USE_SIGALTSTACK
#endif

