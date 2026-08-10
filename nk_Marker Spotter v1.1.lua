-- ============================================================
-- MARKER SPOTTER  v1.1
-- Spots REAPER markers and commits MIDI notes to tracks.
-- Requires: ReaImGui (bundled with ReaPack ReaImGui package)
--
-- v1.1 changes:
--   - Removed marker color filter (unused / impractical)
--   - Added per-rule Copy / Paste settings
--   - Added saveable / loadable Presets (stored via ExtState)
-- ============================================================

local ctx = reaper.ImGui_CreateContext("nk_Marker Spotter v1.1")

-- ============================================================
-- PALETTE
-- ============================================================
local PAL = {
  bg          = 0x1A1A2EFF,
  panel       = 0x16213EFF,
  accent      = 0x0F3460FF,
  highlight   = 0xA63A3AFF,
  text        = 0xE0E0EEFF,
  dim         = 0x7070A0FF,
  ok          = 0x4EC94EFF,
  warn        = 0xFFD166FF,
  err         = 0xFF4C4CFF,
  separator   = 0x2A2A4AFF,
  ruleBg      = 0x20203AFF,
  ruleBorder  = 0x35355AFF,
}

local RULE_COLORS = {
  0xA63A3AFF,
  0x3A7A52FF,
  0x8A6B2AFF,
  0x2A5F8AFF,
  0x7A3A72FF,
  0x2A7A78FF,
  0x6A4A8AFF,
  0x5A5A5AFF,
}

local function ruleColor(i)
  return RULE_COLORS[((i - 1) % #RULE_COLORS) + 1]
end

-- ============================================================
-- STATE
-- ============================================================
local rules         = {}
local log           = {}
local actionQueue    = {}
local timelineOpen   = false
local ruleClipboard  = nil   -- holds a copied rule's settings (search/track/note/vel/length/offset)

local hasDisableAPI  = (reaper.ImGui_BeginDisabled ~= nil and reaper.ImGui_EndDisabled ~= nil)

-- ============================================================
-- LOGGING
-- ============================================================
local function logAdd(t, m)
  table.insert(log, { t = t, m = m })
  if #log > 200 then table.remove(log, 1) end
end

-- ============================================================
-- RULES
-- ============================================================
local function newRule(id)
  return {
    id      = id,
    search  = "",
    track   = "",
    note    = "C2",
    vel     = "100",
    length  = 0.5,   -- MIDI note length in seconds
    offset  = 0.0,   -- trigger offset in seconds
    enabled = true,
    open    = true,
    delete  = false,
  }
end

rules = { newRule(1) }

local function reindexRules()
  for i, r in ipairs(rules) do r.id = i end
end

local function addRule()
  table.insert(rules, newRule(#rules + 1))
end

local function cleanupRules()
  local kept = {}
  for _, r in ipairs(rules) do
    if not r.delete then kept[#kept + 1] = r end
  end
  rules = kept
  reindexRules()
end

-- Copy / Paste rule settings
local function copyRule(r)
  ruleClipboard = {
    search = r.search,
    track  = r.track,
    note   = r.note,
    vel    = r.vel,
    length = r.length,
    offset = r.offset,
  }
  logAdd("INFO", string.format("Copied settings from R%d", r.id))
end

local function pasteRule(r)
  if not ruleClipboard then return end
  r.search = ruleClipboard.search
  r.track  = ruleClipboard.track
  r.note   = ruleClipboard.note
  r.vel    = ruleClipboard.vel
  r.length = ruleClipboard.length
  r.offset = ruleClipboard.offset
  logAdd("INFO", string.format("Pasted settings into R%d", r.id))
end

-- ============================================================
-- MIDI NOTE PARSER
-- ============================================================
local NOTE_MAP = {
  C=0,["C#"]=1,D=2,["D#"]=3,E=4,F=5,
  ["F#"]=6,G=7,["G#"]=8,A=9,["A#"]=10,B=11
}

local function nameToMidi(n)
  if not n then return 60 end
  local p, o = n:match("^([A-G]#?)(%-?%d+)$")
  if p and o then
    return 12 * (tonumber(o) + 1) + NOTE_MAP[p]
  end
  return tonumber(n) or 60
end

local function parseRange(s)
  if not s or s == "" then return 60, 60 end
  local a, b = s:match("^(.+)%-(.+)$")
  if a and b then
    local lo = nameToMidi(a)
    local hi = nameToMidi(b)
    if lo > hi then lo, hi = hi, lo end
    return lo, hi
  end
  local v = nameToMidi(s)
  return v, v
end

-- ============================================================
-- TRACK LOOKUP
-- ============================================================
local function findTrack(name)
  if not name or name == "" then return nil end
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, n = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if n == name then return tr end
  end
  return nil
end

-- ============================================================
-- MIDI ITEM CREATION
-- length: item/note duration in seconds
-- ============================================================
local function makeItem(track, pos, note, vel, length, label)
  note   = math.max(0,   math.min(127, note))
  vel    = math.max(1,   math.min(127, vel))
  length = math.max(0.01, length)

  local item = reaper.CreateNewMIDIItemInProj(track, pos, pos + length, false)
  local take = reaper.GetActiveTake(item)

  if not take or not reaper.TakeIsMIDI(take) then
    logAdd("ERROR", "MIDI creation failed: " .. tostring(label))
    return
  end

  -- Convert length in seconds to MIDI ticks.
  -- REAPER default is 960 PPQ; note fills the item length.
  local ppq = reaper.MIDI_GetPPQPosFromProjTime(take, pos + length)
           - reaper.MIDI_GetPPQPosFromProjTime(take, pos)
  ppq = math.max(1, math.floor(ppq))

  reaper.MIDI_InsertNote(take, false, false, 0, ppq, 0, note, vel, false)
  reaper.MIDI_Sort(take)
  reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", label, true)
end

-- ============================================================
-- SCAN
-- ============================================================
local function scan()
  log         = {}
  actionQueue = {}

  local matches = 0

  for i = 0, reaper.CountProjectMarkers(0) - 1 do
    local _, isrgn, pos, _, name = reaper.EnumProjectMarkers(i)
    name = name or ""

    if not isrgn then
      for idx, r in ipairs(rules) do
        if r.enabled
        and r.search ~= ""
        and name:lower():find(r.search:lower(), 1, true)
        then
          matches = matches + 1

          local n1, n2 = parseRange(r.note)
          local v1, v2 = parseRange(r.vel)

          table.insert(actionQueue, {
            track  = r.track,
            pos    = pos + (r.offset or 0.0),
            n1=n1, n2=n2,
            v1=v1, v2=v2,
            length = math.max(0.01, r.length or 0.5),
            label  = string.format("R%d – %s", r.id, name),
            ruleId = r.id,
            color  = ruleColor(idx),
          })

          logAdd("MATCH", string.format("Rule %d → \"%s\"  @%.2fs", r.id, name, pos))
        end
      end
    end
  end

  logAdd("INFO", string.format("Scan complete — %d match(es), %d item(s) queued", matches, #actionQueue))
end

-- ============================================================
-- COMMIT
-- ============================================================
local function commit()
  if #actionQueue == 0 then
    logAdd("INFO", "Nothing queued — run Scan first")
    return
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local written, failed = 0, 0

  for _, a in ipairs(actionQueue) do
    local tr = findTrack(a.track)
    if tr then
      local note = math.random(a.n1, a.n2)
      local vel  = math.random(a.v1, a.v2)
      makeItem(tr, a.pos, note, vel, a.length, a.label)
      written = written + 1
    else
      logAdd("ERROR", string.format("Track not found for \"%s\"", a.label))
      failed = failed + 1
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Marker Spotter: Commit", -1)
  reaper.UpdateArrange()

  logAdd("INFO", string.format("Committed %d item(s)  |  %d error(s)", written, failed))
end

-- ============================================================
-- PRESETS  (stored via REAPER ExtState, persisted to reaper.ini)
-- ============================================================
local EXT_SECTION = "MarkerSpotter_Presets_v1"
local FS, RS = "\1", "\2"   -- field / record separators for simple serialization

local function escapeField(s)
  s = tostring(s or "")
  s = s:gsub(FS, ""):gsub(RS, "")
  return s
end

local function encodeRules(list)
  local recs = {}
  for _, r in ipairs(list) do
    local fields = {
      escapeField(r.search),
      escapeField(r.track),
      escapeField(r.note),
      escapeField(r.vel),
      tostring(r.length or 0.5),
      tostring(r.offset or 0.0),
    }
    recs[#recs + 1] = table.concat(fields, FS)
  end
  return table.concat(recs, RS)
end

local function decodeRules(str)
  local list = {}
  if not str or str == "" then return list end
  for rec in (str .. RS):gmatch("(.-)" .. RS) do
    local f = {}
    for piece in (rec .. FS):gmatch("(.-)" .. FS) do
      f[#f + 1] = piece
    end
    if #f >= 6 then
      local r = newRule(0)
      r.search = f[1]
      r.track  = f[2]
      r.note   = f[3]
      r.vel    = f[4]
      r.length = tonumber(f[5]) or 0.5
      r.offset = tonumber(f[6]) or 0.0
      list[#list + 1] = r
    end
  end
  return list
end

local function getPresetNames()
  local raw = reaper.GetExtState(EXT_SECTION, "PresetList")
  local names = {}
  if raw and raw ~= "" then
    for n in raw:gmatch("([^,]+)") do
      names[#names + 1] = n
    end
  end
  return names
end

local function setPresetNames(names)
  reaper.SetExtState(EXT_SECTION, "PresetList", table.concat(names, ","), true)
end

local function sanitizePresetName(name)
  name = (name or ""):gsub(",", ""):gsub(FS, ""):gsub(RS, "")
  return name:match("^%s*(.-)%s*$")  -- trim
end

local function savePreset(name)
  name = sanitizePresetName(name)
  if name == "" then
    logAdd("ERROR", "Preset name cannot be empty")
    return
  end

  local data = encodeRules(rules)
  reaper.SetExtState(EXT_SECTION, "Preset_" .. name, data, true)

  local names = getPresetNames()
  local exists = false
  for _, n in ipairs(names) do
    if n == name then exists = true end
  end
  if not exists then
    names[#names + 1] = name
    setPresetNames(names)
  end

  logAdd("INFO", "Preset saved: " .. name)
end

local function loadPreset(name)
  if not name or name == "" then
    logAdd("ERROR", "No preset selected")
    return
  end

  local data = reaper.GetExtState(EXT_SECTION, "Preset_" .. name)
  if not data or data == "" then
    logAdd("ERROR", "Preset not found: " .. name)
    return
  end

  local decoded = decodeRules(data)
  if #decoded == 0 then
    logAdd("ERROR", "Preset empty or corrupt: " .. name)
    return
  end

  rules = decoded
  reindexRules()
  logAdd("INFO", "Preset loaded: " .. name)
end

local function deletePreset(name)
  if not name or name == "" then return end

  reaper.DeleteExtState(EXT_SECTION, "Preset_" .. name, true)

  local names = getPresetNames()
  local kept = {}
  for _, n in ipairs(names) do
    if n ~= name then kept[#kept + 1] = n end
  end
  setPresetNames(kept)

  logAdd("INFO", "Preset deleted: " .. name)
end

-- ============================================================
-- IMGUI HELPERS
-- ============================================================
local function colorSwatch(color, size)
  size = size or 12
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local dl   = reaper.ImGui_GetWindowDrawList(ctx)
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + size, y + size, color)
  reaper.ImGui_Dummy(ctx, size, size)
end

-- ============================================================
-- RULE CARDS
-- ============================================================
local CARD_PAD = 6
local CARD_GAP = 5
local ROW_H    = 18

local function drawRule(r, idx)
  local col = ruleColor(idx)
  local dl  = reaper.ImGui_GetWindowDrawList(ctx)

  local cx, cy = reaper.ImGui_GetCursorScreenPos(ctx)
  local cw     = reaper.ImGui_GetContentRegionAvail(ctx)

  -- Two rows of fields in the body: track row, then note/vel/length/offset row
  local cardH = r.open and (CARD_PAD*2 + ROW_H*10 + 22) or (CARD_PAD*2 + ROW_H + 2)

  reaper.ImGui_DrawList_AddRectFilled(dl, cx, cy, cx + cw, cy + cardH, PAL.ruleBg)
  reaper.ImGui_DrawList_AddRectFilled(dl, cx, cy, cx + 3,  cy + cardH, col)
  reaper.ImGui_DrawList_AddRect(      dl, cx, cy, cx + cw, cy + cardH, PAL.ruleBorder)

  reaper.ImGui_SetCursorScreenPos(ctx, cx + CARD_PAD + 3, cy + CARD_PAD)

  -- Header
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        col)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), PAL.highlight)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  col)
  if reaper.ImGui_Button(ctx, (r.open and "▾" or "▸") .. " R" .. r.id .. "##tog" .. r.id, 52, 0) then
    r.open = not r.open
  end
  reaper.ImGui_PopStyleColor(ctx, 3)

  reaper.ImGui_SameLine(ctx)
  local _, en = reaper.ImGui_Checkbox(ctx, "##en" .. r.id, r.enabled)
  r.enabled = en
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_TextColored(ctx, PAL.dim, "enabled")

  -- Header-right buttons: Copy / Paste / Delete
  local btnSize = 22
  local btnGap  = 4
  local delX    = cx + cw - btnSize - 6
  local pasteX  = delX   - btnSize - btnGap
  local copyX   = pasteX - btnSize - btnGap

  -- Copy
  reaper.ImGui_SetCursorScreenPos(ctx, copyX, cy + CARD_PAD)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        PAL.accent)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), PAL.highlight)
  if reaper.ImGui_Button(ctx, "⧉##copy" .. r.id, btnSize, 0) then
    copyRule(r)
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, "Copy this rule's settings")
  end
  reaper.ImGui_PopStyleColor(ctx, 2)

  -- Paste
  reaper.ImGui_SetCursorScreenPos(ctx, pasteX, cy + CARD_PAD)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        PAL.accent)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), PAL.highlight)
  local pasteDisabled = (ruleClipboard == nil)
  if pasteDisabled and hasDisableAPI then reaper.ImGui_BeginDisabled(ctx, true) end
  if reaper.ImGui_Button(ctx, "⎘##paste" .. r.id, btnSize, 0) and not pasteDisabled then
    pasteRule(r)
  end
  if pasteDisabled and hasDisableAPI then reaper.ImGui_EndDisabled(ctx) end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_SetTooltip(ctx, pasteDisabled and "Nothing copied yet" or "Paste copied settings here")
  end
  reaper.ImGui_PopStyleColor(ctx, 2)

  -- Delete
  reaper.ImGui_SetCursorScreenPos(ctx, delX, cy + CARD_PAD)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        PAL.highlight)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0xC04040FF)
  if reaper.ImGui_Button(ctx, "✕##del" .. r.id, btnSize, 0) then
    r.delete = true
  end
  reaper.ImGui_PopStyleColor(ctx, 2)

  -- Body
  if r.open then
    local bodyX = cx + CARD_PAD + 3

    -- Marker search
    reaper.ImGui_SetCursorScreenPos(ctx, bodyX, cy + CARD_PAD + ROW_H + 6)
    reaper.ImGui_TextColored(ctx, PAL.dim, "Marker search")
    local _, searchFieldY = reaper.ImGui_GetCursorScreenPos(ctx)
    reaper.ImGui_SetCursorScreenPos(ctx, bodyX, searchFieldY)
    reaper.ImGui_SetNextItemWidth(ctx, 200)
    local _, sv = reaper.ImGui_InputText(ctx, "##search" .. r.id, r.search or "")
    r.search = sv

    reaper.ImGui_Spacing(ctx)

    -- Track destination
    local _, trackLabelY = reaper.ImGui_GetCursorScreenPos(ctx)
    reaper.ImGui_SetCursorScreenPos(ctx, bodyX, trackLabelY)
    reaper.ImGui_TextColored(ctx, PAL.dim, "Track destination")
    local _, trackFieldY = reaper.ImGui_GetCursorScreenPos(ctx)
    reaper.ImGui_SetCursorScreenPos(ctx, bodyX, trackFieldY)
    reaper.ImGui_SetNextItemWidth(ctx, 200)
    local _, tv = reaper.ImGui_InputText(ctx, "##track" .. r.id, r.track or "")
    r.track = tv
    reaper.ImGui_SameLine(ctx)
    colorSwatch(col, 16)
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, "Rule colour")
    end

    reaper.ImGui_Spacing(ctx)

    -- Field layout constants
    local noteW  = 60
    local velW   = 60
    local lenW   = 60
    local offW   = 60
    local btnW   = 20
    local colGap = 8
    local btnGap2 = 4

    local _, fieldY = reaper.ImGui_GetCursorScreenPos(ctx)
    local noteX  = bodyX
    local velX   = noteX + noteW  + colGap
    local lenX   = velX  + velW   + colGap
    local offX   = lenX  + lenW   + colGap + 8
    local minusX = offX  + offW   + btnGap2
    local plusX  = minusX + btnW  + 2

    -- Note
    reaper.ImGui_SetCursorScreenPos(ctx, noteX, fieldY)
    reaper.ImGui_SetNextItemWidth(ctx, noteW)
    local _, nv = reaper.ImGui_InputText(ctx, "##note" .. r.id, r.note or "C2")
    r.note = nv

    -- Velocity
    reaper.ImGui_SetCursorScreenPos(ctx, velX, fieldY)
    reaper.ImGui_SetNextItemWidth(ctx, velW)
    local _, vv = reaper.ImGui_InputText(ctx, "##vel" .. r.id, r.vel or "100")
    r.vel = vv

    -- Length (seconds, stored directly)
    reaper.ImGui_SetCursorScreenPos(ctx, lenX, fieldY)
    reaper.ImGui_SetNextItemWidth(ctx, lenW)
    local lenChg, newLen = reaper.ImGui_InputDouble(ctx, "##length" .. r.id, r.length or 0.5, 0, 0, "%.2fs")
    if lenChg then r.length = math.max(0.01, newLen) end

    -- Offset (stored as seconds, shown as ms)
    local offsetMs = math.floor((r.offset or 0.0) * 1000.0 + 0.5)
    reaper.ImGui_SetCursorScreenPos(ctx, offX, fieldY)
    reaper.ImGui_SetNextItemWidth(ctx, offW)
    local offChg, newMs = reaper.ImGui_InputDouble(ctx, "##offset" .. r.id, offsetMs, 0, 0, "%.0f ms")
    if offChg then r.offset = newMs / 1000.0 end

    -- Offset +/- buttons
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        PAL.accent)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), PAL.highlight)
    reaper.ImGui_SetCursorScreenPos(ctx, minusX, fieldY)
    if reaper.ImGui_Button(ctx, "−##ominus" .. r.id, btnW, 0) then
      r.offset = r.offset - 0.010
    end
    reaper.ImGui_SetCursorScreenPos(ctx, plusX, fieldY)
    if reaper.ImGui_Button(ctx, "+##oplus" .. r.id, btnW, 0) then
      r.offset = r.offset + 0.010
    end
    reaper.ImGui_PopStyleColor(ctx, 2)

    -- Labels below fields
    local labelY = fieldY + ROW_H + 2
    reaper.ImGui_SetCursorScreenPos(ctx, noteX, labelY)
    reaper.ImGui_TextColored(ctx, PAL.dim, "Note")
    reaper.ImGui_SetCursorScreenPos(ctx, velX, labelY)
    reaper.ImGui_TextColored(ctx, PAL.dim, "Velocity")
    reaper.ImGui_SetCursorScreenPos(ctx, lenX, labelY)
    reaper.ImGui_TextColored(ctx, PAL.dim, "Length")
    reaper.ImGui_SetCursorScreenPos(ctx, offX, labelY)
    reaper.ImGui_TextColored(ctx, PAL.dim, "Offset")

    reaper.ImGui_SetCursorScreenPos(ctx, bodyX, labelY + ROW_H)
    reaper.ImGui_Dummy(ctx, 1, 1)
  end

  reaper.ImGui_SetCursorScreenPos(ctx, cx, cy + cardH + CARD_GAP)
  reaper.ImGui_Dummy(ctx, 1, 1)
end

-- ============================================================
-- LOG PANEL
-- ============================================================
local function drawLog()
  local cfBorder = reaper.ImGui_ChildFlags_Border and reaper.ImGui_ChildFlags_Border() or 1
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), PAL.panel)
  reaper.ImGui_BeginChild(ctx, "##log", 0, 120, cfBorder)

  local start = math.max(1, #log - 40)
  for i = start, #log do
    local e   = log[i]
    local col = (e.t == "MATCH") and PAL.ok or (e.t == "ERROR") and PAL.err or PAL.warn
    reaper.ImGui_TextColored(ctx, col, string.format("[%s] %s", e.t, e.m))
  end

  if reaper.ImGui_GetScrollY(ctx) >= reaper.ImGui_GetScrollMaxY(ctx) then
    reaper.ImGui_SetScrollHereY(ctx, 1.0)
  end

  reaper.ImGui_EndChild(ctx)
  reaper.ImGui_PopStyleColor(ctx)
end

-- ============================================================
-- MINI TIMELINE
-- ============================================================
local function drawTimeline()
  if not timelineOpen then return end

  local dl      = reaper.ImGui_GetWindowDrawList(ctx)
  local wx, wy  = reaper.ImGui_GetCursorScreenPos(ctx)
  local avail   = reaper.ImGui_GetContentRegionAvail(ctx)
  local barH    = 28
  local projLen = reaper.GetProjectLength(0)

  reaper.ImGui_DrawList_AddRectFilled(dl, wx, wy, wx + avail, wy + barH, 0x1A1917FF)
  reaper.ImGui_DrawList_AddRect(      dl, wx, wy, wx + avail, wy + barH, PAL.ruleBorder)

  if projLen > 0 and #actionQueue > 0 then
    for _, a in ipairs(actionQueue) do
      local xn = math.max(0, math.min(1, a.pos / projLen))
      local sx = wx + xn * avail
      reaper.ImGui_DrawList_AddRectFilled(dl, sx - 1, wy, sx + 1, wy + barH, a.color)
    end
  end

  if projLen > 0 then
    local px = wx + (reaper.GetPlayPosition() / projLen) * avail
    reaper.ImGui_DrawList_AddLine(dl, px, wy, px, wy + barH, 0xFFFFFFBB, 1.5)
  end

  reaper.ImGui_Dummy(ctx, avail, barH)
  reaper.ImGui_TextColored(ctx, PAL.dim,
    string.format("0:00  ──  %.1fs  ──  %d queued", projLen, #actionQueue))
end

-- ============================================================
-- PRESET BAR
-- ============================================================
local presetNameBuf  = ""
local selectedPreset = ""

local function drawPresetBar()
  reaper.ImGui_TextColored(ctx, PAL.dim, "Presets")
  reaper.ImGui_SameLine(ctx)

  -- New preset name + Save
  reaper.ImGui_SetNextItemWidth(ctx, 150)
  local _, pv = reaper.ImGui_InputTextWithHint(ctx, "##presetname", "New preset name…", presetNameBuf)
  presetNameBuf = pv
  reaper.ImGui_SameLine(ctx)

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        PAL.accent)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), PAL.highlight)
  if reaper.ImGui_Button(ctx, "Save Preset", 90, 0) then
    savePreset(presetNameBuf)
    presetNameBuf = ""
  end
  reaper.ImGui_PopStyleColor(ctx, 2)

  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_Dummy(ctx, 10, 1)
  reaper.ImGui_SameLine(ctx)

  -- Existing preset select + Load/Delete
  local names = getPresetNames()
  reaper.ImGui_SetNextItemWidth(ctx, 150)
  if reaper.ImGui_BeginCombo(ctx, "##presetselect", selectedPreset == "" and "Select preset…" or selectedPreset) then
    for _, n in ipairs(names) do
      local sel = (selectedPreset == n)
      if reaper.ImGui_Selectable(ctx, n, sel) then
        selectedPreset = n
      end
      if sel then reaper.ImGui_SetItemDefaultFocus(ctx) end
    end
    reaper.ImGui_EndCombo(ctx)
  end

  reaper.ImGui_SameLine(ctx)
  local noSelection = (selectedPreset == "")
  if noSelection and hasDisableAPI then reaper.ImGui_BeginDisabled(ctx, true) end

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        PAL.accent)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), PAL.highlight)
  if reaper.ImGui_Button(ctx, "Load", 60, 0) and not noSelection then
    loadPreset(selectedPreset)
  end
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Delete", 60, 0) and not noSelection then
    deletePreset(selectedPreset)
    selectedPreset = ""
  end
  reaper.ImGui_PopStyleColor(ctx, 2)

  if noSelection and hasDisableAPI then reaper.ImGui_EndDisabled(ctx) end
end

-- ============================================================
-- MAIN LOOP
-- ============================================================
local function loop()

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(),      PAL.bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBgActive(),  PAL.accent)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBg(),        PAL.panel)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),         PAL.separator)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),           PAL.text)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),        PAL.panel)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(), PAL.accent)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_CheckMark(),      PAL.highlight)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarBg(),    PAL.panel)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarGrab(),  PAL.accent)

  reaper.ImGui_SetNextWindowSize(ctx, 680, 740, reaper.ImGui_Cond_FirstUseEver())

  local ok, open = reaper.ImGui_Begin(ctx, "nk_Marker Spotter  v1.1", true)

  if ok then

    -- ── Toolbar ─────────────────────────────────────────────
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        PAL.accent)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), PAL.highlight)

    if reaper.ImGui_Button(ctx, "⟳  Scan", 80, 0) then scan() end
    reaper.ImGui_SameLine(ctx)

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), PAL.highlight)
    if reaper.ImGui_Button(ctx, "✔  Commit", 90, 0) then commit() end
    reaper.ImGui_PopStyleColor(ctx)

    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "+ Rule", 68, 0) then addRule() end
    reaper.ImGui_SameLine(ctx)

    local tlLabel = timelineOpen and "▾ Timeline" or "▸ Timeline"
    if reaper.ImGui_Button(ctx, tlLabel, 90, 0) then
      timelineOpen = not timelineOpen
    end

    reaper.ImGui_PopStyleColor(ctx, 2)

    reaper.ImGui_Separator(ctx)

    -- ── Presets ─────────────────────────────────────────────
    drawPresetBar()

    reaper.ImGui_Separator(ctx)

    if timelineOpen then
      drawTimeline()
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_Separator(ctx)
    end

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), PAL.bg)
    reaper.ImGui_BeginChild(ctx, "##rules", 0, -160, 0)

    for i, r in ipairs(rules) do
      drawRule(r, i)
    end

    reaper.ImGui_EndChild(ctx)
    reaper.ImGui_PopStyleColor(ctx)

    cleanupRules()

    reaper.ImGui_Separator(ctx)

    reaper.ImGui_TextColored(ctx, PAL.dim, "LOG")
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_SmallButton(ctx, "Clear##logclear") then log = {} end
    drawLog()

    reaper.ImGui_End(ctx)
  end

  reaper.ImGui_PopStyleColor(ctx, 10)

  if open then reaper.defer(loop) end
end

reaper.defer(loop)
