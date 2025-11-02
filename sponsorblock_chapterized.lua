-- Fixed version with proper data structure and synchronization
-- Key fixes:
-- 1. Use chapter indices instead of direct references (prevents stale references)
-- 2. Keep segment times (start/end) as source of truth
-- 3. Rebuild segment_cache from chapter_list after all processing
-- 4. Proper merging of baked-in chapters with fresh segments using time tolerance

local opt = require 'mp.options'
local utils = require 'mp.utils'
local msg = require 'mp.msg'

local ON = false
local sponsor_data = nil
local segment_cache = {} -- Array of {start, end, category, start_idx, end_idx}
local chapter_list = {}
local duration = 0

local options = {
	server = "https://sponsor.ajay.app/api/skipSegments",
	categories = "",
    show_only_cats = "",
	hash = "",
	show_msg_duration = 3,
	uosc_button = true,
	uosc_direct = true,
    show_sponsor_count = true,
	button_enabled_icon = "shield",
	button_disabled_icon = "remove_moderator",
	button_tooltip = "Sponsorblock",
    also_pull_for_local = false,
    skip_unknown = false,
    min_segment_length = 1,
    time_tolerance = 5.0, -- For matching baked-in vs fresh segments
}
opt.read_options(options)

local button_command = "script-message sponsorblock toggle"
local num_seg_found

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
    show_only_lookup[process_category(cat)] = true
end
local cats_lookup = {}
for cat in options.categories:gsub('%s', ''):gmatch('[^,]+') do
    cats_lookup[process_category(cat)] = true
end

local function update_button()
    if not options.uosc_button then return end
    msg.debug("updating button:", num_seg_found, "segments")
	if not options.uosc_direct then
		mp.commandv('script-message-to', 'ucm_sponsorblock_minimal_plugin', 'update-icon', tostring(ON, num_seg_found))
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
    msg.debug("No Sponsorblock data at the moment, hiding button")
    mp.commandv('script-message-to', 'uosc', 'set-button', 'Sponsorblock_Button', utils.format_json({icon = "", hide = true}))
end

local function match_category(title)
    return title and title:match("^%[SponsorBlock%]: (.+)") or false
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

-- Rebuild segment_cache from chapter_list (source of truth)
-- This ensures consistency after any modifications
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
    
    return num_seg_found > 0
end

-- Find or create chapter at time (with tolerance matching)
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
        -- If both are SponsorBlock or both are normal, keep existing (or merge logic here)
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
-- Handles time differences between existing chapters and API data
local function merge_segments()
    -- First, extract segments from existing chapters (baked-in)
    local baked_segments = {}
    for i, chapter in ipairs(chapter_list) do
        local category = match_category(chapter.title)
        if category then
            local next_chapter = chapter_list[i + 1]
            local end_time = next_chapter and next_chapter.time or duration - 0.001
            table.insert(baked_segments, {
                start = chapter.time,
                ['end'] = end_time,
                category = category,
                source = "baked"
            })
        end
    end
    
    -- Add fresh segments from API
    local fresh_segments = {}
    if sponsor_data then
        for _, segment in pairs(sponsor_data) do
            local delta = segment.segment[2] - segment.segment[1]
            if delta > options.min_segment_length then
                table.insert(fresh_segments, {
                    start = segment.segment[1],
                    ['end'] = segment.segment[2],
                    category = process_category(segment.category),
                    source = "fresh"
                })
            end
        end
    end
    
    -- Merge: prefer fresh segments, but merge with baked if within tolerance
    local merged = {}
    local used_baked = {} -- Track which baked segments were merged
    
    -- Process fresh segments first (they take precedence)
    for _, fresh in ipairs(fresh_segments) do
        local merged_segment = {start = fresh.start, ['end'] = fresh['end'], category = fresh.category}
        
        -- Check if any baked segment matches (within tolerance)
        for i, baked in ipairs(baked_segments) do
            if not used_baked[i] and 
               math.abs(baked.start - fresh.start) <= options.time_tolerance and
               math.abs(baked['end'] - fresh['end']) <= options.time_tolerance then
                -- Use baked chapter times (they might be more precise)
                merged_segment.start = baked.start
                merged_segment['end'] = baked['end']
                used_baked[i] = true
                break
            end
        end
        
        table.insert(merged, merged_segment)
    end
    
    -- Add remaining baked segments that weren't merged
    for i, baked in ipairs(baked_segments) do
        if not used_baked[i] then
            table.insert(merged, {start = baked.start, ['end'] = baked['end'], category = baked.category})
        end
    end
    
    -- Remove duplicates (same start/end within tolerance)
    for i = #merged, 2, -1 do
        for j = i - 1, 1, -1 do
            if math.abs(merged[i].start - merged[j].start) <= 0.5 and
               math.abs(merged[i]['end'] - merged[j]['end']) <= 0.5 then
                table.remove(merged, i)
                break
            end
        end
    end
    
    -- Sort by start time
    table.sort(merged, function(a, b) return a.start < b.start end)
    
    -- Handle overlaps
    local final_segments = {}
    for _, seg in ipairs(merged) do
        if #final_segments == 0 then
            table.insert(final_segments, seg)
        else
            local last = final_segments[#final_segments]
            -- Check for overlap
            if seg.start < last['end'] then
                -- Overlap: keep the longer segment, or prefer the one that's more precise
                if seg['end'] - seg.start > last['end'] - last.start then
                    final_segments[#final_segments] = seg
                -- else keep last
                end
            else
                table.insert(final_segments, seg)
            end
        end
    end
    
    -- Preserve non-SponsorBlock chapters, rebuild SponsorBlock ones
    local preserved_chapters = {}
    for _, chapter in ipairs(chapter_list) do
        if not match_category(chapter.title) then
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
    
    -- Now merge chapters that are very close together (within tolerance)
    -- This handles the baked-in vs fresh time differences
    -- BUT: Don't merge a segment's own start and end chapters
    for i = #chapter_list, 2, -1 do
        local curr = chapter_list[i]
        local prev = chapter_list[i - 1]
        
        if math.abs(curr.time - prev.time) <= options.time_tolerance then
            -- Check if these are the start/end of the same segment
            -- A segment's own start and end should never be merged
            local are_same_segment = false
            local small_tol = 0.01  -- Small tolerance for floating point comparison
            for _, seg in ipairs(final_segments) do
                if (math.abs(prev.time - seg.start) <= small_tol and math.abs(curr.time - seg['end']) <= small_tol) or
                   (math.abs(curr.time - seg.start) <= small_tol and math.abs(prev.time - seg['end']) <= small_tol) then
                    are_same_segment = true
                    break
                end
            end
            
            -- Never merge a segment's own boundaries
            if are_same_segment then
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
    
    -- Rebuild cache from final chapter list
    rebuild_segment_cache()
end

local function get_actionable_segment(start_time, chapter_index)
    local segment
    for i, range in ipairs(segment_cache) do
        if range.start <= start_time and (start_time < (range['end'] - 0.0005)) then
            segment = range
            break
        end
    end
    if not segment then return nil end
    
    -- Check if this segment's category is in show_only_cats
    if show_only_lookup[segment.category] then
        msg.debug("Debug: not skipping mark-only segment: ", segment.category)
        return nil -- Don't skip, just mark
    elseif cats_lookup[segment.category] then
        mp.osd_message(("[sponsorblock] skipping %s"):format(segment.category), options.show_msg_duration)
        msg.info("Skipping chapter:", chapter_index, "(" .. segment.category .. ")")
        return segment -- Should be skipped
    else
        -- Try to match segment.category with both show_only_lookup and cats_lookup using pattern matching
        for cat, _ in pairs(cats_lookup) do
            if segment.category:match(cat) then
                mp.osd_message(("[sponsorblock] skipping %s"):format(segment.category), options.show_msg_duration)
                msg.info("Skipping chapter (pattern):", chapter_index, "(" .. segment.category .. ")", "matched against", cat)
                return segment
            end
        end
        for cat, _ in pairs(show_only_lookup) do
            if segment.category:match(cat) then
                msg.debug("Debug: not skipping mark-only segment (pattern): ", segment.category, "matched against", cat)
                return nil
            end
        end
        msg.debug("Debug: unknown segment (pattern): ", segment.category)
        return options.skip_unknown and segment or nil
    end
end

-- Optimized debouncing with fixed-size circular buffer
local skip_times = {0, 0, 0, 0, 0}
local skip_index = 1

local function skip_current_chapter()
    if not ON then return end

    -- Simple debouncing: check if we've been called 5 times in 0.2 seconds
    local now = mp.get_time()
    skip_times[skip_index] = now
    skip_index = skip_index % 5 + 1
    
    if now - skip_times[skip_index] < 0.2 then
        return -- Too many calls, debounce
    end

    local cur_chapter_index = mp.get_property_number("chapter")
    if not cur_chapter_index or cur_chapter_index < 0 then return end
    
    -- Use segment_cache which has reliable start/end times
    local chapter_time = mp.get_property_number("chapter-list/"..cur_chapter_index.."/time")
    if not chapter_time then return end

    local segment = get_actionable_segment(chapter_time, cur_chapter_index)
    if not segment then return end

    local skip_to = math.min(segment['end'] + 0.01, duration - 0.1)
    mp.set_property("time-pos", skip_to)
end

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

local function activate_sponsorblock()
    duration = mp.get_property_native("duration") or 0
    
    -- Get existing chapters
    chapter_list = mp.get_property_native("chapter-list", {})
    
    -- Merge baked-in chapters with fresh segments from API
    merge_segments()
    
    -- Write back the updated chapter list
    mp.set_property_native("chapter-list", chapter_list)

    ON = true
    update_button()
    mp.observe_property("chapter", "number", skip_current_chapter)
    mp.add_forced_key_binding("b","sponsorblock",toggle)
end

local function extract_youtube_id()
    local video_path = mp.get_property("path", "")
    local video_referer = mp.get_property("http-header-fields", ""):match("Referer:([^,]+)") or ""
    local purl = mp.get_property("metadata/by-key/PURL", "")
    
    local patterns = {
        "ytdl://youtu%.be/([%w-_]+)", 
        "ytdl://w?w?w?%.?youtube%.com/v/([%w-_]+)",
        "https?://youtu%.be/([%w-_]+)", 
        "https?://w?w?w?%.?youtube%.com/v/([%w-_]+)",
        "/watch.*[?&]v=([%w-_]+)", 
        "/embed/([%w-_]+)", 
        "^ytdl://([%w-_]+)$", 
    }
    if options.also_pull_for_local then
        table.insert(patterns, "-([%w-_]+)%.")
    end

    for _, pattern in ipairs(patterns) do
        local id = video_path:match(pattern) or video_referer:match(pattern)
        if not id and options.also_pull_for_local then
            id = purl:match(pattern)
        end
        if id and #id >= 11 then
            return id:sub(1, 11)
        end
    end
    return nil
end

local function pull_sponsorskip_data()
    local youtube_id = extract_youtube_id()
    if not youtube_id then return false end

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
        args = args
    }

    if not result.stdout then return false end

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

local function file_loaded()
    msg.debug("file_loaded")
    -- Reset data
    sponsor_data = nil
    ON = false
    segment_cache = {}
    num_seg_found = nil
    hide_button()
    duration = mp.get_property_native("duration") or 0
    
    -- Try to pull data from server
    pull_sponsorskip_data()
    
    -- Activate (will merge with existing chapters)
    activate_sponsorblock()
end

mp.register_event("file-loaded", file_loaded)

-- hide on init (for idle)
hide_button()