# Changelog

## 0.2.0

Rewrite for yabai 7.x and Hammerspoon 1.x (Apple Silicon and Intel).

### Changed
- yabai is the single source of truth: one `yabai -m query --windows <properties>` per refresh (full query on
  yabai < 7.0.3) replaces frame grouping through `hs.window.filter`, which was the main cause of slow startup.
- Refreshes are driven by yabai signals that stackline registers itself (`stackline_*` labels) and re-registers
  after yabai restarts, plus Space and screen watchers. Bursts of events collapse into one refresh.
- One canvas per stack (plus a click target) instead of one full-screen canvas per window; focus changes recolor
  indicators in place and only stacks whose layout changed are rebuilt. App icons are cached per application.
- Indicators use the `floating` window level (configurable via `appearance.windowLevel`), so menus and Spotlight
  draw above them.
- `advanced.maxRefreshRate` now defaults to `0.1` seconds.
- `features.fzyFrameDetect.fuzzFactor` is the maximum distance between the top-left corners of windows in one stack.

### Added
- `stackline:stop()`, `stackline.status()`, `stackline:refresh(force)`; `.` and `:` call styles both work.
- `paths.hs`, `features.yabaiSignals`, `appearance.windowLevel` options.
- Automatic yabai path detection (Homebrew on Apple Silicon/Intel, Homebrew prefixes, Nix); config validation with
  suggestions; hex colors.
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
- Pill indicators of unfocused stacks stay visible (#85).
- Only the `stackline` global is defined; built-in `string`/`table` are no longer extended.

### Removed
- `conf.lua` (defaults moved to `stackline/defaults.lua`), `lib/utils.lua`, `lib/valid.lua`, and the legacy
  `stackline/{query,stackmanager,stack,window,configmanager}.lua` modules.
- `features.hsBugWorkaround`, `features.winTitles` and `features.dynamicLuminosity` are accepted but have no effect.

## 0.1.61 and earlier

See the [upstream changelog](https://github.com/AdamWagner/stackline/wiki/Changelog).
