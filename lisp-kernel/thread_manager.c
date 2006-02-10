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


#include "Threads.h"

#define WAIT_FOR_RESUME_ACK 0
#define RESUME_VIA_RESUME_SEMAPHORE 1
#define SUSPEND_RESUME_VERBOSE 0

typedef struct {
  TCR *tcr;
  void *created;
} thread_activation;

#ifdef HAVE_TLS
__thread TCR current_tcr;
#endif

extern natural
store_conditional(natural*, natural, natural);

extern signed_natural
atomic_swap(signed_natural*, signed_natural);

signed_natural
atomic_incf_by(signed_natural *ptr, signed_natural by)
{
  signed_natural old, new;
  do {
    old = *ptr;
    new = old+by;
  } while (store_conditional((natural *)ptr, (natural) old, (natural) new) !=
           (natural) old);
  return new;
}

signed_natural
atomic_incf(signed_natural *ptr)
{
  return atomic_incf_by(ptr, 1);
}

signed_natural
atomic_decf(signed_natural *ptr)
{
  signed_natural old, new;
  do {
    old = *ptr;
    new = old == 0 ? old : old-1;
  } while (store_conditional((natural *)ptr, (natural) old, (natural) new) !=
           (natural) old);
  return old-1;
}


int
lock_recursive_lock(RECURSIVE_LOCK m, TCR *tcr, struct timespec *waitfor)
{

  if (tcr == NULL) {
    tcr = get_tcr(true);
  }
  if (m->owner == tcr) {
    m->count++;
    return 0;
  }
  while (1) {
    if (atomic_incf(&m->avail) == 1) {
      m->owner = tcr;
      m->count = 1;
      break;
    }
    SEM_WAIT_FOREVER(m->signal);
  }
  return 0;
}
  
int
unlock_recursive_lock(RECURSIVE_LOCK m, TCR *tcr)
{
  int ret = EPERM, pending;

  if (tcr == NULL) {
    tcr = get_tcr(true);
  }

  if (m->owner == tcr) {
    --m->count;
    if (m->count == 0) {
      m->owner = NULL;
      pending = atomic_swap(&m->avail, 0) - 1;
      atomic_incf_by(&m->waiting, pending);
      /* We're counting on atomic_decf not actually decrementing
	 the location below 0, but returning a negative result
	 in that case.
      */
      if (atomic_decf(&m->waiting) >= 0) {
	SEM_RAISE(m->signal);
      }
      ret = 0;
    }
  }
  return ret;
}

void
destroy_recursive_lock(RECURSIVE_LOCK m)
{
  destroy_semaphore((void **)&m->signal);
  postGCfree((void *)(m->malloced_ptr));
}

/*
  If we're already the owner (or if the lock is free), lock it
  and increment the lock count; otherwise, return EBUSY without
  waiting.
*/

int
recursive_lock_trylock(RECURSIVE_LOCK m, TCR *tcr, int *was_free)
{
  TCR *owner = m->owner;

  if (owner == tcr) {
    m->count++;
    if (was_free) {
      *was_free = 0;
      return 0;
    }
  }
  if (store_conditional((natural*)&(m->avail), 0, 1) == 0) {
    m->owner = tcr;
    m->count = 1;
    if (was_free) {
      *was_free = 1;
    }
    return 0;
  }

  return EBUSY;
}

void
sem_wait_forever(SEMAPHORE s)
{
  int status;

  do {
    status = SEM_WAIT(s);
  } while (status != 0);
}

int
wait_on_semaphore(SEMAPHORE s, int seconds, int millis)
{
  int nanos = (millis % 1000) * 1000000;
#ifdef LINUX
  int status;

  struct timespec q;
  gettimeofday((struct timeval *)&q, NULL);
  q.tv_nsec *= 1000L;
    
  q.tv_nsec += nanos;
  if (q.tv_nsec >= 1000000000L) {
    q.tv_nsec -= 1000000000L;
    seconds += 1;
  }
  q.tv_sec += seconds;
  status = SEM_TIMEDWAIT(s, &q);
  if (status < 0) {
    return errno;
  }
  return status;
#endif
#ifdef DARWIN  
  mach_timespec_t q = {seconds, nanos};
  int status = SEM_TIMEDWAIT(s, q);

  
  switch (status) {
  case 0: return 0;
  case KERN_OPERATION_TIMED_OUT: return ETIMEDOUT;
  case KERN_ABORTED: return EINTR;
  default: return EINVAL;
  }

#endif
}


void
signal_semaphore(SEMAPHORE s)
{
  SEM_RAISE(s);
}

  
LispObj
current_thread_osid()
{
  return (LispObj)ptr_to_lispobj(pthread_self());
}

#ifdef SIGRTMIN
#define SIG_SUSPEND_THREAD (SIGRTMIN+6)
#define SIG_RESUME_THREAD (SIG_SUSPEND_THREAD+1)
#else
#define SIG_SUSPEND_THREAD SIGUSR1
#define SIG_RESUME_THREAD SIGUSR2
#endif


int thread_suspend_signal, thread_resume_signal;



void
linux_exception_init(TCR *tcr)
{
}


TCR *
get_interrupt_tcr(Boolean create)
{
  return get_tcr(create);
}
  
  
void
suspend_resume_handler(int signo, siginfo_t *info, ExceptionInformation *context)
{
  TCR *tcr = get_interrupt_tcr(false);

  if (signo == thread_suspend_signal) {
    sigset_t wait_for;

    tcr->suspend_context = context;
    sigfillset(&wait_for);
    SEM_RAISE(tcr->suspend);
    sigdelset(&wait_for, thread_resume_signal);
#if 1
#if RESUME_VIA_RESUME_SEMAPHORE
    SEM_WAIT_FOREVER(tcr->resume);
#if SUSPEND_RESUME_VERBOSE
    fprintf(stderr, "got  resume in 0x%x\n",tcr);
#endif
    tcr->suspend_context = NULL;
#else
    sigsuspend(&wait_for);
#endif
#else
    do {
      sigsuspend(&wait_for);
    } while (tcr->suspend_context);
#endif  
  } else {
    tcr->suspend_context = NULL;
#if SUSEPEND_RESUME_VERBOSE
    fprintf(stderr,"got  resume in in 0x%x\n",tcr);
#endif
#if WAIT_FOR_RESUME_ACK
    SEM_RAISE(tcr->resume);
#endif
  }
#ifdef DARWIN
  DarwinSigReturn(context);
#endif
}

void
thread_signal_setup()
{
  struct sigaction action;
  sigset_t mask, old_mask;
  
  sigemptyset(&mask);
  pthread_sigmask(SIG_SETMASK, &mask, &old_mask);

  thread_suspend_signal = SIG_SUSPEND_THREAD;
  thread_resume_signal = SIG_RESUME_THREAD;
  sigfillset(&action.sa_mask);
  sigdelset(&action.sa_mask,thread_suspend_signal);
  action.sa_flags = 
    SA_RESTART 
    | SA_SIGINFO 
#ifdef DARWIN
#ifdef PPC64
    | SA_64REGSET
#endif
#endif
    ;
  action.sa_sigaction = (void *) suspend_resume_handler;
  sigaction(thread_suspend_signal, &action, NULL);
  sigaction(thread_resume_signal, &action, NULL);
}
  

/*
  'base' should be set to the bottom (origin) of the stack, e.g., the
  end from which it grows.
*/
  
void
os_get_stack_bounds(LispObj q,void **base, natural *size)
{
  pthread_t p = (pthread_t)ptr_from_lispobj(q);
#ifdef DARWIN
  *base = pthread_get_stackaddr_np(p);
  *size = pthread_get_stacksize_np(p);
#endif
#ifdef LINUX
  pthread_attr_t attr;
  
  pthread_getattr_np(p,&attr);
  pthread_attr_getstack(&attr, base, size);
  *(natural *)base += *size;
#endif
}

void *
new_semaphore(int count)
{
#ifdef LINUX
  sem_t *s = malloc(sizeof(sem_t));
  sem_init(s, 0, count);
  return s;
#endif
#ifdef DARWIN
  semaphore_t s = (semaphore_t)0;
  semaphore_create(mach_task_self(),&s, SYNC_POLICY_FIFO, count);
  return (void *)(natural)s;
#endif
}

RECURSIVE_LOCK
new_recursive_lock()
{
  extern int cache_block_size;
  void *p = calloc(1,sizeof(_recursive_lock)+cache_block_size-1);
  RECURSIVE_LOCK m = NULL;
  void *signal = new_semaphore(0);

  if (p) {
    m = (RECURSIVE_LOCK) ((((natural)p)+cache_block_size-1) & (~(cache_block_size-1)));
    m->malloced_ptr = p;
  }

  if (m && signal) {
    m->signal = signal;
    return m;
  }
  if (m) {
    free(p);
  }
  if (signal) {
    destroy_semaphore(&signal);
  }
  return NULL;
}

void
destroy_semaphore(void **s)
{
  if (*s) {
#ifdef LINUX
    sem_destroy((sem_t *)*s);
#endif
#ifdef DARWIN
    semaphore_destroy(mach_task_self(),((semaphore_t)(natural) *s));
#endif
    *s=NULL;
  }
}

void
tsd_set(LispObj key, void *datum)
{
  pthread_setspecific((pthread_key_t)key, datum);
}

void *
tsd_get(LispObj key)
{
  return pthread_getspecific((pthread_key_t)key);
}

void
dequeue_tcr(TCR *tcr)
{
  TCR *next, *prev;

  next = tcr->next;
  prev = tcr->prev;

  prev->next = next;
  next->prev = prev;
  tcr->prev = tcr->next = NULL;
}
  
void
enqueue_tcr(TCR *new)
{
  TCR *head, *tail;
  
  LOCK(lisp_global(TCR_LOCK),new);
  head = (TCR *)ptr_from_lispobj(lisp_global(INITIAL_TCR));
  tail = head->prev;
  tail->next = new;
  head->prev = new;
  new->prev = tail;
  new->next = head;
  UNLOCK(lisp_global(TCR_LOCK),new);
}

TCR *
allocate_tcr()
{
  TCR *tcr, *chain = NULL, *next;
#ifdef DARWIN
  extern Boolean use_mach_exception_handling;
  kern_return_t kret;
  mach_port_t 
    thread_exception_port,
    task_self = mach_task_self();
#endif
  for (;;) {
    tcr = calloc(1, sizeof(TCR));
#ifdef DARWIN
#ifdef PPC64
    if (((unsigned)((natural)tcr)) != ((natural)tcr)) {
      tcr->next = chain;
      chain = tcr;
      continue;
    }
#endif
    if (use_mach_exception_handling) {
      thread_exception_port = (mach_port_t)((natural)tcr);
      kret = mach_port_allocate_name(task_self,
                                     MACH_PORT_RIGHT_RECEIVE,
                                     thread_exception_port);
    } else {
      kret = KERN_SUCCESS;
    }

    if (kret != KERN_SUCCESS) {
      tcr->next = chain;
      chain = tcr;
      continue;
    }
#endif
    for (next = chain; next;) {
      next = next->next;
      free(chain);
    }
    return tcr;
  }
}




/*
  Caller must hold the area_lock.
*/
TCR *
new_tcr(unsigned vstack_size, unsigned tstack_size)
{
  extern area
    *allocate_vstack_holding_area_lock(unsigned),
    *allocate_tstack_holding_area_lock(unsigned);
  area *a;
#ifdef HAVE_TLS
  TCR *tcr = &current_tcr;
#else
  TCR *tcr = allocate_tcr();
#endif
  int i;

#ifdef PPC64
  tcr->single_float_convert.tag = subtag_single_float;
#endif
  lisp_global(TCR_COUNT) += (1<<fixnumshift);
  tcr->suspend = new_semaphore(0);
  tcr->resume = new_semaphore(0);
  tcr->reset_completion = new_semaphore(0);
  tcr->activate = new_semaphore(0);
  a = allocate_vstack_holding_area_lock(vstack_size);
  tcr->vs_area = a;
  tcr->save_vsp = (LispObj *) a->active;  
  a = allocate_tstack_holding_area_lock(tstack_size);
  tcr->ts_area = a;
  tcr->save_tsp = (LispObj *) a->active;
  tcr->valence = TCR_STATE_FOREIGN;
  tcr->lisp_fpscr.words.l = 0xd0;
  tcr->save_allocbase = tcr->save_allocptr = (void *) VOID_ALLOCPTR;
  tcr->tlb_limit = 2048<<fixnumshift;
  tcr->tlb_pointer = (LispObj *)malloc(tcr->tlb_limit);
  for (i = 0; i < 2048; i++) {
    tcr->tlb_pointer[i] = (LispObj) no_thread_local_binding_marker;
  }
  TCR_INTERRUPT_LEVEL(tcr) = (LispObj) (-1<<fixnum_shift);
  tcr->shutdown_count = PTHREAD_DESTRUCTOR_ITERATIONS;
  return tcr;
}

void
shutdown_thread_tcr(void *arg)
{
  TCR *tcr = TCR_FROM_TSD(arg);

  area *vs, *ts, *cs;
  void *termination_semaphore;
  
  if (--(tcr->shutdown_count) == 0) {
    if (tcr->flags & (1<<TCR_FLAG_BIT_FOREIGN)) {
      LispObj callback_macptr = nrs_FOREIGN_THREAD_CONTROL.vcell,
	callback_ptr = ((macptr *)ptr_from_lispobj(untag(callback_macptr)))->address;
    
      tsd_set(lisp_global(TCR_KEY), TCR_TO_TSD(tcr));
      ((void (*)())ptr_from_lispobj(callback_ptr))(1);
      tsd_set(lisp_global(TCR_KEY), NULL);
    }
#ifdef DARWIN
    darwin_exception_cleanup(tcr);
#endif
    LOCK(lisp_global(AREA_LOCK),tcr);
    vs = tcr->vs_area;
    tcr->vs_area = NULL;
    ts = tcr->ts_area;
    tcr->ts_area = NULL;
    cs = tcr->cs_area;
    tcr->cs_area = NULL;
    if (vs) {
      condemn_area_holding_area_lock(vs);
    }
    if (ts) {
      condemn_area_holding_area_lock(ts);
    }
    if (cs) {
      condemn_area_holding_area_lock(cs);
    }
    destroy_semaphore(&tcr->suspend);
    destroy_semaphore(&tcr->resume);
    destroy_semaphore(&tcr->reset_completion);
    destroy_semaphore(&tcr->activate);
    free(tcr->tlb_pointer);
    tcr->tlb_pointer = NULL;
    tcr->tlb_limit = 0;
    tcr->osid = 0;
    termination_semaphore = tcr->termination_semaphore;
    tcr->termination_semaphore = NULL;
    UNLOCK(lisp_global(AREA_LOCK),tcr);
    if (termination_semaphore) {
      SEM_RAISE(termination_semaphore);
    }
  } else {
    tsd_set(lisp_global(TCR_KEY), TCR_TO_TSD(tcr));
  }
}

void *
current_native_thread_id()
{
  return ((void *) (natural)
#ifdef LINUX
          getpid()
#endif
#ifdef DARWIN
	  mach_thread_self()
#endif
#ifdef FREEBSD
	  pthread_self()
#endif
	  );
}

void
thread_init_tcr(TCR *tcr, void *stack_base, natural stack_size)
{
  area *a, *register_cstack_holding_area_lock(BytePtr, unsigned);

  tcr->osid = current_thread_osid();
  tcr->native_thread_id = current_native_thread_id();
  LOCK(lisp_global(AREA_LOCK),tcr);
  a = register_cstack_holding_area_lock((BytePtr)stack_base, stack_size);
  UNLOCK(lisp_global(AREA_LOCK),tcr);
  tcr->cs_area = a;
  if (!(tcr->flags & (1<<TCR_FLAG_BIT_FOREIGN))) {
    tcr->cs_limit = (LispObj)ptr_to_lispobj(a->softlimit);
  }
#ifdef LINUX
#ifdef PPC
#ifndef PPC64
  tcr->native_thread_info = current_r2;
#endif
#endif
#endif
  tcr->errno_loc = &errno;
  tsd_set(lisp_global(TCR_KEY), TCR_TO_TSD(tcr));
#ifdef DARWIN
  extern Boolean use_mach_exception_handling;
  if (use_mach_exception_handling) {
    darwin_exception_init(tcr);
  }
#endif
#ifdef LINUX
  linux_exception_init(tcr);
#endif
  tcr->log2_allocation_quantum = unbox_fixnum(lisp_global(DEFAULT_ALLOCATION_QUANTUM));
}

/*
  Register the specified tcr as "belonging to" the current thread.
  Under Darwin, setup Mach exception handling for the thread.
  Install cleanup handlers for thread termination.
*/
void
register_thread_tcr(TCR *tcr)
{
  void *stack_base;
  natural stack_size;

  os_get_stack_bounds(current_thread_osid(),&stack_base, &stack_size);
  thread_init_tcr(tcr, stack_base, stack_size);
  enqueue_tcr(tcr);
}


  
  
#ifndef MAP_GROWSDOWN
#define MAP_GROWSDOWN 0
#endif

Ptr
create_stack(int size)
{
  Ptr p;
  size=align_to_power_of_2(size, log2_page_size);
  p = (Ptr) mmap(NULL,
		     (size_t)size,
		     PROT_READ | PROT_WRITE | PROT_EXEC,
		     MAP_PRIVATE | MAP_ANON | MAP_GROWSDOWN,
		     -1,	/* Darwin insists on this when not mmap()ing
				 a real fd */
		     0);
  if (p != (Ptr)(-1)) {
    *((size_t *)p) = size;
    return p;
  }
  allocation_failure(true, size);

}
  
void *
allocate_stack(unsigned size)
{
  return create_stack(size);
}

void
free_stack(void *s)
{
  size_t size = *((size_t *)s);
  munmap(s, size);
}

Boolean threads_initialized = false;

void
init_threads(void * stack_base, TCR *tcr)
{
  lisp_global(INITIAL_TCR) = (LispObj)ptr_to_lispobj(tcr);
  pthread_key_create((pthread_key_t *)&(lisp_global(TCR_KEY)), shutdown_thread_tcr);
  thread_signal_setup();
  threads_initialized = true;
}


void *
lisp_thread_entry(void *param)
{
  thread_activation *activation = (thread_activation *)param;
  TCR *tcr = activation->tcr;
  sigset_t mask, old_mask;

  sigemptyset(&mask);
  pthread_sigmask(SIG_SETMASK, &mask, &old_mask);

  register_thread_tcr(tcr);
  tcr->vs_area->active -= node_size;
  *(--tcr->save_vsp) = lisp_nil;
  enable_fp_exceptions();
  tcr->flags |= (1<<TCR_FLAG_BIT_AWAITING_PRESET);
  SEM_RAISE(activation->created);
  do {
    SEM_RAISE(tcr->reset_completion);
    SEM_WAIT_FOREVER(tcr->activate);
    /* Now go run some lisp code */
    start_lisp(TCR_TO_TSD(tcr),0);
  } while (tcr->flags & (1<<TCR_FLAG_BIT_AWAITING_PRESET));
}

void *
xNewThread(natural control_stack_size,
	   natural value_stack_size,
	   natural temp_stack_size)

{
  thread_activation activation;
  TCR *current = get_tcr(false);

  LOCK(lisp_global(AREA_LOCK),current);
  activation.tcr = new_tcr(value_stack_size, temp_stack_size);
  UNLOCK(lisp_global(AREA_LOCK),current);
  if (activation.tcr) {
    activation.created = new_semaphore(0);
    if (create_system_thread(control_stack_size +(CSTACK_HARDPROT+CSTACK_SOFTPROT), 
                             NULL, 
                             lisp_thread_entry,
                             (void *) &activation)) {
      
      SEM_WAIT_FOREVER(activation.created);	/* Wait until thread's entered its initial function */
    } else {
      activation.tcr->shutdown_count = 1;
      shutdown_thread_tcr(TCR_TO_TSD(activation.tcr));
    }
    destroy_semaphore(&activation.created);
  }
  return TCR_TO_TSD(activation.tcr);
}

Boolean
active_tcr_p(TCR *q)
{
  TCR *head = (TCR *)ptr_from_lispobj(lisp_global(INITIAL_TCR)), *p = head;
  
  do {
    if (p == q) {
      return true;
    }
    p = p->next;
  } while (p != head);
  return false;
}


OSErr
xDisposeThread(TCR *tcr)
{
  if (tcr != (TCR *)ptr_from_lispobj(lisp_global(INITIAL_TCR))) {
    if (active_tcr_p(tcr) && (tcr != get_tcr(false))) {
      pthread_cancel((pthread_t)ptr_from_lispobj(tcr->osid));
      return 0;
    }
  }
  return -50;
}

OSErr
xYieldToThread(TCR *target)
{
  Bug(NULL, "xYieldToThread ?");
  return 0;
}
  
OSErr
xThreadCurrentStackSpace(TCR *tcr, unsigned *resultP)
{
  Bug(NULL, "xThreadCurrentStackSpace ?");
  return 0;
}


LispObj
create_system_thread(size_t stack_size,
		     void* stackaddr,
		     void* (*start_routine)(void *),
		     void* param)
{
  pthread_attr_t attr;
  pthread_t returned_thread = (pthread_t) 0;

  pthread_attr_init(&attr);
  pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);  

  if (stack_size == MINIMAL_THREAD_STACK_SIZE) {
    stack_size = PTHREAD_STACK_MIN;
  }

  if (stackaddr != NULL) {
    /* Size must have been specified.  Sort of makes sense ... */
#ifdef DARWIN
    Fatal("no pthread_attr_setsetstack. "," Which end of stack does address refer to?");
#else
    pthread_attr_setstack(&attr, stackaddr, stack_size);
#endif
  } else if (stack_size != DEFAULT_THREAD_STACK_SIZE) {
    pthread_attr_setstacksize(&attr,stack_size);
  }

  /* 
     I think that's just about enough ... create the thread.
  */
  pthread_create(&returned_thread, &attr, start_routine, param);
  return (LispObj) ptr_to_lispobj(returned_thread);
}

TCR *
get_tcr(Boolean create)
{
  void *tsd = (void *)tsd_get(lisp_global(TCR_KEY));
  TCR *current = (tsd == NULL) ? NULL : TCR_FROM_TSD(tsd);

  if ((current == NULL) && create) {
    LispObj callback_macptr = nrs_FOREIGN_THREAD_CONTROL.vcell,
      callback_ptr = ((macptr *)ptr_from_lispobj(untag(callback_macptr)))->address;
    int i, nbindwords = 0;
    extern unsigned initial_stack_size;
    
    /* Make one. */
    current = new_tcr(initial_stack_size, MIN_TSTACK_SIZE);
    current->flags |= (1<<TCR_FLAG_BIT_FOREIGN);
    register_thread_tcr(current);
#ifdef DEBUG_TCR_CREATION
    fprintf(stderr, "\ncreating TCR for pthread 0x%x", pthread_self());
#endif
    current->vs_area->active -= 4;
    *(--current->save_vsp) = lisp_nil;
    nbindwords = ((int (*)())ptr_from_lispobj(callback_ptr))(-1);
    for (i = 0; i < nbindwords; i++) {
      *(--current->save_vsp) = 0;
      current->vs_area->active -= 4;
    }
    current->shutdown_count = 1;
    ((void (*)())ptr_from_lispobj(callback_ptr))(0);

  }
  
  return current;
}


Boolean
suspend_tcr(TCR *tcr)
{
  int suspend_count = atomic_incf(&(tcr->suspend_count));
  if (suspend_count == 1) {
#ifdef DARWIN_but_this_is_tricky
#if SUSPEND_RESUME_VERBOSE
    fprintf(stderr,"Mach suspend to 0x%x\n", tcr);
#endif
    if (mach_suspend_tcr(tcr)) {
      tcr->flags |= (1<<TCR_FLAG_BIT_ALT_SUSPEND);
      return true;
    }
#endif
    if (pthread_kill((pthread_t)ptr_from_lispobj(tcr->osid), thread_suspend_signal) == 0) {
      SEM_WAIT_FOREVER(tcr->suspend);
    } else {
      /* A problem using pthread_kill.  On Darwin, this can happen
	 if the thread has had its signal mask surgically removed
	 by pthread_exit.  If the native (Mach) thread can be suspended,
	 do that and return true; otherwise, flag the tcr as belonging
	 to a dead thread by setting tcr->osid to 0.
      */
#ifdef DARWIN
      if (mach_suspend_tcr(tcr)) {
	tcr->flags |= (1<<TCR_FLAG_BIT_ALT_SUSPEND);
	return true;
      }
#endif
      tcr->osid = 0;
      return false;
    }
    return true;
  }
  return false;
}

Boolean
lisp_suspend_tcr(TCR *tcr)
{
  Boolean suspended;
  TCR *current = get_tcr(true);
  
  LOCK(lisp_global(TCR_LOCK),current);
#ifdef DARWIN
  if (use_mach_exception_handling) {
    pthread_mutex_lock(mach_exception_lock);
  }
#endif
  suspended = suspend_tcr(tcr);
#ifdef DARWIN
  if (use_mach_exception_handling) {
    pthread_mutex_unlock(mach_exception_lock);
  }
#endif
  UNLOCK(lisp_global(TCR_LOCK),current);
  return suspended;
}
	 

Boolean
resume_tcr(TCR *tcr)
{
  int suspend_count = atomic_decf(&(tcr->suspend_count)), err;
  if (suspend_count == 0) {
#ifdef DARWIN
#if SUSPEND_RESUME_VERBOSE
    fprintf(stderr,"Mach resume to 0x%x\n", tcr);
#endif
    if (tcr->flags & (1<<TCR_FLAG_BIT_ALT_SUSPEND)) {
      mach_resume_tcr(tcr);
      return true;
    }
#endif
#if RESUME_VIA_RESUME_SEMAPHORE
    SEM_RAISE(tcr->resume);
#else
    if ((err = (pthread_kill((pthread_t)ptr_from_lispobj(tcr->osid), thread_resume_signal))) != 0) {
      Bug(NULL, "pthread_kill returned %d on thread #x%x", err, tcr->osid);
    }
#endif
#if SUSPEND_RESUME_VERBOSE
    fprintf(stderr, "Sent resume to 0x%x\n", tcr);
#endif
    return true;
  }
  return false;
}

void
wait_for_resumption(TCR *tcr)
{
  if (tcr->suspend_count == 0) {
#ifdef DARWIN
    if (tcr->flags & (1<<TCR_FLAG_BIT_ALT_SUSPEND)) {
      tcr->flags &= ~(1<<TCR_FLAG_BIT_ALT_SUSPEND);
      return;
  }
#endif
#if WAIT_FOR_RESUME_ACK
    fprintf(stderr, "waiting for resume in 0x%x\n",tcr);
    SEM_WAIT_FOREVER(tcr->resume);
#endif
  }
}
    


Boolean
lisp_resume_tcr(TCR *tcr)
{
  Boolean resumed;
  TCR *current = get_tcr(true);
  
  LOCK(lisp_global(TCR_LOCK),current);
  resumed = resume_tcr(tcr);
  wait_for_resumption(tcr);
  UNLOCK(lisp_global(TCR_LOCK), current);
  return resumed;
}


TCR *freed_tcrs = NULL;

void
enqueue_freed_tcr (TCR *tcr)
{
  tcr->next = freed_tcrs;
  freed_tcrs = tcr;
}

void
free_freed_tcrs ()
{
  TCR *current, *next;

  for (current = freed_tcrs; current; current = next) {
    next = current->next;
    free(current);
  }
  freed_tcrs = NULL;
}

void
suspend_other_threads(Boolean for_gc)
{
  TCR *current = get_tcr(true), *other, *next;
  int dead_tcr_count = 0;

  LOCK(lisp_global(TCR_LOCK), current);
  LOCK(lisp_global(AREA_LOCK), current);
#ifdef DARWIN
  if (for_gc && use_mach_exception_handling) {
#ifdef DEBUG_MACH_EXCEPTIONS
    fprintf(stderr, "obtaining Mach exception lock in GC thread\n");
#endif
    pthread_mutex_lock(mach_exception_lock);
  }
#endif
  for (other = current->next; other != current; other = other->next) {
    if ((other->osid != 0)) {
      suspend_tcr(other);
      if (other->osid == 0) {
	dead_tcr_count++;
      }
    } else {
      dead_tcr_count++;
    }
  }
  /* All other threads are suspended; can safely delete dead tcrs now */
  if (dead_tcr_count) {
    for (other = current->next; other != current; other = next) {
      next = other->next;
      if ((other->osid == 0))  {
	dequeue_tcr(other);
	enqueue_freed_tcr(other);
      }
    }
  }
}

void
lisp_suspend_other_threads()
{
  suspend_other_threads(false);
}

void
resume_other_threads(Boolean for_gc)
{
  TCR *current = get_tcr(true), *other;
  for (other = current->next; other != current; other = other->next) {
    if ((other->osid != 0)) {
      resume_tcr(other);
    }
  }
  for (other = current->next; other != current; other = other->next) {
    if ((other->osid != 0)) {
      wait_for_resumption(other);
    }
  }
  free_freed_tcrs();
#ifdef DARWIN
  if (for_gc && use_mach_exception_handling) {
#ifdef DEBUG_MACH_EXCEPTIONS
    fprintf(stderr, "releasing Mach exception lock in GC thread\n");
#endif
    pthread_mutex_unlock(mach_exception_lock);
  }
#endif

  UNLOCK(lisp_global(AREA_LOCK), current);
  UNLOCK(lisp_global(TCR_LOCK), current);
}

void
lisp_resume_other_threads()
{
  resume_other_threads(false);
}


/*
  Try to take an rwquentry off of the rwlock's freelist; failing that,
  malloc one.  The caller owns the lock on the rwlock itself, of course.

*/
rwquentry *
recover_rwquentry(rwlock *rw)
{
  rwquentry *freelist = &(rw->freelist), 
    *p = freelist->next, 
    *follow = p->next;

  if (p == freelist) {
    p = NULL;
  } else {
    follow->prev = freelist;
    freelist->next = follow;
    p->prev = p->next = NULL;
    p->tcr = NULL;
    p->count = 0;
  }
  return p;
}

rwquentry *
new_rwquentry(rwlock *rw)
{
  rwquentry *p = recover_rwquentry(rw);

  if (p == NULL) {
    p = calloc(1, sizeof(rwquentry));
  }
  return p;
}


void
free_rwquentry(rwquentry *p, rwlock *rw)
{
  rwquentry 
    *prev = p->prev, 
    *next = p->next, 
    *freelist = &(rw->freelist),
    *follow = freelist->next;
  
  prev->next = next;
  next->prev = prev;
  p->prev = freelist;
  freelist->next = p;
  follow->prev = p;
  p->next = follow;
  p->prev = freelist;
}
  
void
add_rwquentry(rwquentry *p, rwlock *rw)
{
  rwquentry
    *head = &(rw->head),
    *follow = head->next;
  
  head->next = p;
  follow->prev = p;
  p->next = follow;
  p->prev = head;
}

rwquentry *
find_enqueued_tcr(TCR *target, rwlock *rw)
{
  rwquentry
    *head = &(rw->head),
    *p = head->next;

  do {
    if (p->tcr == target) {
      return p;
    }
    p = p->next;
  } while (p != head);
  return NULL;
}
    
rwlock *
rwlock_new()
{
  rwlock *rw = calloc(1, sizeof(rwlock));
  
  if (rw) {
    pthread_mutex_t *lock = calloc(1, sizeof(pthread_mutex_t));
    if (lock == NULL) {
      free (rw);
      rw = NULL;
    } else {
      pthread_cond_t *reader_signal = calloc(1, sizeof(pthread_cond_t));
      pthread_cond_t *writer_signal = calloc(1, sizeof(pthread_cond_t));
      if ((reader_signal == NULL) || (writer_signal == NULL)) {
        if (reader_signal) {
          free(reader_signal);
        } else {
          free(writer_signal);
        }
       
        free(lock);
        free(rw);
        rw = NULL;
      } else {
        pthread_mutex_init(lock, NULL);
        pthread_cond_init(reader_signal, NULL);
        pthread_cond_init(writer_signal, NULL);
        rw->lock = lock;
        rw->reader_signal = reader_signal;
        rw->writer_signal = writer_signal;
        rw->head.prev = rw->head.next = &(rw->head);
        rw->freelist.prev = rw->freelist.next = &(rw->freelist);
      }
    }
  }
  return rw;
}

/*
  no thread should be waiting on the lock, and the caller has just
  unlocked it.
*/
static void
rwlock_delete(rwlock *rw)
{
  pthread_mutex_t *lock = rw->lock;
  pthread_cond_t *cond;
  rwquentry *entry;

  rw->lock = NULL;
  cond = rw->reader_signal;
  rw->reader_signal = NULL;
  pthread_cond_destroy(cond);
  free(cond);
  cond = rw->writer_signal;
  rw->writer_signal = NULL;
  pthread_cond_destroy(cond);
  free(cond);
  while (entry = recover_rwquentry(rw)) {
    free(entry);
  }
  free(rw);
  pthread_mutex_unlock(lock);
  free(lock);
}

void
rwlock_rlock_cleanup(void *arg)
{
  pthread_mutex_unlock((pthread_mutex_t *)arg);
}
     
/*
  Try to get read access to a multiple-readers/single-writer lock.  If
  we already have read access, return success (indicating that the
  lock is held another time.  If we already have write access to the
  lock ... that won't work; return EDEADLK.  Wait until no other
  thread has or is waiting for write access, then indicate that we
  hold read access once.
*/
int
rwlock_rlock(rwlock *rw, TCR *tcr, struct timespec *waitfor)
{
  pthread_mutex_t *lock = rw->lock;
  rwquentry *entry;
  int err = 0;


  pthread_mutex_lock(lock);

  if (RWLOCK_WRITER(rw) == tcr) {
    pthread_mutex_unlock(lock);
    return EDEADLK;
  }

  if (rw->state > 0) {
    /* already some readers, we may be one of them */
    entry = find_enqueued_tcr(tcr, rw);
    if (entry) {
      entry->count++;
      rw->state++;
      pthread_mutex_unlock(lock);
      return 0;
    }
  }
  entry = new_rwquentry(rw);
  entry->tcr = tcr;
  entry->count = 1;

  pthread_cleanup_push(rwlock_rlock_cleanup,lock);

  /* Wait for current and pending writers */
  while ((err == 0) && ((rw->state < 0) || (rw->write_wait_count > 0))) {
    if (waitfor) {
      if (pthread_cond_timedwait(rw->reader_signal, lock, waitfor)) {
        err = errno;
      }
    } else {
      pthread_cond_wait(rw->reader_signal, lock);
    }
  }
  
  if (err == 0) {
    add_rwquentry(entry, rw);
    rw->state++;
  }

  pthread_cleanup_pop(1);
  return err;
}


/* 
   This is here to support cancelation.  Cancelation is evil. 
*/

void
rwlock_wlock_cleanup(void *arg)
{
  rwlock *rw = (rwlock *)arg;

  /* If this thread was the only queued writer and the lock
     is now available for reading, tell any threads that're
     waiting for read access.
     This thread owns the lock on the rwlock itself.
  */
  if ((--(rw->write_wait_count) == 0) &&
      (rw->state >= 0)) {
    pthread_cond_broadcast(rw->reader_signal);
  }
  
  pthread_mutex_unlock(rw->lock);
}

/*
  Try to obtain write access to the lock.
  If we already have read access, fail with EDEADLK.
  If we already have write access, increment the count that indicates
  that.
  Otherwise, wait until the lock is not held for reading or writing,
  then assert write access.
*/

int
rwlock_wlock(rwlock *rw, TCR *tcr, struct timespec *waitfor)
{
  pthread_mutex_t *lock = rw->lock;
  rwquentry *entry;
  int err = 0;


  pthread_mutex_lock(lock);
  if (RWLOCK_WRITER(rw) == tcr) {
    --RWLOCK_WRITE_COUNT(rw);
    --rw->state;
    pthread_mutex_unlock(lock);
    return 0;
  }
  
  if (rw->state > 0) {
    /* already some readers, we may be one of them */
    entry = find_enqueued_tcr(tcr, rw);
    if (entry) {
      pthread_mutex_unlock(lock);
      return EDEADLK;
    }
  }
  rw->write_wait_count++;
  pthread_cleanup_push(rwlock_wlock_cleanup,rw);

  while ((err == 0) && (rw->state) != 0) {
    if (waitfor) {
      if (pthread_cond_timedwait(rw->writer_signal, lock, waitfor)) {
        err = errno;
      }
    } else {
      pthread_cond_wait(rw->writer_signal, lock);
    }
  }
  if (err == 0) {
    RWLOCK_WRITER(rw) = tcr;
    RWLOCK_WRITE_COUNT(rw) = -1;
    rw->state = -1;
  }
  pthread_cleanup_pop(1);
  return err;
}

/*
  Sort of the same as above, only return EBUSY if we'd have to wait.
  In partucular, distinguish between the cases of "some other readers
  (EBUSY) another writer/queued writer(s)" (EWOULDBLOK) and "we hold a
  read lock" (EDEADLK.)
*/
int
rwlock_try_wlock(rwlock *rw, TCR *tcr)
{
  pthread_mutex_t *lock = rw->lock;
  rwquentry *entry;
  int ret = EBUSY;

  pthread_mutex_lock(lock);
  if ((RWLOCK_WRITER(rw) == tcr) ||
      ((rw->state == 0) && (rw->write_wait_count == 0))) {
    RWLOCK_WRITER(rw) = tcr;
    --RWLOCK_WRITE_COUNT(rw);
    --rw->state;
    pthread_mutex_unlock(lock);
    return 0;
  }
  
  if (rw->state > 0) {
    /* already some readers, we may be one of them */
    entry = find_enqueued_tcr(tcr, rw);
    if (entry) {
      ret = EDEADLK;
    }
  } else {
    /* another writer or queued writers */
    ret = EWOULDBLOCK;
  }
  pthread_mutex_unlock(rw->lock);
  return ret;
}

/*
  "Upgrade" a lock held once or more for reading to one held the same
  number of times for writing.
  Upgraders have higher priority than writers do
*/

int
rwlock_read_to_write(rwlock *rw, TCR *tcr)
{
}


int
rwlock_unlock(rwlock *rw, TCR *tcr)
{
  rwquentry *entry;

  pthread_mutex_lock(rw->lock);
  if (rw->state < 0) {
    /* Locked for writing.  By us ? */
    if (RWLOCK_WRITER(rw) != tcr) {
      pthread_mutex_unlock(rw->lock);
      /* Can't unlock: locked for writing by another thread. */
      return EPERM;
    }
    if (++RWLOCK_WRITE_COUNT(rw) == 0) {
      rw->state = 0;
      RWLOCK_WRITER(rw) = NULL;
      if (rw->write_wait_count) {
        pthread_cond_signal(rw->writer_signal);
      } else {
        pthread_cond_broadcast(rw->reader_signal);
      }
    }
    pthread_mutex_unlock(rw->lock);
    return 0;
  }
  entry = find_enqueued_tcr(tcr, rw);
  if (entry == NULL) {
    /* Not locked for reading by us, so why are we unlocking it ? */
    pthread_mutex_unlock(rw->lock);
    return EPERM;
  }
  if (--entry->count == 0) {
    free_rwquentry(entry, rw);
  }
  if (--rw->state == 0) {
    pthread_cond_signal(rw->writer_signal);
  }
  pthread_mutex_unlock(rw->lock);
  return 0;
}

        
int
rwlock_destroy(rwlock *rw)
{
  return 0;                     /* for now. */
}

/*
  A binding subprim has just done "twlle limit_regno,idx_regno" and
  the trap's been taken.  Extend the tcr's tlb so that the index will
  be in bounds and the new limit will be on a page boundary, filling
  in the new page(s) with 'no_thread_local_binding_marker'.  Update
  the tcr fields and the registers in the xp and return true if this
  all works, false otherwise.

  Note that the tlb was allocated via malloc, so realloc can do some
  of the hard work.
*/
Boolean
extend_tcr_tlb(TCR *tcr, 
               ExceptionInformation *xp, 
               unsigned limit_regno,
               unsigned idx_regno)
{
  unsigned
    index = (unsigned) (xpGPR(xp,idx_regno)),
    old_limit = tcr->tlb_limit,
    new_limit = align_to_power_of_2(index+1,12),
    new_bytes = new_limit-old_limit;
  LispObj 
    *old_tlb = tcr->tlb_pointer,
    *new_tlb = realloc(old_tlb, new_limit),
    *work;

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
  xpGPR(xp, limit_regno) = new_limit;
  return true;
}


