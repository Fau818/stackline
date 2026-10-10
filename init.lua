-- Entry point. In your Hammerspoon init.lua:
--     stackline = require 'stackline'
--     stackline:init()

-- Resolve modules relative to this file, so the repo works wherever it is cloned or symlinked.
local root = debug.getinfo(1, 'S').source:match('^@(.*)/init%.lua$') or (hs.configdir .. '/stackline')
local modules = root .. '/?.lua'
if not package.path:find(modules, 1, true) then
    package.path = modules .. ';' .. package.path
end

return require 'stackline.core'
