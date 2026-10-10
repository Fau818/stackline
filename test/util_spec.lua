local t = require 'test.helper'
local describe, it, eq = t.describe, t.it, t.eq

describe('util', function()
    it('deepCopy copies nested tables without sharing them', function()
        local util = require 'stackline.util'
        local src = { a = { b = { 1, 2 } }, c = 'x' }
        local copy = util.deepCopy(src)
        eq(copy, src)
        copy.a.b[1] = 99
        eq(src.a.b[1], 1)
    end)

    it('round and isFinite handle edge values', function()
        local util = require 'stackline.util'
        eq(util.round(2.5), 3)
        eq(util.round(-2.5), -2)
        eq(util.isFinite(1.5), true)
        eq(util.isFinite(0 / 0), false)
        eq(util.isFinite(math.huge), false)
        eq(util.isFinite('1'), false)
    end)

    it('shellQuote survives single quotes', function()
        local util = require 'stackline.util'
        eq(util.shellQuote("it's"), [['it'\''s']])
        eq(util.shellQuote('/Applications/Hammer spoon.app'), "'/Applications/Hammer spoon.app'")
    end)

    it('closest suggests near misses only', function()
        local util = require 'stackline.util'
        local keys = { 'appearance.showIcons', 'appearance.size', 'features.clickToFocus' }
        eq(util.closest('appearance.showIcon', keys), 'appearance.showIcons')
        eq(util.closest('features.clicktofocus', keys), 'features.clickToFocus')
        eq(util.closest('totally.unrelated.thing', keys), nil)
    end)
end)
