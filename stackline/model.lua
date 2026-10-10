-- Turns yabai window records into stack descriptions. Pure functions: no Hammerspoon calls.
local util = require 'stackline.util'

local model = {}

-- Returns a normalized record for a stacked window, or nil when `w` is not part of a stack.
-- `z` is the record's position in yabai's output, which is front-to-back window order.
-- When `frontPid` is given, keyboard focus only counts for windows of that (frontmost) process.
local function normalize(w, z, frontPid)
    if type(w) ~= 'table' then return nil end

    local index = math.tointeger(tonumber(w['stack-index'])) or 0
    local id = math.tointeger(tonumber(w.id))
    if index <= 0 or not id then return nil end

    -- yabai's inf/nan frame values arrive as nil here and fail the finiteness check.
    local f = w.frame
    if type(f) ~= 'table' then return nil end
    local x, y, width, height = tonumber(f.x), tonumber(f.y), tonumber(f.w), tonumber(f.h)
    if not (util.isFinite(x) and util.isFinite(y) and util.isFinite(width) and util.isFinite(height)) then return nil end
    if width <= 0 or height <= 0 then return nil end

    -- yabai < 4.0 used `focused`/`visible`/`zoom-parent`/`zoom-fullscreen` (0/1) instead.
    local focused = w['has-focus']
    if focused == nil then focused = (w.focused == 1) end
    local visible = w['is-visible']
    if visible == nil then visible = (w.visible == 1) end
    local zoomParent = w['has-parent-zoom'] == true or w['zoom-parent'] == 1
    local zoomFullscreen = w['has-fullscreen-zoom'] == true or w['zoom-fullscreen'] == 1

    local pid = math.tointeger(tonumber(w.pid))
    -- yabai keeps reporting the last window it saw focused when focus moves to an app it does not
    -- track (Raycast, Alfred, ...), so trust it only for the frontmost process.
    if frontPid and pid ~= frontPid then focused = false end

    return {
        id = id,
        pid = pid,
        app = w.app,
        space = w.space or 0,
        frame = { x = x, y = y, w = width, h = height },
        stackIndex = index,
        focused = focused == true,
        visible = visible == true,
        zoomParent = zoomParent,
        zoomFullscreen = zoomFullscreen,
        zoom = zoomFullscreen and 'F' or (zoomParent and 'P' or '-'),
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

-- Sorts `windows` by stack index (front-most first among equal indexes).
local function sortByIndex(windows)
    table.sort(windows, function(a, b)
        if a.stackIndex ~= b.stackIndex then return a.stackIndex < b.stackIndex end
        return a.z < b.z
    end)
end

-- Returns a stack description for the (index-sorted) windows of one cluster.
local function makeStack(space, windows, screens)
    local top, focused, visible, ids = windows[1], nil, false, {}
    local f = windows[1].frame
    local x, y, w, h = f.x, f.y, f.w, f.h
    for i, win in ipairs(windows) do
        ids[i] = win.id
        if win.z < top.z then top = win end
        if win.focused then focused = win end
        visible = visible or win.visible
        -- The smallest origin and size approximate yabai's node area, and do not depend on which
        -- window is in front: min-size apps can be larger than the node.
        local wf = win.frame
        x, y = math.min(x, wf.x), math.min(y, wf.y)
        w, h = math.min(w, wf.w), math.min(h, wf.h)
    end

    -- The front-most window is the one the user sees; when the stack is not focused it is also the
    -- stack's last-active window, so it keeps the brighter "last active" indicator.
    local frame = { x = x, y = y, w = w, h = h }
    return {
        space     = space,
        windows   = windows,
        ids       = ids,
        focusedId = focused and focused.id or nil,
        topId     = top.id,
        activeId  = focused and focused.id or top.id,
        frame     = frame,
        visible   = visible,
        screen    = model.screenFor(frame, screens),
    }
end

-- Returns true when two of `windows` claim the same stack index.
local function hasDuplicates(windows)
    local seen = {}
    for _, win in ipairs(windows) do
        if seen[win.stackIndex] then return true end
        seen[win.stackIndex] = true
    end
    return false
end

-- Returns `windows` split into groups of equal rounded size, in first-seen (front-to-back) order.
-- Two stacks only end up in one cluster when their nodes share an origin; their sizes then differ.
local function splitBySize(windows)
    local groups, byKey = {}, {}
    for _, win in ipairs(windows) do
        local key = util.round(win.frame.w) .. 'x' .. util.round(win.frame.h)
        local group = byKey[key]
        if not group then
            group = {}
            byKey[key] = group
            groups[#groups + 1] = group
        end
        group[#group + 1] = win
    end
    return groups
end

-- Returns `windows` with only the front-most window per stack index, and the number dropped.
local function dedupe(windows)
    local best, order = {}, {}
    for _, win in ipairs(windows) do
        local current = best[win.stackIndex]
        if not current then
            best[win.stackIndex] = win
            order[#order + 1] = win.stackIndex
        elseif win.z < current.z then
            best[win.stackIndex] = win
        end
    end
    local kept = {}
    for i, index in ipairs(order) do kept[i] = best[index] end
    return kept, #windows - #kept
end

-- Returns true when the (index-sorted) windows are numbered exactly 1..n.
local function contiguous(windows)
    for i, win in ipairs(windows) do
        if win.stackIndex ~= i then return false end
    end
    return true
end

-- Returns a record for a visible window that could hide a stack behind it, or nil.
local function occluder(w, z)
    if type(w) ~= 'table' or not (w['is-visible'] == true or w.visible == 1) or type(w.frame) ~= 'table' then
        return nil
    end
    local f = w.frame
    local x, y, width, height = tonumber(f.x), tonumber(f.y), tonumber(f.w), tonumber(f.h)
    if not (util.isFinite(x) and util.isFinite(y) and util.isFinite(width) and util.isFinite(height)) then return nil end
    return { id = math.tointeger(tonumber(w.id)), space = w.space or 0, z = z, x = x, y = y, w = width, h = height }
end

-- Returns true when rect `outer` covers rect `inner` (with a 2px allowance for rounding).
local function covers(outer, inner)
    local slack = 2
    return outer.x <= inner.x + slack and outer.y <= inner.y + slack
        and outer.x + outer.w >= inner.x + inner.w - slack
        and outer.y + outer.h >= inner.y + inner.h - slack
end

-- Marks stacks that are completely covered by a window in front of them (a zoom-parent or
-- zoom-fullscreen window, a maximized floating window, ...) as occluded and not visible, so their
-- indicators are not drawn on top of that window (upstream #11).
local function markOccluded(stacks, occluders)
    for _, stack in ipairs(stacks) do
        local top, members = stack.windows[1], {}
        for _, w in ipairs(stack.windows) do
            members[w.id] = true
            if w.z < top.z then top = w end
        end
        for _, o in ipairs(occluders) do
            if o.z < top.z and o.space == stack.space and not members[o.id] and covers(o, stack.frame) then
                stack.occluded, stack.visible = true, false
                break
            end
        end
    end
end

-- Returns the stacks found in `windows` (decoded `yabai -m query --windows` output), plus
-- `{ inconsistent = n }` counting windows/clusters that look mid-update: stacked windows without a
-- partner, duplicate stack indexes, and stacks whose indexes are not exactly 1..n.
-- `opts.tolerance` is the max distance (px) between top-left corners of windows in one stack;
-- `opts.screens` is a list of `{ id, frame }` used to attach each stack to its screen;
-- `opts.frontPid` limits focus to windows of the frontmost process.
function model.build(windows, opts)
    opts = opts or {}
    local tolerance = opts.tolerance or 0
    local spaces, spaceOrder, occluders = {}, {}, {}

    for z, record in ipairs(windows or {}) do
        local front = occluder(record, z)
        if front then occluders[#occluders + 1] = front end

        local win = normalize(record, z, opts.frontPid)
        if win then
            local clusters = spaces[win.space]
            if not clusters then
                clusters = {}
                spaces[win.space] = clusters
                spaceOrder[#spaceOrder + 1] = win.space
            end

            -- Windows in one yabai stack share the node's origin; sizes may differ (min-size apps).
            -- Zoomed nodes take their parent's (or the root's) area, so a zoomed stack can land on a
            -- sibling's origin: keep zoom states apart.
            local x, y = util.round(win.frame.x), util.round(win.frame.y)
            local cluster
            for _, c in ipairs(clusters) do
                if c.zoom == win.zoom and math.abs(c.x - x) <= tolerance and math.abs(c.y - y) <= tolerance then
                    cluster = c
                    break
                end
            end
            if not cluster then
                cluster = { x = x, y = y, zoom = win.zoom, windows = {} }
                clusters[#clusters + 1] = cluster
            end
            cluster.windows[#cluster.windows + 1] = win
        end
    end

    local stacks, inconsistent = {}, 0
    for _, space in ipairs(spaceOrder) do
        for _, cluster in ipairs(spaces[space]) do
            local groups = hasDuplicates(cluster.windows) and splitBySize(cluster.windows) or { cluster.windows }
            for _, candidates in ipairs(groups) do
                local group = candidates
                if hasDuplicates(group) then
                    local dropped
                    group, dropped = dedupe(group)
                    inconsistent = inconsistent + dropped
                end
                -- yabai only reports stack-index > 0 for nodes holding 2+ windows; a lone window here
                -- is a transient state (e.g. mid re-layout), so it is not drawn.
                if #group < 2 then
                    inconsistent = inconsistent + #group
                else
                    sortByIndex(group)
                    if not contiguous(group) then inconsistent = inconsistent + 1 end
                    stacks[#stacks + 1] = makeStack(space, group, opts.screens)
                end
            end
        end
    end
    markOccluded(stacks, occluders)
    return stacks, { inconsistent = inconsistent }
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
