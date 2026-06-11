-- paramset.lua
-- Minimal fake of the norns `params` API for off-hardware tests of
-- params_sync. Mirrors the semantics the real ParamSet guarantees that the
-- sync layer depends on:
--   * set(id, v, silent): silent=true NEVER fires the action (the loop-killer)
--   * numbers clamp to [min, max]
--   * bang() fires every action except triggers/separators/groups
-- It is stricter than norns in one way: a non-silent set always fires (norns
-- numbers skip unchanged values), so "zero fires during reflection" assertions
-- catch every would-be action. `fires` counts non-silent action invocations.

local Fake = {}
Fake.__index = Fake

local function add(self, p)
  p.get = function(pp) return pp.value end
  self.list[#self.list + 1] = p
  if p.id then self.lookup[p.id] = p end
end

function Fake.new()
  local self = setmetatable({}, Fake)
  self.list = {}
  self.lookup = {}
  self.fires = 0
  return self
end

function Fake:add_separator(id, name) add(self, {t = 'separator', id = id, name = name}) end
function Fake:add_group(id, name, n) add(self, {t = 'group', id = id, name = name, n = n}) end
function Fake:add_option(id, name, options, default)
  add(self, {t = 'option', id = id, name = name, options = options,
             value = default or 1, action = function() end})
end
function Fake:add_number(id, name, min, max, default, formatter)
  add(self, {t = 'number', id = id, name = name, min = min, max = max,
             value = default or min, formatter = formatter, action = function() end})
end
function Fake:add_binary(id, name, behavior, default)
  add(self, {t = 'binary', id = id, name = name, behavior = behavior,
             value = default or 0, action = function() end})
end
function Fake:add_trigger(id, name)
  add(self, {t = 'trigger', id = id, name = name, value = 0, action = function() end})
end
function Fake:add_text(id, name, txt)
  add(self, {t = 'text', id = id, name = name, value = txt or '', action = function() end})
end

function Fake:set_action(id, fn) self.lookup[id].action = fn end
function Fake:lookup_param(id) return self.lookup[id] end
function Fake:get(id) return self.lookup[id].value end

function Fake:string(id)
  local p = self.lookup[id]
  if p.t == 'option' then return p.options[p.value] end
  if p.formatter then return p.formatter(p) end
  return tostring(p.value)
end

function Fake:set(id, v, silent)
  local p = assert(self.lookup[id], 'paramset: no param ' .. tostring(id))
  if p.t == 'number' then v = math.max(p.min, math.min(p.max, v)) end
  p.value = v
  if not silent then
    self.fires = self.fires + 1
    p.action(v)
  end
end

function Fake:bang()
  for _, p in ipairs(self.list) do
    if p.action and p.t ~= 'trigger' and p.t ~= 'separator' and p.t ~= 'group' then
      p.action(p.value)
    end
  end
end

return Fake
