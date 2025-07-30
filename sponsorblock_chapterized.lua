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
local segment_cache = {} -- array of {time, title, category}
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
}
opt.read_options(options)


local button_command = "script-message sponsorblock toggle"
local button_badge
local default_title

local function parsed_categories(cats_to_parse)
    local cats = {}
    for cat in cats_to_parse:gsub('%s', ''):gmatch('[^,]+') do
        table.insert(cats, '"' .. cat .. '"')
    end
    return table.concat(cats, ",")
end
-- Build show_only lookup table once with processed category names
local show_only_table = {}
for cat in options.show_only_cats:gsub('%s', ''):gmatch('[^,]+') do
    local processed_cat = cat:gsub("^%l", string.upper):gsub("_", " ")
    show_only_table[processed_cat] = true
end

local function update_button()
    if not options.uosc_button then return end

	if not options.uosc_direct then
		mp.commandv('script-message-to', 'ucm_sponsorblock_minimal_plugin', 'update-icon', tostring(ON, button_badge))
		return
	end
    print("button_badge", button_badge)
    
    local button = {
        icon = ON and options.button_enabled_icon or options.button_disabled_icon,
        badge = options.show_sponsor_count and button_badge or nil,
        tooltip = options.button_tooltip,
        command = button_command,
        hide = false
    }
    mp.commandv('script-message-to', 'uosc', 'set-button', 'Sponsorblock_Button', utils.format_json(button))
end

local function hide_button()
    if not options.uosc_button then return end
    msg.info("No Sponsorblock data at the moment, hiding button")
    mp.commandv('script-message-to', 'uosc', 'set-button', 'Sponsorblock_Button', utils.format_json({icon = "", hide = true}))
end

local function create_chapter(timestamp, title)
    local target_time = duration and math.min(timestamp, duration - 0.001) or timestamp

    local insert_pos = #chapter_list + 1
    if not default_title then
        default_title = mp.get_property("media-title") or "no title"
    end
    local restore_title = default_title
    
    for i, chapter in ipairs(chapter_list) do
        -- Check for existing chapter within tolerance
        if math.abs(chapter.time - target_time) <= 5 then
            if title then
                chapter_list[i] = {title = title, time = target_time}
            end
            -- if it is a Sponsorblock segment end and close by another chapter 
            -- than the other chapter will close the segment anyway, no need to insert an end-chapter
            return
        end
        
        -- Track insertion position and title for restoration
        if chapter.time > target_time then
            insert_pos = i
            -- Look backwards to find the last non-SponsorBlock chapter
            if not title then  -- Only for segment end chapters
                for j = insert_pos - 1, 1, -1 do
                    local prev_chapter = chapter_list[j]
                    if prev_chapter and prev_chapter.title and not prev_chapter.title:match("^%[SponsorBlock%]:") then
                        restore_title = prev_chapter.title
                        break
                    end
                end
            end
            break
        end
    end
    
    -- Insert new chapter with proper title
    table.insert(chapter_list, insert_pos, {
        title = title or restore_title,
        time = target_time
    })
end

local function build_segment_cache()
    segment_cache = {}
    for i, chapter in ipairs(chapter_list) do
        local category = chapter.title:match("^%[SponsorBlock%]: (.+)")
        if category then
            local next_chapter = chapter_list[i + 1]
            local end_time = next_chapter and next_chapter.time or duration - 0.001
            table.insert(segment_cache, {
                time = chapter.time,
                end_time = end_time,
                title = chapter.title,
                category = category
            })
        end
    end
    button_badge = #segment_cache
end

local function get_actionable_segment(chapter, chapter_index)
    
    local start_time = chapter.time
    for _, segment in ipairs(segment_cache) do
        if segment.time == start_time then
            -- Check if this segment's category is in show_only_cats
            msg.debug("Debug: Checking if " .. segment.category .. " is in show_only_cats:", utils.format_json(show_only_table))
            if show_only_table[segment.category] then
                msg.debug("Debug: Skipping mark-only segment: " , segment.category)
                return nil -- Don't skip, just mark
            else
                mp.osd_message(("[sponsorblock] skipping %s"):format(segment.category or "segment"), options.show_msg_duration)
                msg.info("Skipping chapter " .. chapter_index .. " (" .. chapter.title .. ")")
                return segment -- Should be skipped
            end
        end
    end
    msg.debug("Debug: No actionable segment found at " .. start_time)
    return nil
end

--TODO: use mpv things for this? timeout?
local skip_times = {}
local function skip_current_chapter()
    if not ON then return end

    local now = mp.get_time()
    table.insert(skip_times, now)
    -- debaunce 5 times
    if #skip_times > 5 then table.remove(skip_times, 1) end
    if #skip_times == 5 and (skip_times[5] - skip_times[1] < 0.2) then
        return
    end

    local cur_chapter_index = mp.get_property_number("chapter")
    if not cur_chapter_index or cur_chapter_index < 0 then 
        msg.debug("closing mpv or no chapter to skip or chapter_index is less than 0: ", cur_chapter_index)
        return 
    end
    local chapter_index = cur_chapter_index + 1 -- convert to 1-based index
    local current_chapter = chapter_list[chapter_index]

    local segment = get_actionable_segment(current_chapter, chapter_index)
    if not segment then return end

    local skip_to = math.min(segment.end_time + 0.01, duration - 0.1) -- don't skip past video end
    mp.set_property("time-pos", skip_to)
    --mp.set_property("chapter", chapter_index) --both work
end

local function add_sponsorblock_segment(segment)
    local category = segment.category:gsub("^%l", string.upper):gsub("_", " ")
    create_chapter(segment.segment[1], "[SponsorBlock]: " .. category)
    create_chapter(segment.segment[2])
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

    -- Build initial cache from existing chapters
    build_segment_cache()
    -- Create chapters for new segments. empty table in case of local chapter list only
    for _, segment in pairs(sponsor_data or {}) do
        add_sponsorblock_segment(segment)
    end

    -- Rebuild cache after adding new chapters
    build_segment_cache()
    -- Write back the updated chapter list
    mp.set_property_native("chapter-list", chapter_list)

    ON = true
    update_button()
    mp.observe_property("chapter", "number", skip_current_chapter)
    mp.add_forced_key_binding("b","sponsorblock",toggle)
end

local function pull_sponsorskip_data()
    local categories_str = parsed_categories(options.categories) 
    categories_str = categories_str .. "," .. parsed_categories(options.show_only_cats)

    -- Extract YouTube ID
    local video_path    = mp.get_property("path", "")
    local video_referer = mp.get_property("http-header-fields", ""):match("Referer:([^,]+)") or ""
    local purl          = mp.get_property("metadata/by-key/PURL", "")
    local patterns = {
        "ytdl://youtu%.be/([%w-_]+)", 
        "ytdl://w?w?w?%.?youtube%.com/v/([%w-_]+)",
        "https?://youtu%.be/([%w-_]+)", 
        "https?://w?w?w?%.?youtube%.com/v/([%w-_]+)",
        "/watch.*[?&]v=([%w-_]+)", 
        "/embed/([%w-_]+)", 
        "^ytdl://([%w-_]+)$", 
        "-([%w-_]+)%."
    }

    local youtube_id
    for _, pattern in ipairs(patterns) do
        youtube_id = video_path:match(pattern) or video_referer:match(pattern) or purl:match(pattern)
        if youtube_id then break end
    end

    if not youtube_id or #youtube_id < 11 then return false end
    youtube_id = youtube_id:sub(1, 11)

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
            return
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
                break
            end
        end
    else
        if not json[1] or json[1] == "No valid categories provided." then return false end
        sponsor_data = json
    end

    return true
end

local function file_loaded()
    -- reset data
    sponsor_data = nil
    ON = false
    segment_cache = {}
    hide_button()
    
    local result = pull_sponsorskip_data()
    chapter_list = mp.get_property_native("chapter-list", {})
    if result then
        activate_sponsorblock()
        return
    else
        msg.info("No Sponsorblock data pulled from server")
    end 
    
    local local_sponsorblock_chapters = false
    
    -- if there are chapters and at least one ad chapter then process
    if #chapter_list > 0 then
        msg.info("looking for local sponsorblock chapters")
        for i, chapter in ipairs(chapter_list) do
            if chapter.title and chapter.title:match("^%[SponsorBlock%]:") then
                local_sponsorblock_chapters = true
                activate_sponsorblock()
                return
            end
        end
    end
end

mp.register_event("file-loaded", file_loaded)

-- hide on init (for idle)
hide_button()