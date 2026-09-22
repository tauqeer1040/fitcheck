# Agent guide: the fast Flutter dev loop

**Read this before you touch any UI.** The single biggest time sink in this repo is
rebuilding and reinstalling the APK for every small change. A full
`flutter build apk --debug` + `adb install` **is 40–90 seconds**. A hot reload is
**about 1 second**. Use hot reload.

---

## TL;DR

| Approach | Cost |
| --- | --- |
| `flutter build apk` + `adb install` + relaunch | 40–90 s (**avoid**) |
| `flutter run` + `r` (hot reload) | ~1 s |
| `flutter run` + `R` (hot restart) | 3–25 s |
| `flutter analyze <file>` (typecheck only) | 1–3 s |

Order of operations for any UI change:

1. Edit the source.
2. `flutter analyze <changed files>` — catch syntax/type errors for pennies.
3. Append `r` to the reload pipe.
4. Screenshot the device and look at it.

---

## 1. Check for a device

```bash
adb devices -l
flutter devices
```

Prefer a real device over an emulator. Shell state does **not** carry over
between agent tool calls, so re-declare the id at the top of every command that
needs it:

```bash
DEV=$(adb devices | awk 'NR==2{print $1}')   # e.g. adb-ABC123._adb-tls-connect._tcp
```

The same string works for both `adb -s "$DEV"` and `flutter run -d "$DEV"`.

## 2. Start one persistent `flutter run` — and leave it running

`flutter run` is interactive and never exits, and the agent tooling here has **no
background process type**. So background it with `nohup ... &` and `disown`, and
feed its stdin from a file you append to (`tail -f` keeps the pipe open forever):

```bash
pkill -f "flutter run" 2>/dev/null
rm -f /tmp/sp_cmds /tmp/sp_run.log
touch /tmp/sp_cmds

nohup bash -c "tail -f /tmp/sp_cmds | flutter run -d '$DEV' --no-devtools" \
  > /tmp/sp_run.log 2>&1 &
disown
```

First launch still does one Gradle build + install (60–90 s) — that is the only
slow step in the whole workflow. Wait for it:

```bash
sleep 90; grep -vE "TRuntime|FlutterJNI|GC freed" /tmp/sp_run.log | tail -5
```

You are attached when you see something like:

```
I/flutter (12345): [Analytics] app_opened
```

## 3. Drive the runner by appending keystrokes

The pipe is just a file. Every line you append becomes terminal input:

```bash
echo r >> /tmp/sp_cmds   # hot RELOAD  (~1 s)  — re-runs build(), keeps state
echo R >> /tmp/sp_cmds   # hot RESTART (~3–25 s) — new isolate, fresh widgets
echo q >> /tmp/sp_cmds   # detach/quit
```

Confirm it actually landed — the log is the source of truth:

```bash
tail -2 /tmp/sp_run.log
# Performing hot reload...
# Reloaded 3 of 2268 libraries in 1,037ms (compile: 84 ms, reload: 448 ms, reassemble: 211 ms)
```

`Reloaded 0 libraries` means the tool saw **no source change** — usually you
forgot to save, or you are reloading a file that was never edited.

### `r` vs `R` — this matters

- **`r` (hot reload)** re-runs `build()`. It does **not** re-run `initState`,
  field initialisers, or `static` initialisers, and it does **not** reset
  `State`, navigation, or any other live runtime state.
- **`R` (hot restart)** throws away the widget tree and all app state, rebuilding
  from scratch. Use it when you changed initialisation, a constructor, a
  `late final` field, a `static const`, or when the app is stuck (see gotcha B).

Changing layout/animation/paint code? `r` is enough. Changing how something is
*wired up*? Use `R`.

## 4. Verify visually without guessing

Screenshot, downscale, then actually read the image. Screenshots are ~1 MB and the
file reader rejects anything over 768 KB, so **always downscale first**:

```bash
mkdir -p .tmp_shots
adb -s "$DEV" exec-out screencap -p > .tmp_shots/shot.png
ffmpeg -y -loglevel error -i .tmp_shots/shot.png -vf "scale=540:-1" .tmp_shots/shot_s.png
```

Write screenshots into an ignored scratch dir (`.tmp_shots/`) and delete it when
you are done. `ffmpeg` is available; ImageMagick is not.

### Don't trust your eyes for colour/layout — sample pixels

Judging colours from a scaled screenshot is unreliable. Sample the real pixels:

```bash
for p in "40:1000:CORNER" "540:2160:BOTTOM" "540:1100:CENTER"; do
  IFS=: read x y label <<< "$p"
  echo "$label = #$(ffmpeg -loglevel error -i .tmp_shots/shot.png \
    -vf "crop=1:1:$x:$y" -f rawvideo -pix_fmt rgb24 - | xxd -p)"
done
```

Six identical hex values across the screen is far stronger evidence than "looks
flat to me". Note the screenshot is the device's real resolution (1080×2400 on a
Pixel 6a); multiply coordinates from a 540-wide scaled image by 2.

### Motion: take a burst, not one frame

Anything that animates (springs, pops, transitions) needs several frames. Note
each `screencap` takes 1–3 s, so oversample rather than trying to time one shot:

```bash
adb -s "$DEV" shell input tap <x> <y>
sleep 2
for i in 1 2 3; do adb -s "$DEV" exec-out screencap -p > .tmp_shots/s$i.png; done
```

## 5. Driving the UI

There is no deep-linking in this app, so you navigate by tapping coordinates.
Flutter renders to a canvas, so `uiautomator dump` returns **no text** — you must
look at screenshots to pick tap targets. `adb shell input tap X Y` and
`input keyevent KEYCODE_BACK` are your tools. Re-screenshot after each tap.

---

## Gotchas that will cost you an hour

### A. `flutter run` can silently install a STALE APK

`build/app/outputs/flutter-apk/app-debug.apk` is only rewritten by a real build.
Hot reloads are pushed straight to the running isolate and **never touch that
file**.

If the app process **dies** (crash, force-stop, OOM), the runner relaunches from
the on-disk APK — which may be *far* behind your source. Nothing errors. The
symptom is that a change you already verified on screen **reverts**, or a widget
you deleted reappears.

Detection: `grep -iE "exception|error" /tmp/sp_run.log` and check whether an
`E/flutter` stack trace predates the relaunch.

Fix: restart the runner (section 2). That does the one unavoidable slow
build+install and resyncs the APK with the source.

### B. Hot reload preserves broken state

Because `r` keeps `State` and the navigator, an exception that left something
half-torn-down (e.g. `Failed assertion: '!_debugLocked'`) survives the reload —
every later pop keeps throwing. **Editing the code will not fix it.** Use `R`.

### C. Unhandled async/route errors still print

Watch the log for `E/flutter` lines; a thrown `Navigator.pop` result-type
mismatch or a failed route push shows up there and nowhere else. Grep the log
after any flow that navigates:

```bash
grep -iE "exception|error|assert" /tmp/sp_run.log | tail -20
```

### D. Reloading *mid-edit* can poison the isolate

If you reload while a file is in an inconsistent state (e.g. you deleted a
field but a line still reads it), the isolate keeps a **stale kernel** and later
throws compile-time lookups for symbols that no longer exist on disk:

```
The following _CompileTimeError was thrown building LayoutBuilder:
Lookup failed: shrink in @getters in MorphingShapeClip
```

The source may already be correct — `flutter analyze` will be clean — but the
running isolate is not. **`R`** recompiles from scratch and clears it. Symptom to
watch for: an error naming a symbol you just deleted.

### E. A changed file that only appears in a `const` needs a restart

Reloading a new `static const`/`static final` will not re-evaluate it in a live
isolate. Use `R` for those.

---

## When a full rebuild IS the right call

- First run of a session, or after the runner died (gotcha A).
- Native/Kotlin changes, `AndroidManifest.xml`, `build.gradle.kts`, resources.
- Adding a new plugin or asset.
- Changing `pubspec.yaml`.

```bash
flutter build apk --debug && adb -s "$DEV" install -r build/app/outputs/flutter-apk/app-debug.apk
```

Everything else — Dart UI, layout, animation, painters, services, screens —
is hot reload.

---

## Quick reference

```bash
# typecheck just what you touched (seconds, not minutes)
flutter analyze lib/screens/photo_preview_screen.dart

# reload + grab a frame, timed
t0=$(date +%s%3N); echo r >> /tmp/sp_cmds; sleep 5; t1=$(date +%s%3N)
adb -s "$DEV" exec-out screencap -p > .tmp_shots/shot.png
ffmpeg -y -loglevel error -i .tmp_shots/shot.png -vf "scale=540:-1" .tmp_shots/shot_s.png
echo "reload: $((t1-t0))ms"

# clean up scratch screenshots
rm -rf .tmp_shots
```

Budget roughly **~1 s to see a UI change**, versus ~60 s for a rebuild. Batching
edits and doing one reload is fine; batching a rebuild is not.
