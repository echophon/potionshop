-- quantize.lua
-- Pure beat/division-snapping math, ported from the web app's src/quantize.ts.
--
-- `q` follows the Norns convention: a value of N means "N events per whole
-- note" (so 4 = quarter notes, 16 = sixteenths). Step size in beats is 4/N.
-- q <= 0 disables snapping.
--
-- In the browser app this snapped arbitrary target beats forward to the next
-- grid point. Under the Norns lattice port its main job shifts to snapping a
-- channel's chosen division onto the global quantize grid, but the math is
-- identical and unit-testable without any Norns runtime.

local quantize = {}

-- Snap `target` forward to the next q-grid point. The 1e-9 guard keeps a value
-- that is *exactly* on a grid point from being pushed forward a whole step.
function quantize.snap_beat(target, q)
  if q <= 0 then return target end
  local step = 4 / q
  return math.ceil(target / step - 1e-9) * step
end

return quantize
