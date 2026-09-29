-- sponsorblock_chapterized.lua (minimal)
-- Extracts SponsorBlock segments from ytdl-hook JSON and adds them as chapters.
-- Chapters are drawn by uosc. Segments are skipped based on playback time.

local mp = require "mp"
local utils = require "mp.utils"
local msg = require "mp.msg"

local ON = false
local segment_cache = {}
local chapter_list = {}
local duration = 0

local options = {
    categories = "sponsor,selfpromo,interaction",
    show_only_cats = "intro, outro, music_offtopic, preview, poi_highlight, filler, exclusive_access",
    show_msg_duration = 3,
    skip_unknown = false,
}

for key, value in pairs(options) do
    local opt = mp.get_property_native("options/" .. key)
    if opt then options[key] = opt end
end

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

local show_only_lookup = {}
for cat in options.show_only_cats:gsub("%s", ""):gmatch("[^,]+") do
    show_only_lookup[string.lower(cat:gsub("_", " "))] = true
end
local cats_lookup = {}
for cat in options.categories:gsub("%s", ""):gmatch("[^,]+") do
    cats_lookup[string.lower(cat:gsub("_", " "))] = true
end

local function match_category(title)
    if not title then return nil end
    local p = "^%[SponsorBlock%]: (.+)"
    return title:match(p)
end

local function is_youtube()
    local path = mp.get_property("path", "")
    for _, pattern in ipairs(yt_patterns) do
        if path:match(pattern) then return true end
    end
    return false
end

local function add_sponsorblock_segment(start_time, end_time, category)
    local start_chapter = {title = "[SponsorBlock]: " .. category, time = start_time}
    table.insert(chapter_list, start_chapter)
    local end_chapter = {title = "", time = end_time}
    table.insert(chapter_list, end_chapter)
    table.insert(segment_cache, {
        start = start_time,
        ["end"] = end_time,
        category = category,
    })
end

local function extract_sponsor_data()
    local json_results = mp.get_property_native("user-data/mpv/ytdl/json-subprocess-result")
    if not json_results then return false end
    local stdout_value = json_results["stdout"]
    if not stdout_value then return false end
    local raw_data = utils.parse_json(stdout_value)["sponsorblock_chapters"]
    if not raw_data then return false end
    for _, dataset in ipairs(raw_data) do
        if dataset and dataset["start_time"] and dataset["end_time"] and dataset["category"] then
            add_sponsorblock_segment(dataset["start_time"], dataset["end_time"], dataset["category"])
        end
    end
    return #segment_cache > 0
end

local function rebuild_segment_cache()
    segment_cache = {}
    for i, chapter in ipairs(chapter_list) do
        local category = match_category(chapter.title)
        if category then
            local next_ch = chapter_list[i + 1]
            local end_time = next_ch and next_ch.time or duration - 0.001
            if end_time > chapter.time then
                table.insert(segment_cache, {
                    start = chapter.time,
                    ["end"] = end_time,
                    category = category,
                })
            end
        end
    end
end

local function skip_ads(name, pos)
    if not pos or not ON then return end
    for _, range in ipairs(segment_cache) do
        if not range or not range["end"] or not range.start then goto next_range end
        ::next_range::
        if range.start <= pos and pos < (range["end"] - 0.0005) then
            local cat_lower = string.lower(range.category):gsub("_", " ")
            if show_only_lookup[cat_lower] then
                return  -- mark only, don't skip
            elseif cats_lookup[cat_lower] then
                local skip_to = math.min(range["end"] + 0.01, duration - 0.1)
                msg.info("Skipping " .. range.category .. " at " .. pos .. " -> " .. skip_to)
                mp.osd_message("[sponsorblock] skipping " .. range.category, options.show_msg_duration)
                mp.set_property("time-pos", skip_to)
                return
            else
                if not options.skip_unknown then
                    return
                end
            end
        end
    end
    ::next_range::
end

local function file_loaded()
    ON = false
    segment_cache = {}
    chapter_list = mp.get_property_native("chapter-list", {})
    duration = mp.get_property_native("duration") or 0
    
    if not is_youtube() then
        msg.debug("Not a YouTube stream, aborting")
        return
    end
    
    msg.debug("Trying to extract sponsorblock data from ytdl hook")
    if not extract_sponsor_data() then
        msg.debug("Failed to get data from ytdl hook")
        return
    end
    
    msg.info("Added " .. #segment_cache .. " sponsor chapters")
    mp.set_property_native("chapter-list", chapter_list)
    ON = true
    mp.observe_property("time-pos", "native", skip_ads)
end

mp.register_event("file-loaded", file_loaded)

-- Enable sponsorblock-mark for ytdl hook
local opts = mp.get_property_native("ytdl-raw-options") or {}
opts["sponsorblock-mark"] = "all"
mp.set_property_native("ytdl-raw-options", opts)
