// Jump relay: serves the browser viewer and brokers signaling between a Mac host and its
// viewers when they can't reach each other directly (no Tailscale, no port forwarding).
//
// The Mac connects out to /host and stays connected; viewers connect to /client. One Durable
// Object per Mac ID pipes signaling between them. Media never passes through here: after
// signaling, WebRTC connects the devices directly (STUN), and only falls back to Cloudflare
// TURN when NATs refuse. The password check (HMAC of a nonce) runs end to end between viewer
// and Mac, so this relay never learns the password.
//
// Host  -> relay: {"cid","msg"} to a viewer, {"relay":"close","cid"}, {"relay":"turn"}
// Relay -> host : {"relay":"open","cid","ip"}, {"cid","msg"} from a viewer, {"relay":"close","cid"},
//                 {"relay":"turn","iceServers"}
// "ip" is the viewer's address, so the Mac counts wrong passwords per viewer, not for everyone.
// Viewer <-> relay: the plain signaling protocol (PROTOCOL.md), untouched.

import { DurableObject } from "cloudflare:workers";

const ID_PATTERN = /^[a-z0-9]{8,32}$/;
const MAX_VIEWERS = 4;
const MAX_MESSAGE = 256 * 1024;
const STUN = { urls: "stun:stun.cloudflare.com:3478" };

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    // Tells the viewer page it was served by the relay (the Mac's own server 404s this).
    if (url.pathname === "/relay.json") return Response.json({ relay: true });
    if (url.pathname !== "/host" && url.pathname !== "/client") {
      return new Response("Not found", { status: 404 }); // the viewer itself is a static asset
    }
    const id = url.searchParams.get("id") || "";
    if (!ID_PATTERN.test(id)) return new Response("Bad Mac ID", { status: 400 });
    if (!allowedMac(env, id)) return new Response("Not a Mac of this relay", { status: 403 });
    if (request.headers.get("Upgrade") !== "websocket") return new Response("WebSocket only", { status: 426 });
    return env.ROOMS.get(env.ROOMS.idFromName(id)).fetch(request);
  },
};

/**
 * `HOST_IDS` (a secret: Mac IDs separated by commas) keeps the relay private to those Macs:
 * other copies of the app can't register here, and nobody else's traffic uses this account.
 * Unset, any Mac may claim an ID.
 */
function allowedMac(env, id) {
  const ids = (env.HOST_IDS || "").split(/[\s,]+/).filter(Boolean);
  return ids.length === 0 || ids.includes(id);
}

export class Room extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    // Keepalives are answered without waking the object.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request) {
    const url = new URL(request.url);
    const [client, server] = Object.values(new WebSocketPair());

    if (url.pathname === "/host") {
      if (!(await this.ownsRoom(url.searchParams.get("token") || "", url.searchParams.get("id") || ""))) {
        // 409, not 403: the Mac tells "registered with another token" from "not allowed here".
        return new Response("Wrong host token: run the relay setup again to reset", { status: 409 });
      }
      for (const old of this.ctx.getWebSockets("host")) old.close(4000, "Replaced by a newer host");
      this.ctx.acceptWebSocket(server, ["host"]);
      return new Response(null, { status: 101, webSocket: client });
    }

    const host = this.host();
    if (!host || this.ctx.getWebSockets("viewer").length >= MAX_VIEWERS) {
      server.accept();
      server.close(host ? 4429 : 4404, host ? "Too many viewers" : "Mac offline");
      return new Response(null, { status: 101, webSocket: client });
    }
    const cid = crypto.randomUUID().slice(0, 8);
    this.ctx.acceptWebSocket(server, ["viewer", `c:${cid}`]);
    server.serializeAttachment({ cid });
    const ip = request.headers.get("CF-Connecting-IP");
    host.send(JSON.stringify({ relay: "open", cid, ...(ip ? { ip } : {}) }));
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws, message) {
    if (typeof message !== "string" || message.length > MAX_MESSAGE) {
      ws.close(1009, "Message too large");
      return;
    }
    if (this.ctx.getTags(ws).includes("host")) {
      await this.fromHost(ws, message);
      return;
    }
    const host = this.host();
    if (!host) {
      ws.close(4404, "Mac offline");
      return;
    }
    const { cid } = ws.deserializeAttachment();
    host.send(JSON.stringify({ cid, msg: message }));
  }

  async webSocketClose(ws, code, reason) {
    this.disconnected(ws);
  }

  async webSocketError(ws) {
    this.disconnected(ws);
  }

  // MARK: helpers

  /** The connected host, ignoring one that is mid-close. */
  host() {
    return this.ctx.getWebSockets("host").find((ws) => ws.readyState === WebSocket.OPEN);
  }

  viewer(cid) {
    return this.ctx.getWebSockets(`c:${cid}`)[0];
  }

  async fromHost(ws, message) {
    let data;
    try {
      data = JSON.parse(message);
    } catch {
      return;
    }
    if (data.relay === "turn") {
      ws.send(JSON.stringify({ relay: "turn", iceServers: await this.iceServers() }));
    } else if (data.relay === "close") {
      this.viewer(data.cid)?.close(1000, data.reason || "Closed by Mac");
    } else if (data.cid && typeof data.msg === "string") {
      this.viewer(data.cid)?.send(data.msg);
    }
  }

  disconnected(ws) {
    if (this.ctx.getTags(ws).includes("host")) {
      const other = this.host();
      if (other && other !== ws) return; // a newer host already took over
      for (const viewer of this.ctx.getWebSockets("viewer")) {
        // Say it in-band too: a close frame alone can be slow to reach the viewer. "retry": the
        // Mac's link to the relay usually comes back within seconds, and a viewer whose picture
        // is still flowing (peer to peer) has no need of the relay at all.
        viewer.send(JSON.stringify({ type: "error", message: "Mac 연결이 끊어졌습니다", retry: true }));
        viewer.close(4404, "Mac went offline");
      }
      return;
    }
    const { cid } = ws.deserializeAttachment() || {};
    if (cid) this.host()?.send(JSON.stringify({ relay: "close", cid }));
  }

  /**
   * The first host to connect with a token claims this Mac ID; later ones must match it.
   * A Mac that lost its token (settings wiped, reinstalled) gets back in once the account owner
   * sets the secret HOST_RESET to "<mac id>:<anything new>" (the setup script does): the next
   * host to connect claims the ID again. Every successful host connection uses up the current
   * HOST_RESET value, so it never stays open.
   */
  async ownsRoom(token, id) {
    if (token.length < 32) return false;
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
    const hash = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
    const reset = (this.env.HOST_RESET || "").trim();
    const resetUsed = await this.ctx.storage.get("resetUsed");
    const resetOpen = reset !== "" && reset.split(":")[0] === id && reset !== resetUsed;
    const owner = await this.ctx.storage.get("tokenHash");
    if (owner && owner !== hash && !resetOpen) return false;
    await this.ctx.storage.put(reset ? { tokenHash: hash, resetUsed: reset } : { tokenHash: hash });
    return true;
  }

  /** STUN always; Cloudflare TURN too when the Worker has TURN_KEY_ID / TURN_KEY_API_TOKEN. */
  async iceServers() {
    // Tolerate what gets pasted: surrounding whitespace, a "Bearer " prefix, or a whole
    // .../turn/keys/<id>/... URL instead of the bare key ID.
    const rawId = (this.env.TURN_KEY_ID || "").trim();
    // A pasted label ("Turn Token ID ...") or URL around the ID: keep the 32-hex ID inside it.
    let keyId = (rawId.match(/\/keys\/([^/?#\s]+)/) || rawId.match(/\b[0-9a-f]{32}\b/i) || [null, rawId]).at(-1);
    let token = (this.env.TURN_KEY_API_TOKEN || "").trim().replace(/^Bearer\s+/i, "");
    // Key IDs are 32 hex chars; if the two secrets were entered the other way round, swap.
    const isKeyId = (value) => /^[0-9a-f]{32}$/i.test(value);
    if (!isKeyId(keyId) && isKeyId(token)) [keyId, token] = [token, keyId];
    if (!keyId || !token) return [STUN];
    try {
      const response = await fetch(
        `https://rtc.live.cloudflare.com/v1/turn/keys/${encodeURIComponent(keyId)}/credentials/generate-ice-servers`,
        {
          method: "POST",
          headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
          body: JSON.stringify({ ttl: 86400 }),
        },
      );
      if (!response.ok) {
        // Status and Cloudflare's error text only; never the credentials.
        // Status, Cloudflare's error text and the key ID's shape only; never the credentials.
        console.log(`TURN credentials request failed: ${response.status} ${(await response.text()).slice(0, 300)}` +
          ` (key id: ${keyId.length} chars ${isKeyId(keyId) ? "hex" : "not hex"}, raw has whitespace:` +
          ` ${/\s/.test(rawId)}, token: ${token.length} chars, token has whitespace: ${/\s/.test(token)})`);
        return [STUN];
      }
      const body = await response.json();
      const servers = (Array.isArray(body.iceServers) ? body.iceServers : [body.iceServers]).filter(Boolean);
      return servers.length ? servers : [STUN];
    } catch (error) {
      console.log(`TURN credentials request threw: ${error}`);
      return [STUN];
    }
  }
}
