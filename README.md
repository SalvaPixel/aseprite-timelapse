# Timelapse Recorder for Aseprite  (v1.8)

Snapshots the canvas as you draw and builds an upscaled **GIF** with Aseprite's
own engine — no ffmpeg, no console windows. (ffmpeg/MP4 is opt-in.)

Every dialog title shows **v1.8** — if yours doesn't, you're on an old build
(uninstall in Preferences › Extensions, restart, install, restart).

## Making the timelapse slower / nicer

Use **Fixed FPS** mode (Settings → Mode). A longer drawing then makes a longer
timelapse — the pacing matches the actual process. To make it calmer, **lower
the FPS** (12 → 6–8). Higher FPS = faster; lower = slower. Set **Hold final
frame** to ~1.5s for a nice ending beat.

(Target length mode forces every timelapse to the same duration — usually not
what you want if your pieces vary in length.)

## Re-exporting (don't like the result?)

The **last finished recording's frames are kept**, so you can redo it without
redrawing:

1. Settings → change **FPS** (speed) or **Upscale** (size).
2. **File › Scripts › Timelapse › Re-export Last Timelapse.**
3. The same timelapse rebuilds at the new pacing/size.

Older sessions are auto-deleted (only the latest is kept), so the cache doesn't
pile up.

## Reducing the freeze on stop

The GIF is encoded in one pass (the cost of no ffmpeg). To shrink the hitch:

- **Drop Upscale from 8 to 4** — a quarter of the pixels, ~4× faster, still
  crisp. Biggest win.
- Raise **Min seconds between snaps** so there are fewer frames.

If you want *zero* freeze, I can add a background-ffmpeg mode (hidden, no window)
— ask and I'll wire it in.

## Menu (File > Scripts > Timelapse)

- **Record Timelapse** — on/off (on by default)
- **Build Timelapse From Cache** — make the GIF now (works while recording)
- **Re-export Last Timelapse** — rebuild the last one at new settings
- **Open Timelapse Folder**
- **Clear Frame Cache**
- **Timelapse Settings (v1.8)…**

## Settings

| Setting | Default | Notes |
|---|---|---|
| Min seconds between snaps | `1` | Higher = fewer frames, less freeze. |
| Upscale factor | `8` | Try `4` for much faster/lighter GIFs. |
| Mode | Fixed FPS | Keep this; length follows your process. |
| Fixed FPS | `12` | Lower = slower timelapse. |
| Hold final frame (sec) | `1.0` | Rest on the finished art. |
| GIF | on | Aseprite engine (no console). |
| Use ffmpeg / MP4 | off | Opt-in; may flash consoles. |
| Auto-delete old frames | on | Keeps the last session for re-export. |
