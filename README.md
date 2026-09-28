Minimal SponsorBlock integration for UOSC chapter bar highlighting.

**Data sources:**
1. ytdl_hook — primary, fetches sponsor data from SponsorBlock API
2. Embedded chapters — works with pre-existing `[SponsorBlock]:` chapters

**No:** curl API calls, no hash prefix, no caching. Simple and direct.

**Key features:**
- Timer-based segment checking (checks every 0.2s)
- `categories` — which categories to skip
- `show_only_cats` — mark but don't skip
- UOSC button support (`button:Sponsorblock_Button` in uosc.conf)
- Toggle on/off with `b`

**Prerequisites:**
- ytdl_hook (for API data) or pre-existing `[SponsorBlock]:` chapters

Links:
- Original mpv sponsorblock: https://github.com/po5/mpv_sponsorblock
- SponsorBlock API: https://github.com/ajayyy/SponsorBlock
