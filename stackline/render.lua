-- Draws stack indicators with hs.canvas: one canvas per stack (plus an invisible click target),
-- reconciled against the latest model so unchanged stacks are never redrawn.
--
-- Canvases are reused rather than replaced: canvas:delete() only hides a canvas, and its window
-- lives on until Lua garbage-collects it, so rebuilding on every change would pile up windows.
-- A layout change updates frames and elements in place, and canvases of vanished stacks wait in a
-- small pool for the next new stack.
local log    = require 'stackline.log'
local layout = require 'stackline.layout'
local model  = require 'stackline.model'
local util   = require 'stackline.util'

local render = {}

local POOL_SIZE = 4 -- spare canvases kept per kind ('visual' and 'hit')

local entries = {}                      -- one per drawn stack, see newEntry()
local pool = { visual = {}, hit = {} }  -- hidden canvases ready for reuse
local fading = {}                       -- canvases fading out before they join the pool
local icons = {}                        -- app path (or bundle id) -> hs.image, or false when none exists
local apps = {}                         -- pid -> { name, path, bundle }, so each process is looked up once
local generation = 0                    -- bumped by invalidate() to redraw every stack on the next apply()
local clickHandler = function() end     -- the onClick given to the latest apply()

-- Returns the icon for window record `win`, looked up once per application.
local function iconFor(win)
    local info = win.pid and apps[win.pid]
    if not info or info.name ~= win.app then
        local app = win.pid and hs.application.applicationForPID(win.pid)
        info = { name = win.app, path = app and app:path() or false, bundle = app and app:bundleID() or false }
        if win.pid then apps[win.pid] = info end
    end

    local key = info.path or info.bundle
    if not key then return nil end
    local image = icons[key]
    if image == nil then
        -- iconForFile reads the bundle directly; imageFromAppBundle needs a LaunchServices lookup
        -- (and returns a generic icon rather than nil), so it is only the fallback.
        if info.path then
            image = hs.image.iconForFile(info.path)
        else
            image = hs.image.imageFromAppBundle(info.bundle)
        end
        image = image or false
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

-- Returns a new hidden canvas of `kind` configured for indicators, or nil when `frame` is unusable.
local function newCanvas(kind, frame, level)
    local canvas = hs.canvas.new(frame)
    if not canvas then return nil end
    -- Everything below must be set before the first show(): Hammerspoon creates the window lazily,
    -- and yabai inspects a window's subrole when it first appears.
    canvas:level(level)
    -- Transient: hidden by Mission Control and not managed as a window of its own in Spaces.
    canvas:behavior(hs.canvas.windowBehaviors.transient)
    -- yabai ignores AXUnknown windows, so it never tiles, tracks or focuses indicators
    -- (upstream #67: `yabai -m display --focus` used to focus Hammerspoon instead).
    if canvas._accessibilitySubrole then canvas:_accessibilitySubrole('AXUnknown') end
    canvas:clickActivating(false)
    if kind == 'hit' then
        canvas:mouseCallback(function(_, message, id)
            if message == 'mouseDown' then clickHandler(tonumber(id)) end
        end)
    end
    return canvas
end

-- Returns a hidden canvas of `kind` at `frame`: a pooled one when available, else a new one.
local function acquire(kind, frame, level)
    local spare = table.remove(pool[kind])
    if not spare then return newCanvas(kind, frame, level) end
    spare:frame(frame)
    spare:level(level)
    return spare
end

-- Keeps hidden `canvas` for reuse, or deletes it when the pool is full.
local function stash(kind, canvas)
    local spares = pool[kind]
    if #spares < POOL_SIZE then
        spares[#spares + 1] = canvas
    else
        canvas:delete()
    end
end

-- Hides `canvas` (fading out over `fade` seconds when it is showing) and pools it once hidden.
local function retire(kind, canvas, showing, fade)
    if not showing then return stash(kind, canvas) end
    if not fade or fade <= 0 then
        canvas:hide()
        return stash(kind, canvas)
    end

    canvas:hide(fade)
    -- Reusing it mid-fade would let the fade's completion hide it again, so wait the fade out.
    local pending = { canvas = canvas }
    fading[pending] = true
    pending.timer = hs.timer.doAfter(fade + 0.05, function()
        if not fading[pending] then return end
        fading[pending] = nil
        stash(kind, canvas)
    end)
end

-- Returns the visual elements, the element indexes per window id, and the click targets for `stack`.
local function elementsFor(stack, a, geometry)
    local elements, indexes, targets = {}, {}, {}
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

        -- Hit areas only exist for drawn elements: a 'fill' with a transparent color counts,
        -- 'skip' would not. Clicks inside the canvas but outside a target are swallowed, which is
        -- why this canvas covers exactly the indicators while the visual one is padded.
        targets[#targets + 1] = {
            type = 'rectangle',
            action = 'fill',
            fillColor = { alpha = 0 },
            frame = relative(item.rect, geometry.bounds),
            trackMouseDown = true,
            id = tostring(item.id),
        }
    end
    return elements, indexes, targets
end

-- Sets the window level of `canvas` when it differs from what `entry` last applied.
local function applyLevel(entry, field, canvas, level)
    if entry[field] ~= level then
        canvas:level(level)
        entry[field] = level
    end
end

-- Points `entry` at `stack` and (re)draws its indicators in place, reusing its canvases.
-- Returns false when the stack cannot be drawn (no screen, or no canvas could be created).
local function draw(entry, stack, cfg)
    local a = cfg.appearance
    if not stack.screen then return false end
    local geometry = layout.compute(stack, a, stack.screen.frame)
    local elements, indexes, targets = elementsFor(stack, a, geometry)

    if entry.canvas then
        entry.canvas:frame(geometry.canvasFrame)
        applyLevel(entry, 'level', entry.canvas, a.windowLevel)
    else
        entry.canvas = acquire('visual', geometry.canvasFrame, a.windowLevel)
        if not entry.canvas then return false end
        entry.level = a.windowLevel
    end
    entry.canvas:replaceElements(elements)

    -- The visual canvas is padded for shadows and must stay click-through, so clicks go to a
    -- separate canvas covering exactly the indicators.
    if cfg.features.clickToFocus then
        if entry.hit then
            entry.hit:frame(geometry.bounds)
            applyLevel(entry, 'hitLevel', entry.hit, a.windowLevel)
        else
            entry.hit = acquire('hit', geometry.bounds, a.windowLevel)
            entry.hitLevel = a.windowLevel
            if entry.hit and entry.showing then entry.hit:show() end
        end
        if entry.hit then entry.hit:replaceElements(targets) end
    elseif entry.hit then
        retire('hit', entry.hit, entry.showing, 0)
        entry.hit = nil
    end

    entry.stack, entry.elements, entry.side = stack, indexes, geometry.side
    entry.layoutKey, entry.focusKey = layoutKey(stack), focusKey(stack)
    return true
end

-- Shows or hides an entry's canvases; never shows a canvas that is already showing.
local function setShowing(entry, showing, fade)
    if entry.showing == showing then return end
    if showing then
        entry.canvas:show(fade)
        if entry.hit then entry.hit:show() end
    else
        entry.canvas:hide()
        if entry.hit then entry.hit:hide() end
    end
    entry.showing = showing
end

-- Returns an entry's canvases to the pool (fading the indicators out over `fade` seconds).
local function release(entry, fade)
    if entry.canvas then retire('visual', entry.canvas, entry.showing, fade) end
    if entry.hit then retire('hit', entry.hit, entry.showing, 0) end
    entry.canvas, entry.hit, entry.showing = nil, nil, false
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

-- Reconciles the drawn indicators with `stacks` (from model.build), creating, updating, moving,
-- hiding and retiring canvases as needed. `onClick(windowId)` handles indicator clicks.
--
-- A shown canvas stays on the Space it was shown on, so a stack on a Space that is not visible
-- keeps its canvas (updated in place) without hiding it. Canvases are only created or shown for
-- visible stacks; covered (occluded) stacks are hidden, and a stack that moved to another Space
-- is hidden and shown again, which re-attaches its canvas to the active Space.
function render.apply(stacks, cfg, onClick)
    if onClick then clickHandler = onClick end
    local a = cfg.appearance
    local fade = a.shouldFade and a.fadeDuration or 0

    local previous = {}
    for i, entry in ipairs(entries) do previous[i] = entry.stack end
    local matches = model.match(previous, stacks)

    local kept, nextEntries = {}, {}
    for i, stack in ipairs(stacks) do
        local entry = matches[i] and entries[matches[i]] or nil
        if entry then
            local drawn = true
            if entry.layoutKey ~= layoutKey(stack) then
                drawn = draw(entry, stack, cfg)
            else
                entry.stack = stack
                if entry.focusKey ~= focusKey(stack) then restyle(entry, a) end
            end

            if drawn then
                kept[matches[i]] = true
                if stack.occluded then
                    setShowing(entry, false)
                elseif entry.space ~= stack.space then
                    -- hide() detaches the canvas from its old Space; show() puts it on the active one.
                    setShowing(entry, false)
                    if stack.visible then setShowing(entry, true, 0) end
                elseif stack.visible then
                    setShowing(entry, true, fade)
                end
                entry.space = stack.space
                nextEntries[#nextEntries + 1] = entry
            end
        elseif stack.visible then
            -- Canvases can only be created on a visible Space, so invisible stacks wait.
            entry = { showing = false, space = stack.space }
            if draw(entry, stack, cfg) then
                setShowing(entry, true, fade)
                nextEntries[#nextEntries + 1] = entry
            else
                release(entry, 0)
            end
        end
    end

    for i, entry in ipairs(entries) do
        if not kept[i] then release(entry, fade) end
    end
    entries = nextEntries
end

-- Re-applies focus colors to every drawn stack whose focus state changed (after model.applyFocus).
function render.restyle(cfg)
    for _, entry in ipairs(entries) do
        if entry.focusKey ~= focusKey(entry.stack) then restyle(entry, cfg.appearance) end
    end
end

-- Forces every stack to be redrawn on the next apply() (e.g. after an appearance change).
function render.invalidate()
    generation = generation + 1
end

-- Deletes every indicator, including pooled and fading canvases.
function render.clear(fade)
    for _, entry in ipairs(entries) do
        if entry.canvas then entry.canvas:delete(fade or 0) end
        if entry.hit then entry.hit:delete() end
    end
    entries = {}
    for _, kind in ipairs({ 'visual', 'hit' }) do
        for _, canvas in ipairs(pool[kind]) do canvas:delete() end
        pool[kind] = {}
    end
    for pending in pairs(fading) do
        pending.timer:stop()
        pending.canvas:delete()
    end
    fading = {}
end

-- Forgets cached application icons (they are looked up again on the next draw).
function render.forgetIcons()
    icons, apps = {}, {}
end

-- Returns the number of drawn stacks, how many of them are showing, and the spare canvases kept.
function render.counts()
    local showing = 0
    for _, entry in ipairs(entries) do
        if entry.showing then showing = showing + 1 end
    end
    local spare = #pool.visual + #pool.hit
    for _ in pairs(fading) do spare = spare + 1 end
    return #entries, showing, spare
end

return render
