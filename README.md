(This version generates chapters for sponsor segments, which are detected by uosc and highlighted in red on the seekbar. 
Put button:Sponsorblock_Button in the controls= of your uosc.conf for a button.
Drag the playback into the segment if you want to watch it. Also works with baked in chapters (if your yt-dlp embeds them for example).)

This is a much more simple version of the sponsorblock mpv plugin.

There are no other functions in this other than the sponsor skipping. Also this 
uses curl rather than python to get the ranges. There is also no cache so the 
ranges will get redownloaded if you watch a video more than once.

b toggles between on/off

Prerequisites:

Either lua-curl https://github.com/Lua-cURL/Lua-cURLv3 or curl https://github.com/curl/curl should be installed in the system.

Link to the original mpv sponsorblock plugin:
https://github.com/po5/mpv_sponsorblock

Link to sponsorblock:
https://github.com/ajayyy/SponsorBlock
