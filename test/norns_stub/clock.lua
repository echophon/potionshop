-- Virtual cooperative clock for LOCAL TESTING ONLY. Mirrors the bits of the
-- norns `clock` API the burst engine uses: clock.run starts a coroutine and
-- runs it to its first clock.sleep; clock.sleep yields the beats-to-wait;
-- _run_until(beat) resumes due coroutines in time order, setting get_beats() to
-- each wake instant so fire events report the exact (snapped) beat they fired on.
local clock = {}

local M = { beat = 0, tempo = 120, threads = {}, next_id = 0 }
clock._M = M

function clock.get_beats() return M.beat end
function clock.get_tempo() return M.tempo end

function clock.sleep(sec)
  local beats = sec * (M.tempo / 60)
  coroutine.yield(beats)
end

function clock.sync(beat)
  -- snap to next multiple of `beat`; advance there.
  local cur = M.beat
  local nxt = math.ceil((cur + 1e-9) / beat) * beat
  coroutine.yield(nxt - cur)
end

function clock.run(fn, ...)
  M.next_id = M.next_id + 1
  local id = M.next_id
  local co = coroutine.create(fn)
  M.threads[id] = { co = co, wake = M.beat }
  local ok, yielded = coroutine.resume(co, ...)
  if not ok then error(yielded) end
  if coroutine.status(co) == 'dead' then
    M.threads[id] = nil
  else
    M.threads[id].wake = M.beat + (yielded or 0)
  end
  return id
end

function clock.cancel(id) M.threads[id] = nil end

-- Test driver: resume coroutines in wake order until the earliest wake exceeds
-- `limit` (in beats). Guarded against runaway loops.
function clock._run_until(limit)
  local guard = 0
  while true do
    guard = guard + 1
    if guard > 100000 then error('clock._run_until: runaway') end
    local mid, mwake = nil, math.huge
    for id, t in pairs(M.threads) do
      if t.wake < mwake then mwake = t.wake; mid = id end
    end
    if not mid or mwake > limit then M.beat = limit; return end
    M.beat = mwake
    local t = M.threads[mid]
    local ok, yielded = coroutine.resume(t.co)
    if not ok then error(yielded) end
    if coroutine.status(t.co) == 'dead' then
      M.threads[mid] = nil
    else
      t.wake = M.beat + (yielded or 0)
    end
  end
end

function clock._reset() M.beat = 0; M.threads = {}; M.next_id = 0 end

return clock
