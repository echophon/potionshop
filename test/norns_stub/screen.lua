-- Minimal stub of the norns `screen` drawing API for LOCAL TESTING ONLY.
-- Records every call (name + args) so tests can assert what was drawn; all
-- operations are otherwise no-ops.
local screen = { calls = {} }

local function rec(name)
  return function(...) screen.calls[#screen.calls + 1] = { name, ... } end
end

for _, f in ipairs({
  'clear', 'update', 'fill', 'stroke', 'move', 'line', 'rect', 'level',
  'font_face', 'font_size', 'text', 'text_right', 'text_center', 'line_width',
}) do
  screen[f] = rec(f)
end

-- crude fixed-width metric; only relative layout math depends on it
function screen.text_extents(s) return #tostring(s) * 4 end

function screen._reset() screen.calls = {} end

return screen
