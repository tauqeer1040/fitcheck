"""Comprehensive scan of EVERY image blob ever committed, regardless of size
or filename. Reports shape + alpha so sticker cutouts can't hide behind a
name filter like the previous scan used."""
import subprocess, struct, collections

out = subprocess.run(['git', 'rev-list', '--all', '--objects'],
                     capture_output=True).stdout.decode('utf-8', 'replace')

blob_paths = collections.defaultdict(set)
for line in out.splitlines():
    p = line.split(' ', 1)
    if len(p) == 2:
        blob_paths[p[0]].add(p[1])

print(f'total objects with paths: {len(blob_paths)}')

shas = list(blob_paths.keys())
res = subprocess.run(['git', 'cat-file', '--batch-check'],
                     input=('\n'.join(shas) + '\n').encode(),
                     capture_output=True).stdout.decode()

blobs = []
for line in res.splitlines():
    p = line.split()
    if len(p) >= 3:
        blobs.append((int(p[2]), p[0]))
print(f'objects: {len(blobs)}  -> reading blobs...\n')


def classify(d):
    if len(d) < 40:
        return None
    if d[:4] == b'RIFF' and d[8:12] == b'WEBP':
        fmt = d[12:16]
        try:
            if fmt == b'VP8 ':
                w, h = struct.unpack('<HH', d[26:30])
            elif fmt == b'VP8L':
                b = struct.unpack('<I', d[21:25])[0]
                w, h = (b & 0x3FFF) + 1, ((b >> 14) & 0x3FFF) + 1
            elif fmt == b'VP8X':
                w = (d[24] | d[25] << 8 | d[26] << 16) + 1
                h = (d[27] | d[28] << 8 | d[29] << 16) + 1
                alpha = bool(d[20] & 0x10)
                return ('webp', w, h, alpha)
            else:
                return None
            alpha = bool(d[20] & 0x10) if fmt == b'VP8X' else False
            return ('webp', w, h, alpha)
        except Exception:
            return None
    if d[:8] == b'\x89PNG\r\n\x1a\n':
        w, h = struct.unpack('>II', d[16:24])
        return ('png', w, h, d[25] in (4, 6))
    if d[:2] == b'\xff\xd8':
        return ('jpeg', 0, 0, False)
    return None


imgs = []
for size, sha in blobs:
    d = subprocess.run(['git', 'cat-file', 'blob', sha],
                       capture_output=True).stdout
    c = classify(d)
    if not c:
        continue
    kind, w, h, alpha = c
    imgs.append((size, sha, kind, w, h, alpha))

print(f'image blobs: {len(imgs)}\n')

# sticker cutouts: portrait-ish, have alpha
portrait_alpha = [r for r in imgs if r[5] and r[3] and r[4] / r[3] > 0.8]
print(f'alpha-bearing portrait blobs (cutout-shaped): {len(portrait_alpha)}')
for size, sha, kind, w, h, _ in sorted(portrait_alpha, key=lambda r: -r[4]):
    paths = sorted(blob_paths[sha])[:2]
    print(f'  {size/1024:8.1f} KB  {kind:4} {w:5d}x{h:5d}  {paths}')

print('\n--- comparison: the SHIPPED sticker set today ---')
import os
for f in sorted(os.listdir('assets/onboarding')):
    d = open(f'assets/onboarding/{f}', 'rb').read()
    c = classify(d)
    if c:
        print(f'  {len(d)/1024:8.1f} KB  {c[0]:4} {c[1]:5d}x{c[2]:5d}  {f}')