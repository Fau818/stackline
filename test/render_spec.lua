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

-- Installs apps for pids 501..503 and returns the default config plus a stacks builder.
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
        return model.build(windows, { tolerance = 30, screens = SCREENS })
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
        eq(visual.lastShowFade, 0.2)
        eq(#visual.elements, 6, 'a rectangle and an icon per window')
        eq(visual.elements[1].type, 'rectangle')
        eq(visual.elements[2].image.source, 'bundle:com.example.app501')
        eq(visual.mouseCallbackFn, nil, 'the padded canvas stays click-through')

        -- Indicator rectangles are relative to the canvas, which is padded for shadows.
        local origin = visual.frameRect
        eq(visual.elements[1].frame.x + origin.x, 0)
        eq(visual.elements[1].frame.y + origin.y, 42)

        eq(#hit.elements, 3)
        eq(hit.elements[2].trackMouseDown, true)
        eq(hit.elements[2].id, '102')
        eq(hit.subrole, 'AXUnknown')
        eq(hit.frameRect, { x = 0, y = 42, w = 32, h = 32 * 1.2 * 2 + 32 })
        ctl.click(hit, '103')
        eq(clicks, { 103 })
    end)

    it('colors the focused, inactive and last-active indicators', function()
        local ctl, cfg, stacks, render = setup()
        render.apply(stacks(threeStack()), cfg, function() end)
        local visual = ctl.liveCanvases()[1]
        eq(visual.elements[3].fillColor.alpha, 1, 'focused window 102')
        t.near(visual.elements[1].fillColor.alpha, 1 / 2.5)

        local unfocused = threeStack()
        unfocused[2]['has-focus'] = false
        table.insert(unfocused, 1, table.remove(unfocused, 3)) -- 103 is now front-most
        render.apply(stacks(unfocused), cfg, function() end)
        t.near(visual.elements[5].fillColor.alpha, 1 / (2.5 / 1.2), 'last-active window 103')
        eq(visual.elements[3].fillColor.alpha, 0, 'idle icons drop their background')
    end)

    it('updates focus in place instead of rebuilding', function()
        local ctl, cfg, stacks, render = setup()
        render.apply(stacks(threeStack()), cfg, function() end)
        local windows = threeStack()
        windows[2]['has-focus'] = false
        windows[3]['has-focus'] = true
        render.apply(stacks(windows), cfg, function() end)

        eq(#ctl.canvases, 2, 'no canvas was created')
        local visual = ctl.canvases[1]
        t.truthy(visual.attributeWrites > 0)
        eq(visual.elements[5].fillColor.alpha, 1, 'window 103 is now highlighted')
    end)

    it('does not touch canvases when nothing changed', function()
        local ctl, cfg, stacks, render = setup()
        render.apply(stacks(threeStack()), cfg, function() end)
        render.apply(stacks(threeStack()), cfg, function() end)
        eq(#ctl.canvases, 2)
        eq(ctl.canvases[1].attributeWrites, 0)
    end)

    it('rebuilds only the stack that changed, swapping without a fade', function()
        local ctl, cfg, stacks, render = setup()
        local windows = { win(101, 501, 1, LEFT), win(102, 502, 2, LEFT), win(103, 503, 1, RIGHT), win(104, 503, 2, RIGHT) }
        render.apply(stacks(windows), cfg, function() end)
        eq(#ctl.liveCanvases(), 4)
        local rightVisual = ctl.canvases[3]

        -- Swap the order of the left stack (e.g. `yabai -m window --swap stack.next`).
        windows[1]['stack-index'], windows[2]['stack-index'] = 2, 1
        render.apply(stacks(windows), cfg, function() end)

        eq(ctl.canvases[1].deleted, true)
        eq(ctl.canvases[1].deleteFade, 0)
        eq(rightVisual.deleted, false, 'the other stack is untouched')
        local fresh = ctl.canvases[5]
        eq(fresh.lastShowFade, 0)
        eq(fresh.elements[2].image.source, 'bundle:com.example.app502', 'window 102 now comes first')
        eq(#ctl.liveCanvases(), 4)
    end)

    it('hides stacks on other Spaces and shows them again when they return', function()
        local ctl, cfg, stacks, render = setup()
        render.apply(stacks(threeStack()), cfg, function() end)
        local hidden = threeStack()
        for _, w in ipairs(hidden) do w['is-visible'] = false end
        render.apply(stacks(hidden), cfg, function() end)
        eq(ctl.canvases[1].showing, false)
        eq(ctl.canvases[1].deleted, false)
        eq(ctl.canvases[2].showing, false)

        render.apply(stacks(threeStack()), cfg, function() end)
        eq(ctl.canvases[1].showing, true)
        eq(#ctl.canvases, 2)
    end)

    it('drops hidden stacks whose layout changed while away, and redraws them on return', function()
        local ctl, cfg, stacks, render = setup()
        render.apply(stacks(threeStack()), cfg, function() end)
        local moved = threeStack()
        for _, w in ipairs(moved) do
            w['is-visible'] = false
            w.frame.w = 500
        end
        render.apply(stacks(moved), cfg, function() end)
        eq(#ctl.liveCanvases(), 0)
        for _, w in ipairs(moved) do w['is-visible'] = true end
        render.apply(stacks(moved), cfg, function() end)
        eq(#ctl.liveCanvases(), 2)
    end)

    it('fades out stacks that disappeared', function()
        local ctl, cfg, stacks, render = setup()
        render.apply(stacks(threeStack()), cfg, function() end)
        render.apply({}, cfg, function() end)
        eq(#ctl.liveCanvases(), 0)
        eq(ctl.canvases[1].deleteFade, 0.2)
        eq(select(1, render.counts()), 0)
    end)

    it('skips the click target when clickToFocus is off', function()
        local ctl, cfg, stacks, render = setup({ features = { clickToFocus = false } })
        render.apply(stacks(threeStack()), cfg, function() end)
        eq(#ctl.liveCanvases(), 1)
    end)

    it('draws pills without icon elements when showIcons is off', function()
        local ctl, cfg, stacks, render = setup({ appearance = { showIcons = false } })
        render.apply(stacks(threeStack()), cfg, function() end)
        eq(#ctl.liveCanvases()[1].elements, 3)
    end)

    it('looks up each application icon once', function()
        local ctl, cfg, stacks, render = setup()
        local windows = { win(101, 501, 1, LEFT), win(102, 501, 2, LEFT), win(103, 501, 1, RIGHT), win(104, 502, 2, RIGHT) }
        render.apply(stacks(windows), cfg, function() end)
        eq(ctl.imageLookups, 2)
        eq(ctl.appLookups, 2)
        render.invalidate()
        render.apply(stacks(windows), cfg, function() end)
        eq(ctl.imageLookups, 2, 'rebuilds reuse cached icons')
    end)

    it('rebuilds everything after invalidate()', function()
        local ctl, cfg, stacks, render = setup()
        render.apply(stacks(threeStack()), cfg, function() end)
        render.invalidate()
        render.apply(stacks(threeStack()), cfg, function() end)
        eq(#ctl.canvases, 4)
        eq(#ctl.liveCanvases(), 2)
    end)

    it('uses the configured window level', function()
        local ctl, cfg, stacks, render = setup({ appearance = { windowLevel = 'screenSaver' } })
        render.apply(stacks(threeStack()), cfg, function() end)
        eq(ctl.liveCanvases()[1].levelValue, 1000)
    end)

    it('restyle() applies focus changes made with model.applyFocus', function()
        local ctl, cfg, stacks, render = setup()
        local model = require 'stackline.model'
        local current = stacks(threeStack())
        render.apply(current, cfg, function() end)
        model.applyFocus(current, 101)
        render.restyle(cfg)
        eq(ctl.liveCanvases()[1].elements[1].fillColor.alpha, 1)
    end)
end)
