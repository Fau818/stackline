# Changelog

## 0.2.0

Rewrite for yabai 7.x and Hammerspoon 1.x (Apple Silicon and Intel).

### Changed
- yabai is the single source of truth: one `yabai -m query --windows <properties>` per refresh replaces frame
  grouping through `hs.window.filter`, which was the main cause of slow startup. Older yabai versions that reject
  the property list get a full query instead (detected from yabai's answer, not from `yabai --version`, since the
  running daemon may be older than the installed binary).
- Refreshes are driven by yabai signals that stackline registers itself (`stackline_*` labels) and re-registers
  after yabai restarts. The signals talk to a dedicated Hammerspoon message port (`hs -m stackline`), so no Lua is
  evaluated over IPC; bursts of events collapse into one refresh. Application, Space and screen watchers add
  triggers that do not depend on yabai.
- One canvas per stack (plus a click target) instead of one full-screen canvas per window. Canvases are reused and
  pooled, focus changes recolor indicators in place, and app icons are cached per application.
- Canvases stay on the Space they were drawn on instead of being redrawn on every Space switch.
- Indicators use the `floating` window level (configurable via `appearance.windowLevel`), so menus and Spotlight
  draw above them.
- `advanced.maxRefreshRate` now defaults to `0.1` seconds.
- `features.fzyFrameDetect.fuzzFactor` is the maximum distance between the top-left corners of windows in one stack.

### Added
- `stackline:stop()`, `stackline.status()`, `stackline:refresh(force)`; `.` and `:` call styles both work.
- `paths.hs`, `features.yabaiSignals`, `appearance.windowLevel` and `advanced.pollInterval` options.
- Automatic yabai path detection (Homebrew on Apple Silicon/Intel, Homebrew prefixes, Nix); config validation with
  suggestions; hex colors.
- Indicators of a stack covered by a zoomed or maximized window are hidden (#11).
- Test suite with a mocked Hammerspoon (`make test`).

### Fixed
- Stack swaps and re-orders are always reflected (the previous swap check compared tables by reference and rebuilt
  everything on every event).
- Partial config overrides no longer replace whole sections (#127).
- Click-to-focus on multi-display layouts (#62, #87, #100, #106).
- `yabai -m display --focus` no longer focuses Hammerspoon's indicator windows (#67).
- Indicators no longer appear above menus (#99).
- No crash when yabai reports windows that frame grouping missed (#72); `inf`/`nan` frames no longer break JSON
  parsing.
- Large yabai output no longer stalls refreshes (it is read from a file, since `hs.task` only drains pipes after a
  process exits).
- Switching to an app yabai does not track (Raycast, Alfred, …) no longer leaves a stack highlighted as focused.
- Snapshots taken half-way through a yabai re-layout no longer make indicators flicker.
- Pill indicators of unfocused stacks stay visible (#85).
- Only the `stackline` global is defined; built-in `string`/`table` are no longer extended.

### Removed
- `conf.lua` (defaults moved to `stackline/defaults.lua`), `lib/utils.lua`, `lib/valid.lua`, and the legacy
  `stackline/{query,stackmanager,stack,window,configmanager}.lua` modules.
- `features.hsBugWorkaround`, `features.winTitles` and `features.dynamicLuminosity` are accepted but have no effect.

## 0.1.61 and earlier

See the [upstream changelog](https://github.com/AdamWagner/stackline/wiki/Changelog).
