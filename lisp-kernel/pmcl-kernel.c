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

#ifdef DARWIN
/*	dyld.h included here because something in "lisp.h" causes
    a conflict (actually I think the problem is in "constants.h")
*/
#include <mach-o/dyld.h>
#endif
#include "lisp.h"
#include "lisp_globals.h"
#include "gc.h"
#include "area.h"
#include <stdlib.h>
#include <string.h>
#include "lisp-exceptions.h"
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <errno.h>
#include <sys/utsname.h>

#ifdef LINUX
#include <mcheck.h>
#include <dirent.h>
#include <dlfcn.h>
#include <sys/time.h>
#include <sys/resource.h>
#include <link.h>
#include <elf.h>
/* 
   The version of <asm/cputable.h> provided by some distributions will
   claim that <asm-ppc64/cputable.h> doesn't exist.  It may be present
   in the Linux kernel source tree even if it's not copied to
   /usr/include/asm-ppc64.  Hopefully, this will be straightened out
   soon (and/or the PPC_FEATURE_HAS_ALTIVEC constant will be defined
   in a less volatile place.)  Until that's straightened out, it may
   be necessary to install a copy of the kernel header in the right
   place and/or persuade <asm/cputable> to lighten up a bit.
*/

#ifndef PPC64
#include <asm/cputable.h>
#endif
#ifndef PPC_FEATURE_HAS_ALTIVEC
#define PPC_FEATURE_HAS_ALTIVEC 0x10000000
#endif
#endif

#ifdef DARWIN
#include <sys/types.h>
#include <sys/time.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <mach/mach_types.h>
#include <mach/message.h>
#include <mach/vm_region.h>
#include <sys/sysctl.h>
#ifdef PPC64
/* Assume that if the OS is new enough to support PPC64, it has
   a reasonable dlfcn.h
*/
#include <dlfcn.h>
#endif
#endif

#include <ctype.h>
#include <sys/select.h>
#include "Threads.h"

LispObj lisp_nil = (LispObj) 0;
bitvector global_mark_ref_bits = NULL;


/* These are all "persistent" : they're initialized when
   subprims are first loaded and should never change. */
extern LispObj ret1valn;
extern LispObj nvalret;
extern LispObj popj;
LispObj real_subprims_base = 0;
LispObj text_start = 0;

/* A pointer to some of the kernel's own data; also persistent. */

extern LispObj import_ptrs_base;




void
xMakeDataExecutable(void *, unsigned long);

void
make_dynamic_heap_executable(LispObj *p, LispObj *q)
{
  void * cache_start = (void *) p;
  unsigned long ncacheflush = (unsigned long) q - (unsigned long) p;

  xMakeDataExecutable(cache_start, ncacheflush);  
}
      
size_t
ensure_stack_limit(size_t stack_size)
{
  struct rlimit limits;
  rlim_t cur_stack_limit, max_stack_limit;
 
  stack_size += (CSTACK_HARDPROT+CSTACK_SOFTPROT);
  getrlimit(RLIMIT_STACK, &limits);
  cur_stack_limit = limits.rlim_cur;
  max_stack_limit = limits.rlim_max;
  if (stack_size > max_stack_limit) {
    stack_size = max_stack_limit;
  }
  if (cur_stack_limit < stack_size) {
    limits.rlim_cur = stack_size;
    errno = 0;
    if (setrlimit(RLIMIT_STACK, &limits)) {
      int e = errno;
      fprintf(stderr, "errno = %d\n", e);
      Fatal(": Stack resource limit too small", "");
    }
  }
  return stack_size - (CSTACK_HARDPROT+CSTACK_SOFTPROT);
}


/* This should write-protect the bottom of the stack.
   Doing so reliably involves ensuring that everything's unprotected on exit.
*/

BytePtr
allocate_lisp_stack(unsigned useable,
                    unsigned softsize,
                    unsigned hardsize,
                    lisp_protection_kind softkind,
                    lisp_protection_kind hardkind,
                    Ptr *h_p,
                    BytePtr *base_p,
                    protected_area_ptr *softp,
                    protected_area_ptr *hardp)
{
  void *allocate_stack(unsigned);
  void free_stack(void *);
  unsigned size = useable+softsize+hardsize;
  unsigned overhead;
  BytePtr base, softlimit, hardlimit;
  OSErr err;
  Ptr h = allocate_stack(size+4095);
  protected_area_ptr hprotp = NULL, sprotp;

  if (h == NULL) {
    return NULL;
  }
  if (h_p) *h_p = h;
  base = (BytePtr) align_to_power_of_2( h, 12);
  hardlimit = (BytePtr) (base+hardsize);
  softlimit = hardlimit+softsize;

  overhead = (base - (BytePtr) h);
  if (hardsize) {
    hprotp = new_protected_area((BytePtr)base,hardlimit,hardkind, hardsize, true);
    if (hprotp == NULL) {
      if (base_p) *base_p = NULL;
      if (h_p) *h_p = NULL;
      deallocate(h);
      return NULL;
    }
    if (hardp) *hardp = hprotp;
  }
  if (softsize) {
    sprotp = new_protected_area(hardlimit,softlimit, softkind, softsize, true);
    if (sprotp == NULL) {
      if (base_p) *base_p = NULL;
      if (h_p) *h_p = NULL;
      if (hardp) *hardp = NULL;
      if (hprotp) delete_protected_area(hprotp);
      free_stack(h);
      return NULL;
    }
    if (softp) *softp = sprotp;
  }
  if (base_p) *base_p = base;
  return (BytePtr) ((unsigned long)(base+size));
}

/*
  This should only called by something that owns the area_lock, or
  by the initial thread before other threads exist.
*/
area *
allocate_lisp_stack_area(area_code stack_type,
                         unsigned useable, 
                         unsigned softsize, 
                         unsigned hardsize, 
                         lisp_protection_kind softkind, 
                         lisp_protection_kind hardkind)

{
  BytePtr base, bottom;
  Ptr h;
  area *a = NULL;
  protected_area_ptr soft_area=NULL, hard_area=NULL;

  bottom = allocate_lisp_stack(useable, 
                               softsize, 
                               hardsize, 
                               softkind, 
                               hardkind, 
                               &h, 
                               &base,
                               &soft_area, 
                               &hard_area);

  if (bottom) {
    a = new_area(base, bottom, stack_type);
    a->hardlimit = base+hardsize;
    a->softlimit = base+hardsize+softsize;
    a->h = h;
    a->softprot = soft_area;
    a->hardprot = hard_area;
    add_area_holding_area_lock(a);
  }
  return a;
}

/*
  Also assumes ownership of the area_lock 
*/
area*
register_cstack_holding_area_lock(BytePtr bottom, unsigned size)
{
  BytePtr lowlimit = (BytePtr) (((((unsigned long)bottom)-size)+4095)&~4095);
  area *a = new_area((BytePtr) bottom-size, bottom, AREA_CSTACK);

  a->hardlimit = lowlimit+CSTACK_HARDPROT;
  a->softlimit = a->hardlimit+CSTACK_SOFTPROT;
  add_area_holding_area_lock(a);
  return a;
}
  

area*
allocate_vstack_holding_area_lock(unsigned usable)
{
  return allocate_lisp_stack_area(AREA_VSTACK, 
				  usable > MIN_VSTACK_SIZE ?
				  usable : MIN_VSTACK_SIZE,
                                  VSTACK_SOFTPROT,
                                  VSTACK_HARDPROT,
                                  kVSPsoftguard,
                                  kVSPhardguard);
}

area *
allocate_tstack_holding_area_lock(unsigned usable)
{
  return allocate_lisp_stack_area(AREA_TSTACK, 
                                  usable > MIN_TSTACK_SIZE ?
				  usable : MIN_TSTACK_SIZE,
                                  TSTACK_SOFTPROT,
                                  TSTACK_HARDPROT,
                                  kTSPsoftguard,
                                  kTSPhardguard);
}


/* It's hard to believe that max & min don't exist already */
unsigned unsigned_min(unsigned x, unsigned y)
{
  if (x <= y) {
    return x;
  } else {
    return y;
  }
}

unsigned unsigned_max(unsigned x, unsigned y)
{
  if (x >= y) {
    return x;
  } else {
    return y;
  }
}

#ifdef DARWIN
#define MAXIMUM_MAPPABLE_MEMORY ((1U<<31)-2*heap_segment_size)
#endif

#ifdef LINUX
#define MAXIMUM_MAPPABLE_MEMORY (1U<<30)
#endif

natural
reserved_area_size = MAXIMUM_MAPPABLE_MEMORY;

area *nilreg_area=NULL, *tenured_area=NULL, *g2_area=NULL, *g1_area=NULL;
area *all_areas=NULL;
int cache_block_size=32;


#define DEFAULT_LISP_HEAP_GC_THRESHOLD (16<<20)
#define DEFAULT_INITIAL_STACK_SIZE (1<<20)

unsigned
lisp_heap_gc_threshold = DEFAULT_LISP_HEAP_GC_THRESHOLD;

unsigned 
initial_stack_size = DEFAULT_INITIAL_STACK_SIZE;


/*
  'start' should be on a segment boundary; 'len' should be
  an integral number of segments.  remap the entire range.
*/

BytePtr 
HeapHighWaterMark = NULL;

void 
uncommit_pages(void *start, size_t len)
{
  if (len) {
    madvise(start, len, MADV_DONTNEED);
    if (mmap(start, 
	     len, 
	     PROT_NONE, 
	     MAP_PRIVATE | MAP_FIXED | MAP_ANON,
	     -1,
	     0) != start) {
      int err = errno;
      Fatal("mmap error", "");
      fprintf(stderr, "errno = %d", err);
    }
  }
  HeapHighWaterMark = start;
}

void
commit_pages(void *start, size_t len)
{
  if (len != 0) {
    int i, err;
    void *addr;
    for (i = 0; i < 3; i++) {
      addr = mmap(start, 
		  len, 
		  PROT_READ | PROT_WRITE,
		  MAP_PRIVATE | MAP_FIXED | MAP_ANON,
		  -1,
		  0);
      if (addr  == start) {
        HeapHighWaterMark = ((BytePtr)start) + len;
	return;
      }
      err = errno;
      Bug(NULL, "mmap failure returned 0x%08x, attempt %d: %s\n",
	  addr,
	  i,
	  strerror(errno));
      sleep(5);
    }
    Fatal("mmap error", "");
  }
}

area *
find_readonly_area()
{
  area *a;

  for (a = active_dynamic_area->succ; a != all_areas; a = a->succ) {
    if (a->code == AREA_READONLY) {
      return a;
    }
  }
  return NULL;
}

area *
extend_readonly_area(unsigned more)
{
  area *a;
  unsigned mask;
  BytePtr new_start, new_end;

  if (a = find_readonly_area()) {
    if ((a->active + more) > a->high) {
      return NULL;
    }
    mask = ((unsigned long)a->active) & 4095;
    if (mask) {
      UnProtectMemory(a->active-mask, 4096);
    }
    new_start = (BytePtr)(align_to_power_of_2(a->active,12));
    new_end = (BytePtr)(align_to_power_of_2(a->active+more,12));
    if (mmap(new_start,
             new_end-new_start,
             PROT_READ | PROT_WRITE,
             MAP_PRIVATE | MAP_ANON | MAP_FIXED,
             -1,
             0) != new_start) {
      return NULL;
    }
    return a;
  }
  return NULL;
}

LispObj image_base=0;
BytePtr pure_space_start, pure_space_active, pure_space_limit;
BytePtr static_space_start, static_space_active, static_space_limit;

#ifdef DARWIN
#ifdef PPC64
#define vm_region vm_region_64
#endif

/*
  Check to see if the specified address is unmapped by trying to get
  information about the mapped address at or beyond the target.  If
  the difference between the target address and the next mapped address
  is >= len, we can safely mmap len bytes at addr.
*/
Boolean
address_unmapped_p(char *addr, natural len)
{
  vm_address_t vm_addr = (vm_address_t)addr;
  vm_size_t vm_size;
#ifdef PPC64
  vm_region_basic_info_data_64_t vm_info;
#else
  vm_region_basic_info_data_t vm_info;
#endif
#ifdef PPC64
  mach_msg_type_number_t vm_info_size = VM_REGION_BASIC_INFO_COUNT_64;
#else
  mach_msg_type_number_t vm_info_size = VM_REGION_BASIC_INFO_COUNT;
#endif
  port_t vm_object_name = (port_t) 0;
  kern_return_t kret;

  kret = vm_region(mach_task_self(),
		   &vm_addr,
		   &vm_size,
		   VM_REGION_BASIC_INFO,
		   (vm_region_info_t)&vm_info,
		   &vm_info_size,
		   &vm_object_name);
  if (kret != KERN_SUCCESS) {
    return false;
  }

  return vm_addr >= (vm_address_t)(addr+len);
}
#endif




area *
create_reserved_area(unsigned long totalsize)
{
  OSErr err;
  Ptr h;
  unsigned base, n;
  BytePtr 
    end, 
    lastbyte, 
    start, 
    protstart, 
    p, 
    want = (BytePtr)IMAGE_BASE_ADDRESS,
    try2;
  area *reserved;
  Boolean fixed_map_ok = false;

  /*
    Through trial and error, we've found that IMAGE_BASE_ADDRESS is
    likely to reside near the beginning of an unmapped block of memory
    that's at least 1GB in size.  We'd like to load the heap image's
    sections relative to IMAGE_BASE_ADDRESS; if we're able to do so,
    that'd allow us to file-map those sections (and would enable us to
    avoid having to relocate references in the data sections.)

    In short, we'd like to reserve 1GB starting at IMAGE_BASE_ADDRESS
    by creating an anonymous mapping with mmap().

    If we try to insist that mmap() map a 1GB block at
    IMAGE_BASE_ADDRESS exactly (by specifying the MAP_FIXED flag),
    mmap() will gleefully clobber any mapped memory that's already
    there.  (That region's empty at this writing, but some future
    version of the OS might decide to put something there.)

    If we don't specify MAP_FIXED, mmap() is free to treat the address
    we give it as a hint; Linux seems to accept the hint if doing so
    wouldn't cause a problem.  Naturally, that behavior's too useful
    for Darwin (or perhaps too inconvenient for it): it'll often
    return another address, even if the hint would have worked fine.

    We call address_unmapped_p() to ask Mach whether using MAP_FIXED
    would conflict with anything.  Until we discover a need to do 
    otherwise, we'll assume that if Linux's mmap() fails to take the
    hint, it's because of a legitimate conflict.

    If Linux starts ignoring hints, we can parse /proc/<pid>/maps
    to implement an address_unmapped_p() for Linux.
  */

  totalsize = align_to_power_of_2((void *)totalsize, log2_heap_segment_size);

#ifdef DARWIN
  fixed_map_ok = address_unmapped_p(want,totalsize);
#endif
  start = mmap((void *)want,
	       totalsize + heap_segment_size,
	       PROT_NONE,
	       MAP_PRIVATE | MAP_ANON | (fixed_map_ok ? MAP_FIXED : 0),
	       -1,
	       0);
  if (start == MAP_FAILED) {
    perror("Initial mmap");
    return NULL;
  }

  if (start != want) {
    munmap(start, totalsize+heap_segment_size);
    start = (void *)((((unsigned long)start)+heap_segment_size-1) & ~(heap_segment_size-1));
    if(mmap(start, totalsize, PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0) != start) {
      return NULL;
    }
  }
  mprotect(start, totalsize, PROT_NONE);

  h = (Ptr) start;
  base = (unsigned long) start;
  image_base = base;
  lastbyte = (BytePtr) (start+totalsize);
  static_space_start = static_space_active = (BytePtr)STATIC_BASE_ADDRESS;
  static_space_limit = static_space_start + STATIC_RESERVE;
  pure_space_start = pure_space_active = start;
  pure_space_limit = start + PURESPACE_RESERVE;
  start = pure_space_limit;

  /*
    Allocate mark bits here.  They need to be 1/64 the size of the
     maximum useable area of the heap (+ 3 words for the EGC.)
  */
  end = lastbyte;
  end = (BytePtr) ((unsigned long)((((unsigned long)end) - ((totalsize+63)>>6)) & ~4095));

  global_mark_ref_bits = (bitvector)end;
  end = (BytePtr) ((unsigned long)((((unsigned long)end) - ((totalsize+63) >> 6)) & ~4095));
  global_reloctab = (LispObj *) end;
  reserved = new_area(start, end, AREA_VOID);
  /* The root of all evil is initially linked to itself. */
  reserved->pred = reserved->succ = reserved;
  all_areas = reserved;
  reserved->markbits = global_mark_ref_bits;
  return reserved;
}

void *
allocate_from_reserved_area(unsigned size)
{
  area *reserved = reserved_area;
  BytePtr low = reserved->low, high = reserved->high;
  unsigned avail = high-low;
  size = align_to_power_of_2(size, log2_heap_segment_size);

  if (size > avail) {
    return NULL;
  }
  reserved->low += size;
  reserved->active = reserved->low;
  reserved->ndnodes -= (size>>dnode_shift);
  return low;
}


#define FILE_MAP_FROM_RESERVED_AREA 0

void *
file_map_reserved_pages(unsigned len, int prot, int fd, unsigned offset)
{
  void *start;
  unsigned 
    offset_of_page = offset & ~((1<<12)-1), 
    offset_in_page = offset - offset_of_page,
    segment_len = align_to_power_of_2((offset+len)-offset_of_page, 
				      log2_heap_segment_size);
  
  /* LOCK_MMAP_LOCK(); */
#if FILE_MAP_FROM_RESERVED_AREA
  start = allocate_from_reserved_area(segment_len);
  if (start == NULL) {
    return start;
  }
#endif
#if FILE_MAP_FROM_RESERVED_AREA
  if (start != mmap(start,
		    segment_len,
		    prot,
		    MAP_PRIVATE | MAP_FIXED,
		    fd,
		    offset_of_page)) {
    return NULL;
  }
#else
  if ((start = mmap(NULL,
		    segment_len,
		    prot,
		    MAP_PRIVATE,
		    fd,
		    offset_of_page)) == (void *)-1) {
    return NULL;
  }
#endif
  /* UNLOCK_MMAP_LOCK(); */
  return (void *) (((unsigned long)start) + offset_in_page);
}

BytePtr pagemap_limit = NULL, 
  reloctab_limit = NULL, markbits_limit = NULL;
void
ensure_gc_structures_writable()
{
  unsigned 
    ndnodes = area_dnode(lisp_global(HEAP_END),lisp_global(HEAP_START)),
    npages = (lisp_global(HEAP_END)-lisp_global(HEAP_START)) >> 12,
    markbits_size = 12+((ndnodes+7)>>dnode_shift),
    reloctab_size = (sizeof(LispObj)*(((ndnodes+31)>>5)+1));
  BytePtr 
    new_reloctab_limit = ((BytePtr)global_reloctab)+reloctab_size,
    new_markbits_limit = ((BytePtr)global_mark_ref_bits)+markbits_size;

  if (new_reloctab_limit > reloctab_limit) {
    UnProtectMemory(global_reloctab, reloctab_size);
    reloctab_limit = new_reloctab_limit;
  }
  
  if (new_markbits_limit > markbits_limit) {
    UnProtectMemory(global_mark_ref_bits, markbits_size);
    markbits_limit = new_markbits_limit;
  }
}


area *
allocate_dynamic_area(unsigned initsize)
{
  unsigned totalsize = align_to_power_of_2(initsize, log2_heap_segment_size);
  BytePtr start, end;
  area *a;

  start = allocate_from_reserved_area(totalsize);
  if (start == NULL) {
    return NULL;
  }
  end = start + totalsize;
  a = new_area(start, end, AREA_DYNAMIC);
  a->active = start+initsize;
  add_area_holding_area_lock(a);
  a->markbits = reserved_area->markbits;
  reserved_area->markbits = NULL;
  UnProtectMemory(start, end-start);
  a->h = start;
  a->softprot = NULL;
  a->hardprot = NULL;
  a->hardlimit = end;
  ensure_gc_structures_writable();
  return a;
}


Boolean
grow_dynamic_area(unsigned delta)
{
  area *a = active_dynamic_area, *reserved = reserved_area;
  unsigned avail = reserved->high - reserved->low;
  
  delta = align_to_power_of_2(delta, log2_heap_segment_size);
  if (delta > avail) {
    delta = avail;
  }
  if (!allocate_from_reserved_area(delta)) {
    return false;
  }
  commit_pages(a->high,delta);

  a->high += delta;
  a->ndnodes = area_dnode(a->high, a->low);
  a->hardlimit = a->high;
  lisp_global(HEAP_END) += delta;
  ensure_gc_structures_writable();
  return true;
}

/*
  As above.  Pages that're returned to the reserved_area are
  "condemned" (e.g, we try to convince the OS that they never
  existed ...)
*/
Boolean
shrink_dynamic_area(unsigned delta)
{
  area *a = active_dynamic_area, *reserved = reserved_area;
  
  delta = align_to_power_of_2(delta, log2_heap_segment_size);

  a->high -= delta;
  a->ndnodes = area_dnode(a->high, a->low);
  a->hardlimit = a->high;
  uncommit_pages(a->high, delta);
  reserved->low -= delta;
  reserved->ndnodes += (delta>>dnode_shift);
  lisp_global(HEAP_END) -= delta;
  return true;
}


/* 
 interrupt-level is >= 0 when interrupts are enabled and < 0
 during without-interrupts. Normally, it is 0. When this timer
 goes off, it sets it to 1 if it's 0, or if it's negative,
 walks up the special binding list looking for a previous
 value of 0 to set to 1. 
*/

  



typedef struct {
  int total_hits;
  int lisp_hits;
  int active;
  int interval;
} metering_info;

metering_info
lisp_metering =
{
  0, 
  0, 
  0, 
  0
  };

void
metering_proc(int signum, struct sigcontext *context)
{
  lisp_metering.total_hits++;
#ifndef DARWIN
#ifdef BAD_IDEA
  if (xpGPR(context,rnil) == lisp_nil) {
    unsigned current_lisp = lisp_metering.lisp_hits, element;
    LispObj 
      rpc = (LispObj) xpPC(context),
      rfn = xpGPR(context, fn),
      rnfn = xpGPR(context, nfn),
      reg,
      v =  nrs_ALLMETEREDFUNS.vcell;

    if (area_containing((BytePtr)rfn) == NULL) {
      rfn = (LispObj) 0;
    }
    if (area_containing((BytePtr)rnfn) == NULL) {
      rnfn = (LispObj) 0;
    }

    if (tag_of(rpc) == tag_fixnum) {
      if (register_codevector_contains_pc(rfn, rpc)) {
	reg = rfn;
      } else if (register_codevector_contains_pc(rnfn, rpc)) {
	reg = rnfn;
      } else {
	reg = rpc;
      }
      element = current_lisp % lisp_metering.active;
      lisp_metering.lisp_hits++;
      deref(v,element+1) = reg; /* NOT memoized */
    }
  }
#endif
#endif
}

void
sigint_handler (int signum, siginfo_t *info, ExceptionInformation *context)
{
  if (signum == SIGINT) {
    lisp_global(INTFLAG) = (1 << fixnumshift);
  }
#ifdef DARWIN
  DarwinSigReturn(context);
#endif
}



void
register_sigint_handler()
{
  struct sigaction sa;

  sa.sa_sigaction = (void *)sigint_handler;
  sigfillset(&sa.sa_mask);
  sa.sa_flags = SA_RESTART | SA_SIGINFO;

  sigaction(SIGINT, &sa, NULL);
  
}


extern BytePtr
current_stack_pointer(void);

BytePtr
initial_stack_bottom()
{
  extern char **environ;
  char *p = *environ;
  while (*p) {
    p += (1+strlen(p));
  }
  return (BytePtr)((((unsigned long) p) +4095) & ~4095);
}


  
Ptr fatal_spare_ptr = NULL;

void
prepare_for_the_worst()
{
  /* I guess that CouldDialog is no more */
  /* CouldDialog(666); */
}

void
Fatal(StringPtr param0, StringPtr param1)
{

  if (fatal_spare_ptr) {
    deallocate(fatal_spare_ptr);
    fatal_spare_ptr = NULL;
  }
  fprintf(stderr, "Fatal error: %s\n%s\n", param0, param1);
  exit(-1);
}

OSErr application_load_err = noErr;

area *
set_nil(LispObj);


#ifdef DARWIN
/* 
   The underlying file system may be case-insensitive (e.g., HFS),
   so we can't just case-invert the kernel's name.
   Tack ".image" onto the end of the kernel's name.  Much better ...
*/
char *
default_image_name(char *orig)
{
  int len = strlen(orig) + strlen(".image") + 1;
  char *copy = (char *) malloc(len);

  if (copy) {
    strcat(copy, orig);
    strcat(copy, ".image");
  }
  return copy;
}

#else
char *
default_image_name(char *orig)
{
  char *copy = strdup(orig), *base = copy, *work = copy, c;
  if (copy == NULL) {
    return NULL;
  }
  while(*work) {
    if (*work++ == '/') {
      base = work;
    }
  }
  work = base;
  while (c = *work) {
    if (islower(c)) {
      *work++ = toupper(c);
    } else {
      *work++ = tolower(c);
    }
  }
  return copy;
}
#endif


char *program_name = NULL;
char *real_executable_name = NULL;

char *
determine_executable_name(char *argv0)
{
#ifdef DARWIN
  uint32_t len = 1024;
  char exepath[1024], *p = NULL;

  if (_NSGetExecutablePath(exepath, (void *)&len) == 0) {
    p = malloc(len+1);
    bcopy(exepath, p, len);
    p[len]=0;
    return p;
  } 
  return argv0;
#endif
#ifdef LINUX
  char exepath[PATH_MAX], *p;
  int n;

  if ((n = readlink("/proc/self/exe", exepath, PATH_MAX)) > 0) {
    p = malloc(n+1);
    bcopy(exepath,p,n);
    p[n]=0;
    return p;
  }
  return argv0;
#endif
}

void
usage_exit(char *herald, int exit_status, char* other_args)
{
  if (herald && *herald) {
    fprintf(stderr, "%s\n", herald);
  }
  fprintf(stderr, "usage: %s <options>\n", program_name);
  fprintf(stderr, "\t or %s <image-name>\n", program_name);
  fprintf(stderr, "\t where <options> are one or more of:\n");
  if (other_args && *other_args) {
    fputs(other_args, stderr);
  }
  fprintf(stderr, "\t-R, --heap-reserve <n>: reserve <n> (default: %d)\n",
	  reserved_area_size);
  fprintf(stderr, "\t\t bytes for heap expansion\n");
  fprintf(stderr, "\t-S, --stack-size <n>: set size of initial stacks to <n> (default: %d)\n", initial_stack_size);
  fprintf(stderr, "\t-b, --batch: exit when EOF on *STANDARD-INPUT*\n");
  fprintf(stderr, "\t--no-sigtrap : obscure option for running under GDB\n");
  fprintf(stderr, "\t-I, --image-name <image-name>\n");
  fprintf(stderr, "\t and <image-name> defaults to %s\n", 
	  default_image_name(program_name));
  fprintf(stderr, "\n");
  exit(exit_status);
}

int no_sigtrap = 0;
char *image_name = NULL;
int batch_flag = 0;


natural
parse_numeric_option(char *arg, char *argname, natural default_val)
{
  char *tail;
  unsigned val = 0;

  val = strtoul(arg, &tail, 0);
  switch(*tail) {
  case '\0':
    break;
    
  case 'M':
  case 'm':
    val = val << 20;
    break;
    
  case 'K':
  case 'k':
    val = val << 10;
    break;
    
  case 'G':
  case 'g':
    val = val << 30;
    break;
    
  default:
    fprintf(stderr, "couldn't parse %s argument %s", argname, arg);
    val = default_val;
    break;
  }
  return val;
}
  


/* 
   The set of arguments recognized by the kernel is
   likely to remain pretty small and pretty simple.
   This removes everything it recognizes from argv;
   remaining args will be processed by lisp code.
*/

void
process_options(int argc, char *argv[])
{
  int i, j, k, num_elide, flag, arg_error;
  char *arg, *val;
#ifdef DARWIN
  extern int NXArgc;
#endif

  for (i = 1; i < argc;) {
    arg = argv[i];
    arg_error = 0;
    if (*arg != '-') {
      i++;
    } else {
      num_elide = 0;
      val = NULL;
      if ((flag = (strncmp(arg, "-I", 2) == 0)) ||
	  (strcmp (arg, "--image-name") == 0)) {
	if (flag && arg[2]) {
	  val = arg+2;
	  num_elide = 1;
	} else {
	  if ((i+1) < argc) {
	    val = argv[i+1];
	    num_elide = 2;
	  } else {
	    arg_error = 1;
	  }
	}
	if (val) {
	  image_name = val;
	}
      } else if ((flag = (strncmp(arg, "-R", 2) == 0)) ||
		 (strcmp(arg, "--heap-reserve") == 0)) {
	natural reserved_size;

	if (flag && arg[2]) {
	  val = arg+2;
	  num_elide = 1;
	} else {
	  if ((i+1) < argc) {
	    val = argv[i+1];
	    num_elide = 2;
	  } else {
	    arg_error = 1;
	  }
	}

	if (val) {
	  reserved_size = parse_numeric_option(val, 
					       "-R/--heap-reserve", 
					       reserved_area_size);
	}

	if (reserved_size <= MAXIMUM_MAPPABLE_MEMORY) {
	  reserved_area_size = reserved_size;
	}

      } else if ((flag = (strncmp(arg, "-S", 2) == 0)) ||
		 (strcmp(arg, "--stack-size") == 0)) {
	unsigned stack_size;

	if (flag && arg[2]) {
	  val = arg+2;
	  num_elide = 1;
	} else {
	  if ((i+1) < argc) {
	    val = argv[i+1];
	    num_elide = 2;
	  } else {
	    arg_error = 1;
	  }
	}

	if (val) {
	  stack_size = parse_numeric_option(val, 
					    "-S/--stack-size", 
					    initial_stack_size);
	  

	  if (stack_size >= MIN_CSTACK_SIZE) {
	    initial_stack_size = stack_size;
	  }
	}

      } else if (strcmp(arg, "--no-sigtrap") == 0) {
	no_sigtrap = 1;
	num_elide = 1;
      } else if ((strcmp(arg, "-b") == 0) ||
		 (strcmp(arg, "--batch") == 0)) {
	batch_flag = 1;
	num_elide = 1;
      } else {
	i++;
      }
      if (arg_error) {
	usage_exit("error in program arguments", 1, "");
      }
      if (num_elide) {
	for (j = i+num_elide, k=i; j < argc; j++, k++) {
	  argv[k] = argv[j];
	}
	argc -= num_elide;
#ifdef DARWIN
	NXArgc -= num_elide;
#endif
	argv[argc] = NULL;
      }
    }
  }
}

pid_t main_thread_pid = (pid_t)0;

void
terminate_lisp()
{
  kill(main_thread_pid, SIGKILL);
  exit(-1);
}

#ifdef DARWIN
#define min_os_version "6.0"
#endif
#ifdef LINUX
#define min_os_version "2.2"
#endif

void
check_os_version(char *progname)
{
  struct utsname uts;

  uname(&uts);
  if (strcmp(uts.release, min_os_version) < 0) {
    fprintf(stderr, "\n%s requires %s version %s or later; the current version is %s.\n", progname, uts.sysname, min_os_version, uts.release);
    exit(1);
  }
}

  
main(int argc, char *argv[], char *envp[], void *aux)
{
  extern  set_fpscr(unsigned);

  extern int altivec_present;
  extern LispObj load_image(char *);
  long resp;
  BytePtr stack_end;
  area *a;
  BytePtr stack_base, current_sp = current_stack_pointer();
  TCR *tcr;
  int i;

  check_os_version(argv[0]);
  real_executable_name = determine_executable_name(argv[0]);


#ifdef LINUX
  {
    ElfW(auxv_t) *av = aux;
    int hwcap, done = false;
    
    if (av) {
      do {
	switch (av->a_type) {
	case AT_DCACHEBSIZE:
	  cache_block_size = av->a_un.a_val;
	  break;

	case AT_HWCAP:
	  hwcap = av->a_un.a_val;
	  altivec_present = ((hwcap & PPC_FEATURE_HAS_ALTIVEC) != 0);
	  break;

	case AT_NULL:
	  done = true;
	  break;
	}
	av++;
      } while (!done);
    }
  }
#endif
#ifdef DARWIN
  {
    unsigned value = 0;
    size_t len = sizeof(value);
    int mib[2];
    
    mib[0] = CTL_HW;
    mib[1] = HW_CACHELINE;
    if (sysctl(mib,2,&value,&len, NULL, 0) != -1) {
      if (len == sizeof(value)) {
	cache_block_size = value;
      }
    }
    mib[1] = HW_VECTORUNIT;
    value = 0;
    len = sizeof(value);
    if (sysctl(mib,2,&value,&len, NULL, 0) != -1) {
      if (len == sizeof(value)) {
	altivec_present = value;
      }
    }
  }
#endif

  main_thread_pid = getpid();
  area_lock = (void *)new_recursive_lock();

  program_name = argv[0];
  if ((argc == 2) && (*argv[1] != '-')) {
    image_name = argv[1];
    argv[1] = NULL;
  } else {
    process_options(argc,argv);
  }
  initial_stack_size = ensure_stack_limit(initial_stack_size);
  if (image_name == NULL) {
    if (check_for_embedded_image(real_executable_name)) {
      image_name = real_executable_name;
    } else {
      image_name = default_image_name(real_executable_name);
    }
  }

  prepare_for_the_worst();

  real_subprims_base = (LispObj)(1<<20);
  create_reserved_area(reserved_area_size);
  set_nil(load_image(image_name));
  lisp_global(AREA_LOCK) = ptr_to_lispobj(area_lock);

  lisp_global(SUBPRIMS_BASE) = (LispObj)(1<<20);
  lisp_global(RET1VALN) = (LispObj)&ret1valn;
  lisp_global(LEXPR_RETURN) = (LispObj)&nvalret;
  lisp_global(LEXPR_RETURN1V) = (LispObj)&popj;
  lisp_global(ALL_AREAS) = ptr_to_lispobj(all_areas);

  exception_init();

  if (lisp_global(SUBPRIMS_BASE) == 0) {
    Fatal(": Couldn't load subprims library.", "");
  }
  

  lisp_global(IMAGE_NAME) = ptr_to_lispobj(image_name);
  lisp_global(ARGV) = ptr_to_lispobj(argv);
  lisp_global(KERNEL_IMPORTS) = (LispObj)import_ptrs_base;

  lisp_global(METERING_INFO) = (LispObj) &lisp_metering;
  lisp_global(GET_TCR) = (LispObj) get_tcr;
  *(double *) &(lisp_global(DOUBLE_FLOAT_ONE)) = (double) 1.0;

  lisp_global(HOST_PLATFORM) = (LispObj)
#ifdef LINUX
    1
#endif
#ifdef DARWIN
    3
#endif
    /* We'll get a syntax error here if nothing's defined. */
    << fixnumshift;


  lisp_global(BATCH_FLAG) = (batch_flag << fixnumshift);

  a = active_dynamic_area;

  if (nilreg_area != NULL) {
    BytePtr lowptr = (BytePtr) a->low;

    /* Create these areas as AREA_STATIC, change them to AREA_DYNAMIC */
    g1_area = new_area(lowptr, lowptr, AREA_STATIC);
    g2_area = new_area(lowptr, lowptr, AREA_STATIC);
    tenured_area = new_area(lowptr, lowptr, AREA_STATIC);
    add_area_holding_area_lock(tenured_area);
    add_area_holding_area_lock(g2_area);
    add_area_holding_area_lock(g1_area);

    g1_area->code = AREA_DYNAMIC;
    g2_area->code = AREA_DYNAMIC;
    tenured_area->code = AREA_DYNAMIC;

/*    a->older = g1_area; */ /* Not yet: this is what "enabling the EGC" does. */
    g1_area->younger = a;
    g1_area->older = g2_area;
    g2_area->younger = g1_area;
    g2_area->older = tenured_area;
    tenured_area->younger = g2_area;
    tenured_area->refbits = a->markbits;
    lisp_global(TENURED_AREA) = ptr_to_lispobj(tenured_area);
    lisp_global(REFBITS) = ptr_to_lispobj(tenured_area->refbits);
    g2_area->threshold = (4<<20); /* 4MB */
    g1_area->threshold = (2<<20); /* 2MB */
    a->threshold = (1<<20);     /* 1MB */
  }

  tcr = new_tcr(initial_stack_size, MIN_TSTACK_SIZE);
  stack_base = initial_stack_bottom()-xStackSpace();
  init_threads((void *)(stack_base), tcr);
  thread_init_tcr(tcr, current_sp, current_sp-stack_base);

  lisp_global(EXCEPTION_LOCK) = ptr_to_lispobj(new_recursive_lock());
  enable_fp_exceptions();
  register_sigint_handler();

  lisp_global(ALTIVEC_PRESENT) = altivec_present << fixnumshift;
#if STATIC
  lisp_global(STATICALLY_LINKED) = 1 << fixnumshift;
#endif
  tcr->prev = tcr->next = tcr;
  lisp_global(TCR_LOCK) = ptr_to_lispobj(new_recursive_lock());
  lisp_global(INTERRUPT_SIGNAL) = (LispObj) box_fixnum(SIGNAL_FOR_PROCESS_INTERRUPT);
  tcr->interrupt_level = (-1<<fixnumshift);
  tcr->vs_area->active -= 4;
  *(--tcr->save_vsp) = nrs_TOPLFUNC.vcell;
  nrs_TOPLFUNC.vcell = lisp_nil;
  enable_fp_exceptions();
#if 1
  egc_control(true, NULL);
#endif
  start_lisp(TCR_TO_TSD(tcr), 0);
  exit(0);
}

area *
set_nil(LispObj r)
{

  if (lisp_nil == (LispObj)NULL) {

    lisp_nil = r;
  }
  return NULL;
}


void
xMakeDataExecutable(void *start, unsigned long nbytes)
{
  extern void flush_cache_lines();
  unsigned long ustart = (unsigned long) start, base, end;
  
  base = (ustart) & ~(cache_block_size-1);
  end = (ustart + nbytes + cache_block_size - 1) & ~(cache_block_size-1);
  flush_cache_lines(base, (end-base)/cache_block_size, cache_block_size);
}

int
xStackSpace()
{
  return initial_stack_size+CSTACK_HARDPROT+CSTACK_SOFTPROT;
}

#ifndef DARWIN
void *
xGetSharedLibrary(char *path, int mode)
{
  return dlopen(path, mode);
}
#else
void *
xGetSharedLibrary(char *path, int *resultType)
{
  NSObjectFileImageReturnCode code;
  NSObjectFileImage	         moduleImage;
  NSModule		         module;
  const struct mach_header *     header;
  const char *                   error;
  void *                         result;
  /* not thread safe */
  /*
  static struct {
    const struct mach_header  *header;
    NSModule	              *module;
    const char                *error;
  } results;	
  */
  result = NULL;
  error = NULL;

  /* first try to open this as a bundle */
  code = NSCreateObjectFileImageFromFile(path,&moduleImage);
  if (code != NSObjectFileImageSuccess &&
      code != NSObjectFileImageInappropriateFile &&
      code != NSObjectFileImageAccess)
    {
      /* compute error strings */
      switch (code)
	{
	case NSObjectFileImageFailure:
	  error = "NSObjectFileImageFailure";
	  break;
	case NSObjectFileImageArch:
	  error = "NSObjectFileImageArch";
	  break;
	case NSObjectFileImageFormat:
	  error = "NSObjectFileImageFormat";
	  break;
	case NSObjectFileImageAccess:
	  /* can't find the file */
	  error = "NSObjectFileImageAccess";
	  break;
	default:
	  error = "unknown error";
	}
      *resultType = 0;
      return (void *)error;
    }
  if (code == NSObjectFileImageInappropriateFile ||
      code == NSObjectFileImageAccess ) {
    /* the pathname might be a partial pathane (hence the access error)
       or it might be something other than a bundle, if so perhaps
       it is a .dylib so now try to open it as a .dylib */

    /* protect against redundant loads, Gary Byers noticed possible
       heap corruption if this isn't done */
    header = NSAddImage(path, NSADDIMAGE_OPTION_RETURN_ON_ERROR |
			NSADDIMAGE_OPTION_WITH_SEARCHING |
			NSADDIMAGE_OPTION_RETURN_ONLY_IF_LOADED);
    if (!header)
      header = NSAddImage(path, NSADDIMAGE_OPTION_RETURN_ON_ERROR |
			  NSADDIMAGE_OPTION_WITH_SEARCHING);
    result = (void *)header;
    *resultType = 1;
  }
  else if (code == NSObjectFileImageSuccess) {
    /* we have a sucessful module image
       try to link it, don't bind symbols privately */

    module = NSLinkModule(moduleImage, path,
			  NSLINKMODULE_OPTION_RETURN_ON_ERROR | NSLINKMODULE_OPTION_BINDNOW);
    NSDestroyObjectFileImage(moduleImage);	
    result = (void *)module;
    *resultType = 2;
  }
  if (!result)
    {
      /* compute error string */
      NSLinkEditErrors ler;
      int lerno;
      const char* file;
      NSLinkEditError(&ler,&lerno,&file,&error);
      if (error) {
	result = (void *)error;
	*resultType = 0;
      }
    }
  return result;
}
#endif




int
metering_control(int interval)
{
#ifdef DARWIN
  return -1;
#else
  if (interval) {
    if (! lisp_metering.active) {
      LispObj amf = nrs_ALLMETEREDFUNS.vcell;
      if (fulltag_of(amf) == fulltag_misc) {
        unsigned header = header_of(amf);

        if (header_subtag(header) == subtag_simple_vector) {

          lisp_metering.interval = interval;
          lisp_metering.total_hits = 0;
          lisp_metering.lisp_hits = 0;
          lisp_metering.active = header_element_count(header);
          return 0;
        }
      }
    }
    return -1;
  }  else {
    if (lisp_metering.active) {
      lisp_metering.active = 0;
      return 0;
    } else {
      return -1;
    }
  }
#endif
}





int
fd_setsize_bytes()
{
  return FD_SETSIZE/8;
}

void
do_fd_set(int fd, fd_set *fdsetp)
{
  FD_SET(fd, fdsetp);
}

void
do_fd_clr(int fd, fd_set *fdsetp)
{
  FD_CLR(fd, fdsetp);
}

int
do_fd_is_set(int fd, fd_set *fdsetp)
{
  return FD_ISSET(fd,fdsetp);
}

void
do_fd_zero(fd_set *fdsetp)
{
  FD_ZERO(fdsetp);
}

#include "image.h"


Boolean
check_for_embedded_image (char *path)
{
  int fd = open(path, O_RDONLY);
  Boolean image_is_embedded = false;

  if (fd >= 0) {
    openmcl_image_file_header h;

    if (find_openmcl_image_file_header (fd, &h)) {
      image_is_embedded = true;
    }
    close (fd);
  }
  return image_is_embedded;
}

LispObj
load_image(char *path)
{
  int fd = open(path, O_RDONLY, 0666);
  LispObj image_nil = 0;
  if (fd > 0) {
    openmcl_image_file_header ih;
    image_nil = load_openmcl_image(fd, &ih);
    /* We -were- using a duplicate fd to map the file; that
       seems to confuse Darwin (doesn't everything ?), so
       we'll instead keep the original file open.
    */
    if (!image_nil) {
      close(fd);
    }
  }
  if (image_nil == 0) {
    fprintf(stderr, "Couldn't load lisp heap image from %s\n", path);
    exit(-1);
  }
  return image_nil;
}

int
set_errno(int val)
{
  errno = val;
  return -1;
}




void *
xFindSymbol(void* handle, char *name)
{
#ifdef LINUX
  return dlsym(handle, name);
#endif
#ifdef DARWIN
#ifdef PPC64
  if (handle == NULL) {
    handle = RTLD_DEFAULT;
  }    
  if (*name == '_') {
    name++;
  }
  return dlsym(handle, name);
#else
  natural address = 0;

  if (handle == NULL) {
    if (NSIsSymbolNameDefined(name)) { /* Keep dyld_lookup from crashing */
      _dyld_lookup_and_bind(name, (void *) &address, (void*) NULL);
    }
    return (void *)address;
  }
  Bug(NULL, "How did this happen ?");
#endif
#endif
}


