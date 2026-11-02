# Nanolight Raycast host

Node host that installs and runs [Raycast extensions](https://github.com/raycast/extensions) (MIT) for the native Nanolight launcher. Nanolight spawns `dist/host.js` and talks JSON lines on stdin/stdout. `@raycast/api` is a clean-room implementation from the public docs at developers.raycast.com — Raycast's proprietary runtime is not included.

## CLI

```
node raycast/dist/host.js install <name-or-owner/name> <extensions-dir>
node raycast/dist/host.js list <extensions-dir>
node raycast/dist/host.js run <extension-dir> <command-name>
node raycast/dist/host.js remove <name> <extensions-dir>
node raycast/dist/host.js store <extensions-dir>
```

`store` is a command like an extension's: a list of every extension in raycast/extensions (one API request, kept a day), searched as you type, each with Install or Remove. Nanolight shows it as **Install Raycast Extension…**. After an install it says `{"type":"installed"}` so Nanolight lists the new commands.

The host is built minified (`node build.mjs`: 170 KB, 55 KB compressed) and Nanolight carries it in its program, writing it to its cache for the user's Node when an extension first runs.

`install` prints `{ok, name, title, commands}` or `{ok:false, error}`. `list` prints `[{name,title,icon,commands:[{name,title,subtitle,description,mode,icon}]}]`.

The bundled host is a single file (`dist/host.js`) and does not need `node_modules` at run time. React and react-reconciler are inside it. Install needs Node and npm (it fetches `esbuild` into `<extensions-dir>/.cache` on first use).

## Install

Extensions come from `github.com/raycast/extensions`, directory `extensions/<name>`. The installer does not clone the repo and does not use a token:

1. One API request lists the extension's files: `GET /repos/raycast/extensions/git/trees/main:extensions/<name>?recursive=1`. Without a token GitHub allows 60 an hour; `GITHUB_TOKEN`, when set, is sent.
2. Each file comes from `raw.githubusercontent.com`, which that limit doesn't count, six at a time. `package-lock.json`, `metadata/` and `media/` are skipped.
3. Commands are bundled beside the download and put in place only once every one built, so a failed install leaves what was there. An extension that imports `swift:` or `rust:` code (native code only Raycast's app can build) fails with that reason.
4. `npm install --omit=dev --ignore-scripts` for dependencies other than `@raycast/api`.
5. Bundle each `commands[].name` from `src/<name>.{tsx,ts,jsx,js}` with esbuild. `@raycast/api`, `react`, `react/jsx-runtime` and `react/jsx-dev-runtime` stay external so the host's single React instance is used. `@raycast/utils` is bundled from npm with those same imports external.
6. Copy `package.json` and `assets/` into `<extensions-dir>/<name>/`.

## Protocol

JSON, one object per line, UTF-8. Host to app on stdout (logs go to stderr only):

```
{"type":"render","view":VIEW}
{"type":"toast","style":"success"|"failure"|"animated","title":"...","message":"..."}
{"type":"hud","title":"..."}
{"type":"open","target":"https://... or /path or app name"}
{"type":"copy","text":"..."}
{"type":"paste","text":"..."}
{"type":"close"}
{"type":"pop_to_root"}
{"type":"exit"}
{"type":"error","message":"..."}
{"type":"request","id":N,"method":"clipboard.readText"|"confirm","params":{...}}
```

`render` is sent when the visible top view changes, debounced about 16ms.

VIEW is one of:

```
{"kind":"list","title":"navigationTitle","placeholder":"searchBarPlaceholder","loading":bool,
 "sections":[{"title":"","items":[ITEM...]}], "empty":{"title":"","description":""}|null, "selected":"itemId"|null,
 "actions":[ACTION...]}
{"kind":"detail","title":"...","markdown":"...","loading":bool,"metadata":[{"label":"","text":""}],"actions":[ACTION...]}
{"kind":"form","title":"...","loading":bool,"fields":[{"id":"","type":"text"|"textarea"|"password"|"checkbox"|"dropdown"|"date"|"separator"|"description","title":"","value":..,"placeholder":"","options":[{"value":"","title":""}]}],"actions":[ACTION...]}
```

Grid renders as kind `list`. Unknown components degrade to a detail error view rather than crashing the host.

```
ITEM = {"id":"stable id","title":"","subtitle":"","icon":ICON|null,"accessories":["text", ...],"actions":[ACTION...]}
ACTION = {"id":"stable id","title":"","shortcut":"cmd+enter"|null}
ICON = {"text":"🔥"} | {"file":"/absolute/path.png"} | {"url":"https://..."} | {"builtin":"Icon name"}
```

`tintColor` is ignored. Extension asset names resolve to absolute file paths under `assets/`.

App to host on stdin:

```
{"type":"search","text":"..."}
{"type":"select","id":"itemId"}
{"type":"action","id":"actionId"}
{"type":"field","id":"fieldId","value":..}
{"type":"pop"}
{"type":"reply","id":N,"result":..}
```

Search: if the List has no `onSearchTextChange` and `filtering` is not false, the host filters items (case-insensitive substring, then fuzzy) on title, subtitle, keywords and accessories. Otherwise it calls `onSearchTextChange`.

Actions: `OpenInBrowser` and `Open` send `open`; `CopyToClipboard` sends `copy`; `Paste` sends `paste`; `Push` pushes and re-renders; `SubmitForm` calls the form `onSubmit` with current values; `ShowInFinder` sends `open`; `Trash` is a no-op; a plain `Action` runs `onAction`. The first action is primary (Enter); the second is Cmd+Enter. Escape (`pop`) pops navigation, or sends `pop_to_root` at the root.

Preferences: defaults from extension and command `preferences` in `package.json`, overridden by `<dir>/preferences.json`.

## Supported

- List (Section, Item, EmptyView, Dropdown as defaultValue/onChange only — the dropdown UI is not drawn)
- Detail (markdown; Metadata labels/links as `{label,text}`)
- Grid rendered as list
- Form: TextField, TextArea, PasswordField, Checkbox, Dropdown, DatePicker, Separator, Description
- ActionPanel, Section, Submenu (submenu items flattened), Action and OpenInBrowser, CopyToClipboard, Paste, Push, Open, ShowInFinder, SubmitForm, Trash (no-op)
- useNavigation, showToast / Toast, showHUD
- Clipboard.copy / paste / readText (via request) / clear
- open, closeMainWindow, popToRoot
- LocalStorage (JSON file in the extension dir) and Cache (sync, file under `support/`)
- environment (`extensionName`, `commandName`, `assetsPath`, `supportPath`, `isDevelopment: false`, `raycastVersion: "1.80.0"`, `appearance`)
- getPreferenceValues
- openExtensionPreferences / openCommandPreferences / launchCommand: toast "not supported"
- confirmAlert via request `confirm`
- Icon (Proxy of `{builtin:name}`), Color, Image, Keyboard
- getApplications / getFrontmostApplication: minimal empty results
- updateCommandMetadata: no-op
- `@raycast/utils` when the extension depends on it (bundled from npm; `useFetch`, `usePromise`, `useCachedState`, `getFavicon`, …)

## Not supported

- AI and OAuth throw `not supported` (they do not crash the host if the extension catches the error; calling them uncaught surfaces as an error view)
- MenuBarExtra throws
- Any other missing API member throws a clear "is not supported" error when called
- Real macOS window, Finder selection, application launching beyond an `open` message, and Raycast's private store
- List.Dropdown is not drawn (initial `defaultValue` / `onChange` still run)
- Action panels passed as the `actions` prop are collected on a side render; deeply unusual render props may not appear

## Real extensions

Installed from `raycast/extensions` and run with `node dist/host.js run` (no API keys):

- `hacker-news` command `frontpage`: list, loading false, 30 stories. First titles: "Vibe-Coding a Game in 2026: What AI Builds, What Breaks", "Show HN: Talk to your computer without talking out loud", "Launch HN: Momentic (YC W24) – Agents that catch bugs by using your app", "Bitmovin (YC S15) Is Hiring Technical Graduates in Denver (Engineering/CS Focus)", "My Favourite Laptop", "Anthropic's internal AI use, at retail prices, now exceeds its employee pay", "Show HN: Warsaw in voxels – an interactive 3D map of the city centre", "Show HN: VHS Camera – Run your camera or videos through a simulated VHS signal". Accessories are the point and comment counts. `List.Dropdown` is not drawn; its `defaultValue` (`frontpage`) is applied via `onChange`.
- `dad-jokes` command `index`: detail, loading false, markdown `# "I'm sorry." "Hi sorry, I'm dad"`, actions "New Joke" and "Copy Joke".

`npm test` (Node, macOS): 2 passed — fixture list/search/push/copy/open, and the no-view HUD command.
