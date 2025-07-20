-- sponsorblock_minimal.lua
-- source: https://codeberg.org/jouni/mpv_sponsorblock_minimal
--
-- This script skips sponsored segments of YouTube videos
-- using data from https://github.com/ajayyy/SponsorBlock

local opt = require 'mp.options'
local utils = require 'mp.utils'
local msg = require 'mp.msg'

local ON = false
local ranges = nil
local skipped_chapters = {}

local options = {
	server = "https://sponsor.ajay.app/api/skipSegments",
	categories = '',
	hash = "",
	show_msg_duration = 3,
	skip_once = true,
	uosc_button = true,
	uosc_direct = true,
    show_sponsor_count=true,
	button_enabled_icon = "shield",
	button_disabled_icon = "remove_moderator",
	button_tooltip = "Sponsorblock",
	button_command = "script-message sponsorblock toggle",
    button_badge=0,
}

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

local function skip_current_chapter()
    if not ON then return end
    
    local chapter = mp.get_property_number("chapter")
    if not chapter or chapter < 0 then 
        msg.debug("No chapter to skip or chapter is less than 0")
        return 
    end
    
    local chapters = mp.get_property_native("chapter-list")
    if not chapters or not chapters[chapter + 1] then 
        msg.debug("Video has no next chapter")
        return 
    end

    local current = chapters[chapter + 1]
    if current.title and current.title:match("^%[SponsorBlock%]:") then
        local category = current.title:match("^%[SponsorBlock%]: (.+)")
        mp.osd_message(("[sponsorblock] skipping %s"):format(category or "segment"), options.show_msg_duration)
        mp.set_property("chapter", chapter + 1)
    end
end

local function is_duplicate_segment(existing_chapters, start_time)
    for _, chapter in ipairs(existing_chapters) do
        if chapter.title and chapter.title:match("^%[SponsorBlock%]:") and 
           chapter.time == start_time then
            return true
        end
    end
    return false
end
local function count_preexisting_segment(existing_chapters)
    local count = 0
    for _, chapter in ipairs(existing_chapters) do
        if chapter.title and chapter.title:match("^%[SponsorBlock%]:") then
            count = count + 1
        end
    end
    return count
end

local function find_restore_title(existing_chapters, start_time)
    local restore_title = ' '
    for _, chapter in ipairs(existing_chapters) do
        if chapter.time <= start_time then
            restore_title = chapter.title
        else
            return restore_title
        end
    end
end

local function add_sponsorblock_segment(segment, end_title)
    local category = segment.category:gsub("^%l", string.upper):gsub("_", " ")
    create_chapter("[SponsorBlock]: " .. category, segment.segment[1])
    create_chapter(end_title, segment.segment[2])
end

local function toggle()
    if ON then
        mp.unobserve_property(skip_current_chapter)
        mp.osd_message("[sponsorblock] off")
        ON = false
    else
        mp.observe_property("chapter", "number", skip_current_chapter)
        mp.osd_message("[sponsorblock] on")
        ON = true
    end
    send_state(ON)
end

local function file_loaded()
    ranges = nil
    ON = false
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
    
    -- Fetch sponsor data
    local result = mp.command_native{
        name = "subprocess",
        capture_stdout = true,
        playback_only = false,
        args = {
            "curl", "-L", "-s", "-G", 
            "--data-urlencode", "categories=[" .. parsed_categories .. "]",
            "--data-urlencode", "videoID=" .. youtube_id,
            options.server
        }
    }

    if not result.stdout then return end
    
    local json = utils.parse_json(result.stdout)
    if type(json) ~= "table" or not json[1] then return end
    
    ranges = json

    if not ranges or ranges[1] == "No valid categories provided." then return end
    local existing_chapters = mp.get_property_native("chapter-list") or {}
    options.button_badge = count_preexisting_segment(existing_chapters)
    
    -- Create chapters for new segments
    for _, segment in pairs(ranges) do
        local start_time = segment.segment[1]
        
        if not is_duplicate_segment(existing_chapters, start_time) then
            local end_title = find_restore_title(existing_chapters, start_time)
            add_sponsorblock_segment(segment, end_title)
            options.button_badge = options.button_badge + 1
        end
    end

	-- in case there is a segment at the end of the video but no closing chapter, insert one.
	local last_chapter = existing_chapters[#existing_chapters]
	if last_chapter and last_chapter.title and last_chapter.title:match("^%[SponsorBlock%]:") then
		create_chapter('EOF', mp.get_property_number("duration"))
	end
    
    ON = true
    send_state(ON)
    mp.observe_property("chapter", "number", skip_current_chapter)
    mp.add_forced_key_binding("b","sponsorblock",toggle)
end

mp.register_event("file-loaded", file_loaded)
mp.register_event("seek", skip_current_chapter)
