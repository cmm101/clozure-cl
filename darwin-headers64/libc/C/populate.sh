#!/bin/sh
CFLAGS=-m64;export CFLAGS
h-to-ffi.sh /usr/include/ar.h
h-to-ffi.sh /usr/include/arpa/ftp.h
h-to-ffi.sh -include /usr/include/sys/types.h -include /usr/include/sys/socket.h -include /usr/include/netinet/in.h /usr/include/arpa/inet.h
h-to-ffi.sh /usr/include/arpa/nameser.h
h-to-ffi.sh /usr/include/arpa/nameser_compat.h
h-to-ffi.sh /usr/include/arpa/telnet.h
h-to-ffi.sh /usr/include/arpa/tftp.h
h-to-ffi.sh /usr/include/bitstring.h
h-to-ffi.sh /usr/include/bzlib.h
h-to-ffi.sh /usr/include/c.h
h-to-ffi.sh /usr/include/com_err.h
h-to-ffi.sh /usr/include/crt_externs.h
h-to-ffi.sh /usr/include/ctype.h
h-to-ffi.sh /usr/include/curl/curl.h
h-to-ffi.sh /usr/include/curses.h
h-to-ffi.sh /usr/include/db.h
h-to-ffi.sh /System/Library/Frameworks/IOKit.framework/Headers/hidsystem/ev_keymap.h
h-to-ffi.sh /System/Library/Frameworks/IOKit.framework/Headers/hidsystem/IOHIDTypes.h
h-to-ffi.sh /System/Library/Frameworks/IOKit.framework/Headers/hidsystem/IOLLEvent.h
h-to-ffi.sh /System/Library/Frameworks/IOKit.framework/Headers/hidsystem/IOHIDShared.h
h-to-ffi.sh -include /usr/include/sys/cdefs.h /System/Library/Frameworks/IOKit.framework/Headers/hidsystem/event_status_driver.h
h-to-ffi.sh /usr/include/device/device_port.h
h-to-ffi.sh /usr/include/device/device_types.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/dirent.h
h-to-ffi.sh /usr/include/disktab.h
h-to-ffi.sh /usr/include/DNSServiceDiscovery/DNSServiceDiscovery.h
h-to-ffi.sh /usr/include/err.h
h-to-ffi.sh /usr/include/errno.h
h-to-ffi.sh /usr/include/eti.h
h-to-ffi.sh /usr/include/fcntl.h
h-to-ffi.sh /usr/include/float.h
h-to-ffi.sh /usr/include/fnmatch.h
h-to-ffi.sh /usr/include/form.h
h-to-ffi.sh /usr/include/fsproperties.h
h-to-ffi.sh /usr/include/fstab.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/fts.h
h-to-ffi.sh /usr/include/glob.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/grp.h
h-to-ffi.sh /usr/include/gssapi/gssapi_generic.h
h-to-ffi.sh -include /usr/include/gssapi/gssapi.h /usr/include/gssapi/gssapi_krb5.h
# can't find typedef of Str31
#h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/hfs/hfs_encodings.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/hfs/hfs_format.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/hfs/hfs_mount.h
h-to-ffi.sh /usr/include/histedit.h
#h-to-ffi.sh /usr/include/httpd/httpd.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/ifaddrs.h
h-to-ffi.sh /usr/include/inttypes.h
h-to-ffi.sh /usr/include/iodbcinst.h
#h-to-ffi.sh /usr/include/isofs/cd9660/cd9660_mount.h
#h-to-ffi.sh /usr/include/isofs/cd9660/cd9660_node.h
#h-to-ffi.sh /usr/include/isofs/cd9660/cd9660_rrip.h
#h-to-ffi.sh /usr/include/isofs/cd9660/iso.h
#h-to-ffi.sh /usr/include/isofs/cd9660/iso_rrip.h
h-to-ffi.sh /usr/include/kerberosIV/des.h
h-to-ffi.sh /usr/include/kerberosIV/krb.h
h-to-ffi.sh /usr/include/krb.h
h-to-ffi.sh /usr/include/krb5.h
h-to-ffi.sh /usr/include/kvm.h
h-to-ffi.sh /usr/include/lber.h
h-to-ffi.sh /usr/include/lber_types.h
h-to-ffi.sh /usr/include/ldap.h
h-to-ffi.sh /usr/include/libc.h
h-to-ffi.sh /usr/include/libgen.h
#h-to-ffi.sh /usr/include/libkern/libkern.h
h-to-ffi.sh /usr/include/libkern/OSReturn.h
h-to-ffi.sh /usr/include/libkern/OSTypes.h
h-to-ffi.sh -include /usr/include/float.h /usr/include/limits.h
h-to-ffi.sh /usr/include/locale.h
h-to-ffi.sh /usr/include/mach/boolean.h
#h-to-ffi.sh /usr/include/mach/boot_info.h
h-to-ffi.sh /usr/include/mach/bootstrap.h
h-to-ffi.sh /usr/include/mach/clock.h
h-to-ffi.sh /usr/include/mach/clock_priv.h
h-to-ffi.sh /usr/include/mach/clock_reply.h
h-to-ffi.sh /usr/include/mach/clock_types.h
h-to-ffi.sh /usr/include/mach/error.h
h-to-ffi.sh /usr/include/mach/exception.h
h-to-ffi.sh /usr/include/mach/exception_types.h
h-to-ffi.sh /usr/include/mach/host_info.h
h-to-ffi.sh /usr/include/mach/host_priv.h
h-to-ffi.sh /usr/include/mach/host_reboot.h
h-to-ffi.sh /usr/include/mach/host_security.h
h-to-ffi.sh /usr/include/mach/kern_return.h
h-to-ffi.sh -include /usr/include/mach/vm_types.h /usr/include/mach/kmod.h
h-to-ffi.sh /usr/include/mach/ledger.h
h-to-ffi.sh /usr/include/mach/lock_set.h
h-to-ffi.sh /usr/include/mach/mach.h
h-to-ffi.sh /usr/include/mach/mach_error.h
h-to-ffi.sh /usr/include/mach/mach_host.h
h-to-ffi.sh /usr/include/mach/mach_init.h
h-to-ffi.sh /usr/include/mach/mach_interface.h
h-to-ffi.sh /usr/include/mach/mach_param.h
h-to-ffi.sh /usr/include/mach/mach_port.h
h-to-ffi.sh -include /usr/include/mach/message.h /usr/include/mach/mach_syscalls.h
h-to-ffi.sh /usr/include/mach/mach_time.h
h-to-ffi.sh /usr/include/mach/mach_traps.h
h-to-ffi.sh /usr/include/mach/mach_types.h
h-to-ffi.sh /usr/include/mach/machine.h
h-to-ffi.sh /usr/include/mach/memory_object_types.h
h-to-ffi.sh /usr/include/mach/message.h
h-to-ffi.sh /usr/include/mach/mig.h
h-to-ffi.sh /usr/include/mach/mig_errors.h
h-to-ffi.sh /usr/include/mach/ndr.h
h-to-ffi.sh /usr/include/mach/notify.h
h-to-ffi.sh /usr/include/mach/policy.h
h-to-ffi.sh /usr/include/mach/port.h
h-to-ffi.sh /usr/include/mach/port_obj.h
h-to-ffi.sh /usr/include/mach/processor.h
h-to-ffi.sh /usr/include/mach/processor_info.h
h-to-ffi.sh /usr/include/mach/processor_set.h
h-to-ffi.sh /usr/include/mach/rpc.h
h-to-ffi.sh /usr/include/mach/semaphore.h
h-to-ffi.sh /usr/include/mach/shared_memory_server.h
h-to-ffi.sh /usr/include/mach/std_types.h
h-to-ffi.sh /usr/include/mach/sync.h
h-to-ffi.sh /usr/include/mach/sync_policy.h
#h-to-ffi.sh /usr/include/mach/syscall_sw.h
h-to-ffi.sh /usr/include/mach/task.h
h-to-ffi.sh /usr/include/mach/task_info.h
h-to-ffi.sh /usr/include/mach/task_ledger.h
h-to-ffi.sh /usr/include/mach/task_policy.h
h-to-ffi.sh /usr/include/mach/task_special_ports.h
h-to-ffi.sh /usr/include/mach/thread_act.h
h-to-ffi.sh /usr/include/mach/thread_info.h
h-to-ffi.sh /usr/include/mach/thread_policy.h
h-to-ffi.sh /usr/include/mach/thread_special_ports.h
h-to-ffi.sh /usr/include/mach/thread_status.h
h-to-ffi.sh /usr/include/mach/thread_switch.h
h-to-ffi.sh /usr/include/mach/time_value.h
h-to-ffi.sh /usr/include/mach/vm_attributes.h
h-to-ffi.sh /usr/include/mach/vm_behavior.h
h-to-ffi.sh /usr/include/mach/vm_inherit.h
h-to-ffi.sh /usr/include/mach/vm_map.h
h-to-ffi.sh /usr/include/mach/machine/vm_param.h
h-to-ffi.sh /usr/include/mach/vm_prot.h
h-to-ffi.sh -include /usr/include/mach/mach_types.h /usr/include/mach/vm_region.h
h-to-ffi.sh /usr/include/mach/vm_statistics.h
h-to-ffi.sh /usr/include/mach/vm_sync.h
h-to-ffi.sh /usr/include/mach/vm_task.h
h-to-ffi.sh /usr/include/mach/vm_types.h
h-to-ffi.sh /usr/include/mach-o/arch.h
h-to-ffi.sh -D__private_extern__=extern /usr/include/mach-o/dyld.h
h-to-ffi.sh -D__private_extern__=extern /usr/include/mach-o/dyld_debug.h
h-to-ffi.sh /usr/include/mach-o/fat.h
h-to-ffi.sh /usr/include/mach-o/getsect.h
h-to-ffi.sh /usr/include/mach-o/ldsyms.h
h-to-ffi.sh /usr/include/mach-o/loader.h
h-to-ffi.sh /usr/include/mach-o/nlist.h
h-to-ffi.sh /usr/include/mach-o/ranlib.h
h-to-ffi.sh /usr/include/mach-o/reloc.h
h-to-ffi.sh /usr/include/mach-o/stab.h
h-to-ffi.sh /usr/include/mach-o/swap.h
h-to-ffi.sh -include /usr/include/mach/machine/vm_types.h /usr/include/mach_debug/hash_info.h
h-to-ffi.sh /usr/include/mach_debug/ipc_info.h
h-to-ffi.sh /usr/include/mach_debug/mach_debug.h
h-to-ffi.sh /usr/include/mach_debug/mach_debug_types.h
h-to-ffi.sh /usr/include/mach_debug/page_info.h
h-to-ffi.sh /usr/include/mach_debug/vm_info.h
h-to-ffi.sh /usr/include/mach_debug/zone_info.h
h-to-ffi.sh /usr/include/malloc/malloc.h
h-to-ffi.sh /usr/include/math.h
h-to-ffi.sh /usr/include/memory.h
h-to-ffi.sh /usr/include/monitor.h
h-to-ffi.sh /usr/include/nameser.h
h-to-ffi.sh /usr/include/ncurses_dll.h
h-to-ffi.sh /usr/include/ndbm.h
h-to-ffi.sh -include /usr/include/sys/types.h -include /usr/include/sys/time.h /usr/include/net/bpf.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/net/ethernet.h
h-to-ffi.sh -include /usr/include/sys/types.h -include /usr/include/sys/socket.h /usr/include/net/if.h
h-to-ffi.sh -include /usr/include/sys/types.h -include /usr/include/sys/socket.h /usr/include/net/if_arp.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/net/if_dl.h
h-to-ffi.sh -include /usr/include/sys/types.h  /usr/include/net/if_llc.h
h-to-ffi.sh /usr/include/net/if_media.h
h-to-ffi.sh /usr/include/net/if_types.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/net/kext_net.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/net/pfkeyv2.h
#h-to-ffi.sh -include /usr/include/sys/types.h  /usr/include/net/radix.h
#h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/net/route.h
#h-to-ffi.sh /usr/include/net/slcompress.h
#h-to-ffi.sh /usr/include/net/slip.h
#h-to-ffi.sh /usr/include/netat/adsp.h
h-to-ffi.sh /usr/include/netat/appletalk.h
#h-to-ffi.sh /usr/include/netat/asp.h
#h-to-ffi.sh /usr/include/netat/at_aarp.h
#h-to-ffi.sh /usr/include/netat/at_ddp_brt.h
#h-to-ffi.sh /usr/include/netat/at_pat.h
#h-to-ffi.sh /usr/include/netat/at_pcb.h
#h-to-ffi.sh /usr/include/netat/at_snmp.h
#h-to-ffi.sh /usr/include/netat/at_var.h
#h-to-ffi.sh /usr/include/netat/atp.h
#h-to-ffi.sh /usr/include/netat/aurp.h
#h-to-ffi.sh /usr/include/netat/ddp.h
#h-to-ffi.sh /usr/include/netat/debug.h
#h-to-ffi.sh /usr/include/netat/ep.h
#h-to-ffi.sh /usr/include/netat/lap.h
#h-to-ffi.sh /usr/include/netat/nbp.h
#h-to-ffi.sh /usr/include/netat/pap.h
#h-to-ffi.sh /usr/include/netat/routing_tables.h
#h-to-ffi.sh /usr/include/netat/rtmp.h
#h-to-ffi.sh /usr/include/netat/sysglue.h
#h-to-ffi.sh /usr/include/netat/zip.h
#h-to-ffi.sh /usr/include/netccitt/dll.h
#h-to-ffi.sh /usr/include/netccitt/hd_var.h
#h-to-ffi.sh /usr/include/netccitt/hdlc.h
#h-to-ffi.sh /usr/include/netccitt/llc_var.h
#h-to-ffi.sh /usr/include/netccitt/pk.h
#h-to-ffi.sh /usr/include/netccitt/pk_var.h
#h-to-ffi.sh /usr/include/netccitt/x25.h
#h-to-ffi.sh /usr/include/netccitt/x25_sockaddr.h
#h-to-ffi.sh /usr/include/netccitt/x25acct.h
#h-to-ffi.sh /usr/include/netccitt/x25err.h
h-to-ffi.sh /usr/include/netdb.h
h-to-ffi.sh -include /usr/include/sys/types.h -include /usr/include/netinet/in.h -include /usr/include/netinet/in_systm.h  -include /usr/include/netinet/ip.h -include /usr/include/netinet/udp.h /usr/include/netinet/bootp.h
h-to-ffi.sh -include /usr/include/sys/types.h -include /usr/include/netinet/in.h  /usr/include/netinet/icmp6.h
h-to-ffi.sh -include /usr/include/sys/types.h -include /usr/include/netinet/in.h -include /usr/include/netinet/in_systm.h  -include /usr/include/netinet/ip.h -include /usr/include/netinet/ip_icmp.h /usr/include/netinet/icmp_var.h
h-to-ffi.sh -include /usr/include/sys/types.h -include /usr/include/sys/socket.h /usr/include/netinet/if_ether.h
h-to-ffi.sh -include /usr/include/sys/types.h -include /usr/include/netinet/in.h -include /usr/include/netinet/in_systm.h  -include /usr/include/netinet/ip.h -include /usr/include/netinet/ip_icmp.h /usr/include/netinet/icmp_var.h
h-to-ffi.sh -include /usr/include/sys/types.h -include /usr/include/sys/socket.h /usr/include/netinet/if_ether.h
h-to-ffi.sh -include /usr/include/sys/types.h -include /usr/include/netinet/in.h /usr/include/netinet/igmp.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/netinet/igmp_var.h
#h-to-ffi.sh /usr/include/netinet/in_pcb.h
#h-to-ffi.sh /usr/include/netinet/in_systm.h
#h-to-ffi.sh /usr/include/netinet/in_var.h
#h-to-ffi.sh /usr/include/netinet/ip.h
#h-to-ffi.sh /usr/include/netinet/ip6.h
#h-to-ffi.sh /usr/include/netinet/ip_fw.h
#h-to-ffi.sh /usr/include/netinet/ip_icmp.h
#h-to-ffi.sh /usr/include/netinet/ip_mroute.h
#h-to-ffi.sh /usr/include/netinet/ip_nat.h
#h-to-ffi.sh /usr/include/netinet/ip_proxy.h
#h-to-ffi.sh /usr/include/netinet/ip_state.h
#h-to-ffi.sh /usr/include/netinet/ip_var.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/netinet/tcp.h
#h-to-ffi.sh /usr/include/netinet/tcp_debug.h
#h-to-ffi.sh /usr/include/netinet/tcp_fsm.h
#h-to-ffi.sh /usr/include/netinet/tcp_seq.h
#h-to-ffi.sh /usr/include/netinet/tcp_timer.h
#h-to-ffi.sh /usr/include/netinet/tcp_var.h
#h-to-ffi.sh /usr/include/netinet/tcpip.h
h-to-ffi.sh -include /usr/include/sys/types.h  /usr/include/netinet/udp.h
#h-to-ffi.sh -include /usr/include/sys/types.h  /usr/include/netinet/udp_var.h
#h-to-ffi.sh /usr/include/netinet6/ah.h
#h-to-ffi.sh /usr/include/netinet6/esp.h
#h-to-ffi.sh /usr/include/netinet6/icmp6.h
#h-to-ffi.sh /usr/include/netinet6/in6.h
#h-to-ffi.sh /usr/include/netinet6/in6_gif.h
#h-to-ffi.sh /usr/include/netinet6/in6_ifattach.h
#h-to-ffi.sh /usr/include/netinet6/in6_pcb.h
#h-to-ffi.sh /usr/include/netinet6/in6_prefix.h
#h-to-ffi.sh /usr/include/netinet6/in6_var.h
#h-to-ffi.sh /usr/include/netinet6/ip6.h
#h-to-ffi.sh /usr/include/netinet6/ip6_fw.h
#h-to-ffi.sh /usr/include/netinet6/ip6_mroute.h
#h-to-ffi.sh /usr/include/netinet6/ip6_var.h
#h-to-ffi.sh /usr/include/netinet6/ip6protosw.h
#h-to-ffi.sh /usr/include/netinet6/ipcomp.h
#h-to-ffi.sh /usr/include/netinet6/ipsec.h
#h-to-ffi.sh /usr/include/netinet6/mip6.h
#h-to-ffi.sh /usr/include/netinet6/mip6_common.h
#h-to-ffi.sh /usr/include/netinet6/mld6_var.h
#h-to-ffi.sh /usr/include/netinet6/natpt_defs.h
#h-to-ffi.sh /usr/include/netinet6/natpt_list.h
#h-to-ffi.sh /usr/include/netinet6/natpt_log.h
#h-to-ffi.sh /usr/include/netinet6/natpt_soctl.h
#h-to-ffi.sh /usr/include/netinet6/natpt_var.h
#h-to-ffi.sh /usr/include/netinet6/nd6.h
#h-to-ffi.sh /usr/include/netinet6/pim6.h
#h-to-ffi.sh /usr/include/netinet6/pim6_var.h
#h-to-ffi.sh /usr/include/netinet6/udp6.h
#h-to-ffi.sh /usr/include/netinet6/udp6_var.h
#h-to-ffi.sh /usr/include/netinfo/_lu_types.h
#h-to-ffi.sh /usr/include/netinfo/lookup.h
#h-to-ffi.sh /usr/include/netinfo/lookup_types.h
#h-to-ffi.sh /usr/include/netinfo/ni.h
#h-to-ffi.sh /usr/include/netinfo/ni_prot.h
#h-to-ffi.sh /usr/include/netinfo/ni_util.h
#h-to-ffi.sh /usr/include/netinfo/nibind_prot.h
#h-to-ffi.sh /usr/include/netiso/argo_debug.h
#h-to-ffi.sh /usr/include/netiso/clnl.h
#h-to-ffi.sh /usr/include/netiso/clnp.h
#h-to-ffi.sh /usr/include/netiso/clnp_stat.h
#h-to-ffi.sh /usr/include/netiso/cltp_var.h
#h-to-ffi.sh /usr/include/netiso/cons.h
#h-to-ffi.sh /usr/include/netiso/cons_pcb.h
#h-to-ffi.sh /usr/include/netiso/eonvar.h
#h-to-ffi.sh /usr/include/netiso/esis.h
#h-to-ffi.sh /usr/include/netiso/iso.h
#h-to-ffi.sh /usr/include/netiso/iso_errno.h
#h-to-ffi.sh /usr/include/netiso/iso_pcb.h
#h-to-ffi.sh /usr/include/netiso/iso_snpac.h
#h-to-ffi.sh /usr/include/netiso/iso_var.h
#h-to-ffi.sh /usr/include/netiso/tp_clnp.h
#h-to-ffi.sh /usr/include/netiso/tp_events.h
#h-to-ffi.sh /usr/include/netiso/tp_ip.h
#h-to-ffi.sh /usr/include/netiso/tp_meas.h
#h-to-ffi.sh /usr/include/netiso/tp_param.h
#h-to-ffi.sh /usr/include/netiso/tp_pcb.h
#h-to-ffi.sh /usr/include/netiso/tp_seq.h
#h-to-ffi.sh /usr/include/netiso/tp_stat.h
#h-to-ffi.sh /usr/include/netiso/tp_states.h
#h-to-ffi.sh /usr/include/netiso/tp_timer.h
#h-to-ffi.sh /usr/include/netiso/tp_tpdu.h
#h-to-ffi.sh /usr/include/netiso/tp_trace.h
#h-to-ffi.sh /usr/include/netiso/tp_user.h
#h-to-ffi.sh /usr/include/netiso/tuba_table.h
#h-to-ffi.sh /usr/include/netkey/keydb.h
#h-to-ffi.sh /usr/include/netkey/keysock.h
#h-to-ffi.sh /usr/include/netns/idp.h
#h-to-ffi.sh /usr/include/netns/ns.h
#h-to-ffi.sh /usr/include/netns/ns_error.h
#h-to-ffi.sh /usr/include/netns/ns_if.h
#h-to-ffi.sh /usr/include/netns/ns_pcb.h
#h-to-ffi.sh /usr/include/netns/spidp.h
#h-to-ffi.sh /usr/include/netns/spp_debug.h
#h-to-ffi.sh /usr/include/netns/spp_var.h
#h-to-ffi.sh /usr/include/nfs/krpc.h
#h-to-ffi.sh /usr/include/nfs/nfs.h
#h-to-ffi.sh /usr/include/nfs/nfsdiskless.h
#h-to-ffi.sh /usr/include/nfs/nfsm_subs.h
#h-to-ffi.sh /usr/include/nfs/nfsmount.h
#h-to-ffi.sh /usr/include/nfs/nfsnode.h
#h-to-ffi.sh /usr/include/nfs/nfsproto.h
#h-to-ffi.sh /usr/include/nfs/nfsrtt.h
#h-to-ffi.sh /usr/include/nfs/nfsrvcache.h
#h-to-ffi.sh /usr/include/nfs/nqnfs.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/nfs/rpcv2.h
h-to-ffi.sh /usr/include/nfs/xdr_subs.h
h-to-ffi.sh /usr/include/nlist.h
h-to-ffi.sh /usr/include/NSSystemDirectories.h
h-to-ffi.sh /usr/include/objc/objc-load.h
h-to-ffi.sh /usr/include/objc/objc-runtime.h
h-to-ffi.sh /usr/include/objc/objc.h
h-to-ffi.sh /usr/include/objc/Object.h
h-to-ffi.sh /usr/include/objc/Protocol.h
h-to-ffi.sh /usr/include/objc/zone.h
h-to-ffi.sh /usr/include/openssl/asn1.h
h-to-ffi.sh /usr/include/openssl/asn1_mac.h
h-to-ffi.sh /usr/include/openssl/bio.h
h-to-ffi.sh /usr/include/openssl/blowfish.h
h-to-ffi.sh /usr/include/openssl/bn.h
h-to-ffi.sh /usr/include/openssl/buffer.h
h-to-ffi.sh /usr/include/openssl/cast.h
h-to-ffi.sh /usr/include/openssl/comp.h
h-to-ffi.sh /usr/include/openssl/conf.h
h-to-ffi.sh /usr/include/openssl/conf_api.h
h-to-ffi.sh /usr/include/openssl/crypto.h
h-to-ffi.sh /usr/include/openssl/des.h
h-to-ffi.sh /usr/include/openssl/dh.h
h-to-ffi.sh /usr/include/openssl/dsa.h
h-to-ffi.sh /usr/include/openssl/dso.h
h-to-ffi.sh /usr/include/openssl/e_os2.h
h-to-ffi.sh /usr/include/openssl/ebcdic.h
h-to-ffi.sh /usr/include/openssl/err.h
h-to-ffi.sh /usr/include/openssl/evp.h
h-to-ffi.sh /usr/include/openssl/hmac.h
h-to-ffi.sh /usr/include/openssl/lhash.h
h-to-ffi.sh /usr/include/openssl/md2.h
h-to-ffi.sh /usr/include/openssl/md4.h
h-to-ffi.sh /usr/include/openssl/md5.h
h-to-ffi.sh /usr/include/openssl/mdc2.h
h-to-ffi.sh /usr/include/openssl/obj_mac.h
h-to-ffi.sh /usr/include/openssl/objects.h
h-to-ffi.sh /usr/include/openssl/opensslconf.h
h-to-ffi.sh /usr/include/openssl/opensslv.h
h-to-ffi.sh /usr/include/openssl/pem.h
h-to-ffi.sh /usr/include/openssl/pem2.h
h-to-ffi.sh /usr/include/openssl/pkcs12.h
h-to-ffi.sh /usr/include/openssl/pkcs7.h
h-to-ffi.sh /usr/include/openssl/rand.h
h-to-ffi.sh /usr/include/openssl/rc2.h
h-to-ffi.sh /usr/include/openssl/rc4.h
h-to-ffi.sh /usr/include/openssl/rc5.h
h-to-ffi.sh /usr/include/openssl/ripemd.h
h-to-ffi.sh /usr/include/openssl/rsa.h
h-to-ffi.sh /usr/include/openssl/safestack.h
h-to-ffi.sh /usr/include/openssl/sha.h
h-to-ffi.sh /usr/include/openssl/ssl.h
h-to-ffi.sh /usr/include/openssl/ssl2.h
h-to-ffi.sh /usr/include/openssl/ssl23.h
h-to-ffi.sh /usr/include/openssl/ssl3.h
h-to-ffi.sh /usr/include/openssl/stack.h
h-to-ffi.sh /usr/include/openssl/symhacks.h
h-to-ffi.sh /usr/include/openssl/tls1.h
h-to-ffi.sh /usr/include/openssl/tmdiff.h
h-to-ffi.sh /usr/include/openssl/txt_db.h
h-to-ffi.sh /usr/include/openssl/x509.h
h-to-ffi.sh /usr/include/openssl/x509_vfy.h
h-to-ffi.sh /usr/include/openssl/x509v3.h
h-to-ffi.sh /usr/include/pam/_pam_aconf.h
h-to-ffi.sh /usr/include/pam/_pam_compat.h
h-to-ffi.sh /usr/include/pam/_pam_macros.h
h-to-ffi.sh /usr/include/pam/_pam_types.h
h-to-ffi.sh /usr/include/pam/pam_appl.h
h-to-ffi.sh /usr/include/pam/pam_client.h
h-to-ffi.sh /usr/include/pam/pam_misc.h
h-to-ffi.sh -include /usr/include/pam/_pam_types.h /usr/include/pam/pam_mod_misc.h
h-to-ffi.sh /usr/include/pam/pam_modules.h
h-to-ffi.sh /usr/include/paths.h
h-to-ffi.sh -include /usr/include/sys/types.h -include /usr/include/sys/time.h -include /usr/include/net/bpf.h -include /usr/include/stdio.h /usr/include/pcap-namedb.h
h-to-ffi.sh /usr/include/pcap.h
#h-to-ffi.sh /usr/include/pexpert/boot.h
#h-to-ffi.sh /usr/include/pexpert/pexpert.h
h-to-ffi.sh /usr/include/pexpert/protos.h
#h-to-ffi.sh /usr/include/profile/profile-internal.h
#h-to-ffi.sh /usr/include/profile/profile-kgmon.c
#h-to-ffi.sh /usr/include/profile/profile-mk.h
h-to-ffi.sh /usr/include/profile.h
#h-to-ffi.sh /usr/include/protocols/dumprestore.h
#h-to-ffi.sh /usr/include/protocols/routed.h
h-to-ffi.sh /usr/include/protocols/rwhod.h
#h-to-ffi.sh /usr/include/protocols/talkd.h
#h-to-ffi.sh /usr/include/protocols/timed.h
h-to-ffi.sh /usr/include/pthread.h
h-to-ffi.sh /usr/include/pthread_impl.h
h-to-ffi.sh /usr/include/pwd.h
h-to-ffi.sh /usr/include/ranlib.h
h-to-ffi.sh -include /usr/include/sys/types.h  /usr/include/regex.h
#h-to-ffi.sh /usr/include/regexp.h
h-to-ffi.sh -include /usr/include/sys/types.h -include /usr/include/sys/socket.h -include /usr/include/netinet/in.h -include /usr/include/nameser.h  /usr/include/resolv.h
#h-to-ffi.sh /usr/include/rmd160.h
#h-to-ffi.sh /usr/include/rpc/auth.h
#h-to-ffi.sh /usr/include/rpc/auth_unix.h
#h-to-ffi.sh /usr/include/rpc/clnt.h
#h-to-ffi.sh /usr/include/rpc/pmap_clnt.h
#h-to-ffi.sh /usr/include/rpc/pmap_prot.h
#h-to-ffi.sh /usr/include/rpc/pmap_rmt.h
#h-to-ffi.sh /usr/include/rpc/rpc.h
#h-to-ffi.sh /usr/include/rpc/rpc_msg.h
#h-to-ffi.sh /usr/include/rpc/svc.h
#h-to-ffi.sh /usr/include/rpc/svc_auth.h
#h-to-ffi.sh /usr/include/rpc/types.h
h-to-ffi.sh -include /usr/include/rpc/types.h /usr/include/rpc/xdr.h
h-to-ffi.sh /usr/include/rpcsvc/bootparam_prot.h
h-to-ffi.sh /usr/include/rpcsvc/klm_prot.h
h-to-ffi.sh /usr/include/rpcsvc/mount.h
h-to-ffi.sh /usr/include/rpcsvc/nfs_prot.h
h-to-ffi.sh /usr/include/rpcsvc/nlm_prot.h
h-to-ffi.sh /usr/include/rpcsvc/rex.h
h-to-ffi.sh /usr/include/rpcsvc/rnusers.h
h-to-ffi.sh /usr/include/rpcsvc/rquota.h
h-to-ffi.sh /usr/include/rpcsvc/rstat.h
h-to-ffi.sh /usr/include/rpcsvc/rusers.h
h-to-ffi.sh /usr/include/rpcsvc/rwall.h
h-to-ffi.sh /usr/include/rpcsvc/sm_inter.h
h-to-ffi.sh /usr/include/rpcsvc/spray.h
h-to-ffi.sh /usr/include/rpcsvc/yp.h
#h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/rpcsvc/yp_prot.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/rpcsvc/ypclnt.h
h-to-ffi.sh /usr/include/rpcsvc/yppasswd.h
h-to-ffi.sh /usr/include/rune.h
h-to-ffi.sh /usr/include/runetype.h
h-to-ffi.sh /usr/include/sched.h
h-to-ffi.sh /usr/include/semaphore.h
h-to-ffi.sh /usr/include/servers/bootstrap.h
h-to-ffi.sh /usr/include/servers/bootstrap_defs.h
h-to-ffi.sh /usr/include/servers/key_defs.h
h-to-ffi.sh /usr/include/servers/ls_defs.h
h-to-ffi.sh /usr/include/servers/netname.h
h-to-ffi.sh /usr/include/servers/netname_defs.h
h-to-ffi.sh /usr/include/servers/nm_defs.h
h-to-ffi.sh /usr/include/setjmp.h
h-to-ffi.sh /usr/include/sgtty.h
h-to-ffi.sh /usr/include/signal.h
h-to-ffi.sh /usr/include/sql.h
h-to-ffi.sh /usr/include/sqlext.h
h-to-ffi.sh /usr/include/sqltypes.h
h-to-ffi.sh /usr/include/stab.h
h-to-ffi.sh /usr/include/standards.h
#h-to-ffi.sh /usr/include/stdarg.h
h-to-ffi.sh /usr/include/stdbool.h
h-to-ffi.sh /usr/include/stddef.h
h-to-ffi.sh /usr/include/stdint.h
h-to-ffi.sh /usr/include/stdio.h
h-to-ffi.sh /usr/include/stdlib.h
h-to-ffi.sh /usr/include/string.h
h-to-ffi.sh /usr/include/strings.h
h-to-ffi.sh /usr/include/struct.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/sys/acct.h
h-to-ffi.sh /usr/include/sys/attr.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/sys/buf.h
#h-to-ffi.sh /usr/include/sys/callout.h
h-to-ffi.sh /usr/include/sys/cdefs.h
#h-to-ffi.sh /usr/include/sys/clist.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/sys/conf.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/sys/dir.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/sys/dirent.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/sys/disk.h
#h-to-ffi.sh -include /usr/include/sys/types.h  /usr/include/sys/disklabel.h
#h-to-ffi.sh /usr/include/sys/disktab.h
h-to-ffi.sh /usr/include/sys/dkstat.h
#h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/sys/dmap.h
h-to-ffi.sh -include /usr/include/sys/types.h  /usr/include/sys/domain.h
h-to-ffi.sh /usr/include/sys/errno.h
h-to-ffi.sh /usr/include/sys/ev.h
#h-to-ffi.sh /usr/include/sys/exec.h
h-to-ffi.sh /usr/include/sys/fcntl.h
h-to-ffi.sh /usr/include/sys/file.h
h-to-ffi.sh -include /usr/include/sys/types.h  /usr/include/sys/filedesc.h
h-to-ffi.sh /usr/include/sys/filio.h
h-to-ffi.sh -include /usr/include/sys/types.h  /usr/include/sys/gmon.h
h-to-ffi.sh /usr/include/sys/ioccom.h
h-to-ffi.sh /usr/include/sys/ioctl.h
h-to-ffi.sh /usr/include/sys/ioctl_compat.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/sys/ipc.h
#h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/sys/kdebug.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/sys/kern_control.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/sys/kern_event.h
h-to-ffi.sh /usr/include/sys/kernel.h
#h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/sys/ktrace.h
#h-to-ffi.sh /usr/include/sys/linker_set.h
h-to-ffi.sh /usr/include/sys/loadable_fs.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/sys/lock.h
h-to-ffi.sh -include /usr/include/sys/types.h -include /usr/include/sys/fcntl.h /usr/include/sys/lockf.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/sys/malloc.h
h-to-ffi.sh -include /usr/include/sys/types.h -include /usr/include/machine/param.h /usr/include/sys/mbuf.h
h-to-ffi.sh -include /usr/include/sys/types.h  /usr/include/sys/md5.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/sys/mman.h
h-to-ffi.sh /usr/include/sys/mount.h
h-to-ffi.sh /usr/include/sys/msgbuf.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/sys/mtio.h
#h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/sys/namei.h
h-to-ffi.sh /usr/include/sys/netport.h
h-to-ffi.sh /usr/include/sys/param.h
h-to-ffi.sh /usr/include/sys/paths.h
h-to-ffi.sh -include /usr/include/sys/types.h -include /usr/include/sys/time.h /usr/include/sys/proc.h
h-to-ffi.sh -include /usr/include/sys/types.h  /usr/include/sys/protosw.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/sys/ptrace.h
h-to-ffi.sh /usr/include/sys/queue.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/sys/quota.h
#h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/sys/random.h
h-to-ffi.sh /usr/include/sys/reboot.h
h-to-ffi.sh -include /usr/include/sys/types.h -include /usr/include/sys/time.h -include /usr/include/sys/resource.h /usr/include/sys/resourcevar.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/sys/select.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/sys/sem.h
h-to-ffi.sh /usr/include/sys/semaphore.h
h-to-ffi.sh /usr/include/sys/shm.h
h-to-ffi.sh -include /usr/include/sys/types.h -include /usr/include/sys/signal.h /usr/include/sys/signalvar.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/sys/socket.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/sys/socketvar.h
h-to-ffi.sh /usr/include/sys/sockio.h
h-to-ffi.sh /usr/include/sys/stat.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/sys/sys_domain.h
h-to-ffi.sh /usr/include/sys/syscall.h
h-to-ffi.sh /usr/include/sys/sysctl.h
h-to-ffi.sh /usr/include/sys/syslimits.h
h-to-ffi.sh /usr/include/sys/syslog.h
#h-to-ffi.sh /usr/include/sys/systm.h
h-to-ffi.sh /usr/include/sys/termios.h
h-to-ffi.sh /usr/include/sys/time.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/sys/timeb.h
h-to-ffi.sh /usr/include/sys/times.h
#h-to-ffi.sh /usr/include/sys/tprintf.h
h-to-ffi.sh /usr/include/sys/trace.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/sys/tty.h
h-to-ffi.sh /usr/include/sys/ttychars.h
h-to-ffi.sh /usr/include/sys/ttycom.h
h-to-ffi.sh /usr/include/sys/ttydefaults.h
h-to-ffi.sh /usr/include/sys/ttydev.h
#h-to-ffi.sh /usr/include/sys/types.h
#h-to-ffi.sh /usr/include/sys/ubc.h
h-to-ffi.sh -include /usr/include/sys/types.h -include /usr/include/sys/signal.h /usr/include/sys/ucontext.h
h-to-ffi.sh /usr/include/sys/ucred.h
#h-to-ffi.sh /usr/include/sys/uio.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/sys/un.h
h-to-ffi.sh /usr/include/sys/unistd.h
#h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/sys/unpcb.h
h-to-ffi.sh /usr/include/sys/user.h
h-to-ffi.sh /usr/include/sys/utfconv.h
h-to-ffi.sh /usr/include/sys/utsname.h
#h-to-ffi.sh /usr/include/sys/ux_exception.h
h-to-ffi.sh /usr/include/sys/vadvise.h
h-to-ffi.sh /usr/include/sys/vcmd.h
h-to-ffi.sh /usr/include/sys/version.h
h-to-ffi.sh -include /usr/include/sys/types.h -include /usr/include/sys/time.h -include /usr/include/sys/vmparam.h /usr/include/sys/vm.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/sys/vmmeter.h
h-to-ffi.sh -include /usr/include/sys/types.h -include /usr/include/sys/time.h /usr/include/sys/vmparam.h
h-to-ffi.sh /usr/include/sys/vnioctl.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/sys/vnode.h
#h-to-ffi.sh -include /usr/include/sys/types.h -include /usr/include/sys/vnode.h /usr/include/sys/vnode_if.h
h-to-ffi.sh /usr/include/sys/wait.h
h-to-ffi.sh /usr/include/sysexits.h
h-to-ffi.sh /usr/include/syslog.h
h-to-ffi.sh /usr/include/tar.h
h-to-ffi.sh /usr/include/TargetConditionals.h
h-to-ffi.sh /usr/include/tcl.h
h-to-ffi.sh /usr/include/tcpd.h
h-to-ffi.sh /usr/include/term.h
h-to-ffi.sh /usr/include/termios.h
h-to-ffi.sh /usr/include/time.h
h-to-ffi.sh /usr/include/ttyent.h
h-to-ffi.sh /usr/include/tzfile.h
#h-to-ffi.sh /usr/include/ufs/ffs/ffs_extern.h
#h-to-ffi.sh /usr/include/ufs/ffs/fs.h
#h-to-ffi.sh /usr/include/ufs/ufs/dinode.h
#h-to-ffi.sh /usr/include/ufs/ufs/dir.h
#h-to-ffi.sh /usr/include/ufs/ufs/inode.h
#h-to-ffi.sh /usr/include/ufs/ufs/lockf.h
#h-to-ffi.sh /usr/include/ufs/ufs/quota.h
#h-to-ffi.sh /usr/include/ufs/ufs/ufs_extern.h
h-to-ffi.sh -include /usr/include/sys/types.h -include /usr/include/sys/mount.h /usr/include/ufs/ufs/ufsmount.h
h-to-ffi.sh /usr/include/ulimit.h
h-to-ffi.sh /usr/include/unctrl.h
h-to-ffi.sh /usr/include/unistd.h
h-to-ffi.sh /usr/include/util.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/utime.h
h-to-ffi.sh -include /usr/include/sys/types.h  /usr/include/utmp.h
#h-to-ffi.sh /usr/include/vfs/vfs_support.h
h-to-ffi.sh -include /usr/include/sys/types.h /usr/include/vis.h
h-to-ffi.sh /usr/include/zconf.h
h-to-ffi.sh /usr/include/zlib.h
