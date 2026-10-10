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

    it('uses property selection from 7.0.3 on', function()
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
    it('replaces bare inf / nan numbers so the JSON parses', function()
        t.fresh()
        local yabai = require 'stackline.yabai'
        local windows = yabai.decode(WINDOWS_JSON)
        eq(#windows, 2)
        eq(windows[1].frame.w, 1424.0)
        eq(windows[2].frame, { x = 0, y = 0, w = 0, h = 0 })
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
    it('queries only the needed properties on current yabai', function()
        local ctl = t.fresh()
        local yabai = require 'stackline.yabai'
        yabai.setPath('/opt/homebrew/bin/yabai')
        ctl.taskHandler = function(_, args)
            if args[1] == '--version' then return 0, 'yabai-v7.1.25\n', '' end
            return 0, WINDOWS_JSON, ''
        end
        yabai.probe()
        ctl.flushTasks()
        local result
        yabai.queryWindows(function(windows) result = windows end)
        ctl.flushTasks()
        eq(#result, 2)
        local last = ctl.taskLog[#ctl.taskLog]
        eq(last.path, '/opt/homebrew/bin/yabai')
        eq(last.args, { '-m', 'query', '--windows', yabai.WINDOW_PROPERTIES })
    end)

    it('falls back to a full query when yabai rejects the property list', function()
        local ctl = t.fresh()
        local yabai = require 'stackline.yabai'
        yabai.setPath('/usr/local/bin/yabai')
        ctl.taskHandler = function(_, args)
            if args[4] then return 1, '', "unknown option 'id,pid' given to command '--windows' for domain 'query'\n" end
            return 0, WINDOWS_JSON, ''
        end
        local result
        yabai.queryWindows(function(windows) result = windows end)
        ctl.flushTasks()
        eq(#result, 2)
        eq(ctl.taskLog[2].args, { '-m', 'query', '--windows' })
        yabai.queryWindows(function() end)
        ctl.flushTasks()
        eq(#ctl.taskLog[3].args, 3, 'the fallback is remembered')
    end)

    it('skips property selection for yabai older than 7.0.3', function()
        local ctl = t.fresh()
        local yabai = require 'stackline.yabai'
        yabai.setPath('/usr/local/bin/yabai')
        ctl.taskHandler = function(_, args)
            if args[1] == '--version' then return 0, 'yabai-v6.0.15', '' end
            return 0, '[]', ''
        end
        yabai.probe()
        ctl.flushTasks()
        yabai.queryWindows(function() end)
        ctl.flushTasks()
        eq(ctl.taskLog[2].args, { '-m', 'query', '--windows' })
    end)

    it('passes yabai errors through and recognises connection failures', function()
        local ctl = t.fresh()
        local yabai = require 'stackline.yabai'
        yabai.setPath('/opt/homebrew/bin/yabai')
        ctl.taskHandler = function() return 1, '', 'yabai-msg: failed to connect to socket..\n' end
        local result, err = 'unset', nil
        yabai.queryWindows(function(windows, e) result, err = windows, e end)
        ctl.flushTasks()
        eq(result, nil)
        eq(err, 'yabai-msg: failed to connect to socket..')
        eq(yabai.isConnectionError(err), true)
        eq(yabai.isConnectionError('could not locate window'), false)
    end)

    it('terminates hung commands after the timeout', function()
        local ctl = t.fresh()
        local yabai = require 'stackline.yabai'
        yabai.setPath('/opt/homebrew/bin/yabai')
        ctl.taskHandler = function() return nil end -- never exits
        local calls, ok, err = 0, nil, nil
        yabai.exec({ '-m', 'query', '--windows' }, function(o, _, e) calls = calls + 1 ok, err = o, e end, 1)
        ctl.advance(1.5)
        eq(calls, 1)
        eq(ok, false)
        contains(err, 'timed out')
        eq(ctl.hungTasks[1].terminated, true)
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
