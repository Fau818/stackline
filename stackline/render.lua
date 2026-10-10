-- Draws stack indicators with hs.canvas: one canvas per stack (plus an invisible click target),
-- reconciled against the latest model so unchanged stacks are never redrawn.
local log    = require 'stackline.log'
local layout = require 'stackline.layout'
local model  = require 'stackline.model'
local util   = require 'stackline.util'

local render = {}

local entries = {}    -- one per drawn stack: { stack, layoutKey, focusKey, canvas, hit, elements, side, showing }
local icons = {}      -- icon cache: bundle id (or app path / name) -> hs.image, or false when none exists
local apps = {}       -- pid -> { name, bundle, path }, so each process is looked up once
local generation = 0  -- bumped by invalidate() to rebuild every stack on the next apply()

-- Returns the icon for window record `win`, looked up once per application.
local function iconFor(win)
    local info = win.pid and apps[win.pid]
    if not info or info.name ~= win.app then
        local app = win.pid and hs.application.applicationForPID(win.pid)
        info = { name = win.app, bundle = app and app:bundleID() or false, path = app and app:path() or false }
        if win.pid then apps[win.pid] = info end
    end

    local key = info.bundle or info.path or win.app
    if not key then return nil end
    local image = icons[key]
    if image == nil then
        image = (info.bundle and hs.image.imageFromAppBundle(info.bundle))
            or (info.path and hs.image.iconForFile(info.path))
            or false
        icons[key] = image
        if not image then log.w(('no icon found for %s'):format(tostring(win.app))) end
    end
    return image or nil
end

-- Returns a key that changes whenever the stack's indicator geometry or contents would change.
local function layoutKey(stack)
    local f = stack.frame
    return table.concat({
        generation,
        stack.screen and stack.screen.id or 0,
        util.round(f.x), util.round(f.y), util.round(f.w), util.round(f.h),
        table.concat(stack.ids, ','),
    }, '|')
end

-- Returns a key that changes whenever the stack's focus colors would change.
local function focusKey(stack)
    return tostring(stack.focusedId or 0) .. ':' .. tostring(stack.activeId)
end

-- Returns `rect` translated into the coordinate space of a canvas placed at `origin`.
local function relative(rect, origin)
    return { x = rect.x - origin.x, y = rect.y - origin.y, w = rect.w, h = rect.h }
end

-- Returns a hidden canvas configured for indicators, or nil when `frame` is unusable.
local function newCanvas(frame, level)
    local canvas = hs.canvas.new(frame)
    if not canvas then return nil end
    canvas:level(level)
    -- Transient: hidden by Mission Control and not managed as a window of its own in Spaces.
    canvas:behavior(hs.canvas.windowBehaviors.transient)
    -- yabai ignores AXUnknown windows, so it never tiles, tracks or focuses indicators
    -- (upstream #67: `yabai -m display --focus` used to focus Hammerspoon instead).
    if canvas._accessibilitySubrole then canvas:_accessibilitySubrole('AXUnknown') end
    canvas:clickActivating(false)
    return canvas
end

-- Creates the canvases for `stack`; returns the new entry, or nil when it cannot be drawn.
local function build(stack, cfg, onClick)
    local a = cfg.appearance
    if not stack.screen then return nil end

    local geometry = layout.compute(stack, a, stack.screen.frame)
    local canvas = newCanvas(geometry.canvasFrame, a.windowLevel)
    if not canvas then return nil end

    local elements, indexes = {}, {}
    for i, item in ipairs(geometry.items) do
        local style = layout.style(a, layout.stateFor(stack, item.id), geometry.side)
        elements[#elements + 1] = {
            type = 'rectangle',
            action = 'fill',
            frame = relative(item.rect, geometry.canvasFrame),
            roundedRectRadii = { xRadius = geometry.radius, yRadius = geometry.radius },
            fillColor = style.fill,
            withShadow = true,
            shadow = style.shadow,
        }
        indexes[item.id] = { rect = #elements }

        if a.showIcons then
            local image = iconFor(stack.windows[i])
            if image then
                elements[#elements + 1] = {
                    type = 'image',
                    image = image,
                    frame = relative(item.iconRect, geometry.canvasFrame),
                    imageAlpha = style.iconAlpha,
                }
                indexes[item.id].icon = #elements
            end
        end
    end
    canvas:appendElements(elements)

    -- The visual canvas is padded for shadows and must stay click-through, so clicks go to a
    -- separate canvas covering exactly the indicators (a canvas with a mouse callback swallows
    -- every click inside its frame).
    local hit
    if cfg.features.clickToFocus then
        hit = newCanvas(geometry.bounds, a.windowLevel)
        if hit then
            local targets = {}
            for _, item in ipairs(geometry.items) do
                targets[#targets + 1] = {
                    type = 'rectangle',
                    action = 'fill',
                    fillColor = { alpha = 0 },
                    frame = relative(item.rect, geometry.bounds),
                    trackMouseDown = true,
                    id = tostring(item.id),
                }
            end
            hit:appendElements(targets)
            hit:mouseCallback(function(_, message, id)
                if message == 'mouseDown' then onClick(tonumber(id)) end
            end)
        end
    end

    return {
        stack = stack,
        layoutKey = layoutKey(stack),
        focusKey = focusKey(stack),
        canvas = canvas,
        hit = hit,
        elements = indexes,
        side = geometry.side,
        showing = false,
    }
end

-- Shows an entry's canvases.
local function show(entry, fade)
    entry.canvas:show(fade)
    if entry.hit then entry.hit:show() end
    entry.showing = true
end

-- Hides an entry's canvases (its stack is on a Space that is not visible).
local function hide(entry)
    entry.canvas:hide()
    if entry.hit then entry.hit:hide() end
    entry.showing = false
end

-- Deletes an entry's canvases.
local function destroy(entry, fade)
    entry.canvas:delete(fade)
    if entry.hit then entry.hit:delete() end
end

-- Re-applies focus colors to an entry in place.
local function restyle(entry, a)
    for id, index in pairs(entry.elements) do
        local style = layout.style(a, layout.stateFor(entry.stack, id), entry.side)
        entry.canvas:elementAttribute(index.rect, 'fillColor', style.fill)
        entry.canvas:elementAttribute(index.rect, 'shadow', style.shadow)
        if index.icon then entry.canvas:elementAttribute(index.icon, 'imageAlpha', style.iconAlpha) end
    end
    entry.focusKey = focusKey(entry.stack)
end

-- Reconciles the drawn indicators with `stacks` (from model.build), creating, updating,
-- hiding and deleting canvases as needed. `onClick(windowId)` handles indicator clicks.
function render.apply(stacks, cfg, onClick)
    local a = cfg.appearance
    local fade = a.shouldFade and a.fadeDuration or 0

    local previous = {}
    for i, entry in ipairs(entries) do previous[i] = entry.stack end
    local matches = model.match(previous, stacks)

    local kept, nextEntries = {}, {}
    for i, stack in ipairs(stacks) do
        local old = matches[i] and entries[matches[i]] or nil
        if old then kept[matches[i]] = true end

        if old and old.layoutKey == layoutKey(stack) then
            old.stack = stack
            if stack.visible then
                if old.focusKey ~= focusKey(stack) then restyle(old, a) end
                if not old.showing then show(old, fade) end
            elseif old.showing then
                hide(old)
            end
            nextEntries[#nextEntries + 1] = old
        else
            -- Canvases can only be created on a visible Space, so invisible stacks wait.
            if stack.visible then
                local entry = build(stack, cfg, onClick)
                if entry then
                    -- Replacing an existing stack swaps instantly so the indicators do not blink.
                    show(entry, old and 0 or fade)
                    nextEntries[#nextEntries + 1] = entry
                end
            end
            if old then destroy(old, 0) end
        end
    end

    for i, entry in ipairs(entries) do
        if not kept[i] then destroy(entry, fade) end
    end
    entries = nextEntries
end

-- Re-applies focus colors to every drawn stack whose focus state changed (after model.applyFocus).
function render.restyle(cfg)
    for _, entry in ipairs(entries) do
        if entry.focusKey ~= focusKey(entry.stack) then restyle(entry, cfg.appearance) end
    end
end

-- Forces every stack to be rebuilt on the next apply() (e.g. after an appearance change).
function render.invalidate()
    generation = generation + 1
end

-- Deletes every indicator.
function render.clear(fade)
    for _, entry in ipairs(entries) do destroy(entry, fade or 0) end
    entries = {}
end

-- Forgets cached application icons (they are looked up again on the next build).
function render.forgetIcons()
    icons, apps = {}, {}
end

-- Returns the number of drawn stacks and how many of them are showing.
function render.counts()
    local showing = 0
    for _, entry in ipairs(entries) do
        if entry.showing then showing = showing + 1 end
    end
    return #entries, showing
end

return render
