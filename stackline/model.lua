-- Turns yabai window records into stack descriptions. Pure functions: no Hammerspoon calls.
local util = require 'stackline.util'

local model = {}

-- Returns a normalized record for a stacked window, or nil when `w` is not part of a stack.
-- `z` is the record's position in yabai's output, which is front-to-back window order.
local function normalize(w, z)
    if type(w) ~= 'table' then return nil end

    local index = math.tointeger(tonumber(w['stack-index'])) or 0
    local id = math.tointeger(tonumber(w.id))
    if index <= 0 or not id then return nil end

    local f = w.frame
    if type(f) ~= 'table' then return nil end
    local x, y, width, height = tonumber(f.x), tonumber(f.y), tonumber(f.w), tonumber(f.h)
    if not (util.isFinite(x) and util.isFinite(y) and util.isFinite(width) and util.isFinite(height)) then return nil end
    if width <= 0 or height <= 0 then return nil end

    -- yabai < 4.0 used `focused`/`visible` (0/1) instead of `has-focus`/`is-visible`.
    local focused = w['has-focus']
    if focused == nil then focused = (w.focused == 1) end
    local visible = w['is-visible']
    if visible == nil then visible = (w.visible == 1) end

    return {
        id = id,
        pid = math.tointeger(tonumber(w.pid)),
        app = w.app,
        space = w.space or 0,
        frame = { x = x, y = y, w = width, h = height },
        stackIndex = index,
        focused = focused == true,
        visible = visible == true,
        z = z,
    }
end

-- Returns the screen (from `screens`, each `{ id, frame }`) that contains the center of `frame`,
-- falling back to the screen it overlaps most; nil when `screens` is empty.
function model.screenFor(frame, screens)
    if not screens or #screens == 0 then return nil end

    local cx, cy = frame.x + frame.w / 2, frame.y + frame.h / 2
    for _, screen in ipairs(screens) do
        local s = screen.frame
        if cx >= s.x and cx < s.x + s.w and cy >= s.y and cy < s.y + s.h then return screen end
    end

    local best, bestArea = screens[1], -1
    for _, screen in ipairs(screens) do
        local s = screen.frame
        local w = math.min(frame.x + frame.w, s.x + s.w) - math.max(frame.x, s.x)
        local h = math.min(frame.y + frame.h, s.y + s.h) - math.max(frame.y, s.y)
        local area = (w > 0 and h > 0) and (w * h) or 0
        if area > bestArea then best, bestArea = screen, area end
    end
    return best
end

-- Returns a stack description for the windows of one cluster.
local function makeStack(space, windows, screens)
    table.sort(windows, function(a, b)
        if a.stackIndex ~= b.stackIndex then return a.stackIndex < b.stackIndex end
        return a.z < b.z
    end)

    local top, focused, visible, ids = windows[1], nil, false, {}
    for i, w in ipairs(windows) do
        ids[i] = w.id
        if w.z < top.z then top = w end
        if w.focused then focused = w end
        visible = visible or w.visible
    end

    -- The front-most window is the one the user sees; when the stack is not focused it is also the
    -- stack's last-active window, so it keeps the brighter "last active" indicator.
    local f = top.frame
    return {
        space     = space,
        windows   = windows,
        ids       = ids,
        focusedId = focused and focused.id or nil,
        topId     = top.id,
        activeId  = focused and focused.id or top.id,
        frame     = { x = f.x, y = f.y, w = f.w, h = f.h },
        visible   = visible,
        screen    = model.screenFor(f, screens),
    }
end

-- Returns the list of stacks found in `windows` (decoded `yabai -m query --windows` output).
-- `opts.tolerance` is the max distance (px) between top-left corners of windows in one stack;
-- `opts.screens` is a list of `{ id, frame }` used to attach each stack to its screen.
function model.build(windows, opts)
    opts = opts or {}
    local tolerance = opts.tolerance or 0
    local spaces, spaceOrder = {}, {}

    for z, record in ipairs(windows or {}) do
        local win = normalize(record, z)
        if win then
            local clusters = spaces[win.space]
            if not clusters then
                clusters = {}
                spaces[win.space] = clusters
                spaceOrder[#spaceOrder + 1] = win.space
            end

            -- Windows in one yabai stack share the node's origin; sizes may differ (min-size apps).
            local x, y = util.round(win.frame.x), util.round(win.frame.y)
            local cluster
            for _, c in ipairs(clusters) do
                if math.abs(c.x - x) <= tolerance and math.abs(c.y - y) <= tolerance then
                    cluster = c
                    break
                end
            end
            if not cluster then
                cluster = { x = x, y = y, windows = {} }
                clusters[#clusters + 1] = cluster
            end
            cluster.windows[#cluster.windows + 1] = win
        end
    end

    local stacks = {}
    for _, space in ipairs(spaceOrder) do
        for _, cluster in ipairs(spaces[space]) do
            -- yabai only reports stack-index > 0 for nodes holding 2+ windows; a lone window here is
            -- a transient state (e.g. mid re-layout), so it is not drawn.
            if #cluster.windows >= 2 then
                stacks[#stacks + 1] = makeStack(space, cluster.windows, opts.screens)
            end
        end
    end
    return stacks
end

-- Returns a map from new-stack index to old-stack index, pairing stacks that share the most windows.
function model.match(oldStacks, newStacks)
    local candidates = {}
    for ni, new in ipairs(newStacks) do
        local ids = {}
        for _, id in ipairs(new.ids) do ids[id] = true end
        for oi, old in ipairs(oldStacks) do
            local shared = 0
            for _, id in ipairs(old.ids) do
                if ids[id] then shared = shared + 1 end
            end
            if shared > 0 then candidates[#candidates + 1] = { new = ni, old = oi, shared = shared } end
        end
    end

    table.sort(candidates, function(a, b)
        if a.shared ~= b.shared then return a.shared > b.shared end
        if a.new ~= b.new then return a.new < b.new end
        return a.old < b.old
    end)

    local newToOld, usedOld = {}, {}
    for _, c in ipairs(candidates) do
        if not newToOld[c.new] and not usedOld[c.old] then
            newToOld[c.new] = c.old
            usedOld[c.old] = true
        end
    end
    return newToOld
end

-- Returns the stack containing window `id` and the window record, or nil.
function model.find(stacks, id)
    for _, stack in ipairs(stacks or {}) do
        for _, w in ipairs(stack.windows) do
            if w.id == id then return stack, w end
        end
    end
    return nil
end

-- Updates focus state in place as if window `id` just received focus (it may be outside any stack).
-- Returns the list of stacks whose focus state changed.
function model.applyFocus(stacks, id)
    local changed = {}
    for _, stack in ipairs(stacks or {}) do
        local contains = false
        for _, w in ipairs(stack.windows) do
            if w.id == id then contains = true break end
        end
        if contains then
            if stack.focusedId ~= id or stack.activeId ~= id then
                stack.focusedId, stack.activeId = id, id
                changed[#changed + 1] = stack
            end
        elseif stack.focusedId then
            -- The stack keeps its last-active window; it is merely no longer focused.
            stack.focusedId = nil
            changed[#changed + 1] = stack
        end
    end
    return changed
end

return model
