;;;-*- Mode: Lisp; Package: CCL -*-
;;;
;;;   Copyright (C) 1994-2001 Digitool, Inc
;;;   This file is part of OpenMCL.  
;;;
;;;   OpenMCL is licensed under the terms of the Lisp Lesser GNU Public
;;;   License , known as the LLGPL and distributed with OpenMCL as the
;;;   file "LICENSE".  The LLGPL consists of a preamble and the LGPL,
;;;   which is distributed with OpenMCL as the file "LGPL".  Where these
;;;   conflict, the preamble takes precedence.  
;;;
;;;   OpenMCL is referenced in the preamble as the "LIBRARY."
;;;
;;;   The LLGPL is also available online at
;;;   http://opensource.franz.com/preamble.html

;;; It's easier to keep this is LAP; we want to play around with its
;;; constants.

;;; This just maps a SLOT-ID to a SLOT-DEFINITION or NIL.
;;; The map is a vector of (UNSIGNED-BYTE 8); this should
;;; be used when there are less than 255 slots in the class.
(defppclapfunction %small-map-slot-id-lookup ((slot-id arg_z))
  (lwz temp1 'map nfn)
  (svref arg_x slot-id.index slot-id)
  (getvheader imm0 temp1)
  (header-length temp4 imm0)
  (lwz temp0 'table nfn)
  (cmplw arg_x temp4)
  (srwi imm0 arg_x 2)
  (la imm0 ppc32::misc-data-offset imm0)
  (li imm1 ppc32::misc-data-offset)
  (bge @have-scaled-table-index)
  (lbzx imm1 temp1 imm0)
  (slwi imm1 imm1 2)
  (la imm1 ppc32::misc-data-offset imm1)
  @have-scaled-table-index
  (lwzx arg_z temp0 imm1)
  (blr))

;;; The same idea, only the map is a vector of (UNSIGNED-BYTE 32).
(defppclapfunction %large-map-slot-id-lookup ((slot-id arg_z))
  (lwz temp1 'map nfn)
  (svref arg_x slot-id.index slot-id)
  (getvheader imm0 temp1)
  (header-length temp4 imm0)
  (lwz temp0 'table nfn)
  (cmplw arg_x temp4)
  (la imm0 ppc32::misc-data-offset arg_x)
  (li imm1 ppc32::misc-data-offset)
  (bge @have-scaled-table-index)
  (lwzx imm1 temp1 imm0)
  (la imm1 ppc32::misc-data-offset imm1)
  @have-scaled-table-index
  (lwzx arg_z temp0 imm1)
  (blr))

(defppclapfunction %small-slot-id-value ((instance arg_y) (slot-id arg_z))
  (lwz temp1 'map nfn)
  (svref arg_x slot-id.index slot-id)
  (getvheader imm0 temp1)
  (lwz temp0 'table nfn)
  (header-length temp4 imm0)
  (cmplw arg_x temp4)
  (srwi imm0 arg_x 2)
  (la imm0 ppc32::misc-data-offset imm0)
  (bge @missing)
  (lbzx imm1 temp1 imm0)
  (cmpwi imm1 0)
  (slwi imm1 imm1 2)
  (la imm1 ppc32::misc-data-offset imm1)
  (beq @missing)
  @have-scaled-table-index
  (lwz arg_x 'class nfn)
  (lwz temp1 'cell nfn)
  (lwzx arg_z temp0 imm1)
  (%car nfn temp1)
  (lwz temp0 ppc32::misc-data-offset nfn)
  (set-nargs 3)
  (mtctr temp0)
  (bctr)
  @missing                              ; (%slot-id-ref-missing instance id)
  (lwz fname '%slot-id-ref-missing nfn)
  (set-nargs 2)
  (lwz nfn ppc32::symbol.fcell fname)
  (lwz temp0 ppc32::misc-data-offset nfn)
  (mtctr temp0)
  (bctr))

(defppclapfunction %large-slot-id-value ((instance arg_y) (slot-id arg_z))
  (lwz temp1 'map nfn)
  (svref arg_x slot-id.index slot-id)
  (getvheader imm0 temp1)
  (lwz temp0 'table nfn)
  (header-length temp4 imm0)
  (cmplw arg_x temp4)
  (la imm0 ppc32::misc-data-offset arg_x)
  (bge @missing)
  (lwzx imm1 temp1 imm0)
  (cmpwi imm1 0)
  (la imm1 ppc32::misc-data-offset imm1)
  (beq @missing)
  @have-scaled-table-index
  (lwz arg_x 'class nfn)
  (lwz temp1 'cell nfn)
  (lwzx arg_z temp0 imm1)
  (%car nfn temp1)
  (lwz temp0 ppc32::misc-data-offset nfn)
  (set-nargs 3)
  (mtctr temp0)
  (bctr)
  @missing                              ; (%slot-id-ref-missing instance id)
  (lwz fname '%slot-id-ref-missing nfn)
  (set-nargs 2)
  (lwz nfn ppc32::symbol.fcell fname)
  (lwz temp0 ppc32::misc-data-offset nfn)
  (mtctr temp0)
  (bctr))
  
(defppclapfunction %small-set-slot-id-value ((instance arg_x)
                                             (slot-id arg_y)
                                             (new-value arg_z))
  (lwz temp1 'map nfn)
  (svref temp4 slot-id.index slot-id)
  (getvheader imm0 temp1)
  (lwz temp0 'table nfn)
  (header-length imm5 imm0)
  (cmplw temp4 imm5)
  (srwi imm0 temp4 2)
  (la imm0 ppc32::misc-data-offset imm0)
  (bge @missing)
  (lbzx imm1 temp1 imm0)
  (cmpwi imm1 0)
  (slwi imm1 imm1 2)
  (la imm1 ppc32::misc-data-offset imm1)
  (beq @missing)
  @have-scaled-table-index
  (vpush new-value)
  (mr arg_y instance)
  (lwz arg_x 'class nfn)
  (lwz temp1 'cell nfn)
  (lwzx arg_z temp0 imm1)
  (%car nfn temp1)
  (lwz temp0 ppc32::misc-data-offset nfn)
  (set-nargs 4)
  (mtctr temp0)
  (bctr)
  @missing                              ; (%slot-id-set-missing instance id new-value)
  (lwz fname '%slot-id-set-missing nfn)
  (set-nargs 3)
  (lwz nfn ppc32::symbol.fcell fname)
  (lwz temp0 ppc32::misc-data-offset nfn)
  (mtctr temp0)
  (bctr))

(defppclapfunction %large-set-slot-id-value ((instance arg_x)
                                             (slot-id arg_y)
                                             (new-value arg_z))
  (lwz temp1 'map nfn)
  (svref temp4 slot-id.index slot-id)
  (getvheader imm0 temp1)
  (lwz temp0 'table nfn)
  (header-length imm5 imm0)
  (cmplw temp4 imm5)
  (la imm0 ppc32::misc-data-offset temp4)
  (bge @missing)
  (lwzx imm1 temp1 imm0)
  (cmpwi imm1 0)
  (la imm1 ppc32::misc-data-offset imm1)
  (beq @missing)
  @have-scaled-table-index
  (vpush new-value)
  (mr arg_y instance)
  (lwz arg_x 'class nfn)
  (lwz temp1 'cell nfn)
  (lwzx arg_z temp0 imm1)
  (%car nfn temp1)
  (lwz temp0 ppc32::misc-data-offset nfn)
  (set-nargs 4)
  (mtctr temp0)
  (bctr)
  @missing                              ; (%slot-id-set-missing instance id new-value)
  (lwz fname '%slot-id-set-missing nfn)
  (set-nargs 3)
  (lwz nfn ppc32::symbol.fcell fname)
  (lwz temp0 ppc32::misc-data-offset nfn)
  (mtctr temp0)
  (bctr))
