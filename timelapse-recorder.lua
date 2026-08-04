--[[
  Timelapse Recorder  -  Aseprite extension  (v2.5)
  --------------------------------------------------------------------------
  Library-based timelapse recorder with a tiled thumbnail picker.

  GIF is ALWAYS built by Aseprite's own engine - no ffmpeg, no command line,
  no console windows. It's the reliable output. MP4 is optional and uses ffmpeg
  (a command-line tool); on locked-down Windows the OS may block that, so if MP4
  errors, just leave it off and use the GIF.

  * Records only SAVED sprites; a new sprite starts recording once saved.
  * Pieces show/export under their CURRENT name (rename-aware).
  * "Create Timelapse..." = scrollable grid of thumbnails; click to select.
  * Storage auto-managed (newest N pieces kept). Export settings remembered.
]]

local VERSION = "2.5"

-- ---------------------------------------------------------------------------
-- state / constants
-- ---------------------------------------------------------------------------
local prefs
local recording  = false
local busy       = false
local siteCode   = nil
local sessions   = {}
local MIN_FRAMES = 2
local FRAME_CAP  = 120
local MAX_DIM    = 384
local MEM_BUDGET = 64000000
local RECENT     = 8
local COLS       = 4
local TW, TH     = 90, 88
local TITLE      = "Timelapse Recorder v" .. VERSION

local startRecording, stopRecording, arm
local hookSprite, onSiteChange, onSpriteChange, captureSprite
local buildGifNative, ffmpegMp4, purgeFrames, effectiveFps
local compileDir, openCreatePicker, clearCache, showSettings, reportResults

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

local function isSaved(spr) return spr and spr.filename and #spr.filename > 0 end

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

local function openPath(path)
  pcall(function() app.fs.makeAllDirectories(path) end)
  pcall(function()
    if isWindows() then os.execute('start "" "' .. path .. '"')
    else os.execute('(open "' .. path .. '" || xdg-open "' .. path .. '") >/dev/null 2>&1 &') end
  end)
end

local function rememberDir(dir, title) prefs.pieces = prefs.pieces or {}; prefs.pieces[dir] = { t = title } end
local function forgetDir(dir) if prefs.pieces then prefs.pieces[dir] = nil end end

local function baseName(dir) return app.fs.fileName(dir) end
local function titleOf(folder) return folder:match("^(.-)%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d$") or folder end
local function folderStamp(folder) return folder:match("(%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d)$") end
local function fmtTs(ts)
  if not ts then return "" end
  return ts:sub(1,4) .. "-" .. ts:sub(5,6) .. "-" .. ts:sub(7,8) .. " " .. ts:sub(10,11) .. ":" .. ts:sub(12,13)
end
local function pieceTitle(dir, folder)
  local v = prefs.pieces and prefs.pieces[dir]
  if type(v) == "table" and v.t and #v.t > 0 then return v.t end
  if type(v) == "string" and #v > 0 then return titleOf(v) end
  return titleOf(folder)
end
local function tsKey(folder) return folderStamp(folder) or folder end

local function enforceLibraryCap()
  local root = cacheRoot()
  if not app.fs.isDirectory(root) then return end
  local dirs = {}
  for _, name in ipairs(app.fs.listFiles(root)) do
    local d = jp(root, name)
    if app.fs.isDirectory(d) and not activeDir(d) then dirs[#dirs + 1] = name end
  end
  table.sort(dirs, function(a, b) return tsKey(a) < tsKey(b) end)
  local excess = #dirs - (prefs.maxPieces or 40)
  for i = 1, excess do
    local d = jp(root, dirs[i])
    purgeFrames(d, listPng(d)); forgetDir(d)
  end
end

local function scanPieces()
  local map = {}
  if prefs.pieces then for dir, _ in pairs(prefs.pieces) do map[dir] = baseName(dir) end end
  local root = cacheRoot()
  if app.fs.isDirectory(root) then
    for _, name in ipairs(app.fs.listFiles(root)) do
      local dpath = jp(root, name)
      if app.fs.isDirectory(dpath) then map[dpath] = name end
    end
  end
  local pieces = {}
  for dir, folder in pairs(map) do
    if app.fs.isDirectory(dir) then
      local pngs = listPng(dir)
      if #pngs >= MIN_FRAMES then
        local title = pieceTitle(dir, folder)
        local ts    = folderStamp(folder)
        local shortT = (#title > 10 and (title:sub(1, 9) .. "~")) or title
        pieces[#pieces + 1] = {
          dir = dir, folder = folder, frames = #pngs, last = pngs[#pngs],
          title = title, ts = ts,
          disp = title .. (ts and ("   (" .. fmtTs(ts) .. ")") or ""),
          short = shortT .. "  " .. #pngs .. "f",
          outBase = sanitize(title) .. (ts and ("-" .. ts) or ""),
        }
      else
        forgetDir(dir)
      end
    else
      forgetDir(dir)
    end
  end
  table.sort(pieces, function(a, b) return tsKey(a.folder) > tsKey(b.folder) end)
  return pieces
end

-- ---------------------------------------------------------------------------
-- capture
-- ---------------------------------------------------------------------------
captureSprite = function(spr, force)
  local s = sessions[spr.id]
  if not s then return end
  if prefs.savedOnly and not isSaved(spr) then return end

  if not s.dir then
    s.base = sanitize(spriteTitle(spr)) .. "-" .. stamp()
    s.dir  = jp(cacheRoot(), s.base)
    if not pcall(function() app.fs.makeAllDirectories(s.dir) end) then s.dir = nil; return end
    rememberDir(s.dir, spriteTitle(spr))
    pcall(enforceLibraryCap)
  end

  local ct = spriteTitle(spr)
  local v = prefs.pieces[s.dir]
  if not (type(v) == "table" and v.t == ct) then prefs.pieces[s.dir] = { t = ct } end

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
  local s = { sprite = spr, dir = nil, base = nil,
              count = 0, lastTime = -1, lastImg = nil, code = nil }
  sessions[spr.id] = s
  s.code = spr.events:on("change", function(ev) onSpriteChange(spr, ev) end)
  captureSprite(spr, true)
end

onSiteChange = function()
  if busy or not recording then return end
  for id, s in pairs(sessions) do
    if not (s.sprite and s.sprite.isValid) then sessions[id] = nil end
  end
  local spr = app.sprite
  if spr and not sessions[spr.id] then pcall(function() hookSprite(spr) end) end
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

local function sample(files, n)
  if #files <= n then return files end
  local out = {}
  local step = #files / n
  for k = 0, n - 1 do
    local i = math.floor(k * step) + 1
    if i > #files then i = #files end
    out[#out + 1] = files[i]
  end
  out[#out] = files[#files]
  return out
end

-- MP4 via ffmpeg (the only place a command line is launched; MP4 is opt-in).
ffmpegMp4 = function(dir, outPath, fps, scale, hold)
  local vf = string.format("scale=iw*%d:ih*%d:flags=neighbor,pad=ceil(iw/2)*2:ceil(ih/2)*2", scale, scale)
  if hold > 0 then vf = vf .. string.format(",tpad=stop_mode=clone:stop_duration=%s", tostring(hold)) end
  local cmd = string.format(
    '%s -y -framerate %d -i "%s" -vf "%s" -c:v libx264 -pix_fmt yuv420p -crf 18 "%s"',
    prefs.ffmpegPath or "ffmpeg", fps, jp(dir, "frame_%05d.png"), vf, outPath)
  cmd = cmd .. (isWindows() and " >nul 2>&1" or " >/dev/null 2>&1")
  local ok, res = pcall(function() return os.execute(cmd) end)
  if not ok then return false, "command line unavailable on this system" end
  if res == true or res == 0 then return true end
  return false, "ffmpeg not found / failed"
end

-- GIF via Aseprite's own engine. Memory-bounded so it can't crash.
buildGifNative = function(dir, files, gifPath, fps)
  local first
  for _, f in ipairs(files) do
    local ok, im = pcall(function() return Image{ fromFile = jp(dir, f) } end)
    if ok and im then first = im break end
  end
  if not first then error("no readable frames") end

  local eff = math.max(1, math.floor(prefs.scale or 1))
  local maxSide = math.max(first.width, first.height)
  while eff > 1 and maxSide * eff > MAX_DIM do eff = eff - 1 end
  local W, H = first.width * eff, first.height * eff
  local raw = math.max(1, W * H * 4)
  local cap = math.max(24, math.min(FRAME_CAP, math.floor(MEM_BUDGET / raw)))
  local sel = sample(files, cap)

  local dur  = 1.0 / fps
  local hold = tonumber(prefs.holdSeconds) or 0
  local spr  = Sprite(W, H, ColorMode.RGB)
  local layer = spr.layers[1]
  if spr.cels[1] then pcall(function() spr:deleteCel(spr.cels[1]) end) end

  local fi = 0
  for _, f in ipairs(sel) do
    local ok, img = pcall(function() return Image{ fromFile = jp(dir, f) } end)
    if ok and img then
      if eff > 1 then pcall(function() img:resize(W, H) end) end
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

compileDir = function(dir, name, deleteAfter)
  local files = listPng(dir)
  if #files < MIN_FRAMES then return false, nil, name .. ": too few frames" end

  app.fs.makeAllDirectories(outputDir())
  local fps   = effectiveFps(#files)
  local scale = math.max(1, math.floor(prefs.scale or 1))
  local hold  = tonumber(prefs.holdSeconds) or 0
  local outs, notes = {}, {}

  -- GIF: always the native engine (reliable, no command line)
  if prefs.makeGif then
    local ok, err = pcall(function() buildGifNative(dir, files, jp(outputDir(), name .. ".gif"), fps) end)
    if ok then outs[#outs + 1] = "GIF" else notes[#notes + 1] = "GIF failed: " .. tostring(err) end
  end
  -- MP4: optional, uses ffmpeg (command line). Only when explicitly enabled.
  if prefs.makeMp4 then
    local ok, err = ffmpegMp4(dir, jp(outputDir(), name .. ".mp4"), fps, scale, hold)
    if ok then outs[#outs + 1] = "MP4" else notes[#notes + 1] = "MP4 skipped (" .. tostring(err) .. ")" end
  end

  local success = #outs > 0
  if success and deleteAfter and not activeDir(dir) then
    purgeFrames(dir, files); forgetDir(dir)
  end

  local summary = success and
    (name .. "  ->  " .. table.concat(outs, " + ") .. "  (" .. #files .. "f @ " .. fps .. " fps)") or nil
  local note = (#notes > 0) and (name .. ": " .. table.concat(notes, " | ")) or nil
  return success, summary, note
end

reportResults = function(results, notes, emptyMsg)
  local lines = {}
  if #results > 0 then
    lines[#lines + 1] = "Saved to:  " .. outputDir()
    lines[#lines + 1] = ""
    for _, r in ipairs(results) do lines[#lines + 1] = r end
  else
    lines[#lines + 1] = emptyMsg
  end
  if #notes > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Notes:"
    for _, n in ipairs(notes) do lines[#lines + 1] = n end
  end
  alert(lines)
end

-- ---------------------------------------------------------------------------
-- Create Timelapse picker
-- ---------------------------------------------------------------------------
local function canvasSupported()
  return pcall(function()
    local t = Dialog("probe")
    t:canvas{ width = 8, height = 8, onpaint = function() end }
  end)
end

local function drawTile(ev, thumb, p, isSel)
  local gc = ev.context
  pcall(function()
    local w, h = gc.width, gc.height
    local barH = 15
    gc.color = isSel and Color{ r = 40, g = 52, b = 72 } or Color{ r = 26, g = 26, b = 26 }
    gc:fillRect(Rectangle(0, 0, w, h))
    local th = h - barH
    if thumb and thumb.width > 0 and thumb.height > 0 then
      local iw, ih = thumb.width, thumb.height
      local sc = math.min((w - 6) / iw, (th - 6) / ih)
      local dw, dh = math.max(1, math.floor(iw * sc)), math.max(1, math.floor(ih * sc))
      local dx, dy = math.floor((w - dw) / 2), math.floor((th - dh) / 2)
      gc:drawImage(thumb, Rectangle(0, 0, iw, ih), Rectangle(dx, dy, dw, dh))
    end
    gc.color = Color{ r = 16, g = 16, b = 16 }
    gc:fillRect(Rectangle(0, h - barH, w, barH))
    gc.color = Color{ r = 215, g = 215, b = 215 }
    gc:fillText(p.short, 4, h - barH + 2)
    if isSel then gc.color = Color{ r = 95, g = 175, b = 255 }; gc.strokeWidth = 2
    else gc.color = Color{ r = 68, g = 68, b = 68 }; gc.strokeWidth = 1 end
    gc:strokeRect(Rectangle(0, 0, w, h))
  end)
end

openCreatePicker = function()
  local useThumbs = canvasSupported()
  local selected = {}
  local showAll = false
  local function selCount() local c = 0; for _ in pairs(selected) do c = c + 1 end; return c end

  while true do
    local pieces = scanPieces()
    if #pieces == 0 then
      alert({ "No recorded pieces yet.",
              "Draw on a SAVED sprite - recording is on by default.",
              "(A new sprite starts recording once you save it.)" })
      return
    end

    local limit = showAll and #pieces or math.min(RECENT, #pieces)
    local shown = {}
    for i = 1, limit do shown[i] = pieces[i] end

    local dlg = Dialog("Create Timelapse  (v" .. VERSION .. ")")
    dlg:separator{ text = #pieces .. " piece(s)" ..
                          ((#pieces > RECENT and not showAll) and ("  -  showing " .. limit .. " recent") or "") }

    if useThumbs then
      for i, p in ipairs(shown) do
        local dir = p.dir
        local thumb
        pcall(function() thumb = Image{ fromFile = jp(p.dir, p.last) } end)
        dlg:canvas{ id = "t" .. i, width = TW, height = TH, hexpand = false, vexpand = false,
          onpaint     = function(ev) drawTile(ev, thumb, p, selected[dir]) end,
          onmousedown = function(ev)
            selected[dir] = (not selected[dir]) or nil
            pcall(function() dlg:modify{ id = "selcount", text = "Selected: " .. selCount() } end)
            dlg:repaint()
          end }
        if (i % COLS) == 0 then dlg:newrow() end
      end
      dlg:newrow()
      dlg:label{ id = "selcount", text = "Selected: " .. selCount() }
      dlg:newrow()
    else
      for i, p in ipairs(shown) do
        dlg:check{ id = "chk" .. i, text = p.disp .. "  [" .. p.frames .. "f]", selected = selected[p.dir] or false }
        dlg:newrow()
      end
    end

    if #pieces > RECENT then
      dlg:button{ id = "toggleAll", text = showAll and "Show recent only" or ("Show all " .. #pieces .. " >>") }
      dlg:newrow()
    end

    dlg:separator{ text = "Options  (remembered next time; lower FPS = slower)" }
    dlg:combobox{ id = "lengthMode", label = "Speed",
                  option = (prefs.lengthMode == "seconds") and "Target length" or "Fixed FPS",
                  options = { "Fixed FPS", "Target length" } }
    dlg:number{ id = "fps",           label = "Fixed FPS",           text = tostring(prefs.fps),           decimals = 0 }
    dlg:number{ id = "targetSeconds", label = "Target length (sec)", text = tostring(prefs.targetSeconds), decimals = 0 }
    dlg:number{ id = "scale",         label = "Upscale (x)",         text = tostring(prefs.scale),         decimals = 0 }
    dlg:number{ id = "holdSeconds",   label = "Hold final (sec)",    text = tostring(prefs.holdSeconds),   decimals = 1 }
    dlg:check{ id = "makeGif", label = "Output", text = "GIF  (recommended)",              selected = prefs.makeGif }
    dlg:newrow()
    dlg:check{ id = "mp4",     label = "",       text = "MP4  (needs ffmpeg; may error on locked-down PCs)", selected = prefs.makeMp4 }
    dlg:newrow()
    dlg:check{ id = "delAfter", label = "",      text = "Delete frames after creating",   selected = false }
    dlg:separator()
    dlg:button{ id = "create", text = "Create Timelapse!", focus = true }
    dlg:button{ id = "delete", text = "Delete Selected" }
    dlg:button{ id = "cancel", text = "Close" }
    dlg:show{ autoscrollbars = true }
    local data = dlg.data

    if not useThumbs then
      for i, p in ipairs(shown) do selected[p.dir] = data["chk" .. i] or nil end
    end

    prefs.lengthMode    = (data.lengthMode == "Target length") and "seconds" or "fps"
    prefs.fps           = math.max(1, math.floor(data.fps or prefs.fps))
    prefs.targetSeconds = math.max(1, math.floor(data.targetSeconds or prefs.targetSeconds))
    prefs.scale         = math.max(1, math.floor(data.scale or prefs.scale))
    prefs.holdSeconds   = math.max(0, tonumber(data.holdSeconds) or prefs.holdSeconds)
    prefs.makeGif       = data.makeGif
    prefs.makeMp4       = data.mp4

    local sel = {}
    for _, p in ipairs(pieces) do if selected[p.dir] then sel[#sel + 1] = p end end

    if data.toggleAll then
      showAll = not showAll
    elseif data.create then
      if #sel == 0 then
        alert({ "Select at least one piece (click a tile)." })
      elseif not (data.makeGif or data.mp4) then
        alert({ "Pick at least one output (GIF or MP4)." })
      else
        busy = true
        local results, notes = {}, {}
        for _, p in ipairs(sel) do
          local delAfter = data.delAfter and not activeDir(p.dir)
          local ok, summary, note
          pcall(function() ok, summary, note = compileDir(p.dir, p.outBase, delAfter) end)
          if summary then results[#results + 1] = summary end
          if note then notes[#notes + 1] = note end
        end
        busy = false
        reportResults(results, notes, "No timelapse was created.")
        return
      end
    elseif data.delete then
      for _, p in ipairs(sel) do
        if not activeDir(p.dir) then purgeFrames(p.dir, listPng(p.dir)); forgetDir(p.dir); selected[p.dir] = nil end
      end
    else
      return
    end
  end
end

clearCache = function()
  local root = cacheRoot()
  if not app.fs.isDirectory(root) then alert({ "The library is already empty." }) return end
  local r = app.alert{ title = TITLE,
    text = { "Delete ALL recorded pieces (raw frames)?", "Finished GIFs/MP4s are NOT affected." },
    buttons = { "Delete all", "Cancel" } }
  if r ~= 1 then return end
  local removed = 0
  for _, name in ipairs(app.fs.listFiles(root)) do
    local d = jp(root, name)
    if app.fs.isDirectory(d) and not activeDir(d) then
      purgeFrames(d, listPng(d)); forgetDir(d); removed = removed + 1
    end
  end
  alert({ "Cleared " .. removed .. " recorded piece(s)." })
end

-- ---------------------------------------------------------------------------
-- record on/off
-- ---------------------------------------------------------------------------
arm = function()
  if not siteCode then siteCode = app.events:on("sitechange", onSiteChange) end
  if app.sprite then pcall(function() hookSprite(app.sprite) end) end
end

startRecording = function()
  if recording then return end
  recording = true
  prefs.recording = true
  arm()
  alert({ "Recording is ON (saved sprites only).",
          "Work on your pieces normally - each is banked automatically.",
          "Use \"Create Timelapse...\" when you want to export." })
end

stopRecording = function()
  recording = false
  prefs.recording = false
  if siteCode then pcall(function() app.events:off(siteCode) end); siteCode = nil end
  for id, s in pairs(sessions) do
    if s.sprite and s.sprite.isValid and s.code then pcall(function() s.sprite.events:off(s.code) end) end
    sessions[id] = nil
  end
  alert({ "Recording paused.",
          "Your recorded pieces are kept - open \"Create Timelapse...\" any time." })
end

-- ---------------------------------------------------------------------------
-- settings
-- ---------------------------------------------------------------------------
showSettings = function()
  local d = Dialog("Timelapse Settings  (v" .. VERSION .. ")")
  d:separator{ text = "Recording" }
  d:check{ id = "savedOnly", label = "Record", text = "Only record saved sprites", selected = prefs.savedOnly }
  d:newrow()
  d:check{ id = "skipUndo",  label = "",       text = "Skip undo / redo",          selected = prefs.skipUndo }
  d:number{ id = "minInterval", label = "Min seconds between snaps", text = tostring(prefs.minInterval), decimals = 0 }
  d:number{ id = "maxPieces",   label = "Max pieces to keep",       text = tostring(prefs.maxPieces),   decimals = 0 }
  d:separator{ text = "Default export options" }
  d:number{ id = "scale",       label = "Upscale factor (x)",     text = tostring(prefs.scale),         decimals = 0 }
  d:combobox{ id = "lengthMode", label = "Speed",
              option = (prefs.lengthMode == "seconds") and "Target length" or "Fixed FPS",
              options = { "Fixed FPS", "Target length" } }
  d:number{ id = "fps",           label = "Fixed FPS",              text = tostring(prefs.fps),           decimals = 0 }
  d:number{ id = "targetSeconds", label = "Target length (sec)",    text = tostring(prefs.targetSeconds), decimals = 0 }
  d:number{ id = "holdSeconds",   label = "Hold final frame (sec)", text = tostring(prefs.holdSeconds),   decimals = 1 }
  d:check{ id = "makeGif", label = "Formats", text = "GIF",                 selected = prefs.makeGif }
  d:newrow()
  d:check{ id = "mp4",     label = "",        text = "MP4 (needs ffmpeg)",  selected = prefs.makeMp4 }
  d:separator()
  d:entry{ id = "ffmpegPath", label = "ffmpeg path", text = prefs.ffmpegPath }
  d:entry{ id = "outputDir",  label = "Output folder (blank = Documents)", text = prefs.outputDir }
  d:separator()
  d:button{ id = "ok", text = "Save", focus = true }
  d:button{ id = "cancel", text = "Cancel" }
  d:show()

  local data = d.data
  if data.ok then
    prefs.savedOnly     = data.savedOnly
    prefs.skipUndo      = data.skipUndo
    prefs.minInterval   = math.max(0, math.floor(data.minInterval or prefs.minInterval))
    prefs.maxPieces     = math.max(1, math.floor(data.maxPieces or prefs.maxPieces))
    prefs.scale         = math.max(1, math.floor(data.scale or prefs.scale))
    prefs.lengthMode    = (data.lengthMode == "Target length") and "seconds" or "fps"
    prefs.fps           = math.max(1, math.floor(data.fps or prefs.fps))
    prefs.targetSeconds = math.max(1, math.floor(data.targetSeconds or prefs.targetSeconds))
    prefs.holdSeconds   = math.max(0, tonumber(data.holdSeconds) or prefs.holdSeconds)
    prefs.makeGif       = data.makeGif
    prefs.makeMp4       = data.mp4
    prefs.ffmpegPath    = data.ffmpegPath
    prefs.outputDir     = data.outputDir
    pcall(enforceLibraryCap)
  end
end

-- ---------------------------------------------------------------------------
-- plugin lifecycle
-- ---------------------------------------------------------------------------
function init(plugin)
  prefs = plugin.preferences
  if prefs.minInterval   == nil then prefs.minInterval   = 1 end
  if prefs.maxPieces     == nil then prefs.maxPieces     = 40 end
  if prefs.scale         == nil then prefs.scale         = 8 end
  if prefs.lengthMode    == nil then prefs.lengthMode    = "fps" end
  if prefs.fps           == nil then prefs.fps           = 12 end
  if prefs.targetSeconds == nil then prefs.targetSeconds = 20 end
  if prefs.holdSeconds   == nil then prefs.holdSeconds   = 1.0 end
  if prefs.skipUndo      == nil then prefs.skipUndo      = true end
  if prefs.savedOnly     == nil then prefs.savedOnly     = true end
  if prefs.makeGif       == nil then prefs.makeGif       = true end
  if prefs.makeMp4       == nil then prefs.makeMp4       = false end
  if prefs.outputDir     == nil then prefs.outputDir     = "" end
  if prefs.ffmpegPath    == nil then prefs.ffmpegPath    = "ffmpeg" end
  if prefs.pieces        == nil then prefs.pieces        = {} end
  if prefs.recording     == nil then prefs.recording     = true end

  for dir, _ in pairs(prefs.pieces) do
    if not app.fs.isDirectory(dir) then prefs.pieces[dir] = nil end
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
    id      = "CreateTimelapse",
    title   = "Create Timelapse...",
    group   = "timelapse_group",
    onclick = function() pcall(openCreatePicker) end,
  }
  plugin:newCommand{
    id      = "OpenTimelapseFolder",
    title   = "Open Timelapse Folder",
    group   = "timelapse_group",
    onclick = function() pcall(function() openPath(outputDir()) end) end,
  }
  plugin:newCommand{
    id      = "ClearTimelapseCache",
    title   = "Clear Recorded Pieces",
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
  for _, s in pairs(sessions) do
    if s.sprite and s.sprite.isValid and s.code then pcall(function() s.sprite.events:off(s.code) end) end
  end
end
