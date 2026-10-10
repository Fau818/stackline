local t = require 'test.helper'
local describe, it, eq = t.describe, t.it, t.eq

local SCREENS = { { id = 1, frame = { x = 0, y = 0, w = 1440, h = 900 } } }

-- Returns a yabai window record.
local function win(id, pid, index, frame, extra)
    local w = {
        id = id, pid = pid, app = 'App' .. pid, space = 1,
        frame = { x = frame[1], y = frame[2], w = frame[3], h = frame[4] },
        ['stack-index'] = index, ['has-focus'] = false, ['is-visible'] = true,
    }
    for k, v in pairs(extra or {}) do w[k] = v end
    return w
end

-- Installs apps for pids 501..503 and returns the mock, the config, a stacks builder and render.
local function setup(configOverrides)
    local ctl = t.fresh()
    for pid = 501, 503 do
        ctl.apps[pid] = { name = 'App' .. pid, bundleID = 'com.example.app' .. pid, path = '/Applications/App' .. pid .. '.app' }
    end
    local Config = require 'stackline.config'
    local config = Config.new(require 'stackline.defaults')
    config:load(configOverrides)
    local model = require 'stackline.model'
    local function stacks(windows)
        return (model.build(windows, { tolerance = 30, screens = SCREENS }))
    end
    return ctl, config:all(), stacks, require 'stackline.render'
end

local LEFT = { 8, 40, 700, 852 }
local RIGHT = { 716, 40, 716, 852 }

-- Returns one visible 3-window stack on the left with window 102 focused.
local function threeStack()
    return {
        win(101, 501, 1, LEFT), win(102, 502, 2, LEFT, { ['has-focus'] = true }), win(103, 503, 3, LEFT),
    }
end

-- Returns two visible 2-window stacks, left (101, 102) and right (103, 104).
local function twoStacks()
    return { win(101, 501, 1, LEFT), win(102, 502, 2, LEFT), win(103, 503, 1, RIGHT), win(104, 503, 2, RIGHT) }
end

-- Returns `n` 2-window stacks, one per Space (all reported visible).
local function stacksOnSpaces(n)
    local windows = {}
    for space = 1, n do
        windows[#windows + 1] = win(space * 10 + 1, 501, 1, LEFT, { space = space })
        windows[#windows + 1] = win(space * 10 + 2, 502, 2, LEFT, { space = space })
    end
    return windows
end

local noop = function() end

describe('render.apply', function()
    it('draws one visual canvas and one click target per visible stack', function()
        local ctl, cfg, stacks, render = setup()
        local clicks = {}
        render.apply(stacks(threeStack()), cfg, function(id) clicks[#clicks + 1] = id end)

        local live = ctl.liveCanvases()
        eq(#live, 2)
        local visual, hit = live[1], live[2]
        eq(visual.levelValue, 3, 'floating level, below menus (#99)')
        eq(visual.behaviorValue, 8, 'transient')
        eq(visual.subrole, 'AXUnknown', 'invisible to yabai (#67)')
        eq(visual.clickActivatingValue, false)
        eq(visual.showing, true)
        eq(visual.showCount, 1)
        eq(visual.lastShowFade, 0.2)
        eq(#visual.elements, 6, 'a rectangle and an icon per window')
        eq(visual.elements[1].type, 'rectangle')
        eq(visual.elements[2].image.source, 'file:/Applications/App501.app')
        eq(visual.mouseCallbackFn, nil, 'the padded canvas stays click-through')

        -- Indicator rectangles are relative to the canvas, which is padded for shadows.
        local origin = visual.frameRect
        eq(visual.elements[1].frame.x + origin.x, 0)
        eq(visual.elements[1].frame.y + origin.y, 42)

        eq(#hit.elements, 3)
        eq(hit.elements[2].trackMouseDown, true)
        eq(hit.elements[2].action, 'fill', 'skip elements get no hit area')
        eq(hit.elements[2].id, '102')
        eq(hit.subrole, 'AXUnknown')
        eq(hit.clickActivatingValue, false)
        eq(hit.showing, true)
        eq(hit.frameRect, { x = 0, y = 42, w = 32, h = 32 * 1.2 * 2 + 32 })
        ctl.click(hit, '103')
        eq(clicks, { 103 })
    end)

    it('routes clicks to the onClick of the latest apply()', function()
        local ctl, cfg, stacks, render = setup()
        local first, second = {}, {}
        render.apply(stacks(threeStack()), cfg, function(id) first[#first + 1] = id end)
        render.apply(stacks(threeStack()), cfg, function(id) second[#second + 1] = id end)
        ctl.click(ctl.liveCanvases()[2], '101')
        eq(first, {})
        eq(second, { 101 })
    end)

    it('colors the focused, inactive and last-active indicators', function()
        local ctl, cfg, stacks, render = setup()
        render.apply(stacks(threeStack()), cfg, noop)
        local visual = ctl.liveCanvases()[1]
        eq(visual.elements[3].fillColor.alpha, 1, 'focused window 102')
        t.near(visual.elements[1].fillColor.alpha, 1 / 2.5)

        local unfocused = threeStack()
        unfocused[2]['has-focus'] = false
        table.insert(unfocused, 1, table.remove(unfocused, 3)) -- 103 is now front-most
        render.apply(stacks(unfocused), cfg, noop)
        t.near(visual.elements[5].fillColor.alpha, 1 / (2.5 / 1.2), 'last-active window 103')
        eq(visual.elements[3].fillColor.alpha, 0, 'idle icons drop their background')
    end)

    it('updates focus in place instead of redrawing', function()
        local ctl, cfg, stacks, render = setup()
        render.apply(stacks(threeStack()), cfg, noop)
        local windows = threeStack()
        windows[2]['has-focus'] = false
        windows[3]['has-focus'] = true
        render.apply(stacks(windows), cfg, noop)

        eq(#ctl.canvases, 2, 'no canvas was created')
        local visual = ctl.canvases[1]
        t.truthy(visual.attributeWrites > 0)
        eq(visual.replaceCount, 1, 'elements were not replaced')
        eq(visual.elements[5].fillColor.alpha, 1, 'window 103 is now highlighted')
    end)

    it('does not touch canvases when nothing changed', function()
        local ctl, cfg, stacks, render = setup()
        for _ = 1, 3 do render.apply(stacks(threeStack()), cfg, noop) end
        eq(#ctl.canvases, 2)
        local visual, hit = ctl.canvases[1], ctl.canvases[2]
        eq(visual.attributeWrites, 0)
        eq(visual.replaceCount, 1)
        eq(visual.frameWrites, 0)
        eq(visual.showCount, 1, 'never shown twice')
        eq(hit.showCount, 1)
        eq(visual.hideCount, 0)
    end)

    it('redraws a re-ordered stack in place (swap), leaving other stacks alone', function()
        local ctl, cfg, stacks, render = setup()
        local windows = twoStacks()
        render.apply(stacks(windows), cfg, noop)
        eq(#ctl.liveCanvases(), 4)
        local leftVisual, rightVisual = ctl.canvases[1], ctl.canvases[3]

        -- `yabai -m window --swap stack.next`: 101 and 102 trade places.
        windows[1]['stack-index'], windows[2]['stack-index'] = 2, 1
        render.apply(stacks(windows), cfg, noop)

        eq(#ctl.canvases, 4, 'no canvas was created')
        eq(leftVisual.deleted, false)
        eq(leftVisual.replaceCount, 2)
        eq(leftVisual.elements[2].image.source, 'file:/Applications/App502.app', 'window 102 now comes first')
        eq(ctl.canvases[2].elements[1].id, '102', 'click targets follow the new order')
        eq(leftVisual.showCount, 1)
        eq(leftVisual.hideCount, 0)
        eq(rightVisual.replaceCount, 1, 'the other stack is untouched')
    end)

    it('moves and resizes indicators in place when the stack frame changes', function()
        local ctl, cfg, stacks, render = setup()
        render.apply(stacks(threeStack()), cfg, noop)
        local visual, hit = ctl.canvases[1], ctl.canvases[2]
        local moved = threeStack()
        for _, w in ipairs(moved) do w.frame = { x = 100, y = 40, w = 600, h = 852 } end
        render.apply(stacks(moved), cfg, noop)

        eq(#ctl.canvases, 2)
        eq(visual.frameWrites, 1)
        eq(visual.frameRect.x, 100 - 32 - 4 - 24, 'padded canvas follows the stack')
        eq(visual.elements[1].frame.x, 24, 'elements are re-laid out relative to the new frame')
        eq(hit.frameRect.x, 100 - 32 - 4)
        eq(hit.replaceCount, 2)
        eq(visual.showing, true)
        eq(visual.showCount, 1)
    end)

    it('keeps canvases of stacks on other Spaces shown, and updates them in place', function()
        local ctl, cfg, stacks, render = setup()
        render.apply(stacks(threeStack()), cfg, noop)
        local visual, hit = ctl.canvases[1], ctl.canvases[2]

        -- A shown canvas stays on its own Space: switching away needs no work at all.
        local away = threeStack()
        for _, w in ipairs(away) do w['is-visible'] = false end
        render.apply(stacks(away), cfg, noop)
        eq(visual.hideCount, 0)
        eq(visual.showing, true)
        eq(hit.showing, true)

        -- Changes while away are applied in place.
        for _, w in ipairs(away) do w.frame = { x = 8, y = 40, w = 500, h = 852 } end
        render.apply(stacks(away), cfg, noop)
        eq(#ctl.canvases, 2)
        eq(visual.replaceCount, 2)

        -- Coming back: nothing to show, it never left.
        for _, w in ipairs(away) do w['is-visible'] = true end
        render.apply(stacks(away), cfg, noop)
        eq(visual.showCount, 1)
        eq(visual.hideCount, 0)
    end)

    it('creates no canvases for stacks first seen on another Space', function()
        local ctl, cfg, stacks, render = setup()
        local hidden = threeStack()
        for _, w in ipairs(hidden) do w['is-visible'] = false end
        render.apply(stacks(hidden), cfg, noop)
        eq(#ctl.canvases, 0)
        eq(render.counts(), 0)
        for _, w in ipairs(hidden) do w['is-visible'] = true end
        render.apply(stacks(hidden), cfg, noop)
        eq(#ctl.showingCanvases(), 2)
    end)

    it('hides occluded stacks and shows them again once uncovered', function()
        local ctl, cfg, stacks, render = setup()
        render.apply(stacks(threeStack()), cfg, noop)
        local visual, hit = ctl.canvases[1], ctl.canvases[2]

        local covered = stacks(threeStack())
        covered[1].occluded, covered[1].visible = true, false
        render.apply(covered, cfg, noop)
        eq(visual.showing, false)
        eq(hit.showing, false)
        eq(visual.deleted, false)
        local _, showing = render.counts()
        eq(showing, 0)

        render.apply(stacks(threeStack()), cfg, noop)
        eq(visual.showing, true)
        eq(hit.showing, true)
        eq(visual.showCount, 2)
        eq(visual.lastShowFade, 0.2)
        eq(#ctl.canvases, 2)
    end)

    it('re-attaches a canvas to the active Space when its stack moved Spaces', function()
        local ctl, cfg, stacks, render = setup()
        render.apply(stacks(threeStack()), cfg, noop)
        local visual = ctl.canvases[1]

        -- The stack now lives on (visible) Space 2: hide() + show() moves the canvas there.
        local moved = threeStack()
        for _, w in ipairs(moved) do w.space = 2 end
        render.apply(stacks(moved), cfg, noop)
        eq(visual.hideCount, 1)
        eq(visual.showCount, 2)
        eq(visual.lastShowFade, 0, 'no fade: the indicators should not blink')
        eq(visual.showing, true)

        -- Moved to a Space that is not visible: park it hidden until that Space shows.
        for _, w in ipairs(moved) do
            w.space = 3
            w['is-visible'] = false
        end
        render.apply(stacks(moved), cfg, noop)
        eq(visual.showing, false)
        eq(visual.hideCount, 2)
        render.apply(stacks(moved), cfg, noop)
        eq(visual.showCount, 2, 'still parked')

        for _, w in ipairs(moved) do w['is-visible'] = true end
        render.apply(stacks(moved), cfg, noop)
        eq(visual.showing, true)
        eq(visual.showCount, 3)
        eq(#ctl.canvases, 2)
    end)

    it('fades out stacks that disappeared, then pools their canvases', function()
        local ctl, cfg, stacks, render = setup()
        render.apply(stacks(threeStack()), cfg, noop)
        local visual, hit = ctl.canvases[1], ctl.canvases[2]
        render.apply({}, cfg, noop)

        eq(visual.showing, false)
        eq(visual.lastHideFade, 0.2)
        eq(visual.deleted, false, 'kept for reuse')
        eq(hit.showing, false)
        local drawn, showing, spare = render.counts()
        eq({ drawn, showing, spare }, { 0, 0, 2 })
        ctl.advance(0.3)
        eq(select(3, render.counts()), 2)
    end)

    it('reuses pooled canvases for new stacks', function()
        local ctl, cfg, stacks, render = setup()
        render.apply(stacks(threeStack()), cfg, noop)
        render.apply({}, cfg, noop)
        ctl.advance(0.3)

        render.apply(stacks({ win(201, 502, 1, RIGHT), win(202, 503, 2, RIGHT) }), cfg, noop)
        eq(#ctl.canvases, 2, 'no canvas was created')
        local visual, hit = ctl.canvases[1], ctl.canvases[2]
        eq(visual.showing, true)
        eq(hit.showing, true)
        eq(#visual.elements, 4)
        eq(visual.elements[2].image.source, 'file:/Applications/App502.app')
        eq(hit.elements[1].id, '201')
        eq(hit.frameRect.x, 1440 - 32, 'moved to the right-side stack')
        eq(select(3, render.counts()), 0)
    end)

    it('does not reuse a canvas while it is still fading out', function()
        local ctl, cfg, stacks, render = setup()
        render.apply(stacks(threeStack()), cfg, noop)
        render.apply({}, cfg, noop)
        render.apply(stacks({ win(201, 502, 1, RIGHT), win(202, 503, 2, RIGHT) }), cfg, noop)
        eq(#ctl.canvases, 3, 'a new visual canvas; the click target (no fade) was reused')
        eq(ctl.canvases[1].showing, false)
        ctl.advance(0.3)
        eq(select(3, render.counts()), 1, 'the faded canvas joined the pool afterwards')
    end)

    it('keeps at most 4 spare canvases of each kind and deletes the rest', function()
        local ctl, cfg, stacks, render = setup()
        render.apply(stacks(stacksOnSpaces(6)), cfg, noop)
        eq(#ctl.canvases, 12)
        render.apply({}, cfg, noop)
        ctl.advance(0.3)
        local deleted = 0
        for _, c in ipairs(ctl.canvases) do
            if c.deleted then deleted = deleted + 1 end
        end
        eq(deleted, 4)
        eq(select(3, render.counts()), 8)
    end)

    it('clear() deletes drawn, pooled and fading canvases', function()
        local ctl, cfg, stacks, render = setup()
        render.apply(stacks(twoStacks()), cfg, noop)
        render.apply(stacks({ win(101, 501, 1, LEFT), win(102, 502, 2, LEFT) }), cfg, noop) -- right stack fades out
        render.clear()
        eq(#ctl.liveCanvases(), 0)
        eq({ render.counts() }, { 0, 0, 0 })
        ctl.advance(1)
        eq(#ctl.liveCanvases(), 0, 'pending fades do not resurrect anything')
    end)

    it('releases the click target when clickToFocus is turned off and reuses it when turned on', function()
        local ctl, cfg, stacks, render = setup()
        render.apply(stacks(threeStack()), cfg, noop)
        local visual, hit = ctl.canvases[1], ctl.canvases[2]

        cfg.features.clickToFocus = false
        render.invalidate()
        render.apply(stacks(threeStack()), cfg, noop)
        eq(hit.showing, false)
        eq(visual.showing, true)
        eq(select(3, render.counts()), 1, 'the click target waits in the pool')

        cfg.features.clickToFocus = true
        render.invalidate()
        render.apply(stacks(threeStack()), cfg, noop)
        eq(#ctl.canvases, 2, 'the pooled click target was reused')
        eq(hit.showing, true)
        eq(hit.showCount, 2)
        eq(visual.showCount, 1)
    end)

    it('skips the click target when clickToFocus is off', function()
        local ctl, cfg, stacks, render = setup({ features = { clickToFocus = false } })
        render.apply(stacks(threeStack()), cfg, noop)
        eq(#ctl.liveCanvases(), 1)
    end)

    it('draws pills without icon elements when showIcons is off', function()
        local ctl, cfg, stacks, render = setup({ appearance = { showIcons = false } })
        render.apply(stacks(threeStack()), cfg, noop)
        eq(#ctl.liveCanvases()[1].elements, 3)
    end)

    it('takes icons from the app path, and from the bundle id only without a path', function()
        local ctl, cfg, stacks, render = setup()
        ctl.apps[503].path = nil
        local bundleCalls = 0
        local fromBundle = hs.image.imageFromAppBundle
        hs.image.imageFromAppBundle = function(id)
            bundleCalls = bundleCalls + 1
            return fromBundle(id)
        end
        render.apply(stacks(threeStack()), cfg, noop)
        local visual = ctl.liveCanvases()[1]
        eq(visual.elements[2].image.source, 'file:/Applications/App501.app')
        eq(visual.elements[4].image.source, 'file:/Applications/App502.app')
        eq(visual.elements[6].image.source, 'bundle:com.example.app503')
        eq(bundleCalls, 1)
    end)

    it('looks up each application icon once', function()
        local ctl, cfg, stacks, render = setup()
        local windows = { win(101, 501, 1, LEFT), win(102, 501, 2, LEFT), win(103, 501, 1, RIGHT), win(104, 502, 2, RIGHT) }
        render.apply(stacks(windows), cfg, noop)
        eq(ctl.imageLookups, 2)
        eq(ctl.appLookups, 2)
        render.invalidate()
        render.apply(stacks(windows), cfg, noop)
        eq(ctl.imageLookups, 2, 'redraws reuse cached icons')
    end)

    it('redraws everything in place after invalidate()', function()
        local ctl, cfg, stacks, render = setup()
        render.apply(stacks(threeStack()), cfg, noop)
        render.invalidate()
        render.apply(stacks(threeStack()), cfg, noop)
        eq(#ctl.canvases, 2)
        eq(ctl.canvases[1].replaceCount, 2)
        eq(ctl.canvases[1].showCount, 1)
    end)

    it('uses the configured window level, and updates it in place', function()
        local ctl, cfg, stacks, render = setup({ appearance = { windowLevel = 'screenSaver' } })
        render.apply(stacks(threeStack()), cfg, noop)
        local visual, hit = ctl.liveCanvases()[1], ctl.liveCanvases()[2]
        eq(visual.levelValue, 1000)
        eq(hit.levelValue, 1000)
        cfg.appearance.windowLevel = 'floating'
        render.invalidate()
        render.apply(stacks(threeStack()), cfg, noop)
        eq(visual.levelValue, 3)
        eq(hit.levelValue, 3)
        eq(#ctl.canvases, 2)
    end)

    it('restyle() applies focus changes made with model.applyFocus', function()
        local ctl, cfg, stacks, render = setup()
        local model = require 'stackline.model'
        local current = stacks(threeStack())
        render.apply(current, cfg, noop)
        model.applyFocus(current, 101)
        render.restyle(cfg)
        eq(ctl.liveCanvases()[1].elements[1].fillColor.alpha, 1)
    end)
end)
