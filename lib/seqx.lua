-- seqx.lua
-- Thin glue over the stock `sequins` library so the rest of the port can keep
-- the web app's mental model (0-based grid columns, a "playhead" of the
-- just-fired step) while sequins itself does the cycling.
--
-- Native sequins facts this module pins down (verified against norns source):
--   * construct with `sequins{...}`; advance by calling `seq()`.
--   * 1-based: `seq.data` is the values table indexed 1..#seq.
--   * after each `seq()` call, `seq.ix` is the 1-based index of the value JUST
--     returned — i.e. the current playhead. (new() starts ix=1, qix=1.)
--   * `seq:reset()` queues index 1 for the next call.
-- So the 0-based "just-fired" step the web controller drew as
-- `(index-1+len)%len` is simply `seq.ix - 1` here.

local sequins = require 'sequins'

local seqx = {}

seqx.new = function(vals) return sequins(vals) end

seqx.is_seq = function(v) return sequins.is_sequins(v) end

-- Wrap a scalar in a length-1 sequins; pass an existing sequins through.
function seqx.as_seq(v)
  if sequins.is_sequins(v) then return v end
  return sequins{ v }
end

-- Underlying values table (1-based). Callers that think in 0-based grid columns
-- read `values(seq)[col + 1]`.
function seqx.values(seq) return seq.data end

function seqx.len(seq) return #seq end

-- 0-based index of the most-recently-fired step (for grid playhead rendering).
function seqx.playhead(seq)
  local n = #seq
  if n == 0 then return 0 end
  return (seq.ix - 1) % n
end

return seqx
