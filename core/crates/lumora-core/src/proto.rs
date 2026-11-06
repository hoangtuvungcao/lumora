//! Application protocol carried inside QUIC (already TLS 1.3 end-to-end).
//!
//! Streams: the first byte of every stream selects its kind.
//!   0x01 control (bi, long-lived, length-prefixed MessagePack `PeerMsg`)
//!   0x02 file    (uni, header + raw bytes)
//!   0x03 media   (uni, one stream per video frame → stale frames are cancelled, no HOL)
//! QUIC datagrams carry latency-critical small packets (audio, mouse/keyboard).

use crate::identity::PeerId;
use crate::net::ConnInfo;
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// Protocol history (peers announce theirs in `Hello`; the newest one seen is remembered):
/// * 2: checklists, reminders, silent messages, wake-on-LAN messages.
/// * 3: multi-device — `PeerMsg::Ext` (map-encoded bodies, see [`ext`]), device lists,
///   device signatures (DevSig) inside the existing `sig` fields, `STREAM_SYNC`, and
///   remote-control authentication v2.
///
/// New message kinds are only sent to peers known to speak the version that introduced
/// them (older peers get a plain-text fallback or nothing), because older decoders reject
/// them. Never add a field to an existing (array-encoded) wire struct: add an `Ext` kind.
pub const PROTO_VERSION: u32 = 3;
/// First protocol version that understands the v2 additions above.
pub const PROTO_V2: u32 = 2;
/// First protocol version that understands `PeerMsg::Ext`, DevSig and `STREAM_SYNC`.
pub const PROTO_V3: u32 = 3;
pub const MAX_CONTROL_FRAME: usize = 4 * 1024 * 1024;

pub const STREAM_CONTROL: u8 = 1;
pub const STREAM_FILE: u8 = 2;
pub const STREAM_MEDIA: u8 = 3;
pub const STREAM_RELAY: u8 = 4;
/// (uni, v3) multi-device bootstrap/history: length-prefixed `to_vec_named(SyncBatch)` frames.
/// Older peers ignore unknown stream kinds.
pub const STREAM_SYNC: u8 = 5;

/// Signaling envelope body (sealed with `crypto::seal_to`).
#[derive(Serialize, Deserialize, Debug, Clone)]
pub enum Signal {
    Offer { sid: u64, info: ConnInfo, name: String },
    Answer { sid: u64, info: ConnInfo },
    /// Offline delivery through a relay mailbox: an opaque sealed PeerMsg.
    Mail { payload: Vec<u8> },
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub enum Body {
    Text { text: String },
    File {
        file_id: [u8; 16],
        name: String,
        size: u64,
        mime: String,
        hash: [u8; 32],
        /// Small JPEG preview (images) so the chat shows the picture instantly.
        #[serde(default, with = "serde_bytes")]
        thumb: Vec<u8>,
        #[serde(default)]
        width: u32,
        #[serde(default)]
        height: u32,
    },
    /// Built-in sticker (`data` empty) or a user-made sticker carried inline (PNG/WebP/GIF ≤ 512 KB).
    /// Receivers cache it by `hash`, so a sticker used 1000× is stored once.
    Sticker {
        pack: String,
        id: String,
        #[serde(default)]
        hash: [u8; 32],
        #[serde(default)]
        mime: String,
        #[serde(default, with = "serde_bytes")]
        data: Vec<u8>,
        #[serde(default)]
        emoji: String,
        #[serde(default)]
        animated: bool,
    },
    Voice {
        file_id: [u8; 16],
        duration_ms: u32,
        #[serde(default)]
        size: u64,
        #[serde(default)]
        hash: [u8; 32],
        /// 32 amplitude samples (0–255) for the waveform.
        #[serde(default, with = "serde_bytes")]
        wave: Vec<u8>,
    },
    Location { lat: f64, lon: f64, accuracy_m: f32, label: String, live_until: u64 },
    Contact { peer: PeerId, name: String },
    Call { video: bool, duration_s: u32, missed: bool },
    System { text: String },
    Poll { question: String, options: Vec<String> },
    /// Shared to-do list: anyone in the chat can tick items, the sender can add more.
    Checklist { title: String, items: Vec<CheckItem> },
    /// "Nhắc hẹn": every device holding it raises `reminder_due` at `at_ms`.
    Reminder { title: String, at_ms: u64, #[serde(default)] note: String },
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct CheckItem {
    pub id: u32,
    pub text: String,
}

impl Body {
    pub fn kind(&self) -> &'static str {
        match self {
            Body::Text { .. } => "text",
            Body::File { .. } => "file",
            Body::Sticker { .. } => "sticker",
            Body::Voice { .. } => "voice",
            Body::Location { .. } => "location",
            Body::Contact { .. } => "contact",
            Body::Call { .. } => "call",
            Body::System { .. } => "system",
            Body::Poll { .. } => "poll",
            Body::Checklist { .. } => "checklist",
            Body::Reminder { .. } => "reminder",
        }
    }
    /// One-line preview for the chat list. Machine tokens the app translates and draws with
    /// its own icons (keep them stable): "🖼️ Photo", "🎬 Video", "🎤 Voice message",
    /// "📍 Live location", "📍 Location", "📞 Call", "📹 Call", "📞 Missed call",
    /// "📹 Missed call" and "<emoji> Sticker". Everything else is plain localized text.
    pub fn preview(&self) -> String {
        match self {
            Body::Text { text } => text.clone(),
            Body::File { name, mime, .. } if mime.starts_with("image/") => {
                let _ = name;
                "🖼️ Photo".into()
            }
            Body::File { mime, .. } if mime.starts_with("video/") => "🎬 Video".into(),
            Body::File { name, .. } => crate::i18n::trf("pv.file", &[("name", name)]),
            Body::Sticker { emoji, .. } => if emoji.is_empty() { "🙂 Sticker".into() } else { format!("{emoji} Sticker") },
            Body::Voice { .. } => "🎤 Voice message".into(),
            Body::Location { live_until, .. } => if *live_until > 0 { "📍 Live location".into() } else { "📍 Location".into() },
            Body::Contact { name, .. } => crate::i18n::trf("pv.contact", &[("name", name)]),
            Body::Call { video, missed, .. } => {
                format!("{} {}", if *video { "📹" } else { "📞" }, if *missed { "Missed call" } else { "Call" })
            }
            Body::System { text } => text.clone(),
            Body::Poll { question, .. } => crate::i18n::trf("pv.poll", &[("question", question)]),
            Body::Checklist { title, .. } => crate::i18n::trf("pv.checklist", &[("title", title)]),
            Body::Reminder { title, .. } => crate::i18n::trf("pv.reminder", &[("title", title)]),
        }
    }
    pub fn to_json(&self) -> serde_json::Value {
        match self {
            Body::File { file_id, name, size, mime, hash, thumb, width, height } => {
                // `thumb` is a picture or a preview container (see file_preview.rs), validated here
                let (thumb, preview) = crate::file_preview::split_thumb(thumb);
                let mut v = serde_json::json!({
                    "file_id": hex::encode(file_id), "name": name, "size": size, "mime": mime, "hash": hex::encode(hash),
                    "thumb": if thumb.is_empty() { serde_json::Value::Null } else { serde_json::Value::String(data_encoding::BASE64.encode(&thumb)) },
                    "width": width, "height": height,
                });
                if let Some(p) = preview {
                    v["preview"] = p.to_json();
                }
                v
            }
            Body::Voice { file_id, duration_ms, size, wave, .. } => serde_json::json!({
                "file_id": hex::encode(file_id), "duration_ms": duration_ms, "size": size, "wave": wave,
            }),
            Body::Location { lat, lon, accuracy_m, label, live_until } => serde_json::json!({
                "lat": lat, "lon": lon, "accuracy_m": accuracy_m, "label": label, "live_until": live_until,
            }),
            Body::Contact { peer, name } => serde_json::json!({"peer": peer.to_base32(), "short_id": peer.short_id_fmt(), "name": name}),
            // the image itself lives in the sticker cache (fetch with `sticker_get {hash}`)
            Body::Sticker { pack, id, hash, mime, emoji, animated, data } => serde_json::json!({
                "pack": pack, "id": id, "hash": if data.is_empty() && *hash == [0u8; 32] { String::new() } else { hex::encode(hash) },
                "mime": mime, "emoji": emoji, "animated": animated,
            }),
            other => serde_json::to_value(other)
                .ok()
                .and_then(|v| v.as_object().and_then(|o| o.values().next().cloned()))
                .unwrap_or(serde_json::Value::Null),
        }
    }
}

/// A chat message signed by its author (so it can be relayed/gossiped safely).
#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct ChatMsg {
    pub id: [u8; 16],
    pub author: PeerId,
    pub hlc: u64,
    pub body: Body,
    pub reply_to: Option<[u8; 16]>,
    pub ttl_ms: Option<u64>,
    #[serde(default)]
    pub meta: MsgMeta,
    #[serde(with = "serde_bytes")]
    pub sig: Vec<u8>,
}

impl ChatMsg {
    pub fn signing_bytes(&self, conv_scope: &[u8]) -> Vec<u8> {
        let mut v = b"lumora-chat-v1".to_vec();
        v.extend_from_slice(conv_scope);
        v.extend_from_slice(&self.id);
        v.extend_from_slice(&self.author.0);
        v.extend_from_slice(&self.hlc.to_le_bytes());
        v.extend(rmp_serde::to_vec(&self.body).unwrap_or_default());
        if let Some(r) = self.reply_to {
            v.extend_from_slice(&r);
        }
        v.extend_from_slice(&self.ttl_ms.unwrap_or(0).to_le_bytes());
        v.extend(rmp_serde::to_vec(&self.meta).unwrap_or_default());
        v
    }
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub enum MsgAction {
    Edit { target: [u8; 16], text: String },
    Delete { target: [u8; 16] },
    React { target: [u8; 16], emoji: String, on: bool },
    Pin { target: [u8; 16], on: bool },
    /// Live-location update for a Location message (author only).
    LiveLocation { target: [u8; 16], lat: f64, lon: f64, accuracy_m: f32, stop: bool },
    Vote { target: [u8; 16], option: u32 },
    /// Wipe the conversation history (≤ upto_hlc). 1-1: either side; groups: owner/admin.
    ClearHistory { upto_hlc: u64, delete_chat: bool },
    /// Groups, admins: delete every message of one member.
    PurgeAuthor { author: PeerId },
    /// A user pressed an inline button on `target` (sent to the message author).
    Callback { target: [u8; 16], data: String },
    /// Tick / untick one checklist item (anyone in the chat). `at` (ms) orders concurrent
    /// toggles: the newest wins on every device.
    ChecklistToggle { target: [u8; 16], item: u32, done: bool, at: u64 },
    /// Add items to a checklist (its sender only).
    ChecklistAdd { target: [u8; 16], items: Vec<CheckItem> },
    /// Cancel a reminder (its sender only).
    ReminderCancel { target: [u8; 16] },
    /// "Đã xem": the actor has seen the reminder.
    ReminderSeen { target: [u8; 16] },
}

/// Extra, optional message metadata (signed together with the message).
#[derive(Serialize, Deserialize, Debug, Clone, Default)]
pub struct MsgMeta {
    #[serde(default)]
    pub mentions: Vec<PeerId>,
    #[serde(default)]
    pub forwarded_from: Option<String>,
    #[serde(default)]
    pub mention_all: bool,
    /// Inline keyboard (bots): rows of buttons; pressing one sends a Callback to the author.
    #[serde(default)]
    pub buttons: Vec<Vec<Button>>,
    /// "Gửi không âm báo": receivers show the message without a sound or notification.
    /// Skipped when false so messages stay byte-identical for older peers (MessagePack
    /// structs are positional: this must remain the LAST field).
    #[serde(default, skip_serializing_if = "is_false")]
    pub silent: bool,
}

fn is_false(b: &bool) -> bool {
    !*b
}

#[derive(Serialize, Deserialize, Debug, Clone, Default, PartialEq)]
pub struct BotInfo {
    /// (command without "/", description) — shown in private chats
    pub commands: Vec<(String, String)>,
    /// commands shown in groups/communities (empty → same as `commands`)
    #[serde(default)]
    pub group_commands: Vec<(String, String)>,
    #[serde(default)]
    pub about: String,
    /// BotFather ownership proof: {owner, username, created, sig}
    #[serde(default)]
    pub owner: Option<serde_json::Value>,
}

#[derive(Serialize, Deserialize, Debug, Clone, Default, PartialEq)]
pub struct Button {
    pub text: String,
    /// Opaque callback data (≤ 64 bytes) delivered back to the message author.
    #[serde(default)]
    pub data: String,
    /// Optional link opened by the client instead of a callback.
    #[serde(default)]
    pub url: String,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub enum PeerMsg {
    Hello { version: u32, name: String, app: String, os: String },
    /// Double Ratchet: ask a friend for a signed one-time key / the answer.
    OlmKeysRequest,
    OlmKeys { curve: [u8; 32], otk: [u8; 32], #[serde(with = "serde_bytes")] sig: Vec<u8> },
    /// A direct-chat message (Chat / Action) encrypted with the ratchet.
    Olm { msg_type: u8, #[serde(with = "serde_bytes")] ciphertext: Vec<u8>, curve: [u8; 32], #[serde(with = "serde_bytes")] curve_sig: Vec<u8> },
    /// Reliable delivery wrapper: the receiver processes `inner` then replies `Ack { ids: [id] }`,
    /// which removes the item from the sender's outbox (keeps storage bounded).
    Wrapped { id: [u8; 16], inner: Box<PeerMsg> },
    Ping { t: u64 },
    Pong { t: u64 },

    // ---- friends ----
    FriendRequest { name: String, note: String },
    FriendAccept { name: String },
    FriendRemove,
    Profile { name: String },
    ProfileV2 {
        name: String,
        bio: String,
        status: String,
        #[serde(default)]
        bot: Option<BotInfo>,
        #[serde(default)]
        username: String,
        #[serde(with = "serde_bytes")]
        avatar: Vec<u8>,
        #[serde(default, with = "serde_bytes")]
        cover: Vec<u8>,
    },
    /// Join a PUBLIC group (no invite needed); sent to one of its admins.
    JoinPublic { gid: [u8; 16] },
    /// Ask an inviter to add us to a group using a signed invite link.
    JoinRequest { gid: [u8; 16], expires: u64, #[serde(with = "serde_bytes")] sig: Vec<u8> },

    // ---- direct chat ----
    Chat(ChatMsg),
    Action { id: [u8; 16], author: PeerId, hlc: u64, action: MsgAction, #[serde(with = "serde_bytes")] sig: Vec<u8> },
    Ack { ids: Vec<[u8; 16]> },
    Read { upto_hlc: u64 },
    Typing { conv: String, on: bool },

    // ---- groups ----
    /// Encrypted+signed group envelope (see group.rs). Gossiped between members.
    Group { gid: [u8; 16], #[serde(with = "serde_bytes")] env: Vec<u8> },
    /// Anti-entropy: "for each author, I have everything up to hlc".
    GroupSync { gid: [u8; 16], heads: Vec<(PeerId, u64)> },
    /// Group state snapshot + current key, sealed to the recipient.
    GroupWelcome { #[serde(with = "serde_bytes")] sealed: Vec<u8> },
    GroupKey { #[serde(with = "serde_bytes")] sealed: Vec<u8> },
    GroupTyping { gid: [u8; 16], on: bool },
    /// A group message addressed to a privacy-mode bot (command / mention / reply), sent
    /// directly to the bot by its author. The bot can't read the rest of the group.
    BotGroupMsg { gid: [u8; 16], channel: String, msg: Box<ChatMsg> },
    /// A privacy-mode bot posting into a group (it has no group key): delivered to each member.
    BotGroupPost { gid: [u8; 16], channel: String, msg: Box<ChatMsg> },
    /// "Seen by": I have read `conv` (a group conversation) up to `upto_hlc`.
    GroupRead { gid: [u8; 16], conv: String, upto_hlc: u64 },

    // ---- store & forward (friend keeps sealed mail for an offline peer) ----
    StoreFor { to: PeerId, id: [u8; 16], #[serde(with = "serde_bytes")] sealed: Vec<u8> },
    Mail { #[serde(with = "serde_bytes")] sealed: Vec<u8> },

    // ---- files ----
    FileOffer { file_id: [u8; 16], name: String, size: u64, hash: [u8; 32], conv: String },
    FileRequest { file_id: [u8; 16], offset: u64 },
    FileCancel { file_id: [u8; 16] },
    FileDone { file_id: [u8; 16], ok: bool },

    // ---- calls ----
    CallInvite { call_id: [u8; 16], video: bool, group: Option<[u8; 16]> },
    CallAnswer { call_id: [u8; 16], accept: bool },
    CallEnd { call_id: [u8; 16] },
    CallState { call_id: [u8; 16], mic: bool, cam: bool, screen: bool },
    KeyframeRequest { stream: u32 },
    Bitrate { stream: u32, kbps: u32 },

    // ---- remote desktop ----
    RemoteRequest { session: [u8; 16], proof: Option<[u8; 32]>, view_only: bool, #[serde(default)] ask: bool },
    RemoteChallenge { session: [u8; 16], nonce: [u8; 16] },
    RemoteAuth { session: [u8; 16], proof: [u8; 32] },
    RemoteAccept { session: [u8; 16], width: u32, height: u32, displays: Vec<(u32, u32, String)>, control: bool },
    RemoteDeny { session: [u8; 16], reason: String },
    RemoteEnd { session: [u8; 16] },
    RemoteSelectDisplay { session: [u8; 16], index: u32 },
    /// Power actions on the controlled machine: "lock" | "restart" | "logout". Requires an
    /// accepted session with control; "restart" additionally needs the host's opt-in setting.
    RemoteAction { session: [u8; 16], action: String },
    /// Reliable input (keys, buttons, text) — must never be dropped, unlike pointer moves.
    RemoteInput { session: [u8; 16], #[serde(with = "serde_bytes")] ev: Vec<u8> },
    Clipboard { text: String },

    // ---- peer relay ----
    Peers { peers: Vec<PeerId> },
    /// "I have an open/easy NAT and can relay for you (encrypted, rate-limited)."
    RelayOffer { kbps: u32 },

    // ---- stories (24 h, friends only) ----
    Story { id: [u8; 16], author: PeerId, created: u64, text: String, #[serde(with = "serde_bytes")] image: Vec<u8>, bg: String, #[serde(with = "serde_bytes")] sig: Vec<u8> },
    StorySeen { id: [u8; 16] },

    // ---- wake-on-LAN ----
    /// Host → accepted viewer: hardware addresses of this computer's active network cards,
    /// so the viewer can wake it later ("Đánh thức máy").
    RemoteHostInfo { session: [u8; 16], macs: Vec<[u8; 6]> },
    /// Friend → friend: "please send a wake-up packet on your network" (rate limited).
    WakeRequest { macs: Vec<[u8; 6]> },

    // ---- iPhone push wake-ups (node/push.rs) ----
    /// The sender's push registration (`lumora_push::PushReg`, map-encoded so it can grow).
    /// Only sent to peers whose `Hello.app` contains `+push1`.
    PushReg { #[serde(with = "serde_bytes")] blob: Vec<u8> },

    // ---- protocol v3 ----
    /// Extension message: `body` is `rmp_serde::to_vec_named` of the struct for `kind`
    /// (see [`ext`]), so it can grow without breaking anyone; unknown kinds are ignored.
    /// Only ever sent to peers that announced version ≥ [`PROTO_V3`] (or appear in a
    /// device list, which implies it) — older decoders would skip the whole frame.
    /// Keep this the LAST variant.
    Ext { kind: u16, #[serde(with = "serde_bytes")] body: Vec<u8> },
}

/// `PeerMsg::Ext` kinds. Bodies are map-encoded (`to_vec_named`): new fields are optional
/// (`#[serde(default)]`) and unknown fields are ignored by every version.
pub mod ext {
    pub const DEVICE_SYNC: u16 = 0x01;
    pub const DEVICE_LIST: u16 = 0x02;
    pub const DEVICE_LIST_REQUEST: u16 = 0x03;
    /// A linked device asks the main device to sign it out (own devices only).
    pub const DEVICE_REVOKE_REQUEST: u16 = 0x04;
    /// A linked device gives the main device its acceptance signature (it agrees to be a
    /// device of this account) for the device list: `{proof}`. Own devices only.
    pub const DEVICE_ACCEPT: u16 = 0x05;
    pub const LINK_HELLO: u16 = 0x10;
    pub const LINK_PAKE: u16 = 0x11;
    pub const LINK_CONFIRM: u16 = 0x12;
    pub const LINK_INFO: u16 = 0x13;
    pub const LINK_ACCEPT: u16 = 0x14;
    pub const LINK_REJECT: u16 = 0x15;
    /// Link pre-authentication over sealed signaling mail (before any dial / address):
    /// `{stage, msg}` — QR proof or SPAKE2 + key confirmation (node/link.rs).
    pub const LINK_PRE: u16 = 0x16;
    /// Own devices only.
    pub const SELF_SYNC: u16 = 0x20;
    pub const HISTORY_REQUEST: u16 = 0x21;
    pub const HISTORY_STATUS: u16 = 0x22;
    pub const GROUP_REKEY_REQUEST: u16 = 0x30;
    /// A group member at an epoch it has no key for asks members for it:
    /// `{gid, epoch}` → answered with ordinary sealed `GroupKey` messages.
    pub const GROUP_KEY_REQUEST: u16 = 0x31;
    /// Legacy bridge (Phase 9): to the own primary only.
    pub const PROXY: u16 = 0x40;
    pub const REMOTE_CHALLENGE_V2: u16 = 0x50;
    pub const REMOTE_AUTH_V2: u16 = 0x51;
    /// IP privacy: remote-control pre-authentication over sealed signaling mail (no
    /// connection, no addresses) before a host reveals where it can be reached.
    /// Viewer → host: `{session, view_only, ts, cert}`.
    pub const REMOTE_PRE_REQ: u16 = 0x52;
    /// Host → viewer: `{session, nonce, kdf}` (same shape as `REMOTE_CHALLENGE_V2`).
    pub const REMOTE_PRE_CHALLENGE: u16 = 0x53;
    /// Viewer → host: `{session, proof, sig}` (same shape as `REMOTE_AUTH_V2`).
    pub const REMOTE_PRE_AUTH: u16 = 0x54;
    /// Host → viewer: `{session, ok, reason}`; `ok` = the viewer may now connect.
    pub const REMOTE_PRE_RESULT: u16 = 0x55;
    /// Own devices only: an incoming call was answered / declined on another of my devices.
    pub const CALL_ELSEWHERE: u16 = 0x60;
    /// Friends and own devices: the key of the sender's friends-only DHT address record.
    pub const DHT_KEY: u16 = 0x78;
    /// "I switched to this connection because the one it replaces looked dead": the other
    /// side, which may have kept the old one, switches too (both use the same connection).
    pub const PATH_CHOSEN: u16 = 0x79;
    /// Video codec capabilities (`lumora_media::Caps`: enc/dec/hw_enc/hw_dec format
    /// lists), sent right before a call invite/answer and a remote-control request.
    /// A device that never sent one is an older build: H.264 only.
    pub const VIDEO_CAPS: u16 = 0x70;
}

/// Build an `Ext` message (body map-encoded so it stays forward compatible).
pub fn ext<T: Serialize>(kind: u16, body: &T) -> PeerMsg {
    PeerMsg::Ext { kind, body: rmp_serde::to_vec_named(body).unwrap_or_default() }
}

/// Decode an `Ext` body (map- or array-encoded).
pub fn ext_body<T: serde::de::DeserializeOwned>(body: &[u8]) -> anyhow::Result<T> {
    Ok(from_slice_capped(body)?)
}

/// One `STREAM_SYNC` frame (map-encoded). Each item is decoded on its own so a newer
/// sender's unknown item kinds are skipped instead of failing the batch.
#[derive(Serialize, Deserialize, Debug, Clone, Default)]
pub struct SyncBatch {
    #[serde(default)]
    pub items: Vec<serde_bytes::ByteBuf>,
    /// Opaque resume position after this batch.
    #[serde(default, with = "serde_bytes")]
    pub cursor: Vec<u8>,
    #[serde(default)]
    pub done: bool,
    /// 1 = account state (bootstrap), 2 = message history.
    #[serde(default)]
    pub phase: u8,
    #[serde(default)]
    pub convs_done: u32,
    #[serde(default)]
    pub convs_total: u32,
}

pub const MAX_SYNC_FRAME: usize = 1024 * 1024;

pub async fn write_sync_frame<W: AsyncWriteExt + Unpin>(w: &mut W, b: &SyncBatch) -> anyhow::Result<()> {
    let v = rmp_serde::to_vec_named(b)?;
    anyhow::ensure!(v.len() <= MAX_SYNC_FRAME, "sync frame too large");
    w.write_all(&(v.len() as u32).to_be_bytes()).await?;
    w.write_all(&v).await?;
    Ok(())
}

/// `Ok(None)` at a clean end of stream.
pub async fn read_sync_frame<R: AsyncReadExt + Unpin>(r: &mut R) -> anyhow::Result<Option<SyncBatch>> {
    let mut len = [0u8; 4];
    match r.read_exact(&mut len).await {
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e.into()),
    }
    let n = u32::from_be_bytes(len) as usize;
    anyhow::ensure!(n <= MAX_SYNC_FRAME, "sync frame too large");
    let mut b = vec![0u8; n];
    r.read_exact(&mut b).await?;
    Ok(Some(rmp_serde::from_slice(&b)?))
}

pub async fn write_frame<W: AsyncWriteExt + Unpin>(w: &mut W, msg: &PeerMsg) -> anyhow::Result<()> {
    let b = rmp_serde::to_vec(msg)?;
    anyhow::ensure!(b.len() <= MAX_CONTROL_FRAME, "frame too large");
    let mut buf = Vec::with_capacity(4 + b.len());
    buf.extend_from_slice(&(b.len() as u32).to_be_bytes());
    buf.extend_from_slice(&b);
    w.write_all(&buf).await?;
    Ok(())
}

/// Nesting cap for MessagePack received from peers. serde recursion is otherwise bounded only
/// by rmp's default (1024), and a tiny hostile frame — ~1000 nested `Wrapped`, or nested arrays
/// in a remote-input event — overflows a 2 MB worker stack, which aborts the whole process
/// (found by fuzzing, core/fuzz). Legitimate messages nest < 16 levels.
pub const MAX_DECODE_DEPTH: usize = 64;

/// `rmp_serde::from_slice` with [`MAX_DECODE_DEPTH`]: use it for everything a peer sends.
pub fn from_slice_capped<'a, T: Deserialize<'a>>(b: &'a [u8]) -> Result<T, rmp_serde::decode::Error> {
    let mut de = rmp_serde::Deserializer::from_read_ref(b);
    de.set_max_depth(MAX_DECODE_DEPTH);
    T::deserialize(&mut de)
}

/// Decode a received `PeerMsg` (depth-capped, see [`MAX_DECODE_DEPTH`]).
pub fn decode_peer_msg(b: &[u8]) -> Result<PeerMsg, rmp_serde::decode::Error> {
    from_slice_capped(b)
}

/// Like [`read_frame`] but a frame that doesn't decode (e.g. a message kind added by a newer
/// version) yields `Ok(None)` instead of an error, so the stream keeps going.
pub async fn read_frame_lenient<R: AsyncReadExt + Unpin>(r: &mut R) -> anyhow::Result<Option<PeerMsg>> {
    let mut len = [0u8; 4];
    r.read_exact(&mut len).await?;
    let n = u32::from_be_bytes(len) as usize;
    anyhow::ensure!(n <= MAX_CONTROL_FRAME, "frame too large");
    let mut b = vec![0u8; n];
    r.read_exact(&mut b).await?;
    Ok(decode_peer_msg(&b).ok())
}

pub async fn read_frame<R: AsyncReadExt + Unpin>(r: &mut R) -> anyhow::Result<PeerMsg> {
    let mut len = [0u8; 4];
    r.read_exact(&mut len).await?;
    let n = u32::from_be_bytes(len) as usize;
    anyhow::ensure!(n <= MAX_CONTROL_FRAME, "frame too large");
    let mut b = vec![0u8; n];
    r.read_exact(&mut b).await?;
    Ok(decode_peer_msg(&b)?)
}

/// Datagram tags (first byte).
pub mod dgram {
    pub const AUDIO: u8 = 1;
    pub const INPUT: u8 = 2;
    pub const PING: u8 = 3;
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn frame_roundtrip() {
        let (mut a, mut b) = tokio::io::duplex(1 << 16);
        let m = PeerMsg::Typing { conv: "x".into(), on: true };
        write_frame(&mut a, &m).await.unwrap();
        match read_frame(&mut b).await.unwrap() {
            PeerMsg::Typing { conv, on } => {
                assert_eq!(conv, "x");
                assert!(on)
            }
            _ => panic!(),
        }
    }
    /// MsgMeta as it was before `silent` existed (positional MessagePack layout).
    #[derive(Serialize, Deserialize, Default)]
    struct OldMeta {
        mentions: Vec<PeerId>,
        forwarded_from: Option<String>,
        mention_all: bool,
        buttons: Vec<Vec<Button>>,
    }

    #[test]
    fn meta_silent_is_wire_compatible() {
        // not silent → byte-identical to the old layout (signatures stay valid for old peers)
        let new = rmp_serde::to_vec(&MsgMeta::default()).unwrap();
        assert_eq!(new, rmp_serde::to_vec(&OldMeta::default()).unwrap());
        // old bytes decode with silent = false
        let m: MsgMeta = rmp_serde::from_slice(&rmp_serde::to_vec(&OldMeta { mention_all: true, ..Default::default() }).unwrap()).unwrap();
        assert!(m.mention_all && !m.silent);
        // silent round-trips
        let m: MsgMeta = rmp_serde::from_slice(&rmp_serde::to_vec(&MsgMeta { silent: true, ..Default::default() }).unwrap()).unwrap();
        assert!(m.silent);
    }

    #[test]
    fn new_bodies_roundtrip_and_json() {
        let b = Body::Checklist { title: "Đi chợ".into(), items: vec![CheckItem { id: 1, text: "Rau".into() }] };
        let back: Body = rmp_serde::from_slice(&rmp_serde::to_vec(&b).unwrap()).unwrap();
        assert_eq!(back.kind(), "checklist");
        assert_eq!(b.to_json()["items"][0]["text"], "Rau");
        let r = Body::Reminder { title: "Họp".into(), at_ms: 5, note: String::new() };
        assert_eq!(r.to_json()["at_ms"], 5);
        assert!(r.preview().contains("Họp"));
    }

    #[tokio::test]
    async fn lenient_reader_skips_unknown_frames() {
        let (mut a, mut b) = tokio::io::duplex(1 << 16);
        // a frame no PeerMsg variant matches, then a valid one
        let junk = rmp_serde::to_vec(&serde_json::json!({"FutureKind": [1, 2]})).unwrap();
        a.write_all(&(junk.len() as u32).to_be_bytes()).await.unwrap();
        a.write_all(&junk).await.unwrap();
        write_frame(&mut a, &PeerMsg::Ping { t: 7 }).await.unwrap();
        assert!(read_frame_lenient(&mut b).await.unwrap().is_none());
        assert!(matches!(read_frame_lenient(&mut b).await.unwrap(), Some(PeerMsg::Ping { t: 7 })));
    }

    /// Frozen wire fixtures: the exact bytes protocol v1/v2 peers produce and expect. If one
    /// of these fails, an existing wire struct changed shape — old peers would reject it.
    fn fixtures() -> Vec<(&'static str, PeerMsg)> {
        let p = PeerId([7; 32]);
        vec![
            ("hello", PeerMsg::Hello { version: 1, name: "An".into(), app: "lumora/0.1.0".into(), os: "linux".into() }),
            (
                "chat",
                PeerMsg::Chat(ChatMsg {
                    id: [1; 16],
                    author: p,
                    hlc: 42,
                    body: Body::Text { text: "chào".into() },
                    reply_to: None,
                    ttl_ms: None,
                    meta: MsgMeta::default(),
                    sig: vec![9; 64],
                }),
            ),
            ("wrapped_ack", PeerMsg::Wrapped { id: [2; 16], inner: Box::new(PeerMsg::Ack { ids: vec![[3; 16]] }) }),
            ("group_sync", PeerMsg::GroupSync { gid: [4; 16], heads: vec![(p, 5)] }),
            ("action", PeerMsg::Action { id: [5; 16], author: p, hlc: 6, action: MsgAction::React { target: [6; 16], emoji: "👍".into(), on: true }, sig: vec![1; 64] }),
        ]
    }

    const FROZEN: &[(&str, &str)] = &[
        ("hello", "81a548656c6c6f9401a2416eac6c756d6f72612f302e312e30a56c696e7578"),
        ("chat", "81a44368617498dc001001010101010101010101010101010101dc002007070707070707070707070707070707070707070707070707070707070707072a81a45465787491a56368c3a06fc0c09490c0c290c44009090909090909090909090909090909090909090909090909090909090909090909090909090909090909090909090909090909090909090909090909090909"),
        ("wrapped_ack", "81a75772617070656492dc00100202020202020202020202020202020281a341636b9191dc001003030303030303030303030303030303"),
        ("group_sync", "81a947726f757053796e6392dc0010040404040404040404040404040404049192dc0020070707070707070707070707070707070707070707070707070707070707070705"),
        ("action", "81a6416374696f6e95dc001005050505050505050505050505050505dc002007070707070707070707070707070707070707070707070707070707070707070681a5526561637493dc001006060606060606060606060606060606a4f09f918dc3c44001010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101"),
    ];

    #[test]
    fn frozen_v1_fixtures_still_encode_and_decode() {
        for (name, m) in fixtures() {
            let got = hex::encode(rmp_serde::to_vec(&m).unwrap());
            match FROZEN.iter().find(|(n, _)| *n == name) {
                Some((_, want)) => {
                    assert_eq!(&got, want, "wire layout of {name} changed");
                    let back: PeerMsg = rmp_serde::from_slice(&hex::decode(want).unwrap()).unwrap();
                    assert_eq!(hex::encode(rmp_serde::to_vec(&back).unwrap()), *want);
                }
                None => panic!("no frozen fixture for {name}: (\"{name}\", \"{got}\")"),
            }
        }
    }

    #[tokio::test]
    async fn ext_roundtrips_and_old_readers_skip_it() {
        #[derive(Serialize, Deserialize, PartialEq, Debug)]
        struct V1 {
            a: u32,
        }
        #[derive(Serialize, Deserialize, PartialEq, Debug)]
        struct V2 {
            a: u32,
            #[serde(default)]
            b: String,
        }
        // a newer sender's extra field is ignored; an older sender's missing field defaults
        let m = ext(ext::DEVICE_SYNC, &V2 { a: 1, b: "x".into() });
        let PeerMsg::Ext { kind, body } = &m else { panic!() };
        assert_eq!(*kind, ext::DEVICE_SYNC);
        assert_eq!(ext_body::<V1>(body).unwrap(), V1 { a: 1 });
        let PeerMsg::Ext { body, .. } = ext(1, &V1 { a: 2 }) else { panic!() };
        assert_eq!(ext_body::<V2>(&body).unwrap(), V2 { a: 2, b: String::new() });
        // a v2 reader (no Ext variant) skips the frame and keeps reading the stream
        #[derive(Deserialize, Debug)]
        #[allow(dead_code)]
        enum OldMsg {
            Ping { t: u64 },
        }
        let (mut a, mut b) = tokio::io::duplex(1 << 16);
        write_frame(&mut a, &m).await.unwrap();
        write_frame(&mut a, &PeerMsg::Ping { t: 3 }).await.unwrap();
        for want_some in [false, true] {
            let mut len = [0u8; 4];
            b.read_exact(&mut len).await.unwrap();
            let mut buf = vec![0u8; u32::from_be_bytes(len) as usize];
            b.read_exact(&mut buf).await.unwrap();
            assert_eq!(rmp_serde::from_slice::<OldMsg>(&buf).is_ok(), want_some);
        }
    }

    #[test]
    fn fuzz_ext_bodies_never_panic() {
        #[derive(Deserialize)]
        #[allow(dead_code)]
        struct Any {
            #[serde(default)]
            v: u8,
            #[serde(default)]
            items: Vec<serde_bytes::ByteBuf>,
        }
        for i in 0..2000u32 {
            let len = (i % 131) as usize;
            let data: Vec<u8> = (0..len).map(|j| ((i as usize * 13 + j * 29) % 256) as u8).collect();
            let _ = ext_body::<Any>(&data);
            let _ = ext_body::<SyncBatch>(&data);
        }
    }

    #[tokio::test]
    async fn sync_frames_roundtrip() {
        let (mut a, mut b) = tokio::io::duplex(1 << 20);
        let batch = SyncBatch { items: vec![serde_bytes::ByteBuf::from(vec![1, 2, 3])], cursor: vec![9], done: true, phase: 2, ..Default::default() };
        write_sync_frame(&mut a, &batch).await.unwrap();
        drop(a);
        let got = read_sync_frame(&mut b).await.unwrap().unwrap();
        assert_eq!(got.items[0].as_ref(), &[1, 2, 3]);
        assert!(got.done && got.phase == 2 && got.cursor == vec![9]);
        assert!(read_sync_frame(&mut b).await.unwrap().is_none());
    }

    /// Fuzz regression: ~1000 nested `Wrapped` (26 KB) used to overflow a 2 MB tokio worker
    /// stack and abort the process; nested arrays in a remote-input event did the same.
    #[test]
    fn deep_nesting_is_rejected_not_a_stack_overflow() {
        let nested = |n: usize| {
            let mut v = Vec::new();
            for _ in 0..n {
                v.extend_from_slice(b"\x81\xa7Wrapped\x92\xc4\x10");
                v.extend_from_slice(&[0u8; 16]);
            }
            v.extend_from_slice(b"\x81\xa4Ping\x91\x01");
            v
        };
        let r = std::thread::Builder::new()
            .stack_size(1 << 20)
            .spawn(move || {
                assert!(decode_peer_msg(&nested(3)).is_ok(), "legit nesting must still decode");
                for n in [100, 1000, 5000] {
                    assert!(decode_peer_msg(&nested(n)).is_err());
                }
                let arrays: Vec<u8> = std::iter::repeat_n(0x91u8, 5000).chain([1]).collect();
                assert!(from_slice_capped::<serde_json::Value>(&arrays).is_err());
                assert!(ext_body::<serde_json::Value>(&arrays).is_err());
            })
            .unwrap()
            .join();
        assert!(r.is_ok());
    }

    #[test]
    fn fuzz_garbage_never_panics() {
        for i in 0..2000u32 {
            let len = (i % 97) as usize;
            let data: Vec<u8> = (0..len).map(|j| ((i as usize * 31 + j * 17) % 256) as u8).collect();
            let _ = rmp_serde::from_slice::<PeerMsg>(&data);
            let _ = rmp_serde::from_slice::<Signal>(&data);
        }
    }
}
