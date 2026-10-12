# Kick.com plugin for VLC

A Lua playlist plugin that lets VLC open **Kick.com** links directly: live streams, VODs (including `?t=` timestamps) and clips.

Paste a Kick link into VLC (**Media → Open Network Stream**, `Ctrl+N`), or open it from the command line, and the plugin resolves it to the actual HLS stream. The stream title, channel name and category appear in VLC's playlist and media information.

Works with **VLC 3.0.x** and **VLC 4.0-dev**.

---

## Features

- **Live streams**: open a channel link and VLC starts at the live edge, at the best available quality.
- **VODs**: past broadcasts, including ones still being recorded.
- **VOD timestamps**: `?t=54582` or `?t=15h9m42s` starts playback at that point.
- **Clips**: both the clip page link and the `?clip=` dialog link.
- **Ad-free VODs with fast seeking**: VODs play from the raw recording in ≈2-second byte-range chunks, so a seek downloads ~2 MB instead of a whole 12 MB segment.
- **Metadata**: title, streamer name, category and clip author are filled in.
- **Fallbacks**: if Kick's current web API fails, the plugin tries Kick's older API.
- **Configurable**: maximum resolution, live latency and VOD source order are set at the top of the file.

## Supported links

| Type | Example |
|---|---|
| Live stream | `https://kick.com/deenthegreat` |
| VOD | `https://kick.com/deenthegreat/videos/01a10f04-4ed8-75b4-96b7-b893d9241deb` |
| VOD from a timestamp | `https://kick.com/deenthegreat/videos/01a123f6-1fd8-7f4c-91dd-a46b3a078cee?t=54582` |
| VOD (old style link) | `https://kick.com/video/01a123f6-1fd8-7f4c-91dd-a46b3a078cee` |
| Clip | `https://kick.com/deenthegreat/clips/clip_01M4831J8DN8EWH2R883E72YR8` |
| Clip (dialog link) | `https://kick.com/deenthegreat?clip=clip_01M4831J8DN8EWH2R883E72YR8` |

`www.kick.com` and `m.kick.com` links work too.

The timestamp `t` accepts plain seconds (`54582`) or `h`/`m`/`s` notation (`15h9m42s`, `1h5m`, `90s`). A timestamp past the end of the video is ignored.

## Requirements

- VLC 3.0 or newer (VLC 4.0-dev included)
- `curl` on the system `PATH`:
  - **Windows 10/11**: already included (`C:\Windows\System32\curl.exe`)
  - **macOS**: already included
  - **Linux**: usually installed already. If not, install it with your package manager, e.g. `sudo apt install curl`

`curl` is needed because VLC's Lua API can't send POST requests or custom HTTP headers, and Kick's API requires both.

## Installation

1. Download [`kick.lua`](kick.lua).
2. Copy it into VLC's `lua/playlist` folder:

   | OS | Folder |
   |---|---|
   | Windows (current user) | `%APPDATA%\vlc\lua\playlist\` |
   | Windows (all users) | `C:\Program Files\VideoLAN\VLC\lua\playlist\` |
   | Linux (current user) | `~/.local/share/vlc/lua/playlist/` |
   | Linux (all users) | `/usr/lib/x86_64-linux-gnu/vlc/lua/playlist/` (path varies by distro) |
   | macOS (current user) | `~/Library/Application Support/org.videolan.vlc/lua/playlist/` |
   | macOS (all users) | `/Applications/VLC.app/Contents/MacOS/share/lua/playlist/` |

   Create the folder if it doesn't exist.
3. Restart VLC.

The current-user folders need no admin rights and survive VLC updates.

## Usage

**In the VLC window:** go to **Media → Open Network Stream** (`Ctrl+N`), paste a Kick link and click **Play**.

**From the command line:**

```sh
vlc "https://kick.com/deenthegreat"
vlc "https://kick.com/deenthegreat/videos/01a123f6-1fd8-7f4c-91dd-a46b3a078cee?t=54582"
vlc "https://kick.com/deenthegreat/clips/clip_01M4831J8DN8EWH2R883E72YR8"
```

Put the link in quotes, because the shell treats `?` and `&` as special characters.

## Configuration

To change a setting, edit it at the top of `kick.lua` and restart VLC:

| Setting | Default | Meaning |
|---|---|---|
| `CURL` | `"curl"` | curl executable. Use a full path if curl isn't on `PATH`. |
| `MAX_HEIGHT` | `0` | Highest resolution to play, e.g. `720` or `1080`. `0` = best available. |
| `OPTIONS` | `{ ":adaptive-logic=highest" }` | Extra VLC input options for every item. `highest` starts at the best quality instead of ramping up. `":adaptive-logic=nearoptimal"` adapts to bandwidth instead. |
| `LIVE_EDGE_DELAY_MS` | `0` | Distance from the live edge in ms. `0` = VLC default. Larger values, e.g. `15000`, add latency but stall less. |
| `VOD_SOURCES` | `{ "dvr", "vod" }` | Order in which VOD sources are tried. `dvr` = plain recording (no ads), `vod` = Kick's version with ads inserted. |
| `VOD_PREFER_RAW` | `true` | Play VODs from the raw recording on `stream.kick.com` instead of Kick's ad-stitched manifest. Uses the byte-range playlist (≈2 s chunks) when available, for fast seeking. |
| `SPLIT_AT_TS_WRAP` | `true` | Split long VODs into parts (see [Long VODs](#long-vods)). `true` = always, `"auto"` = VLC 3 only, `false` = never. |
| `MAX_PART_S` | `43200` (12 h) | Longest part of a split VOD, in seconds. Keep it below 13 hours. |

## How it works

| Link | Steps |
|---|---|
| **Live** | 1. `GET web.kick.com/api/v1/channels/<channel>/livestream` returns the current stream id.<br>2. `POST web.kick.com/api/v1/stream/<id>/playback` (the same request Kick's web player makes) returns the live HLS URL and metadata. |
| **VOD** | `POST web.kick.com/api/v1/stream/<id>/playback` returns the recording URL (`dvr`) or the version with ads (`vod`), plus metadata. The timestamp is passed to VLC as `:start-time`. |
| **Clip** | `GET web.kick.com/api/v1/clips/<id>` returns the clip's HLS playlist, or its MP4 file if there is no playlist. |

If a request fails or Cloudflare blocks it, the plugin falls back to Kick's older endpoints:

- `kick.com/api/v2/channels/<channel>/info`
- `kick.com/api/v2/channels/<channel>/playback-url`
- `kick.com/api/v2/channels/<channel>`
- `kick.com/api/v1/video/<id>`
- `kick.com/api/v2/clips/<id>`

The plugin only uses public, logged-out endpoints. It needs no account, cookies or tokens, and sends no personal data.

## Troubleshooting

To see what the plugin is doing, open **Tools → Messages**, set the verbosity to **2 (debug)** and filter by `Kick:`. Then open the link again.

| Message | Cause / fix |
|---|---|
| `Kick: <channel> is offline` | The channel isn't live. Its VODs still work. |
| `blocked by Cloudflare` | Kick's Cloudflare protection rejected curl. Try again later, from another network, or with a newer curl. If it keeps happening, please open an issue. |
| `empty response (is curl installed?)` | curl is missing or not on `PATH`. Set `CURL` to the full path of the curl executable. |
| `failed to parse channel name from url` | The link isn't in one of the supported formats. |
| Slow seeking in a VOD | Make sure `VOD_PREFER_RAW = true`. The log should show `using the raw recording …/byte-range-multivariant.m3u8`. Lowering `MAX_HEIGHT` (e.g. `720`) also makes chunks smaller. |
| VOD stuck at "Buffering 0%" (VLC 3), or VLC 4 crashes with `Assertion failed! ... FakeESOut.cpp ... ts >= VLC_TICK_INVALID` | The VOD is too long for VLC to seek in. Make sure `SPLIT_AT_TS_WRAP = true` and `MAX_PART_S` is below 13 hours, and see [Long VODs](#long-vods). The log should show `Kick: VOD is … long, timestamp wrap …, split into N parts`. |
| Many `http error: local stream N error: Cancellation (0x8)` lines | Harmless. VLC drops requests for byte-range chunks it no longer needs, mostly while jumping to `?t=` or seeking. Ignore them if the video plays. |
| `no playable source for VOD` | The VOD was deleted, made private, or has expired (Kick keeps VODs for a limited time). |
| Nothing happens, VLC shows a web page error | The plugin isn't loaded. Check the install folder and restart VLC. |

**Windows:** a console window may flash briefly when a link is opened. That's curl running, and it's harmless.

## Long VODs

Video timestamps in Kick's recordings (MPEG-TS) wrap around to zero every **26.5 hours of video** (2³³ ticks at 90 kHz). Recordings don't start at zero, so the wrap can come much earlier, e.g. 12 hours in. Neither VLC version can play or seek across this point. VLC 3 gets stuck at "Buffering 0%" with a black screen. VLC 4.0-dev builds stop with `Assertion failed! ... FakeESOut.cpp ... Expression: ts >= VLC_TICK_INVALID` and close.

There is a second limit. VLC treats any timestamp jump of more than half that cycle (**13.25 hours**) as a wrap. So even without a wrap, opening a VOD at `?t=` or seeking more than 13.25 hours from where VLC started reading fails the same way.

To work around this, the plugin reads the first timestamp of the VOD and works out where the wraps fall. It then splits the VOD into parts:

- Parts are cut at every wrap point, and no part is longer than 12 hours (`MAX_PART_S`). A 38-hour VOD with a wrap at 26:29 becomes 4 parts: from 0:00:00, 12:00:00, 24:00:00 and 26:29:42.
- Each part is a playlist item named like `… [part 2/4, from 12:00:00]`. The parts play one after another.
- Playback starts in the part that contains `?t=`. Earlier parts are left out.
- Inside a part, VLC's time display counts from the start of that part, not the start of the VOD. The item name shows where the part begins.
- The part playlists are small text files (about 1 MB each) saved in your temp folder (`%TEMP%` on Windows) as `kick_<video id>_partN.m3u8`. Opening the same VOD again overwrites them.

VODs shorter than 12 hours without a wrap play as a single item, exactly as before. Set `SPLIT_AT_TS_WRAP = "auto"` to split on VLC 3 only, or `false` to never split.

## Known limitations

- **Live ads on VLC 3.** Kick inserts ads directly into the live stream. On VLC 3, the switch from an ad back to the stream can cause a black screen or a freeze. Re-open the link to recover. VLC 4 handles this switch itself.
- **Subscriber-only content** isn't supported, because the plugin doesn't log in.
- **Kick changes its API often.** If links stop working after a Kick website update, please open an issue and include the debug log.

## Contributing

Bug reports and pull requests are welcome. When reporting a problem, include:

- your VLC version (**Help → About**) and OS
- the Kick link you tried to open
- the `Kick:` lines from the debug log (see [Troubleshooting](#troubleshooting))

A HAR file of the failing Kick page, from your browser's DevTools → **Network** → **Save all as HAR**, is the fastest way to adapt the plugin to API changes. Before sharing it, remove the cookies and any `Authorization` headers.

## Changelog

### 1.0.4
- Fixed: VLC 3 stuck at "Buffering 0%" when a long VOD was opened at a `?t=` more than 13.25 hours into a part. Split VODs now have parts of at most 12 hours (`MAX_PART_S`), and VODs longer than 12 hours are split even without a timestamp wrap.

### 1.0.3
- Fixed: VLC 4.0-dev closed with `Assertion failed: ts >= VLC_TICK_INVALID` (FakeESOut.cpp) on long VODs. Long VODs are now split at MPEG-TS timestamp wraps on VLC 4 too (`SPLIT_AT_TS_WRAP = true` by default).

### 1.0.2
- VODs always play from the raw recording on `stream.kick.com`, using its byte-range playlist when available. Seeking and `?t=` downloads ~2 MB chunks instead of whole ~12 MB segments. This also avoids the ad-stitched manifest, where the VLC 4 seek bar could fail.
- Byte-range offsets are written out explicitly in split VOD parts.

### 1.0.1
- Fixed: on VLC 3, long VODs got stuck at "Buffering 0%" when opened or seeked past an MPEG-TS timestamp wrap. They're now split into parts at the wrap points.
- VODs play from the raw recording (no ads) when Kick returns only the version with ads.
- VODs play at the best quality up to `MAX_HEIGHT` when split into parts.

### 1.0.0
- First release: live streams, VODs with `?t=` timestamps, and clips
- Uses Kick's current web API (`web.kick.com`), with the older `kick.com/api` as a fallback
- VLC 3.0 and VLC 4.0-dev support (Lua 5.1 – 5.4)

## License

[GNU General Public License v2.0 or later](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html), the same license as VLC's bundled Lua scripts. See the header of [`kick.lua`](kick.lua).

This project isn't affiliated with or endorsed by Kick or VideoLAN.
