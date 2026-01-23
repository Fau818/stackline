local Stack = {}

function Stack:new(stackedWindows) -- {{{
    local stack = {
        windows = stackedWindows
    }
    setmetatable(stack, self)
    self.__index = self
    return stack
end -- }}}

function Stack:get() -- {{{
    return self.windows
end -- }}}

function Stack:getHs() -- {{{
   return u.map(self.windows, function(w)
       return w._win
   end)
end -- }}}

function Stack:frame() -- {{{
   -- All stacked windows have the same dimensions,
   -- so the 1st Hs window's frame is ~= to the stack's frame
   -- TODO: Incorrect when the 1st window has min-size < stack width. See ./query.lua:105
   return self.windows[1]._win:frame()
end -- }}}

function Stack:eachWin(fn) -- {{{
   for _idx, win in pairs(self.windows) do
       fn(win)
   end
end -- }}}

function Stack:getOtherAppWindows(win) -- {{{
   -- NOTE: may not need when HS issue #2400 is closed
   return u.filter(self:get(), function(w)
       return w.app == win.app
   end)
end -- }}}

function Stack:anyFocused() -- {{{
   return u.any(self.windows, function(w)
       return w:isFocused()
   end)
end -- }}}

function Stack:resetAllIndicators() -- {{{
   self:eachWin(function(w)
       w:setupIndicator():drawIndicator()
   end)
end -- }}}

function Stack:redrawAllIndicators(opts) -- {{{
   self:eachWin(function(win)
       if win.id ~= opts.except then
           win:redrawIndicator()
       end
   end)
end -- }}}

function Stack:deleteAllIndicators() -- {{{
   self:eachWin(function(win)
       win:deleteIndicator()
   end)
end -- }}}

function Stack:getWindowByPoint(p)
   -- FIX: https://github.com/AdamWagner/stackline/issues/100
   -- Window indicator frame coordinates are relative to the window's screen.
   -- We need to convert click coordinates to be relative to the stack's screen,
   -- not just any screen with negative coordinates.
   
   -- Get the stack's screen (all windows in stack share the same screen)
   local stackScreen = self.windows[1] and self.windows[1]._win and self.windows[1]._win:screen()
   if not stackScreen then return nil end
   
   -- Check if click point is on the stack's screen
   local stackFrame = stackScreen:frame()
   if not p:inside(stackFrame) then
      -- Click is not on the stack's screen, so it can't be clicking an indicator
      return nil
   end
   
   -- Convert click point to stack screen's local coordinates
   local localPoint = stackScreen:absoluteToLocal(p)

   return table.unpack(
         u.filter(self.windows, function(w)
          local indicatorFrame = w.indicator and w.indicator:canvasElements()[1].frame
          if not indicatorFrame then return false end
          return localPoint:inside(indicatorFrame) -- NOTE: frame *must* be a hs.geometry.rect instance
      end)
   )
end

return Stack
