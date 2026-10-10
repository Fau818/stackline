LUA  ?= lua
LUAC ?= luac

.PHONY: test check

# Unit + integration tests against a mocked Hammerspoon (no yabai or Hammerspoon needed).
test:
	$(LUA) test/run.lua

# Syntax-check every Lua file.
check:
	@find . -name '*.lua' -not -path './.git/*' -print0 | xargs -0 -n1 $(LUAC) -p && echo 'syntax ok'
