-- Take n Bake
-- Renders Take FX on selected items while preserving the full source audio file length.
-- The resulting item can have its handles dragged out to the original file boundaries.
-- Channels (mono/stereo) are detected automatically from the source file.
-- Rendered file is saved alongside the original source file.

local r = reaper

-- helpers

local function get_source_path(take)
  local src = r.GetMediaItemTake_Source(take)
  while true do
    local t = r.GetMediaSourceType(src)
    if t == "SECTION" or t == "REVERSE" then
      src = r.GetMediaSourceParent(src)
    else
      break
    end
  end
  return r.GetMediaSourceFileName(src), src
end

local function source_channel_count(src)
  return r.GetMediaSourceNumChannels(src) or 2
end

local function source_length_seconds(src)
  local len, is_qn = r.GetMediaSourceLength(src)
  if is_qn then
    local bpm, _ = r.TimeMap_GetTimeSigAtTime(0, 0)
    len = len / (bpm / 60.0)
  end
  return len
end

local function make_output_path(source_path)
  local dir  = source_path:match("^(.*[/\\])") or ""
  local base = source_path:match("[/\\]([^/\\]+)$") or source_path
  local name = base:match("^(.+)%.[^%.]+$") or base
  local ext  = base:match("%.([^%.]+)$") or "wav"
  name = name:gsub("_fx%d*$", "")
  return dir .. name .. "_fx." .. ext
end

local function file_exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

local function unique_path(base_path)
  if not file_exists(base_path) then return base_path end
  local dir  = base_path:match("^(.*[/\\])") or ""
  local base = base_path:match("[/\\]([^/\\]+)$") or base_path
  local name = base:match("^(.+)%.[^%.]+$") or base
  local ext  = base:match("%.([^%.]+)$") or "wav"
  local i = 2
  while true do
    local candidate = dir .. name .. i .. "." .. ext
    if not file_exists(candidate) then return candidate end
    i = i + 1
  end
end

local function move_file(src_path, dst_path)
  if src_path == dst_path then return src_path end
  if os.rename(src_path, dst_path) then return dst_path end
  local inf  = io.open(src_path, "rb")
  local outf = io.open(dst_path, "wb")
  if inf and outf then
    outf:write(inf:read("*all"))
    inf:close()
    outf:close()
    os.remove(src_path)
    return dst_path
  end
  if inf  then inf:close()  end
  if outf then outf:close() end
  return src_path
end

-- main render logic for a single item/take
-- Returns nil on success or an error string on failure

local function bake_item(item)
  local take = r.GetActiveTake(item)
  if not take then
    return "item has no active take"
  end
  if r.TakeIsMIDI(take) then
    return "take is MIDI, not audio"
  end
  if r.TakeFX_GetCount(take) == 0 then
    return "take has no FX to bake"
  end

  -- snapshot geometry & properties
  local item_pos    = r.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_len    = r.GetMediaItemInfo_Value(item, "D_LENGTH")
  local take_offset = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local take_rate   = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  local orig_track  = r.GetMediaItemTrack(item)

  local snap = {
    item_mute     = r.GetMediaItemInfo_Value(item, "B_MUTE"),
    fadein_len    = r.GetMediaItemInfo_Value(item, "D_FADEINLEN"),
    fadeout_len   = r.GetMediaItemInfo_Value(item, "D_FADEOUTLEN"),
    fadein_dir    = r.GetMediaItemInfo_Value(item, "D_FADEINDIR"),
    fadeout_dir   = r.GetMediaItemInfo_Value(item, "D_FADEOUTDIR"),
    fadein_shape  = r.GetMediaItemInfo_Value(item, "C_FADEINSHAPE"),
    fadeout_shape = r.GetMediaItemInfo_Value(item, "C_FADEOUTSHAPE"),
    take_pan      = r.GetMediaItemTakeInfo_Value(take, "D_PAN"),
    take_mute     = r.GetMediaItemTakeInfo_Value(take, "B_MUTE"),
    take_name     = ({r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)})[2],
  }

  local source_path, src = get_source_path(take)
  if source_path == "" then
    return "could not resolve source file (offline media?)"
  end

  local src_len  = source_length_seconds(src)
  local src_ch   = source_channel_count(src)
  local out_path = unique_path(make_output_path(source_path))

  local src_start_on_timeline = item_pos - (take_offset / take_rate)
  local src_len_in_project    = src_len  / take_rate

  -- create temp track
  local n_tracks = r.CountTracks(0)
  r.InsertTrackAtIndex(n_tracks, false)
  local tmp_track = r.GetTrack(0, n_tracks)
  r.GetSetMediaTrackInfo_String(tmp_track, "P_NAME", "~tmp_bake~", true)

  -- move item to temp track and expand to full source length
  r.MoveMediaItemToTrack(item, tmp_track)
  r.SetMediaItemInfo_Value(item, "D_POSITION", src_start_on_timeline)
  r.SetMediaItemInfo_Value(item, "D_LENGTH",   src_len_in_project)
  r.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", 0.0)

  local fx_count = r.TakeFX_GetCount(take)
  local fx_bypass = {}
  for fi = 0, fx_count - 1 do
    fx_bypass[fi] = r.TakeFX_GetEnabled(take, fi)
    r.TakeFX_SetEnabled(take, fi, true)
  end

  -- Take volume and item volume are left at their set values so FX receive
  -- the correct input level (important for dynamics). Both bake into the
  -- rendered file. New item's volumes are left at unity

  r.UpdateItemInProject(item)
  r.SelectAllMediaItems(0, false)
  r.SetMediaItemSelected(item, true)

  local render_action = (src_ch >= 2) and 40209 or 40361
  r.Main_OnCommand(render_action, 0)

  -- find rendered item on tmp_track
  local rendered_item = r.GetTrackMediaItem(tmp_track, 0)
  local rendered_take = rendered_item and r.GetActiveTake(rendered_item)

  if not rendered_item or not rendered_take then
    r.DeleteTrack(tmp_track)
    return "render produced no output (internal error)"
  end

  local rendered_path = r.GetMediaSourceFileName(r.GetMediaItemTake_Source(rendered_take))
  local final_path    = move_file(rendered_path, out_path)

  -- build final item on original track 
  local final_item = r.AddMediaItemToTrack(orig_track)
  local final_take = r.AddTakeToMediaItem(final_item)
  r.GetSetMediaItemTakeInfo_String(final_take, "P_NAME", snap.take_name, true)

  local new_src = r.PCM_Source_CreateFromFile(final_path)
  if not new_src then
    r.DeleteMediaItem(0, final_item)
    r.DeleteTrack(tmp_track)
    return "could not load rendered file: " .. final_path .. " (disk/permissions issue?)"
  end
  r.SetMediaItemTake_Source(final_take, new_src)

  -- Full source extent then crop to original window
  r.SetMediaItemInfo_Value(final_item, "D_POSITION", src_start_on_timeline)
  r.SetMediaItemInfo_Value(final_item, "D_LENGTH",   src_len_in_project)
  r.SetMediaItemTakeInfo_Value(final_take, "D_STARTOFFS", 0.0)
  r.SetMediaItemTakeInfo_Value(final_take, "D_PLAYRATE",  1.0)
  r.SetMediaItemInfo_Value(final_item, "D_POSITION", item_pos)
  r.SetMediaItemInfo_Value(final_item, "D_LENGTH",   item_len)
  r.SetMediaItemTakeInfo_Value(final_take, "D_STARTOFFS", take_offset)

  -- Restore take properties
  r.SetMediaItemTakeInfo_Value(final_take, "D_PAN",  snap.take_pan)
  r.SetMediaItemTakeInfo_Value(final_take, "B_MUTE", snap.take_mute)

  -- Restore item properties
  r.SetMediaItemInfo_Value(final_item, "B_MUTE",         snap.item_mute)
  r.SetMediaItemInfo_Value(final_item, "D_FADEINLEN",    snap.fadein_len)
  r.SetMediaItemInfo_Value(final_item, "D_FADEOUTLEN",   snap.fadeout_len)
  r.SetMediaItemInfo_Value(final_item, "D_FADEINDIR",    snap.fadein_dir)
  r.SetMediaItemInfo_Value(final_item, "D_FADEOUTDIR",   snap.fadeout_dir)
  r.SetMediaItemInfo_Value(final_item, "C_FADEINSHAPE",  snap.fadein_shape)
  r.SetMediaItemInfo_Value(final_item, "C_FADEOUTSHAPE", snap.fadeout_shape)

  r.UpdateItemInProject(final_item)
  r.DeleteTrack(tmp_track)
  r.Undo_OnStateChangeEx("Bake Take FX (full length)", -1, -1)

  return nil -- success
end



local function main()
  local n_sel = r.CountSelectedMediaItems(0)
  if n_sel == 0 then
    r.ShowMessageBox("No items selected.", "Bake Take FX – Full Length", 0)
    return
  end

  local items = {}
  for i = 0, n_sel - 1 do
    items[#items + 1] = r.GetSelectedMediaItem(0, i)
  end

  local errors = {}
  for i, item in ipairs(items) do
    local err = bake_item(item)
    if err then
      local take = r.GetActiveTake(item)
      local label = take and r.GetTakeName(take) or ("item " .. i)
      errors[#errors + 1] = label .. ": " .. err
    end
  end



  r.UpdateArrange()
  r.Main_OnCommand(40104, 0) -- build peaks for new files



  if #errors > 0 then
    local lines = { "Bake Take FX – " .. #errors .. " item(s) skipped:\n" }
    for _, e in ipairs(errors) do
      lines[#lines + 1] = "• " .. e
    end
    r.ShowConsoleMsg(table.concat(lines, "\n") .. "\n")
  end
end

main()
