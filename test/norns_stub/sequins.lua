-- Minimal faithful stub of norns lib/sequins for LOCAL TESTING ONLY.
-- Mirrors the real semantics the port relies on: ix starts at 1, qix starts at
-- 1, next() advances-then-the-just-read index lands in self.ix. Flow modifiers
-- and transformers are omitted (the port does not use them).
local S = {}
S.metaix = { reset = true, select = true, settable = true, setdata = true }

local function wrap(s, ix) return ((ix - 1) % s.length) + 1 end

function S.new(t)
  local s = { data = t, length = #t, ix = 1, qix = 1 }
  return setmetatable(s, S)
end

function S.next(s)
  local newix = wrap(s, s.qix or (s.ix + 1))
  s.ix = newix
  s.qix = nil
  return s.data[newix]
end

function S:reset() self.qix = 1 end
function S:select(ix) self.qix = ix; return self end
function S:setdata(t) self.data = t; self.length = #t; self.ix = wrap(self, self.ix) end
S.settable = S.setdata

function S.is_sequins(v) return type(v) == 'table' and getmetatable(v) == S end

S.__index = function(self, k)
  if S.metaix[k] then return S[k] end
  return rawget(self, k)
end
S.__len = function(self) return self.length end
S.__call = function(self, ...)
  return (self == S) and S.new(...) or S.next(self)
end

return setmetatable(S, S)
