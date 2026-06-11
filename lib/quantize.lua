-- quantize.lua
-- Pure beat/division-snapping math, ported from the web app's src/quantize.ts.
--
-- `q` follows the Norns convention: a value of N means "N events per whole
-- note" (so 4 = quarter notes, 16 = sixteenths). Step size in beats is 4/N.
-- q <= 0 disables snapping.
--
-- This snaps an event's target beat FORWARD to the next grid point, so every
-- channel's clock coroutine (see burst.lua) locks to a shared sub-beat grid
-- regardless of its own division. The math is identical to the browser app and
-- unit-testable without any Norns runtime.

local quantize = {}

-- Snap `target` forward to the next q-grid point. The 1e-9 guard keeps a value
-- that is *exactly* on a grid point from being pushed forward a whole step.
function quantize.snap_beat(target, q)
  if q <= 0 then return target end
  local step = 4 / q
  return math.ceil(target / step - 1e-9) * step
end

return quantize
