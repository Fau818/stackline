<!-- vim: set tw=0 :-->
![stackline-logo](https://user-images.githubusercontent.com/1683979/90966915-1f9b1400-e48d-11ea-8cbb-0ceea6fcfc39.png)
<p>
  <img alt="Version" src="https://img.shields.io/badge/version-0.2.0-blue.svg?cacheSeconds=2592000" />
  <a href="LICENSE" target="_blank">
    <img alt="License: MIT" src="https://img.shields.io/badge/License-MIT-yellow.svg" />
  </a>
</p>

> Visualize yabai window stacks on macOS. Works with yabai & hammerspoon.

`stackline` adds unobtrusive visual indicators to complement [yabai](https://github.com/koekeishiya/yabai)'s window
stacking. A stack lets several windows share the same screen space; stackline shows how many windows a stack holds,
which one is focused, and lets you click an indicator to switch windows.

![stackline-demo](https://user-images.githubusercontent.com/1683979/90967233-08f6bc00-e491-11ea-9b0a-d75f248ce4b1.gif)

<table>
<thead>
 <th>Icon indicators…</th>
 <th>…or minimal indicators</th>
</thead>
<tbody>
  <tr>
    <td><img src="https://user-images.githubusercontent.com/1683979/90966909-1ad66000-e48d-11ea-9f64-7708a9e1d149.png"/></td>
    <td><img src="https://user-images.githubusercontent.com/1683979/90966912-1dd15080-e48d-11ea-9890-3e10ea7ce397.png"/></td>
  </tr>
</tbody>
</table>

## About this version (0.2)

The original project has been unmaintained since 2021. Version 0.2 is a rewrite for **yabai 7.x** and
**Hammerspoon 1.x** on **Apple Silicon and Intel** Macs:

- ⚡️ **Fast start, idle when idle.** No `hs.window.filter` (which scanned every running app through the
  Accessibility API, and again on every Space change). A refresh is one small `yabai` query; nothing runs while
  nothing changes.
- 🎯 **yabai is the source of truth.** Stack membership, order (`stack-index`), focus and frames come straight from
  yabai, so swaps, inserts and re-orders are always reflected. No more frame-guessing crashes.
- 📡 **Event driven.** stackline registers its own yabai signals (labels `stackline_*`) and re-registers them after
  yabai restarts. Nothing to add to your `yabairc`.
- 🖼️ **One small canvas per stack** instead of a full-screen canvas per window. Focus changes only recolor
  indicators; a stack is rebuilt only when its layout changes. App icons are cached.
- 🖥️ **Multi-display click-to-focus** without coordinate conversions, and indicators no longer draw over menus.
  yabai ignores the indicator windows, so `yabai -m display --focus` no longer focuses Hammerspoon.
- 🧩 **Same configuration** keys as before, now deep-merged with the defaults, validated (with "did you mean…?"
  hints), and accepting hex colors such as `'#e6e6e6'` or yabai-style `'0xffe6e6e6'`.

## Requirements

- [yabai](https://github.com/koekeishiya/yabai) **7.0.3 or newer** recommended (tested with 7.1.25); 4.x–6.x work with
  a slightly larger query. The scripting addition is not required.
- [Hammerspoon](https://www.hammerspoon.org) **1.0 or newer** (tested with 1.1.1) with Accessibility permission.

## Installation

1. Clone the repo into your Hammerspoon config directory (usually `~/.hammerspoon`):

   ```sh
   git clone https://github.com/Fau818/stackline.git ~/.hammerspoon/stackline
   ```

   If you moved the config directory (e.g. `defaults write org.hammerspoon.Hammerspoon MJConfigFile
   "~/.config/hammerspoon/init.lua"`), clone or symlink it there instead:

   ```sh
   ln -s /path/to/stackline ~/.config/hammerspoon/stackline
   ```

2. Start it from your Hammerspoon `init.lua`:

   ```lua
   stackline = require 'stackline'
   stackline:init()
   ```

3. Reload Hammerspoon. The yabai binary is found automatically (`/opt/homebrew/bin`, `/usr/local/bin`, Nix
   profiles); set `paths.yabai` if yours lives elsewhere.

Optional: install the `hs` command line tool to control stackline from scripts and key bindings. In the Hammerspoon
console run `hs.ipc.cliInstall()`, or `hs.ipc.cliInstall('/opt/homebrew')` for a Homebrew prefix on Apple Silicon.
stackline's own yabai signals do not need this: they use the copy of `hs` bundled inside Hammerspoon.app.

## Usage

Create a stack, e.g. with a terminal positioned to the left of a browser window:

```sh
yabai -m window --stack next
```

Two app icons appear at the top-left corner of the stack. Click one to focus that window, or move between stacked
windows with `yabai -m window --focus stack.next`. See the
[yabai wiki](https://github.com/koekeishiya/yabai/wiki) for stack key bindings.

Toggle minimalist mode (pills instead of icons):

```sh
hs -c "stackline.config:toggle('appearance.showIcons')"
```

Check what stackline is doing:

```sh
hs -c 'stackline.status()'
```

## Configuration

Pass overrides to `init()`; they are deep-merged with the [defaults](stackline/defaults.lua), so you only list what
you change:

```lua
stackline:init({
    appearance = { showIcons = false, color = '#e6e6e6', offset = { x = 6 } },
    features   = { clickToFocus = true },
})
```

Change settings at runtime (string values from the CLI are converted for you):

```sh
hs -c "stackline.config:set('appearance.size', 40)"
hs -c "stackline.config:toggle('features.clickToFocus')"
hs -c "print(stackline.config:get('appearance.size'))"
```

| Key | Default | Description |
| --- | --- | --- |
| `paths.yabai` | `'auto'` | yabai binary or Homebrew prefix (e.g. `/opt/homebrew/opt/yabai`) |
| `paths.hs` | `'auto'` | `hs` CLI used by yabai signals; defaults to the one inside Hammerspoon.app |
| `appearance.color` | `{ white = 0.90 }` | Indicator color: a table (`{ red = 0.5, blue = 0 }`) or hex string |
| `appearance.alpha` | `1` | Opacity of active indicators |
| `appearance.dimmer` | `2.5` | Higher numbers increase contrast between focused & unfocused state |
| `appearance.iconDimmer` | `1.1` | Higher numbers dim inactive icons *less* than the non-icon indicators |
| `appearance.showIcons` | `true` | App icons, or slim pills when `false` |
| `appearance.size` | `32` | Indicator size (height when icons are off) |
| `appearance.radius` | `3` | Roundness; for icons higher numbers mean *less* roundness |
| `appearance.iconPadding` | `4` | Space between icon and indicator edge |
| `appearance.pillThinness` | `6` | Pill aspect ratio (width = size / pillThinness) |
| `appearance.vertSpacing` | `1.2` | Vertical spacing between indicators |
| `appearance.offset.x` / `.y` | `4` / `2` | Distance from the window edge / top |
| `appearance.shouldFade` | `true` | Fade indicators in and out |
| `appearance.fadeDuration` | `0.2` | Fade duration (seconds) |
| `appearance.windowLevel` | `'floating'` | [`hs.canvas.windowLevels`](https://www.hammerspoon.org/docs/hs.canvas.html#windowLevels) name; `'screenSaver'` restores the old always-on-top behavior |
| `features.clickToFocus` | `true` | Click an indicator to focus its window |
| `features.yabaiSignals` | `true` | Register yabai signals so indicators update on window events |
| `features.fzyFrameDetect.enabled` | `true` | Treat stacked windows whose top-left corners nearly match as one stack |
| `features.fzyFrameDetect.fuzzFactor` | `30` | Max distance (px) between corners of windows in one stack |
| `advanced.maxRefreshRate` | `0.1` | Minimum seconds between refreshes during bursts of events |

`features.hsBugWorkaround`, `features.winTitles` and `features.dynamicLuminosity` are still accepted but have no effect.

Indicators sit just outside the window edge closest to the screen edge. If they overlap window content, give yabai
more padding, e.g. `yabai -m config left_padding 40 right_padding 40`.

## How it works

```
yabai event ──► yabai signal (stackline_*) ──► hs CLI ──► stackline.onSignal()
Space / screen change (Hammerspoon watchers) ─────────────────┘        │
                                                   throttled refresh ◄──┘
                                                          │
          yabai -m query --windows id,pid,app,space,frame,stack-index,has-focus,is-visible
                                                          │
                       group windows into stacks ─► diff with what is drawn ─► update canvases
```

- Bursts of events (e.g. while resizing) are collapsed: at most one Hammerspoon call per refresh.
- `window_focused` carries the window id, so the highlight moves before the follow-up query returns.
- Every 5 seconds stackline checks yabai's socket; when yabai restarts it registers its signals again, and when yabai
  stops the indicators are hidden.
- yabai emits no event for a few actions: `space --layout float`, toggling float without moving the window, or
  swapping two *unfocused* stacked windows. Indicators catch up on the next event; to update them immediately, add
  `hs -c 'stackline.refresh()'` to those key bindings.

## API

| Call | Description |
| --- | --- |
| `stackline:init(config)` | Start with optional config overrides |
| `stackline:stop()` | Remove indicators, watchers and stackline's yabai signals |
| `stackline:refresh(force)` | Re-query yabai now; `force = true` also rebuilds every indicator |
| `stackline.status()` | Human-readable state: yabai version/path, signals, stacks, timings, last error |
| `stackline:setLogLevel(level)` | `'warning'` (default), `'info'`, `'debug'`, … |
| `stackline.config:get/set/toggle(path)` | Read or change configuration at runtime |

`.` and `:` call styles both work. `stackline.manager:update()` is kept as an alias of `refresh()` for old snippets.

## Troubleshooting

- **Nothing shows up:** run `hs -c 'stackline.status()'`. If yabai isn't found, set `paths.yabai`. Then
  `hs -c "stackline:setLogLevel('info')"` and watch the Hammerspoon console while creating a stack.
- **Indicators do not update:** list the signals with
  `yabai -m signal --list | jq '[.[] | select(.label | startswith("stackline_"))] | length'`. If it prints `0`,
  run `hs -c 'stackline:refresh()'` or reload Hammerspoon.
- **Old signal snippets:** lines in your `yabairc` that call `stackline.manager:update(...)` or `stackline:refresh()`
  still work but are no longer needed.

## Migrating from 0.1.x

- `conf.lua` and `lib/` are gone. The defaults now live in [`stackline/defaults.lua`](stackline/defaults.lua); keep
  your changes in the table you pass to `stackline:init()`.
- The architecture switch (`uname -m`) for the yabai path is no longer needed.
- `advanced.maxRefreshRate` now defaults to `0.1` (a refresh is cheap now), and indicators use the `floating`
  window level instead of `screenSaver`.

## Development

```sh
make test   # unit + integration tests against a mocked Hammerspoon (Lua 5.4+)
make check  # syntax check
```

## Thanks to contributors!

All are welcome. Feel free to dive in by opening an issue or submitting a PR.

[@alin23](https://github.com/alin23) initially proposed the [concept for stackline here](https://github.com/koekeishiya/yabai/issues/203#issuecomment-652948362) and encouraged [@AdamWagner](https://github.com/AdamWagner) to share the mostly-broken proof-of-concept publicly. Since then, [@alin23](https://github.com/alin23) dramatically improved upon the initial proof-of-concept with [#13](https://github.com/AdamWagner/stackline/pull/13), has some pretty whiz-bang functionality on deck with [#17](https://github.com/AdamWagner/stackline/pull/17), and has been a great thought partner/reviewer.

[@zweck](https://github.com/zweck), who, [in the same thread](https://github.com/koekeishiya/yabai/issues/203#issuecomment-656780281), got the gears turning about how [@alin23](https://github.com/alin23)'s idea could be implemented and _also_ urged Adam to share his POC.

[@johnallen3d](https://github.com/johnallen3d) for being of one the first folks to install stackline, and for identifying several mistakes & gaps in the setup instructions.

[@pete-may](https://github.com/pete-may) for saving folks from frustration by fixing an out-of-date command in the readme ([#48](https://github.com/AdamWagner/stackline/pull/48))

[@AdamWagner](https://github.com/AdamWagner) wrote the initial proof-of-concept (POC) and maintained stackline through v0.1.61.

### …on the shoulders of giants

Thanks to [@koekeishiya](https://github.com/koekeishiya) without whom the _wonderful_ [yabai](https://github.com/koekeishiya/yabai) would not exist, and projects like this would have no reason to exist.

Similarly, thanks to [@dominiklohmann](https://github.com/dominiklohmann), who has helped _so many people_ make chunkwm/yabai "do the thing" they want and provides great feedback on new and proposed yabai features.

Thanks to [@cmsj](https://github.com/cmsj), [@asmagill](https://github.com/asmagill), and all of the contributors to [hammerspoon](https://github.com/Hammerspoon/hammerspoon) for making macos APIs accessible to the rest of us!

## License & attribution

stackline is licensed under the [MIT License](LICENSE), the same license used by [yabai](https://github.com/koekeishiya/yabai/blob/master/LICENSE.txt) and [hammerspoon](https://github.com/Hammerspoon/hammerspoon/blob/master/LICENSE).

[MIT](LICENSE) © Adam Wagner
