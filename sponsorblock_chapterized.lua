-- SponsorBlock Chapterized (mpv Lua)
--
-- Turns SponsorBlock skip data into mpv chapters, and auto-skips those
-- segments during playback. A segment lives in the chapter list as
-- "[SponsorBlock]: <category>" chapters; rebuilding segment_cache from those
-- chapters is what drives the skipping (see rebuild_segment_cache).
--
-- Two data sources:
--   • local files – SponsorBlock chapters baked into the media itself
--     (no network involved); only nearby-boundary deduplication is applied
--   • YouTube – fresh data from a ytdl_hook hook result or the SponsorBlock
--     server (curl fallback); that data is merged into the existing chapters
--
-- Flow: file_loaded → fetch/parse → rebuild chapter list → activate_sponsorblock
--       → observe "chapter" property → skip_current_chapter seeks past segments

local mp = require 'mp'
-- Configuration loader and utilities
local opt = require 'mp.options'
local utils = require 'mp.utils'
local msg = require 'mp.msg'

-- Global state for the current media.
local enabled = false        -- whether auto-skip is enabled right now
local sponsor_data = nil     -- raw segments from the API or ytdl hook
local segment_cache = {}     -- {start, end, category, start_idx, end_idx}, rebuilt
                             -- from chapter_list (rebuild_segment_cache); the
                             -- actual source of truth for the skip logic
local chapter_list = {}      -- mpv's chapter list as it is being maintained
local duration = 0           -- media duration in seconds

-- Options (configurable via config file under this script's name)
local options = {
    server = "https://sponsor.ajay.app/api/skipSegments",
    categories = "",
    show_only_cats = "",
    hash = "",
    show_msg_duration = 3,
    uosc_button = true,
    use_ucm_plugin = true,
    show_sponsor_count = true,
    button_enabled_icon = "shield",
    button_disabled_icon = "remove_moderator",
    button_tooltip = "Sponsorblock",
    skip_unknown = false,
    min_segment_length = 1,
    time_tolerance = 0.1, -- Used for segment boundary checks and chapter time matching
    nearby_merge_tolerance = 2, -- Tolerance for folding nearby chapters into segment boundaries
    use_curl_fallback = true,
}

opt.read_options(options, mp.get_script_name())

-- URL formats the video ID can be pulled from: ytdl_hook hook paths and
-- plain YouTube links (see extract_youtube_id, which also checks the
-- Referer header and PURL metadata).
local yt_patterns = {
    "ytdl://youtu%.be/([%w-_]+)",
    "ytdl://w?w?w?%.?youtube%.com/v/([%w-_]+)",
    "https?://youtu%.be/([%w-_]+)",
    "https?://w?w?w?%.?youtube%.com/v/([%w-_]+)",
    "/watch.*[?&]v=([%w-_]+)",
    "/embed/([%w-_]+)",
    "^ytdl://([%w-_]+)$",
    "%[([%w-_]+)%]%.",
}

-- Command string the UOSC button runs (sent to this script).
local button_command = "script-message sponsorblock toggle"
local num_seg_found -- segment count shown as the button badge; nil before first scan

-- Turns a comma-separated option into the quoted list the API expects,
-- e.g. "sponsor, selfpromo" → '"sponsor","selfpromo"'.
local function parsed_cats(cats_to_parse)
    if cats_to_parse == "" then return "" end
    local cats = {}
    for cat in cats_to_parse:gsub('%s', ''):gmatch('[^,]+') do
        table.insert(cats, '"' .. cat .. '"')
    end
    return table.concat(cats, ",")
end

-- Set-membership lookups, built once from the options and keyed by
-- lowercase name with underscores replaced by spaces (the same normalization
-- get_actionable_segment applies to segment categories):
--   show_only_lookup     – mark-only categories: shown as chapters, never skipped
--   skip_categories_lookup – categories that are actively skipped
local show_only_lookup = {}
for cat in options.show_only_cats:gsub('%s', ''):gmatch('[^,]+') do
    show_only_lookup[string.lower(cat:gsub('_', ' '))] = true
end
local skip_cats_lookup = {}
for cat in options.categories:gsub('%s', ''):gmatch('[^,]+') do
    skip_cats_lookup[string.lower(cat:gsub('_', ' '))] = true
end

-- Returns the category name of a SponsorBlock chapter title
-- ("[SponsorBlock]: <category>", with or without extra quotes), else false.
-- This is the core "is this chapter an SB boundary?" test used everywhere.
local function match_cat(title)
    msg.trace("match_category", title, "-", title:match('^"?%[SponsorBlock%]: (.-)\"?$') or false)
    return title and title:match('^"?%[SponsorBlock%]: (.-)\"?$') or false
end

local function is_youtube()
    local path = mp.get_property("path", "")
    for _, pattern in ipairs(yt_patterns) do
        if path:match(pattern) then return true end
    end
    return false
end
local function is_local_file()
    local path = mp.get_property("path", "")
    return path:match("^/") or path:match("^[A-Za-z]:\\")
end

-- Syncs the status button with current state (enabled/disabled icon,
-- segment-count badge). Talks to the ucm minimal plugin or UOSC depending
-- on the use_ucm_plugin option. This is the visual indicator only; the
-- 'b' keybinding is what actually toggles skipping.
local function update_button()
    if not options.uosc_button then return end
    -- if not enabled then return end
    num_seg_found = #segment_cache
    if options.use_ucm_plugin then
        mp.commandv('script-message-to', 'ucm_sponsorblock_minimal_plugin', 'update-button', tostring(enabled), tostring(num_seg_found))
        return
    end

    local button = {
        icon = enabled and options.button_enabled_icon or options.button_disabled_icon,
        badge = options.show_sponsor_count and num_seg_found or nil,
        tooltip = options.button_tooltip,
        command = button_command,
        hide = false
    }
    mp.commandv('script-message-to', 'uosc', 'set-button', 'Sponsorblock_Button', utils.format_json(button))
end

-- Clears the button (called on script init for the idle screen and at the
-- start of every file load, before data is known).
local function hide_button()
    if not options.uosc_button then return end
    if options.use_ucm_plugin then
        mp.commandv('script-message-to', 'ucm_sponsorblock_minimal_plugin', 'update-button', 'false', '0')
        return
    end
    mp.commandv('script-message-to', 'uosc', 'set-button', 'Sponsorblock_Button', utils.format_json({icon = "", hide = true}))
end

--MARK: Segment cache
--
-- Derives segment_cache from the chapters: each "[SponsorBlock]:" chapter
-- starts a segment, and the *next* chapter's time is that segment's end
-- (or the end of the file for the last chapter). segment_cache is what the
-- skip logic and the button badge read, so it must be rebuilt every time the
-- chapter list changes shape.
local function rebuild_segment_cache()
    segment_cache = {}
    num_seg_found = 0

    for i, chapter in ipairs(chapter_list) do
        local cat = match_cat(chapter.title)
        if cat then
            local next_chapter = chapter_list[i + 1]
            local end_time = next_chapter and next_chapter.time or duration - 0.001

            -- Check for valid segment
            if end_time > chapter.time then
                table.insert(segment_cache, {
                    start = chapter.time,
                    ['end'] = end_time,
                    category = cat,
                    start_idx = i,
                    end_idx = next_chapter and (i + 1) or nil,
                })
                num_seg_found = num_seg_found + 1
            end
        end
    end

    -- Log the rebuilt segments for debugging, and report whether anything was found.
    msg.info("segment_cache: " .. #segment_cache .. " segments"); for _, seg in ipairs(segment_cache) do msg.info("  " .. seg.category .. " [" .. seg.start .. " -> " .. seg["end"] .. "]"); end; return num_seg_found > 0
end

--MARK: Chapter merging
--
-- One merge function for both local and YouTube paths, implementing the
-- original "subsume" semantics: a normal chapter that lands within
-- nearby_merge_tolerance of a segment boundary is folded into that boundary
-- instead of producing a duplicate adjacent chapter.
--   * start: the nearby normal is replaced by the SB start chapter (which
--            keeps the SB time, so the segment cache / skip logic stays
--            accurate); the replaced title is carried over to the segment's
--            end chapter.
--   * end:   the normal nearest the segment end becomes that end (kept at its
--            own time); no separate end chapter is synthesized, and any other
--            normal clustering within tolerance of the same end is dropped as
--            a drift duplicate.
--   * else:  the end is synthesized at the segment end, borrowing the nearest
--            earlier normal title (fallback: the media title).

-- Derive segments from the SB chapters already baked into a local file: each
-- "[SponsorBlock]:" chapter starts a segment and the *next* chapter's time is
-- that segment's end (or the end of the file for the last chapter).
local function build_segments_local()
    local segs = {}
    for i, ch in ipairs(chapter_list) do
        local cat = match_cat(ch.title)
        if cat then
            local next_ch = chapter_list[i + 1]
            local end_t = next_ch and next_ch.time or duration - 0.001
            if end_t > ch.time then
                table.insert(segs, {start = ch.time, ['end'] = end_t, category = cat})
            end
        end
    end
    return segs
end

-- Build normalized, deduped, overlap-resolved segments from fresh sponsor_data.
local function build_segments_data()
    if not sponsor_data then return {} end
    local segs = {}
    for _, segment in pairs(sponsor_data) do
        if segment.segment and segment.segment[1] and segment.segment[2] then
            if segment.segment[2] - segment.segment[1] > options.min_segment_length then
                table.insert(segs, {
                    start = segment.segment[1],
                    ['end'] = segment.segment[2],
                    category = string.lower(segment.category):gsub('_', ' '),
                })
            end
        end
    end
    -- Drop near-identical duplicates (within 0.5s on both ends).
    for i = #segs, 2, -1 do
        for j = i - 1, 1, -1 do
            if math.abs(segs[i].start - segs[j].start) <= 0.5 and
               math.abs(segs[i]['end'] - segs[j]['end']) <= 0.5 then
                table.remove(segs, i)
                break
            end
        end
    end
    table.sort(segs, function(a, b) return a.start < b.start end)
    -- Overlapping segments: keep the wider one.
    local out = {}
    for _, seg in ipairs(segs) do
        if #out == 0 then
            table.insert(out, seg)
        else
            local last = out[#out]
            if seg.start < last['end'] then
                if seg['end'] - seg.start > last['end'] - last.start then
                    out[#out] = seg
                end
            else
                table.insert(out, seg)
            end
        end
    end
    return out
end

-- The unified merge. Rebuilds chapter_list from the non-SB chapters and the
-- given segments, subsuming nearby chapters into the segment boundaries.
local function merge_chapters(final_segments)
    -- The non-SB chapters are the base the segments fold into.
    local normals = {}
    for _, ch in ipairs(chapter_list) do
        if not match_cat(ch.title) then
            table.insert(normals, ch)
        end
    end
    table.sort(normals, function(a, b) return a.time < b.time end)

    local tol = options.nearby_merge_tolerance
    local default_title = mp.get_property("media-title") or "no title"
    local used = {}        -- index into normals: true = consumed/dropped
    local boundaries = {}  -- SB start + end chapters created here

    -- Nearest unconsumed normal within tol of t (index, or nil).
    local function nearest_normal(t)
        local best_i, best_d
        for i, ch in ipairs(normals) do
            if not used[i] then
                local d = math.abs(ch.time - t)
                if d <= tol and (not best_i or d < best_d) then
                    best_i, best_d = i, d
                end
            end
        end
        return best_i
    end

    for _, seg in ipairs(final_segments) do
        local end_title

        -- START: fold a nearby normal into the SB start (SB keeps its time).
        local s_i = nearest_normal(seg.start)
        if s_i then
            used[s_i] = true
            end_title = normals[s_i].title  -- carry the replaced title to the end
        end
        table.insert(boundaries, {title = "[SponsorBlock]: " .. seg.category, time = seg.start})

        -- END: the normal nearest the end becomes it; drop the rest of the cluster.
        local e_i = nearest_normal(seg['end'])
        if e_i then
            used[e_i] = true
            table.insert(boundaries, {title = end_title or normals[e_i].title, time = normals[e_i].time})
            for i, ch in ipairs(normals) do
                if not used[i] and math.abs(ch.time - seg['end']) <= tol then
                    used[i] = true
                end
            end
        else
            -- No normal at the end: synthesize one, borrowing a nearby title.
            local title = end_title or default_title
            local best
            for i, ch in ipairs(normals) do
                if ch.time < seg['end'] then
                    if not best or ch.time > best.time then
                        best = ch
                    end
                end
            end
            if best and not end_title then
                title = best.title
            end
            table.insert(boundaries, {title = title, time = seg['end']})
        end
    end
    -- Drop normals that fall strictly inside a segment: these are the
    -- uploader's own "sponsor"/"ad" chapters, redundant with the SB
    -- boundary (documented behavior). Fold already consumed near-boundary
    -- normals within nearby_merge_tolerance; this clears the interior.
    for i, ch in ipairs(normals) do
        if not used[i] then
            for _, seg in ipairs(final_segments) do
                if ch.time > seg.start + options.time_tolerance and ch.time < seg['end'] - options.time_tolerance then
                    used[i] = true
                    break
                end
            end
        end
    end

    -- Compose: remaining normals + boundary chapters, sorted by time.
    chapter_list = {}
    for i, ch in ipairs(normals) do
        if not used[i] then
            table.insert(chapter_list, ch)
        end
    end
    for _, b in ipairs(boundaries) do
        table.insert(chapter_list, b)
    end
    table.sort(chapter_list, function(a, b) return a.time < b.time end)

    rebuild_segment_cache()
end

--MARK: Auto-skip
--
-- Returns the segment that should be skipped for the given playback position,
-- or nil. Classification of the segment's category:
--   • in show_only_cats → mark-only, never skipped (returned nil)
--   • in categories      → skipped
--   • unknown            → skipped only if skip_unknown is enabled
local function get_actionable_segment(start_time, chapter_index)
    local segment
    for i, range in ipairs(segment_cache) do
        -- Subtract a tiny amount to avoid edge-case matching at exact segment end boundary
        if range.start <= start_time and (start_time < (range['end'] - 0.0005)) then
            segment = range
            break
        end
    end
    if not segment then return nil end

    -- Normalize the category the same way the lookup tables were keyed.
    local cat_lower = string.lower(segment.category):gsub('_', ' ')
    if show_only_lookup[cat_lower] then
        msg.debug("Sponsorblock: not skipping mark-only segment: ", segment.category)
        return nil -- Don't skip, just mark
    elseif skip_cats_lookup[cat_lower] then
        mp.osd_message(("[sponsorblock] skipping %s"):format(segment.category), options.show_msg_duration)
        msg.info("Sponsorblock: Skipping chapter:", chapter_index, "(" .. segment.category .. ")")
        return segment -- Should be skipped
    else
        msg.debug("Sponsorblock: unknown segment: ", segment.category)
        return options.skip_unknown and segment or nil
    end
end

-- Debounce state: a small ring of recent skip timestamps so the same spot
-- can't be skipped in a tight loop (e.g. when playback is stuck at a segment
-- boundary or the user is dragging over it).
local skip_times = {0, 0, 0, 0, 0}
local skip_index = 1
local last_skip_position = -1

-- Invoked on every chapter change while enabled. If the chapter's time falls
-- inside an actionable segment, seeks just past the segment's end.
local function skip_current_chapter()
    if not enabled then return end

    local cur_chapter_index = mp.get_property_number("chapter")
    if not cur_chapter_index or cur_chapter_index < 0 then return end

    -- Read the chapter's start time directly (segment_cache only holds
    -- boundary times, this is the actual playback position we're testing).
    local chapter_time = mp.get_property_number("chapter-list/"..cur_chapter_index.."/time")
    if not chapter_time then return end

    local segment = get_actionable_segment(chapter_time, cur_chapter_index)
    if not segment then return end

    -- Debounce: if we're being asked to skip (nearly) the same position again,
    -- only allow it if the oldest of the last 5 attempts is >0.2s old –
    -- i.e. five rapid attempts at one spot are ignored. A genuinely new
    -- position always skips.
    local now = mp.get_time()

    if math.abs(chapter_time - last_skip_position) < 0.5 then
        -- Same position as last skip attempt - debounce check
        skip_times[skip_index] = now
        skip_index = skip_index % 5 + 1

        local oldest = skip_times[skip_index]
        if now - oldest < 0.2 then
            return -- Too many rapid attempts at this position, debounce
        end
    end

    -- New position or not debounced: seek just past the segment end (with a
    -- small overshoot, and clamped so we can't run past the end of the media).
    last_skip_position = chapter_time
    local skip_to = math.min(segment['end'] + 0.01, duration - 0.1)
    mp.set_property("time-pos", skip_to)
end

-- Toggles auto-skip. Wired to the forced 'b' keybinding (activate_sponsorblock);
-- enabling it also starts observing the chapter property, disabling stops it.
local function toggle()
    if enabled then
        msg.info("Turning off sponsorblock")
        mp.unobserve_property(skip_current_chapter)
        mp.osd_message("[sponsorblock] off")
        enabled = false
    else
        msg.info("Turning on sponsorblock")
        mp.observe_property("chapter", "number", skip_current_chapter)
        mp.osd_message("[sponsorblock] on")
        enabled = true
    end
    update_button()
end

-- Final activation, called from file_loaded and the manual re-pull script
-- message.
--   merge truthy  → build segments from fresh sponsor_data (YouTube path)
--   merge falsy   → derive segments from the SB chapters already in the file (local)
-- Afterwards the modified chapter list is written back to mpv, the chapter
-- property is observed, and the forced 'b' keybinding becomes active.
local function activate_sponsorblock(merge)
    duration = mp.get_property_native("duration") or 0

    local segments
    if merge then
        segments = build_segments_data()
    else
        segments = build_segments_local()
    end
    merge_chapters(segments)

    -- Publish the result to mpv.
    mp.set_property_native("chapter-list", chapter_list)

    enabled = true
    update_button()
    mp.observe_property("chapter", "number", skip_current_chapter)
    mp.add_forced_key_binding("b","sponsorblock", toggle)
end

--MARK: Data fetching
--
-- Extracts the 11-character YouTube video ID. Tries the media path first,
-- then the HTTP Referer header, then PURL metadata – in that order – because
-- different ytdl_hook setups expose the URL in different places.
local function extract_youtube_id()
    local video_path = mp.get_property("path", "")
    msg.debug("Sponsorblock: video_path:", video_path)
    local video_referer = mp.get_property("http-header-fields", ""):match("Referer:([^,]+)") or ""
    if video_referer ~= "" then msg.debug("Sponsorblock: video_referer:", video_referer) end
    local purl = mp.get_property("metadata/by-key/PURL", "")
    if purl ~= "" then msg.debug("Sponsorblock: purl:", purl) end

    for _, pattern in ipairs(yt_patterns) do
        local id = video_path:match(pattern) or video_referer:match(pattern)
        msg.trace("Sponsorblock: id:", id, "pattern:", pattern)
        if not id then
            id = purl:match(pattern)
        end
        -- Some sources (e.g. query strings) append extra data after the ID; a
        -- real ID is exactly 11 characters, so we truncate.
        if id and #id >= 11 then
            return id:sub(1, 11)
        end
    end
    msg.debug("Sponsorblock: no id found")
    return nil
end

-- Reads SponsorBlock chapters out of the ytdl_hook subprocess result
-- (sponsorblock_chapters). Only works when the hook was configured with
-- sponsorblock-mark=all – see the ytdl-raw-options injection at the bottom of
-- this file.
local function extract_sponsorskip_data()
    local json_results = mp.get_property_native("user-data/mpv/ytdl/json-subprocess-result")
    if not json_results then return false end
    local stdout_value = json_results["stdout"]
    local raw_data = utils.parse_json(stdout_value)["sponsorblock_chapters"]
    if not raw_data then return false end
    sponsor_data = {}
    for _, dataset in ipairs(raw_data) do
        table.insert(sponsor_data, {
            segment = {dataset["start_time"], dataset["end_time"]},
            category = dataset["category"]
        })
    end
    return true
end

-- Fallback: query the SponsorBlock server directly via curl.
-- The categories parameter includes both skip and mark-only categories so
-- mark-only segments also show up as chapters (they just never get skipped,
-- see get_actionable_segment).
-- Hash mode (options.hash = "true"): instead of the video ID, query
-- /{first 4 chars of sha256(id)} and match the response entry by videoID.
local function pull_sponsorskip_data()
    local youtube_id = extract_youtube_id()
    if not youtube_id then return false end
    msg.debug("Sponsorblock: found youtube_id:", youtube_id)

    local cats_str = parsed_cats(options.categories)
    if options.show_only_cats ~= "" then
        local show_only_str = parsed_cats(options.show_only_cats)
        cats_str = cats_str ~= "" and (cats_str .. "," .. show_only_str) or show_only_str
    end

    local args = {"curl", "-L", "-s", "-G", "--data-urlencode", ("categories=[%s]"):format(cats_str)}
    local url = options.server

    -- Hash mode: derive the lookup key from the video ID
    if options.hash == "true" then
        local sha_result = mp.command_native{
            name = "subprocess",
            capture_stdout = true,
            args = {"sha256sum"},
            stdin_data = youtube_id
        }
        if sha_result.stdout then
            url = ("%s/%s"):format(url, sha_result.stdout:sub(1, 4))
        else
            msg.error("Failed to generate SHA256 hash")
            return false
        end
    else
        table.insert(args, "--data-urlencode")
        table.insert(args, "videoID=" .. youtube_id)
    end
    table.insert(args, url)

    local result = mp.command_native{
        name = "subprocess",
        capture_stdout = true,
        playback_only = false,
        timeout = 10,
        args = args,
    }
    if not result or not result.stdout then return false end
    local json = utils.parse_json(result.stdout)

    if type(json) ~= "table" then return false end

    -- Hash mode returns a list; pick the entry whose videoID matches.
    if options.hash == "true" then
        for _, i in pairs(json) do
            if i.videoID == youtube_id then
                sponsor_data = i.segments
                return true
            end
        end
        return false
    else
        if not json[1] or json[1] == "No valid categories provided." then return false end
        sponsor_data = json
        return true
    end
end

--MARK: Entry point
--
-- Runs on every file load. Resets all state, then branches on the media:
--   • local file → usable only if SB chapters are baked in (merge=false)
--   • YouTube    → ytdl hook result, falling back to a server pull (merge=true)
--   • anything else → abort
local function file_loaded()
    msg.debug("Sponsorblock: file_loaded")
    -- Reset everything from the previous media, including the 'b' keybinding.
    mp.remove_key_binding("sponsorblock")
    sponsor_data = nil
    enabled = false
    segment_cache = {}
    num_seg_found = nil
    hide_button()
    duration = mp.get_property_native("duration") or 0
    chapter_list = mp.get_property_native("chapter-list", {})
    if is_local_file() then
        msg.debug("Sponsorblock: Local file detected, trying to extract segments from local file")
        local function find_baked_cat()
            for i, chapter in ipairs(chapter_list) do
                local category = match_cat(chapter.title)
                if category then
                    msg.debug("Sponsorblock: found local chapter", i, chapter.title)
                    return category
                end
            end
        end

        -- Local files have no server data source: either the file carries SB
        -- chapters or there's nothing to do.
        if find_baked_cat() then
            msg.info("Sponsorblock: Using local segments")
            activate_sponsorblock(false)
            return
        else
            msg.debug("Sponsorblock: Local file but no local segments found")
            return
        end
    elseif is_youtube() then
        msg.debug("Sponsorblock: Trying to extract sponsorblock data from ytdl hook property")
        local result = extract_sponsorskip_data()
        if not result and options.use_curl_fallback then
            msg.debug("Sponsorblock: ytdl hook returned no data, falling back to server")
            result = pull_sponsorskip_data()
        end
        if not result then
            msg.debug("Sponsorblock: Failed to get data (ytdl hook and fallback both returned nothing)")
            return
        end
    else
        msg.debug("Sponsorblock: Not a youtube stream, aborting")
        return
    end
    msg.info("Sponsorblock: blockable chapters found, engaging Skipdrive")
    -- Fresh data (YouTube path): merge it into the existing chapters.
    activate_sponsorblock(true)
end

--MARK: Registration
mp.register_event("file-loaded", file_loaded)

-- Script message: re-pulls data on demand:
--   • local file with baked-in SB chapters → fresh server data replaces the
--     old segments (SB chapters are rebuilt from the fresh data).
--     The video ID must be in the path (e.g. [videoid].ext).
--   • YouTube stream that loaded before any sponsor data existed (fresh
--     release) → pull again once the data exists.
mp.register_script_message('manual_sponsorblock_pull', function()
    sponsor_data = nil
    enabled = false
    segment_cache = {}
    num_seg_found = nil
    msg.info("Sponsorblock: Manual trigger to pull data from server")
    local result = pull_sponsorskip_data()
    if not result then
        msg.debug("Sponsorblock: Failed to pull data from server (or no data for the video found), aborting")
        return
    end
    activate_sponsorblock(true)
end)

-- Tell ytdl_hook to emit SponsorBlock chapters (sponsorblock-mark=all) in its
-- subprocess result; extract_sponsorskip_data() reads them from there.
local opts = mp.get_property_native("ytdl-raw-options") or {}
opts["sponsorblock-mark"] = "all"
mp.set_property_native("ytdl-raw-options", opts)

-- Clear the button on script init so it's not shown over the idle screen.
hide_button()
