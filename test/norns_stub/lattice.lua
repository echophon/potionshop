-- Minimal stub of norns lib/lattice for LOCAL TESTING ONLY.
-- Does not auto-drive from a clock; tests invoke sprocket.action manually.
local Sprocket = {}
Sprocket.__index = Sprocket
function Sprocket:start() self.enabled = true end
function Sprocket:stop() self.enabled = false end
function Sprocket:set_division(n) self.division = n end

local Lattice = {}
Lattice.__index = Lattice

function Lattice:new(args)
  args = args or {}
  local l = { ppqn = args.ppqn or 96, sprockets = {} }
  return setmetatable(l, Lattice)
end

function Lattice:new_sprocket(args)
  args = args or {}
  local sp = setmetatable({
    action = args.action or function() end,
    division = args.division or 1 / 4,
    enabled = (args.enabled == nil) and true or args.enabled,
    phase = (args.division or 1 / 4) * self.ppqn * 4,
  }, Sprocket)
  table.insert(self.sprockets, sp)
  return sp
end

function Lattice:start() self.started = true end
function Lattice:stop() self.started = false end

return Lattice
