"""Extract files from the Godot 3 PCK by path prefix / extension."""
import struct, sys, os, re

def parse(path):
    d = open(path, 'rb').read()
    assert d[:4] == b'GDPC'
    n = struct.unpack_from('<I', d, 84)[0]
    pos = 88
    out = {}
    for _ in range(n):
        sl = struct.unpack_from('<I', d, pos)[0]; pos += 4
        p = d[pos:pos+sl].rstrip(b'\0').decode('utf-8', 'replace'); pos += sl
        ofs, size = struct.unpack_from('<QQ', d, pos); pos += 16
        pos += 16
        out[p] = (ofs, size)
    return d, out

def safe(p):
    return p.replace('res://', '').replace(':', '_').replace('*', '_').replace('?', '_')

if __name__ == '__main__':
    pck = sys.argv[1]
    outdir = sys.argv[2]
    pat = sys.argv[3] if len(sys.argv) > 3 else None
    d, files = parse(pck)
    os.makedirs(outdir, exist_ok=True)
    rx = re.compile(pat) if pat else None
    n = 0
    for p, (ofs, size) in files.items():
        if rx and not rx.search(p):
            continue
        dst = os.path.join(outdir, safe(p))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, 'wb') as f:
            f.write(d[ofs:ofs+size])
        n += 1
    print('extracted', n, 'to', outdir)
