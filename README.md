# SponsorBlock Chapter Integration for mpv with UOSC

Adds SponsorBlock segments from ytdl-hook data as chapters for uosc seekbar highlighting. Skips active sponsor segments while playing based on the timestamps of the provided segments.

The script can be toggled off and on with `b` when the video has sponsor segments.

## Options

Configuration in `sponsorblock_chapterized.conf`:

| Option | Description |
|--------|-------------|
| `categories` | Comma-separated categories to skip (use `_` for spaces) |
| `show_only_cats` | Comma-separated categories to mark but not skip |
| `skip_unknown` | Skip segments not in configured categories |
| `show_msg_duration` | Duration of OSD skip messages (seconds) |

## Links

- Original mpv sponsorblock: https://github.com/po5/mpv_sponsorblock
- SponsorBlock: https://github.com/ajayyy/SponsorBlock
