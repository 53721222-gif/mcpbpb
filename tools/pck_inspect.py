"""Inspect a Godot 3 PCK: header, file list, encryption flags, extensions."""
import struct, sys, os, collections, json

def parse(path, dump_list=False):
    with open(path, 'rb') as f:
        data = f.read()
    if data[:4] != b'GDPC':
        raise SystemExit('not a pck: %r' % data[:4])
    pack_ver, major, minor, patch = struct.unpack_from('<IIII', data, 4)
    file_count, = struct.unpack_from('<I', data, 84)
    pos = 88
    entries = []
    for i in range(file_count):
        path_len, = struct.unpack_from('<I', data, pos); pos += 4
        raw = data[pos:pos+path_len]; pos += path_len
        p = raw.rstrip(b'\x00').decode('utf-8', 'replace')
        ofs, size = struct.unpack_from('<QQ', data, pos); pos += 16
        md5 = data[pos:pos+16]; pos += 16
        flags, = struct.unpack_from('<I', data, pos); pos += 4
        entries.append((p, ofs, size, flags, md5.hex()))
    return dict(pack_ver=pack_ver, version=f'{major}.{minor}.{patch}',
                count=file_count, dir_end=pos, data_len=len(data)), entries

if __name__ == '__main__':
    path = sys.argv[1]
    hdr, entries = parse(path)
    print(json.dumps(hdr, indent=2))
    enc = [e for e in entries if e[3] & 1]
    print('encrypted files:', len(enc))
    exts = collections.Counter(os.path.splitext(e[0])[1].lower() for e in entries)
    print('extensions:', exts.most_common(25))
    for kw in ['project', 'shop', 'player', 'backpack', 'item', 'game', 'autoload', 'network', 'ui/']:
        hits = [e[0] for e in entries if kw in e[0].lower()]
        print(f'--- {kw}: {len(hits)}')
        for h in hits[:15]:
            print('   ', h)
    if dump_list:
        with open('pck_files.txt', 'w', encoding='utf-8') as f:
            for e in entries:
                f.write(f'{e[0]}\t{e[1]}\t{e[2]}\t{e[3]}\n')
        print('wrote pck_files.txt')
