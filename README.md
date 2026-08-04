# Timelapse Recorder for Aseprite  (v2.5)

Library-based timelapse recorder with a tiled thumbnail picker.

Dialog titles show **v2.5** — if not, you're on an old build (Preferences ›
Extensions → Uninstall → **restart** → install → **restart**).

## GIF vs MP4 — important

- **GIF is always built by Aseprite itself** — no ffmpeg, no command line, no
  console windows. This is the reliable output and it's on by default.
- **MP4 is optional and uses ffmpeg** (a command-line program). On some Windows
  setups the OS blocks launching command-line tools (that `cmd.exe … 0xc0000142`
  error). If MP4 errors for you, **just leave it unticked** — your GIF is
  unaffected and comes out perfectly.

v2.5 fixes the bug where ticking MP4 also routed the **GIF** through ffmpeg,
producing a second, corrupt/unopenable GIF. Now the GIF never touches ffmpeg,
so you get exactly one, always-openable GIF per piece.

## How it works

1. Recording ON by default, records only **saved sprites** (new sprite records
   once saved; renames are reflected in the name).
2. **File › Scripts › Timelapse › Create Timelapse…** → click thumbnail tiles
   (8 recent + "Show all"), set FPS/upscale/hold, **Create** → one GIF per piece.
3. Storage: newest **N pieces** kept (Settings → "Max pieces to keep", default
   40). Delete pieces in the picker, or Clear Recorded Pieces.

## Slower / nicer

Fixed FPS mode, lower the FPS (6–8). Hold final frame ~1.5s.

## Menu

Record Timelapse (on/off) · Create Timelapse… · Open Timelapse Folder ·
Clear Recorded Pieces · Timelapse Settings (v2.5)…

## Notes

- Leaving MP4 off means the extension never launches a command line at all — no
  cmd.exe error possible.
- If you have an old corrupt GIF from a previous version, just delete it; new
  ones are always native.
