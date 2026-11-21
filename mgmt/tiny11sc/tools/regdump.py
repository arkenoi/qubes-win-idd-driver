# regdump.py <export.reg> - flatten a hivexregedit --export into "key :: name = value" lines, decoding
# hex(1)/hex(2)/hex(7) strings, so a whole hive can be grepped (how every Edge registration was found).
import sys,re
# decode hivexregedit export: print "key | name = value" with hex(1)/hex(2) decoded
key=None
for line in open(sys.argv[1],encoding='utf-8',errors='replace'):
    line=line.rstrip('\n')
    if line.startswith('['): key=line[1:-1]; continue
    m=re.match(r'^("(?:[^"\\]|\\.)*"|@)=(.*)$',line)
    if not m: continue
    name,val=m.groups()
    h=re.match(r'hex\((1|2|7)\):(.*)',val)
    if h:
        try:
            b=bytes(int(x,16) for x in h.group(2).split(',') if x)
            val=b.decode('utf-16le','replace').replace('\x00',' | ').strip(' |')
        except Exception: pass
    print(f"{key} :: {name} = {val}")
