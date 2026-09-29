local mp = require 'mp'
local opt = require 'mp.options'
local utils = require 'mp.utils'
local msg = require 'mp.msg'

local ON = false
local sponsor_data = nil
local segment_cache = {} -- Array of {start, end, category, start_idx, end_idx}
local chapter_list = {}
local duration = 0
local keep_local_segments = false

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
    nearby_merge_tolerance = 2, -- Tolerance for merge_nearby_chapters (deduping close chapters in local files)
    use_curl_fallback = true,
}

opt.read_options(options, mp.get_script_name())

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

local button_command = "script-message sponsorblock toggle"
local num_seg_found

--MARK: Helper functions
-- Helper function to process category names consistently
local function process_category(cat)
    return cat:gsub("^%l", string.upper):gsub("_", " ")
end

local function parsed_categories(cats_to_parse)
    if cats_to_parse == "" then return "" end
    local cats = {}
    for cat in cats_to_parse:gsub('%s', ''):gmatch('[^,]+') do
        table.insert(cats, '"' .. cat .. '"')
    end
    return table.concat(cats, ",")
end

-- Build show_only lookup table once with processed category names
local show_only_lookup = {}
for cat in options.show_only_cats:gsub('%s', ''):gmatch('[^,]+') do
    show_only_lookup[string.lower(cat:gsub('_', ' '))] = true
end
local cats_lookup = {}
for cat in options.categories:gsub('%s', ''):gmatch('[^,]+') do
    cats_lookup[string.lower(cat:gsub('_', ' '))] = true
end

local function match_category(title)
    msg.trace("match_category", title, "-", title:match('^"?%[SponsorBlock%]: (.-)\"?$') or false)
    return title and title:match('^"?%[SponsorBlock%]: (.-)\"?$') or false
end

-- Find chapter index by time (with tolerance)
local function find_chapter_by_time(time, tolerance)
    tolerance = tolerance or 0.5
    for i, chapter in ipairs(chapter_list) do
        if math.abs(chapter.time - time) <= tolerance then
            return i
        end
    end
    return nil
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

local function update_button()
    if not options.uosc_button then return end
    -- if not ON then return end
    num_seg_found = #segment_cache
    if options.use_ucm_plugin then
        mp.commandv('script-message-to', 'ucm_sponsorblock_minimal_plugin', 'update-button', tostring(ON), tostring(num_seg_found))
        return
    end
    
    local button = {
        icon = ON and options.button_enabled_icon or options.button_disabled_icon,
        badge = options.show_sponsor_count and num_seg_found or nil,
        tooltip = options.button_tooltip,
        command = button_command,
        hide = false
    }
    mp.commandv('script-message-to', 'uosc', 'set-button', 'Sponsorblock_Button', utils.format_json(button))
end

local function hide_button()
    if not options.uosc_button then return end
    if options.use_ucm_plugin then
        mp.commandv('script-message-to', 'ucm_sponsorblock_minimal_plugin', 'update-button', 'false', '0')
        return
    end
    mp.commandv('script-message-to', 'uosc', 'set-button', 'Sponsorblock_Button', utils.format_json({icon = "", hide = true}))
end

-- Rebuild segment_cache from chapter_list (source of truth)
-- This ensures consistency after any modifications
--MARK: segment cache
local function rebuild_segment_cache()
    segment_cache = {}
    num_seg_found = 0
    
    for i, chapter in ipairs(chapter_list) do
        local category = match_category(chapter.title)
        if category then
            local next_chapter = chapter_list[i + 1]
            local end_time = next_chapter and next_chapter.time or duration - 0.001
            
            -- Check for valid segment
            if end_time > chapter.time then
                table.insert(segment_cache, {
                    start = chapter.time,
                    ['end'] = end_time,
                    category = category,
                    start_idx = i,
                    end_idx = next_chapter and (i + 1) or nil,
                })
                num_seg_found = num_seg_found + 1
            end
        end
    end
    
    msg.info("segment_cache: " .. #segment_cache .. " segments"); for _, seg in ipairs(segment_cache) do msg.info("  " .. seg.category .. " [" .. seg.start .. " -> " .. seg["end"] .. "]"); end; return num_seg_found > 0
end

-- Find or create chapter at time (with tolerance matching)
--MARK: find or create ch
local function find_or_create_chapter(time, title, tolerance)
    tolerance = tolerance or options.time_tolerance
    
    -- First, try to find existing chapter within tolerance
    local idx = find_chapter_by_time(time, tolerance)
    
    if idx then
        local existing = chapter_list[idx]
        -- If we're adding a SponsorBlock chapter, replace normal chapter
        if title and match_category(title) and not match_category(existing.title) then
            chapter_list[idx] = {title = title, time = time}
            return idx
        end
        -- Both SB or both normal: keep existing
        return idx
    end
    
    -- Create new chapter at correct position
    local insert_pos = #chapter_list + 1
    for i, chapter in ipairs(chapter_list) do
        if chapter.time > time then
            insert_pos = i
            break
        end
    end
    
    table.insert(chapter_list, insert_pos, {title = title, time = time})
    return insert_pos
end

-- Merge baked-in segments with fresh segments
-- Called for local segments to merge overlapping chapter boundaries
local function merge_nearby_chapters()
    -- Sort by time
    table.sort(chapter_list, function(a, b) return a.time < b.time end)

    for i = #chapter_list, 2, -1 do
        local curr = chapter_list[i]
        local prev = chapter_list[i - 1]
        if math.abs(curr.time - prev.time) <= options.nearby_merge_tolerance then
            -- Both are SponsorBlock: keep both (distinct segment boundaries)
            if match_category(curr.title) and match_category(prev.title) then
                -- Do nothing: both are segment boundaries, keep them
            -- SB + normal (SB is curr): remove SB if it's a segment END
            elseif match_category(curr.title) and not match_category(prev.title) then
                if match_category(chapter_list[i + 1] and chapter_list[i + 1].title) then
                    -- curr is segment START: keep it, remove normal prev
                    table.remove(chapter_list, i - 1)
                else
                    -- curr is segment END: remove it (subsume into normal)
                    table.remove(chapter_list, i)
                end
            -- Normal + SB (normal is curr, SB is prev): keep both
            -- (normal chapter after SB should not be subsumed into SB boundary)
            elseif not match_category(curr.title) and match_category(prev.title) then
                -- Do nothing: keep both chapters
            -- Both normal: remove duplicate
            else
                if curr.title == prev.title then
                    table.remove(chapter_list, i)
                end
            end
        end
    end
end
--MARK: merge segments
local function merge_segments()
    -- clean up in case there were local ones and the user manual sponsorblock pulled
    for i, chapter in ipairs(chapter_list) do
        local category = match_category(chapter.title)
        if category then
            table.remove(chapter_list, i)
        end
    end

    if not sponsor_data then return end
    -- Build fresh segments from API

    msg.debug("Sponsorblock: sponsor_data:", utils.to_string(sponsor_data))

    local fresh_segments = {}
    for _, segment in pairs(sponsor_data) do
        -- Guard: skip segments with missing end to prevent nil cascade
        if not segment.segment or not segment.segment[1] or not segment.segment[2] then
            msg.debug("Sponsorblock: skipping invalid segment entry:", segment)
        else
            local delta = segment.segment[2] - segment.segment[1]
            if delta > options.min_segment_length then
                table.insert(fresh_segments, {
                    start = segment.segment[1],
                    ['end'] = segment.segment[2],
                    category = string.lower(segment.category):gsub('_', ' '),
                })
            end
        end
    end

    -- Remove duplicates (same start and end within tolerance)
    for i = #fresh_segments, 2, -1 do
        for j = i - 1, 1, -1 do
            if math.abs(fresh_segments[i].start - fresh_segments[j].start) <= 0.5 and
               math.abs(fresh_segments[i]['end'] - fresh_segments[j]['end']) <= 0.5 then
                table.remove(fresh_segments, i)
                break
            end
        end
    end
    
    -- Sort by start time
    table.sort(fresh_segments, function(a, b) return a.start < b.start end)

    -- Handle overlaps
    local final_segments = {}
    for _, seg in ipairs(fresh_segments) do
        if #final_segments == 0 then
            table.insert(final_segments, seg)
        else
            local last = final_segments[#final_segments]
            if seg.start < last['end'] then
                if seg['end'] - seg.start > last['end'] - last.start then
                    final_segments[#final_segments] = seg
                end
            else
                table.insert(final_segments, seg)
            end
        end
    end
    
    -- Preserve non-SponsorBlock chapters, rebuild SponsorBlock ones
    local preserved_chapters = {}
    for _, chapter in ipairs(chapter_list) do
        -- Drop chapters that fall inside a segment (not at boundaries)
        -- avoids leftover uploader chapters marking sponsor/ad content
        local inside_segment = false
        for _, seg in ipairs(final_segments) do
            if chapter.time > seg.start + options.time_tolerance and
               chapter.time < seg['end'] - options.time_tolerance then
                inside_segment = true
                msg.debug("Sponsorblock: inside segment found, assuming youtuber marked sponsor/add chapter:", chapter.title)
                break
            end
        end
        if not inside_segment then
            table.insert(preserved_chapters, chapter)
        end
    end
    
    -- Create new chapter list with preserved chapters + SponsorBlock segments
    chapter_list = {}
    
    -- Add all preserved chapters
    for _, chapter in ipairs(preserved_chapters) do
        table.insert(chapter_list, chapter)
    end
    
    -- Add SponsorBlock segment chapters
    local default_title = mp.get_property("media-title") or "no title"
    
    -- Track which preserved chapters we've used as end boundaries (to avoid duplicates)
    local used_preserved_as_end = {}
    
    for _, seg in ipairs(final_segments) do
        -- Add start chapter
        local start_chapter = {title = "[SponsorBlock]: " .. seg.category, time = seg.start}
        table.insert(chapter_list, start_chapter)
        
        -- Add end chapter
        -- First, check if there's a preserved chapter at the exact end time (within small tolerance)
        local end_chapter = nil
        local found_preserved = false
        local small_tol = 0.001
        for i, preserved in ipairs(preserved_chapters) do
            if not used_preserved_as_end[i] and math.abs(preserved.time - seg['end']) <= small_tol then
                -- Use the preserved chapter as the end boundary - don't create duplicate
                -- Mark it as used so we don't use it again
                used_preserved_as_end[i] = true
                found_preserved = true
                -- Don't add a duplicate - the preserved chapter is already in chapter_list
                break
            end
        end
        
        if not found_preserved then
            -- Create new end chapter and restore title from nearest previous chapter
            end_chapter = {title = default_title, time = seg['end']}
            
            -- Find the nearest previous non-SponsorBlock chapter (by time, not array order)
            local nearest_chapter = nil
            local nearest_time = -1
            
            -- Check already-added chapters in chapter_list
            for _, prev in ipairs(chapter_list) do
                if prev.time < seg['end'] and prev.title and not match_category(prev.title) then
                    if prev.time > nearest_time then
                        nearest_time = prev.time
                        nearest_chapter = prev
                    end
                end
            end
            
            -- Also check preserved chapters (in case they weren't added yet)
            for _, preserved in ipairs(preserved_chapters) do
                if preserved.time < seg['end'] and not match_category(preserved.title) then
                    if preserved.time > nearest_time then
                        nearest_time = preserved.time
                        nearest_chapter = preserved
                    end
                end
            end
            
            if nearest_chapter then
                end_chapter.title = nearest_chapter.title
            end
            
            table.insert(chapter_list, end_chapter)
        end
    end
    
    -- Sort by time
    table.sort(chapter_list, function(a, b) return a.time < b.time end)
    
    local function is_segment_boundary(prev, curr)
        -- Check if these are the start/end of the same segment
        -- A segment's own start and end should never be merged
        local small_tol = 0.01  -- Small tolerance for floating point comparison
        for _, seg in ipairs(final_segments) do
            if (math.abs(prev.time - seg.start) <= small_tol and math.abs(curr.time - seg['end']) <= small_tol) or
               (math.abs(curr.time - seg.start) <= small_tol and math.abs(prev.time - seg['end']) <= small_tol) then
                return true
            end
        end
        return false
    end
    -- Now merge chapters that are very close together (within tolerance)
    -- This handles the baked-in vs fresh time differences
    -- BUT: Don't merge a segment's own start and end chapters
    for i = #chapter_list, 2, -1 do
        local curr = chapter_list[i]
        local prev = chapter_list[i - 1]
        
        if math.abs(curr.time - prev.time) <= options.time_tolerance then
            -- Never merge a segment's own boundaries
            if is_segment_boundary(prev, curr) then
                -- Keep both chapters - these are start/end of the same segment
            elseif match_category(curr.title) and not match_category(prev.title) then
                -- Replace prev with curr
                chapter_list[i - 1] = curr
                table.remove(chapter_list, i)
            elseif match_category(prev.title) and not match_category(curr.title) then
                -- Keep prev, remove curr
                table.remove(chapter_list, i)
            elseif match_category(curr.title) and match_category(prev.title) then
                -- Both are SponsorBlock: keep one, remove duplicate (but not if same segment)
                table.remove(chapter_list, i)
            else
                -- Both are normal: keep the one with better title or remove duplicate
                if curr.title == prev.title then
                    table.remove(chapter_list, i)
                end
            end
        end
    end
    
    -- Trace: dump merged chapter list
    rebuild_segment_cache()
end

--MARK: actionable segs
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
    
    -- Check if this segment's category is in show_only_cats
    local cat_lower = string.lower(segment.category):gsub('_', ' ')
    if show_only_lookup[cat_lower] then
        msg.debug("Sponsorblock: not skipping mark-only segment: ", segment.category)
        return nil -- Don't skip, just mark
    elseif cats_lookup[cat_lower] then
        mp.osd_message(("[sponsorblock] skipping %s"):format(segment.category), options.show_msg_duration)
        msg.info("Sponsorblock: Skipping chapter:", chapter_index, "(" .. segment.category .. ")")
        return segment -- Should be skipped
    else
        msg.debug("Sponsorblock: unknown segment: ", segment.category)
        return options.skip_unknown and segment or nil
    end
end

-- Track skip attempts per position for debouncing during seeking
local skip_times = {0, 0, 0, 0, 0}
local skip_index = 1
local last_skip_position = -1

--MARK: skip current ch
local function skip_current_chapter()
    if not ON then return end

    local cur_chapter_index = mp.get_property_number("chapter")
    if not cur_chapter_index or cur_chapter_index < 0 then return end
    
    -- Use segment_cache which has reliable start/end times
    local chapter_time = mp.get_property_number("chapter-list/"..cur_chapter_index.."/time")
    if not chapter_time then return end

    local segment = get_actionable_segment(chapter_time, cur_chapter_index)
    if not segment then return end

    -- Debounce: track attempts per position. If the chapter_time hasn't
    -- meaningfully changed since the last skip, we're likely being held
    -- in a segment by seek-bar dragging -- debounce after 5 attempts in 0.2s.
    -- Different chapter positions always skip (normal playback progression).
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

    -- New position or not debounced - skip it
    last_skip_position = chapter_time
    local skip_to = math.min(segment['end'] + 0.01, duration - 0.1)
    mp.set_property("time-pos", skip_to)
end

--MARK: toggle
local function toggle()
    if ON then
        msg.info("Turning off sponsorblock")
        mp.unobserve_property(skip_current_chapter)
        mp.osd_message("[sponsorblock] off")
        ON = false
    else
        msg.info("Turning on sponsorblock")
        mp.observe_property("chapter", "number", skip_current_chapter)
        mp.osd_message("[sponsorblock] on")
        ON = true
    end
    update_button()
end

--MARK: activate sponsorblock
local function activate_sponsorblock(merge)
    duration = mp.get_property_native("duration") or 0
    
    if merge then
        -- Merge baked-in chapters with fresh segments from API
        merge_segments()
    else
        merge_nearby_chapters()
        rebuild_segment_cache()
    end
    
    -- Write back the updated chapter list
    mp.set_property_native("chapter-list", chapter_list)
    mp.commandv('script-message-to', 'uosc', 'refresh')

    ON = true
    update_button()
    mp.observe_property("chapter", "number", skip_current_chapter)
    mp.add_forced_key_binding("b","sponsorblock", toggle)
end

--MARK: extract yt id
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
        if id and #id >= 11 then
            return id:sub(1, 11)
        end
    end
    msg.debug("Sponsorblock: no id found")
    return nil
end

--MARK: extract sponsor data
local function extract_sponsorskip_data()
    local json_results = mp.get_property_native("user-data/mpv/ytdl/json-subprocess-result")
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

--MARK: pull sponsor data
local function pull_sponsorskip_data()
    local youtube_id = extract_youtube_id()
    if not youtube_id then return false end
    msg.debug("Sponsorblock: found youtube_id:", youtube_id)

    local categories_str = parsed_categories(options.categories)
    if options.show_only_cats ~= "" then
        local show_only_str = parsed_categories(options.show_only_cats)
        categories_str = categories_str ~= "" and (categories_str .. "," .. show_only_str) or show_only_str
    end

    -- Prepare curl arguments
    local args = {"curl", "-L", "-s", "-G", "--data-urlencode", ("categories=[%s]"):format(categories_str)}
    local url = options.server

    -- Handle hash functionality
    if options.hash == "true" then
        local sha = mp.command_native{
            name = "subprocess",
            capture_stdout = true,
            args = {"sha256sum"},
            stdin_data = youtube_id
        }
        if sha.stdout then
            url = ("%s/%s"):format(url, sha.stdout:sub(1, 4))
        else
            msg.error("Failed to generate SHA256 hash")
            return false
        end
    else
        table.insert(args, "--data-urlencode")
        table.insert(args, "videoID=" .. youtube_id)
    end
    table.insert(args, url)

    -- Fetch sponsor data
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

    -- Handle hash response format
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

--MARK: file loaded
local function file_loaded()
    msg.debug("Sponsorblock: file_loaded")
    -- Clean up keybinding from previous video
    mp.remove_key_binding("sponsorblock")
    -- Reset data
    sponsor_data = nil
    ON = false
    segment_cache = {}
    num_seg_found = nil
    hide_button()
    duration = mp.get_property_native("duration") or 0
    -- Get existing chapters
    chapter_list = mp.get_property_native("chapter-list", {})
    if is_local_file() then
        msg.debug("Sponsorblock: Local file detected, trying to extract segments from local file")
        local function hit()
            for i, chapter in ipairs(chapter_list) do
                local category = match_category(chapter.title)
                if category then
                    msg.debug("Sponsorblock: found local chapter", i, chapter.title)
                    return category
                end
            end
        end

        if hit() then
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
    -- Activate (will merge with existing chapters)
    activate_sponsorblock(true)
end

--MARK: Register
mp.register_event("file-loaded", file_loaded)

mp.register_script_message('manual_sponsorblock_pull', function()
    -- Reset data
    sponsor_data = nil
    ON = false
    segment_cache = {}
    num_seg_found = nil
    msg.info("Sponsorblock: Manual trigger to pull data from server")
    local result = pull_sponsorskip_data()
    if not result then
        msg.debug("Sponsorblock: Failed to pull data from server (or no data for the video found), aborting")
        return
    end
    activate_sponsorblock()
end)

-- Always enable sponsorblock-mark for ytdl hook
local opts = mp.get_property_native("ytdl-raw-options") or {}
opts["sponsorblock-mark"] = "all"
mp.set_property_native("ytdl-raw-options", opts)

-- hide on init (for idle)
hide_button()

