"""Dump every class descriptor from an AAB's dex files so two builds can be
diffed: proves exactly which classes R8 removed, instead of guessing."""
import sys, zipfile, struct, io, collections


def uleb(b, o):
    r = s = 0
    while True:
        x = b[o]
        o += 1
        r |= (x & 0x7F) << s
        if not (x & 0x80):
            return r, o
        s += 7


def classes_from_dex(d):
    hdr = struct.unpack_from('<20I', d, 0x20)
    s_size, s_off = hdr[6], hdr[7]
    t_size, t_off = hdr[8], hdr[9]
    c_size, c_off = hdr[16], hdr[17]
    strs = []
    for i in range(s_size):
        off = struct.unpack_from('<I', d, s_off + 4 * i)[0]
        _, o = uleb(d, off)
        end = d.index(b'\x00', o)
        strs.append(d[o:end].decode('utf-8', 'replace'))
    types = [strs[struct.unpack_from('<I', d, t_off + 4 * i)[0]]
             for i in range(t_size)]
    out = set()
    for i in range(c_size):
        ci = struct.unpack_from('<I', d, c_off + 32 * i)[0]
        out.add(types[ci])
    return out


def main(aab, out):
    z = zipfile.ZipFile(aab)
    names = [n for n in z.namelist() if n.endswith('.dex')]
    allc = set()
    per = {}
    for n in sorted(names):
        cs = classes_from_dex(z.read(n))
        per[n] = len(cs)
        allc |= cs
    with open(out, 'w', encoding='utf-8') as f:
        for c in sorted(allc):
            f.write(c + '\n')
    print(f'{aab}')
    for k, v in per.items():
        print(f'   {k}: {v} classes')
    print(f'   TOTAL unique: {len(allc)} -> {out}')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])