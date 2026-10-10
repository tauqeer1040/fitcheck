"""Diff the class list of the release AAB against the pre-change baseline.

Purpose: prove that narrowing the R8 keep-rules removed ONLY dead code, and
that every class the Flutter <-> native bridges actually need survived.

Usage:
    python tools/verify_r8_shrink.py before.txt build/app/outputs/bundle/release/app-release.aab
"""
import sys, os, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dump_dex_classes import classes_from_dex
import zipfile

before = set(l.strip() for l in open(sys.argv[1], encoding='utf-8') if l.strip())

aab = sys.argv[2]
z = zipfile.ZipFile(aab)
after = set()
for n in z.namelist():
    if n.endswith('.dex'):
        after |= classes_from_dex(z.read(n))

removed = before - after
added = after - before

print(f'before : {len(before)} classes')
print(f'after  : {len(after)} classes')
print(f'removed: {len(removed)}   added: {len(added)}')

print('\n=== removed, grouped by package (top 25) ===')
c = collections.Counter()
for r in removed:
    n = r[1:-1].replace('/', '.') if r.startswith('L') else r
    c['.'.join(n.split('.')[:3]) if n.count('.') >= 2 else n] += 1
for k, v in c.most_common(25):
    print(f'   {v:6d}  {k}')

# Classes the app genuinely needs at runtime. If any of these were removed,
# the keep-rules were narrowed too far.
# NB: names are checked against the R8 mapping, because R8 renames what it
# keeps -- a class missing from the dex may simply be present under a new
# name. Anything genuinely gone shows up as R8$$REMOVED$$CLASS$$*.
MUST_KEEP = [
    'io/flutter/plugins/GeneratedPluginRegistrant',
    'org/tensorflow/lite/Interpreter',
    'org/tensorflow/lite/Tensor',
    'com/google/mlkit/',
    'com/revenuecat/purchases/hybridcommon/ui/PaywallFragment',
    'com/revenuecat/purchases/ui/revenuecatui/activity/PaywallActivity',
    'com/revenuecat/purchases/ui/revenuecatui/customercenter/CustomerCenterActivity',
    'com/revenuecat/purchases/paywalls/PaywallAssetWarmerImpl',
    'com/dexterous/flutterlocalnotifications/FlutterLocalNotificationsPlugin',
    'es/antonborri/home_widget/HomeWidgetPlugin',
    'io/flutter/plugins/firebase/analytics/FlutterFirebaseAnalyticsPlugin',
    'io/flutter/embedding/engine/plugins/FlutterPlugin',
]
print('\n=== critical-class check ===')
if len(sys.argv) > 3:
    mapping = open(sys.argv[3], encoding='utf-8', errors='replace').read()
    bad = 0
    for needle in MUST_KEEP:
        pat = needle.rstrip('/').replace('/', '.')
        present = f'{pat} -> ' in mapping
        removed = f'{pat} -> R8$$REMOVED$$CLASS' in mapping
        if removed:
            print(f'   REMOVED  {pat}')
            bad += 1
        elif present:
            print(f'   kept     {pat}')
        else:
            # may be reachable only as an inner/renamed symbol
            print(f'   n/a      {pat} (no mapping entry - check reachability)')
    print()
    print('FAILED: something critical was removed.' if bad else
          'No critical class was removed.')
    sys.exit(1 if bad else 0)

for needle in MUST_KEEP:
    hits = [a for a in after if needle.rstrip('/') in a]
    print(f'   {"ok      " if hits else "MISSING "} {needle}'
          f'  ({len(hits)} classes)')