changequote([,])
changecom([/*], [*/])


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

/*
  BSD debugging information (line numbers, etc) is a little different
  from ELF/SVr4 debugging information.  There are probably lots more
  differences, but this helps us to distinguish between what LinuxPPC
  (ELF/SVr4) wants and what Darwin(BSD) wants.
*/

define([BSDstabs],[1])
define([ELFstabs],[2])
undefine([EABI])
undefine([POWEROPENABI])


ifdef([DARWIN],[define([SYSstabs],[BSDstabs])
                define([CNamesNeedUnderscores],[])
	        define([LocalLabelPrefix],[L])
	        define([StartTextLabel],[Ltext0])
	        define([EndTextLabel],[Letext])
		define([POWEROPENABI],[])])

ifdef([LINUX],[define([SYSstabs],[ELFstabs])
	       define([HaveWeakSymbols],[])
	       define([LocalLabelPrefix],[.L])
	       define([StartTextLabel],[.Ltext0])
	       define([EndTextLabel],[.Letext])
	       define([EABI],[])])

/*
  Names exported to (or imported from) C may need leading underscores.
  Still.  After all these years.  Why ?
*/

define([C],[ifdef([CNamesNeedUnderscores],[[_]$1],[$1])])

define([_linecounter_],0)

define([_emit_BSD_source_line_stab],[
	.stabd 68,0,$1
])

/*
  We don't really do "weak importing" of symbols from a separate
  subprims library anymore; if we ever do and the OS supports it,
  here's how to say that we want it ...
*/

define([WEAK],[ifdef([HaveWeakSymbols],[
	.weak $1
],[
	.globl $1
])])

define([_emit_ELF_source_line_stab],[
  define([_linecounter_],incr(_linecounter_))
[.LM]_linecounter_:
	.stabn 68,0,$1,[.LM]_linecounter_[-]func_start
])

define([emit_source_line_stab],[
	ifelse(eval(SYSstabs),eval(BSDstabs),
	[_emit_BSD_source_line_stab($1)],
	[_emit_ELF_source_line_stab($1)])])


/*
  Assemble a reference to the high half of a 32-bit constant,
  possibly adjusted for sign-extension of thw low half.
*/

define([HA],[ifdef([DARWIN],[ha16($1)],[$1@ha])])

/* 
  Likewise for the low half, and for the high half without
  concern for sign-extension of the low half.
*/
define([LO],[ifdef([DARWIN],[lo16($1)],[$1@l])])
define([HI],[ifdef([DARWIN],[hi16($1)],[$1@hi])])
/*
  Note that m4 macros that could be expanded in the .text segment
  need to advertise the current line number after they have finished
  expanding.  That shouldn]t be too onerous, if only because there
  should not be too many of them.
*/

define([N_FUN],36)
define([N_SO],100)
/*
    I wish that there was a less-dumb way of doing this.
*/
define([pwd0],esyscmd([/bin/pwd]))
define([__pwd__],substr(pwd0,0,decr(len(pwd0)))[/])
/*
   _beginfile() -- gets line/file in synch, generates N_SO for file,
   starts .text section
*/

define([_beginfile],[
	.stabs "__pwd__",N_SO,0,0,StartTextLabel()
	.stabs "__file__",N_SO,0,0,StartTextLabel()
	.text
StartTextLabel():
# __line__ "__file__"
])

define([_endfile],[
	.stabs "",N_SO,0,0,EndTextLabel()
EndTextLabel():
# __line__
])

define([_startfn],[define([__func_name],$1)
# __line__
	ifelse(eval(SYSstabs),eval(ELFstabs),[
	.type $1,@function
])
$1:
        .stabd 68,0,__line__
	.stabs "$1:F1",36,0,__line__,$1
	.set func_start,$1
])



define([_exportfn],[
	.globl $1
	_startfn($1)
# __line__
])

define([_endfn],[
LocalLabelPrefix[]__func_name[999]:
	.stabs "",36,0,0,LocalLabelPrefix[]__func_name[999]-__func_name
	.line __line__
	ifelse(eval(SYSstabs),eval(ELFstabs),[
        .size __func_name,LocalLabelPrefix[]__func_name[999]-__func_name
])
])


/* _struct(name,start_offset)
   This just generates a bunch of assembler equates; m4
   doesn]t remember much of it ... */
define([_struct], [define([__struct_name],$1)
 define([_struct_org_name], _$1_org) 
 define([_struct_base_name], _$1_base)
	.set _struct_org_name,$2
	.set _struct_base_name,_struct_org_name])

define([_struct_pad],[
	.set _struct_org_name,_struct_org_name + $1
])
 
define([_struct_label],[
	.set __struct_name[.]$1, _struct_org_name
])

/*  _field(name,size) */
define([_field],[_struct_label($1) _struct_pad($2)])

define([_halfword], [_field($1, 2)])
define([_word], [_field($1, 4)])
define([_dword],[_field($1, 8)])
define([_node], [_field($1, node_size)])

define([_ends],[
	.set  __struct_name[.size], _struct_org_name-_struct_base_name
])

/* 
   Lisp fixed-size objects always have a 1-word header
   and are always accessed from a "fulltag_misc"-tagged pointer.
   We also want to define STRUCT_NAME.element-count for each
   such object.
*/

define([_structf],[
	_struct($1,-misc_bias)
        _node(header)
])

define([_endstructf],[
	.set __struct_name.[element_count],((_struct_org_name-node_size)-_struct_base_name)/node_size
	_ends
])


define([__],[emit_source_line_stab(__line__)
# __line__
	$@
	])

define([__local_label_counter__],0)
define([__macro_label_counter__],0)

define([new_local_labels],
  [define([__local_label_counter__],incr(__local_label_counter__))])

define([new_macro_labels],
  [define([__macro_label_counter__],incr(__macro_label_counter__))])

define([_local_label],[LocalLabelPrefix()[]$1])

define([local_label],[_local_label($1[]__local_label_counter__)])

define([macro_label],[_local_label($1[]__macro_label_counter__)])




