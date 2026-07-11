--[[
  Timelapse Recorder  -  Aseprite extension  (v1.8)
  --------------------------------------------------------------------------
  Records a CSP/Procreate-style timelapse: snapshots the *canvas state* as you
  draw, then builds an upscaled GIF with Aseprite's OWN engine (no ffmpeg, no
  console windows). ffmpeg/MP4 is opt-in (Settings > "Use ffmpeg").

  SPEED: use "Fixed FPS" mode - a longer drawing makes a longer timelapse.
  Lower the FPS to make it slower/calmer (higher FPS = faster).

  RE-EXPORT: the last finished recording's frames are kept, so if you don't
  like the result you can change FPS/upscale in Settings and run
  "Re-export Last Timelapse" - no need to redraw.

  Every dialog title shows the version so you can confirm the build is loaded.
]]

local VERSION = "1.8"

-- ---------------------------------------------------------------------------
-- state
-- ---------------------------------------------------------------------------
local prefs
local recording  = false
local busy       = false
local siteCode   = nil
local sessions   = {}
local ffmpegMemo = nil
local MIN_FRAMES = 2
local FRAME_CAP  = 180        -- max frames fed to the native GIF builder
local TITLE      = "Timelapse Recorder v" .. VERSION

local startRecording, stopRecording, finalizeAll, arm
local hookSprite, onSiteChange, onSpriteChange, captureSprite
local buildGifNative, ffmpegGif, ffmpegMp4, purgeFrames, effectiveFps
local compileDir, buildFromCache, reExportLast, clearCache, showSettings, reportResults

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------
local function jp(...) return app.fs.joinPath(...) end
local function stamp() return os.date("%Y%m%d-%H%M%S") end

local function sanitize(s)
  s = s or "untitled"
  return (s:gsub("[^%w%-_]", "_"))
end

local function spriteTitle(spr)
  if spr.filename and #spr.filename > 0 then
    local t = app.fs.fileTitle(spr.filename)
    if t and #t > 0 then return t end
  end
  return "untitled"
end

local function outputDir()
  if prefs.outputDir and #prefs.outputDir > 0 then return prefs.outputDir end
  return jp(app.fs.userDocsPath, "Aseprite Timelapses")
end

local function cacheRoot() return jp(outputDir(), ".cache") end

local function listPng(dir)
  local out = {}
  for _, f in ipairs(app.fs.listFiles(dir)) do
    if f:lower():match("%.png$") then out[#out + 1] = f end
  end
  table.sort(out)
  return out
end

local function alert(lines) app.alert{ title = TITLE, text = lines } end
local function isWindows() return app.fs.pathSeparator == "\\" end

local function activeDir(d)
  for _, s in pairs(sessions) do
    if s.sprite and s.sprite.isValid and s.dir == d then return true end
  end
  return false
end

local function runCmd(cmd)   -- only reached when the user opted into ffmpeg
  local full = cmd .. (isWindows() and " >nul 2>&1" or " >/dev/null 2>&1")
  local ok, res = pcall(function() return os.execute(full) end)
  if not ok then return false, "os.execute blocked" end
  if res == true or res == 0 then return true end
  return false, "failed"
end

local function ffmpegAvailable()
  if ffmpegMemo == nil then
    ffmpegMemo = runCmd((prefs.ffmpegPath or "ffmpeg") .. " -version")
  end
  return ffmpegMemo
end

local function openPath(path)
  pcall(function() app.fs.makeAllDirectories(path) end)
  pcall(function()
    if isWindows() then
      os.execute('start "" "' .. path .. '"')
    else
      os.execute('(open "' .. path .. '" || xdg-open "' .. path .. '") >/dev/null 2>&1 &')
    end
  end)
end

local function rememberDir(dir, base)
  prefs.pendingDirs = prefs.pendingDirs or {}
  prefs.pendingDirs[dir] = base
end
local function forgetDir(dir)
  if prefs.pendingDirs then prefs.pendingDirs[dir] = nil end
end

-- ---------------------------------------------------------------------------
-- capture
-- ---------------------------------------------------------------------------
captureSprite = function(spr, force)
  local s = sessions[spr.id]
  if not s then return end

  local now = os.time()
  if (not force) and s.lastTime >= 0 and (now - s.lastTime) < (prefs.minInterval or 1) then
    return
  end

  local ok, img = pcall(function()
    local fn = 1
    if app.sprite == spr and app.frame then fn = app.frame.frameNumber end
    local im = Image(spr.width, spr.height, ColorMode.RGB)
    im:drawSprite(spr, fn)
    return im
  end)
  if not ok or not img then return end

  if s.lastImg and img:isEqual(s.lastImg) then
    s.lastTime = now
    return
  end

  s.count = s.count + 1
  local saved = pcall(function() img:saveAs(jp(s.dir, string.format("frame_%05d.png", s.count))) end)
  if not saved then
    alert({ "Couldn't write snapshot files.",
            "Recording paused - grant file access, then toggle Record off/on." })
    stopRecording()
    return
  end

  s.lastImg  = img
  s.lastTime = now
end

onSpriteChange = function(spr, ev)
  if busy or not recording then return end
  if prefs.skipUndo and ev and ev.fromUndo then return end
  captureSprite(spr, false)
end

hookSprite = function(spr)
  if not spr or sessions[spr.id] then return end
  local base = sanitize(spriteTitle(spr)) .. "-" .. stamp()
  local dir  = jp(cacheRoot(), base)
  app.fs.makeAllDirectories(dir)
  rememberDir(dir, base)
  local s = { sprite = spr, dir = dir, base = base,
              count = 0, lastTime = -1, lastImg = nil, code = nil }
  sessions[spr.id] = s
  s.code = spr.events:on("change", function(ev) onSpriteChange(spr, ev) end)
  captureSprite(spr, true)
end

onSiteChange = function()
  if busy or not recording then return end
  for id, s in pairs(sessions) do
    if not (s.sprite and s.sprite.isValid) then
      busy = true
      pcall(function() compileDir(s.dir, s.base, false) end)
      busy = false
      sessions[id] = nil
    end
  end
  local spr = app.sprite
  if spr and not sessions[spr.id] then
    pcall(function() hookSprite(spr) end)
  end
end

-- ---------------------------------------------------------------------------
-- compile
-- ---------------------------------------------------------------------------
effectiveFps = function(numFrames)
  if prefs.lengthMode == "seconds" and prefs.targetSeconds and prefs.targetSeconds > 0 then
    return math.max(1, math.floor(numFrames / prefs.targetSeconds + 0.5))
  end
  return math.max(1, math.floor(prefs.fps or 12))
end

ffmpegGif = function(dir, outPath, fps, scale, hold)
  local vf = string.format("scale=iw*%d:ih*%d:flags=neighbor", scale, scale)
  if hold > 0 then vf = vf .. string.format(",tpad=stop_mode=clone:stop_duration=%s", tostring(hold)) end
  vf = vf .. ",split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=none"
  return runCmd(string.format('%s -y -framerate %d -i "%s" -vf "%s" "%s"',
    prefs.ffmpegPath or "ffmpeg", fps, jp(dir, "frame_%05d.png"), vf, outPath))
end

ffmpegMp4 = function(dir, outPath, fps, scale, hold)
  local vf = string.format("scale=iw*%d:ih*%d:flags=neighbor,pad=ceil(iw/2)*2:ceil(ih/2)*2", scale, scale)
  if hold > 0 then vf = vf .. string.format(",tpad=stop_mode=clone:stop_duration=%s", tostring(hold)) end
  return runCmd(string.format(
    '%s -y -framerate %d -i "%s" -vf "%s" -c:v libx264 -pix_fmt yuv420p -crf 18 "%s"',
    prefs.ffmpegPath or "ffmpeg", fps, jp(dir, "frame_%05d.png"), vf, outPath))
end

buildGifNative = function(dir, files, gifPath, fps)
  local sel = files
  if #files > FRAME_CAP then
    sel = {}
    local step = #files / FRAME_CAP
    for k = 0, FRAME_CAP - 1 do
      local i = math.floor(k * step) + 1
      if i > #files then i = #files end
      sel[#sel + 1] = files[i]
    end
    sel[#sel] = files[#files]
  end

  local scale = math.max(1, math.floor(prefs.scale or 1))
  local dur   = 1.0 / fps
  local hold  = tonumber(prefs.holdSeconds) or 0

  local first
  for _, f in ipairs(sel) do
    local ok, im = pcall(function() return Image{ fromFile = jp(dir, f) } end)
    if ok and im then first = im break end
  end
  if not first then error("no readable frames") end

  local W, H  = first.width * scale, first.height * scale
  local spr   = Sprite(W, H, ColorMode.RGB)
  local layer = spr.layers[1]
  if spr.cels[1] then pcall(function() spr:deleteCel(spr.cels[1]) end) end

  local fi = 0
  for _, f in ipairs(sel) do
    local ok, img = pcall(function() return Image{ fromFile = jp(dir, f) } end)
    if ok and img then
      if scale > 1 then pcall(function() img:resize(W, H) end) end
      fi = fi + 1
      if fi > 1 then spr:newEmptyFrame(fi) end
      spr:newCel(layer, fi, img, Point(0, 0))
      spr.frames[fi].duration = dur
    end
  end
  if fi == 0 then spr:close() error("no frames added") end
  if hold > 0 then spr.frames[#spr.frames].duration = dur + hold end

  spr:saveAs(gifPath)
  spr:close()
end

purgeFrames = function(dir, files)
  for _, f in ipairs(files or {}) do pcall(function() os.remove(jp(dir, f)) end) end
  pcall(function() app.fs.removeDirectory(dir) end)
end

-- keepFrames=true -> preview (don't delete, don't change re-export target)
compileDir = function(dir, base, keepFrames)
  local files = listPng(dir)
  if #files < MIN_FRAMES then
    if not keepFrames then purgeFrames(dir, files); forgetDir(dir) end
    return false, nil, nil
  end

  app.fs.makeAllDirectories(outputDir())
  local fps   = effectiveFps(#files)
  local scale = math.max(1, math.floor(prefs.scale or 1))
  local hold  = tonumber(prefs.holdSeconds) or 0
  local hasFf = (prefs.useFfmpeg == true) and ffmpegAvailable()
  local outs, notes = {}, {}

  if prefs.makeGif then
    local ok, err
    if hasFf then ok, err = ffmpegGif(dir, jp(outputDir(), base .. ".gif"), fps, scale, hold)
    else          ok, err = pcall(function() buildGifNative(dir, files, jp(outputDir(), base .. ".gif"), fps) end) end
    if ok then outs[#outs + 1] = base .. ".gif"
    else notes[#notes + 1] = "GIF failed: " .. tostring(err) end
  end

  if prefs.makeMp4 then
    if hasFf then
      local ok, err = ffmpegMp4(dir, jp(outputDir(), base .. ".mp4"), fps, scale, hold)
      if ok then outs[#outs + 1] = base .. ".mp4"
      else notes[#notes + 1] = "MP4 failed: " .. tostring(err) end
    else
      notes[#notes + 1] = "MP4 needs ffmpeg (enable 'Use ffmpeg' in Settings)"
    end
  end

  local success = #outs > 0
  if success and not keepFrames then
    -- final compile: keep THIS session's frames for re-export; purge the
    -- previously-kept one so the cache never piles up.
    if prefs.purgeFrames then
      local prev = prefs.lastDir
      if prev and prev ~= dir and not activeDir(prev) then
        purgeFrames(prev, listPng(prev))
      end
    end
    forgetDir(dir)
    prefs.lastDir  = dir
    prefs.lastBase = base
  end

  local summary = success and
    (table.concat(outs, " + ") .. "   (" .. #files .. " frames @ " .. fps .. " fps)") or nil
  local note = (#notes > 0) and table.concat(notes, " | ") or nil
  return success, summary, note
end

buildFromCache = function()
  busy = true
  local results, notes = {}, {}
  local active = {}
  for _, s in pairs(sessions) do
    if s.sprite and s.sprite.isValid then
      active[s.dir] = true
      local ok, summary, note
      pcall(function() ok, summary, note = compileDir(s.dir, s.base, true) end)
      if summary then results[#results + 1] = summary end
      if note then notes[#notes + 1] = note end
    end
  end
  if #results == 0 then
    local root = cacheRoot()
    if app.fs.isDirectory(root) then
      local dirs = {}
      for _, name in ipairs(app.fs.listFiles(root)) do
        local d = jp(root, name)
        if app.fs.isDirectory(d) and not active[d] then dirs[#dirs + 1] = name end
      end
      table.sort(dirs)
      local newest = dirs[#dirs]
      if newest then
        local ok, summary, note
        pcall(function() ok, summary, note = compileDir(jp(root, newest), sanitize(newest), false) end)
        if summary then results[#results + 1] = summary end
        if note then notes[#notes + 1] = note end
      end
    end
  end
  busy = false
  reportResults(results, notes, "Nothing to build yet - draw something first (recording is on by default).")
end

-- Rebuild the last finished timelapse using the CURRENT settings (fps/upscale/hold).
reExportLast = function()
  local dir, base = prefs.lastDir, prefs.lastBase
  if not (dir and base and app.fs.isDirectory(dir) and #listPng(dir) >= MIN_FRAMES) then
    alert({ "Nothing to re-export yet.",
            "Finish a recording first - its frames are kept so you can re-export",
            "at a different speed/size (change FPS or Upscale in Settings, then run this)." })
    return
  end
  busy = true
  local ok, summary, note
  pcall(function() ok, summary, note = compileDir(dir, base, true) end)  -- keep frames for more re-exports
  busy = false
  reportResults(summary and { summary } or {}, note and { note } or {}, "Re-export failed.")
end

clearCache = function()
  local root = cacheRoot()
  if not app.fs.isDirectory(root) then alert({ "The frame cache is already empty." }) return end
  local r = app.alert{ title = TITLE,
    text = { "Delete all cached raw frames?",
             "Your finished GIFs/MP4s are NOT affected, but you won't be able to",
             "re-export until you record again." },
    buttons = { "Delete", "Cancel" } }
  if r ~= 1 then return end
  local active = {}
  for _, s in pairs(sessions) do
    if s.sprite and s.sprite.isValid then active[s.dir] = true end
  end
  local removed = 0
  for _, name in ipairs(app.fs.listFiles(root)) do
    local d = jp(root, name)
    if app.fs.isDirectory(d) and not active[d] then
      purgeFrames(d, listPng(d))
      forgetDir(d)
      removed = removed + 1
    end
  end
  prefs.lastDir  = nil
  prefs.lastBase = nil
  alert({ "Cleared " .. removed .. " cached session folder(s)." })
end

reportResults = function(results, notes, emptyMsg)
  local lines = {}
  if #results > 0 then
    lines[#lines + 1] = "Saved to:"
    lines[#lines + 1] = outputDir()
    lines[#lines + 1] = ""
    for _, r in ipairs(results) do lines[#lines + 1] = r end
  else
    lines[#lines + 1] = emptyMsg
  end
  if #notes > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = (#results > 0) and "Notes:" or "Problems (frames kept):"
    for _, n in ipairs(notes) do lines[#lines + 1] = n end
  end
  alert(lines)
end

-- ---------------------------------------------------------------------------
-- start / stop
-- ---------------------------------------------------------------------------
arm = function()
  if not siteCode then siteCode = app.events:on("sitechange", onSiteChange) end
  if app.sprite then pcall(function() hookSprite(app.sprite) end) end
end

finalizeAll = function()
  busy = true
  local results, notes = {}, {}
  for id, s in pairs(sessions) do
    if s.sprite and s.sprite.isValid and s.code then
      pcall(function() s.sprite.events:off(s.code) end)
    end
    local ok, summary, note
    pcall(function() ok, summary, note = compileDir(s.dir, s.base, false) end)
    if summary then results[#results + 1] = summary end
    if note then notes[#notes + 1] = note end
    sessions[id] = nil
  end
  busy = false
  return results, notes
end

startRecording = function()
  if recording then return end
  recording = true
  prefs.recording = true
  arm()
  alert({ "Recording is ON.",
          "Draw normally - snapshots are automatic.",
          "Toggle OFF (or Build Timelapse From Cache) to make the video." })
end

stopRecording = function()
  recording = false
  prefs.recording = false
  if siteCode then pcall(function() app.events:off(siteCode) end); siteCode = nil end
  local results, notes = finalizeAll()
  reportResults(results, notes, "No timelapse was produced (no frames captured).")
end

-- ---------------------------------------------------------------------------
-- settings
-- ---------------------------------------------------------------------------
showSettings = function()
  local d = Dialog("Timelapse Settings  (v" .. VERSION .. ")")
  d:number{ id = "minInterval", label = "Min seconds between snaps", text = tostring(prefs.minInterval), decimals = 0 }
  d:number{ id = "scale",       label = "Upscale factor (x)",        text = tostring(prefs.scale),       decimals = 0 }
  d:separator{ text = "Speed  (lower FPS = slower)" }
  d:combobox{ id = "lengthMode", label = "Mode",
              option = (prefs.lengthMode == "seconds") and "Target length" or "Fixed FPS",
              options = { "Fixed FPS", "Target length" } }
  d:number{ id = "fps",           label = "Fixed FPS",              text = tostring(prefs.fps),           decimals = 0 }
  d:number{ id = "targetSeconds", label = "Target length (sec)",    text = tostring(prefs.targetSeconds), decimals = 0 }
  d:number{ id = "holdSeconds",   label = "Hold final frame (sec)", text = tostring(prefs.holdSeconds),   decimals = 1 }
  d:separator{ text = "Output  (GIF uses Aseprite - no console windows)" }
  d:check{ id = "makeGif",   label = "GIF",    text = "Build a GIF",                     selected = prefs.makeGif }
  d:check{ id = "useFfmpeg", label = "ffmpeg", text = "Use ffmpeg (may flash consoles)", selected = prefs.useFfmpeg }
  d:check{ id = "makeMp4",   label = "MP4",    text = "Build an MP4 (requires ffmpeg)",  selected = prefs.makeMp4 }
  d:check{ id = "skipUndo",  label = "Capture", text = "Skip undo / redo",               selected = prefs.skipUndo }
  d:check{ id = "purgeFrames", label = "Cache", text = "Auto-delete old frames (keep last for re-export)", selected = prefs.purgeFrames }
  d:separator()
  d:entry{ id = "ffmpegPath", label = "ffmpeg path", text = prefs.ffmpegPath }
  d:entry{ id = "outputDir",  label = "Output folder (blank = Documents)", text = prefs.outputDir }
  d:separator()
  d:button{ id = "ok", text = "Save", focus = true }
  d:button{ id = "cancel", text = "Cancel" }
  d:show()

  local data = d.data
  if data.ok then
    prefs.minInterval   = math.max(0, math.floor(data.minInterval or prefs.minInterval))
    prefs.scale         = math.max(1, math.floor(data.scale or prefs.scale))
    prefs.lengthMode    = (data.lengthMode == "Target length") and "seconds" or "fps"
    prefs.fps           = math.max(1, math.floor(data.fps or prefs.fps))
    prefs.targetSeconds = math.max(1, math.floor(data.targetSeconds or prefs.targetSeconds))
    prefs.holdSeconds   = math.max(0, tonumber(data.holdSeconds) or prefs.holdSeconds)
    prefs.makeGif       = data.makeGif
    prefs.useFfmpeg     = data.useFfmpeg
    prefs.makeMp4       = data.makeMp4
    prefs.skipUndo      = data.skipUndo
    prefs.purgeFrames   = data.purgeFrames
    prefs.ffmpegPath    = data.ffmpegPath
    prefs.outputDir     = data.outputDir
    ffmpegMemo          = nil
  end
end

-- ---------------------------------------------------------------------------
-- plugin lifecycle
-- ---------------------------------------------------------------------------
function init(plugin)
  prefs = plugin.preferences
  if prefs.minInterval   == nil then prefs.minInterval   = 1 end
  if prefs.scale         == nil then prefs.scale         = 8 end
  if prefs.lengthMode    == nil then prefs.lengthMode    = "fps" end
  if prefs.fps           == nil then prefs.fps           = 12 end
  if prefs.targetSeconds == nil then prefs.targetSeconds = 20 end
  if prefs.holdSeconds   == nil then prefs.holdSeconds   = 1.0 end
  if prefs.skipUndo      == nil then prefs.skipUndo      = true end
  if prefs.purgeFrames   == nil then prefs.purgeFrames   = true end
  if prefs.makeGif       == nil then prefs.makeGif       = true end
  if prefs.useFfmpeg     == nil then prefs.useFfmpeg     = false end
  if prefs.makeMp4       == nil then prefs.makeMp4       = false end
  if prefs.outputDir     == nil then prefs.outputDir     = "" end
  if prefs.ffmpegPath    == nil then prefs.ffmpegPath    = "ffmpeg" end
  if prefs.pendingDirs   == nil then prefs.pendingDirs   = {} end
  if prefs.recording     == nil then prefs.recording     = true end

  for dir, _ in pairs(prefs.pendingDirs) do
    if not app.fs.isDirectory(dir) then prefs.pendingDirs[dir] = nil end
  end

  plugin:newMenuGroup{ id = "timelapse_group", title = "Timelapse", group = "file_scripts" }

  plugin:newCommand{
    id        = "ToggleTimelapseRecording",
    title     = "Record Timelapse",
    group     = "timelapse_group",
    onenabled = function() return recording or app.sprite ~= nil end,
    onchecked = function() return recording end,
    onclick   = function() if recording then stopRecording() else startRecording() end end,
  }
  plugin:newCommand{
    id      = "BuildTimelapseFromCache",
    title   = "Build Timelapse From Cache",
    group   = "timelapse_group",
    onclick = function() pcall(buildFromCache) end,
  }
  plugin:newCommand{
    id      = "ReExportLastTimelapse",
    title   = "Re-export Last Timelapse",
    group   = "timelapse_group",
    onclick = function() pcall(reExportLast) end,
  }
  plugin:newCommand{
    id      = "OpenTimelapseFolder",
    title   = "Open Timelapse Folder",
    group   = "timelapse_group",
    onclick = function() pcall(function() openPath(outputDir()) end) end,
  }
  plugin:newCommand{
    id      = "ClearTimelapseCache",
    title   = "Clear Frame Cache",
    group   = "timelapse_group",
    onclick = function() pcall(clearCache) end,
  }
  plugin:newCommand{
    id      = "TimelapseSettings",
    title   = "Timelapse Settings (v" .. VERSION .. ")...",
    group   = "timelapse_group",
    onclick = function() pcall(showSettings) end,
  }

  if prefs.recording == true then
    recording = true
    arm()
  end
end

function exit(plugin)
  if siteCode then pcall(function() app.events:off(siteCode) end); siteCode = nil end
  if next(sessions) ~= nil then pcall(finalizeAll) end
end
