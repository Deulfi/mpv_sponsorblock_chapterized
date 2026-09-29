# SponsorBlock Chapter Integration for mpv with UOSC

Extracts SponsorBlock segments from ytdl-hook chapter data and adds them as chapters so uosc highlights them on the seekbar. Skips active sponsor segments while playing using chapter-based monitoring. Falls back to direct API calls via curl if ytdl-hook provides no data and the fallback flag is active.

For YouTube: extracts fresh segment data from ytdl-hook, creates new SponsorBlock chapter markers at segment boundaries, and preserves non-segment chapters that are not inside sponsor segments. For local files with baked-in SponsorBlock chapters: deduplicates nearby entries using configurable tolerance.

Toggle with `b`. Manual API pull: `B script-message-to sponsorblock_chapterized manual_sponsorblock_pull`

## Options

Configuration in `sponsorblock_chapterized.conf`:

| Option | Description |
|--------|-------------|
| `categories` | Comma-separated categories to skip (use `_` for spaces) |
| `show_only_cats` | Comma-separated categories to mark but not skip |
| `show_msg_duration` | Duration of OSD skip messages (seconds) |
| `skip_unknown` | Skip segments not in configured categories |
| `uosc_button` | Show UOSC toggle button |
| `use_ucm_plugin` | Send button info via uosc_controls_modifier plugin |
| `show_sponsor_count` | Show badge count of segments |
| `button_enabled_icon` | Button icon when enabled |
| `button_disabled_icon` | Button icon when disabled |
| `button_tooltip` | Button tooltip text |
| `use_curl_fallback` | Enable curl API fallback |
| `server` | SponsorBlock API server URL for curl fallback or manual pull |
| `hash` | SponsorBlock API hash for video identification for curl fallback or manual pull |
| `min_segment_length` | Minimum segment length in seconds |
| `time_tolerance` | Floating point tolerance for chapter matching |
| `nearby_merge_tolerance` | Tolerance for merging nearby chapters |

## Links

- Original mpv sponsorblock: https://github.com/po5/mpv_sponsorblock
- SponsorBlock: https://github.com/ajayyy/SponsorBlock
