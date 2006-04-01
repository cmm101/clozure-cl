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
#include <fpu_control.h>
#include <linux/prctl.h>
#endif


#include <sys/mman.h>

void
allocation_failure(Boolean pointerp, natural size)
{
  char buf[64];
  sprintf(buf, "Can't allocate %s of size %d bytes.", pointerp ? "pointer" : "handle", size);
  Fatal(":   Kernel memory allocation failure.  ", buf);
}

void
fatal_oserr(StringPtr param, OSErr err)
{
  char buf[64];
  sprintf(buf," - operating system error %d.", err);
  Fatal(param, buf);
}


Ptr
allocate(natural size)
{
  return (Ptr) malloc(size);
}

void
deallocate(Ptr p)
{
  free((void *)p);
}

Ptr
zalloc(natural size)
{
  Ptr p = allocate(size);
  if (p != NULL) {
    memset(p, 0, size);
  }
  return p;
}

int
ProtectMemory(LogicalAddress addr, int nbytes)
{
  int status = mprotect(addr, nbytes, PROT_READ | PROT_EXEC);
  
  if (status) {
    status = errno;
    Bug(NULL, "couldn't protect %d bytes at %x, errno = %d", nbytes, addr, status);
  }
  return status;
}

int
UnProtectMemory(LogicalAddress addr, int nbytes)
{
  return mprotect(addr, nbytes, PROT_READ|PROT_WRITE|PROT_EXEC);
}

void
unprotect_area(protected_area_ptr p)
{
  BytePtr start = p->start;
  natural nprot = p->nprot;
  
  if (nprot) {
    UnProtectMemory(start, nprot);
    p->nprot = 0;
  }
}

protected_area_ptr
new_protected_area(BytePtr start, BytePtr end, lisp_protection_kind reason, natural protsize, Boolean now)
{
  protected_area_ptr p = (protected_area_ptr) allocate(sizeof(protected_area));
  
  if (p == NULL) return NULL;
  p->protsize = protsize;
  p->nprot = 0;
  p->start = start;
  p->end = end;
  p->why = reason;
  p->next = AllProtectedAreas;

  AllProtectedAreas = p;
  if (now) {
    protect_area(p);
  }
  
  return p;
}

/*
  Un-protect the first nbytes bytes in specified area.
  Note that this may cause the area to be empty.
*/
void
unprotect_area_prefix(protected_area_ptr area, size_t delta)
{
  unprotect_area(area);
  area->start += delta;
  if ((area->start + area->protsize) <= area->end) {
    protect_area(area);
  }
}


/*
  Extend the protected area, causing the preceding nbytes bytes
  to be included and protected.
*/
void
protect_area_prefix(protected_area_ptr area, size_t delta)
{
  unprotect_area(area);
  area->start -= delta;
  protect_area(area);
}

protected_area_ptr
AllProtectedAreas = NULL;


/* 
  This does a linear search.  Areas aren't created all that often;
  if there get to be very many of them, some sort of tree search
  might be justified.
*/

protected_area_ptr
find_protected_area(BytePtr addr)
{
  protected_area* p;
  
  for(p = AllProtectedAreas; p; p=p->next) {
    if ((p->start <= addr) && (p->end > addr)) {
      return p;
    }
  }
  return NULL;
}



  

/* 
   Grow or shrink the dynamic area.  Or maybe not.
   Whether or not the end of (mapped space in) the heap changes,
   ensure that everything between the freeptr and the heap end
   is mapped and read/write.  (It'll incidentally be zeroed.)
*/
Boolean
resize_dynamic_heap(BytePtr newfree, 
		    natural free_space_size)
{
  extern int page_size;
  natural protbytes, zerobytes;
  area *a = active_dynamic_area;
  BytePtr newlimit, protptr, zptr;
  int psize = page_size;
  /* 
     Zero the region between the new freepointer and the end of the
     containing segment.
  */
  zptr = (BytePtr) align_to_power_of_2(newfree,log2_heap_segment_size);
  zerobytes = zptr-newfree;
  HeapHighWaterMark = zptr;

  while (zerobytes >= psize) {
    zptr -= psize;
    zerobytes -= psize;
    zero_page(zptr);
  }
  
  if (zerobytes) {
    bzero(newfree, zerobytes);
  }
  if (free_space_size) {
    BytePtr lowptr = a->active;
    newlimit = lowptr + align_to_power_of_2(newfree-lowptr+free_space_size,
					    log2_heap_segment_size);
    if (newlimit > a->high) {
      return grow_dynamic_area(newlimit-a->high);
    } else if ((HeapHighWaterMark + free_space_size) < a->high) {
      shrink_dynamic_area(a->high-newlimit);
      return true;
    }
  }
}

void
protect_area(protected_area_ptr p)
{
  BytePtr start = p->start;
  natural n = p->protsize;

  if (n && ! p->nprot) {
    ProtectMemory(start, n);
    p->nprot = n;
  }
}


void
zero_page(BytePtr start)
{
  extern int page_size;
#ifdef PPC
  extern void zero_cache_lines(BytePtr, size_t, size_t);
  zero_cache_lines(start, (page_size/cache_block_size), cache_block_size);
#else
  memset(start, 0, page_size);
#endif
}

/* area management */


area *
new_area(BytePtr lowaddr, BytePtr highaddr, area_code code)
{
  area *a = (area *) (zalloc(sizeof(area)));
  if (a) {
    natural ndnodes = area_dnode(highaddr, lowaddr);
    a->low = lowaddr;
    a->high = highaddr;
    a->active = (code == AREA_DYNAMIC) ? lowaddr : highaddr;
    a->code = code;
    a->ndnodes = ndnodes;
    /* Caller must allocate markbits when allocating heap ! */
    
  }
  return a;
}

static area *
add_area_before(area *new_area, area *before)
{
  area *before_before = before->pred;

  new_area->pred = before_before;
  new_area->succ = before;
  before_before->succ = new_area;
  before->pred = new_area;
  return new_area;
}

/*
  The active dynamic area comes first.
  Static areas follow dynamic areas.
  Stack areas follow static areas.
  Readonly areas come last.
*/

/*
  If we already own the area_lock (or during iniitalization), it's safe
  to add an area.
*/


void
add_area_holding_area_lock(area *new_area)
{
  area *that = all_areas;
  int
    thiscode = (int)(new_area->code),
    thatcode;

  /* Cdr down the linked list */
  do {
    that = that->succ;
    thatcode = (int)(that->code);
  } while (thiscode < thatcode);
  add_area_before(new_area, that);
}

/*
  In general, we need to own the area lock before adding an area.
*/
void
add_area(area *new_area, TCR *tcr)
{
  LOCK(lisp_global(AREA_LOCK),tcr);
  add_area_holding_area_lock(new_area);
  LOCK(lisp_global(AREA_LOCK),tcr);
}  

/*
  Search areas "forward" from the header's successor, until
  an area containing ADDR is found or an area with code < MINCODE
  is encountered.
  This walks the area list visiting heaps (dynamic, then static)
  first, then stacks.

*/
static area *
find_area_forward(BytePtr addr, area_code mincode)
{
  area *p, *header = all_areas;

  for (p = header->succ; p != header; p = p->succ) {
    area_code pcode = p->code;
    if (pcode < mincode) {
      return NULL;
    }
    if (pcode >= AREA_READONLY) {
      if ((addr >= p->low) &&
          (addr < p->active)) {
        return p;
      }
    } else {
      if ((addr >= p->active) &&
          (addr < p->high)) {
        return p;
      }
    }
  }
  return NULL;
}

static area *
find_area_backward(BytePtr addr, area_code maxcode)
{
  area *p, *header = all_areas;

  for (p = header->pred; p != header; p = p->pred) {
    area_code pcode = p->code;

    if (pcode > maxcode) {
      return NULL;
    }
    if (pcode >= AREA_READONLY) {
      if ((addr >= p->low) &&
          (addr < p->active)) {
        return p;
      }
    } else {
      if ((addr >= p->active) &&
          (addr < p->high)) {
        return p;
      }
    }
  }
  return NULL;
}

area *
area_containing(BytePtr addr)
{
  return find_area_forward(addr, AREA_VOID);
}

area *
heap_area_containing(BytePtr addr)
{
  return find_area_forward(addr, AREA_READONLY);
}

area *
stack_area_containing(BytePtr addr)
{
  return find_area_backward(addr, AREA_TSTACK);
}

/*
  Make everything "younger" than the start of the target area
  belong to that area; all younger areas will become empty, and
  the dynamic area will have to lose some of its markbits (they
  get zeroed and become part of the tenured area's refbits.)

  The active dynamic area must have been "normalized" (e.g., its
  active pointer must match the free pointer) before this is called.

  If the target area is 'tenured_area' (the oldest ephemeral generation),
  zero its refbits and update YOUNGEST_EPHEMERAL.

*/

void
tenure_to_area(area *target)
{
  area *a = active_dynamic_area, *child;
  BytePtr 
    curfree = a->active,
    target_low = target->low,
    tenured_low = tenured_area->low;
  natural 
    dynamic_dnodes = area_dnode(curfree, a->low),
    new_tenured_dnodes = area_dnode(curfree, tenured_area->low);
  bitvector 
    refbits = tenured_area->refbits,
    markbits = a->markbits,
    new_markbits;

  target->high = target->active = curfree;
  target->ndnodes = area_dnode(curfree, target_low);

  for (child = target->younger; child != a; child = child->younger) {
    child->high = child->low = child->active = curfree;
    child->ndnodes = 0;
  }

  a->low = curfree;
  a->ndnodes = area_dnode(a->high, curfree);

  new_markbits = refbits + ((new_tenured_dnodes + (nbits_in_word-1)) >> bitmap_shift);
  
  if (target == tenured_area) {
    zero_bits(refbits, new_tenured_dnodes);
    lisp_global(OLDEST_EPHEMERAL) = ptr_to_lispobj(curfree);
  } else {
    /* Need more (zeroed) refbits & fewer markbits */
    zero_bits(markbits, ((new_markbits-markbits)<<bitmap_shift));
  }
   
  a->markbits = new_markbits;
  lisp_global(OLDSPACE_DNODE_COUNT) = area_dnode(curfree, lisp_global(HEAP_START));
}



/*
  Make everything younger than the oldest byte in 'from' belong to 
  the youngest generation.  If 'from' is 'tenured_area', this means
  that nothing's ephemeral any more (and OLDEST_EPHEMERAL can be set
  to 0 to indicate this.)
  
  Some tenured_area refbits become dynamic area markbits in the process;
  it's not necessary to zero them, since the GC will do that.
*/

void
untenure_from_area(area *from)
{
  if (lisp_global(OLDEST_EPHEMERAL) != 0) {
    area *a = active_dynamic_area, *child;
    BytePtr curlow = from->low;
    natural new_tenured_dnodes = area_dnode(curlow, tenured_area->low);
    
    for (child = from; child != a; child = child->younger) {
      child->low = child->active = child->high = curlow;
      child->ndnodes = 0;
    }
    
    a->low = curlow;
    a->ndnodes = area_dnode(a->high, curlow);
    
    a->markbits = (tenured_area->refbits) + ((new_tenured_dnodes+(nbits_in_word-1))>>bitmap_shift);
    if (from == tenured_area) {
      /* Everything's in the dynamic area */
      lisp_global(OLDEST_EPHEMERAL) = 0;
      lisp_global(OLDSPACE_DNODE_COUNT) = 0;

    }
  }
}


Boolean
egc_control(Boolean activate, BytePtr curfree)
{
  area *a = active_dynamic_area;
  Boolean egc_is_active = (a->older != NULL);

  if (activate != egc_is_active) {
    if (curfree != NULL) {
      a->active = curfree;
    }
    if (activate) {
      LispObj *heap_start = ptr_from_lispobj(lisp_global(HEAP_START));

      a->older = g1_area;
      tenure_to_area(tenured_area);
      egc_is_active = true;
    } else {
      untenure_from_area(tenured_area);
      a->older = NULL;
      egc_is_active = false;
    }
  }
  return egc_is_active;
}

/*
  Lisp ff-calls this; it needs to set the active area's active pointer
  correctly.
*/

Boolean
lisp_egc_control(Boolean activate)
{
  area *a = active_dynamic_area;
  return egc_control(activate, (BytePtr) a->active);
}



  
/* Splice the protected_area_ptr out of the list and dispose of it. */
void
delete_protected_area(protected_area_ptr p)
{
  BytePtr start = p->start;
  int nbytes = p->nprot;
  protected_area_ptr *prev = &AllProtectedAreas, q;

  if (nbytes) {
    UnProtectMemory((LogicalAddress)start, nbytes);
  }
  
  while ((q = *prev) != NULL) {
    if (p == q) {
      *prev = p->next;
      break;
    } else {
      prev = &(q->next);
    }
  }

  deallocate((Ptr)p);
}




/* 
  Unlink the area from all_areas.
  Unprotect and dispose of any hard/soft protected_areas.
  If the area has a handle, dispose of that as well.
  */

void
condemn_area_holding_area_lock(area *a)
{
  void free_stack(void *);
  area *prev = a->pred, *next = a->succ;
  Ptr h = a->h;
  protected_area_ptr p;

  prev->succ = next;
  next->pred = prev;

  p = a->softprot;
  if (p) delete_protected_area(p);

  p = a->hardprot;

  if (p) delete_protected_area(p);

  if (h) free_stack(h);
  deallocate((Ptr)a);
}



void
condemn_area(area *a, TCR *tcr)
{
  LOCK(lisp_global(AREA_LOCK),tcr);
  condemn_area_holding_area_lock(a);
  LOCK(lisp_global(AREA_LOCK),tcr);
}




/*
  condemn an area and all the other areas that can be reached
  via the area.older & area.younger links.
  This is the function in the ppc::kernel-import-condemn-area slot,
  called by free-stack-area
  */
void
condemn_area_chain(area *a, TCR *tcr)
{
  area *older;

  LOCK(lisp_global(AREA_LOCK),tcr);

  for (; a->younger; a = a->younger) ;
  for (;a;) {
    older = a->older;
    condemn_area_holding_area_lock(a);
    a = older;
  }
  UNLOCK(lisp_global(AREA_LOCK),tcr);
}

