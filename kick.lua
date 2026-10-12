--[[
 Resolve Kick.com live channels, VODs (with ?t= timestamp) and clips
 to the actual HLS stream URL.

 Supported links:
   https://kick.com/<channel>                          live stream
   https://kick.com/<channel>/videos/<uuid>            VOD
   https://kick.com/<channel>/videos/<uuid>?t=54582    VOD from a timestamp
   https://kick.com/video/<uuid>                       VOD (old style link)
   https://kick.com/<channel>/clips/clip_<id>          clip
   https://kick.com/<channel>?clip=clip_<id>           clip (dialog link)
 ?t= accepts seconds (54582) or 15h9m42s style values.

 Works with VLC 3.0.x and VLC 4.0-dev (Lua 5.1 / 5.2 / 5.4).

 Install: copy this file into the "lua/playlist" folder of VLC
   Windows (all users): C:\Program Files\VideoLAN\VLC\lua\playlist\
   Windows (current user): %APPDATA%\vlc\lua\playlist\
   Linux:   ~/.local/share/vlc/lua/playlist/
   macOS:   ~/Library/Application Support/org.videolan.vlc/lua/playlist/

 Needs curl (bundled with Windows 10+, macOS and most Linux distros):
 VLC's Lua API can't send POST requests or custom headers.

 Author: mmrry <sl2007 at yandex dot com>

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation; either version 2 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program; if not, write to the Free Software
 Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston MA 02110-1301, USA.
--]]

----------------------------------------------------------------------------
-- Settings
----------------------------------------------------------------------------

-- curl executable ("curl" = from PATH; on Windows 10+ that is System32\curl.exe)
local CURL = "curl"
-- Highest resolution to play. 0 = best available.
local MAX_HEIGHT = 0
-- Start on the best variant instead of ramping up from 160p
local OPTIONS = { ":adaptive-logic=highest" }
-- Distance from the live edge in ms. 0 = VLC default.
-- Larger values (e.g. 15000) trade latency for fewer stalls.
local LIVE_EDGE_DELAY_MS = 0
-- VOD source order. "dvr" is the raw recording on stream.kick.com (no ads),
-- "vod" is Kick's ad-stitched manifest on web.kick.com.
local VOD_SOURCES = { "dvr", "vod" }
-- Play VODs from the raw recording on stream.kick.com: no ads, working seek
-- bar, and byte-range chunks (~2 s) that make seeking and ?t= fast
local VOD_PREFER_RAW = true
-- Long VODs: MPEG-TS timestamps wrap around every 26.5 h of video (2^33 at
-- 90 kHz) and Kick recordings don't start at 0, so the wrap can fall anywhere.
-- VLC 3 can't play or seek past it (stuck at "Buffering 0%"), VLC 4.0-dev
-- aborts with "Assertion failed: ts >= VLC_TICK_INVALID" (FakeESOut.cpp).
-- The plugin then splits the VOD into parts at the wrap points (local
-- playlists in the temp folder) and starts in the part that holds ?t=.
-- true = always, "auto" = only on VLC 3, false = never
local SPLIT_AT_TS_WRAP = true

----------------------------------------------------------------------------

local UA       = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
              .. "(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
local WEB_API  = "https://web.kick.com/api"   -- current web player API
local SITE_API = "https://kick.com/api"       -- legacy API, used as fallback
local IS_WIN   = package.config:sub(1, 1) == "\\"
local TAG      = "Kick: "

local json_lib
local function json()
    json_lib = json_lib or require("dkjson")
    return json_lib
end

function probe()
    if vlc.access ~= "http" and vlc.access ~= "https" then
        return false
    end
    local host, path = vlc.path:match("^([%w%.%-]-)kick%.com/([^?#]*)")
    if not host then
        return false
    end
    -- Only the website itself: web.kick.com, stream.kick.com, clips.kick.com
    -- etc. serve the resolved media and must not loop back into this script
    if host ~= "" and host ~= "www." and host ~= "m." then
        return false
    end
    if path:match("^api/") then
        return false
    end
    return path:match("^[%w_%-]") ~= nil or vlc.path:match("[?&]clip=clip_") ~= nil
end

local function fail(msg)
    vlc.msg.err(TAG .. msg)
    return {}
end

-- Major VLC version (3, 4, ...). vlc.misc may not be exposed to playlist
-- scripts, so fall back to the Lua runtime: VLC 4 ships Lua 5.4, VLC 3 older.
local vlc_major_cache
local function vlc_major()
    if vlc_major_cache then return vlc_major_cache end
    local ok, v = pcall(function() return vlc.misc.version() end)
    local major = ok and v and tonumber(tostring(v):match("^(%d+)"))
    if not major then
        local lv = tonumber((_VERSION or ""):match("(%d+%.%d+)")) or 5.1
        major = (lv >= 5.4) and 4 or 3
    end
    vlc_major_cache = major
    return major
end

local function nonempty(s)
    if type(s) == "string" and s ~= "" then return s end
    return nil
end

-- Copy of the shared OPTIONS plus per-item extras
local function item_options(extra)
    local opts = {}
    for _, v in ipairs(OPTIONS) do opts[#opts + 1] = v end
    if MAX_HEIGHT > 0 then
        opts[#opts + 1] = ":adaptive-maxheight=" .. MAX_HEIGHT
    end
    opts[#opts + 1] = ":http-referrer=https://kick.com/"
    for _, v in ipairs(extra or {}) do opts[#opts + 1] = v end
    return opts
end

-- Quote a single shell argument (cmd.exe on Windows, sh elsewhere)
local function quote(s)
    if IS_WIN then
        return '"' .. (s:gsub('"', '\\"')) .. '"'
    end
    return "'" .. (s:gsub("'", "'\\''")) .. "'"
end

local seeded = false
local function uuid4()
    if not seeded then
        math.randomseed(os.time() + math.floor((os.clock() * 1e6) % 1e6))
        seeded = true
    end
    return (("xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"):gsub("[xy]", function(c)
        local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
        return string.format("%x", v)
    end))
end

-- HTTP request through the system curl. Returns decoded JSON or nil, error.
-- The request body must stay free of & | < > ^ % (cmd.exe on Windows).
local function api(url, body)
    local args = {
        CURL, "-sS", "--compressed", "--max-time", "15",
        "-A", quote(UA),
        "-H", quote("Accept: application/json"),
        "-H", quote("Origin: https://kick.com"),
        "-H", quote("Referer: https://kick.com/"),
        "-H", quote("x-app-platform: web"),
    }
    if body then
        args[#args + 1] = "-H"
        args[#args + 1] = quote("Content-Type: application/json")
        args[#args + 1] = "--data-binary"
        args[#args + 1] = quote(body)
    end
    args[#args + 1] = quote(url)

    local pipe = io.popen(table.concat(args, " "))
    if not pipe then
        return nil, "failed to run curl"
    end
    local resp = pipe:read("*a") or ""
    pipe:close()

    if resp == "" then
        return nil, "empty response (is curl installed?)"
    end
    local obj = json().decode(resp, 1, nil)
    if type(obj) ~= "table" then
        if resp:find("Just a moment", 1, true) or resp:find("cf%-chl") then
            return nil, "blocked by Cloudflare"
        end
        return nil, "bad response: " .. resp:sub(1, 120):gsub("%s+", " ")
    end
    return obj
end

-- First non-empty string in a decoded JSON tree whose key is in `keys`
-- (breadth-first, so top-level fields win)
local function find_field(tree, keys, match)
    local want = {}
    for _, k in ipairs(keys) do want[k] = true end
    local queue, head = { tree }, 1
    while queue[head] do
        local node = queue[head]
        head = head + 1
        for k, v in pairs(node) do
            if type(v) == "string" and want[k] and v ~= ""
               and (not match or v:find(match)) then
                return v
            elseif type(v) == "table" then
                queue[#queue + 1] = v
            end
        end
    end
    return nil
end

-- Parse "t" parameter: 54582, 15h9m42s, 1h5m, 90s -> seconds
local function parse_timestamp(t)
    if not t or t == "" then return nil end
    if t:match("^%d+$") then
        local n = tonumber(t)
        return (n and n > 0) and n or nil
    end
    if not t:match("^[%dhms]+$") then return nil end
    local mult = { h = 3600, m = 60, s = 1 }
    local total, consumed = 0, 0
    for num, unit in t:gmatch("(%d+)([hms])") do
        total    = total + tonumber(num) * mult[unit]
        consumed = consumed + #num + 1
    end
    if consumed ~= #t or total == 0 then return nil end
    return total
end

local function start_seconds(duration)
    local start = parse_timestamp(vlc.path:match("[?&]t=([%w]+)"))
    if not start then return nil end
    if duration and duration > 0 and start >= duration then
        vlc.msg.warn(TAG .. "timestamp " .. start .. "s is past the end, ignored")
        return nil
    end
    vlc.msg.dbg(TAG .. "starting at " .. start .. "s")
    return start
end

local function start_option(duration)
    local start = start_seconds(duration)
    return start and (":start-time=" .. start) or nil
end

local function hms(sec)
    sec = math.floor(sec)
    return string.format("%d:%02d:%02d", math.floor(sec / 3600),
                         math.floor(sec / 60) % 60, sec % 60)
end

----------------------------------------------------------------------------
-- HLS helpers (playlists are fetched through VLC's own network stack)
----------------------------------------------------------------------------

local function read_stream(s, limit)
    local parts, got = {}, 0
    while not limit or got < limit do
        local chunk = s:read(65536)
        if not chunk or chunk == "" then break end
        parts[#parts + 1] = chunk
        got = got + #chunk
    end
    return table.concat(parts)
end

local function http_get(url, limit)
    local ok, s = pcall(vlc.stream, url)
    if not ok or not s then return nil end
    local body = read_stream(s, limit)
    -- VLC asks for gzip; some playlists come back compressed
    if not limit and body:sub(1, 2) == "\31\139" then
        ok, s = pcall(vlc.stream, url)
        if not ok or not s or not s.addfilter then return nil end
        s:addfilter("inflate")
        body = read_stream(s)
    end
    if body == "" then return nil end
    return body
end

local function resolve_url(base, ref)
    if ref:match("^%a[%w+.-]*://") then return ref end
    if ref:sub(1, 2) == "//" then return base:match("^(%a[%w+.-]*:)") .. ref end
    if ref:sub(1, 1) == "/" then return base:match("^(%a[%w+.-]*://[^/]+)") .. ref end
    return base:gsub("[?#].*$", ""):match("^(.*/)") .. ref
end

-- Highest variant (resolution, then frame rate, then bitrate) not above MAX_HEIGHT
local function pick_variant(master, base)
    local best, best_key, fallback
    for attrs, uri in master:gmatch("#EXT%-X%-STREAM%-INF:([^\r\n]*)[\r\n]+([^\r\n#][^\r\n]*)") do
        uri = resolve_url(base, uri)
        fallback = fallback or uri
        local h   = tonumber(attrs:match("RESOLUTION=%d+x(%d+)")) or 0
        local fps = tonumber(attrs:match("FRAME%-RATE=([%d%.]+)")) or 0
        local bw  = tonumber(attrs:match("[^%-]BANDWIDTH=(%d+)") or attrs:match("^BANDWIDTH=(%d+)")) or 0
        if h > 0 and (MAX_HEIGHT == 0 or h <= MAX_HEIGHT) then
            local key = h * 1e12 + fps * 1e9 + bw
            if not best_key or key > best_key then best, best_key = uri, key end
        end
    end
    return best or fallback
end

-- Media playlist -> header tag lines + segments { lines, start, dur, uri }
local function parse_media(text, base)
    local header, segs, pending, t, dur = {}, {}, {}, 0, nil
    local cur_map, cur_key   -- EXT-X-MAP / EXT-X-KEY in effect (re-emitted per part)
    local range              -- pending EXT-X-BYTERANGE { length, offset or nil }
    local next_off = {}      -- implicit byte-range offsets, per file
    local function abs_uri_attr(line)
        return (line:gsub('URI="([^"]+)"', function(u) return 'URI="' .. resolve_url(base, u) .. '"' end))
    end
    for line in text:gmatch("[^\r\n]+") do
        if line:match("^#EXT%-X%-ENDLIST") or line:match("^#EXTM3U")
            or line:match("^#EXT%-X%-MEDIA%-SEQUENCE")
            or line:match("^#EXT%-X%-DISCONTINUITY%-SEQUENCE") then
            -- rewritten per part
        elseif line:match("^#EXT%-X%-VERSION") or line:match("^#EXT%-X%-TARGETDURATION")
            or line:match("^#EXT%-X%-PLAYLIST%-TYPE") or line:match("^#EXT%-X%-INDEPENDENT%-SEGMENTS")
            or line:match("^#EXT%-X%-ALLOW%-CACHE") then
            header[#header + 1] = line
        elseif line:match("^#EXT%-X%-BYTERANGE") then
            local len, off = line:match("^#EXT%-X%-BYTERANGE:%s*(%d+)@?(%d*)")
            range = len and { tonumber(len), tonumber(off) } or nil
        elseif line:match("^#") then
            -- per-segment tag (EXTINF, PROGRAM-DATE-TIME, DISCONTINUITY, MAP, KEY...)
            line = abs_uri_attr(line)
            if line:match("^#EXT%-X%-MAP") then cur_map = line end
            if line:match("^#EXT%-X%-KEY") then cur_key = line end
            if line:match("^#EXTINF:") then
                dur = tonumber(line:match("^#EXTINF:%s*([%d%.]+)")) or 0
            end
            pending[#pending + 1] = line
        elseif line:match("%S") and dur then
            local uri = resolve_url(base, line)
            if range then
                -- a range without @offset continues the previous range of the
                -- same file: make every offset explicit so parts stand alone
                local off = range[2] or next_off[uri] or 0
                pending[#pending + 1] = "#EXT-X-BYTERANGE:" .. range[1] .. "@" .. off
                next_off[uri] = off + range[1]
            end
            pending[#pending + 1] = uri
            segs[#segs + 1] = { lines = pending, start = t, dur = dur,
                                uri = uri, map = cur_map, key = cur_key }
            t = t + dur
            pending, dur, range = {}, nil, nil
        end
    end
    return header, segs, t
end

-- First PTS (in 90 kHz ticks) found in the first bytes of an MPEG-TS segment.
-- Pure arithmetic: Lua 5.1 (VLC 3) has no bit operators.
local function first_pts(data)
    local function band_lo(x, n) return x % (2 ^ n) end
    local function shr(x, n) return math.floor(x / (2 ^ n)) end
    local pos = data:find("\71", 1, true)
    while pos and pos + 187 <= #data do
        if data:byte(pos) ~= 71 then
            pos = data:find("\71", pos + 1, true)
        else
            local b1, b3 = data:byte(pos + 1), data:byte(pos + 3)
            local pusi = shr(b1, 6) % 2 == 1
            local afc  = shr(b3, 4) % 4
            local off  = pos + 4
            if afc == 2 or afc == 3 then off = off + 1 + data:byte(pos + 4) end
            if pusi and (afc == 1 or afc == 3) and off + 13 < pos + 188
               and data:sub(off, off + 2) == "\0\0\1" then
                local sid = data:byte(off + 3)
                local flags = data:byte(off + 7)
                if sid and sid >= 0xC0 and sid <= 0xEF and shr(flags, 7) == 1 then
                    local p0, p1, p2, p3, p4 = data:byte(off + 9, off + 13)
                    return band_lo(shr(p0, 1), 3) * 2 ^ 30 + p1 * 2 ^ 22
                         + shr(p2, 1) * 2 ^ 15 + p3 * 2 ^ 7 + shr(p4, 1)
                end
            end
            pos = pos + 188
        end
    end
    return nil
end

local function temp_dir()
    local d = os.getenv("TEMP") or os.getenv("TMP") or os.getenv("TMPDIR")
    if not d or d == "" then d = IS_WIN and "." or "/tmp" end
    return (d:gsub("[\\/]+$", ""))
end

local function file_uri(path)
    local ok, uri = pcall(function() return vlc.strings.make_uri(path) end)
    if ok and uri then return uri end
    path = path:gsub("\\", "/")
    if not path:match("^/") then path = "/" .. path end
    return "file://" .. path:gsub(" ", "%%20")
end

local function write_part(path, header, segs, first, last, target)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write("#EXTM3U\n")
    local has_type = false
    for _, h in ipairs(header) do
        if h:match("^#EXT%-X%-TARGETDURATION") then
            h = "#EXT-X-TARGETDURATION:" .. target
        end
        has_type = has_type or h:match("^#EXT%-X%-PLAYLIST%-TYPE") ~= nil
        f:write(h, "\n")
    end
    if not has_type then f:write("#EXT-X-PLAYLIST-TYPE:VOD\n") end
    f:write("#EXT-X-MEDIA-SEQUENCE:", first - 1, "\n")
    -- MAP/KEY declared earlier in the full playlist still apply to this part
    local own = table.concat(segs[first].lines, "\n")
    if segs[first].key and not own:find("#EXT-X-KEY", 1, true) then
        f:write(segs[first].key, "\n")
    end
    if segs[first].map and not own:find("#EXT-X-MAP", 1, true) then
        f:write(segs[first].map, "\n")
    end
    for i = first, last do
        for _, l in ipairs(segs[i].lines) do f:write(l, "\n") end
    end
    f:write("#EXT-X-ENDLIST\n")
    f:close()
    return true
end

-- POST /api/v1/stream/<id>/playback: the call the web player makes.
-- Works for live streams and VODs (same id space).
local function playback(video_id, page_type, slug)
    local body = json().encode({
        video_player = {
            player = {
                player_name = "web",
                player_version = "web",
                player_software = "IVS Player",
                player_software_version = "1.56.1",
            },
            mux_sdk = { sdk_available = false },
            pal_sdk = { sdk_available = false, nonce = "" },
            datazoom_sdk = { sdk_available = false },
            google_ads_sdk = { sdk_available = false },
        },
        video_session = {
            page_type = page_type,
            player_remote_played = false,
            enable_sampling = false,
            url_path = slug or "",
            autoplay_behaviour = "auto",
            play_muted = false,
            viewer_connection_type = "",
        },
        user_session = {
            session_id = uuid4(),
            player_device_id = uuid4(),
            browser_lang = "en",
            non_personalised_ads = false,
        },
    })
    local data, err = api(WEB_API .. "/v1/stream/" .. video_id .. "/playback", body)
    if data and type(data.playback_url) ~= "table" then
        err  = "no playback_url" .. (data.message and (": " .. tostring(data.message)) or "")
        data = nil
    end
    if not data then
        vlc.msg.dbg(TAG .. "playback API (" .. page_type .. "): " .. tostring(err))
    end
    return data
end

-- Shared metadata from the playback response
local function session_meta(pb, fallback_name)
    local vs = type(pb.video_session) == "table" and pb.video_session or {}
    local who   = nonempty(vs.video_series) or fallback_name
    local title = nonempty(vs.video_title)
    local game  = nonempty(vs.video_content_type)
    return {
        who      = who,
        title    = title,
        game     = game,
        status   = vs.video_stream_status,
        duration = tonumber(vs.video_duration),
    }
end

----------------------------------------------------------------------------
-- Live
----------------------------------------------------------------------------

local function parse_live(slug)
    vlc.msg.dbg(TAG .. "loading live stream for " .. slug)
    local id, title, game, err

    -- 1) current live session id (web API)
    local d
    d, err = api(WEB_API .. "/v1/channels/" .. slug .. "/livestream")
    local ls = d and type(d.data) == "table" and d.data.livestream
    if type(ls) == "table" then
        id    = nonempty(ls.id)
        title = nonempty(ls.title)
        game  = type(ls.category) == "table" and nonempty(ls.category.name) or nil
    elseif d then
        vlc.msg.dbg(TAG .. "web API says no livestream: " .. tostring(d.message))
    else
        vlc.msg.dbg(TAG .. "web livestream API: " .. tostring(err))
    end

    -- 2) legacy channel info carries the same id as livestream.vod_id
    local info
    if not id then
        info = api(SITE_API .. "/v2/channels/" .. slug .. "/info")
        local l = info and type(info.livestream) == "table" and info.livestream
        if l then
            id    = nonempty(l.vod_id)
            title = title or nonempty(l.session_title)
        elseif info and info.id then
            return fail(slug .. " is offline")
        end
    end

    local url, meta
    if id then
        local pb = playback(id, "channel", slug)
        if pb then
            url  = nonempty(pb.playback_url.live)
            meta = session_meta(pb, slug)
        end
    end

    -- 3) legacy playback URL endpoints
    if not url then
        local pu = api(SITE_API .. "/v2/channels/" .. slug .. "/playback-url")
        url = pu and find_field(pu, { "playback_url", "url", "data" }, "%.m3u8")
    end
    if not url then
        local ch = info or api(SITE_API .. "/v2/channels/" .. slug)
        if ch and ch.livestream == nil and ch.id then
            return fail(slug .. " is offline")
        end
        url = ch and find_field(ch, { "playback_url" }, "%.m3u8")
    end
    if not url then
        if not id and not d and not info then
            return fail("Kick API unreachable for " .. slug .. " (" .. tostring(err) .. ")")
        end
        return fail("no live stream URL for " .. slug .. " (offline?)")
    end

    meta = meta or { who = slug }
    title = meta.title or title
    game  = meta.game or game
    local extra = {}
    if LIVE_EDGE_DELAY_MS > 0 then
        extra[#extra + 1] = ":adaptive-livedelay=" .. LIVE_EDGE_DELAY_MS
    end
    return { {
        path        = url,
        name        = TAG .. meta.who .. (title and (" - " .. title) or ""),
        title       = title,
        artist      = meta.who,
        nowplaying  = game and (meta.who .. " playing " .. game) or title,
        genre       = game,
        description = title,
        url         = vlc.path,
        options     = item_options(extra),
    } }
end

----------------------------------------------------------------------------
-- VOD
----------------------------------------------------------------------------

local function vod_item(base, path, start, suffix)
    local item = {}
    for k, v in pairs(base) do item[k] = v end
    item.path = path
    if suffix then item.name = item.name .. suffix end
    start = start and math.floor(start)
    item.options = item_options((start and start > 0) and { ":start-time=" .. start } or nil)
    return item
end

local function load_media(url)
    local text = http_get(url)
    if not text or not text:find("#EXTM3U", 1, true) then return nil end
    local variant = url
    if text:find("#EXT-X-STREAM-INF", 1, true) then
        variant = pick_variant(text, url)
        text = variant and http_get(variant)
        if not text then return nil end
    end
    local header, segs, total = parse_media(text, variant)
    if #segs == 0 then return nil end
    return { header = header, segs = segs, total = total, variant = variant }
end

-- Resolve the VOD to playlist items: raw recording when possible, and split
-- into parts at MPEG-TS timestamp wrap points for VLC 3
local RAW_DIR = "(https?://stream%.kick%.com/[^\r\n\"]-/media/hls/)"

-- The stream.kick.com ".../media/hls/" folder of the recording behind a
-- playlist (Kick's ad-stitched manifest references its segments)
local function raw_prefix(url)
    local p = url:match("^" .. RAW_DIR)
    if p then return p end
    local text = http_get(url)
    if not text then return nil end
    p = text:match(RAW_DIR)
    if p then return p end
    local variant = text:match("#EXT%-X%-STREAM%-INF:[^\r\n]*[\r\n]+([^\r\n#][^\r\n]*)")
    if not variant then return nil end
    text = http_get(resolve_url(url, variant), 65536)   -- the first segments are enough
    return text and text:match(RAW_DIR)
end

-- Raw recording playlists, best first. The byte-range one cuts every ~10 s
-- segment (~12 MB at 1080p60) into ~2 s chunks: VLC downloads one chunk per
-- seek instead of a whole segment, so seeking and ?t= start much faster.
local RAW_PLAYLISTS = { "byte-range-multivariant.m3u8", "master.m3u8" }

local function vod_items(url, video_id, start, base, still_live)
    if VOD_PREFER_RAW and not url:find("byte%-range%-multivariant") then
        local prefix = raw_prefix(url)
        for _, name in ipairs(prefix and RAW_PLAYLISTS or {}) do
            local cand = prefix .. name
            if cand == url then break end
            local text = http_get(cand)
            if text and text:find("#EXT-X-STREAM-INF", 1, true) then
                vlc.msg.dbg(TAG .. "using the raw recording " .. cand)
                url = cand
                break
            end
        end
        if not prefix then
            vlc.msg.dbg(TAG .. "raw recording not found, using " .. url)
        end
    end
    local plain = { vod_item(base, url, start) }

    local split = SPLIT_AT_TS_WRAP
    if split == "auto" then split = vlc_major() < 4 end
    if not split or still_live then return plain end

    local m = load_media(url)
    if not m then
        vlc.msg.dbg(TAG .. "VOD playlist not readable here, handing it to VLC as is")
        return plain
    end
    for _, s in ipairs(m.segs) do
        if not s.uri:find("^https?://stream%.kick%.com/") then
            vlc.msg.dbg(TAG .. "ads in the VOD playlist, timestamp wrap not checked")
            return plain
        end
    end

    local segs  = m.segs
    local data  = http_get(segs[1].uri, 65536)
    local pts   = data and first_pts(data)
    if not pts then
        vlc.msg.dbg(TAG .. "no timestamp in the first segment, wrap not checked")
        return plain
    end
    local WRAP = 2 ^ 33 / 90000                 -- 95443.7 s
    local first_wrap = WRAP - pts / 90000      -- seconds into the VOD
    if first_wrap >= m.total then
        vlc.msg.dbg(TAG .. "no timestamp wrap in this VOD")
        return plain
    end

    -- Cut before the first segment that starts past each wrap point
    -- (the segment holding the wrap stays in the earlier part)
    local parts, cur, b = {}, { first = 1 }, first_wrap
    for i, s in ipairs(segs) do
        if s.start >= b then
            if i > cur.first then
                cur.last = i - 1
                parts[#parts + 1] = cur
                cur = { first = i }
            end
            while b <= s.start do b = b + WRAP end
        end
    end
    cur.last = #segs
    parts[#parts + 1] = cur

    local target = 1
    for _, s in ipairs(segs) do
        if s.dur > target then target = math.ceil(s.dur) end
    end

    local first_part = 1
    for j, p in ipairs(parts) do
        p.start = segs[p.first].start
        if start and start >= p.start then first_part = j end
    end

    vlc.msg.info(string.format("%sVOD crosses an MPEG-TS timestamp wrap at %s, split into %d parts",
        TAG, hms(first_wrap), #parts))

    local items, sep = {}, IS_WIN and "\\" or "/"
    for j = first_part, #parts do
        local p = parts[j]
        local path = temp_dir() .. sep .. "kick_" .. video_id .. "_part" .. j .. ".m3u8"
        if not write_part(path, m.header, segs, p.first, p.last, target) then
            vlc.msg.warn(TAG .. "can't write " .. path .. ", playing the VOD unsplit")
            return plain
        end
        local st = (j == first_part and start) and (start - p.start) or nil
        items[#items + 1] = vod_item(base, file_uri(path), st,
            string.format(" [part %d/%d, from %s]", j, #parts, hms(p.start)))
    end
    return items
end

local function parse_vod(video_id, slug)
    vlc.msg.dbg(TAG .. "loading VOD " .. video_id)

    local url, meta
    local pb = playback(video_id, "video", slug) or playback(video_id, "channel", slug)
    if pb then
        for _, k in ipairs(VOD_SOURCES) do
            url = url or nonempty(pb.playback_url[k])
        end
        meta = session_meta(pb, slug)
        if meta.status == "live" then
            vlc.msg.info(TAG .. "this VOD is still being recorded")
        end
    end

    -- Legacy endpoint (older UUIDs)
    if not url then
        local v, err = api(SITE_API .. "/v1/video/" .. video_id)
        url = v and nonempty(v.source)
        if url then
            local l  = type(v.livestream) == "table" and v.livestream or {}
            local ch = type(l.channel) == "table" and l.channel or {}
            local u  = type(ch.user) == "table" and ch.user or {}
            local cats = type(l.categories) == "table" and l.categories[1]
            meta = {
                who      = nonempty(u.username) or nonempty(ch.slug) or slug,
                title    = nonempty(l.session_title),
                game     = type(cats) == "table" and nonempty(cats.name) or nil,
                duration = tonumber(l.duration) and tonumber(l.duration) / 1000 or nil,
            }
        elseif not pb then
            return fail("VOD " .. video_id .. " not found (" .. tostring(err) .. ")")
        end
    end
    if not url then
        return fail("no playable source for VOD " .. video_id)
    end

    meta = meta or {}
    local who = meta.who or slug or "Kick"
    local base = {
        name        = TAG .. who .. " - " .. (meta.title or video_id),
        title       = meta.title,
        artist      = who,
        genre       = meta.game,
        description = meta.title,
        url         = vlc.path,
    }
    return vod_items(url, video_id, start_seconds(meta.duration), base, meta.status == "live")
end

----------------------------------------------------------------------------
-- Clips
----------------------------------------------------------------------------

local CLIP_URL_KEYS = { "playback_url", "video_url", "clip_url", "source", "url" }

local function clip_object(d)
    if type(d) ~= "table" then return nil end
    local o = d
    if type(o.data) == "table" then o = o.data end
    if type(o.clip) == "table" then o = o.clip end
    return o
end

local function parse_clip(clip_id)
    vlc.msg.dbg(TAG .. "loading clip " .. clip_id)

    local clip, url, err
    for _, endpoint in ipairs({
        WEB_API .. "/v1/clips/" .. clip_id,
        SITE_API .. "/v2/clips/" .. clip_id,
    }) do
        local d
        d, err = api(endpoint)
        local o = clip_object(d)
        if o then
            -- HLS first (VLC seeks it well), then MP4
            url = find_field(o, CLIP_URL_KEYS, "%.m3u8") or find_field(o, CLIP_URL_KEYS, "%.mp4")
            if url then
                clip = o
                break
            end
            vlc.msg.dbg(TAG .. "no clip URL from " .. endpoint)
        else
            vlc.msg.dbg(TAG .. endpoint .. ": " .. tostring(err))
        end
    end
    if not url then
        return fail("clip " .. clip_id .. " not found" .. (err and (" (" .. err .. ")") or ""))
    end

    local ch    = type(clip.channel) == "table" and clip.channel or {}
    local cat   = type(clip.category) == "table" and clip.category or {}
    local cr    = type(clip.creator) == "table" and clip.creator or {}
    local who   = nonempty(ch.username) or nonempty(ch.slug) or "Kick"
    local title = nonempty(clip.title) or clip_id

    local extra = {}
    local st = start_option(tonumber(clip.duration))
    if st then extra[#extra + 1] = st end

    -- Kick often prefixes clip titles with the channel name already
    local shown = title
    if shown:sub(1, #who + 3):lower() ~= (who .. " - "):lower() then
        shown = who .. " - " .. shown
    end

    return { {
        path        = url,
        name        = TAG .. shown,
        title       = title,
        artist      = who,
        genre       = nonempty(cat.name),
        description = nonempty(cr.username) and ("Clipped by " .. cr.username) or nil,
        arturl      = nonempty(clip.thumbnail_url),
        url         = vlc.path,
        options     = item_options(extra),
    } }
end

----------------------------------------------------------------------------

function parse()
    local path = vlc.path
    local slug = path:match("kick%.com/([%w_%-]+)")
    if slug and (slug == "video" or slug == "clips") then
        slug = nil
    end

    local clip = path:match("[?&]clip=(clip_[%w]+)") or path:match("/clips/(clip_[%w]+)")
    if clip then
        return parse_clip(clip)
    end

    local vod = path:match("/videos?/(%x+%-%x+%-%x+%-%x+%-%x+)")
    if vod then
        return parse_vod(vod, slug)
    end

    if not slug then
        return fail("failed to parse channel name from url")
    end
    return parse_live(slug:lower())
end
