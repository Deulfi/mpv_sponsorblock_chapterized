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

	-- Categories to fetch and skip types are [sponsor selfpromo interaction intro outro preview music_offtopic]
	categories = '"sponsor","selfpromo"',

	-- Set this to "true" to use sha256HashPrefix instead of videoID
	hash = "",
	-- duration the osd message shows up
	show_msg = 3,
	-- Skip each chapter only once
	skip_once = true
}

opt.read_options(options)

function skip_sponsorblock_chapter(_, current_chapter)
	if not ON or not current_chapter or current_chapter < 0 then return end
	
	local chapters = mp.get_property_native("chapter-list")
	if not chapters then return end
	-- Check if current chapter is a SponsorBlock chapter
	local current_chapter_index = current_chapter + 1 -- Lua is 1-indexed

	if current_chapter_index <= #chapters then
		local chapter = chapters[current_chapter_index]
		if chapter.title and string.match(chapter.title, "^%[SponsorBlock%]:") then
			-- Check if we should skip this chapter
			if not options.skip_once or not skipped_chapters[current_chapter_index] then
				local category = string.match(chapter.title, "^%[SponsorBlock%]: (.+)")
				mp.osd_message(("[sponsorblock] skipping %s"):format(category or "segment"), options.show_msg)
				
				-- Simply jump to next chapter
				mp.set_property("chapter", current_chapter + 1)
				skipped_chapters[current_chapter_index] = true
			end
		end
	end
end

function file_loaded()
	-- Reset for new file
	skipped_chapters = {}
	ranges = nil
	ON = false
	send_state(ON)
	
	local video_path = mp.get_property("path", "")
	local video_referer = string.match(mp.get_property("http-header-fields", ""), "Referer:([^,]+)") or ""

	local urls = {
		"ytdl://youtu%.be/([%w-_]+).*",
		"ytdl://w?w?w?%.?youtube%.com/v/([%w-_]+).*",
		"https?://youtu%.be/([%w-_]+).*",
		"https?://w?w?w?%.?youtube%.com/v/([%w-_]+).*",
		"/watch.*[?&]v=([%w-_]+).*",
		"/embed/([%w-_]+).*",
		"^ytdl://([%w-_]+)$",
		"-([%w-_]+)%."
	}
	local youtube_id = nil
	local purl = mp.get_property("metadata/by-key/PURL", "")
	for i,url in ipairs(urls) do
		youtube_id = youtube_id or string.match(video_path, url) or string.match(video_referer, url) or string.match(purl, url)
		if youtube_id then break end
	end

	if not youtube_id or string.len(youtube_id) < 11 then return end
	youtube_id = string.sub(youtube_id, 1, 11)

	local args = {"curl", "-L", "-s", "-G", "--data-urlencode", ("categories=[%s]"):format(options.categories)}
	local url = options.server
	if options.hash == "true" then
		local sha = mp.command_native{
			name = "subprocess",
			capture_stdout = true,
			args = {"sha256sum"},
			stdin_data = youtube_id
		}
		url = ("%s/%s"):format(url, string.sub(sha.stdout, 0, 4))
	else
		table.insert(args, "--data-urlencode")
		table.insert(args, "videoID=" .. youtube_id)
	end
	table.insert(args, url)

	local sponsors = mp.command_native{
		name = "subprocess",
		capture_stdout = true,
		playback_only = false,
		args = args
	}
	if sponsors.stdout then
		local json = utils.parse_json(sponsors.stdout)

		if type(json) == "table" then
			if options.hash == "true" then
				for _, i in pairs(json) do
					if i.videoID == youtube_id then
						ranges = i.segments
						break
					end
				end
			else
				ranges = json
			end

			-- Add sponsorblock segments as chapters
			if ranges then
				local chapter_list = mp.get_property_native("chapter-list") or {{title = "", time = 0}}

				for _, i in pairs(ranges) do
					msg.info("ranges: " .. utils.to_string(i.segment))
					msg.info("category: " .. i.category)

					-- Insert chapters for sponsor segments
					table.insert(chapter_list, {title = "[SponsorBlock]: ".. i.category, time = i.segment[1]})
					table.insert(chapter_list, {title = " ", time = i.segment[2]})
				end

				-- Sort chapters by time
				table.sort(chapter_list, function(a, b) return a.time < b.time end)
				mp.set_property_native("chapter-list", chapter_list)

				ON = true
				send_state(ON)
				mp.add_forced_key_binding("b","sponsorblock",toggle)
				mp.observe_property("chapter", "number", skip_sponsorblock_chapter)
			end
		end
	end
end


function toggle()
	if ON then
		mp.unobserve_property(skip_sponsorblock_chapter)
		mp.osd_message("[sponsorblock] off")
		ON = false
	else
		mp.observe_property("chapter", "number", skip_sponsorblock_chapter)
		mp.osd_message("[sponsorblock] on")
		ON = true
	end
	send_state(ON)
end

function send_state(on_state)
	mp.commandv('script-message-to', 'ucm_sponsorblock_minimal_plugin', 'update-icon', tostring(on_state))
end

mp.register_event("file-loaded", file_loaded)
mp.register_event("seek", function() 
    skip_sponsorblock_chapter(nil, mp.get_property_number("chapter"))
end)
