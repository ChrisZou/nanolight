# The promo

[promo.mp4](promo.mp4) is 47 seconds, 1920 × 1080 at 60 fps. [promo-preview.gif](promo-preview.gif) is the same video, silent and smaller. `tools/promo.sh` makes both in a few minutes, once the Windows and Linux recordings are in `zig-out/promo` (below).

| Time | Shot |
| --- | --- |
| 0:00 | A MacBook Air, the camera coming round to face it; ⌘Space opens the panel on its display, and the camera pushes in until the display fills the frame |
| 0:03 | The panel fills the frame: "saf" finds Safari, → takes the rest |
| 0:05 | Math, the answer lifted by a loupe, ↩ copies it |
| 0:08 | "liquid gl": Google's suggestions arrive, the faint completion is lifted, Tab takes it |
| 0:11 | Google's results, right in the panel |
| 0:15 | ⌘, opens Settings in the panel |
| 0:18 | "hacker": a Raycast extension (Hacker News) runs in the panel; ⌘K shows its actions |
| 0:23 | "system": a Raycast script command, run by Nanolight itself, its output in the panel |
| 0:26 | The pivot: the MacBook pulls back, the camera pans across to a Dell XPS 13 showing Windows |
| 0:30 | "Now on Windows": the System Info script command on Windows |
| 0:34 | "And Linux": Hacker News on Linux (Xfce) |
| 0:42 | The panel's rectangle becomes the icon beside the name; "Mac · Windows · Linux" |

## How it's shot

Before this cut, a research pass (grok-4.7, through graff) looked at what makes software launch films feel well made: Apple's Liquid Glass and Spotlight films, Raycast's and Linear's launch and changelog videos, Cursor 2.0's film, Screen Studio's and Rotato's camera, and Emil Kowalski's easing guidance. This cut follows its conclusions:

- **The interface is the shot.** The panel fills most of the frame, and one thing happens per shot. There are no title cards or stat cards.
- **Quiet type.** One small label sits under the panel and names what is shown. Its size is undone by the camera's zoom, so it reads the same at every zoom.
- **Camera on an S-curve.** Zooms ease on `cubic-bezier(0.77, 0, 0.175, 1)`, and things that enter ease on `cubic-bezier(0.23, 1, 0.32, 1)`. The camera never goes closer than keeps the panel and its label in frame, and it follows the panel's height the way an editor's auto-zoom does.
- **A loupe, not a lunge.** One detail (the answer, then the completion and Tab) is magnified in a window over the frame, which itself doesn't move.
- **Sound under the picture.** There's a soft 86 BPM pad and room tone, a tick for each key, a glass tick when the panel opens, and a bell on the name. There's no kick drum and no riser.

`src/promo_camera.zig` is the camera, eases, loupe, vignette and grain. `src/promo_scene.zig` is what it looks at, and `src/promo.zig` is the timeline.

## What is real

- **The panel is the app's own code** (`src/view.zig`), drawn by nanoui offscreen and driven by key presses through nanoui's Tester. No window was shown and nothing was screen-recorded. The rows, the ranking, the faint completion, the math, the selection and the panel's springs are what the app does with those keys.
- **The apps listed** are Apple's own plus Google Chrome (`apps` in `src/promo.zig`), so they're the same on any Mac.
- **Google's suggestions** are what `suggestqueries.google.com` returned for "liquid gl" and "liquid glass" on 2 November 2026, decoded by the app's own `suggest.zig`. They show 0.3 s after typing pauses.
- **The results page** is Google's page for "liquid glass apple", loaded in an offscreen WebKit view with a Safari user agent as the panel's preview does (`tools/promo/serp.swift`), and placed where the panel shows it.
- **Hacker News** is what its extension (raycast/extensions) rendered through Nanolight's host on 3 November 2026, its first nine stories (`src/promo_hn.json`), drawn by the app's own `raycast_view.zig`. The **System Info** output is what that script command printed on the Mac that made the video (`src/promo_sysinfo.txt`).
- **The Windows and Linux shots are screen recordings** of the real app (a release build of this code) on a Windows Server 2025 desktop and a Debian 13 (Xfce) desktop, in Daytona's sandboxes, recorded by their own screen recorder at 1024 × 768 and 30 fps while a script pressed the keys. They are put in `zig-out/promo` as `rec-win.mp4` and `rec-linux.mp4` and aren't stored in this repository. The video shows them cropped to the panel, 1.5× and 1.3× as fast as they were typed. The hotkey there is Ctrl Space, since the window manager holds Alt Space.

## What is made for the video

- **The laptops** are Apple's MacBook Air (13-inch, midnight) AR model from apple.com and Dell's XPS 13 (DX13260) AR model from dell.com, rendered in Blender (`tools/promo/laptop.py`). The MacBook's display shows the promo's frames, the XPS's the Windows recording. The Mac's desktop wallpaper is the one baked into Apple's model. The models are downloaded when the script runs and aren't stored in this repository.
- **The camera moves, the pan between the laptops, loupes, labels and end card** are added for the video. The labels over the recordings are drawn by `tools/promo/caption.swift`.
- **The music and sound effects** are synthesised with ffmpeg in `tools/promo.sh`.
