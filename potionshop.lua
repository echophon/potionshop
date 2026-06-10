-- potionshop
-- Six-channel FM burst sequencer for monome norns + grid.
-- A native port of the browser app (https://github.com/.../potionshop), itself
-- a descendant of the er301_geode Lua patch. FM voice first; JF/Mangrove voices
-- route to FM for now (see lib/Engine_Potionshop.sc).
--
-- The grid is the primary interface (read lib/grid_ui.lua's layout comment).
-- The screen + encoders/keys are a complete secondary surface (lib/screen_ui).
--
-- E1 channel · E2 param (K1+E2 step) · E3 value · K2 launch/stop · K3 page · K1+K3 scale

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
for _, m in ipairs({'burst', 'grid_ui', 'screen_ui', 'scales', 'seqx', 'quantize'}) do
  package.loaded[m] = nil
end

local Burst    = require 'burst'
local GridUI   = require 'grid_ui'
local ScreenUI = require 'screen_ui'
local scales   = require 'scales'

local eng        -- Burst engine
local controller -- GridUI
local ui_screen  -- ScreenUI
local g          -- norns grid
local gw         -- grid wrapper (0-based -> 1-based, strobe overlay)
local strobe_metro
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

-- ---- params ------------------------------------------------------------

local function add_params()
  params:add_separator('potionshop', 'POTIONSHOP')

  params:add_option('scale', 'scale', scales.names, 2)  -- default 'major'
  params:set_action('scale', function(i)
    local name = scales.names[i]
    eng.scale = scales.by_name[name]
    if controller then
      controller.selectedScaleName = name
      controller.customMask = {}
      for _, v in ipairs(scales.by_name[name]) do
        controller.customMask[#controller.customMask + 1] = v
      end
      controller:refresh()
    end
  end)

  params:add_number('quantize', 'quantize (per whole note)', 1, 32, 32)
  params:set_action('quantize', function(v) eng.quantize = v end)

  params:add_number('mod_index', 'FM mod index', 1, 24, 8)
  params:set_action('mod_index', function(v) eng.modIndex = v end)
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
    on_redraw = function() redraw() end,
  })
  ui_screen = ScreenUI.new(eng, controller)

  add_params()
  params:bang()

  -- strobe blink driver (~15 Hz): slow ≈ 0.6 Hz, fast ≈ 1.4 Hz
  strobe_metro = metro.init()
  strobe_metro.time = 1 / 15
  strobe_metro.event = function(c)
    gw.slow_on = (math.floor(c / 8) % 2) == 0
    gw.fast_on = (math.floor(c / 3) % 2) == 0
    gw:refresh()
  end
  strobe_metro:start()

  -- per-bar reset scheduler: each channel resets on its own interval
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
          if bars[i] % iv == 0 then eng:reset_channel(i); did = true end
        end
      end
      if did then controller:refresh() end
    end
  end)

  -- sensible starting tempo (web default was 55 bpm)
  if params:lookup_param('clock_tempo') then params:set('clock_tempo', 55) end

  redraw()
end

function key(n, z) if ui_screen then ui_screen:key(n, z) end; redraw() end
function enc(n, d) if ui_screen then ui_screen:enc(n, d) end; redraw() end
function redraw() if ui_screen then ui_screen:redraw() end end

function cleanup()
  if eng then eng:stop_all() end
  if engine and engine.panic then engine.panic() end
  if strobe_metro then strobe_metro:stop() end
  if reset_clock then clock.cancel(reset_clock) end
end
