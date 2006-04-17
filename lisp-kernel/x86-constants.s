//   Copyright (C) 2005 Clozure Associates
//   This file is part of OpenMCL.  

//   OpenMCL is licensed under the terms of the Lisp Lesser GNU Public
//   License , known as the LLGPL and distributed with OpenMCL as the
//   file "LICENSE".  The LLGPL consists of a preamble and the LGPL,
//   which is distributed with OpenMCL as the file "LGPL".  Where these
//   conflict, the preamble takes precedence.  

//   OpenMCL is referenced in the preamble as the "LIBRARY."

//   The LLGPL is also available online at
//   http://opensource.franz.com/preamble.html



        
// Indices in %builtin-functions%
	
_builtin_plus = 0	// +-2 
_builtin_minus = 1	// --2 
_builtin_times = 2	// *-2 
_builtin_div = 3	// /-2 
_builtin_eq = 4		// =-2 
_builtin_ne = 5		// /-2 
_builtin_gt = 6		// >-2 
_builtin_ge = 7		// >=-2 
_builtin_lt = 8		// <-2 
_builtin_le = 9		// <=-2 
_builtin_eql = 10	// eql 
_builtin_length = 11	// length 
_builtin_seqtype = 12	// sequence-type 
_builtin_assq = 13	// assq 
_builtin_memq = 14	// memq 
_builtin_logbitp = 15	// logbitp 
_builtin_logior = 16	// logior-2 
_builtin_logand = 17	// logand-2 
_builtin_ash = 18	// ash 
_builtin_negate = 19	// %negate 
_builtin_logxor = 20	// logxor-2 
_builtin_aref1 = 21	// %aref1 
_builtin_aset1 = 22	// %aset1 
	

ifdef([X8664],[
	include(x86-constants64.s)
],[
	include(x86-constants32.s)
])						

// registers, as used in destrucuring-bind/macro-bind 

define([whole_reg],[temp1])
define([arg_reg],[temp0])
define([keyvect_reg],[arg_x])
define([initopt_bit],[24])
define([keyp_bit],[25]) //  note that keyp can be true even when 0 keys. 
define([aok_bit],[26])
define([restp_bit],[27])
define([seen_aok_bit],[28])        
        
num_lisp_globals = 48		 // MUST UPDATE THIS !!! 
	
	_struct(lisp_globals,lisp_globals_limit-(num_lisp_globals*node_size))
	 _node(initial_tcr)	        // initial thread tcr 
	 _node(image_name)	        // --image-name argument 
	 _node(BADfpscr_save_high)      // high word of FP reg used to save FPSCR 
	 _node(BADfpscr_save)           // saved FPSCR 
	 _node(batch_flag)	        // -b 
	 _node(host_platform)	        // for runtime platform-specific stuff 
	 _node(argv)			// address of argv[0] 
	 _node(errno)		        // ADDRESS of errno 
	 _node(tenured_area) 		// the tenured_area 
	 _node(oldest_ephemeral) 	// dword address of oldest ephemeral object or 0 
	 _node(lisp_exit_hook)		// install foreign exception_handling 
	 _node(lisp_return_hook)	// install lisp exception_handling 
	 _node(double_float_one) 	// high half of 1.0d0 
	 _node(short_float_zero) 	// low half of 1.0d0 
	 _node(doh_head) 		// creole objects header 
	 _node(metering_info) 		// address of lisp_metering global 
	 _node(in_gc) 			// non-zero when GC active 
	 _node(lexpr_return1v) 		// simpler when &lexpr called for single value. 
	 _node(lexpr_return) 		// magic &lexpr return code. 
	 _node(all_areas) 		// doubly-linked list of all memory areas 
	 _node(bad_funcall)	 	// pseudo-funcall target for cmove 
	 _node(BAD_current_ts) 		// current temp-stack area 
	 _node(BAD_current_vs) 		// current value-stack area 
	 _node(statically_linked)	// non-zero if -static 
	 _node(heap_end)                // end of lisp heap 
	 _node(heap_start)              // start of lisp heap 
	 _node(gcable_pointers)         // linked-list of weak macptrs. 
	 _node(gc_num)                  // fixnum: GC call count. 
	 _node(fwdnum)                  // fixnum: GC "forwarder" call count. 
	 _node(altivec_present)         // non-zero when AltiVec available 
	 _node(oldspace_dnode_count) 	// dynamic dnodes older than g0 start 
	 _node(refbits) 		// EGC refbits 
	 _node(gc_inhibit_count)
	 _node(intflag) 		// sigint pending 
	 _node(default_allocation_quantum)	// for per-thread allocation 
	 _node(deleted_static_pairs) 		
	 _node(exception_lock)
	 _node(area_lock)
	 _node(tcr_key) 		// tsd key for per-thread tcr 
	 _node(ret1val_addr) 		// address of "dynamic" subprims magic values return addr 
	 _node(subprims_base) 		// address of dynamic subprims jump table 
	 _node(saveR13)			// probably don]t really need this 
	 _node(saveTOC)                 // where the 68K emulator stores the  emulated regs 
	 _node(tcr_lock)		// this thread]s exception frame chain 
	 _node(kernel_imports) 		// some things we need imported for us 
	 _node(interrupt_signal)	// signal used by PROCESS-INTERRUPT 
	 _node(tcr_count) 		// tcr_id for next tcr 
	 _node(get_tcr) 		// address of get_tcr() 	
	_ends
	
	
		
define([TCR_STATE_FOREIGN],1)
define([TCR_STATE_LISP],0)
define([TCR_STATE_EXCEPTION_WAIT],2)
define([TCR_STATE_EXCEPTION_RETURN],4)

tstack_alloc_limit = 0xffff
	
