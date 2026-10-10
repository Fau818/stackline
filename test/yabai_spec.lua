local t = require 'test.helper'
local describe, it, eq, contains = t.describe, t.it, t.eq, t.contains

-- yabai's real output style: one property per line, frames printed with %.4f.
local WINDOWS_JSON = [[
[{
	"id":101,
	"pid":501,
	"app":"kitty",
	"space":1,
	"frame":{
		"x":8.0000,
		"y":40.0000,
		"w":1424.0000,
		"h":852.0000
	},
	"stack-index":1,
	"has-focus":true,
	"is-visible":true
},{
	"id":102,
	"pid":502,
	"app":"Safari",
	"space":1,
	"frame":{
		"x":inf,
		"y":-inf,
		"w":nan,
		"h":-nan
	},
	"stack-index":0,
	"has-focus":false,
	"is-visible":false
}]
]]

-- Returns the yabai binary and argument list behind a captured /bin/sh task.
local function invocation(task)
    eq(task.path, '/bin/sh')
    eq(task.args[1], '-c')
    eq(task.args[3], t.CAPTURE_TAG)
    return task.args[5], { table.unpack(task.args, 6) }
end

-- Returns true when a file exists at `path`.
local function exists(path)
    local f = io.open(path, 'rb')
    if f then f:close() end
    return f ~= nil
end

describe('yabai.resolve', function()
    it('prefers a configured binary', function()
        local ctl = t.fresh()
        local yabai = require 'stackline.yabai'
        ctl.files['/custom/yabai'] = { mode = 'file' }
        ctl.files['/opt/homebrew/bin/yabai'] = { mode = 'file' }
        eq(yabai.resolve('/custom/yabai'), '/custom/yabai')
    end)

    it('accepts a Homebrew prefix directory such as /opt/homebrew/opt/yabai (#125)', function()
        local ctl = t.fresh()
        local yabai = require 'stackline.yabai'
        ctl.files['/opt/homebrew/opt/yabai'] = { mode = 'directory' }
        ctl.files['/opt/homebrew/opt/yabai/bin/yabai'] = { mode = 'file' }
        eq(yabai.resolve('/opt/homebrew/opt/yabai'), '/opt/homebrew/opt/yabai/bin/yabai')
    end)

    it('auto-detects Apple Silicon before Intel Homebrew', function()
        local ctl = t.fresh()
        local yabai = require 'stackline.yabai'
        ctl.files['/usr/local/bin/yabai'] = { mode = 'file' }
        eq(yabai.resolve('auto'), '/usr/local/bin/yabai')
        ctl.files['/opt/homebrew/bin/yabai'] = { mode = 'file' }
        eq(yabai.resolve('auto'), '/opt/homebrew/bin/yabai')
    end)

    it('falls back to auto-detection when the configured path is unusable', function()
        local ctl = t.fresh()
        local yabai = require 'stackline.yabai'
        ctl.files['/opt/homebrew/bin/yabai'] = { mode = 'file' }
        eq(yabai.resolve('/usr/local/bin/yabai'), '/opt/homebrew/bin/yabai')
        contains(ctl.logText('w'), 'is not an executable')
    end)

    it('returns nil and the paths it tried when yabai is missing', function()
        t.fresh()
        local yabai = require 'stackline.yabai'
        local path, tried = yabai.resolve('auto')
        eq(path, nil)
        contains(table.concat(tried, ' '), '/opt/homebrew/bin/yabai')
    end)
end)

describe('yabai versions', function()
    it('parses `yabai --version` output', function()
        t.fresh()
        local yabai = require 'stackline.yabai'
        eq(yabai.parseVersion('yabai-v7.1.25\n'), { 7, 1, 25 })
        eq(yabai.parseVersion('garbage'), nil)
    end)

    it('knows property selection arrived in 7.0.3', function()
        t.fresh()
        local yabai = require 'stackline.yabai'
        eq(yabai.supportsPropertySelection({ 7, 1, 25 }), true)
        eq(yabai.supportsPropertySelection({ 7, 0, 3 }), true)
        eq(yabai.supportsPropertySelection({ 7, 0, 2 }), false)
        eq(yabai.supportsPropertySelection({ 6, 0, 15 }), false)
        eq(yabai.supportsPropertySelection({ 8, 0, 0 }), true)
    end)
end)

describe('yabai.decode', function()
    it('turns bare inf / nan numbers into nil fields so the JSON parses', function()
        t.fresh()
        local yabai = require 'stackline.yabai'
        local windows = yabai.decode(WINDOWS_JSON)
        eq(#windows, 2)
        eq(windows[1].frame.w, 1424.0)
        eq(windows[2].frame, {}, 'x, y, w and h are all nil')
        eq(windows[2].app, 'Safari')
    end)

    it('reports empty and invalid output', function()
        t.fresh()
        local yabai = require 'stackline.yabai'
        local value, err = yabai.decode('')
        eq(value, nil)
        contains(err, 'empty')
        value, err = yabai.decode('{ nope')
        eq(value, nil)
        contains(err, 'JSON')
    end)
end)

describe('yabai commands', function()
    it('captures stdout in a file and removes it afterwards', function()
        local ctl = t.fresh()
        local yabai = require 'stackline.yabai'
        yabai.setPath('/opt/homebrew/bin/yabai')
        ctl.taskHandler = t.yabai(function() return 0, 'yabai-v7.1.25\n', '' end)
        local out
        yabai.exec({ '--version' }, function(ok, stdout) out = { ok, stdout } end)
        local task = ctl.taskLog[1]
        local bin, args = invocation(task)
        eq(bin, '/opt/homebrew/bin/yabai')
        eq(args, { '--version' })
        eq(task.args[2], 'out=$1; shift; exec "$@" >"$out"')
        local file = task.args[4]
        eq(file:sub(1, #ctl.tmpdir), ctl.tmpdir, 'inside hs.fs.temporaryDirectory()')
        ctl.flushTasks()
        eq(out, { true, 'yabai-v7.1.25\n' })
        eq(exists(file), false)
    end)

    it('returns output larger than a pipe buffer intact', function()
        local ctl = t.fresh()
        local json = require 'test.json'
        local yabai = require 'stackline.yabai'
        yabai.setPath('/opt/homebrew/bin/yabai')
        local windows = {}
        for i = 1, 500 do
            windows[i] = {
                id = i, pid = 1000 + i, app = 'App ' .. i .. ' 微信', space = (i % 4) + 1,
                frame = { x = 8.0, y = 40.0, w = 700.5, h = 852.25 },
                ['stack-index'] = i % 3, ['has-focus'] = i == 1, ['is-visible'] = true,
                ['has-parent-zoom'] = false, ['has-fullscreen-zoom'] = false,
            }
        end
        local payload = json.encode(windows)
        t.truthy(#payload > 65536, 'fixture exceeds 64 KB: ' .. #payload)
        ctl.taskHandler = t.yabai(function() return 0, payload, '' end)
        local result
        yabai.queryWindows(function(list) result = list end)
        ctl.flushTasks()
        eq(#result, 500)
        eq(result[500].app, 'App 500 微信')
        eq(result[499]['stack-index'], 499 % 3)
    end)

    it('queries only the needed properties, including zoom state', function()
        local ctl = t.fresh()
        local yabai = require 'stackline.yabai'
        yabai.setPath('/opt/homebrew/bin/yabai')
        ctl.taskHandler = t.yabai(function(_, args)
            if args[1] == '--version' then return 0, 'yabai-v7.1.25\n', '' end
            return 0, WINDOWS_JSON, ''
        end)
        yabai.probe()
        ctl.flushTasks()
        eq(yabai.version(), { 7, 1, 25 })
        local result
        yabai.queryWindows(function(windows) result = windows end)
        ctl.flushTasks()
        eq(#result, 2)
        local bin, args = invocation(ctl.taskLog[#ctl.taskLog])
        eq(bin, '/opt/homebrew/bin/yabai')
        eq(args, { '-m', 'query', '--windows', yabai.WINDOW_PROPERTIES })
        contains(args[4], 'has-parent-zoom')
        contains(args[4], 'has-fullscreen-zoom')
    end)

    it('falls back to a full query when yabai rejects the property list, until reset()', function()
        local ctl = t.fresh()
        local yabai = require 'stackline.yabai'
        yabai.setPath('/usr/local/bin/yabai')
        ctl.taskHandler = t.yabai(function(_, args)
            if args[4] then return 1, '', "unknown option 'id,pid' given to command '--windows' for domain 'query'\n" end
            return 0, WINDOWS_JSON, ''
        end)
        local result
        yabai.queryWindows(function(windows) result = windows end)
        ctl.flushTasks()
        eq(#result, 2)
        local _, retry = invocation(ctl.taskLog[2])
        eq(retry, { '-m', 'query', '--windows' })

        yabai.queryWindows(function() end)
        ctl.flushTasks()
        local _, remembered = invocation(ctl.taskLog[3])
        eq(#remembered, 3, 'the fallback is remembered')

        yabai.reset()
        yabai.queryWindows(function() end)
        ctl.flushTasks()
        local _, again = invocation(ctl.taskLog[4])
        eq(#again, 4, 'a restarted yabai is asked for properties again')
    end)

    it('does not let an old `--version` disable property selection', function()
        local ctl = t.fresh()
        local yabai = require 'stackline.yabai'
        yabai.setPath('/usr/local/bin/yabai')
        ctl.taskHandler = t.yabai(function(_, args)
            if args[1] == '--version' then return 0, 'yabai-v6.0.15', '' end
            return 0, '[]', ''
        end)
        yabai.probe()
        ctl.flushTasks()
        eq(yabai.version(), { 6, 0, 15 })
        yabai.queryWindows(function() end)
        ctl.flushTasks()
        local _, args = invocation(ctl.taskLog[2])
        eq(args, { '-m', 'query', '--windows', yabai.WINDOW_PROPERTIES }, 'the daemon decides, not the binary')
    end)

    it('passes yabai errors through, removes the capture file, and recognises connection failures', function()
        local ctl = t.fresh()
        local yabai = require 'stackline.yabai'
        yabai.setPath('/opt/homebrew/bin/yabai')
        ctl.taskHandler = t.yabai(function() return 1, 'partial', 'yabai-msg: failed to connect to socket..\n' end)
        local result, err = 'unset', nil
        yabai.queryWindows(function(windows, e) result, err = windows, e end)
        ctl.flushTasks()
        eq(result, nil)
        eq(err, 'yabai-msg: failed to connect to socket..')
        eq(yabai.isConnectionError(err), true)
        eq(yabai.isConnectionError('could not locate window'), false)
        eq(exists(ctl.taskLog[1].args[4]), false)
    end)

    it('terminates hung commands after the timeout and removes their capture file', function()
        local ctl = t.fresh()
        local yabai = require 'stackline.yabai'
        yabai.setPath('/opt/homebrew/bin/yabai')
        ctl.taskHandler = function(_, args)
            local f = assert(io.open(args[4], 'wb')) -- the hung process already wrote something
            f:write('partial output')
            f:close()
            return nil -- never exits
        end
        local calls, ok, err = 0, nil, nil
        yabai.exec({ '-m', 'query', '--windows' }, function(o, _, e) calls = calls + 1 ok, err = o, e end, 1)
        ctl.advance(1.5)
        eq(calls, 1)
        eq(ok, false)
        contains(err, 'timed out')
        eq(ctl.hungTasks[1].terminated, true)
        eq(exists(ctl.hungTasks[1].args[4]), false)
    end)

    it('reports a launch failure exactly once', function()
        local ctl = t.fresh()
        local yabai = require 'stackline.yabai'
        yabai.setPath('/opt/homebrew/bin/yabai')
        ctl.hs.task.new = function() return nil end
        local calls, ok, err = 0, nil, nil
        local task = yabai.exec({ '-m', 'query', '--windows' }, function(o, _, e) calls = calls + 1 ok, err = o, e end, 1)
        ctl.advance(2)
        eq(task, nil)
        eq(calls, 1)
        eq(ok, false)
        contains(err, 'could not launch')
    end)

    it('reports a missing binary without launching anything', function()
        local ctl = t.fresh()
        local yabai = require 'stackline.yabai'
        local ok, err
        yabai.exec({ '--version' }, function(o, _, e) ok, err = o, e end)
        eq(ok, false)
        contains(err, 'not found')
        eq(#ctl.taskLog, 0)
    end)

    it('derives the socket path from $USER', function()
        t.fresh()
        local yabai = require 'stackline.yabai'
        eq(yabai.socketPath(), '/tmp/yabai_' .. os.getenv('USER') .. '.socket')
    end)
end)
