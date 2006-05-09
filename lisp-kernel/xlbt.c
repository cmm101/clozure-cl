/*
   Copyright (C) 2005 Clozure Associates
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

#include "lispdcmd.h"
#include <stdio.h>

const char *
foreign_name_and_offset(void *frame, unsigned *delta)
{
}


void
print_lisp_frame(lisp_frame *frame)
{
  LispObj pc = frame->tra, fun;
  int delta = 0;

  if (pc == lisp_global(RET1VALN)) {
    pc = frame->xtra;
  }
  if (tag_of(pc) == tag_tra) {
    fun = pc - (((unsigned *)pc)[-1]);
    if (fulltag_of(fun) == fulltag_function) {
      delta = pc - fun;
      Dprintf("(#x%016lX) #x%016lX : %s + %d", frame, pc, print_lisp_object(fun), delta);
      return;
    }
  }
  if (pc == 0) {
    fun = ((xcf *)frame)->nominal_function;
    Dprintf("(#x%016lX) #x%016lX : %s + ??", frame, pc, print_lisp_object(fun));
    return;
  }
}

Boolean
lisp_frame_p(lisp_frame *f)
{
  LispObj fun, ra;
  unsigned offset;

  if (f) {
    ra = f->tra;
    if (ra == lisp_global(RET1VALN)) {
      ra = f->xtra;
    }
    if (tag_of(ra) == tag_tra) {
      offset = (((unsigned *)ra)[-1]);
      if (offset == 0) {
	return true;
      } else {
	fun = ra - (((unsigned *)ra)[-1]);
	if (fulltag_of(fun) == fulltag_function) {
	  return true;
	}
      }
    } else if ((ra == lisp_global(LEXPR_RETURN)) ||
	       (ra == lisp_global(LEXPR_RETURN1V))) {
      return true;
    } else if (ra == 0) {
      return true;
    }
  }
  return false;
}

void
walk_stack_frames(lisp_frame *start, lisp_frame *end) 
{
  lisp_frame *next;
  Dprintf("\n");
  while (start < end) {

    if (lisp_frame_p(start)) {
      print_lisp_frame(start);
    } else {
      if (start->backlink) {
        fprintf(stderr, "Bogus  frame %lx\n", start);
      }
      return;
    }
    
    next = start->backlink;
    if (next == 0) {
      next = end;
    }
    if (next < start) {
      fprintf(stderr, "Bad frame! (%x < %x)\n", next, start);
      break;
    }
    start = next;
  }
}

char *
interrupt_level_description(TCR *tcr)
{
  signed_natural level = (signed_natural) TCR_INTERRUPT_LEVEL(tcr);
  if (level < 0) {
    if (tcr->interrupt_pending) {
      return "disabled(pending)";
    } else {
      return "disabled";
    }
  } else {
    return "enabled";
  }
}

void
plbt_sp(LispObj currentRBP)
{
  area *vs_area, *cs_area;
  
{
    TCR *tcr = (TCR *)get_tcr(true);
    char *ilevel = interrupt_level_description(tcr);
    vs_area = tcr->vs_area;
    cs_area = tcr->cs_area;
    if ((((LispObj) ptr_to_lispobj(vs_area->low)) > currentRBP) ||
        (((LispObj) ptr_to_lispobj(vs_area->high)) < currentRBP)) {
      Dprintf("\nFramepointer [#x%lX] in unknown area.", currentRBP);
    } else {
      fprintf(stderr, "current thread: tcr = 0x%lx, native thread ID = 0x%lx, interrupts %s\n", tcr, tcr->native_thread_id, ilevel);
      walk_stack_frames((lisp_frame *) ptr_from_lispobj(currentRBP), (lisp_frame *) (vs_area->high));
      /*      walk_other_areas();*/
    }
  } 
}


void
plbt(ExceptionInformation *xp)
{
  plbt_sp(xpGPR(xp,Irbp));
}
