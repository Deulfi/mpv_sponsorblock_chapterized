-- sponsorblock_chapterized.lua
-- Automatically integrates SponsorBlock data into MPV chapter lists
-- and provides chapter-based skipping.

local msg = mp.msg
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

local function split(str, delim)
    local result = {}
    for part in string.gmatch(str, "[^" .. delim .. "]+") do
        table.insert(result, part)
    end
    return result
end

local cats_lookup = {}
for _, cat in ipairs(split(options.categories, ",")) do
    cats_lookup[string.lower(string.gsub(cat, "%s+", ""))] = true
end

local show_only_lookup = {}
for _, cat in ipairs(split(options.show_only_cats, ",")) do
    show_only_lookup[string.lower(string.gsub(cat, "%s+", ""))] = true
end

local function process_category(cat)
    return string.gsub(string.lower(cat), "%s+", "")
end

local function match_category(title)
    if not title then return nil end
    return title:match('^"?%[SponsorBlock%]: (.-)"?$')
end

local function find_chapter_by_time(time, tolerance)
    for _, chapter in ipairs(chapter_list) do
        if math.abs(chapter.time - time) <= tolerance then
            return chapter
        end
    end
    return nil
end

local function find_or_create_chapter(time, title, tolerance)
    local existing = find_chapter_by_time(time, tolerance)
    if existing then return existing end
    local new_chapter = {title = title, time = time}
    table.insert(chapter_list, new_chapter)
    return new_chapter
end

local function add_sponsorblock_segment(seg)
    local start_time = seg.segment[1]
    local end_time = seg.segment[2]
    local category = seg.category
    find_or_create_chapter(start_time, "[SponsorBlock]: " .. category)
    find_or_create_chapter(end_time, "")
end

local function rebuild_segment_cache()
    segment_cache = {}
    num_seg_found = 0
    for i, chapter in ipairs(chapter_list) do
        local category = match_category(chapter.title)
        if category then
            local next_ch = chapter_list[i + 1]
            local end_time = next_ch and next_ch.time or duration - 0.001
            table.insert(segment_cache, {
                start = chapter.time,
                ['end'] = end_time,
                category = category,
            })
            num_seg_found = num_seg_found + 1
        end
    end
end

local function get_actionable_segment(start_time)
    local skip_unknown = options.skip_unknown
    if type(skip_unknown) == "string" then
        skip_unknown = skip_unknown == "yes"
    end
    for _, range in ipairs(segment_cache) do
        local matches = range.start <= start_time and start_time < (range['end'] - 0.0005)
        msg.info("  seg_check:", range.start, "->", range['end'], "cat:", range.category, "t:", start_time, "m:", matches, "sk:", skip_unknown)
        if matches then
            local cat = string.lower(process_category(range.category))
            if show_only_lookup[cat] then
                msg.info("  -> skip_only (mark only)")
                return nil
            elseif cats_lookup[cat] then
                msg.info("  -> actionable (in categories)")
                return range
            else
                if skip_unknown then
                    msg.info("  -> actionable (skip_unknown)")
                    return range
                end
                msg.info("  -> skip_only (unknown, skip_unknown=false)")
                return nil
            end
        end
    end
    msg.info("  -> no segment for t:", start_time)
    return nil
end

local last_skip_position = 0
local skip_times = {0, 0, 0, 0, 0}
local skip_index = 1
local function skip_current_chapter()
    local cur_chapter_index = mp.get_property_number("chapter")
    if not cur_chapter_index or cur_chapter_index < 0 then return end
    local chapter_time = mp.get_property_number("chapter-list/" .. cur_chapter_index .. "/time")
    if not chapter_time then return end
    msg.info("skip_check: ch=", cur_chapter_index, "time=", chapter_time)
    local now = mp.get_time()
    local prev = skip_times[skip_index]
    skip_times[skip_index] = now
    skip_index = skip_index % 5 + 1
    if now - prev < 0.2 then msg.info("  -> debounce"); return end
    msg.info("  cache_size=", #segment_cache)
    local segment = get_actionable_segment(chapter_time)
    if not segment then
        msg.info("  -> no actionable segment")
        return
    end
    local skip_to = math.min(segment['end'] + 0.01, duration - 0.1)
    if math.abs(chapter_time - last_skip_position) < 0.5 and skip_to <= last_skip_position + 0.5 then
        msg.info("  -> debounce2")
        return
    end
    last_skip_position = skip_to
    local cat = process_category(segment.category)
    msg.info("  skipping", cat, chapter_time, "->", skip_to, "(seg_end:", segment['end'], "dur-0.1:", duration-0.1, ")")
    mp.osd_message("[sponsorblock] skipping " .. cat, options.show_msg_duration)
    mp.set_property("time-pos", skip_to)
end

local function toggle_skip()
    ON = not ON
    if ON then
        msg.info("skipping enabled")
    else
        msg.info("skipping disabled")
    end
end

local function activate_sponsorblock()
    if sponsor_data then
        for _, seg in pairs(sponsor_data) do
            add_sponsorblock_segment(seg)
        end
    end
    rebuild_segment_cache()
    mp.set_property_native("chapter-list", chapter_list)
    msg.info("added", num_seg_found, "sponsor chapters")
    ON = true
    mp.observe_property("chapter", "number", skip_current_chapter)
    mp.add_forced_key_binding("b", "sponsorblock", toggle_skip)
end

local function file_loaded()
    msg.info("file_loaded")
    ON = false
    sponsor_data = nil
    segment_cache = {}
    chapter_list = mp.get_property_native("chapter-list", {})
    duration = mp.get_property_native("duration") or 0
    local json_results = mp.get_property_native("user-data/mpv/ytdl/json-subprocess-result")
    if json_results and json_results["stdout"] then
        local raw_data = utils.parse_json(json_results["stdout"])["sponsorblock_chapters"]
        if raw_data then
            sponsor_data = {}
            for _, dataset in ipairs(raw_data) do
                table.insert(sponsor_data, {
                    segment = {dataset["start_time"], dataset["end_time"]},
                    category = dataset["category"]
                })
            end
            msg.info("extracted", #sponsor_data, "segments from ytdl_hook")
            activate_sponsorblock()
            return
        end
    end
    -- Fallback: build segment_cache from embedded [SponsorBlock]: chapters
    for i, chapter in ipairs(chapter_list) do
        local category = match_category(chapter.title)
        if category then
            local next_ch = chapter_list[i + 1]
            local end_time = next_ch and next_ch.time or duration - 0.001
            table.insert(segment_cache, {
                start = chapter.time,
                ['end'] = end_time,
                category = category
            })
        end
    end
    if #segment_cache > 0 then
        msg.info("extracted", #segment_cache, "segments from local chapters")
        activate_sponsorblock()
    end
end

mp.register_script_message("manual_sponsorblock_pull", function(args)
    msg.info("manual_sponsorblock_pull")
    if not args or args == "" then
        msg.error("no manual data provided")
        return
    end
    local data = utils.parse_json(args)
    if not data then
        msg.error("invalid manual data json")
        return
    end
    sponsor_data = {}
    for _, dataset in ipairs(data) do
        table.insert(sponsor_data, {
            segment = {dataset["start_time"], dataset["end_time"]},
            category = dataset["category"]
        })
    end
    msg.info("injected", #sponsor_data, "segments manually")
    if chapter_list then
        activate_sponsorblock()
    end
end)

mp.register_event("file-loaded", file_loaded)
