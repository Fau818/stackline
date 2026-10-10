local t = require 'test.helper'
local describe, it, eq = t.describe, t.it, t.eq

-- Returns a scheduler whose runs complete when the returned `finish()` is called, plus a run log.
local function setup(interval)
    local Scheduler = require 'stackline.scheduler'
    local runs, pending = {}, {}
    local scheduler = Scheduler.new({
        interval = function() return interval end,
        timeout = 2,
        run = function(done)
            runs[#runs + 1] = hs.timer.absoluteTime() / 1e9
            pending[#pending + 1] = done
        end,
    })
    local function finish()
        local done = table.remove(pending, 1)
        if done then done() end
    end
    return scheduler, runs, finish
end

describe('scheduler', function()
    it('runs immediately when idle (leading edge)', function()
        local ctl = t.fresh()
        local scheduler, runs = setup(0.1)
        scheduler:request()
        eq(#runs, 1)
        eq(runs[1], ctl.now)
    end)

    it('coalesces requests made while a run is in flight into one follow-up run', function()
        local ctl = t.fresh()
        local scheduler, runs, finish = setup(0.1)
        scheduler:request()
        scheduler:request()
        scheduler:request()
        eq(#runs, 1)
        ctl.advance(0.05)
        finish()
        eq(#runs, 1, 'follow-up waits for the interval')
        ctl.advance(0.05)
        eq(#runs, 2)
        finish()
        ctl.advance(1)
        eq(#runs, 2, 'no extra runs without requests')
    end)

    it('throttles bursts to one trailing run per interval', function()
        local ctl = t.fresh()
        local scheduler, runs, finish = setup(0.1)
        scheduler:request()
        finish()
        for _ = 1, 9 do
            ctl.advance(0.01)
            scheduler:request()
        end
        eq(#runs, 1, 'requests inside the interval wait')
        ctl.advance(0.01)
        eq(#runs, 2, 'one trailing run at the end of the interval')
        finish()
        ctl.advance(0.5)
        eq(#runs, 2, 'the burst produced exactly one extra run')
    end)

    it('recovers from a run that never finishes', function()
        local ctl = t.fresh()
        local scheduler, runs = setup(0)
        scheduler:request()
        scheduler:request()
        eq(#runs, 1)
        ctl.advance(2.1)
        eq(#runs, 2, 'the dirty follow-up starts after the timeout')
        t.contains(ctl.logText('w'), 'did not finish')
    end)

    it('ignores requests after stop()', function()
        t.fresh()
        local scheduler, runs = setup(0)
        scheduler:stop()
        scheduler:request()
        eq(#runs, 0)
    end)

    it('treats an error thrown by run() as a finished run', function()
        local ctl = t.fresh()
        local Scheduler = require 'stackline.scheduler'
        local calls = 0
        local scheduler = Scheduler.new({
            interval = function() return 0 end,
            run = function() calls = calls + 1 error('boom') end,
        })
        scheduler:request()
        scheduler:request()
        eq(calls, 2)
        t.contains(ctl.logText('e'), 'boom')
    end)
end)
