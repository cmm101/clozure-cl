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

#include "lisp.h"
#include "lisp-exceptions.h"
#include "lisp_globals.h"
#include "Threads.h"
#include <ctype.h>
#include <stdio.h>
#include <stddef.h>
#include <string.h>
#include <stdarg.h>
#include <errno.h>
#include <stdio.h>
#ifdef LINUX
#include <strings.h>
#include <sys/mman.h>
#include <fpu_control.h>
#include <linux/prctl.h>
#endif
#ifdef DARWIN
#include <sysexits.h>
#endif
#include <sys/syslog.h>


int
page_size = 4096;

int
log2_page_size = 12;


void
update_bytes_allocated(TCR* tcr, void *cur_allocptr)
{
  BytePtr 
    last = (BytePtr) tcr->last_allocptr, 
    current = (BytePtr) cur_allocptr;
  if (last && (tcr->save_allocbase != ((void *)VOID_ALLOCPTR))) {
    tcr->bytes_allocated += last-current;
  }
  tcr->last_allocptr = 0;
}



//  This doesn't GC; it returns true if it made enough room, false
//  otherwise.
//  If "extend" is true, it can try to extend the dynamic area to
//  satisfy the request.


Boolean
new_heap_segment(ExceptionInformation *xp, natural need, Boolean extend, TCR *tcr)
{
  area *a;
  natural newlimit, oldlimit;
  natural log2_allocation_quantum = tcr->log2_allocation_quantum;

  a  = active_dynamic_area;
  oldlimit = (natural) a->active;
  newlimit = (align_to_power_of_2(oldlimit, log2_allocation_quantum) +
	      align_to_power_of_2(need, log2_allocation_quantum));
  if (newlimit > (natural) (a->high)) {
    if (extend) {
      if (! resize_dynamic_heap(a->active, (newlimit-oldlimit)+lisp_heap_gc_threshold)) {
        return false;
      }
    } else {
      return false;
    }
  }
  a->active = (BytePtr) newlimit;
  tcr->last_allocptr = (void *)newlimit;
  tcr->save_allocptr = (void *)newlimit;
  xpGPR(xp,Iallocptr) = (LispObj) newlimit;
  tcr->save_allocbase = (void *) oldlimit;

  while (HeapHighWaterMark < (BytePtr)newlimit) {
    zero_page(HeapHighWaterMark);
    HeapHighWaterMark+=page_size;
  }
  return true;
}

Boolean
allocate_object(ExceptionInformation *xp,
                natural bytes_needed, 
                signed_natural disp_from_allocptr,
		TCR *tcr)
{
  area *a = active_dynamic_area;

  /* Maybe do an EGC */
  if (a->older && lisp_global(OLDEST_EPHEMERAL)) {
    if (((a->active)-(a->low)) >= a->threshold) {
      gc_from_xp(xp, 0L);
    }
  }

  /* Life is pretty simple if we can simply grab a segment
     without extending the heap.
  */
  if (new_heap_segment(xp, bytes_needed, false, tcr)) {
    xpGPR(xp, Iallocptr) -= disp_from_allocptr;
    tcr->save_allocptr = (void *) (xpGPR(xp, Iallocptr));
    return true;
  }
  
  /* It doesn't make sense to try a full GC if the object
     we're trying to allocate is larger than everything
     allocated so far.
  */
  if ((lisp_global(HEAP_END)-lisp_global(HEAP_START)) > bytes_needed) {
    untenure_from_area(tenured_area); /* force a full GC */
    gc_from_xp(xp, 0L);
  }
  
  /* Try again, growing the heap if necessary */
  if (new_heap_segment(xp, bytes_needed, true, tcr)) {
    xpGPR(xp, Iallocptr) -= disp_from_allocptr;
    tcr->save_allocptr = (void *) (xpGPR(xp, Iallocptr));
    return true;
  }
  
  return false;
}

natural gc_deferred = 0, full_gc_deferred = 0;

Boolean
handle_gc_trap(ExceptionInformation *xp, TCR *tcr)
{
  LispObj 
    selector = xpGPR(xp,Iimm0), 
    arg = xpGPR(xp,Iimm1);
  area *a = active_dynamic_area;
  Boolean egc_was_enabled = (a->older != NULL);
  natural gc_previously_deferred = gc_deferred;

  switch (selector) {
  case GC_TRAP_FUNCTION_EGC_CONTROL:
    egc_control(arg != 0, a->active);
    xpGPR(xp,Iarg_z) = lisp_nil + (egc_was_enabled ? t_offset : 0);
    break;

  case GC_TRAP_FUNCTION_CONFIGURE_EGC:
    a->threshold = unbox_fixnum(xpGPR(xp, Iarg_x));
    g1_area->threshold = unbox_fixnum(xpGPR(xp, Iarg_y));
    g2_area->threshold = unbox_fixnum(xpGPR(xp, Iarg_z));
    xpGPR(xp,Iarg_z) = lisp_nil+t_offset;
    break;

  case GC_TRAP_FUNCTION_SET_LISP_HEAP_THRESHOLD:
    if (((signed_natural) arg) > 0) {
      lisp_heap_gc_threshold = 
        align_to_power_of_2((arg-1) +
                            (heap_segment_size - 1),
                            log2_heap_segment_size);
    }
    /* fall through */
  case GC_TRAP_FUNCTION_GET_LISP_HEAP_THRESHOLD:
    xpGPR(xp, Iimm0) = lisp_heap_gc_threshold;
    break;

  case GC_TRAP_FUNCTION_USE_LISP_HEAP_THRESHOLD:
    /*  Try to put the current threshold in effect.  This may
        need to disable/reenable the EGC. */
    untenure_from_area(tenured_area);
    resize_dynamic_heap(a->active,lisp_heap_gc_threshold);
    if (egc_was_enabled) {
      if ((a->high - a->active) >= a->threshold) {
        tenure_to_area(tenured_area);
      }
    }
    xpGPR(xp, Iimm0) = lisp_heap_gc_threshold;
    break;

  default:
    update_bytes_allocated(tcr, (void *) tcr->save_allocptr);

    if (selector == GC_TRAP_FUNCTION_IMMEDIATE_GC) {
      if (!full_gc_deferred) {
        gc_from_xp(xp, 0L);
        break;
      }
      /* Tried to do a full GC when gc was disabled.  That failed,
         so try full GC now */
      selector = GC_TRAP_FUNCTION_GC;
    }
    
    if (egc_was_enabled) {
      egc_control(false, (BytePtr) a->active);
    }
    gc_from_xp(xp, 0L);
    if (gc_deferred > gc_previously_deferred) {
      full_gc_deferred = 1;
    } else {
      full_gc_deferred = 0;
    }
    if (selector & GC_TRAP_FUNCTION_PURIFY) {
      purify_from_xp(xp, 0L);
      gc_from_xp(xp, 0L);
    }
    if (selector & GC_TRAP_FUNCTION_SAVE_APPLICATION) {
      OSErr err;
      extern OSErr save_application(unsigned);
      area *vsarea = tcr->vs_area;
	
      nrs_TOPLFUNC.vcell = *((LispObj *)(vsarea->high)-1);
      err = save_application(arg);
      if (err == noErr) {
	_exit(0);
      }
      fatal_oserr(": save_application", err);
    }
    if (selector == GC_TRAP_FUNCTION_SET_HONS_AREA_SIZE) {
      LispObj aligned_arg = align_to_power_of_2(arg, log2_nbits_in_word);
      signed_natural 
	delta_dnodes = ((signed_natural) aligned_arg) - 
	((signed_natural) tenured_area->static_dnodes);
      change_hons_area_size_from_xp(xp, delta_dnodes*dnode_size);
      xpGPR(xp, Iimm0) = tenured_area->static_dnodes;
    }
    if (egc_was_enabled) {
      egc_control(true, NULL);
    }
    break;
  }
  return true;
}

  



void
push_on_lisp_stack(ExceptionInformation *xp, LispObj value)
{
  LispObj *vsp = (LispObj *)xpGPR(xp,Isp);
  *--vsp = value;
  xpGPR(xp,Isp) = (LispObj)vsp;
}


/* Hard to know if or whether this is necessary in general.  For now,
   do it when we get a "wrong number of arguments" trap.
*/
void
finish_function_entry(ExceptionInformation *xp)
{
  natural nargs = (xpGPR(xp,Inargs)&0xffff)>> fixnumshift;
  signed_natural disp = nargs-3;
  LispObj *vsp =  (LispObj *) xpGPR(xp,Isp);
   
  
  if (disp > 0) {               /* implies that nargs > 3 */
    vsp[disp] = xpGPR(xp,Irbp);
    vsp[disp+1] = xpGPR(xp,Ira0);
    xpGPR(xp,Irbp) = (LispObj)(vsp+disp);
    push_on_lisp_stack(xp,xpGPR(xp,Iarg_x));
    push_on_lisp_stack(xp,xpGPR(xp,Iarg_y));
    push_on_lisp_stack(xp,xpGPR(xp,Iarg_z));
  } else {
    push_on_lisp_stack(xp,xpGPR(xp,Ira0));
    push_on_lisp_stack(xp,xpGPR(xp,Irbp));
    xpGPR(xp,Irbp) = xpGPR(xp,Isp);
    if (nargs == 3) {
      push_on_lisp_stack(xp,xpGPR(xp,Iarg_x));
    }
    if (nargs >= 2) {
      push_on_lisp_stack(xp,xpGPR(xp,Iarg_y));
    }
    if (nargs >= 1) {
      push_on_lisp_stack(xp,xpGPR(xp,Iarg_z));
    }
  }
}

Boolean
object_contains_pc(LispObj container, LispObj addr)
{
  if (fulltag_of(container) >= fulltag_misc) {
    natural elements = header_element_count(header_of(container));
    if ((addr >= container) &&
        (addr < ((LispObj)&(deref(container,1+elements))))) {
      return true;
    }
  }
  return false;
}

LispObj
create_exception_callback_frame(ExceptionInformation *xp)
{
  LispObj containing_uvector = 0, 
    relative_pc, 
    nominal_function = lisp_nil, 
    f, tra, tra_f = 0, abs_pc;

  f = xpGPR(xp,Ifn);
  tra = xpGPR(xp,Ira0);
  if (tag_of(tra) == tag_tra) {
    tra_f = tra - ((int *)tra)[-1];
    if (fulltag_of(tra_f) != fulltag_function) {
      tra_f = 0;
    }
  }

  abs_pc = (LispObj)xpPC(xp);

  if (fulltag_of(f) == fulltag_function) {
    nominal_function = f;
  } else {
    if (tra_f) {
      nominal_function = tra_f;
    }
  }
  
  f = xpGPR(xp,Ifn);
  if (object_contains_pc(f, abs_pc)) {
    containing_uvector = untag(f)+fulltag_misc;
  } else {
    f = xpGPR(xp,Ixfn);
    if (object_contains_pc(f, abs_pc)) {
      containing_uvector = untag(f)+fulltag_misc;
    } else {
      if (tra_f) {
        f = tra_f;
        if (object_contains_pc(f, abs_pc)) {
          containing_uvector = untag(f)+fulltag_misc;
          relative_pc = (abs_pc - f) << fixnumshift;
        }
      }
    }
  }
  if (containing_uvector) {
    relative_pc = (abs_pc - (LispObj)&(deref(containing_uvector,1))) << fixnumshift;
  } else {
    containing_uvector = lisp_nil;
    relative_pc = abs_pc << fixnumshift;
  }
  
  push_on_lisp_stack(xp,tra);
  push_on_lisp_stack(xp,(LispObj)xp);
  push_on_lisp_stack(xp,containing_uvector); 
  push_on_lisp_stack(xp,relative_pc);
  push_on_lisp_stack(xp,nominal_function);
  push_on_lisp_stack(xp,0);
  push_on_lisp_stack(xp,xpGPR(xp,Irbp));
  xpGPR(xp,Irbp) = xpGPR(xp,Isp);
  return xpGPR(xp,Isp);
}

#ifndef XMEMFULL
#define XMEMFULL (76)
#endif

Boolean
handle_alloc_trap(ExceptionInformation *xp, TCR *tcr)
{
  natural cur_allocptr, bytes_needed;
  unsigned allocptr_tag;
  signed_natural disp;
  
  cur_allocptr = xpGPR(xp,Iallocptr);
  allocptr_tag = fulltag_of(cur_allocptr);
  if (allocptr_tag == fulltag_misc) {
    disp = xpGPR(xp,Iimm1);
  } else {
    disp = dnode_size-fulltag_cons;
  }
  bytes_needed = disp+allocptr_tag;

  update_bytes_allocated(tcr,((BytePtr)(cur_allocptr+disp)));
  if (allocate_object(xp, bytes_needed, disp, tcr)) {
    return true;
  }
  
  {
    LispObj xcf = create_exception_callback_frame(xp),
      cmain = nrs_CMAIN.vcell;
    int skip;
    
    tcr->save_allocptr = tcr->save_allocbase = (void *)VOID_ALLOCPTR;
    xpGPR(xp,Iallocptr) = VOID_ALLOCPTR;

    skip = callback_to_lisp(tcr, cmain, xp, xcf, -1, XMEMFULL, 0, 0);
    xpPC(xp) += skip;
  }

  return true;
}

extern unsigned get_mxcsr();
extern void set_mxcsr(unsigned);
  
int
callback_to_lisp (TCR * tcr, LispObj callback_macptr, ExceptionInformation *xp,
                  natural arg1, natural arg2, natural arg3, natural arg4, natural arg5)
{
  sigset_t mask;
  natural  callback_ptr, i;
  int delta;
  unsigned old_mxcsr = get_mxcsr();

  set_mxcsr(0x1f80);

  /* Put the active stack pointers where .SPcallback expects them */
  tcr->save_vsp = (LispObj *) xpGPR(xp, Isp);
  tcr->save_rbp = (LispObj *) xpGPR(xp, Irbp);


  /* Call back.  The caller of this function may have modified stack/frame
     pointers (and at least should have called prepare_for_callback()).
  */
  callback_ptr = ((macptr *)ptr_from_lispobj(untag(callback_macptr)))->address;
  UNLOCK(lisp_global(EXCEPTION_LOCK), tcr);
  delta = ((int (*)())callback_ptr) (xp, arg1, arg2, arg3, arg4, arg5);
  LOCK(lisp_global(EXCEPTION_LOCK), tcr);
  set_mxcsr(old_mxcsr);
  return delta;
}

void
callback_for_interrupt(TCR *tcr, ExceptionInformation *xp)
{
  LispObj save_rbp = xpGPR(xp,Irbp),
    *save_vsp = (LispObj *)xpGPR(xp,Isp),
    word_beyond_vsp = save_vsp[-1],
    xcf = create_exception_callback_frame(xp);
  int save_errno = errno;
  
  callback_to_lisp(tcr, nrs_CMAIN.vcell,xp, xcf, 0, 0, 0, 0);
  xpGPR(xp,Irbp) = save_rbp;
  xpGPR(xp,Isp) = (LispObj)save_vsp;
  save_vsp[-1] = word_beyond_vsp;
  errno = save_errno;
}

Boolean
handle_error(TCR *tcr, ExceptionInformation *xp)
{
  pc program_counter = (pc)xpPC(xp);
  unsigned char op0 = program_counter[0], op1 = program_counter[1];
  LispObj rpc = (LispObj) program_counter, errdisp = nrs_ERRDISP.vcell,
    save_rbp = xpGPR(xp,Irbp), save_vsp = xpGPR(xp,Isp), xcf;
  int skip;

  if ((fulltag_of(errdisp) == fulltag_misc) &&
      (header_subtag(header_of(errdisp)) == subtag_macptr)) {

    if ((op0 == 0xcd) && (op1 >= 0xc0) && (op1 <= 0xc2)) {
      finish_function_entry(xp);
    }
    xcf = create_exception_callback_frame(xp);
    skip = callback_to_lisp(tcr, errdisp, xp, xcf, 0, 0, 0, 0);
    xpGPR(xp,Irbp) = save_rbp;
    xpGPR(xp,Isp) = save_vsp;
    xpPC(xp) += skip;
    return true;
  } else {
    return false;
  }
}


protection_handler
* protection_handlers[] = {
  do_spurious_wp_fault,
  do_soft_stack_overflow,
  do_soft_stack_overflow,
  do_soft_stack_overflow,
  do_hard_stack_overflow,    
  do_hard_stack_overflow,
  do_hard_stack_overflow,
};


/* Maybe this'll work someday.  We may have to do something to
   make the thread look like it's not handling an exception */
void
reset_lisp_process(ExceptionInformation *xp)
{
}

Boolean
do_hard_stack_overflow(ExceptionInformation *xp, protected_area_ptr area, BytePtr addr)
{
  reset_lisp_process(xp);
  return false;
}


Boolean
do_spurious_wp_fault(ExceptionInformation *xp, protected_area_ptr area, BytePtr addr)
{

  return false;
}

Boolean
do_soft_stack_overflow(ExceptionInformation *xp, protected_area_ptr prot_area, BytePtr addr)
{
  /* Trying to write into a guard page on the vstack or tstack.
     Allocate a new stack segment, emulate stwu and stwux for the TSP, and
     signal an error_stack_overflow condition.
      */
  lisp_protection_kind which = prot_area->why;
  Boolean on_TSP = (which == kTSPsoftguard);
  LispObj save_rbp = xpGPR(xp,Irbp), 
    save_vsp = xpGPR(xp,Isp), 
    xcf,
    cmain = nrs_CMAIN.vcell;
  area *a;
  protected_area_ptr soft;
  TCR *tcr = get_tcr(false);
  int skip;

  if ((fulltag_of(cmain) == fulltag_misc) &&
      (header_subtag(header_of(cmain)) == subtag_macptr)) {
    if (on_TSP) {
      a = tcr->ts_area;
    } else {
      a = tcr->vs_area;
    }
    soft = a->softprot;
    unprotect_area(soft);
    xcf = create_exception_callback_frame(xp);
    skip = callback_to_lisp(tcr, nrs_CMAIN.vcell, xp, xcf, SIGSEGV, on_TSP, 0, 0);
    xpGPR(xp,Irbp) = save_rbp;
    xpGPR(xp,Isp) = save_vsp;
    xpPC(xp) += skip;
    return true;
  }
  return false;
}

Boolean
handle_fault(TCR *tcr, ExceptionInformation *xp, siginfo_t *info)
{
#ifdef FREEBSD
  BytePtr addr = (BytePtr) xp->uc_mcontext.mc_addr;
#else
  BytePtr addr = (BytePtr) info->si_addr;
#endif

  if (addr && (addr == tcr->safe_ref_address)) {
    xpGPR(xp,Iimm0) = 0;
    xpPC(xp) = xpGPR(xp,Ira0);
    return true;
  } else {
    protected_area *a = find_protected_area(addr);
    protection_handler *handler;

    if (a) {
      handler = protection_handlers[a->why];
      return handler(xp, a, addr);
    }
  }
  return false;
}

Boolean
handle_floating_point_exception(TCR *tcr, ExceptionInformation *xp, siginfo_t *info)
{
  int code = info->si_code, rfn = 0, skip;
  pc program_counter = (pc)xpPC(xp);
  LispObj rpc = (LispObj) program_counter, xcf, cmain = nrs_CMAIN.vcell,

    save_rbp = xpGPR(xp,Irbp), save_vsp = xpGPR(xp,Isp);

  if ((fulltag_of(cmain) == fulltag_misc) &&
      (header_subtag(header_of(cmain)) == subtag_macptr)) {
    xcf = create_exception_callback_frame(xp);
    skip = callback_to_lisp(tcr, cmain, xp, xcf, SIGFPE, code, 0, 0);
    xpPC(xp) += skip;
    xpGPR(xp,Irbp) = save_rbp;
    xpGPR(xp,Isp) = save_vsp;
    return true;
  } else {
    return false;
  }
}

Boolean
extend_tcr_tlb(TCR *tcr, ExceptionInformation *xp)
{
  LispObj index, old_limit = tcr->tlb_limit, new_limit, new_bytes;
  LispObj *old_tlb = tcr->tlb_pointer, *new_tlb, *work, *tos;

  tos = (LispObj*)(xpGPR(xp,Isp));
  index = *tos++;
  (xpGPR(xp,Isp))=(LispObj)tos;
  
  new_limit = align_to_power_of_2(index+1,12);
  new_bytes = new_limit-old_limit;
  new_tlb = realloc(old_tlb, new_limit);

  if (new_tlb == NULL) {
    return false;
  }
  work = (LispObj *) ((BytePtr)new_tlb+old_limit);

  while (new_bytes) {
    *work++ = no_thread_local_binding_marker;
    new_bytes -= sizeof(LispObj);
  }
  tcr->tlb_pointer = new_tlb;
  tcr->tlb_limit = new_limit;
  return true;
}


#if defined(FREEBSD) || defined(DARWIN)
static
char mxcsr_bit_to_fpe_code[] = {
  FPE_FLTINV,                   /* ie */
  0,                            /* de */
  FPE_FLTDIV,                   /* ze */
  FPE_FLTOVF,                   /* oe */
  FPE_FLTUND,                   /* ue */
  FPE_FLTRES                    /* pe */
};

void
decode_vector_fp_exception(siginfo_t *info, uint32_t mxcsr)
{
  /* If the exception appears to be an XMM FP exception, try to
     determine what it was by looking at bits in the mxcsr.
  */
  int xbit, maskbit;
  
  for (xbit = 0, maskbit = MXCSR_IM_BIT; xbit < 6; xbit++, maskbit++) {
    if ((mxcsr & (1 << xbit)) &&
        !(mxcsr & (1 << maskbit))) {
      info->si_code = mxcsr_bit_to_fpe_code[xbit];
      return;
    }
  }
}

#ifdef FREEBSD
void
freebsd_decode_vector_fp_exception(siginfo_t *info, ExceptionInformation *xp)
{
  if (info->si_code == 0) {
    struct savefpu *fpu = (struct savefpu *) &(xp->uc_mcontext.mc_fpstate);
    uint32_t mxcsr = fpu->sv_env.en_mxcsr;

    decode_vector_fp_exception(info, mxcsr);
  }
}
#endif

#ifdef DARWIN
void
darwin_decode_vector_fp_exception(siginfo_t *info, ExceptionInformation *xp)
{
  if (info->si_code == EXC_I386_SSEEXTERR) {
    uint32_t mxcsr = UC_MCONTEXT(xp)->__fs.__fpu_mxcsr;

    decode_vector_fp_exception(info, mxcsr);
  }
}

#endif

#endif

void
get_lisp_string(LispObj lisp_string, char *c_string, natural max)
{
  lisp_char_code *src = (lisp_char_code *)  (ptr_from_lispobj(lisp_string + misc_data_offset));
  natural i, n = header_element_count(header_of(lisp_string));

  if (n > max) {
    n = max;
  }

  for (i = 0; i < n; i++) {
    c_string[i] = 0xff & (src[i]);
  }
  c_string[n] = 0;
}

Boolean
handle_exception(int signum, siginfo_t *info, ExceptionInformation  *context, TCR *tcr)
{
  pc program_counter = (pc)xpPC(context);

  switch (signum) {
  case SIGNUM_FOR_INTN_TRAP:
    if (IS_MAYBE_INT_TRAP(info,context)) {
      /* Something mapped to SIGSEGV/SIGBUS that has nothing to do with
	 a memory fault.  On x86, an "int n" instruction that's
         not otherwise implemented causes a "protecton fault".  Of
         course that has nothing to do with accessing protected
         memory; of course, most Unices act as if it did.*/
      if (*program_counter == INTN_OPCODE) {
	program_counter++;
	switch (*program_counter) {
	case UUO_ALLOC_TRAP:
	  if (handle_alloc_trap(context, tcr)) {
	    xpPC(context) += 2;	/* we might have GCed. */
	    return true;
	  }
	  break;
	case UUO_GC_TRAP:
	  if (handle_gc_trap(context, tcr)) {
	    xpPC(context) += 2;
	    return true;
	  }
	  break;
	  
	case UUO_DEBUG_TRAP:
	  xpPC(context) = (natural) (program_counter+1);
	  lisp_Debugger(context, info, debug_entry_dbg, "Lisp Breakpoint");
	  return true;

	case UUO_DEBUG_TRAP_WITH_STRING:
	  xpPC(context) = (natural) (program_counter+1);
          {
            char msg[512];

            get_lisp_string(xpGPR(context,Iarg_z),msg, sizeof(msg)-1);
            lisp_Debugger(context, info, debug_entry_dbg, msg);
          }
	  return true;
          
        default:
          return handle_error(tcr, context);
	}
      } else {
	return false;
      }

    } else {
      return handle_fault(tcr, context, info);
    }
    break;

  case SIGNAL_FOR_PROCESS_INTERRUPT:
    tcr->interrupt_pending = 0;
    callback_for_interrupt(tcr, context);
    return true;
    break;


  case SIGILL:
    if ((program_counter[0] == XUUO_OPCODE_0) &&
	(program_counter[1] == XUUO_OPCODE_1)) {
      switch (program_counter[2]) {
      case XUUO_TLB_TOO_SMALL:
        if (extend_tcr_tlb(tcr,context)) {
          xpPC(context)+=3;
          return true;
        }
	break;
	
      case XUUO_INTERRUPT_NOW:
	callback_for_interrupt(tcr,context);
	xpPC(context)+=3;
	return true;
	
      default:
	return false;
      }
    } else {
      return false;
    }
    break;
    
  case SIGFPE:
#ifdef FREEBSD
    /* As of 6.1, FreeBSD/AMD64 doesn't seem real comfortable
       with this newfangled XMM business (and therefore info->si_code
       is often 0 on an XMM FP exception.
       Try to figure out what really happened by decoding mxcsr
       bits.
    */
    freebsd_decode_vector_fp_exception(info,context);
#endif
#ifdef DARWIN
    /* Same general problem with Darwin as of 8.7.2 */
    darwin_decode_vector_fp_exception(info,context);
#endif

    return handle_floating_point_exception(tcr, context, info);

#if SIGBUS != SIGNUM_FOR_INTN_TRAP
  case SIGBUS:
    return handle_fault(tcr, context, info);
#endif
    
#if SIGSEGV != SIGNUM_FOR_INTN_TRAP
  case SIGSEGV:
    return handle_fault(tcr, context, info);
#endif    
    
  default:
    return false;
  }
}


/* 
   Current thread has all signals masked.  Before unmasking them,
   make it appear that the current thread has been suspended.
   (This is to handle the case where another thread is trying
   to GC before this thread is able to seize the exception lock.)
*/
int
prepare_to_wait_for_exception_lock(TCR *tcr, ExceptionInformation *context)
{
  int old_valence = tcr->valence;

  tcr->pending_exception_context = context;
  tcr->valence = TCR_STATE_EXCEPTION_WAIT;

  ALLOW_EXCEPTIONS(context);
  return old_valence;
}  

void
wait_for_exception_lock_in_handler(TCR *tcr, 
				   ExceptionInformation *context,
				   xframe_list *xf)
{

  LOCK(lisp_global(EXCEPTION_LOCK), tcr);
#if 0
  fprintf(stderr, "0x%x has exception lock\n", tcr);
#endif
  xf->curr = context;
  xf->prev = tcr->xframe;
  tcr->xframe =  xf;
  tcr->pending_exception_context = NULL;
  tcr->valence = TCR_STATE_FOREIGN; 
}

void
unlock_exception_lock_in_handler(TCR *tcr)
{
  tcr->pending_exception_context = tcr->xframe->curr;
  tcr->xframe = tcr->xframe->prev;
  tcr->valence = TCR_STATE_EXCEPTION_RETURN;
  UNLOCK(lisp_global(EXCEPTION_LOCK),tcr);
#if 0
  fprintf(stderr, "0x%x released exception lock\n", tcr);
#endif
}

/* 
   If an interrupt is pending on exception exit, try to ensure
   that the thread sees it as soon as it's able to run.
*/
void
raise_pending_interrupt(TCR *tcr)
{
  if ((TCR_INTERRUPT_LEVEL(tcr) >= 0) &&
      (tcr->interrupt_pending)) {
    pthread_kill((pthread_t)(tcr->osid), SIGNAL_FOR_PROCESS_INTERRUPT);
  }
}

void
exit_signal_handler(TCR *tcr, int old_valence)
{
  sigset_t mask;
  sigfillset(&mask);
  
  pthread_sigmask(SIG_SETMASK,&mask, NULL);
  tcr->valence = old_valence;
  tcr->pending_exception_context = NULL;
}

void
signal_handler(int signum, siginfo_t *info, ExceptionInformation  *context, TCR *tcr, int old_valence)
{
#ifdef DARWIN_GS_HACK
  Boolean gs_was_tcr = ensure_gs_pthread();
#endif
  xframe_list xframe_link;
#ifndef DARWIN
  tcr = get_tcr(false);

  old_valence = prepare_to_wait_for_exception_lock(tcr, context);
#endif
  wait_for_exception_lock_in_handler(tcr,context, &xframe_link);


  if (! handle_exception(signum, info, context, tcr)) {
    char msg[512];

    snprintf(msg, sizeof(msg), "Unhandled exception %d at 0x%lx, context->regs at #x%lx", signum, xpPC(context), (natural)xpGPRvector(context));
    
    if (lisp_Debugger(context, info, signum, msg)) {
      SET_TCR_FLAG(tcr,TCR_FLAG_BIT_PROPAGATE_EXCEPTION);
    }
  }
  unlock_exception_lock_in_handler(tcr);
#ifndef DARWIN_USE_PSEUDO_SIGRETURN
  exit_signal_handler(tcr, old_valence);
#endif
  /* raise_pending_interrupt(tcr); */
#ifdef DARWIN_GS_HACK
  if (gs_was_tcr) {
    set_gs_address(tcr);
  }
#endif
#ifndef DARWIN_USE_PSEUDO_SIGRETURN
  SIGRETURN(context);
#endif
}

#ifdef DARWIN
void
pseudo_signal_handler(int signum, siginfo_t *info, ExceptionInformation  *context, TCR *tcr, int old_valence)
{
  sigset_t mask;

  sigfillset(&mask);

  pthread_sigmask(SIG_SETMASK,&mask,&(context->uc_sigmask));
  signal_handler(signum, info, context, tcr, old_valence);
}
#endif



#ifdef LINUX
LispObj *
copy_fpregs(ExceptionInformation *xp, LispObj *current, fpregset_t *destptr)
{
  fpregset_t src = xp->uc_mcontext.fpregs, dest;
  
  if (src) {
    dest = ((fpregset_t)current)-1;
    *dest = *src;
    *destptr = dest;
    current = (LispObj *) dest;
  }
  return current;
}
#endif

#ifdef DARWIN
LispObj *
copy_darwin_mcontext(MCONTEXT_T context, 
                     LispObj *current, 
                     MCONTEXT_T *out)
{
  MCONTEXT_T dest = ((MCONTEXT_T)current)-1;
  dest = (MCONTEXT_T) (((LispObj)dest) & ~15);

  *dest = *context;
  *out = dest;
  return (LispObj *)dest;
}
#endif

LispObj *
copy_siginfo(siginfo_t *info, LispObj *current)
{
  siginfo_t *dest = ((siginfo_t *)current) - 1;
  dest = (siginfo_t *) (((LispObj)dest)&~15);
  *dest = *info;
  return (LispObj *)dest;
}

#ifdef LINUX
typedef fpregset_t copy_ucontext_last_arg_t;
#else
typedef void * copy_ucontext_last_arg_t;
#endif

LispObj *
copy_ucontext(ExceptionInformation *context, LispObj *current, copy_ucontext_last_arg_t fp)
{
  ExceptionInformation *dest = ((ExceptionInformation *)current)-1;
  dest = (ExceptionInformation *) (((LispObj)dest) & ~15);

  *dest = *context;
  /* Fix it up a little; where's the signal mask allocated, if indeed
     it is "allocated" ? */
#ifdef LINUX
  dest->uc_mcontext.fpregs = fp;
#endif
  dest->uc_stack.ss_sp = 0;
  dest->uc_stack.ss_size = 0;
  dest->uc_stack.ss_flags = 0;
  dest->uc_link = NULL;
  return (LispObj *)dest;
}

LispObj *
find_foreign_rsp(LispObj rsp, area *foreign_area, TCR *tcr)
{

  if (((BytePtr)rsp < foreign_area->low) ||
      ((BytePtr)rsp > foreign_area->high)) {
    rsp = (LispObj)(tcr->foreign_sp);
  }
  return (LispObj *) ((rsp-128 & ~15));
}


#ifdef DARWIN
/* 
   There seems to be a problem with thread-level exception handling;
   Mach seems (under some cirumstances) to conclude that there's
   no thread-level handler and exceptions get passed up to a
   handler that raises Un*x signals.  Ignore those signals so that
   the exception will repropagate and eventually get caught by
   catch_exception_raise() at the thread level.

   Mach sucks, but no one understands how.
*/
void
bogus_signal_handler()
{
  /* This does nothing, but does it with signals masked */
}
#endif

void
handle_signal_on_foreign_stack(TCR *tcr,
                               void *handler, 
                               int signum, 
                               siginfo_t *info, 
                               ExceptionInformation *context,
                               LispObj return_address
#ifdef DARWIN_GS_HACK
                               , Boolean gs_was_tcr
#endif
                               )
{
#ifdef LINUX
  fpregset_t fpregs = NULL;
#else
  void *fpregs = NULL;
#endif
#ifdef DARWIN
  MCONTEXT_T mcontextp = NULL;
#endif
  siginfo_t *info_copy = NULL;
  ExceptionInformation *xp = NULL;
  LispObj *foreign_rsp = find_foreign_rsp(xpGPR(context,Isp), tcr->cs_area, tcr);

#ifdef LINUX
  foreign_rsp = copy_fpregs(context, foreign_rsp, &fpregs);
#endif
#ifdef DARWIN
  foreign_rsp = copy_darwin_mcontext(UC_MCONTEXT(context), foreign_rsp, &mcontextp);
#endif
  foreign_rsp = copy_siginfo(info, foreign_rsp);
  info_copy = (siginfo_t *)foreign_rsp;
  foreign_rsp = copy_ucontext(context, foreign_rsp, fpregs);
  xp = (ExceptionInformation *)foreign_rsp;
#ifdef DARWIN
  UC_MCONTEXT(xp) = mcontextp;
#endif
  *--foreign_rsp = return_address;
#ifdef DARWIN_GS_HACK
  if (gs_was_tcr) {
    set_gs_address(tcr);
  }
#endif
  switch_to_foreign_stack(foreign_rsp,handler,signum,info_copy,xp);
}


void
altstack_signal_handler(int signum, siginfo_t *info, ExceptionInformation  *context)
{
  TCR* tcr = get_tcr(true);
#if 1
  if (tcr->valence != TCR_STATE_LISP) {
    Bug(context, "exception in foreign context");
  }
#endif
  handle_signal_on_foreign_stack(tcr,signal_handler,signum,info,context,(LispObj)__builtin_return_address(0)
#ifdef DARWIN_GS_HACK
                                 , false
#endif
);
}

void
interrupt_handler (int signum, siginfo_t *info, ExceptionInformation *context)
{
#ifdef DARWIN_GS_HACK
  Boolean gs_was_tcr = ensure_gs_pthread();
#endif
  TCR *tcr = get_interrupt_tcr(false);
  if (tcr) {
    if ((TCR_INTERRUPT_LEVEL(tcr) < 0) ||
        (tcr->valence != TCR_STATE_LISP) ||
        (tcr->unwinding != 0)) {
      tcr->interrupt_pending = (1L << (nbits_in_word - 1L));
    } else {
      LispObj cmain = nrs_CMAIN.vcell;

      if ((fulltag_of(cmain) == fulltag_misc) &&
	  (header_subtag(header_of(cmain)) == subtag_macptr)) {
	/* 
	   This thread can (allegedly) take an interrupt now. 
        */

        xframe_list xframe_link;
        int old_valence;
        signed_natural alloc_displacement = 0;
        LispObj 
          *next_tsp = tcr->next_tsp,
          *save_tsp = tcr->save_tsp,
          *p,
          q;
            
        if (next_tsp != save_tsp) {
          tcr->next_tsp = save_tsp;
        } else {
          next_tsp = NULL;
        }
        /* have to do this before allowing interrupts */
        pc_luser_xp(context, tcr, &alloc_displacement);
        old_valence = prepare_to_wait_for_exception_lock(tcr, context);
        wait_for_exception_lock_in_handler(tcr, context, &xframe_link);
        handle_exception(signum, info, context, tcr);
        if (alloc_displacement) {
          tcr->save_allocptr -= alloc_displacement;
        }
        if (next_tsp) {
          tcr->next_tsp = next_tsp;
          p = next_tsp;
          while (p != save_tsp) {
            *p++ = 0;
          }
          q = (LispObj)save_tsp;
          *next_tsp = q;
        }
        unlock_exception_lock_in_handler(tcr);
        exit_signal_handler(tcr, old_valence);
      }
    }
  }
#ifdef DARWIN_GS_HACK
  if (gs_was_tcr) {
    set_gs_address(tcr);
  }
#endif
  SIGRETURN(context);
}

#ifndef USE_SIGALTSTACK
void
arbstack_interrupt_handler (int signum, siginfo_t *info, ExceptionInformation *context)
{
#ifdef DARWIN_GS_HACK
  Boolean gs_was_tcr = ensure_gs_pthread();
#endif
  TCR *tcr = get_interrupt_tcr(false);
  area *vs = tcr->vs_area;
  BytePtr current_sp = (BytePtr) current_stack_pointer();

  if ((current_sp >= vs->low) &&
      (current_sp < vs->high)) {
    handle_signal_on_foreign_stack(tcr,
                                   interrupt_handler,
                                   signum,
                                   info,
                                   context,
                                   (LispObj)__builtin_return_address(0)
#ifdef DARWIN_GS_HACK
                                   ,gs_was_tcr
#endif
                                   );
  } else {
    /* If we're not on the value stack, we pretty much have to be on
       the C stack.  Just run the handler. */
#ifdef DARWIN_GS_HACK
    if (gs_was_tcr) {
      set_gs_address(tcr);
    }
#endif
    interrupt_handler(signum, info, context);
  }
}

#else /* altstack works */
  
void
altstack_interrupt_handler (int signum, siginfo_t *info, ExceptionInformation *context)
{
#ifdef DARWIN_GS_HACK
  Boolean gs_was_tcr = ensure_gs_pthread();
#endif
  TCR *tcr = get_interrupt_tcr(false);
  handle_signal_on_foreign_stack(tcr,interrupt_handler,signum,info,context,(LispObj)__builtin_return_address(0)
#ifdef DARWIN_GS_HACK
                                 ,gs_was_tcr
#endif
                                 );
}

#endif


void
install_signal_handler(int signo, void * handler)
{
  struct sigaction sa;
  
  sa.sa_sigaction = (void *)handler;
  sigfillset(&sa.sa_mask);
#ifdef FREEBSD
  /* Strange FreeBSD behavior wrt synchronous signals */
  sigdelset(&sa.sa_mask,SIGNUM_FOR_INTN_TRAP);
  sigdelset(&sa.sa_mask,SIGTRAP);  /* let GDB work */
  sigdelset(&sa.sa_mask,SIGILL);
  sigdelset(&sa.sa_mask,SIGFPE);
  sigdelset(&sa.sa_mask,SIGSEGV);
#endif
  sa.sa_flags = 
    SA_RESTART
#ifdef USE_SIGALTSTACK
    | SA_ONSTACK
#endif
    | SA_SIGINFO;

  sigaction(signo, &sa, NULL);
}


void
install_pmcl_exception_handlers()
{
#ifndef DARWIN  
  install_signal_handler(SIGILL, altstack_signal_handler);
  
  install_signal_handler(SIGBUS, altstack_signal_handler);
  install_signal_handler(SIGSEGV,altstack_signal_handler);
  install_signal_handler(SIGFPE, altstack_signal_handler);
#else
  install_signal_handler(SIGTRAP,bogus_signal_handler);
  install_signal_handler(SIGILL, bogus_signal_handler);
  
  install_signal_handler(SIGBUS, bogus_signal_handler);
  install_signal_handler(SIGSEGV,bogus_signal_handler);
  install_signal_handler(SIGFPE, bogus_signal_handler);
  /*  9.0.0d8 generates spurious SIGSYS from mach_msg_trap */
  install_signal_handler(SIGSYS, bogus_signal_handler);
#endif
  
  install_signal_handler(SIGNAL_FOR_PROCESS_INTERRUPT,
#ifdef USE_SIGALTSTACK
			 altstack_interrupt_handler
#else
                         arbstack_interrupt_handler
#endif
);
  signal(SIGPIPE, SIG_IGN);
}

#ifndef USE_SIGALTSTACK
void
arbstack_suspend_resume_handler(int signum, siginfo_t *info, ExceptionInformation  *context)
{
#ifdef DARWIN_GS_HACK
  Boolean gs_was_tcr = ensure_gs_pthread();
#endif
  TCR *tcr = get_interrupt_tcr(false);
  area *vs = tcr->vs_area;
  BytePtr current_sp = (BytePtr) current_stack_pointer();

  if ((current_sp >= vs->low) &&
      (current_sp < vs->high)) {
    handle_signal_on_foreign_stack(tcr,
                                   suspend_resume_handler,
                                   signum,
                                   info,
                                   context,
                                   (LispObj)__builtin_return_address(0)
#ifdef DARWIN_GS_HACK
                                   ,gs_was_tcr
#endif
                                   );
  } else {
    /* If we're not on the value stack, we pretty much have to be on
       the C stack.  Just run the handler. */
#ifdef DARWIN_GS_HACK
    if (gs_was_tcr) {
      set_gs_address(tcr);
    }
#endif
    suspend_resume_handler(signum, info, context);
  }
}


#else /* altstack works */
void
altstack_suspend_resume_handler(int signum, siginfo_t *info, ExceptionInformation  *context)
{
#ifdef DARWIN_GS_HACK
  Boolean gs_was_tcr = ensure_gs_pthread();
#endif
  TCR* tcr = get_tcr(true);
  handle_signal_on_foreign_stack(tcr,
                                 suspend_resume_handler,
                                 signum,
                                 info,
                                 context,
                                 (LispObj)__builtin_return_address(0)
#ifdef DARWIN_GS_HACK
                                 ,gs_was_tcr
#endif
                                 );
}

#endif

void
quit_handler(int signum, siginfo_t *info, ExceptionInformation *xp)
{
  TCR *tcr = get_tcr(false);
  area *a;
  sigset_t mask;
  
  sigemptyset(&mask);


  if (tcr) {
    tcr->valence = TCR_STATE_FOREIGN;
    a = tcr->vs_area;
    if (a) {
      a->active = a->high;
    }
    a = tcr->ts_area;
    if (a) {
      a->active = a->high;
    }
    a = tcr->cs_area;
    if (a) {
      a->active = a->high;
    }
  }
  
  pthread_sigmask(SIG_SETMASK,&mask,NULL);
  pthread_exit(NULL);
}

#ifndef USE_SIGALTSTACK
arbstack_quit_handler(int signum, siginfo_t *info, ExceptionInformation *context)
{
#ifdef DARWIN_GS_HACK
  Boolean gs_was_tcr = ensure_gs_pthread();
#endif
  TCR *tcr = get_interrupt_tcr(false);
  area *vs = tcr->vs_area;
  BytePtr current_sp = (BytePtr) current_stack_pointer();

  if ((current_sp >= vs->low) &&
      (current_sp < vs->high)) {
    handle_signal_on_foreign_stack(tcr,
                                   quit_handler,
                                   signum,
                                   info,
                                   context,
                                   (LispObj)__builtin_return_address(0)
#ifdef DARWIN_GS_HACK
                                   ,gs_was_tcr
#endif
                                   );
  } else {
    /* If we're not on the value stack, we pretty much have to be on
       the C stack.  Just run the handler. */
#ifdef DARWIN_GS_HACK
    if (gs_was_tcr) {
      set_gs_address(tcr);
    }
#endif
    quit_handler(signum, info, context);
  }
}


#else
void
altstack_quit_handler(int signum, siginfo_t *info, ExceptionInformation *context)
{
#ifdef DARWIN_GS_HACK
  Boolean gs_was_tcr = ensure_gs_pthread();
#endif
  TCR* tcr = get_tcr(true);
  handle_signal_on_foreign_stack(tcr,
                                 quit_handler,
                                 signum,
                                 info,
                                 context,
                                 (LispObj)__builtin_return_address(0)
#ifdef DARWIN_GS_HACK
                                 ,gs_was_tcr
#endif
                                 );
}
#endif

#ifdef USE_SIGALTSTACK
#define SUSPEND_RESUME_HANDLER altstack_suspend_resume_handler
#define QUIT_HANDLER altstack_quit_handler
#else
#define SUSPEND_RESUME_HANDLER arbstack_suspend_resume_handler
#define QUIT_HANDLER arbstack_quit_handler
#endif

void
thread_signal_setup()
{
  thread_suspend_signal = SIG_SUSPEND_THREAD;
  thread_resume_signal = SIG_RESUME_THREAD;

  install_signal_handler(thread_suspend_signal, (void *)SUSPEND_RESUME_HANDLER);
  install_signal_handler(thread_resume_signal, (void *)SUSPEND_RESUME_HANDLER);
  install_signal_handler(SIGQUIT, (void *)QUIT_HANDLER);
}


void
enable_fp_exceptions()
{
}

void
exception_init()
{
  install_pmcl_exception_handlers();
}

void
adjust_exception_pc(ExceptionInformation *xp, int delta)
{
  xpPC(xp) += delta;
}

/*
  Lower (move toward 0) the "end" of the soft protected area associated
  with a by a page, if we can.
*/

void

adjust_soft_protection_limit(area *a)
{
  char *proposed_new_soft_limit = a->softlimit - 4096;
  protected_area_ptr p = a->softprot;
  
  if (proposed_new_soft_limit >= (p->start+16384)) {
    p->end = proposed_new_soft_limit;
    p->protsize = p->end-p->start;
    a->softlimit = proposed_new_soft_limit;
  }
  protect_area(p);
}

void
restore_soft_stack_limit(unsigned restore_tsp)
{
  TCR *tcr = get_tcr(false);
  area *a;
 
  if (restore_tsp) {
    a = tcr->ts_area;
  } else {
    a = tcr->vs_area;
  }
  adjust_soft_protection_limit(a);
}


#ifdef USE_SIGALTSTACK
void
setup_sigaltstack(area *a)
{
  stack_t stack;
  stack.ss_sp = a->low;
  a->low += 8192;
  stack.ss_size = 8192;
  stack.ss_flags = 0;
  mmap(stack.ss_sp,stack.ss_size, PROT_READ|PROT_WRITE|PROT_EXEC,MAP_FIXED|MAP_ANON|MAP_PRIVATE,-1,0);
  if (sigaltstack(&stack, NULL) != 0) {
    perror("sigaltstack");
    exit(-1);
  }
}
#endif

extern opcode egc_write_barrier_start, egc_write_barrier_end,
  egc_store_node_conditional_success_test,egc_store_node_conditional,
  egc_set_hash_key, egc_gvset, egc_rplacd;

/* We use (extremely) rigidly defined instruction sequences for consing,
   mostly so that 'pc_luser_xp()' knows what to do if a thread is interrupted
   while consing.

   Note that we can usually identify which of these instructions is about
   to be executed by a stopped thread without comparing all of the bytes
   to those at the stopped program counter, but we generally need to
   know the sizes of each of these instructions.
*/

opcode load_allocptr_reg_from_tcr_save_allocptr_instruction[] =
  {0x65,0x48,0x8b,0x1c,0x25,0xd8,0x00,0x00,0x00};
opcode compare_allocptr_reg_to_tcr_save_allocbase_instruction[] =
  {0x65,0x48,0x3b,0x1c,0x25,0xe0,0x00,0x00,0x00};
opcode branch_around_alloc_trap_instruction[] =
  {0x7f,0x02};
opcode alloc_trap_instruction[] =
  {0xcd,0xc5};
opcode clear_tcr_save_allocptr_tag_instruction[] =
  {0x65,0x80,0x24,0x25,0xd8,0x00,0x00,0x00,0xf0};
opcode set_allocptr_header_instruction[] =
  {0x48,0x89,0x43,0xf3};


alloc_instruction_id
recognize_alloc_instruction(pc program_counter)
{
  switch(program_counter[0]) {
  case 0xcd: return ID_alloc_trap_instruction;
  case 0x7f: return ID_branch_around_alloc_trap_instruction;
  case 0x48: return ID_set_allocptr_header_instruction;
  case 0x65: 
    switch(program_counter[1]) {
    case 0x80: return ID_clear_tcr_save_allocptr_tag_instruction;
    case 0x48:
      switch(program_counter[2]) {
      case 0x3b: return ID_compare_allocptr_reg_to_tcr_save_allocbase_instruction;
      case 0x8b: return ID_load_allocptr_reg_from_tcr_save_allocptr_instruction;
      }
    }
  }
  return ID_unrecognized_alloc_instruction;
}
      
  
void
pc_luser_xp(ExceptionInformation *xp, TCR *tcr, signed_natural *interrupt_displacement)
{
  pc program_counter = (pc)xpPC(xp);
  int allocptr_tag = fulltag_of((LispObj)(tcr->save_allocptr));

  if (allocptr_tag != 0) {
    alloc_instruction_id state = recognize_alloc_instruction(program_counter);
    signed_natural 
      disp = (allocptr_tag == fulltag_cons) ?
      sizeof(cons) - fulltag_cons :
      xpGPR(xp,Iimm1);
    LispObj new_vector;

    if ((state == ID_unrecognized_alloc_instruction) ||
        ((state == ID_set_allocptr_header_instruction) &&
         (allocptr_tag != fulltag_misc))) {
      Bug(xp, "Can't determine state of thread 0x%lx, interrupted during memory allocation", tcr);
    }
    switch(state) {
    case ID_set_allocptr_header_instruction:
      /* We were consing a vector and we won.  Set the header of the new vector
         (in the allocptr register) to the header in %rax and skip over this
         instruction, then fall into the next case. */
      new_vector = xpGPR(xp,Iallocptr);
      deref(new_vector,0) = xpGPR(xp,Iimm0);

      xpPC(xp) += sizeof(set_allocptr_header_instruction);
      /* Fall thru */
    case ID_clear_tcr_save_allocptr_tag_instruction:
      tcr->save_allocptr = (void *)(((LispObj)tcr->save_allocptr) & ~fulltagmask);
      xpPC(xp) += sizeof(clear_tcr_save_allocptr_tag_instruction);
      break;
    case ID_alloc_trap_instruction:
      /* If we're looking at another thread, we're pretty much committed to
         taking the trap.  We don't want the allocptr register to be pointing
         into the heap, so make it point to (- VOID_ALLOCPTR disp), where 'disp'
         was determined above. 
      */
      if (interrupt_displacement == NULL) {
        xpGPR(xp,Iallocptr) = VOID_ALLOCPTR - disp;
        tcr->save_allocptr = (void *)(VOID_ALLOCPTR - disp);
      } else {
        /* Back out, and tell the caller how to resume the allocation attempt */
        *interrupt_displacement = disp;
        xpGPR(xp,Iallocptr) = VOID_ALLOCPTR;
        tcr->save_allocptr += disp;
        xpPC(xp) -= (sizeof(branch_around_alloc_trap_instruction)+
                     sizeof(compare_allocptr_reg_to_tcr_save_allocbase_instruction) +
                     sizeof(load_allocptr_reg_from_tcr_save_allocptr_instruction));
      }
      break;
    case ID_branch_around_alloc_trap_instruction:
      /* If we'd take the branch - which is a 'jg" - around the alloc trap,
         we might as well finish the allocation.  Otherwise, back out of the
         attempt. */
      {
        int flags = (int)xpGPR(xp,Iflags);
        
        if ((!(flags & (1 << X86_ZERO_FLAG_BIT))) &&
            ((flags & (1 << X86_SIGN_FLAG_BIT)) ==
             (flags & (1 << X86_CARRY_FLAG_BIT)))) {
          /* The branch (jg) would have been taken.  Emulate taking it. */
          xpPC(xp) += (sizeof(branch_around_alloc_trap_instruction)+
                       sizeof(alloc_trap_instruction));
          if (allocptr_tag == fulltag_misc) {
            /* Slap the header on the new uvector */
            new_vector = xpGPR(xp,Iallocptr);
            deref(new_vector,0) = xpGPR(xp,Iimm0);
            xpPC(xp) += sizeof(set_allocptr_header_instruction);
          }
          tcr->save_allocptr = (void *)(((LispObj)tcr->save_allocptr) & ~fulltagmask);
          xpPC(xp) += sizeof(clear_tcr_save_allocptr_tag_instruction);
        } else {
          /* Back up */
          xpPC(xp) -= (sizeof(compare_allocptr_reg_to_tcr_save_allocbase_instruction) +
                       sizeof(load_allocptr_reg_from_tcr_save_allocptr_instruction));
          xpGPR(xp,Iallocptr) = VOID_ALLOCPTR;
          if (interrupt_displacement) {
            *interrupt_displacement = disp;
            tcr->save_allocptr += disp;
          } else {
            tcr->save_allocptr = (void *)(VOID_ALLOCPTR-disp);
          }
        }
      }
      break;
    case ID_compare_allocptr_reg_to_tcr_save_allocbase_instruction:
      xpGPR(xp,Iallocptr) = VOID_ALLOCPTR;
      xpPC(xp) -= sizeof(load_allocptr_reg_from_tcr_save_allocptr_instruction);
      /* Fall through */
    case ID_load_allocptr_reg_from_tcr_save_allocptr_instruction:
      if (interrupt_displacement) {
        tcr->save_allocptr += disp;
        *interrupt_displacement = disp;
      } else {
        tcr->save_allocptr = (void *)(VOID_ALLOCPTR-disp);
      }
      break;
    }
    return;
  }
  if ((program_counter >= &egc_write_barrier_start) &&
      (program_counter < &egc_write_barrier_end)) {
    LispObj *ea = 0, val, root;
    bitvector refbits = (bitvector)(lisp_global(REFBITS));
    Boolean need_store = true, need_check_memo = true, need_memoize_root = false;

    if (program_counter >= &egc_store_node_conditional) {
      if ((program_counter < &egc_store_node_conditional_success_test) ||
          ((program_counter == &egc_store_node_conditional_success_test) &&
           !(xpGPR(xp, Iflags) & (1 << X86_ZERO_FLAG_BIT)))) {
        /* Back up the PC, try again */
        xpPC(xp) = (LispObj) &egc_store_node_conditional;
        return;
      }
      /* The conditional store succeeded.  Set the refbit, return to ra0 */
      val = xpGPR(xp,Iarg_z);
      ea = (LispObj*)(xpGPR(xp,Iarg_x) + (unbox_fixnum((signed_natural)
                                                       xpGPR(xp,Itemp0))));
      xpGPR(xp,Iarg_z) = t_value;
      need_store = false;
    } else if (program_counter >= &egc_set_hash_key) {
      root = xpGPR(xp,Iarg_x);
      ea = (LispObj *) (root+xpGPR(xp,Iarg_y)+misc_data_offset);
      val = xpGPR(xp,Iarg_z);
      need_memoize_root = true;
    } else if (program_counter >= &egc_gvset) {
      ea = (LispObj *) (xpGPR(xp,Iarg_x)+xpGPR(xp,Iarg_y)+misc_data_offset);
      val = xpGPR(xp,Iarg_z);
    } else if (program_counter >= &egc_rplacd) {
      ea = (LispObj *) untag(xpGPR(xp,Iarg_y));
      val = xpGPR(xp,Iarg_z);
    } else {                      /* egc_rplaca */
      ea =  ((LispObj *) untag(xpGPR(xp,Iarg_y)))+1;
      val = xpGPR(xp,Iarg_z);
    }
    if (need_store) {
      *ea = val;
    }
    if (need_check_memo) {
      natural  bitnumber = area_dnode(ea, lisp_global(HEAP_START));
      if ((bitnumber < lisp_global(OLDSPACE_DNODE_COUNT)) &&
          ((LispObj)ea < val)) {
        atomic_set_bit(refbits, bitnumber);
        if (need_memoize_root) {
          bitnumber = area_dnode(root, lisp_global(HEAP_START));
          atomic_set_bit(refbits, bitnumber);
        }
      }
    }
    xpPC(xp) = xpGPR(xp,Ira0);
    return;
  }
}

void
normalize_tcr(ExceptionInformation *xp, TCR *tcr, Boolean is_other_tcr)
{
  void *cur_allocptr = (void *)(tcr->save_allocptr);
  LispObj lisprsp, lisptsp;
  area *a;

  if (xp) {
    if (is_other_tcr) {
      pc_luser_xp(xp, tcr, NULL);
    }
    a = tcr->vs_area;
    lisprsp = xpGPR(xp, Isp);
    if (((BytePtr)lisprsp >= a->low) &&
	((BytePtr)lisprsp < a->high)) {
      a->active = (BytePtr)lisprsp;
    } else {
      a->active = (BytePtr) tcr->save_vsp;
    }
    a = tcr->ts_area;
    a->active = (BytePtr) tcr->save_tsp;
  } else {
    /* In ff-call; get area active pointers from tcr */
    tcr->vs_area->active = (BytePtr) tcr->save_vsp;
    tcr->ts_area->active = (BytePtr) tcr->save_tsp;
  }
  if (cur_allocptr) {
    update_bytes_allocated(tcr, cur_allocptr);
  }
  tcr->save_allocbase = (void *)VOID_ALLOCPTR;
  if (fulltag_of((LispObj)(tcr->save_allocptr)) == 0) {
    tcr->save_allocptr = (void *)VOID_ALLOCPTR;
  }
}


/* Suspend and "normalize" other tcrs, then call a gc-like function
   in that context.  Resume the other tcrs, then return what the
   function returned */

TCR *gc_tcr = NULL;


int
gc_like_from_xp(ExceptionInformation *xp, 
                int(*fun)(TCR *, signed_natural), 
                signed_natural param)
{
  TCR *tcr = get_tcr(false), *other_tcr;
  ExceptionInformation* other_xp;
  int result;
  signed_natural inhibit;

  suspend_other_threads(true);
  inhibit = (signed_natural)(lisp_global(GC_INHIBIT_COUNT));
  if (inhibit != 0) {
    if (inhibit > 0) {
      lisp_global(GC_INHIBIT_COUNT) = (LispObj)(-inhibit);
    }
    resume_other_threads(true);
    gc_deferred++;
    return 0;
  }
  gc_deferred = 0;

  gc_tcr = tcr;

  /* This is generally necessary if the current thread invoked the GC
     via an alloc trap, and harmless if the GC was invoked via a GC
     trap.  (It's necessary in the first case because the "allocptr"
     register - %rbx - may be pointing into the middle of something
     below tcr->save_allocbase, and we wouldn't want the GC to see
     that bogus pointer.) */
  xpGPR(xp, Iallocptr) = VOID_ALLOCPTR; 

  normalize_tcr(xp, tcr, false);


  for (other_tcr = tcr->next; other_tcr != tcr; other_tcr = other_tcr->next) {
    if (other_tcr->pending_exception_context) {
      other_tcr->gc_context = other_tcr->pending_exception_context;
    } else if (other_tcr->valence == TCR_STATE_LISP) {
      other_tcr->gc_context = other_tcr->suspend_context;
    } else {
      /* no pending exception, didn't suspend in lisp state:
	 must have executed a synchronous ff-call. 
      */
      other_tcr->gc_context = NULL;
    }
    normalize_tcr(other_tcr->gc_context, other_tcr, true);
  }
    


  result = fun(tcr, param);

  other_tcr = tcr;
  do {
    other_tcr->gc_context = NULL;
    other_tcr = other_tcr->next;
  } while (other_tcr != tcr);

  gc_tcr = NULL;

  resume_other_threads(true);

  return result;

}

int
change_hons_area_size_from_xp(ExceptionInformation *xp, signed_natural delta_in_bytes)
{
  return gc_like_from_xp(xp, change_hons_area_size, delta_in_bytes);
}

int
purify_from_xp(ExceptionInformation *xp, signed_natural param)
{
  return gc_like_from_xp(xp, purify, param);
}

int
impurify_from_xp(ExceptionInformation *xp, signed_natural param)
{
  return gc_like_from_xp(xp, impurify, param);
}

/* Returns #bytes freed by invoking GC */

int
gc_from_tcr(TCR *tcr, signed_natural param)
{
  area *a;
  BytePtr oldfree, newfree;
  BytePtr oldend, newend;

#if 0
  fprintf(stderr, "Start GC  in 0x%lx\n", tcr);
#endif
  a = active_dynamic_area;
  oldend = a->high;
  oldfree = a->active;
  gc(tcr, param);
  newfree = a->active;
  newend = a->high;
#if 0
  fprintf(stderr, "End GC  in 0x%lx\n", tcr);
#endif
  return ((oldfree-newfree)+(newend-oldend));
}

int
gc_from_xp(ExceptionInformation *xp, signed_natural param)
{
  int status = gc_like_from_xp(xp, gc_from_tcr, param);

  freeGCptrs();
  return status;
}

#ifdef DARWIN

#define TCR_FROM_EXCEPTION_PORT(p) ((TCR *)((natural)p))
#define TCR_TO_EXCEPTION_PORT(tcr) ((mach_port_t)((natural)(tcr)))

pthread_mutex_t _mach_exception_lock, *mach_exception_lock;
extern void pseudo_sigreturn(void);



#define LISP_EXCEPTIONS_HANDLED_MASK \
 (EXC_MASK_SOFTWARE | EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION | EXC_MASK_ARITHMETIC)

/* (logcount LISP_EXCEPTIONS_HANDLED_MASK) */
#define NUM_LISP_EXCEPTIONS_HANDLED 4 

typedef struct {
  int foreign_exception_port_count;
  exception_mask_t         masks[NUM_LISP_EXCEPTIONS_HANDLED];
  mach_port_t              ports[NUM_LISP_EXCEPTIONS_HANDLED];
  exception_behavior_t behaviors[NUM_LISP_EXCEPTIONS_HANDLED];
  thread_state_flavor_t  flavors[NUM_LISP_EXCEPTIONS_HANDLED];
} MACH_foreign_exception_state;




/*
  Mach's exception mechanism works a little better than its signal
  mechanism (and, not incidentally, it gets along with GDB a lot
  better.

  Initially, we install an exception handler to handle each native
  thread's exceptions.  This process involves creating a distinguished
  thread which listens for kernel exception messages on a set of
  0 or more thread exception ports.  As threads are created, they're
  added to that port set; a thread's exception port is destroyed
  (and therefore removed from the port set) when the thread exits.

  A few exceptions can be handled directly in the handler thread;
  others require that we resume the user thread (and that the
  exception thread resumes listening for exceptions.)  The user
  thread might eventually want to return to the original context
  (possibly modified somewhat.)

  As it turns out, the simplest way to force the faulting user
  thread to handle its own exceptions is to do pretty much what
  signal() does: the exception handlng thread sets up a sigcontext
  on the user thread's stack and forces the user thread to resume
  execution as if a signal handler had been called with that
  context as an argument.  We can use a distinguished UUO at a
  distinguished address to do something like sigreturn(); that'll
  have the effect of resuming the user thread's execution in
  the (pseudo-) signal context.

  Since:
    a) we have miles of code in C and in Lisp that knows how to
    deal with Linux sigcontexts
    b) Linux sigcontexts contain a little more useful information
    (the DAR, DSISR, etc.) than their Darwin counterparts
    c) we have to create a sigcontext ourselves when calling out
    to the user thread: we aren't really generating a signal, just
    leveraging existing signal-handling code.

  we create a Linux sigcontext struct.

  Simple ?  Hopefully from the outside it is ...

  We want the process of passing a thread's own context to it to
  appear to be atomic: in particular, we don't want the GC to suspend
  a thread that's had an exception but has not yet had its user-level
  exception handler called, and we don't want the thread's exception
  context to be modified by a GC while the Mach handler thread is
  copying it around.  On Linux (and on Jaguar), we avoid this issue
  because (a) the kernel sets up the user-level signal handler and
  (b) the signal handler blocks signals (including the signal used
  by the GC to suspend threads) until tcr->xframe is set up.

  The GC and the Mach server thread therefore contend for the lock
  "mach_exception_lock".  The Mach server thread holds the lock
  when copying exception information between the kernel and the
  user thread; the GC holds this lock during most of its execution
  (delaying exception processing until it can be done without
  GC interference.)

*/

#ifdef PPC64
#define	C_REDZONE_LEN		320
#define	C_STK_ALIGN             32
#else
#define	C_REDZONE_LEN		224
#define	C_STK_ALIGN		16
#endif
#define C_PARAMSAVE_LEN		64
#define	C_LINKAGE_LEN		48

#define TRUNC_DOWN(a,b,c)  (((((natural)a)-(b))/(c)) * (c))

void
fatal_mach_error(char *format, ...);

#define MACH_CHECK_ERROR(context,x) if (x != KERN_SUCCESS) {fatal_mach_error("Mach error while %s : %d", context, x);}


void
restore_mach_thread_state(mach_port_t thread, ExceptionInformation *pseudosigcontext)
{
  int i, j;
  kern_return_t kret;
#if WORD_SIZE == 64
  MCONTEXT_T mc = UC_MCONTEXT(pseudosigcontext);
#else
  struct mcontext * mc = UC_MCONTEXT(pseudosigcontext);
#endif

  /* Set the thread's FP state from the pseudosigcontext */
  kret = thread_set_state(thread,
                          x86_FLOAT_STATE64,
                          (thread_state_t)&(mc->__fs),
                          x86_FLOAT_STATE64_COUNT);

  MACH_CHECK_ERROR("setting thread FP state", kret);

  /* The thread'll be as good as new ... */
#if WORD_SIZE == 64
  kret = thread_set_state(thread,
                          x86_THREAD_STATE64,
                          (thread_state_t)&(mc->__ss),
                          x86_THREAD_STATE64_COUNT);
#else
  kret = thread_set_state(thread, 
                          x86_THREAD_STATE32,
                          (thread_state_t)&(mc->__ss),
                          x86_THREAD_STATE32_COUNT);
#endif
  MACH_CHECK_ERROR("setting thread state", kret);
}  

/* This code runs in the exception handling thread, in response
   to an attempt to execute the UU0 at "pseudo_sigreturn" (e.g.,
   in response to a call to pseudo_sigreturn() from the specified
   user thread.
   Find that context (the user thread's R3 points to it), then
   use that context to set the user thread's state.  When this
   function's caller returns, the Mach kernel will resume the
   user thread.
*/

kern_return_t
do_pseudo_sigreturn(mach_port_t thread, TCR *tcr)
{
  ExceptionInformation *xp;

#ifdef DEBUG_MACH_EXCEPTIONS
  fprintf(stderr, "doing pseudo_sigreturn for 0x%x\n",tcr);
#endif
  xp = tcr->pending_exception_context;
  if (xp) {
    tcr->pending_exception_context = NULL;
    tcr->valence = TCR_STATE_LISP;
    restore_mach_thread_state(thread, xp);
    raise_pending_interrupt(tcr);
  } else {
    Bug(NULL, "no xp here!\n");
  }
#ifdef DEBUG_MACH_EXCEPTIONS
  fprintf(stderr, "did pseudo_sigreturn for 0x%x\n",tcr);
#endif
  return KERN_SUCCESS;
}  

ExceptionInformation *
create_thread_context_frame(mach_port_t thread, 
			    natural *new_stack_top,
                            siginfo_t **info_ptr,
                            TCR *tcr,
#ifdef X8664
                            x86_thread_state64_t *ts
#else
                            x86_thread_state_t *ts
#endif
                            )
{
  mach_msg_type_number_t thread_state_count;
  kern_return_t result;
  int i,j;
  ExceptionInformation *pseudosigcontext;
#ifdef X8664
  MCONTEXT_T mc;
#else
  struct mcontext *mc;
#endif
  natural stackp, backlink;

  
  stackp = (LispObj) find_foreign_rsp(ts->__rsp,tcr->cs_area,tcr);
  stackp = TRUNC_DOWN(stackp, C_REDZONE_LEN, C_STK_ALIGN);
  stackp = TRUNC_DOWN(stackp, sizeof(siginfo_t), C_STK_ALIGN);
  if (info_ptr) {
    *info_ptr = (siginfo_t *)stackp;
  }
  stackp = TRUNC_DOWN(stackp,sizeof(*pseudosigcontext), C_STK_ALIGN);
  pseudosigcontext = (ExceptionInformation *) ptr_from_lispobj(stackp);

  stackp = TRUNC_DOWN(stackp, sizeof(*mc), C_STK_ALIGN);
#ifdef X8664
  mc = (MCONTEXT_T) ptr_from_lispobj(stackp);
#else
  mc = (struct mcontext *) ptr_from_lispobj(stackp);
#endif
  
  bcopy(ts,&(mc->__ss),sizeof(*ts));

  thread_state_count = x86_FLOAT_STATE64_COUNT;
  thread_get_state(thread,
		   x86_FLOAT_STATE64,
		   (thread_state_t)&(mc->__fs),
		   &thread_state_count);


#ifdef X8664
  thread_state_count = x86_EXCEPTION_STATE64_COUNT;
#else
  thread_state_count = x86_EXCEPTION_STATE_COUNT;
#endif
  thread_get_state(thread,
#ifdef X8664
                   x86_EXCEPTION_STATE64,
#else
		   x86_EXCEPTION_STATE,
#endif
		   (thread_state_t)&(mc->__es),
		   &thread_state_count);


  UC_MCONTEXT(pseudosigcontext) = mc;
  if (new_stack_top) {
    *new_stack_top = stackp;
  }
  return pseudosigcontext;
}

/*
  This code sets up the user thread so that it executes a "pseudo-signal
  handler" function when it resumes.  Create a fake ucontext struct
  on the thread's stack and pass it as an argument to the pseudo-signal
  handler.

  Things are set up so that the handler "returns to" pseudo_sigreturn(),
  which will restore the thread's context.

  If the handler invokes code that throws (or otherwise never sigreturn()'s
  to the context), that's fine.

  Actually, check that: throw (and variants) may need to be careful and
  pop the tcr's xframe list until it's younger than any frame being
  entered.
*/

int
setup_signal_frame(mach_port_t thread,
		   void *handler_address,
		   int signum,
                   int code,
		   TCR *tcr,
#ifdef X8664
                   x86_thread_state64_t *ts
#else
                   x86_thread_state_t *ts
#endif
                   )
{
#ifdef X8664
  x86_thread_state64_t new_ts;
#else
  x86_thread_state_t new_ts;
#endif
  ExceptionInformation *pseudosigcontext;
  int i, j, old_valence = tcr->valence;
  kern_return_t result;
  natural stackp, *stackpp;
  siginfo_t *info;

#ifdef DEBUG_MACH_EXCEPTIONS
  fprintf(stderr,"Setting up exception handling for 0x%x\n", tcr);
#endif
  pseudosigcontext = create_thread_context_frame(thread, &stackp, &info, tcr,  ts);
  bzero(info, sizeof(*info));
  info->si_code = code;
  info->si_addr = (void *)(UC_MCONTEXT(pseudosigcontext)->__es.__faultvaddr);
  info->si_signo = signum;
  pseudosigcontext->uc_onstack = 0;
  pseudosigcontext->uc_sigmask = (sigset_t) 0;
  pseudosigcontext->uc_stack.ss_sp = 0;
  pseudosigcontext->uc_stack.ss_size = 0;
  pseudosigcontext->uc_stack.ss_flags = 0;
  pseudosigcontext->uc_link = NULL;
  pseudosigcontext->uc_mcsize = sizeof(*UC_MCONTEXT(pseudosigcontext));
  tcr->pending_exception_context = pseudosigcontext;
  tcr->valence = TCR_STATE_EXCEPTION_WAIT;
  

  /* 
     It seems like we've created a  sigcontext on the thread's
     stack.  Set things up so that we call the handler (with appropriate
     args) when the thread's resumed.
  */

  new_ts.__rip = (natural) handler_address;
  stackpp = (natural *)stackp;
  *--stackpp = (natural)pseudo_sigreturn;
  stackp = (natural)stackpp;
  new_ts.__rdi = signum;
  new_ts.__rsi = (natural)info;
  new_ts.__rdx = (natural)pseudosigcontext;
  new_ts.__rcx = (natural)tcr;
  new_ts.__r8 = (natural)old_valence;
  new_ts.__rsp = stackp;
  new_ts.__rflags = ts->__rflags;


#ifdef X8664
  thread_set_state(thread,
                   x86_THREAD_STATE64,
                   (thread_state_t)&new_ts,
                   x86_THREAD_STATE64_COUNT);
#else
  thread_set_state(thread, 
		   x86_THREAD_STATE,
		   (thread_state_t)&new_ts,
		   x86_THREAD_STATE_COUNT);
#endif
#ifdef DEBUG_MACH_EXCEPTIONS
  fprintf(stderr,"Set up exception context for 0x%x at 0x%x\n", tcr, tcr->pending_exception_context);
#endif
  return 0;
}






/*
  This function runs in the exception handling thread.  It's
  called (by this precise name) from the library function "exc_server()"
  when the thread's exception ports are set up.  (exc_server() is called
  via mach_msg_server(), which is a function that waits for and dispatches
  on exception messages from the Mach kernel.)

  This checks to see if the exception was caused by a pseudo_sigreturn()
  UUO; if so, it arranges for the thread to have its state restored
  from the specified context.

  Otherwise, it tries to map the exception to a signal number and
  arranges that the thread run a "pseudo signal handler" to handle
  the exception.

  Some exceptions could and should be handled here directly.
*/

/* We need the thread's state earlier on x86_64 than we did on PPC;
   the PC won't fit in code_vector[1].  We shouldn't try to get it
   lazily (via catch_exception_raise_state()); until we own the
   exception lock, we shouldn't have it in userspace (since a GCing
   thread wouldn't know that we had our hands on it.)
*/

#ifdef X8664
#define ts_pc(t) t.__rip
#else
#define ts_pc(t) t.eip
#endif

#ifdef DARWIN_USE_PSEUDO_SIGRETURN
#define DARWIN_EXCEPTION_HANDLER signal_handler
#else
#define DARWIN_EXCEPTION_HANDLER pseudo_signal_handler
#endif

kern_return_t
catch_exception_raise(mach_port_t exception_port,
		      mach_port_t thread,
		      mach_port_t task, 
		      exception_type_t exception,
		      exception_data_t code_vector,
		      mach_msg_type_number_t code_count)
{
  int signum = 0, code = *code_vector, code1;
  TCR *tcr = TCR_FROM_EXCEPTION_PORT(exception_port);
  kern_return_t kret, call_kret;
#ifdef X8664
  x86_thread_state64_t ts;
#else
  x86_thread_state_t ts;
#endif
  mach_msg_type_number_t thread_state_count;


#ifdef DEBUG_MACH_EXCEPTIONS
  fprintf(stderr, "obtaining Mach exception lock in exception thread\n");
#endif


  if (pthread_mutex_trylock(mach_exception_lock) == 0) {
#ifdef X8664
    thread_state_count = x86_THREAD_STATE64_COUNT;
    call_kret = thread_get_state(thread,
                                 x86_THREAD_STATE64,
                                 (thread_state_t)&ts,
                     &thread_state_count);
  MACH_CHECK_ERROR("getting thread state",call_kret);
#else
    thread_state_count = x86_THREAD_STATE_COUNT;
    thread_get_state(thread,
                     x86_THREAD_STATE,
                     (thread_state_t)&ts,
                     &thread_state_count);
#endif
    if (tcr->flags & (1<<TCR_FLAG_BIT_PENDING_EXCEPTION)) {
      CLR_TCR_FLAG(tcr,TCR_FLAG_BIT_PENDING_EXCEPTION);
    } 
    if ((code == EXC_I386_GPFLT) &&
        ((natural)(ts_pc(ts)) == (natural)pseudo_sigreturn)) {
      kret = do_pseudo_sigreturn(thread, tcr);
#if 0
      fprintf(stderr, "Exception return in 0x%x\n",tcr);
#endif
    } else if (tcr->flags & (1<<TCR_FLAG_BIT_PROPAGATE_EXCEPTION)) {
      CLR_TCR_FLAG(tcr,TCR_FLAG_BIT_PROPAGATE_EXCEPTION);
      kret = 17;
    } else {
      switch (exception) {
      case EXC_BAD_ACCESS:
        if (code == EXC_I386_GPFLT) {
          signum = SIGSEGV;
        } else {
          signum = SIGBUS;
        }
        break;
        
      case EXC_BAD_INSTRUCTION:
        if (code == EXC_I386_GPFLT) {
          signum = SIGSEGV;
        } else {
          signum = SIGILL;
        }
        break;
      
      case EXC_SOFTWARE:
          signum = SIGILL;
        break;
      
      case EXC_ARITHMETIC:
        signum = SIGFPE;
        break;

      default:
        break;
      }
      if (signum) {
        kret = setup_signal_frame(thread,
                                  (void *)DARWIN_EXCEPTION_HANDLER,
                                  signum,
                                  code,
                                  tcr, 
                                  &ts);
#if 0
      fprintf(stderr, "Setup pseudosignal handling in 0x%x\n",tcr);
#endif

      } else {
        kret = 17;
      }
    }
#ifdef DEBUG_MACH_EXCEPTIONS
    fprintf(stderr, "releasing Mach exception lock in exception thread\n");
#endif
    pthread_mutex_unlock(mach_exception_lock);
  } else {
    SET_TCR_FLAG(tcr,TCR_FLAG_BIT_PENDING_EXCEPTION);
      
#if 0
    fprintf(stderr, "deferring pending exception in 0x%x\n", tcr);
#endif
    kret = 0;
    if (tcr == gc_tcr) {
      int i;
      write(1, "exception in GC thread. Sleeping for 60 seconds\n",sizeof("exception in GC thread.  Sleeping for 60 seconds\n"));
      for (i = 0; i < 60; i++) {
        sleep(1);
      }
      _exit(EX_SOFTWARE);
    }
  }
  return kret;
}




static mach_port_t mach_exception_thread = (mach_port_t)0;


/*
  The initial function for an exception-handling thread.
*/

void *
exception_handler_proc(void *arg)
{
  extern boolean_t exc_server();
  mach_port_t p = TCR_TO_EXCEPTION_PORT(arg);

  mach_exception_thread = pthread_mach_thread_np(pthread_self());
  mach_msg_server(exc_server, 256, p, 0);
  /* Should never return. */
  abort();
}



void
mach_exception_thread_shutdown()
{
  kern_return_t kret;

  fprintf(stderr, "terminating Mach exception thread, 'cause exit can't\n");
  kret = thread_terminate(mach_exception_thread);
  if (kret != KERN_SUCCESS) {
    fprintf(stderr, "Couldn't terminate exception thread, kret = %d\n",kret);
  }
}


mach_port_t
mach_exception_port_set()
{
  static mach_port_t __exception_port_set = MACH_PORT_NULL;
  kern_return_t kret;  
  if (__exception_port_set == MACH_PORT_NULL) {
    mach_exception_lock = &_mach_exception_lock;
    pthread_mutex_init(mach_exception_lock, NULL);

    kret = mach_port_allocate(mach_task_self(),
			      MACH_PORT_RIGHT_PORT_SET,
			      &__exception_port_set);
    MACH_CHECK_ERROR("allocating thread exception_ports",kret);
    create_system_thread(0,
                         NULL,
                         exception_handler_proc, 
                         (void *)((natural)__exception_port_set));
  }
  return __exception_port_set;
}

/*
  Setup a new thread to handle those exceptions specified by
  the mask "which".  This involves creating a special Mach
  message port, telling the Mach kernel to send exception
  messages for the calling thread to that port, and setting
  up a handler thread which listens for and responds to
  those messages.

*/

/*
  Establish the lisp thread's TCR as its exception port, and determine
  whether any other ports have been established by foreign code for
  exceptions that lisp cares about.

  If this happens at all, it should happen on return from foreign
  code and on entry to lisp code via a callback.

  This is a lot of trouble (and overhead) to support Java, or other
  embeddable systems that clobber their caller's thread exception ports.
  
*/
kern_return_t
tcr_establish_exception_port(TCR *tcr, mach_port_t thread)
{
  kern_return_t kret;
  MACH_foreign_exception_state *fxs = (MACH_foreign_exception_state *)tcr->native_thread_info;
  int i;
  unsigned n = NUM_LISP_EXCEPTIONS_HANDLED;
  mach_port_t lisp_port = TCR_TO_EXCEPTION_PORT(tcr), foreign_port;
  exception_mask_t mask = 0;

  kret = thread_swap_exception_ports(thread,
				     LISP_EXCEPTIONS_HANDLED_MASK,
				     lisp_port,
				     EXCEPTION_DEFAULT,
				     THREAD_STATE_NONE,
				     fxs->masks,
				     &n,
				     fxs->ports,
				     fxs->behaviors,
				     fxs->flavors);
  if (kret == KERN_SUCCESS) {
    fxs->foreign_exception_port_count = n;
    for (i = 0; i < n; i ++) {
      foreign_port = fxs->ports[i];

      if ((foreign_port != lisp_port) &&
	  (foreign_port != MACH_PORT_NULL)) {
	mask |= fxs->masks[i];
      }
    }
    tcr->foreign_exception_status = (int) mask;
  }
  return kret;
}

kern_return_t
tcr_establish_lisp_exception_port(TCR *tcr)
{
  return tcr_establish_exception_port(tcr, (mach_port_t)((natural)tcr->native_thread_id));
}

/*
  Do this when calling out to or returning from foreign code, if
  any conflicting foreign exception ports were established when we
  last entered lisp code.
*/
kern_return_t
restore_foreign_exception_ports(TCR *tcr)
{
  exception_mask_t m = (exception_mask_t) tcr->foreign_exception_status;
  
  if (m) {
    MACH_foreign_exception_state *fxs  = 
      (MACH_foreign_exception_state *) tcr->native_thread_info;
    int i, n = fxs->foreign_exception_port_count;
    exception_mask_t tm;

    for (i = 0; i < n; i++) {
      if ((tm = fxs->masks[i]) & m) {
	thread_set_exception_ports((mach_port_t)((natural)tcr->native_thread_id),
				   tm,
				   fxs->ports[i],
				   fxs->behaviors[i],
				   fxs->flavors[i]);
      }
    }
  }
}
				   

/*
  This assumes that a Mach port (to be used as the thread's exception port) whose
  "name" matches the TCR's 32-bit address has already been allocated.
*/

kern_return_t
setup_mach_exception_handling(TCR *tcr)
{
  mach_port_t 
    thread_exception_port = TCR_TO_EXCEPTION_PORT(tcr),
    target_thread = pthread_mach_thread_np((pthread_t)ptr_from_lispobj(tcr->osid)),
    task_self = mach_task_self();
  kern_return_t kret;

  kret = mach_port_insert_right(task_self,
				thread_exception_port,
				thread_exception_port,
				MACH_MSG_TYPE_MAKE_SEND);
  MACH_CHECK_ERROR("adding send right to exception_port",kret);

  kret = tcr_establish_exception_port(tcr, (mach_port_t)((natural) tcr->native_thread_id));
  if (kret == KERN_SUCCESS) {
    mach_port_t exception_port_set = mach_exception_port_set();

    kret = mach_port_move_member(task_self,
				 thread_exception_port,
				 exception_port_set);
  }
  return kret;
}

void
darwin_exception_init(TCR *tcr)
{
  void tcr_monitor_exception_handling(TCR*, Boolean);
  kern_return_t kret;
  MACH_foreign_exception_state *fxs = 
    calloc(1, sizeof(MACH_foreign_exception_state));
  
  tcr->native_thread_info = (void *) fxs;

  if ((kret = setup_mach_exception_handling(tcr))
      != KERN_SUCCESS) {
    fprintf(stderr, "Couldn't setup exception handler - error = %d\n", kret);
    terminate_lisp();
  }
  lisp_global(LISP_EXIT_HOOK) = (LispObj) restore_foreign_exception_ports;
  lisp_global(LISP_RETURN_HOOK) = (LispObj) tcr_establish_lisp_exception_port;
}

/*
  The tcr is the "name" of the corresponding thread's exception port.
  Destroying the port should remove it from all port sets of which it's
  a member (notably, the exception port set.)
*/
void
darwin_exception_cleanup(TCR *tcr)
{
  void *fxs = tcr->native_thread_info;
  extern Boolean use_mach_exception_handling;

  if (fxs) {
    tcr->native_thread_info = NULL;
    free(fxs);
  }
  if (use_mach_exception_handling) {
    mach_port_deallocate(mach_task_self(),TCR_TO_EXCEPTION_PORT(tcr));
    mach_port_destroy(mach_task_self(),TCR_TO_EXCEPTION_PORT(tcr));
  }
}


Boolean
suspend_mach_thread(mach_port_t mach_thread)
{
  kern_return_t status;
  Boolean aborted = false;
  
  do {
    aborted = false;
    status = thread_suspend(mach_thread);
    if (status == KERN_SUCCESS) {
      status = thread_abort_safely(mach_thread);
      if (status == KERN_SUCCESS) {
        aborted = true;
      } else {
        fprintf(stderr, "abort failed on thread = 0x%x\n",mach_thread);
        thread_resume(mach_thread);
      }
    } else {
      return false;
    }
  } while (! aborted);
  return true;
}

/*
  Only do this if pthread_kill indicated that the pthread isn't
  listening to signals anymore, as can happen as soon as pthread_exit()
  is called on Darwin.  The thread could still call out to lisp as it
  is exiting, so we need another way to suspend it in this case.
*/
Boolean
mach_suspend_tcr(TCR *tcr)
{
  mach_port_t mach_thread = (mach_port_t)((natural)( tcr->native_thread_id));
  ExceptionInformation *pseudosigcontext;
  Boolean result = false;
  
  result = suspend_mach_thread(mach_thread);
  if (result) {
    mach_msg_type_number_t thread_state_count;
#ifdef X8664
    x86_thread_state64_t ts;
    thread_state_count = x86_THREAD_STATE64_COUNT;
    thread_get_state(mach_thread,
                     x86_THREAD_STATE64,
                     (thread_state_t)&ts,
                     &thread_state_count);
#else
    x86_thread_state_t ts;
    thread_state_count = x86_THREAD_STATE_COUNT;
    thread_get_state(mach_thread,
                     x86_THREAD_STATE,
                     (thread_state_t)&ts,
                     &thread_state_count);
#endif

    pseudosigcontext = create_thread_context_frame(mach_thread, NULL, NULL,tcr, &ts);
    pseudosigcontext->uc_onstack = 0;
    pseudosigcontext->uc_sigmask = (sigset_t) 0;
    tcr->suspend_context = pseudosigcontext;
  }
  return result;
}

void
mach_resume_tcr(TCR *tcr)
{
  ExceptionInformation *xp;
  mach_port_t mach_thread = (mach_port_t)((natural)(tcr->native_thread_id));
  
  xp = tcr->suspend_context;
#ifdef DEBUG_MACH_EXCEPTIONS
  fprintf(stderr, "resuming TCR 0x%x, pending_exception_context = 0x%x\n",
          tcr, tcr->pending_exception_context);
#endif
  tcr->suspend_context = NULL;
  restore_mach_thread_state(mach_thread, xp);
#ifdef DEBUG_MACH_EXCEPTIONS
  fprintf(stderr, "restored state in TCR 0x%x, pending_exception_context = 0x%x\n",
          tcr, tcr->pending_exception_context);
#endif
  thread_resume(mach_thread);
}

void
fatal_mach_error(char *format, ...)
{
  va_list args;
  char s[512];
 

  va_start(args, format);
  vsnprintf(s, sizeof(s),format, args);
  va_end(args);

  Fatal("Mach error", s);
}




#endif
