-- sponsorblock_minimal.lua
-- source: https://codeberg.org/jouni/mpv_sponsorblock_minimal
--
-- This script skips sponsored segments of YouTube videos
-- using data from https://github.com/ajayyy/SponsorBlock

local opt = require 'mp.options'
local utils = require 'mp.utils'
local msg = require 'mp.msg'

local ON = false
local sponsor_data = nil
local segment_cache = {} -- time-indexed table: {[time] = {start_time, end_time, title, category}}
local segment_cache = {}
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
}
opt.read_options(options)

local button_command = "script-message sponsorblock toggle"
local num_seg_found
local state = {
    chapter_index = 1,
    range_index = 1,
    last_viable_title = "default_title"
 }
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
    return title:match("^%[SponsorBlock%]: (.+)") or false
end

local function init_segment_cache()
    local count = 0
    for i, chapter in ipairs(chapter_list) do
        local category = match_category(chapter.title)
        if category then
            local next_chapter = chapter_list[i + 1]
            local end_time = next_chapter and next_chapter.time or duration - 0.001

            table.insert(segment_cache, {
                start_chapter = chapter,
                end_chapter = next_chapter,
                start = chapter.time,
                ['end'] = end_time,
                title = chapter.title,
                category = category,
            })
            count = count + 1
        end
    end
    return count > 0 and count or nil
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
        msg.info("Skipping chapter:", chapter_index, "(" .. segment.title .. ")")
        return segment -- Should be skipped
    else
        -- Try to match segment.category with both show_only_lookup and cats_lookup using pattern matching
        for cat, _ in pairs(cats_lookup) do
            if segment.category:match(cat) then
                mp.osd_message(("[sponsorblock] skipping %s"):format(segment.category), options.show_msg_duration)
                msg.info("Skipping chapter (pattern):", chapter_index, "(" .. segment.title .. ")" , "matched against", cat)
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
    local start_time =  mp.get_property_number("chapter-list/"..cur_chapter_index.."/time")
    if not start_time then return end

    local segment = get_actionable_segment(start_time, cur_chapter_index)
    if not segment then return end

    --local skip_to = math.min(segment.end_time + 0.01, duration - 0.1)
    local skip_to = math.min(segment.end_chapter and segment.end_chapter.time + 0.01 or 9999999999999, duration - 0.1)
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
-- Converts a chapter time (in seconds) to a human-readable string "MM:SS"
local function readable(time)
    if not time or type(time) ~= "number" then return "??:??" end
    local total_seconds = math.floor(time + 0.5)
    local minutes = math.floor(total_seconds / 60)
    local seconds = total_seconds % 60
    return string.format("%02d:%02d", minutes, seconds)
end

local function processChapterInLoop(state)
    local current_chapter = chapter_list[state.chapter_index]
    local next_chapter = chapter_list[state.chapter_index + 1]

    msg.error("Chapter " .. state.chapter_index ..  " " .. current_chapter.title .. " " .. readable(current_chapter.time))
    msg.error("Segment " .. state.range_index .. " "  .. " " .. readable(segment_cache[state.range_index].start) .. " " .. readable(segment_cache[state.range_index]['end']))

    
    if state.range_index > #segment_cache then 
        return false  -- Break signal
    end
    
    local current_range = segment_cache[state.range_index]
    local next_range = segment_cache[state.range_index + 1]

    local is_sponsor_start = current_chapter == current_range.start_chapter or match_category(current_chapter.title)
    local is_sponsor_end = current_chapter == current_range.end_chapter or current_chapter.title == "end"
    
    -- Normal chapter
    if not is_sponsor_start and not is_sponsor_end then
        state.last_viable_title = current_chapter.title
        state.chapter_index = state.chapter_index + 1
        msg.debug("Normal chapter", current_chapter.title, "chapter index", state.chapter_index, "is normal and segment_index is", state.range_index)
        return true
    end
    

    if is_sponsor_start then
        -- No more segments, skip to end processing
        if not next_range then 
            state.chapter_index = state.chapter_index + 1
            return true
        end

        -- Case: Duplicates
        for i, next_range in ipairs(segment_cache) do
            msg.debug("Segment " .. i .. " "  .. " " .. readable(segment_cache[i].start) .. " " .. readable(segment_cache[i]['end']))
            if  math.abs(current_range.start - next_range.start) <= 0.5 and i ~= state.range_index then
                if math.abs(current_range['end'] - next_range['end']) <= 0.5 then
                    print("checking duplicates: current=" .. current_range.start .. "-" .. current_range['end'] .. " vs next=" .. (next_range and next_range.start or "nil") .. "-" .. (next_range and next_range['end'] or "nil"))
                    
                    table.remove(segment_cache, i)
                    table.remove(chapter_list, state.chapter_index + 2)
                    table.remove(chapter_list, state.chapter_index + 2)
                    msg.debug("Duplicate, same start and end", state.chapter_index, " - ", i)
                    return true
                
                else
                    msg.debug("Not dupe, same start but different end chapter_index", state.chapter_index, " - range_index", i)
                    print(">>>>>> ",math.abs(current_range['end'] - next_range['end']),"with", readable(current_range['end']), "and", readable(next_range['end']))
                end
            else
                print("same start but different end")
                print("current range index: ", state.range_index, "next range index: ", i)
                print(">>>>>> ",math.abs(current_range.start - next_range.start),"with", readable(current_range.start), "and", readable(next_range.start))
                --msg.error("Not dupe, different start", readable(current_range.start)," - ", readable(next_range.start))
            end
        end
        -- Case: Overlap same start
        if math.abs(current_range.start - next_range.start) <= 0.5 then
            msg.debug("Case: Overlap same start")
            local current_length = current_range['end'] - current_range.start
            local next_length = next_range['end'] - next_range.start
            
            if current_length > next_length then
                table.insert(segment_cache, state.range_index, next_range)
                table.remove(segment_cache, state.range_index + 2)
                table.insert(chapter_list, state.chapter_index, next_range.start_chapter)
                table.insert(chapter_list, state.chapter_index + 1, next_range.end_chapter)
                table.remove(chapter_list, state.chapter_index + 4)
                table.remove(chapter_list, state.chapter_index + 4)
                current_range = segment_cache[state.range_index]
                next_range = segment_cache[state.range_index + 1]
            else
                msg.debug("Current segment not enclosing next segment:", readable(current_length)," < ", readable(next_length))
                msg.debug("Keeping shorter segment and showing the end of the longer segment")

                -- since the segments have the same start but next_segment ends outside of current_segment
                -- we let the next segment start at the end of current segment.
                next_range.start = current_range['end']
                --if next_range.start_chapter then
                -- we also need to move the actual chapter to the time of current segment end
                next_range.start_chapter.time = current_range.end_chapter.time
                --end
                -- Remove redundant chapter created by overlapping starts, if present
                local redundant_idx = state.chapter_index + 1
                if chapter_list[redundant_idx] and math.abs((chapter_list[redundant_idx].time or -1) - next_range.start) <= 0.001 then
                    msg.debug("Redundant chapter found and removed")
                    table.remove(chapter_list, redundant_idx)
                end
            end

            return true
        end
        -- Case: Overlap different starts
        local overlap_start = current_range['end'] - next_range.start
        local overlap_end = current_range['end'] - next_range['end']
        
        if overlap_start > 0 and overlap_end > 0 then
            print("overlap different starts")
            -- next_range completely inside current_range; trim current_range to end at next_range.start
            current_range['end'] = next_range.start
            if current_range.end_chapter then
                current_range.end_chapter.time = next_range.start
            end
            return true
            
        elseif overlap_start > 0 and overlap_end <= 0 then
            print("overlap different ends")
            -- next_range ends after current_range; trim current_range to end at next_range.start
            local new_end = next_range.start
            if new_end < current_range.start then
                new_end = current_range.start
            end
            current_range['end'] = new_end
            if current_range.end_chapter then
                current_range.end_chapter.time = new_end
            end
            return true
        end
        
        --print("12")
    end
    -- Case: Chapter snapping
    if is_sponsor_start or is_sponsor_end then
        --print("4")
        local prev_chapter = chapter_list[state.chapter_index - 1]
        local snap_chapter = nil
        local segment_time = is_sponsor_start and current_range.start or current_range['end']
        local new_title = is_sponsor_start and current_chapter.title or "end"
        
        -- Check previous chapter
        if prev_chapter and math.abs(prev_chapter.time - segment_time) <= 5.0 then
            msg.debug("prev_chapter snap")
            local prev_range = segment_cache[state.range_index - 1]
            if not prev_range or prev_range.end_chapter ~= prev_chapter then
                snap_chapter = prev_chapter
            end
        end
        --print("5")
        -- Check next chapter
        if not snap_chapter and next_chapter and math.abs(next_chapter.time - segment_time) <= 5.0 then
            msg.debug("next_chapter snap")
            if not next_range or next_range.start_chapter ~= next_chapter then
                snap_chapter = next_chapter
            end
        end
        --print("6")
        -- Snap to found chapter but not to other sponsor segment or own boundary
        -- NOTE: "not a == b" in Lua evaluates as (not a) == b. Use ~= for inequality.
        if snap_chapter
            and (not next_range or snap_chapter.time ~= next_range.start)
            and not (is_sponsor_start and snap_chapter == current_range.end_chapter)
            and not (is_sponsor_end and snap_chapter == current_range.start_chapter)
            and (
                (is_sponsor_start and match_category(snap_chapter.title))
                or (is_sponsor_end and snap_chapter.title == "end")
            ) then
            print("snap to found chapter")
            if is_sponsor_start then
                current_range.start = snap_chapter.time
                -- Remove the old start chapter that current_chapter pointed to
                table.remove(chapter_list, state.chapter_index)
                current_range.start_chapter = snap_chapter
            else
                current_range['end'] = snap_chapter.time
                -- Remove the old end chapter that current_chapter pointed to
                table.remove(chapter_list, state.chapter_index)
                current_range.end_chapter = snap_chapter
            end
            return true
        elseif snap_chapter then
            msg.debug("Snap was armed but wasn't done")
        end
    end

    
    if is_sponsor_end then
        -- Do not retitle 'end' markers inline; retain existing boundary semantics
        -- Case: Adjacent segments (end aligns to next start; keep the existing end title)
        if next_range and math.abs(current_range['end'] - next_range.start) <= 0.5 then
            msg.debug("Adjacent segments", current_range.start_chapter.title, readable(current_range['end']), next_range.start_chapter.title, readable(next_range.start))
            local boundary_time = next_range.start
            current_range['end'] = boundary_time
            -- Remove duplicate 'end' only if previous chapter is non-sponsor and has same time
            local removed = false
            local prev = chapter_list[state.chapter_index - 1]
            if prev and not match_category(prev.title) and math.abs((prev.time or -1) - boundary_time) <= 0.0005 then
                table.remove(chapter_list, state.chapter_index)
                removed = true
            end
            -- Keep end_chapter reference consistent at boundary time
            if current_range.end_chapter then current_range.end_chapter.time = boundary_time end
            -- Avoid re-processing same boundary: advance if nothing was removed
            if not removed then
                state.chapter_index = state.chapter_index + 1
            end
            return true
        end

        -- Replace 'end' marker title only if previous chapter is non-sponsor
        if current_chapter.title == "end" then
            msg.debug("Replacing end_marker with last viable title:", state.last_viable_title)
            current_chapter.title = state.last_viable_title
        else
            msg.debug("Segment_end but no end_marker:", current_chapter.title)
        end
    end


    --print("15")
    --TODO: check if the next range would also aplply to the current chapter. if yes change state.range_index and return true
    if next_range and (current_chapter.time == next_range.start or math.abs(current_chapter.time - next_range.start) <= 0.5) then 
        msg.debug("Next Segment also could apply to current chapter, because segment start time matches chapter time")
        state.range_index = state.range_index + 1
        return true
    else
        msg.debug("No next segment or next segment does not apply to current chapter")
    end


    msg.debug("Chapter", state.chapter_index, "got to the end with segment_index", state.range_index)
    state.chapter_index = state.chapter_index + 1
        --TODO: this shit does not work as it does not handle duplicates (finds the first and ignores the rest.), 
    -- the code should work without this but that is enven more borked.
    while state.range_index <= #segment_cache do
        local current_range = segment_cache[state.range_index]
        if current_chapter.time < current_range.start then break end
        if current_chapter.time > current_range['end'] then 
            state.range_index = state.range_index + 1
        else
            break
        end
    end
    return true
end
local function activate_sponsorblock()  
    
    -- Build initial cache from existing chapters
    num_seg_found = init_segment_cache()
    -- Create chapters for new segments

    -- for delte local chapter
    --if true then
    --    segment_cache = {}
    --    chapter_list = {}
    --end

    
    for i, segment in pairs(sponsor_data or {}) do
        msg.debug("segment", utils.format_json(segment))


        local start_title = "[SponsorBlock]: " .. process_category(segment.category)
        local start_chapter = {title = start_title, time = segment.segment[1]}
        local end_chapter = {title = "end", time = segment.segment[2]}
        local delta = end_chapter.time - start_chapter.time
        if delta > options.min_segment_length then
            table.insert(chapter_list, start_chapter)
            -- if the end coincides with next segment's start, we will not add a duplicate end marker now
            table.insert(chapter_list, end_chapter)

            -- add the segment to the cache. 
            table.insert(segment_cache, {
                start_chapter = start_chapter,
                end_chapter = end_chapter,
                start = segment.segment[1],
                ['end'] = segment.segment[2],
                title = segment.category,
                category = process_category(segment.category),
            })
        end
    end
    table.sort(chapter_list, function(a, b) return a.time < b.time end)
    for i, chapter in ipairs(chapter_list) do
        print("chapter", i, chapter.title, readable(chapter.time))
    end

    table.sort(segment_cache, function(a, b) return a.start_chapter.time < b.start_chapter.time end)

    for i, segment in ipairs(segment_cache) do
        print("segment", i, segment.start, segment['end'], segment.start_chapter.title, "endtitle:", segment.end_chapter and segment.end_chapter.title)
    end
        -- Reset processing state and run main loop
        state.chapter_index = 1
        state.range_index = 1
    while state.chapter_index <= #chapter_list do
        if not processChapterInLoop(state) then break end
    end

    -- Removed normalize_after_processing(); keep existing chapters intact and rely on in-loop adjustments
    --print("segment_cache", utils.format_json(segment_cache))
    for i, segment in ipairs(segment_cache) do
        print("segment", i, segment.start, segment['end'], segment.start_chapter.title, "endtitle:" , segment.end_chapter and segment.end_chapter.title)
    end

    for i, chapter in ipairs(chapter_list) do
        print("chapter", i, chapter.title, chapter.time)
    end

    -- Rebuild cache after adding new chapters
    num_seg_found = #segment_cache
    --button_badge = num_seg_found
    --if not num_seg_found then return end

    ON = true
    update_button()
    -- Write back the updated chapter list
    mp.set_property_native("chapter-list", chapter_list)
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

local function has_local_sponsorblock_chapters()
    for _, chapter in ipairs(chapter_list) do
        if chapter.title and match_category(chapter.title) then
            return true
        end
    end
    return false
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
    chapter_list = mp.get_property_native("chapter-list", {})
    state.last_viable_title = mp.get_property("media-title")
    
    ---- Try to pull data from server first
    --if pull_sponsorskip_data() then
    pull_sponsorskip_data()
    activate_sponsorblock()
end

mp.register_event("file-loaded", file_loaded)

-- hide on init (for idle)
hide_button()
--TODO: better stream detection
