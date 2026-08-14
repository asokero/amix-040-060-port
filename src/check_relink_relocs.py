#!/usr/bin/env python3
# check_relink_relocs.py -- simulate the AMIX loader rel.c symvaddr/bindsections/
# allocbss logic over a relinked kernel (big-endian ELF32 m68k) to catch
# relocations rel.c would abort on (RELA guru 0xD2454C41) BEFORE booting.
# Flags: symbols in unbound sections, or UND refs (e.g. GLOBAL refs to kernel
# FILE-LOCAL symbols, which ld -r cannot bind).
#
# Usage: python3 check_relink_relocs.py [image]      (default build/unix-040)
#
# Exit status: 0 clean, 1 complaints, 2 could not read the image.
#
# 2026-08-14: BOTH of those were defects until this date.  The path was hard-coded, so the
# four variant scripts that passed their own output as argv (rtg, xsvga, va2000, z3660) had
# the argument silently ignored and were shown the RELOC CENSUS OF A DIFFERENT KERNEL --
# build/unix-040 -- labelled as their own.  And the script only printed its verdict, never
# exiting non-zero, so the callers that did check could not have noticed either.  The image
# actually read is now echoed, because a checker that will not say what it checked is how
# that lasted this long.

import struct,sys
path = sys.argv[1] if len(sys.argv) > 1 else 'build/unix-040'
try:
    f=open(path,'rb').read()
except OSError as e:
    print("CANNOT READ %s: %s" % (path, e)); sys.exit(2)
print("image:", path)
def u16(o): return struct.unpack('>H',f[o:o+2])[0]
def u32(o): return struct.unpack('>I',f[o:o+4])[0]
# ELF header (big-endian)
e_type=u16(16); e_shoff=u32(32); e_shentsize=u16(46); e_shnum=u16(48); e_shstrndx=u16(50)
print("e_type=%d e_shnum=%d"%(e_type,e_shnum))
secs=[]
for i in range(e_shnum):
    b=e_shoff+i*e_shentsize
    secs.append(dict(name=u32(b),type=u32(b+4),flags=u32(b+8),addr=u32(b+12),
                     off=u32(b+16),size=u32(b+20),link=u32(b+24),info=u32(b+28),
                     entsize=u32(b+36),idx=i))
shstr=secs[e_shstrndx]['off']
def sname(s): 
    o=shstr+s['name']; e=f.index(b'\0',o); return f[o:e].decode('latin1')
for s in secs: s['nm']=sname(s)
SHT_PROGBITS,SHT_NOBITS,SHT_SYMTAB,SHT_RELA=1,8,2,4
SHF_WRITE,SHF_EXEC=1,4
# findsections
thdr=dhdr=bhdr=symhdr=None
for s in secs:
    if s['type']==SHT_PROGBITS:
        if s['flags']&SHF_EXEC and s['size']>0: thdr=s
        elif s['flags']&SHF_WRITE and s['size']>0: dhdr=s
    elif s['type']==SHT_NOBITS and (s['flags']&SHF_WRITE) and s['size']>0: bhdr=s
    elif s['type']==SHT_SYMTAB: symhdr=s
# bindsections
BIND=0x07000000
bound={}
thdr['baddr']=BIND
dhdr['baddr']=thdr['baddr']+thdr['size']
if bhdr: bhdr['baddr']=dhdr['baddr']+dhdr['size']
named={'.uvblock':0x40000000,'.kvsysseg':0x40040000,'.kvsegmap':0x40440000,'.kvsegu':0x48440000}
for s in secs:
    if s['nm'] in named: s['baddr']=named[s['nm']]
def boundaddr(s): return s.get('baddr',0)
print("thdr=%s dhdr=%s bhdr=%s symtab=%s"%(thdr['nm'],dhdr['nm'],bhdr['nm'] if bhdr else None,symhdr['nm']))
print("bound sections:", [s['nm'] for s in secs if boundaddr(s)!=0])
# symbols
symoff=symhdr['off']; nsyms=symhdr['size']//16
def sym(i):
    b=symoff+i*16
    return dict(name=u32(b),value=u32(b+4),size=u32(b+8),info=f[b+12],shndx=u16(b+14))
strh=secs[symhdr['link']]
def symname(sm):
    if sm['name']==0: return ''
    o=strh['off']+sm['name']; e=f.index(b'\0',o); return f[o:e].decode('latin1')
# specialsyms: etext/edata/end -> ABS
SHN_ABS=0xfff1; SHN_UNDEF=0
absset=set()
for i in range(nsyms):
    sm=sym(i); nm=symname(sm)
    if nm in('etext','edata','end'): absset.add(i)
# walk RELA sections, simulate symvaddr
complaints=0
for s in secs:
    if s['type']!=SHT_RELA: continue
    n=s['size']//s['entsize']
    for j in range(n):
        b=s['off']+j*s['entsize']
        r_off=u32(b); r_info=u32(b+4); r_add=u32(b+8)
        symidx=r_info>>8; rtype=r_info&0xff
        sm=sym(symidx); shndx=sm['shndx']
        if symidx in absset or shndx==SHN_ABS or shndx==0xfff2: continue
        if 0<shndx<e_shnum:
            if boundaddr(secs[shndx])==0:
                complaints+=1
                if complaints<=12:
                    print("UNBOUND: reloc in %s off=0x%x -> sym[%d] '%s' in section[%d] '%s'"%(
                        s['nm'],r_off,symidx,symname(sm),shndx,secs[shndx]['nm']))
        else:
            complaints+=1
            if complaints<=12:
                print("BADSHNDX: reloc in %s off=0x%x -> sym[%d] '%s' shndx=%d"%(
                    s['nm'],r_off,symidx,symname(sm),shndx))
# The image is named on the VERDICT line, not only at the top: callers show the last line
# only, and a verdict that does not say what it was about is what let four scripts validate
# somebody else's kernel for months.
print("TOTAL complaints: %d   [%s]" % (complaints, path))
sys.exit(1 if complaints else 0)
