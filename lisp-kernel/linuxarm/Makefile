#
#   Copyright (C) 2010 Clozure Associates
#   This file is part of Clozure CL.  
#
#   Clozure CL is licensed under the terms of the Lisp Lesser GNU Public
#   License , known as the LLGPL and distributed with Clozure CL as the
#   file "LICENSE".  The LLGPL consists of a preamble and the LGPL,
#   which is distributed with Clozure CL as the file "LGPL".  Where these
#   conflict, the preamble takes precedence.  
#
#   Clozure CL is referenced in the preamble as the "LIBRARY."
#
#   The LLGPL is also available online at
#   http://opensource.franz.com/preamble.html

SVN_REVISION := "$(shell svnversion || echo unknown)"

VPATH = ../
RM = /bin/rm
# Versions of GNU as >= 2.9.1 all seem to work
# AS = gas-2.9.1
AS = as
M4 = m4
ASFLAGS = -mfpu=vfp -march=armv6 -mfloat-abi=$(FLOAT_ABI)
M4FLAGS = -DLINUX -DARM
CDEFINES = -DLINUX -DARM -D_REENTRANT -D_GNU_SOURCE -DSVN_REVISION=$(SVN_REVISION)
CDEBUG = -g
COPT = -O2
# Once in a while, -Wformat says something useful.  The odds are against that,
# however.
WFORMAT = -Wno-format
PLATFORM_H = platform-linuxarm.h
include float_abi.mk

# If the linker supports a "--hash-style=" option, use traditional
# Sysv hash tables.  (If it doesn't support that option, assume
# that traditional hash tables will be used by default.)
ld_has_hash_style = $(shell $(LD) --help | grep "hash-style=")
ifeq ($(ld_has_hash_style),)
HASH_STYLE=
else
HASH_STYLE="-Wl,--hash-style=sysv"
endif


# Likewise, some versions of GAS may need a "-a32" flag, to force the

# output file to be 32-bit compatible.

A32 = $(shell ($(AS) --help -v 2>&1 | grep -q -e "-a32") && /bin/echo "-a32")

.s.o:
	$(M4) $(M4FLAGS) -I../ $< | $(AS) $(A32) $(ASFLAGS) -o $@
.c.o:
	$(CC) -include ../$(PLATFORM_H) -c $< $(CDEFINES) $(CDEBUG) $(COPT) -marm -march=armv6 -mfloat-abi=$(FLOAT_ABI) $(WFORMAT)  -o $@

SPOBJ = pad.o  arm-spentry.o
ASMOBJ = arm-asmutils.o imports.o

COBJ  = pmcl-kernel.o gc-common.o arm-gc.o bits.o  arm-exceptions.o \
	image.o thread_manager.o lisp-debug.o memory.o unix-calls.o

DEBUGOBJ = lispdcmd.o plprint.o plsym.o albt.o arm_print.o
KERNELOBJ= $(COBJ) arm-asmutils.o  imports.o

SPINC =	lisp.s m4macros.m4 arm-constants.s arm-macros.s errors.s arm-uuo.s \
	lisp_globals.s

CHEADERS = area.h bits.h arm-constants.h lisp-errors.h gc.h lisp.h \
	lisp-exceptions.h lisp_globals.h macros.h memprotect.h image.h \
	threads.h arm-exceptions.h $(PLATFORM_H)

# Subprims linked into the kernel ?
# Yes:

KSPOBJ = $(SPOBJ)
all:	../../armcl


# No:

# KSPOBJ=
# all:	../../armcl ../../subprims.so

OSLIBS = -ldl -lm -lpthread -lrt


../../armcl:	$(KSPOBJ) $(KERNELOBJ) $(DEBUGOBJ)
	$(CC)  $(CDEBUG)  -Wl,--export-dynamic $(HASH_STYLE) -mfloat-abi=$(FLOAT_ABI) -o $@ -T ./armlinux.x $(KSPOBJ) $(KERNELOBJ) $(DEBUGOBJ) -Wl,--no-as-needed $(OSLIBS)


$(SPOBJ): $(SPINC)
$(ASMOBJ): $(SPINC)
$(COBJ): $(CHEADERS)
$(DEBUGOBJ): $(CHEADERS) lispdcmd.h


cclean:
	$(RM) -f $(KERNELOBJ) $(DEBUGOBJ) ../../armcl

clean:	cclean
	$(RM) -f $(SPOBJ)

strip:	../../armcl
	strip -g ../../armcl
