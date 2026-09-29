# Jump protocol (v1)

Host = Mac (`host/`, Swift). Client = iPad / Android (`client/`, Flutter).
Transport = WebRTC. Signaling = one WebSocket per session.

## Signaling (WebSocket, JSON text frames)

Client opens `ws://<host>:47865/`. The host also serves a browser viewer at `http://<host>:47866/`.

| # | Direction | Message |
|---|-----------|---------|
| 1 | host → client | `{"type":"challenge","nonce":"<base64 32 bytes>","host":"<mac name>","version":1}` |
| 2 | client → host | `{"type":"auth","hmac":"<base64 HMAC-SHA256(key=password, msg=nonce bytes)>","device":{"name":"...","width":W,"height":H,"scale":S}}` |
| 3 | host → client | `{"type":"offer","sdp":"..."}` (or `{"type":"error","message":"..."}` then close) |
| 4 | client → host | `{"type":"answer","sdp":"..."}` |
| * | both | `{"type":"candidate","candidate":"...","sdpMid":"0","sdpMLineIndex":0}` |

The password never travels on the wire; only an HMAC of a fresh nonce does.
`device.width/height` are the client viewport in physical pixels (used to size the virtual display).
`device.codecs` lists the video codecs the client can receive (`RTCRtpReceiver.getCapabilities`
mime types). The host prefers HEVC when `video/H265` is listed, else H.264.
`device.cursor: true` means the client draws the cursor itself: the host leaves it out of the video
and streams its position and shape on the input channel instead.
One session at a time: a newly authenticated client replaces the old one.
Closing the WebSocket ends the session.

Signaling only sets a session up. Once WebRTC is connected, either side may lose the WebSocket
(a phone backgrounding the page, a mobile network, the relay) and the session goes on; it ends
when the viewer closes the input channel, WebRTC fails, or the host says `bye` (below).
`device.reconnect` (optional) is the reason an automatic reconnect is happening, for the host's log.

`{"type":"error","message":"...","retry":true}`: the session ended for a reason that a new session
fixes (a host setting changed); the client reconnects by itself. Without `retry` (wrong password,
lockout, another device took over) it stops and shows the message. A client that loses an
established session without any error (network change, host restart) also reconnects by itself,
with backoff, for about a minute.

## Media

Host sends one video track, hardware encoded: HEVC (VideoToolbox, our own encoder since the
macOS WebRTC build ships none) when the client reports it can decode it, otherwise H.264.

## Audio channel (WebRTC data channel `audio`, unordered, no retransmits, binary)

Host → client, only when "소리 전송" is on. Each message is raw PCM: 48 kHz, 2 channels,
Int16 little-endian, interleaved (~21 ms per message). Lost packets are skipped, not resent.
(libwebrtc's macOS build has no custom audio device API, so system audio can't use an audio track.)

## Input channel (WebRTC data channel `input`, ordered + reliable, JSON)

Client → host. Coordinates `x`,`y` are normalized `0..1` over the video frame.

| Message | Meaning |
|---------|---------|
| `{"t":"move","x":0.5,"y":0.5}` | move pointer (drag if a button is held) |
| `{"t":"down","b":0,"x":..,"y":..}` | button down. `b`: 0 left, 1 right, 2 middle. Optional `"c":1` forces the click count (otherwise the host counts double/triple clicks) |
| `{"t":"up","b":0,"x":..,"y":..}` | button up |
| `{"t":"scroll","dx":0,"dy":-40}` | scroll in points; positive `dy` = content moves down (reveals what is above) |
| `{"t":"key","code":458756,"down":true}` | physical key; `code` = USB HID usage (`0x0007xxxx`), i.e. Flutter `PhysicalKeyboardKey.usbHidUsage` |
| `{"t":"text","s":"안녕"}` | type committed text (soft keyboard / IME / dictation). `"paste":true` (the viewer's compose box) always pastes it, so line breaks stay line breaks instead of pressing Return |
| `{"t":"ping","ts":123}` | host answers `{"t":"pong","ts":123}` |
| `{"t":"audio","on":true}` | client is (not) playing the audio channel. While on, the host mutes the Mac's speakers; while off, the Mac plays its own sound |
| `{"t":"clip","text":"…"}` | text copied on the client (at most 60 000 bytes of UTF-8); the host puts it on the Mac pasteboard before handling the next message, so a following Cmd+V pastes it |
| `{"t":"selectDisplay","id":2}` | show another monitor (an `id` from `displays`); the host remembers it for the next session |
| `{"t":"password","current":"…","new":"…"}` | change the host password (8–128 characters, no leading/trailing spaces). The current one is still required; wrong guesses count toward the login lockout. Sent only on this channel, which is end-to-end encrypted, never through signaling or the relay |

Host → client on the same channel:

| Message | Meaning |
|---------|---------|
| `{"t":"display","id":1,"w":1470,"h":956}` | captured display and its size in points; sent again after a monitor switch |
| `{"t":"displays","current":1,"list":[{"id":1,"name":"…","w":1470,"h":956,"main":true}]}` | the Mac's monitors (mirrors left out); sent when the channel opens and after a switch |
| `{"t":"clip","text":"…"}` | text copied on the Mac during the session (earlier clipboard contents are never sent) |
| `{"t":"pong","ts":123}` | ping echo, for round-trip latency |
| `{"t":"cursor","x":0.5,"y":0.5}` | cursor position (normalized), up to 60 Hz, only if the client sent `"cursor":true` in `auth.device` |
| `{"t":"cursorImage","png":"<base64, 2x>","w":..,"h":..,"hx":..,"hy":..}` | cursor shape in points with its hot spot; sent on change and whenever the channel opens |
| `{"t":"bye","message":"…","retry":false}` | the host ended the session (another device took over, a setting changed, …): same meaning as the signaling `error`, sent here too because signaling may be gone |
| `{"t":"password","ok":true}` / `{"t":"password","ok":false,"error":"…"}` | result of a password change; the new password applies from the next login and the current session stays |
