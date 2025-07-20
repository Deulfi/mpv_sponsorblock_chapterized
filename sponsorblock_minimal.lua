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
local skipped_chapters = {}

local options = {
	server = "https://sponsor.ajay.app/api/skipSegments",
	categories = '',
	hash = "",
	show_msg_duration = 3,
	uosc_button = true,
	uosc_direct = true,
    show_sponsor_count=true,
	button_enabled_icon = "shield",
	button_disabled_icon = "remove_moderator",
	button_tooltip = "Sponsorblock",
	button_command = "script-message sponsorblock toggle",
    button_badge=0,
}
local segment_cache = {} -- array of {time, title, category}
local chapter_list = {}

opt.read_options(options)

local function parse_categories(str)
    local cats = {}
    for cat in str:gsub('%s', ''):gmatch('[^,]+') do
        table.insert(cats, '"' .. cat .. '"')
    end
    return table.concat(cats, ",")
end
local parsed_categories = parse_categories(options.categories)

local function send_state(on_state)
    if not options.uosc_button then return end

	if not options.uosc_direct then
		mp.commandv('script-message-to', 'ucm_sponsorblock_minimal_plugin', 'update-icon', tostring(on_state, options.button_badge))
		return
	end
    
    local button = {
        icon = on_state and options.button_enabled_icon or options.button_disabled_icon,
        badge = options.show_sponsor_count and options.button_badge or nil,
        tooltip = options.button_tooltip,
        command = options.button_command
    }
    mp.commandv('script-message-to', 'uosc', 'set-button', 'Sponsorblock_Button', utils.format_json(button))
end

local function create_chapter(title, time)
    local chapters = mp.get_property_native("chapter-list") or {}
    local duration = mp.get_property_native("duration")
    table.insert(chapters, {
        title = title, 
        time = (duration and duration > time) and time or (duration and duration - 0.001 or time)
    })
    table.sort(chapters, function(a, b) return a.time < b.time end)
    mp.set_property_native("chapter-list", chapters)
end

local function build_segment_cache()
    segment_cache = {}
    chapter_list = mp.get_property_native("chapter-list") or {}
    for i, chapter in ipairs(chapter_list) do
        local category = chapter.title:match("^%[SponsorBlock%]: (.+)")
        if category then
            local next_chapter = chapter_list[i + 1]
            local end_time = next_chapter and next_chapter.time or mp.get_property_native("duration") - 0.5
            table.insert(segment_cache, {
                time = chapter.time,
                end_time = end_time,
                title = chapter.title,
                category = category
            })
        end
    end
    options.button_badge = #segment_cache
end


local function is_sponsorblock_segment(time)
    for _, segment in ipairs(segment_cache) do
        if segment.time == time then return segment end
    end
    return nil
end

local last_skip = 0
local function skip_current_chapter()
    if not ON then return end

    -- otherwise this function would giht the user if they drag the playback into a segment
    local now = mp.get_time()
    if now - last_skip < 0.1 then return end
    last_skip = now
    
    local cur_chapter_index = mp.get_property_number("chapter")
    if not cur_chapter_index or cur_chapter_index < 0 then 
        msg.debug("No chapter to skip or chapter_index is less than 0.")
        return 
    end
    cur_chapter_index = cur_chapter_index + 1 or 1 -- convert to 1-based index

    local current = chapter_list[cur_chapter_index]
    local segment = is_sponsorblock_segment(current.time)

    if not segment then 
        msg.debug("Debug: No segment found at chapter " .. cur_chapter_index)
        return 
    end

    mp.osd_message(("[sponsorblock] skipping %s"):format(segment.category or "segment"), options.show_msg_duration)
    msg.info("Skipping chapter " .. cur_chapter_index .. " (" .. current.title .. ")")
    --mp.set_property("time-pos",segment.end_time + 0.01) --both work
    mp.set_property("chapter", cur_chapter_index)

end

local function find_restore_title(start_time)
    local restore_title = ' '
    for _, chapter in ipairs(chapter_list) do
        if chapter.time <= start_time then
            restore_title = chapter.title
        else
            break
        end
    end
    return restore_title
end

local function add_sponsorblock_segment(segment, end_title)
    local category = segment.category:gsub("^%l", string.upper):gsub("_", " ")
    create_chapter("[SponsorBlock]: " .. category, segment.segment[1])
    create_chapter(end_title, segment.segment[2])
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
    send_state(ON)
end

local function file_loaded()
    sponsor_data = nil
    ON = false
    segment_cache = {} -- Clear cache
    send_state(ON)
    
    -- Extract YouTube ID
    local video_path = mp.get_property("path", "")
    local video_referer = mp.get_property("http-header-fields", ""):match("Referer:([^,]+)") or ""
    local purl = mp.get_property("metadata/by-key/PURL", "")
    
    local patterns = {
        "ytdl://youtu%.be/([%w-_]+)", "ytdl://w?w?w?%.?youtube%.com/v/([%w-_]+)",
        "https?://youtu%.be/([%w-_]+)", "https?://w?w?w?%.?youtube%.com/v/([%w-_]+)",
        "/watch.*[?&]v=([%w-_]+)", "/embed/([%w-_]+)", "^ytdl://([%w-_]+)$", "-([%w-_]+)%."
    }
    
    local youtube_id
    for _, pattern in ipairs(patterns) do
        youtube_id = video_path:match(pattern) or video_referer:match(pattern) or purl:match(pattern)
        if youtube_id then break end
    end
    
    if not youtube_id or #youtube_id < 11 then return end
    youtube_id = youtube_id:sub(1, 11)
    
    -- Prepare curl arguments
    local args = {"curl", "-L", "-s", "-G", "--data-urlencode", ("categories=[%s]"):format(parsed_categories)}
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

    if not result.stdout then return end
    
    local json = utils.parse_json(result.stdout)
    if type(json) ~= "table" then return end
    
    -- Handle hash response format
    if options.hash == "true" then
        for _, i in pairs(json) do
            if i.videoID == youtube_id then
                sponsor_data = i.segments
                break
            end
        end
    else
        if not json[1] or json[1] == "No valid categories provided." then return end
        sponsor_data = json
    end

    -- Build initial cache from existing chapters
    build_segment_cache()
    -- Create chapters for new segments
    for _, segment in pairs(sponsor_data) do
        local start_time = segment.segment[1]
        -- only add if it is new and not in the cache already (could be already baked into the video)
        if not is_sponsorblock_segment(start_time) then
            local end_title = find_restore_title(start_time)
            add_sponsorblock_segment(segment, end_title)
        end
    end
    -- Rebuild cache after adding new chapters
    build_segment_cache()

    -- in case there is a segment at the end of the video but no closing chapter, insert one (happend in a video with baked in segments).
    local last_chapter = chapter_list[#chapter_list]
    if last_chapter and is_sponsorblock_segment(last_chapter.time) then
        create_chapter('EOF', mp.get_property_number("duration"))
    end
    
    ON = true
    send_state(ON)
    mp.observe_property("chapter", "number", skip_current_chapter)
    mp.add_forced_key_binding("b","sponsorblock",toggle)
end

mp.register_event("file-loaded", file_loaded)
