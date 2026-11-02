# The promo

[promo.mp4](promo.mp4) is 30 seconds, 1920 × 1080 at 60 fps. [promo-preview.gif](promo-preview.gif) is the same video, silent and smaller. `tools/promo.sh` makes both in a few minutes.

| Time | Shot |
| --- | --- |
| 0:00 | A MacBook Air, the camera coming round to face it; ⌘Space opens the panel on its display, and the camera pushes in until the display fills the frame |
| 0:03 | The panel fills the frame: "saf" finds Safari, → takes the rest |
| 0:05 | Initials (`ss`), then a typo (`chorme`) |
| 0:09 | Math, the answer lifted by a loupe, ↩ copies it |
| 0:12 | "liquid gl": Google's suggestions arrive, the faint completion is lifted, Tab takes it |
| 0:16 | Google's results, right in the panel |
| 0:19 | Ask Grok, search X |
| 0:22 | Back to rest |
| 0:24 | The panel's rectangle becomes the icon beside the name; "Opens with ⌘ Space" |

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

## What is made for the video

- **The laptop** is Apple's MacBook Air (13-inch, midnight) AR model from apple.com, rendered in Blender (`tools/promo/laptop.py`) with the promo's frames on its display. The desktop wallpaper is the one baked into that model. The model is downloaded when the script runs and isn't stored in this repository.
- **The camera moves, loupes, labels and end card** are added for the video.
- **The music and sound effects** are synthesised with ffmpeg in `tools/promo.sh`.
