-- Default stackline configuration. Override any subset with `stackline:init({ ... })`,
-- or at runtime with `stackline.config:set('appearance.size', 40)`.
return {
    paths = {
        yabai = 'auto',  -- yabai binary or Homebrew prefix. 'auto' tries /opt/homebrew, /usr/local, Nix profiles, then $PATH
        hs    = 'auto',  -- `hs` CLI used by yabai signals. 'auto' uses the copy bundled inside Hammerspoon.app
    },

    appearance = {
        color        = { white = 0.90 }, -- Indicator background color, e.g., { red = 0.5, blue = 0 } or '#e6e6e6'
        alpha        = 1,                -- Opacity of active indicators
        dimmer       = 2.5,              -- Higher numbers increase contrast b/n focused & unfocused state
        iconDimmer   = 1.1,              -- Higher numbers dim inactive icons *less* than the non-icon indicators
        showIcons    = true,             -- Window indicator style ('lozenge'-shaped when false)
        size         = 32,               -- Size of window indicators (height when icons off)
        radius       = 3,                -- Indicator roundness. Higher numbers → *less* roundness… I'm sorry
        iconPadding  = 4,                -- Space between icon & indicator edge. Higher numbers → smaller, more inset icons
        pillThinness = 6,                -- Aspect ratio of pill-style icons (width = size / pillThinness)
        vertSpacing  = 1.2,              -- Amount of vertical space between indicators

        offset = {                       -- Offset controls position of stack indicators relative to the window
            y = 2,                       -- Distance from top of the window to render indicators
            x = 4,                       -- Distance away from the edge of the window to render indicators
        },

        shouldFade   = true,             -- Enable/disable fade animations
        fadeDuration = 0.2,              -- Duration of fade animations (seconds)
        windowLevel  = 'floating',       -- hs.canvas.windowLevels name; 'floating' sits above windows but below menus
    },

    features = {
        clickToFocus = true,             -- Click an indicator to focus its window
        yabaiSignals = true,             -- Register yabai signals so indicators update on window events

        fzyFrameDetect = {
            enabled    = true,           -- Treat stacked windows whose top-left corners nearly match as one stack
            fuzzFactor = 30,             -- Max distance (px) between the top-left corners of windows in one stack
        },

        hsBugWorkaround   = true,              -- Deprecated, no effect: the Hammerspoon bug it worked around no longer applies
        winTitles         = 'not_implemented', -- Valid options: false, true, 'when_switching', 'not_implemented'
        dynamicLuminosity = 'not_implemented', -- Valid options: false, true, 'not_implemented'
    },

    advanced = {
        maxRefreshRate = 0.1,            -- Minimum seconds between refreshes. Higher = slower response + less work during bursts
    },
}
