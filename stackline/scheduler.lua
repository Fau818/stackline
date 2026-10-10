-- Refresh scheduler: runs an async job at most once per interval, immediately when idle (leading
-- edge), once more after a burst (trailing edge), and never twice at the same time.
local log = require 'stackline.log'

local Scheduler = {}
Scheduler.__index = Scheduler

-- Returns the current monotonic time in seconds.
local function now()
    return hs.timer.absoluteTime() / 1e9
end

-- Returns a scheduler that calls `opts.run(done)`; `opts.interval()` gives the minimum spacing in
-- seconds and `opts.timeout` (seconds) bounds how long a run may take before it is abandoned.
function Scheduler.new(opts)
    return setmetatable({
        run      = opts.run,
        interval = opts.interval,
        timeout  = opts.timeout or 5,
        lastStart = -math.huge,
        running  = false,
        dirty    = false,
        timer    = nil,
        watchdog = nil,
        token    = nil,
        stopped  = false,
    }, Scheduler)
end

-- Asks for a run: starts now when idle, otherwise coalesces into one pending run.
function Scheduler:request()
    if self.stopped then return end
    if self.running then
        self.dirty = true
        return
    end
    if self.timer then return end

    local wait = self.lastStart + (self.interval() or 0) - now()
    if wait <= 0 then
        self:start()
    else
        self.timer = hs.timer.doAfter(wait, function()
            self.timer = nil
            self:start()
        end)
    end
end

-- Starts a run right away (internal).
function Scheduler:start()
    if self.stopped or self.running then return end
    self.running = true
    self.lastStart = now()

    local token = {}
    self.token = token
    self.watchdog = hs.timer.doAfter(self.timeout, function()
        if self.token == token then
            log.w(('refresh did not finish within %ss; continuing'):format(self.timeout))
            self:finish(token)
        end
    end)

    local ok, err = pcall(self.run, function() self:finish(token) end)
    if not ok then
        log.e('refresh failed: ' .. tostring(err))
        self:finish(token)
    end
end

-- Marks the run identified by `token` as finished and starts the coalesced run, if any (internal).
function Scheduler:finish(token)
    if self.token ~= token or not self.running then return end
    self.running = false
    self.token = nil
    if self.watchdog then
        self.watchdog:stop()
        self.watchdog = nil
    end
    if self.dirty then
        self.dirty = false
        self:request()
    end
end

-- Returns true while a run is in progress or pending.
function Scheduler:busy()
    return self.running or self.timer ~= nil
end

-- Cancels pending work; later requests are ignored.
function Scheduler:stop()
    self.stopped = true
    self.running = false
    self.dirty = false
    self.token = nil
    if self.timer then self.timer:stop(); self.timer = nil end
    if self.watchdog then self.watchdog:stop(); self.watchdog = nil end
end

return Scheduler
