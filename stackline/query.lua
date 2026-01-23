local log   = hs.logger.new('query', 'info')
log.i('Loading module: query')

local function yabai(command, callback) -- {{{
    callback = callback or function(x) return x end
    command = '-m ' .. command

    hs.task.new(
        stackline.config:get'paths.yabai',
        u.task_cb(callback),   -- wrap callback in json decoder
        command:split(' ')
    ):start()
end  -- }}}

local function stackIdMapper(yabaiWindow) -- {{{
    -- u.p(yabaiWindow)
    local res = {}
    if type(yabaiWindow)~='table' then u.p(yabaiWindow) end
    for _,win in pairs(yabaiWindow or {}) do
        if win['stack-index']~=0 then
            res[tostring(win.id)] = win['stack-index']
        end
    end
    return res
end  -- }}}

local function getStackedWinIds(byStack) -- {{{
    local stackedWinIds = {}
    for _, group in pairs(byStack) do
        for _, win in pairs(group) do
            stackedWinIds[win.id] = true
        end
    end
    return stackedWinIds
end  -- }}}

local function getStackOrderFromWindows(byStack, winStackIdxs) -- {{{
    -- Build a map of stackId -> ordered window IDs based on yabai stack-index
    local result = {}
    for stackId, windows in pairs(byStack) do
        local ordered = {}
        for _, win in pairs(windows) do
            local stackIdx = winStackIdxs[tostring(win.id)] or 0
            table.insert(ordered, {id = win.id, stackIdx = stackIdx})
        end
        table.sort(ordered, function(a, b)
            return a.stackIdx < b.stackIdx
        end)
        result[stackId] = u.map(ordered, function(w) return w.id end)
    end
    return result
end  -- }}}

local function groupWindows(ws) -- {{{
    -- Given windows from hs.window.filter:
    --    1. Create stackline window objects
    --    2. Group wins by `stackId` prop (aka top-left frame coords)
    --    3. If at least one such group, also group wins by app (to workaround hs bug unfocus event bug)
    local byStack
    local byApp

    local windows = u.map(ws, function(w)
        return stackline.window:new(w)
    end)

    -- See 'stackId' def @ /window.lua:233
    local groupKey = c.features.fzyFrameDetect.enabled
        and 'stackIdFzy'
        or 'stackId'

    byStack = u.filter(
        u.groupBy(windows, groupKey),
        u.greaterThan(1))  -- stacks have >1 window, so ignore 'groups' of 1

    if u.length(byStack) > 0 then
        local stackedWinIds = getStackedWinIds(byStack)
        local stackedWins = u.filter(windows, function(w)
            return stackedWinIds[w.id] --true if win id is in stackedWinIds
        end)

        byApp = u.groupBy(stackedWins, 'app') -- app names are keys in group
    end

    return byStack, byApp
end -- }}}

local function removeGroupedWin(win, byStack) -- {{{
    -- remove given window if it's present in byStack windows
    return u.map(byStack, function(stack)
        return u.filter(stack, function(w)
            return w.id ~= win.id
        end)
    end)
end -- }}}

local function mergeWinStackIdxs(byStack, winStackIdxs) -- {{{
    -- merge windowID <> stack-index mapping queried from yabai into window objs

    local function assignStackIndex(win)
        local stackIdx = winStackIdxs[tostring(win.id)]
        if stackIdx == 0 then
            -- Remove windows with stackIdx == 0. Such windows overlap exactly with
            -- other (potentially stacked) windows, and so are grouped with them,
            -- but they are NOT stacked according to yabai.
            -- Windows that belong to a *real* stack have stackIdx > 0.
            byStack = removeGroupedWin(win, byStack)
        end

        -- set the stack idx
        win.stackIdx = stackIdx
    end

    u.each(byStack, function(stack)
        u.each(stack, assignStackIndex)
    end)

    return byStack

end -- }}}

local function shouldRestack(new) -- {{{
    -- Analyze byStack to determine if a stack refresh is needed
    --  • change num stacks (+/-)
    --  • changes to existing stack
    --    • change position
    --    • change num windows (win added / removed)
    -- NOTE: Stack order (swap) is checked separately after yabai query

    local curr = stackline.manager:getSummary()
    new = stackline.manager:getSummary(u.values(new))

    if curr.numStacks ~= new.numStacks then
        log.i('Should refresh -> Num stacks changed')
        return true
    end

    if not u.equal(curr.topLeft, new.topLeft) then
        u.p(curr.topLeft)
        log.i('Should refresh -> Stack position changed', curr.topLeft, new.topLeft)
        return true
    end

    if not u.equal(curr.numWindows, new.numWindows) then
        log.i('Should refresh -> Windows changed')
        return true
    end

    log.i('Should not redraw.')
end -- }}}

local function run(opts) -- {{{
    opts = opts or {}
    local byStack, byApp = groupWindows(stackline.wf:getWindows()) -- set byStack & self.appWindows

    -- Check if space has stacks...
    local spaceHasStacks  = stackline.manager:getSummary().numStacks > 0

    -- Get current stack order before querying yabai (for swap detection)
    local currStackOrder = stackline.manager:getStackOrder()

    local shouldRefresh = spaceHasStacks and shouldRestack(byStack) -- Don't even check on a space that doesn't have any stacks

    if shouldRefresh or opts.forceRedraw then
        log.i('Refreshing stackline')
        -- TODO: if there's only 1 space, use 'query --windows --space' to reduce chance that parsing fails
        local yabai_cmd = 'query --windows'

        yabai(yabai_cmd, function(yabaiRes)
            local winStackIdxs = stackIdMapper(yabaiRes)
            local mergedStacks = mergeWinStackIdxs(byStack, winStackIdxs)
            
            -- Check if stack order changed (swap detection)
            local newStackOrder = getStackOrderFromWindows(mergedStacks, winStackIdxs)
            local orderChanged = not u.equal(currStackOrder, newStackOrder)
            
            if orderChanged then
                log.i('Stack order changed (swap detected) - forcing redraw')
            end
            
            stackline.manager:ingest( -- hand over to stackmanager
                mergedStacks,
                byApp,
                spaceHasStacks or orderChanged
            )
        end)
    elseif spaceHasStacks then
        -- Even if shouldRestack is false, check for swap by querying yabai
        local yabai_cmd = 'query --windows'
        yabai(yabai_cmd, function(yabaiRes)
            local winStackIdxs = stackIdMapper(yabaiRes)
            local newStackOrder = getStackOrderFromWindows(byStack, winStackIdxs)
            
            if not u.equal(currStackOrder, newStackOrder) then
                log.i('Stack order changed (swap detected) - refreshing')
                local mergedStacks = mergeWinStackIdxs(byStack, winStackIdxs)
                stackline.manager:ingest(mergedStacks, byApp, true)
            end
        end)
    end
end -- }}}

return {
    run = run,
    setLogLevel = log.setLogLevel
}
