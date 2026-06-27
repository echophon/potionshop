--         _/ .    _  /     
--     /)()//()/)_) /)()/) 
--   /                /   
--                          
--
--
--
-- sequins burst sequencer 
-- E1 channel E2 cursor E3 value 
-- K2/K3 page back/fwd

engine.name = 'Potionshop'

-- Make this script's lib/ requireable so the lib modules can require each other
-- (norns puts the stock libs on package.path, but not a script's own folder).
-- Using require (not include) also means require's cache yields a single shared
-- instance of each module across all files.
local _dir = norns.state.path
if _dir:sub(-1) ~= '/' then _dir = _dir .. '/' end
package.path = _dir .. 'lib/?.lua;' .. package.path

-- require() caches in package.loaded, and a norns script RELOAD does not clear
-- it (only a full matron restart does). Drop our own modules from the cache so
-- editing a lib/ file and reloading the script actually picks up the change.
for _, m in ipairs({'burst', 'grid_ui', 'screen_ui', 'scales', 'seqx', 'quantize', 'params_sync', 'outputs'}) do
  package.loaded[m] = nil
end

local Burst      = require 'burst'
local GridUI     = require 'grid_ui'
local ScreenUI   = require 'screen_ui'
local ParamsSync = require 'params_sync'
local Outputs    = require 'outputs'
local scales     = require 'scales'

local eng        -- Burst engine
local controller -- GridUI
local ui_screen  -- ScreenUI
local psync      -- ParamsSync (params <-> engine/UI bidirectional sync)
local outs       -- Outputs (per-channel midi / crow / i2c routing, params-only)
local g          -- norns grid
local gw         -- grid wrapper (0-based -> 1-based, strobe overlay)
local strobe_metro
local screen_metro
local reset_clock

-- ---- grid wrapper ------------------------------------------------------
-- Keeps grid_ui 0-based and overlays the LED strobe (hardware grids can't
-- self-animate). A metro flips slow/fast blink phases and re-pushes the buffer.

local function make_grid_wrapper(dev)
  local w = {
    dev = dev,
    buf = {},        -- key (y*16+x, 0-based) -> brightness
    strobe = {},     -- key -> 'slow' | 'fast'
    slow_on = true,
    fast_on = true,
  }
  function w:set_led(x, y, b) self.buf[y * 16 + x] = b end
  function w:set_strobe(x, y, s)
    self.strobe[y * 16 + x] = (s ~= 'off') and s or nil
  end
  function w:clear() self.buf = {}; self.strobe = {} end
  function w:refresh()
    if not self.dev then return end
    self.dev:all(0)
    for k, b in pairs(self.buf) do
      local lvl = b
      local sp = self.strobe[k]
      if sp then
        local on = (sp == 'fast') and self.fast_on or self.slow_on
        if not on then lvl = math.floor(b * 0.2) end
      end
      local x = k % 16
      local y = math.floor(k / 16)
      self.dev:led(x + 1, y + 1, lvl)
    end
    self.dev:refresh()
  end
  return w
end

-- ---- lifecycle ---------------------------------------------------------

function init()
  eng = Burst.new()
  eng:setup()

  -- seed musical defaults (mirrors the web app's boot: randomize + B offsets)
  for i = 1, Burst.NUM_CHANNELS do eng:randomize(i) end
  local seqx = require 'seqx'
  for i = 1, Burst.NUM_CHANNELS do
    eng.channels[i].noteB = seqx.new{ (i - 1) * 3 }
  end

  -- grid
  g = grid.connect()
  gw = make_grid_wrapper(g)
  g.key = function(x, y, z)
    if z == 1 and controller then controller:press(x - 1, y - 1) end
  end

  controller = GridUI.new(eng, gw, {
    -- mark the screen dirty; the screen metro's tick repaints at ~30 Hz
    on_redraw = function() if ui_screen then ui_screen.dirty = true end end,
  })
  ui_screen = ScreenUI.new(eng, controller)

  -- params layer (lib/params_sync.lua): the entire instrument as norns params,
  -- kept bidirectionally in sync with the grid/screen. Defaults are captured
  -- from the engine state seeded above, so the bang re-applies the boot
  -- randomization rather than clobbering it; triggers arm only after the bang.
  psync = ParamsSync.new{engine = eng, controller = controller, params = params, scales = scales}

  -- output routing (lib/outputs.lua): per-channel midi / crow / i2c
  -- destinations, params-only (OUTPUTS group, placed between the globals
  -- and the channel groups). Burst:fire consults it.
  outs = Outputs.new{params = params, midi = midi, crow = crow,
                     num_channels = Burst.NUM_CHANNELS}
  eng.outputs = outs

  psync:add_globals()
  outs:add_params()
  psync:add_channels()
  -- MIDI clock out follows the script's OWN transport (norns is the master with
  -- its internal clock): the first channel to start sends MIDI Start + begins the
  -- 24 ppqn stream, the last to stop sends MIDI Stop. Guarded on the 0<->1 running
  -- transition so a live relaunch never re-sends Start (which would snap external
  -- sequencers back to bar 1). outs gates the whole thing on `midi clock out`.
  eng:on(function(ev)
    if ev.type == 'stop' then outs:notes_off(ev.ch) end
    if ev.type == 'launch' or ev.type == 'stop' then
      local any = false
      for i = 1, Burst.NUM_CHANNELS do if eng:is_running(i) then any = true; break end end
      outs:set_transport(any)  -- edge-guarded Start/Stop + 24 ppqn stream
    end
  end)

  psync:attach()
  params:bang()
  psync:enable_triggers()

  -- strobe blink driver (~15 Hz): slow ≈ 0.6 Hz, fast ≈ 1.4 Hz
  strobe_metro = metro.init()
  strobe_metro.time = 1 / 15
  strobe_metro.event = function(c)
    gw.slow_on = (math.floor(c / 8) % 2) == 0
    gw.fast_on = (math.floor(c / 3) % 2) == 0
    gw:refresh()
    if psync then psync:flush() end  -- coalesced repaint for param-menu edits
  end
  strobe_metro:start()

  -- screen redraw driver, decoupled from the 15 Hz grid strobe: the sparkline
  -- scrolls ~11 px/s, so 15 fps lands ~1.3 frames per pixel and stutters; 30 fps
  -- evens the cadence out. tick() self-guards (system menu) and only repaints
  -- when dirty, so the higher rate costs nothing while the screen is idle.
  screen_metro = metro.init()
  screen_metro.time = 1 / 30
  screen_metro.event = function()
    if ui_screen then ui_screen:tick() end
  end
  screen_metro:start()

  -- per-bar reset scheduler: each channel resets on its own interval. bar_reset
  -- hard-restarts a running channel on the bar boundary (rewind sequins + re-
  -- anchor burst timing to the bar), so channels sharing a reset interval — e.g.
  -- a copy/pasted duplicate with reset = 1 bar — lock together instead of drifting.
  local bars = {}
  for i = 1, Burst.NUM_CHANNELS do bars[i] = 0 end
  reset_clock = clock.run(function()
    while true do
      clock.sync(4)  -- one bar (4 beats); aligns all channels to the bar grid
      local did = false
      for i = 1, Burst.NUM_CHANNELS do
        local iv = eng.channels[i].resetInterval
        if iv > 0 then
          bars[i] = bars[i] + 1
          if bars[i] % iv == 0 then eng:bar_reset(i); did = true end
        end
      end
      if did then
        if outs then outs:clock_reset() end  -- realign downstream gear to the bar
        controller:refresh()
      end
    end
  end)

  redraw()
end

function key(n, z) if ui_screen then ui_screen:key(n, z) end; redraw() end
function enc(n, d) if ui_screen then ui_screen:enc(n, d) end; redraw() end
function redraw() if ui_screen then ui_screen:redraw() end end

function cleanup()
  if eng then eng:stop_all() end
  if outs then outs:clock_stop(); outs:all_notes_off() end
  if engine and engine.panic then engine.panic() end
  if strobe_metro then strobe_metro:stop() end
  if screen_metro then screen_metro:stop() end
  if reset_clock then clock.cancel(reset_clock) end
end
