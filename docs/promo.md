# The promo

[promo.mp4](promo.mp4) is 31 seconds, 1920 × 1080 at 30 fps, cut to a 120 BPM beat. It has one idea per shot, a word on screen the whole time (there is no voice-over to follow), and a progress bar along the bottom so you always know how much is left. [promo-preview.gif](promo-preview.gif) is the same video, silent and smaller. `tools/promo.sh` makes both.

| Time | Shot |
| --- | --- |
| 0:00 | Find apps. Do math. Google it. One key: ⌘ Space |
| 0:02 | A MacBook Air: ⌘Space, the panel opens, "saf" finds Safari |
| 0:06 | Apps, initials (`ss`), typos (`chorme`), math (`2^10 * 3`) |
| 0:13 | Google's suggestions as you type, Tab takes one |
| 0:16 | The results page, right in the panel |
| 0:19 | Ask Grok, search X |
| 0:21 | The numbers: the app's size, the time to rank every app, Zig |
| 0:24 | Back out to the laptop |
| 0:28 | Nanolight, ⌘Space, github.com/justrach/nanolight |

## What is real

- **The panel is the app's own code** (`src/view.zig`), drawn by nanoui offscreen and driven by key presses through nanoui's Tester (`src/promo.zig`). No window was shown and nothing was screen-recorded. Rows, rankings, the faint completion, the math, the selection and the panel's springs are what the app does with those keys.
- **The apps listed** are Apple's own and Google Chrome (`apps` in `src/promo.zig`), the same on any Mac, rather than the machine's own list.
- **Google's suggestions** are what `suggestqueries.google.com` returned for "liquid gl" and "liquid glass" on 2 November 2026, decoded by the app's own `suggest.zig`. They show 0.3 s after typing pauses, about when a live answer lands.
- **The results page** is Google's page for "liquid glass apple", loaded in an offscreen WebKit view with a Safari user agent, as the panel's preview does (`tools/promo/serp.swift`), and placed where the panel shows it.
- **The numbers** are measured as the video renders: the size of the packaged `Nanolight.app`, and the slowest keystroke's ranking of every app on the Mac that renders it.

## What is made for the video

- **The laptop** is Apple's MacBook Air (13-inch, midnight) AR model from apple.com, rendered in Blender (`tools/promo/laptop.py`) with the promo's frames on its display. Its desktop wallpaper is the one baked into that model. The model is downloaded when the script runs and isn't stored in this repository.
- **The title cards, captions and keycaps** are drawn by nanoui for the video (`src/promo_cards.zig`).
- **The music and sound effects** (kick, hi-hat, bass, whooshes, key ticks) are synthesised with ffmpeg in `tools/promo.sh`.
