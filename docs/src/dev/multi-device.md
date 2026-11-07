# Lumora multi-device design and implementation plan

I read the core crates to check the stated architecture. It is accurate. The code also has seven constraints that decide the design, so read §0 first.

---

## 0. Codebase facts the design depends on

1. **An old peer stops reading its control stream when it gets a message type it doesn't know.** In `node/conn.rs`, `spawn_control` loops on `while let Ok(m) = proto::read_frame(..)`. `read_frame` fails on any undecodable frame, and the loop exits. The connection stays open but nothing more is processed.
   - Messages are encoded by variant name (rmp-serde writes `{ "VariantName": [...] }`), so an unknown variant fails to decode.
   - Rule: no new `PeerMsg` variant may reach a peer unless the version in its `Hello` says it understands it.
2. **Structs are encoded as arrays.** rmp-serde with the default config writes arrays. Decoding fails with `LengthMismatch` if there are extra elements (`rmp-serde-1.3.1/src/decode.rs:571`).
   - Old peers therefore cannot decode `ChatMsg`, `Signed`, `SealedInner`, `LanAnnounce` or `Hello` if a field is added.
   - Rule: never add fields to existing wire structs. New wire structs use `rmp_serde::to_vec_named` (map encoding, so unknown keys are ignored).
3. **Every content signature is a `Vec<u8>`.** This covers `ChatMsg.sig`, `PeerMsg::Action.sig`, `group::Signed.sig`, `Story.sig` and the invite `sig`. A longer, tagged signature can be carried without changing any struct. Old verifiers reject it cleanly: `Signature::from_slice` fails and `PeerId::verify` returns false.
4. **Group anti-entropy assumes one writer per author.** `GroupSync { heads: Vec<(PeerId,u64)> }` and `group_log(author, hlc)` record "for each author, everything up to this HLC".
   - Two devices posting as the same account would create permanent gaps.
   - Fix: key the log and heads by the signing device.
5. **Key rotation would run on every one of my devices at once.** In `groups.rs::apply_group_payload`, `i_rotate = s.author == self.me`. Once the account is the author, all my devices would rotate concurrently.
   - Each rotating device calls `group_key_put(epoch, key)` before publishing. The losing devices keep a wrong key for that epoch.
   - Fix: only the device that signed the op rotates.
6. **`self.me` means two things today.** It is used both as "my account" and as "my transport key". Four checks would break on a secondary device whose primary key equals the account:
   - `connect()`: `peer == self.me` would refuse to dial my own primary.
   - `handle_signal`: `from == self.me` would ignore signals from my own primary.
   - `setup_conn(.., self.me, ..)` (the dialer).
   - `dialer == self.me`.
7. **Single points of failure for linking or self-sync.**
   - `store.rs`: `outbox(id, to_peer)` already allows many rows per message id. `mailbox(for_peer)` and the relay mailbox are keyed by the recipient key.
   - `olm.rs` already keys sessions by the transport `PeerId`. Once the transport identity is a device key, Olm is per device with almost no change.

---

## 1. Identity model

### Keys

| Term | What it is | Where it lives |
|---|---|---|
| **Account root key** | The existing Ed25519 `Identity`; its public key is the **AccountId**. It is today's `PeerId`, short ID, `@handle` tag, security code and safety number. | Only on the **primary** device and in the recovery phrase. |
| **Device key** | One Ed25519 key per device; its public key is the **DeviceId**. It is the TLS identity, the `seal_to`/`open_sealed` identity, the Olm signing key, the DHT ConnInfo key and the Nostr inbox. | Each device's keystore (`keystore.json` stays unchanged). |
| **Primary device (device #0)** | Its device key **is** the root key: DeviceId == AccountId. | Every existing install becomes this automatically. |
| **DeviceCert** | `{account, device, created, caps}` signed by the root. | Carried by secondary devices. |

Why the existing key doubles as device #0: old peers dial and TLS-pin the AccountId. Keeping the root key as the primary's transport key means old peers keep working with no flag day.

### Why the root key is not copied to other devices

If every device held the root key, a stolen laptop could:
- open everything sealed to the account,
- sign as the account,
- re-add itself to the device list.

Revocation would then mean nothing without changing the AccountId, which breaks the "a revoked device can no longer decrypt" requirement. So the root stays on the primary.

### Recovery implications

These go in `docs/src/dev/security.md` and the UI:
- **Restoring from the phrase** (`NodeConfig.recovery_phrase`) produces the primary again, exactly as today. It then publishes `DeviceList` version + 1 and keeps the secondaries it finds (from the DHT device record or its siblings).
- **Promote** (`device_promote{phrase}`, Phase 6): a secondary enters the phrase, then:
  1. rewraps its keystore with the root as its identity,
  2. revokes its old device key,
  3. restarts as the primary.
- **A lost secondary** is revoked from the primary.
- **A lost primary** means the root key may be compromised. This is the same exposure as today. Mitigations: keystore passphrase, plus Promote on another device. True account rotation is out of scope.
- **Secondaries cannot show the recovery phrase.** The `recovery_phrase` API returns `err.phrase_on_primary`.
- **`export_backup` on a secondary** backs up that device. Restoring a revoked device is useless.
- **Recovery from friends** (node/recovery.rs, v1.0.8). A primary restored from its phrase into an
  empty folder has no contacts, so it cannot tell friends from anyone else by its own store. It
  therefore never says hello on connect: `Ext RECOVER_HELLO` goes only to a peer that proved it holds
  this account as a friend by sending `Ext DHT_KEY` (a device sends its friends-only DHT key only to
  accounts that are friends in its own store, `share_dht_key`). Strangers, pending requests and group
  co-members never learn that the account is recovering. The friend side still re-checks the
  friendship and the signed hello before offering anything.
- As soon as a linked device of mine brings messages back (sibling sync or history stream), the
  primary stops asking friends (`recover.since` = 0, event `recovery {recovering:false, own_device:true}`);
  offers already accepted still finish.
- Handed-back messages that are not signed by me carry `meta.restored_from` / `restored_peer`
  (the bubble shows "Restored from …"); a shared group joined back this way gets the neutral notice
  `sys.group_restored` instead of "… added you".

### Signer abstraction

New pure module `core/crates/lumora-core/src/devices.rs`, exported from `lib.rs`:

```rust
pub struct DeviceCert { pub account: PeerId, pub device: PeerId, pub created: u64, pub caps: u8, pub sig: [u8; 64] }
// signed bytes = b"lumora-devcert-v1" || account || device || created(LE u64) || caps
pub const CAP_PRIMARY: u8 = 1; pub const CAP_REMOTE_HOST: u8 = 2; pub const CAP_CALLS: u8 = 4;

pub struct Signer { id: Identity, account: PeerId, cert: Option<DeviceCert> }
impl Signer {
    fn sign(&self, msg: &[u8]) -> Vec<u8>   // 64 bytes if device==account, otherwise a 170-byte DevSig
    fn account(&self) -> PeerId
    fn device(&self) -> PeerId
}
pub enum SigBy { Account, Device { device: PeerId, cert: DeviceCert } }
pub fn verify_by(author: &PeerId, msg: &[u8], sig: &[u8]) -> Option<SigBy>  // pure; no revocation check
pub fn signer_device(author: &PeerId, sig: &[u8]) -> PeerId                 // device id, or author for a 64-byte sig
```

**DevSig layout** (inside the existing `sig: Vec<u8>` fields, 170 bytes):

| Bytes | Content |
|---|---|
| 0 | `0xD1` |
| 1..33 | device public key |
| 33..41 | cert.created (LE) |
| 41 | cert.caps |
| 42..106 | cert signature (root over the cert bytes) |
| 106..170 | device signature over the **unchanged** content signing bytes (e.g. `ChatMsg::signing_bytes(scope)`) |

The cert is self-contained, so group members can verify posts from a device whose list they haven't fetched yet. The cost is about 106 extra bytes, and only on messages from secondary devices.

### DeviceList wire format

```rust
#[derive(Serialize, Deserialize)] pub struct DeviceEntry { device: PeerId, name: String /*≤32*/, kind: u8 /*1 phone,2 tablet,3 desktop,4 cli*/, caps: u8, added: u64 }
#[derive(Serialize, Deserialize)] pub struct Revoked { device: PeerId, at: u64 /*list version*/, wipe: bool }
#[derive(Serialize, Deserialize)] pub struct DeviceListBody { v: u8 /*=1*/, account: PeerId, version: u64, devices: Vec<DeviceEntry>, revoked: Vec<Revoked> }
pub struct SignedDeviceList { body: Vec<u8> /* to_vec_named(DeviceListBody) */, sig: [u8; 64] /* root over b"lumora-devlist-v1" || body */ }
pub const MAX_DEVICES: usize = 8; pub const MAX_REVOKED: usize = 32;
```

- **Version:** `version = max(prev + 1, hlc.tick())`, so it is monotonic and close to real time.
- **Validation (`SignedDeviceList::validate`):**
  - the signature checks against `account`;
  - `v == 1`;
  - at most 8 devices, with unique device keys;
  - no device is both active and revoked;
  - if `account` appears as a device it has `CAP_PRIMARY`;
  - the version is strictly greater than the cached one.
- **Ties:** if two root holders produce the same version, the larger `blake3(body)` wins.
- **Signing:** we sign the stored bytes, never a re-encoded struct.
- **Migration:** on first start after upgrade, `node/devices.rs::ensure_own_list()` creates version 1 = `[{device: me, name: default device name, kind, caps: PRIMARY | REMOTE_HOST(if desktop) | CALLS}]`.
- **Single-device users:** the list is never pushed to anyone and never published to the DHT, so their overhead is close to zero.

### How peers learn and refresh device lists

1. **TLS.**
   - A secondary puts its DeviceCert in its X.509 certificate as an extra SAN URI `lumora:devcert:v1:<base32(msgpack cert)>`.
   - Change `tls::make_cert(id, cert: Option<&DeviceCert>)` and add `tls::remote_identity(conn) -> (PeerId, Option<DeviceCert>)` (read via x509-parser `subject_alternative_name()`).
   - Old peers ignore the SAN; pinning stays by DeviceId.
   - This lets `setup_conn` know the account before any message arrives.
2. **On every connection with a peer whose Hello version is ≥ 3:** exchange `Ext DeviceSync { my_version, your_version_i_have }`. Whoever is newer pushes `Ext DeviceList { signed }`.
3. **Push on change:** the primary sends the new list with `deliver` (reliable, with offline mail) to its siblings and to every device of every friend running version 3. It also goes out with `FriendRequest` and `FriendAccept`.
4. **Stale-list detection:** if a valid cert or DevSig names a device that is not in our cached list, our list is stale. Send `Ext DeviceListRequest` to that device.
5. **DHT:** the primary publishes a compact record (`{version, [(device, caps)]}`) as a mutable item under the account key with salt `b"lumora-devs"`. This is new `Dht::publish_devices` / `lookup_devices` in `net/discovery.rs`. The BEP44 item signature is by the account key, which authenticates it. It is only published when there are 2 or more devices.

### Stale or compromised devices

- **Stale list on a sender:** that sender only reaches the devices it knows about. The account's own siblings repair the gap with anti-entropy (§3).
- **Compromised secondary:** revoke it (§6, Phase 6).
- **Revocation check:** this is node-level, not in the pure verifier. `Node::is_revoked(account, device)` is true if the newest list has a `Revoked` entry for that device. Any not-yet-stored content signed by a revoked device is dropped.
  - History that arrives through our own sibling sync is still accepted.
  - A connection from a revoked device is closed in `setup_conn` with reason `"revoked"`.

---

## 2. Linking protocol

The new device **N** shows a QR code or short code. The existing device **E** scans or types it and approves. In v1, **E must be the primary**; the UI on a secondary says so. Approval from any device is future work.

Both sides speak version 3. All link messages are `PeerMsg::Ext` kinds (§3).

### Step 0: N starts in link mode

- Onboarding offers a choice: "Liên kết với thiết bị khác". This starts the node with `NodeConfig.link_pending = true` (CLI flag `--link-pending`).
- N generates its device key Kd as a normal identity and keystore.
- While pending, N does **not** publish its directory record or username, does not run the friend reconnect sweep, and does not create stranger contact rows.
- N **does** subscribe to its Nostr inbox (`inbox_tag(Kd)`) and publishes its DHT ConnInfo, so it can be dialed.
- `link_start` is rejected on non-fresh nodes (contacts, messages or groups present) and on bots (`err.bot_single_device`).

### Step 1a: QR path

N displays:

```
lumora://link/<base32(to_vec_named{v:1, d:Kd, s:S[32], a:[≤4 SocketAddr], r:[≤2 relay URL], n:"Laptop", k:kind, e:expires_ms})>
```

Here S is 32 random bytes, and the QR expires after 10 minutes.

### Step 1b: Short-code path

N displays a 12-digit code `rrrr-pppp-pppp`.

- **Rendezvous (no secret involved):**
  - **Nostr:** N posts an ephemeral event every 5 s with a new `LINK_KIND = 21213` and tag `p = hex(blake3::derive_key("lumora link rv v2", first 6 digits))` (was the first 4 digits: 10⁴ buckets made concurrent links share tags). The content is plaintext `to_vec_named{d:Kd, a, r}` and reveals nothing secret.
    - Add to `net/nostr.rs`: `subscribe_tag(tag) -> mpsc::Receiver<Value>` (an extra `REQ` with sub id `lumora-link`, routed by sub id in `relay_loop`) and `post_ephemeral(kind, tag, content)`.
  - **LAN:** N multicasts a `LinkBeacon` packet with magic `"LMRL"` and `{rv_hash[..8], Kd, port, addrs}`.
    - Use a new beacon table in `net/discovery.rs`. Keep `LanAnnounce` v1 unchanged, because old parsers reject extra fields.
- **Authentication:** SPAKE2 using the `spake2` crate (Ed25519 group), with all 12 digits as the password.
  - What is published can be ground offline to at most the 6 rendezvous digits; the other 6 stay secret.
  - An active attacker gets one guess per session (probability 1e-6), 3 guesses per code.
  - N regenerates the code after 3 failed sessions.
- **IP privacy (pre-authentication, `Ext LINK_PRE` over sealed signaling mail):** the device showing the QR / code answers offers (reveals its addresses) only to a device that proved it first: QR → `pre_qr_proof(S, holder, scanner, nonce)` both ways; code → SPAKE2 over signaling with confirmations both ways (`pre_pake_confirm`, roles 11/12/13), each attempt counted as a guess until it confirms; ≤ 10 attempts a minute. The scanning device doesn't dial a Nostr rendezvous candidate before that; LAN beacon candidates (LAN addresses) and the QR's own addresses are dialed directly, and the connection-level proofs below run as before.
- **Device acceptance:** N's `LinkInfo` carries `accept` = N's signature over `lumora-devaccept-v1 ‖ account ‖ N`; E puts it into N's entry (`DeviceEntry.proof`). Friends bind a listed device to an account only with that proof (or a certificate the device itself presented) and never re-assign a device known under another account; linked devices from before proofs send theirs to the main device with `Ext DEVICE_ACCEPT`.

### Step 2: E connects

E resolves Kd from the QR, a Nostr candidate or a LAN beacon. It then calls `connect(Kd)`, which uses the existing machinery: LAN fast path, then Nostr/relay offer, hole punching, spraying, relay fallback. TLS is pinned to Kd, so N is authenticated to E.
- With the short code, E tries each rendezvous candidate in turn, because beacons are unauthenticated.
- In `handle_signal`, N must answer offers from strangers and must not record E as a contact.

### Step 3: Authenticate E to N

Both proofs bind the channel with `conn.export_keying_material(b"lumora-link", ..)`.
- **QR:** E→N `Ext LinkHello { proof = blake3::keyed_hash(S, "lumora-link-qr-v1" || Kd || E_dev || A || exporter) }`.
- **Code:** `Ext LinkPake { msg }` in both directions, then `Ext LinkConfirm { mac = keyed_hash(K_pake, role || Kd || E_dev || exporter) }` in both directions.
- On failure: `LinkReject`, the connection closes and the failure counter increases.

### Step 4: N describes itself

N→E `Ext LinkInfo { name, kind, os, app_version }`. E shows the approval sheet:
- device name and OS,
- path (LAN, Internet or relay),
- history choice: none / 1 / 3 / 6 / 12 months / all, with a test-only absolute `history_since_ms`,
- "include media" (default off; files are fetched on demand).

### Step 5: Approval on E

1. Issue `DeviceCert(Kd, caps)`.
2. Build list version + 1 and sign it with the root.
3. Save it and seed `sync_peers(Kd).sent_upto = current sync_log seq`.
4. Send E→N `Ext LinkAccept { cert, list, account: A, counts }`.
5. Push the new list to siblings and friends, and publish the DHT device record.

### Step 6: Bootstrap stream (all small state, before history)

- Use a new uni stream kind `STREAM_SYNC = 0x05` (in `proto.rs`, dispatched in `spawn_conn_tasks`).
- Frames are length-prefixed `to_vec_named(SyncBatch { items: Vec<ByteBuf>, cursor: Vec<u8>, done: bool })`, at most 256 KB each.
- Items (each decoded independently, so unknown kinds are skipped):
  - profile keys (name, bio, status, avatar, cover, username),
  - contact rows including avatar/cover/bot/username,
  - cached friend DeviceLists,
  - conversation rows and flags,
  - group states and op logs,
  - all `group_keys`,
  - group_log rows inside the history window,
  - sync-whitelisted kv entries,
  - sticker packs and blobs,
  - `botfather.bots` tokens, for management only,
  - `remote_trusted`.
- **Not sent:** the root key, Olm state, outbox, mailbox, peer_cache, net settings, storage policy, scheduled messages (these stay per device).
- The bootstrap is streamed rather than sent in `LinkAccept`, because avatars alone can exceed `MAX_CONTROL_FRAME` (4 MB).

### Step 7: N switches to the account

1. N writes kv `account.id = A`, `account.cert`, `account.role = "secondary"`.
2. It imports the bootstrap in transactions (`Store::import_batch`).
3. It emits `link_state {state: "restart"}`.
4. The app (FFI `lumora_stop` + `lumora_start`) or `lumorad` (re-runs `Node::start`) restarts.
5. `Node::start` reads `account.*`: `me = A`, `device = Kd`, `signer = Signer{Kd, A, Some(cert)}`, and calls `Transport::start(id, Some(cert), ..)`.
6. Keep `Node.me` immutable for the life of a `Node`; restarting is simpler than making it mutable.

### Step 8: History (Phase 4)

After the restart, N connects to E as a sibling and sends `Ext HistoryRequest { since_ms, cursor, media }`. E streams on `STREAM_SYNC`.
- **Cursor:** `(conv, hlc, id)`. Iterate conversations in sorted order, then messages through the existing `messages_conv(conv, hlc)` index. This needs no new index, and it is stable even after VACUUM.
- **Each batch carries:**
  - message rows (body, status, edited/deleted, reactions, pinned, meta, reply_to, expires, device),
  - group_log rows,
  - file rows with a new state `6 = "on another device"` and `peer = E` (thumbnails are already in the body JSON).
- **N's handling:**
  1. insert each batch in one transaction with `INSERT OR IGNORE`, so retries are idempotent;
  2. persist `sync_peers(E).hist_cursor` after each commit;
  3. if the connection drops, reconnect and resend `HistoryRequest` with the saved cursor;
  4. emit `history_sync { messages, convs_done, convs_total, done }`.
- **Serving:** any non-revoked sibling can serve history; N prefers E.
- **Encryption:** QUIC TLS 1.3 between the two pinned device keys, plus SQLCipher at rest.

---

## 3. Fan-out, self-sync, wire additions and conversation IDs

### Wire additions (`proto.rs`)

- `PROTO_VERSION`: 2 in Phase 0 (tolerant reader), 3 in Phase 1 (multi-device). There is no capability field, so the number carries the meaning.
- One new variant: `PeerMsg::Ext { kind: u16, #[serde(with="serde_bytes")] body: Vec<u8> }`. The body is `to_vec_named` of a kind-specific struct. Readers ignore unknown kinds. Helpers: `proto::ext(kind, &T)` and `ExtKind` constants:

| Kind | Name | Notes |
|---|---|---|
| 0x01 | DeviceSync | |
| 0x02 | DeviceList | |
| 0x03 | DeviceListRequest | |
| 0x10 | LinkHello | |
| 0x11 | LinkPake | |
| 0x12 | LinkConfirm | |
| 0x13 | LinkInfo | |
| 0x14 | LinkAccept | |
| 0x15 | LinkReject | |
| 0x20 | SelfSync | own devices only |
| 0x21 | HistoryRequest | |
| 0x22 | HistoryStatus | |
| 0x30 | GroupRekeyRequest | |
| 0x31 | GroupKeyRequest | `{gid, epoch}`: a member without that epoch's key asks members; answered with sealed `GroupKey` |
| 0x32 | GroupReport | `{id, gid, msg_id, excerpt, member, reason, note, ts}`: a member reports a message / member to each owner / admin device (node/reports.rs) |
| 0x33 | GroupReportDone | `{ids}`: own devices only — reports handled on the sender |
| 0x40 | Proxy | legacy bridge, to own primary only |

- **Gating:** `PeerConn.proto: AtomicU32` is set from `Hello.version`, and the maximum is persisted in `contacts.proto` / `devices.proto`.
  - Only send `Ext` when proto ≥ 3, or when the device appears in a DeviceList (which implies version 3).
  - Never put `Ext` into the outbox for a device whose capability is unknown.
- Olm may wrap `Chat`, `Action`, and `Ext` of kind SelfSync. Widen the `ensure!(matches!(..))` in `handle_msg` and `on_mail`.

### Connection model (`node/mod.rs`, `node/conn.rs`)

- `peers: HashMap<DeviceId, Arc<PeerConn>>`. Deduplication stays per device.
- New `PeerConn` fields:
  - `account: PeerId` (from the TLS cert; otherwise the cached `account_of`; otherwise itself),
  - `own: bool` (`account == self.me && device != self.device`),
  - `proto`.
- New `Node` fields:
  - `device: PeerId`,
  - `signer: devices::Signer`,
  - `devs: devices::Registry` (an in-memory `account → Arc<AccountDevices>` and `device → account` cache backed by the store, bounded by contact count).
- In `handle_msg`, set `let from = pc.account; let dev = pc.peer;`. Account-level handlers then work unchanged (friend checks, `direct_conv(&from)`, group membership). Device-level spots:
  - `Ack` → `outbox_remove(&id, &dev)`
  - Olm handlers use `dev`.
  - `StoreFor { to }`: allowed if `is_friend(from)` and (`is_friend(account_of(to))` or `account_of(to) == self.me`); the mailbox is keyed by device.
  - File requests and streams, remote desktop and calls stay on `pc`.
  - `inbound_allowed` is keyed by account.
- `on_mail` / `handle_signal`: the sealed `from` is a device; map it with `account_of(from)`. For an unknown device:
  - **Chat / Action:** learned from the DevSig cert.
  - **GroupKey:** accepted only if it matches `key_commits` (the commitment is authoritative).
  - **GroupWelcome:** parked in a bounded `pending_welcomes` (16 entries) while `resolve_device(dev)` dials the device and reads its TLS cert.
  - In `handle_signal`, do not create stranger contact rows for devices that map to a known account. When a device's account is learned, delete any status-0 contact row keyed by that device.

### Delivery fan-out

- Rename the current `deliver` to `deliver_dev(to_device, id, m, mail)` (Olm wrap, outbox, send or dial, mail — unchanged logic).
- New `deliver(to_account, id, m, mail)` loops over `delivery_targets(account)`:
  - active devices from the list, or `[account]` if no list is known;
  - minus revoked devices;
  - minus **dormant** devices (`last_seen` more than 30 days ago and added more than 30 days ago). Their outbox rows are purged in `maintain()`, and they catch up from siblings when they return.
  - When `to_account == self.me`, the targets are my siblings, excluding myself.
- Existing call sites (`deliver(p, ..)` with `p` an account) fan out automatically. That includes friend requests and accepts, profile, read receipts, stories, group welcome/key/envelopes, and actions.
- `send_now(account, m)` sends to all connected devices of the account. `send_now_dev` is the per-device version used by calls and remote desktop.
- `connect_any(account)` races the active devices and returns the first connection. Use it for single-target requests:
  - `JoinRequest` and `JoinPublic`, so the group is not added twice;
  - `resolve_device`.
- **Message status:** an `Ack` from any device sets status 2. Outbox rows remain per device.
- **Reconnect sweep (`spawn_background`):** connect to own siblings always; to friends' devices seen in the last 7 days (at most 3 per friend); others only when the outbox has items for them. This bounds the number of QUIC connections and battery use.

### Self-sync (new `node/sync.rs`)

`Ext SelfSync` body: `SyncMsg = Items { items: Vec<ByteBuf> } | Have { from_seq, to_seq, digests: Vec<(u8, ByteBuf, u64)> } | Want { keys } | Ack { upto_seq }`.

Each item is `#[serde(tag = "t")] SyncItem`, encoded separately:

| Item | Fields | Merge rule |
|---|---|---|
| `Msg` | `{ conv, msg: ChatMsg, status }` | Mine or received, including `s:me`. The receiver re-verifies the signature (`dm_scope(me, peer)` / `b"s"`), so trust is not needed. |
| `Action` | `{ conv, id, author, hlc, action, sig }` | Re-verified. |
| `Read` | `{ conv, upto_hlc }` | Maximum wins. |
| `ConvFlags` | `{ conv, muted?, pinned?, archived?, mute_until?, hlc }` | Last writer wins. |
| `ConvClear` | `{ conv, upto_hlc, delete_chat, hlc }` | |
| `Purge` | `{ conv, id }` | Delete for me. |
| `Contact` | `{ peer, status, alias, verified, hlc }` | Last writer wins. |
| `Kv` | `{ key, value, hlc }` | Last writer wins. Whitelist: `profile.*`, `privacy.*`, `ui.lang`, `wallpaper.*`, `mute_until.*`, retention. Never `net.*`, `olm.*`, `remote.*`, `bot.*`, `account.*`, `device.*`, `link.*`. |
| `GroupKey` | `{ gid, epoch, key }` | |
| `GroupWelcome` | `{ welcome bytes }` | |
| `Story` / `StickerPack` / `Sticker` | | |
| `Status` | `{ id, status }` | Maximum wins. |
| `FileAvail` | `{ file_id, device }` | |

Two layers:
1. **Eager push.** Every local change I make calls `sync_push(item)`, which is `deliver(self.me, random id, Ext SelfSync, mail = true)`. This gives Olm per sibling, the outbox, and relay/friend mailboxes for offline siblings. Hooks:
   - `chat.rs`: `send_body_meta` (direct and Saved), `message_action`, `mark_read`, `delete_for_me`, `clear_history`, `add_contact`, `accept_contact`, `remove_contact`;
   - `api.rs`: `rename_contact`, `mark_verified`, `conv_flag`, `mute`, `settings_set`, `set_retention`, `set_wallpaper`;
   - `social.rs`: `set_profile`, `set_username`;
   - `extras.rs`: `post_story`;
   - `stickers.rs`.
2. **Anti-entropy (repair).** This covers received messages, mail sealed to the account (only the primary can open it), messages from old peers, and messages from senders with a stale list.
   - New table `sync_log(seq, kind, key, hlc)` is appended on message insert, action, read, flags, contact and kv changes, **only when the account has 2 or more active devices**.
   - When a sibling connects (and every 30 s while connected if `seq` has advanced): send `Have(sent_upto..head)` in batches of 500. The sibling replies `Want`, we send `Items`, the sibling sends `Ack`, and we advance `sync_peers.sent_upto`.
   - Trim `sync_log` up to the lowest `sent_upto` among active siblings.

Deduplication: message ids are random 16-byte values, and `insert_message` ignores duplicates by id. `seen_wrapped` deduplicates per hop. `conv_touch(unread_inc)` and the `message` event fire only when the row is new. Read state is a maximum, so the sync clears unread counts and notifications on the other devices.

Profile and directory:
- Any device may push `ProfileV2`; it is unsigned and travels over authenticated connections.
- Directory and username publishing stays on the primary, because it needs the account's Nostr `dir_key` and a root signature.
- Secondaries store the primary's last signed Nostr events (kv `nostr.events`, delivered by sync) and re-broadcast them verbatim when the primary is offline.
- Each secondary publishes its own device short-ID record with extra JSON fields `account` and `cert`. Old resolvers ignore them; version-3 `resolve_id` maps the device to its account for contacts but keeps the device for remote desktop.

### Conversation IDs

- `d:<account base32>`: `direct_conv` and `parse_conv` stay unchanged, so existing data needs no migration.
- `messages.author` stays the account. "Mine" (`m.author == self.me`) is therefore true on every one of my devices.
- New nullable column `messages.device` records the authoring device ("Gửi từ Laptop").
- There is no conversation with my own devices; Saved (`s:me`) syncs.

---

## 4. Olm

- Sessions are already keyed by transport `PeerId`, which becomes the `DeviceId`:
  - kv `olm.sess.<device>`,
  - the pickle key comes from the device secret,
  - `OlmKeys` and `curve_sig` are signed by the device.
- Change the gating in `olm_ensure_session` and `on_olm_keys_request` from `is_friend(&pc.peer)` to `is_friend(&pc.account) || pc.own`.
- **Encrypting for N devices:** `deliver(account)` calls `deliver_dev` per device, and each wraps the plaintext with that device's session (`olm_wrap(to_device, &inner)`). That is N symmetric ratchet steps — cheap.
- With no session yet (the device has never been online with us), the payload is sealed to the device key (`seal_to`). It is still end-to-end encrypted, but without forward secrecy until the session exists. This matches today's fallback.
- **Revocation:** delete `olm.sess.<device>` and the in-memory sessions.
- **Linking:** E and N run `OlmKeysRequest` immediately after the restart.
- **Optional (Phase 10):** a vodozemac fallback key per device in a device-signed `DeviceKeys` record, so senders can start sessions with offline devices.

---

## 5. Groups

- **Membership stays at the account level.** `GroupState.members`, `Role`, `Add`/`Remove`/`Leave` are unchanged, so old members converge.
- **Op and message signing:**
  - `Signed::new(&Signer, ..)`, `group::create(&Signer, ..)` (`derive_gid(signer.account(), id)`).
  - `Signed::verify` → `verify_by(..).is_some()`.
  - In `apply_group_payload`, `msg.author.verify(..)` → `verify_by`.
  - `on_bot_group_msg` / `on_bot_group_post` also switch to `verify_by`.
  - Node-level revocation check after `open_envelope` in `on_group_envelope`.
- **Anti-entropy:**
  - `group_log_put(&s.id, &gid, &signer_device(&s.author, &s.sig), ..)`; `group_log_heads` / `GroupSync` heads are per signer device. For primary-signed entries this is identical to what old peers send.
  - `on_group_sync`: for peers with proto < 3, serve only rows whose signer is a member account, so we don't resend envelopes they can never open.
- **Rotation:** `i_rotate` = (the signer device of the op == `self.device`) or (op is `Leave`, `after.owner == self.me`, and I am primary).
- **Key delivery:**
  - `rotate_key` and `send_welcome` seal `KeyUpdate` / `Welcome` per device of each `key_holders()` account (`delivery_targets`).
  - `publish()` delivers envelopes to the devices of every member, including my own siblings. Replace `if m == self.me { continue }` with an exclusion of `self.device`.
  - Gossip in `on_group_envelope` picks up to `GOSSIP_FANOUT` connected member devices.
  - `GroupTyping` / `GroupRead` use `send_now(account)`.
  - `on_group_key` / `on_group_welcome`: map sender device → account for `is_member` / `is_friend`, then forward the accepted key or welcome to siblings (`SyncItem::GroupKey` / `GroupWelcome`). This covers senders whose copy of my list is stale; the overhead is tiny.
- **Revoking a device of account A:**
  - Groups where A is admin or owner: the revoking device calls `rotate_key`.
  - Otherwise: send `Ext GroupRekeyRequest { gid, account, list_version }` to the admins' devices. An admin device rotates if the requester's list contains a `Revoked.at` newer than the HLC of the Rekey op for `st.epoch` (at most once per minute per group).
  - The revoked device's account stays a member, but the device gets no new epoch keys and its signatures are rejected.
  - Do not change the fold rules: member-initiated Rekey would split old peers into a different state.

---

## 6. Store schema migrations (`store.rs`)

These are additive only, using `SCHEMA` plus `migrate()`.

**New tables:**

```sql
CREATE TABLE IF NOT EXISTS device_lists(account BLOB PRIMARY KEY, version INTEGER NOT NULL, list BLOB NOT NULL, sig BLOB NOT NULL, updated INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS devices(device BLOB PRIMARY KEY, account BLOB NOT NULL, name TEXT NOT NULL DEFAULT '', kind INTEGER NOT NULL DEFAULT 0,
  caps INTEGER NOT NULL DEFAULT 0, added INTEGER NOT NULL, revoked INTEGER, last_seen INTEGER NOT NULL DEFAULT 0, proto INTEGER NOT NULL DEFAULT 1);
CREATE INDEX IF NOT EXISTS devices_account ON devices(account);
CREATE TABLE IF NOT EXISTS sync_log(seq INTEGER PRIMARY KEY AUTOINCREMENT, kind INTEGER NOT NULL, key BLOB NOT NULL, hlc INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS sync_peers(device BLOB PRIMARY KEY, sent_upto INTEGER NOT NULL DEFAULT 0, hist_cursor BLOB, hist_done INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS lww(key TEXT PRIMARY KEY, hlc INTEGER NOT NULL);
```

**ALTERs:**
- `contacts ADD COLUMN proto INTEGER NOT NULL DEFAULT 1`
- `messages ADD COLUMN device BLOB`
- `convs ADD COLUMN read_upto INTEGER NOT NULL DEFAULT 0`

`files.state` gets the new value 6, meaning "stored on sibling `files.peer`".

**kv keys:** `account.id`, `account.cert`, `account.role`, `device.name`, `link.*`, `nostr.events`.

**New Store methods:**
- `device_list_get/put`, `devices_of`, `device_account`, `device_touch(dev, last_seen, proto)`, `device_set_revoked`
- `sync_log_append/since/trim`, `sync_peer_get/set`, `lww_newer(key, hlc) -> bool`
- `conv_set_read_upto(conv, upto, me) -> unread`
- `outbox_purge_device`
- `history_page(cursor, since_hlc, limit) -> (items, next)`
- `import_batch(items)` in one transaction
- `insert_message(.., device: Option<&PeerId>)`

`maintain()`: trim `sync_log`, purge outbox rows for dormant or revoked devices.

The keystore format is unchanged; a secondary's identity is its device key.

---

## 7. Discovery

| Channel | Per account | Per device |
|---|---|---|
| LAN multicast | — | `LanAnnounce v1` (unchanged), keyed by device. `LinkBeacon "LMRL"` while linking. |
| Mainline DHT | `lumora-devs` record (primary, when there are 2 or more devices): `{version, [(device, caps)]}`, signed by the account key | `lumora` ConnInfo record under the device key (`dht.publish(&node.id, ..)` is already device-level) |
| Nostr signaling | — | `inbox_tag(device)` (unchanged). Link rendezvous kind 21213. |
| Nostr directory | `lumora:sid:<account sid>` and `@username` from the primary; secondaries re-broadcast the stored signed events | Optional `lumora:sid:<device sid>` with `account` and `cert` (remote desktop IDs) |

Resolution: an account becomes devices through the cached DeviceList, then the DHT `lumora-devs` record. Each device is then reached with `connect(device)` (LAN, cached addresses, signal, DHT, relay). `connect_inner`'s DHT fallback (`dht.lookup`) stays per device.

---

## 8. API and app UI

### API (`api.rs`, documented in `docs/src/dev/api.md`)

**Changed:**
- `me` adds `account`, `device`, `primary`, `device_name`, `devices`.
- `recovery_phrase` returns `err.phrase_on_primary` on a secondary.
- `remote_connect {target, password, view_only, device?}`.

**New commands:**

| Command | Arguments / result |
|---|---|
| `devices` | — |
| `device_rename` | `{device, name}` (on the primary; a secondary sends the request through sync) |
| `device_revoke` | `{device, wipe_media}` (primary) |
| `device_logout` | self; secondary sends a request to the primary, then wipes locally |
| `device_promote` | `{phrase}` |
| `contact_devices` | `{peer}` |
| `link_start` | `{mode: "qr" \| "code", name}` → `{qr, code, expires}` |
| `link_scan` | `{qr \| code}` → `{device, name, os, path}` |
| `link_approve` | `{device, history: "none" \| "1m" \| "3m" \| "6m" \| "12m" \| "all", history_since_ms?, media}` |
| `link_reject` | `{device}` |
| `link_cancel` | — |
| `history_status` | — |

**Events:**
- `link_state {state: waiting | connecting | verifying | awaiting_approval | approved | restart | failed, reason}`
- `link_request`
- `devices`
- `history_sync`
- `device_revoked` (this device)
- `presence {peer: account, device, online}`, where an account is online if any of its devices is
- `call {…, answered_elsewhere}`
- `contact_device_added`, which also writes a system message in `d:<peer>` ("Lan đã liên kết thiết bị mới: Laptop"); gated by `privacy.device_notices`, default on

### Flutter (`app/lib`)

**Core and state:**
- `core/api.dart`: typed wrappers for the commands above.
- `core/mock_api.dart`: mock commands and events.
- `core/ffi_api.dart`: `link_scan` / `link_approve` timeouts; restart on `link_state: restart`.
- `state/stores.dart`: `DevicesStore`, `LinkStore`, history progress.
- `pubspec.yaml`: `mobile_scanner` (Android/iOS; desktop uses code entry).
- `l10n/strings_data.dart`: vi/en strings.

**New screens:**
- `ui/devices/link_new_device.dart` (on N):
  - large QR, the code `1234-5678-9012`, and a 10-minute countdown;
  - editable device name;
  - status steps;
  - then "Đang đồng bộ lịch sử… x/y" with a "Dùng ngay" button.
- `ui/devices/my_devices.dart` ("Thiết bị của tôi"):
  - rows with kind icon, name, "Thiết bị này" and "Chính" badges, online dot, last active, date added;
  - on the primary: "Liên kết thiết bị mới", plus Rename / "Đăng xuất thiết bị" / "Xoá dữ liệu từ xa" on each row;
  - on a secondary: "Đăng xuất thiết bị này" and "Đặt làm thiết bị chính (cần cụm từ khôi phục)".
- `ui/devices/scan_link.dart`: camera scan or code entry.
- `ui/devices/approve_sheet.dart`: the approval sheet from step 4.

**Edits to existing screens:**
- `ui/onboarding/onboarding_screen.dart`: third option, "Liên kết với tài khoản có sẵn".
- `ui/settings/settings_screen.dart`: add `SettingsPage.devices`.
- `ui/chats/chat_info.dart`: contact "Thiết bị (n)" section.
- `ui/remote/remote_home.dart` and `ui/flows.dart`: device picker ("Laptop của Lan" / "Điện thoại của Lan" = `s('device_of', {device, name})`), showing only devices with `CAP_REMOTE_HOST`.
- `ui/calls/call_layer.dart`: "Đã trả lời trên {device}" banner, then dismiss.
- Message info: "Gửi từ {device}".

### Calls and remote desktop (`node/remote.rs`)

- **Calls:**
  - `call_start` sends `CallInvite` to every online device of each callee account. `invited` holds devices; my own siblings are not rung.
  - On the first `CallAnswer{accept: true}` from device X of account B, send `CallEnd` (the existing variant, which old peers understand) to B's other invited devices. They stop ringing through the existing `CallEnd` path.
  - Decline on one device = decline for the account: send `CallEnd` to the others, and `end_call` if no accounts remain.
  - On incoming calls, check block and group membership with `account_of(from)`.
  - The busy state stays per device.
- **Remote desktop:**
  - `remote_connect` resolves the target; a device argument is required when the account has 2 or more `REMOTE_HOST` devices, otherwise an error lists them.
  - Sessions keep `peer = DeviceId`, and `proof(.., viewer, host)` binds device IDs.
  - Change the `err.self_control` check to `peer == self.device`. Own siblings are allowed, in ask mode by default.
  - `ask_mode` and `remote_trusted` use `account_of(peer)`.
  - Group call membership checks use the account.
- **Bots:** `link_*` refuse when `is_bot()` or a bot token is set. Bots never publish a DeviceList; senders treat them as `[account]`.

### Legacy bridge (Phase 9)

- A secondary cannot produce account-key signatures that old peers accept.
- For targets with proto < 3, the secondary sends `Ext Proxy { targets, msg }` to its own primary. The primary checks that the request is from a non-revoked sibling and that the DevSig device equals the sender. It then re-signs **with the same ids and HLC**:
  - `ChatMsg`, `Action`, or a group `Signed` with its inner `ChatMsg` (resealed with the epoch key);
  - it reseals `KeyUpdate` / `Welcome`, and forwards `ProfileV2`, `FriendRequest` and `FriendAccept`.
- Version-3 recipients deduplicate the two copies by id.
- Until the primary is online, those messages stay "pending". The UI shows "Bạn bè dùng phiên bản cũ — gửi qua điện thoại".
- Inbound from old peers is already handled by self-sync anti-entropy.

---

## 9. Test plan

### Unit tests (`cargo test -p lumora-core`)

- `proto`:
  - frozen version-1 byte fixtures still decode;
  - an unknown variant frame is skipped and the next frame is still read;
  - `Ext` round-trips;
  - fuzz `Ext` bodies.
- `devices`:
  - cert issue and verify;
  - DevSig: tampered content, wrong cert, cert for a different account;
  - list validation: replayed lower version, duplicate device, more than 8 devices, active and revoked at once, tie-break;
  - a 64-byte signature still verifies.
- `tls`: SAN cert round-trip; `remote_identity` against a cert with no SAN.
- `group`:
  - fold and convergence with DevSig ops;
  - `derive_gid` with the account as creator;
  - heads per signer device (two devices of one account with interleaved HLCs: no gap after sync);
  - only one rotation when ops come from different devices.
- `store`:
  - `history_page` cursor stability across inserts and deletes;
  - `import_batch` idempotent;
  - `sync_log` trim;
  - LWW.
- `link`:
  - QR proof bound to the TLS exporter (fails with another exporter);
  - SPAKE2 with a wrong code fails;
  - code parse and checksum.

### End-to-end (new `core/tests/multidevice.py`)

First move the `Node`, `step` and `wait_until` harness out of `e2e.py` into `core/tests/harness.py`. Add `--link-pending` support and a restart helper. Nodes: A0 (primary), A1 and A2 (linked), B0 and B1, C.

1. **Link by code over LAN.** A1: `link_start code`; A0: `link_scan` + `link_approve`. Check:
   - A1 `me.account == A0.peer`;
   - both list 2 devices;
   - contacts and groups are present on A1;
   - no stranger rows were created.
2. **Link by QR with `--no-lan --relay-only`** (A2): works with the relay or Nostr only.
3. **Short-code abuse.** A wrong code gets 3 failures, then the code rotates. A fake beacon with the same rendezvous does not stop a correct link, and gets no address from the scanning device (it must pass the PAKE over signaling first).
4. **History window.** Batch 1 of messages, then sleep, record t, then batch 2. Approve with `history_since_ms = t`: A2 has only batch 2, plus group history and file rows in state 6. A2 accepts a file and downloads it from A0.
5. **Resumable history.** 5,000 messages with `LUMORA_HIST_BATCH=50`. Kill A1 mid-transfer, restart: complete, no duplicates, RSS bounded.
6. **Fan-out.** B1 sends to A: it arrives at A0, A1 and A2. B shows delivered. Exactly one copy per device.
7. **Offline catch-up.**
   - Stop A2. B sends 10 messages; A1 sends 5 to B. Stop A1 and B.
   - Start A2: it gets B's 10 (from its own mail/mailbox, or from A0 by anti-entropy) and A1's 5 (self-sync mail).
8. **Self-sync.**
   - `mark_read` on A1 clears unread on A0 and A2.
   - Pin, mute and archive propagate.
   - `add_contact C` on A1; C accepts; A0 shows C as a friend.
   - Rename the profile on A1; B sees it; A0's `profile` is updated.
   - "Delete for me" propagates.
9. **Groups.**
   - A1 creates a group with B and C (B has 2 devices). Everyone posts; every device of every member gets every message.
   - Remove C on A1: exactly one Rekey op (from A1); all A and B devices decrypt epoch-1 messages; C cannot.
   - Add a new device to B after the group exists: it gets keys through forwarding or bootstrap.
10. **Revocation.**
    - A0 revokes A2 with wipe:
      - B's `contact_devices(A)` no longer lists A2;
      - B's outbox has no rows for A2;
      - A2's data folder is wiped (`device_revoked` event).
    - Group:
      - when A is admin, a rotation happens;
      - when A is a plain member, `GroupRekeyRequest` leads to a rotation by the admin;
      - in both cases new messages cannot be decrypted with A2's old keys (check A2's copied DB).
    - A connection from a revoked key is closed with `"revoked"`.
11. **Calls.**
    - B calls A: A0 and A1 both emit an incoming call. A1 answers: A0 emits ended within 2 s; B's participants are [A1].
    - Decline on A0 ends the call for the account.
12. **Remote desktop.** B runs `remote_connect {target: A, device: A1}`: only A1 emits `remote_state` (headless, no media). Without `device`: an error with the choices.
13. **Old-peer compatibility** (historical; used during the rollout, removed on 2026-11-06 because no
    old versions are in use — `multidevice_e2e.py` no longer has a legacy node and the legacy binary
    is gone). What it covered: a pre-multi-device node L chatting with A0 (chat, groups, files), never
    receiving undecodable frames, and reaching A1 through A0 (anti-entropy, Phase 9 bridge).
14. **Promote.** A1 runs `device_promote(phrase)`: it becomes the primary (DeviceId == account), A1's old key is revoked, and B can still message A.
15. **Overhead.**
    - `scale.py --n 12 --per 10 --devices 2` and single-device runs.
    - Budget: single-device RSS/CPU within 3% of baseline; 2 devices ≤ +25% CPU; outbox and `sync_log` drain to 0.

Also: NAT lab linking between CGNAT and symmetric NAT over the relay. Flutter widget tests for the link, device and approval screens using `mock_api`.

---

## 10. Phasing

Each phase ships on its own, keeps compatibility with version 1, and has its own tests.

### Phase 0: compatibility groundwork (ship first and widely)

**Changes:**
- `proto.rs`: `PROTO_VERSION = 2`; `read_frame` returns `Ok(None)` on decode errors (only I/O and size are fatal); add the `Ext` variant and helpers; fixtures and tests.
- `node/conn.rs`: the reader loop skips undecodable frames; `Hello` sets `pc.proto` and persists it; `Ext` is ignored for now.
- `node/mod.rs`: add `PeerConn.{account, own, proto}` and `Node.device` (= `me` for now). Change transport checks to `self.device`: `connect`, `setup_conn` dialer, `handle_signal` `from == self.me`, and in `remote.rs` the `err.self_control` check.
- `store.rs`: migrations `contacts.proto`, `messages.device`, `convs.read_upto`.
- (Historical) a legacy binary was kept for the old-peer tests; removed on 2026-11-06.

**Risk:** low. This phase makes later rollouts safe even with peers that are only partly upgraded.

### Phase 1: device identity, DeviceList, DevSig (still single-device)

**Changes:**
- New `devices.rs`; `lib.rs`.
- `tls.rs`: SAN cert and `remote_identity`.
- `net/mod.rs`: `Transport::start(id, cert, cfg)`, `client_config(&id, cert, ..)`.
- New `node/devices.rs`: Registry, `account_of`, `delivery_targets` (single entry for now), `ensure_own_list`, DeviceSync / DeviceList / DeviceListRequest handlers, revocation check.
- `node/mod.rs`: `signer`, `devs`; `setup_conn` uses the TLS identity, a revoked check and `is_blocked(account)`.
- `node/conn.rs`: `from = pc.account`; device-level spots; DeviceSync on `Hello ≥ 3`.
- Signing and verification:
  - `chat.rs`: `new_chat_msg_meta`, `message_action`, `press_button`, `accept_direct`, `on_direct_action`;
  - `extras.rs`: `post_story` / `on_story`;
  - `social.rs`: invites, `on_join_request`, `parse_invite`;
  - `groups.rs` and `group.rs`: `Signer`, `verify_by`, signer-device heads, `i_rotate` fix, `on_group_sync` filter.
- `net/discovery.rs`: `publish_devices` / `lookup_devices`.
- `store.rs`: `device_lists` and `devices` tables.
- `PROTO_VERSION = 3`.

**Risk:** the signature changes touch every content path. The unit tests and the old-peer e2e must stay green.

### Phase 2: linking and bootstrap

**Changes:**
- New `node/link.rs` (QR, code, rendezvous, SPAKE2, proofs, approval, `LinkAccept`, bootstrap streaming, restart).
- `Cargo.toml`: `spake2`.
- `net/nostr.rs`: `subscribe_tag`, `post_ephemeral`, routing by sub id.
- `net/discovery.rs`: LinkBeacon.
- `proto.rs`: `STREAM_SYNC`; `conn.rs`: dispatch for it.
- `node/mod.rs`: `NodeConfig.link_pending`, load `account.*` at start, skip publishing while pending, `is_fresh()`.
- `store.rs`: `import_batch`.
- `api.rs`: `link_*`, `devices`, `device_rename`, `me` fields.
- `lumora-cli/src/main.rs`: `--link-pending`, in-process restart.
- e2e scenarios 1–3.

**Risks:** PAKE dependency review; restart handling on the FFI side.

### Phase 3: fan-out and self-sync

**Changes:**
- `node/conn.rs`: `deliver` / `deliver_dev` / `send_now` / `connect_any`, StoreFor and mailbox mapping, reconnect sweep policy, dormant devices, sibling sync on connect.
- `node/olm.rs`: gating, SelfSync inner.
- New `node/sync.rs`: items, `sync_push`, apply, LWW, Have/Want/Items/Ack.
- Hooks in `chat.rs`, `social.rs`, `extras.rs`, `stickers.rs`, `api.rs`.
- `node/mod.rs`: account-level `is_online`, presence.
- `store.rs`: `sync_log`, `sync_peers`, `lww`, `conv_set_read_upto`, `outbox_purge_device`.
- e2e scenarios 6–8.

**Risks:** duplicate notifications; connection count; mobile battery.

### Phase 4: history transfer

**Changes:**
- `node/sync.rs` (or a new `node/history.rs`): HistoryRequest, cursor, window, group_log/group_keys, file state 6, progress events.
- `node/files.rs`: `on_file_request` allows siblings for any conversation; `accept_file` fetches state-6 files from the sibling.
- `store.rs`: `history_page`, transactional import.
- `api.rs`: `history_status`, `link_approve` options.
- e2e scenarios 4–5.

**Risks:** disk and time on phones; keep batches at most 256 KB and one transaction each.

### Phase 5: groups across devices

**Changes:**
- `node/groups.rs`: `publish`, `send_welcome`, `rotate_key` per device; key/welcome forwarding; gossip targets; typing and read; single-target join; `GroupRekeyRequest`.
- e2e scenario 9 plus `scale.py --devices 2`.

**Risk:** N × M key seals per rotation (fine at the 64-member "small" cutoff that `publish` already uses).

### Phase 6: revocation, wipe, promote

**Changes:**
- `node/devices.rs`: `revoke`, revoked handling (sessions, outbox, connections, rekey/request, self-wipe).
- `node/olm.rs`: `drop_sessions(dev)`.
- `keystore.rs` and `node/mod.rs`: `wipe_account_data`, `promote_with_phrase`.
- `api.rs`: `device_revoke`, `device_logout`, `device_promote`.
- e2e scenarios 10 and 14.

**Risks:** the window while peers still hold a stale list; documented limits for a lost primary.

### Phase 7: calls and remote targeting

**Changes:**
- `node/remote.rs`: invite all devices, first answer wins with `CallEnd` to the others, decline for the account, device-targeted `remote_connect`, own devices allowed.
- `api.rs`: `remote_connect` `device` argument, `contact_devices`.
- e2e scenarios 11–12.

### Phase 8: discovery and overhead polish

**Changes:**
- `connect_any` uses the DHT `lumora-devs` record.
- Device short-ID records with account and cert.
- Secondaries re-broadcast stored Nostr events.
- Lazy connections.
- Scale test and budget check.

### Phase 9: legacy bridge

**Changes:** `Ext Proxy` and primary countersigning in a new `node/bridge.rs`, hooked from `chat.rs` / `groups.rs` when targets have proto < 3; UI pending hint; e2e scenario 13 in full.

### Phase 10: app UI

This can run in parallel from Phase 2 against `mock_api`. Files as listed in §8, plus `flutter test` screenshots.

### Phase 11: documentation and optional hardening

- Docs: `docs/src/dev/architecture.md`, `security.md` (multi-device threat model, limits for a lost primary, revocation window), `api.md`, `adr.md`, `testing.md`.
- ADRs to record: root key on the primary; DevSig carried in the existing `sig` field; one `Ext` variant with named bodies; heads keyed by signer device.
- Optional hardening: Olm fallback keys; DeviceCert expiry with automatic renewal; "cold root" mode.

### Cross-cutting risks

1. Sending a variant to a peer that is not version 3 kills its reader. Gate everything through one helper, `Node::can_ext(&pc)`.
2. Any field added to an existing wire struct breaks old decoders. Add a CI test that compares the new encoder with frozen fixtures.
3. `self.me` versus `self.device` confusion. Audit every `== self.me` and `self.id.sign` (33 `self.id` uses, about 90 `self.me` uses) and tag each one as "account" or "device".
4. Group heads and rotations with several writers per account (fixed in Phase 1; covered by tests).
5. Privacy: friends see device names and count. Possible later setting: "ẩn tên thiết bị".
6. Resource growth: N copies per message (outbox, relay mailbox), more connections. Mitigated by dormant-device rules, `sync_log` only when there are 2 or more devices, the lazy-connection policy, and the per-device mailbox cap that already exists.
7. Clock skew in list versions. `max(prev + 1, hlc)` plus `Hlc::observe` keeps them sane.

---

### Critical files for implementation
- /home/vantrong/Downloads/p2p_all/core/crates/lumora-core/src/node/conn.rs
- /home/vantrong/Downloads/p2p_all/core/crates/lumora-core/src/node/mod.rs
- /home/vantrong/Downloads/p2p_all/core/crates/lumora-core/src/proto.rs
- /home/vantrong/Downloads/p2p_all/core/crates/lumora-core/src/node/groups.rs
- /home/vantrong/Downloads/p2p_all/core/crates/lumora-core/src/tls.rs

Also central: /home/vantrong/Downloads/p2p_all/core/crates/lumora-core/src/group.rs, /home/vantrong/Downloads/p2p_all/core/crates/lumora-core/src/node/chat.rs, /home/vantrong/Downloads/p2p_all/core/crates/lumora-core/src/node/olm.rs, /home/vantrong/Downloads/p2p_all/core/crates/lumora-core/src/store.rs, /home/vantrong/Downloads/p2p_all/core/crates/lumora-core/src/node/remote.rs, /home/vantrong/Downloads/p2p_all/core/crates/lumora-core/src/net/nostr.rs, /home/vantrong/Downloads/p2p_all/core/crates/lumora-core/src/net/discovery.rs, /home/vantrong/Downloads/p2p_all/core/crates/lumora-core/src/api.rs, /home/vantrong/Downloads/p2p_all/core/tests/e2e.py.

---

## 12. Progress (implementation log)

Phases 0–5 are implemented, plus remote-control authentication v2 (in the same protocol bump).
Status per phase, then what changed from the plan above and why.

### Phase 0: compatibility groundwork — done

- Already present before this work: the lenient control reader (`read_frame_lenient`, test
  `lenient_reader_skips_unknown_frames`), per-device protocol versions from `Hello` persisted in kv
  `peer.proto.<device>`, capability tokens in `Hello.app` (`+push1`).
- Added: `PeerMsg::Ext { kind, body }` (last variant; bodies are `to_vec_named`) with `proto::ext()` /
  `proto::ext_body()` and the `proto::ext::*` kind constants; `PROTO_VERSION = 3`, `PROTO_V3`;
  `STREAM_SYNC = 0x05` with `SyncBatch` frames (`write_sync_frame` / `read_sync_frame`, ≤ 1 MB).
- Gating: `Ext` is only ever written to a device whose `Hello` said ≥ 3 or that appears in a device
  list / presented a device certificate (`Node::dev_speaks_v3`); `send_now` / `send_now_dev` /
  `deliver_dev` drop it otherwise, so it never reaches an outbox for an old peer.
- `PeerConn.{account, own, proto}`, `Node.device`; transport checks use the device (`connect`, dialer,
  `handle_signal`, remote `err.self_control`).
- Store migrations (additive): `messages.device`, `messages.rev`, `convs.read_upto`, `convs.cleared_upto`,
  `convs.rev`, `contacts.rev`, tables `device_lists`, `devices`, `sync_log`, `sync_peers`, `lww`.
- Tests: frozen v1/v2 wire fixtures (`frozen_v1_fixtures_still_encode_and_decode`: Hello, Chat, Wrapped(Ack),
  GroupSync, Action byte-for-byte), `ext_roundtrips_and_old_readers_skip_it` (a decoder without the `Ext`
  variant skips the frame and reads the next one), `fuzz_ext_bodies_never_panic`, `sync_frames_roundtrip`.

### Phase 1: device identity, DeviceList, DevSig — done

- `devices.rs` (pure): `DeviceCert`, DevSig (170 bytes in the existing `sig` fields), `Signer`,
  `verify_by`, `signer_device`, `SignedDeviceList` (+ validation, tie-break), link helpers.
- TLS: a secondary's certificate carries its `DeviceCert` as SAN URI `lumora:devcert:v1:…`;
  `tls::remote_identity` returns (device, cert) — a cert is only accepted for exactly the TLS key.
  `Transport::start(id, devcert, cfg)`.
- `node/devices.rs`: `account_of`, `delivery_targets`, `siblings`, `is_revoked`, `verify_content`
  (verify + revocation + learn the cert), `ensure_own_list` (primary, version 1, never sent while
  single-device), `publish_own_list`, `DeviceSync` / `DeviceList` / `DeviceListRequest` handlers,
  `devices_json`, `contact_devices_json`, `device_rename`.
- All content signing goes through `Node.signer` (chat, actions, buttons, stories, invites, Bot Studio
  ownership, group ops/messages); all verification through `verify_content` / `verify_by`.
- Groups: `Signed::new(&Signer…)`, `group::create(&Signer…)` (gid bound to the account), log/heads keyed by
  the signing device, `i_rotate` = signing device is this device (owner-leave: primary only), `GroupSync`
  for peers < v3 only serves rows whose signer is a member account.
- Tests: `devices::tests` (6: cert/SAN, DevSig tampering/wrong cert/other account, 64-byte signatures,
  list validation incl. replay/duplicate/>8/active+revoked/tie-break, QR proof channel binding, SPAKE2
  wrong code, code parsing), `tls::tests::devcert_rides_in_the_san`,
  `group::tests::devsig_ops_fold_and_heads_are_per_device`.

### Phase 2: linking and bootstrap — done

- `node/link.rs`: `link_start` (QR `lumora://link/…` + 12-digit code, 10 min), `link_scan` (QR proof bound to
  the TLS exporter; code: LAN `LinkBeacon` "LMRL" + Nostr kind 21213 rendezvous on the first 6 digits, SPAKE2
  over all 12 digits + key confirmation; 3 failures rotate the code), `LinkInfo`, `link_approve` (cert + new
  signed list, history window), `LinkAccept` → kv `account.{id,cert,role}` → `link_state: restart`.
- `lumorad --link-pending`; lumorad restarts the node in-process on `restart` (fresh tokio runtime per node
  instance; stdin is read by one thread for the life of the process).
- Bootstrap: see "Changes from the plan" (runs right after the restart, on the sibling connection).
- e2e: link by QR; link by code over LAN with 3 wrong codes (rotation) — `multidevice_e2e.py`.

### Phase 3: fan-out and self-sync — done

- `deliver(account)` fans out to every active device (`deliver_dev` per device: Olm per device, outbox per
  device, mail sealed per device); `send_now(account)` reaches every connected device; `connect_any`.
- `StoreFor`/mailbox per device (friends and own devices may keep mail for each other).
- Reconnect sweep: own siblings + ≤ 3 devices per friend; dormant devices (30 days) skipped.
- `node/sync.rs` anti-entropy (`Have` / `Want` / `Items` / `Ack`) over the store's change log; merge rules in
  `store_sync.rs` (messages: status max, deleted sticky, mutable fields LWW by `rev`; conversations: flags LWW,
  `read_upto`/`cleared_upto` max; contacts: status/alias/verified LWW; settings whitelist LWW; group keys).
- e2e: friend → all 3 devices (one copy each, sender sees delivered); A1 → B appears on A0/A2; read state,
  pin, profile name; offline device catches up.

### Phase 4: history transfer — done

- `HistoryRequest` (state + window + cursor + batch size) → `STREAM_SYNC` batches ≤ 256 KB, one transaction
  each (`Store::sync_import_batch`), cursor `(conv, hlc, id)` → group log → file rows; cursor saved after every
  batch; a newer request from the same device supersedes a stale stream; progress `history_sync`.
- File rows arrive with state **7** ("kept on another of my devices"); `accept_file` fetches them from a
  connected sibling (own devices may fetch any local copy).
- e2e: window honoured (`history_since_ms`), file fetched from A0 (hash checked), transfer killed mid-way
  (`LUMORA_HIST_BATCH=10`) and resumed with no duplicates and nothing missing.

### Phase 5: groups across devices — done

- `publish` delivers to every device of every member including my siblings; `send_welcome` / `rotate_key`
  seal per device (`deliver_sealed`); accepted keys/welcomes from other accounts are forwarded to my siblings
  (covers senders with a stale list); gossip goes to connected member devices; typing/read to all devices.
- e2e: B gets a second device; A1 creates a group with B and C; every device of every member gets every
  message; removing C on A1 → exactly one rotation (epoch 1 everywhere), C can't read the next message.

### Remote control authentication v2 — done

- Host stores the fixed (unattended) password only as a verifier: `seed = Argon2id(pw, salt, 19 MiB, t=2,
  p=1)`, verifier = Ed25519 public key of the seed (kv `remote.fixed_v2`). v3 viewers get
  `Ext RemoteChallengeV2 {session, nonce, kdf?}` and answer `Ext RemoteAuthV2 {session, proof, sig}`;
  `sig` signs `nonce ‖ viewer device ‖ host device`. The temporary password keeps the v1 keyed proof.
- Peers below v3 still get `RemoteChallenge` v1: they can use the temporary password; a fixed password set
  by this version can't be checked for them (by design: no password-equivalent at rest). A legacy v1 key
  from an older install keeps working until the password is set again (`fixed_password_legacy` in
  `remote_status`), then it is deleted. Viewers refuse unreasonable KDF parameters (memory/time caps).
- Tests: `remote::v2_tests` (3), e2e "remote control v2" (v3 viewer logs in unattended; legacy viewer is
  denied with the fixed password and gets in with the temporary one).

### Test results (2026-11-05)

| Suite | Result |
|---|---|
| `cargo test -p lumora-core` | 90 passed (75 before + 15 new) |
| `cargo test --workspace` | 162 passed, 0 failed (lumora-core 97 with workspace features, push 40+1, relay 4+6, others) |
| `cargo clippy --workspace --features lumora-core/media --all-targets` | clean (no warnings) |
| `core/tests/e2e.py` | 30/30 |
| `core/tests/multidevice_e2e.py` | 13/13 (A0, A1, A2, A3, B0, B1, C + legacy L at the time; the legacy node was removed on 2026-11-06), several consecutive runs |
| `flutter analyze` / `flutter test` | no issues / 581 passed, 7 skipped |

### Changes from the plan (the plan was wrong or a better fit existed in the current code)

1. **File state 6 was already taken** ("removed locally, fetch again from the sender", files.rs). "Kept on
   another of my devices" is state **7**. Own uploads keep `direction = 0` with state 7, so once fetched the
   new device can serve them again.
2. **Bootstrap after the restart, not before.** The new device stores only the certificate and the signed
   list, restarts, and then asks the approving device for "state + history" on one resumable `STREAM_SYNC`
   (phase 1 = state, phase 2 = history). One code path, resumable for both, and the new device never
   imports account data under its stand-alone identity. Its stand-alone profile/settings are wiped at
   `LinkAccept` (`Store::reset_for_link`) so the account's values win.
3. **Self-sync without per-change mail.** Every mutation is logged by the store itself (no hooks in every
   API path); a sibling round starts whenever the log moved (1 s poll) or a sibling connects. Offline
   siblings catch up from any sibling on reconnect (and from mail friends/siblings keep for them).
   Plan's eager `sync_push` via mail is not needed for the tested cases; add it if a 2-device account
   where both devices are rarely online together turns out to need it.
4. **Sync items are stored rows, not signed `ChatMsg`s.** The database doesn't keep signatures, so rows
   can't be re-verified; they are only accepted from own devices over TLS authenticated by a
   root-signed device certificate (same trust as history transfer).
5. **Olm doesn't wrap `SelfSync`.** Between siblings it's TLS-only (online) or sealed to the device (mail).
6. **No `contacts.proto` column**: the existing kv `peer.proto.<device>` (set from `Hello`) already persists
   versions per device; the main device's knowledge is copied to new devices in the bootstrap.
7. **Remote-control proof binds devices**, not accounts (`proof(.., viewer_device, host_device)`); for
   single-device users the bytes are identical, so old viewers/hosts are unaffected.
8. **Nostr link rendezvous** uses short-lived extra subscriptions (`watch_link_beacons`) instead of routing
   by sub id inside `relay_loop` (less invasive; ephemeral events need a live listener either way).
9. **Linked devices don't talk to legacy friends** until the bridge (Phase 9): `deliver` skips them and
   direct sends fail with `err.peer_needs_update`; the main device keeps the conversation going and
   received messages reach the other devices by self-sync.
10. **A new sibling is seeded at the current log head on every existing device** (not only on the approver),
    otherwise other siblings would push pre-approval changes and defeat the history window.
11. API names: the plan's `link_*` commands are implemented; `device_link_start` / `device_link_accept` /
    `device_link_confirm` are aliases (start on the new device, scan + approve on the main device).

### Burst reliability fix (before Phase 6)

A friend sending hundreds of messages at once lost some of them for good. The previous guess (Olm
skipped-key limit) was only part of it. There were two root causes:

1. **The rate limit dropped messages after they were decrypted and acknowledged.** `handle_msg`
   checked the 20/s budget on the *inner* message. A `Wrapped(Olm(Chat))` frame passed the outer
   check (Olm wasn't counted as content), was marked as seen, and was decrypted (which consumed its
   ratchet key). The inner `Chat` then hit the limit and was dropped, but the outer `Wrapped` handler
   acknowledged it anyway. The sender deleted it from its outbox and it never came back. In the
   repro with 1,000 messages, 775 were lost.
2. **Ratchet steps were taken when a message was queued, not when it was sent.** The outbox stored
   the Olm ciphertext. When the control channel was full, `try_send` failed for some messages while
   later ones went out first. Re-sends (every 8 s, `outbox_for` capped at 200 or 500) and offline
   mail copies arrived out of ratchet order. vodozemac keeps only 40 skipped message keys and allows
   a gap of at most 2,000. Anything older failed to decrypt, and those failures were *also*
   acknowledged ("ack even on permanent errors").

Fix (all wire-compatible; no new message kinds):

- **Receiver.**
  - Duplicates are recognised before any budget is spent.
  - The budget is charged once, on the outer frame, with Olm counted as content.
  - A trusted sender (friend, own device) over budget is **slowed down, not dropped**: the
    per-connection reader waits, so QUIC flow control pushes back on the sender's queue.
  - Strangers are still dropped, unacknowledged.
  - Friend budget: 250 burst, then 40 messages/s.
- **Encrypt at write time.**
  - The outbox now keeps the plain `Wrapped` message.
  - The connection writer ratchet-encrypts each reliable message as it writes it
    (`Node::olm_for_wire`), so ratchet order is exactly stream order and every re-send uses the
    current chain.
  - Offline mail copies are encrypted when they are made, one ratchet step each.
- **Outbox pump.**
  - One pump per connection (`pump_outbox`) pages through the whole outbox with back-pressure
    (`ctl.send().await`), with no 200/500 cap.
  - It skips items already written to this connection and not yet acknowledged
    (`PeerConn.sent`), unless they have waited more than 5 minutes.
  - It runs when a peer connects, every 8 s, and after a new session.
- **Session repair.**
  - A message that can't be decrypted is *not* acknowledged and not marked as seen.
  - The receiver hands the sender a fresh one-time key unasked (`OlmKeys`; every version starts a
    new outbound session from it), at most once per 10 s per device.
  - The sender clears `sent` and pumps again, so everything unacknowledged is re-encrypted with the
    new session.
  - After 4 failed deliveries of the same message it is acknowledged anyway. This covers old
    senders, which re-send the same ciphertext.
  - Offline copies are only acknowledged after successful handling.

Measured (debug build, two nodes on the same machine, machine under load from other builds):

| Case | Before | After |
|---|---|---|
| 300-message burst, 1-1 | 206/300 within 90 s (94 lost) | 300/300 |
| 1,000-message burst, 1-1 | 225/1,000 within 120 s (775 lost) | 1,000/1,000 in about 20 s |
| 1,000 messages, receiver offline in the middle | 408/1,000 | 1,000/1,000; catch-up in 20–23 s |
| Group, 1,000 messages | 1,000/1,000 (envelopes are not rate-limited) | 1,000/1,000 |
| Receiver lost its ratchet sessions, 200 messages | — | 200/200 (session repaired automatically) |

In every "after" case the order matches the sender's (by HLC) and there are no duplicates. This is
a permanent scenario in `e2e.py`: "burst: 1,000 messages, receiver offline mid-burst, lost ratchet
session". It uses the debug-only command `debug_olm_drop`.

### Phase 6: revocation, wipe, promote — done

- `device_revoke {device, wipe_media}` (main device; `node/revoke.rs`):
  - A new signed list moves the device to `revoked` (`at` = the new list version).
  - Locally: ratchet sessions dropped; outbox, kept mail and sync cursors forgotten.
  - The device gets the list live (pushed to connected own devices) and as offline mail; the
    connection is closed with code 3 "revoked" after 3 s.
  - Group keys: the main device rotates every group where the account is admin/owner. Elsewhere it
    sends `Ext GROUP_REKEY_REQUEST {gid, list}` to one admin (the owner if it is an admin). Only that
    admin account's *main* device acts on it, at most once a minute per group, and only if a
    revocation in the attached (root-signed) list is newer than the current epoch's Rekey op.
- Every holder of a list with a revoked device forgets it the same way (`accept_device_list`).
- The revoked device (`self_revoke`):
  - triggered by the list, or by an own device closing the connection with code 3;
  - writes `device_reset.json`, emits `device_revoked {device, wipe, by_self, restart: true}`, and
    with `wipe` deletes the downloads the database points to;
  - `Node::start` sees the marker first and deletes keystore + database (+ `downloads/`), so the
    next start is a fresh install. `lumorad` restarts in-process (`Exit::Reset`), the app halts
    the core and goes to onboarding.
- `device_logout` (linked device): asks the main device to revoke it (`Ext DEVICE_REVOKE_REQUEST`,
  live, or as mail), then signs out. On the main device: `err.primary_logout`.
- `device_promote {phrase, passphrase?}` (linked device):
  - the phrase must give this account's key;
  - signs a list where the account key is this device (its name/kind) and its old device key is
    revoked;
  - drops `account.*` and `olm.*`, re-wraps the keystore with the account key **and the same
    database key**, and restarts (`link_state restart, reason promoted`);
  - after the restart it pushes the list to its siblings.
  - A previous main device that later sees a newer list of its own account that it didn't sign
    steps down (`self_revoke`). `DeviceSync` now asks a friend for that list when the friend holds a
    newer version of *my* account's list than I do.
- e2e: revoke with wipe (friends drop the device, it restarts fresh, group key rotated, new
  messages readable on A0/A1); plain member revokes → admin rotates once on request; linked device
  signs itself out; promote with the main device lost, then the old main device comes back and
  signs out.

### Phase 7: calls and remote targeting — done

- `call_start` rings every active device of every callee (never my own devices); `invited`
  holds devices.
- First `CallAnswer{accept}` from a device of account B: the caller sends `CallEnd` (every version
  understands it) to B's other ringing devices, 600 ms later. A decline is the account's answer;
  the call ends when nobody else is ringing.
- The answering device tells its siblings with `Ext CALL_ELSEWHERE {call_id, answered,
  device_name}`. They stop ringing with `call {state: ended, reason: answered_elsewhere |
  declined_elsewhere, device_name}` and add no missed-call line.
- `call.participants[]` gains `account` (`peer` stays the device); `from` is the account.
- `remote_connect {…, device?}`: an account with ≥ 2 remote-controllable devices needs `device`
  (`err.choose_device`, `detail` = JSON choices). A device's own short ID or key works as `target`.
- e2e: A0/A1 both ring; A1 answers → A0 "answered_elsewhere" within 5 s, B's participants = [A1];
  A0 declines → A1 stops, B's call ends. B → A without `device` → choice error; with `device` → A0.

### Phase 8: discovery and overhead — done

- DHT: the main device publishes `DhtDevices {version, [(device, caps)]}` under the account key
  (BEP44 salt `lumora-devs`, encrypted with a key derived from the account, ≤ 1000 bytes for 8
  devices; unit test). `connect_any` uses it only when no list is cached and the account key itself
  is unreachable, and keeps a result only if the TLS certificate names that account.
- Device short IDs: `devices` / `contact_devices` carry `short_id` (and `safety` = the device's
  security code).
  - `resolve_id` finds known devices by short ID.
  - Linked devices publish their own `lumora:sid:<device sid>` directory record with `account` +
    `cert` (older resolvers ignore both); a lookup that finds one learns the device → account
    mapping.
  - `add_contact` with a device's ID befriends its account.
- Linked devices keep the main device's latest signed directory/username events (kv
  `nostr.events`, synced) and re-broadcast them verbatim while the main device is offline.
- Lazy connections: the reconnect sweep dials a friend's main key always, its other devices only if
  seen (or added) in the last 7 days; anything else is dialed when something is queued for it.
- Budget: `scale.py --idle-devices 3` (results below).

### Phase 9: legacy bridge — done

- `deliver()` on a linked device, for a friend whose app predates multi-device, hands `Chat`,
  `Action` and group envelopes to the main device: `Ext PROXY {to, msg}`, reliable (outbox +
  mail), one queue slot per (item, friend).
- The main device (`node/bridge.rs`) accepts only from a current device of the account, checks that
  that device's DevSig covers the content, signs it again with the account key (same ids and HLC),
  and delivers it.
  - Group envelopes are opened with the epoch key, the op and inner message signatures replaced,
    and the envelope sealed again.
  - It also stores a bridged direct message itself, so the old friend's receipts find it.
- `err.peer_needs_update` is no longer raised. While the main device is offline, the message stays
  "sending".
- e2e: A1 → L arrives with author = account, A1 sees it delivered.

### Phase 10: app — done (see the app report)

- Linking direction changed for the app (user request): the **main device shows** the QR / code
  (`link_invite`), the **new device scans** it (`link_scan` with `link_pending`). The core supports
  both directions.
  - Same proofs: the QR secret bound to the TLS exporter, or SPAKE2 + key confirmation over the 12
    digits, with dialer and responder swapped.
  - Both sides send `LinkInfo` (the responder's tells the new device it was verified).
  - The main device emits `link_request`; one invitation links one device.
- Screens: My devices, link (QR + code), approval sheet with history choice, the onboarding entry
  "Tôi đã có tài khoản Lumora trên thiết bị khác", history progress (resumable), contact devices
  with security codes, "Đã trả lời trên thiết bị khác", remote device picker.
- `ffi_api.dart` restarts the core on `link_state: restart`; on `device_revoked` the app halts and
  the next start is clean.
- Camera QR scanning on phones is not wired yet (platform setup collides with other work): phones
  type or paste the code.

### Phase 11: docs — done

- `docs/src/user/devices.md` (VI/EN user guide).
- ADRs 8–15 in `adr.md`.
- `api.md` (Phase 6–9 commands/events).
- `security.md` (revocation window, lost main device, bridge).

### Bots in groups (fixes from the SDK tests)

- Privacy-mode bots hold no key. After every op, `publish` now also sends them the signed ops
  without the key (keyless `Welcome`), so they learn members added after them, and their own
  removal (they get a `group_removed` event).
- A welcome for a group we're already in now merges newly signed ops (each op's signature checked)
  and takes the current epoch key if we lack it and it matches its commitment (epoch 0: from an
  admin). This makes `read_all` switches and remove + re-add work.
- A privacy-mode bot leaves by sending its signed `Leave` op inside a keyless welcome.
- `join_public` refuses bots (`err.bot_join_public`).
- `group_info.members[]` shows names of non-contacts (from the name they introduce themselves with),
  plus `short_id` and `friend`.
- e2e scenario "bots in groups".

### Test results after Phases 6–11 (2026-11-05)

| Suite | Result |
|---|---|
| `cargo test --workspace` | lumora-core 101 passed; push 4, bridge 6, relay 5 + 9, video_fx 1; lumora-media 53 passed, 4 failed. The 4 failures were H.264 tests during a short-lived intermediate codec design (since replaced by bundled VP8/VP9 + OS H.264, see [Video codecs](video-codecs.md); all media tests pass now). They are not related to this work. |
| `cargo clippy --workspace --features lumora-core/media --all-targets` | clean, except one `identity_op` warning in `lumora-media/src/camera_in.rs` test code, which another agent owns |
| `core/tests/e2e.py` | 32/32, including the burst and bot scenarios |
| `core/tests/multidevice_e2e.py` | 20/20 (13 before + invitation linking, short IDs, calls, revocation ×2, sign-out, promote) |
| `soak.py --msgs 5000 --file-mb 300` | 13/13 |
| `scale.py --n 24 --per 5` | PASS: 2,880 deliveries in 4.5 s; RSS 35 MB average (37 max); outbox 0 |
| `scale.py --idle-devices 3` (60 s idle) | PASS. One device: 0.12 % CPU, 28 MB. Three devices: main 0.17 %, 30 MB; the others 0.22 %, 30–31 MB |
| `flutter analyze` / `flutter test` | no issues / 685 passed, 7 skipped, 1 timing-flaky test on a loaded machine (it passes when run alone) |

### Left / limits

- ~~Camera QR scanning in the app~~ done (2026-11-06): `app/lib/ui/devices/qr_scan.dart`
  (`mobile_scanner`, unbundled ML Kit on Android / Vision on iOS); desktop keeps paste / 12-digit code.
- ~~`device_promote` with a passphrase~~ done: the app asks for it (secure input) and passes it.
- Also done: the "Sent through your main device" hint (`bridged` on contacts), and the
  `sys.contact_device_added` line when a friend links a new device (their security code changed).
- The legacy-build interop steps were removed from `multidevice_e2e.py` (no old versions in use);
  the bridge code stays.
- A revoked device that is offline learns it only from mail or its siblings; until then it can
  still read what senders with an older list send it.
- Old-app friends' group sync (`GroupSync`) still only serves account-signed rows; bridged copies
  cover new messages.

### Recovery from friends after a phrase restore (v1.0.8, `node/recovery.rs`)

An account restored from its 24 words into an empty folder (`recover.since`) asks every v3
peer that connects, for 30 days or until "Stop asking friends", for help:

- `Ext RECOVER_HELLO` `{to, ts, sig}` — signed by the account key over (tag, account, peer, ts);
  ±10 min. The friend answers only if its OWN store has the account as a friend (not blocked)
  and "Help friends restore their history" (`privacy.help_restore`, synced kv, default on) is on.
- `RECOVER_OFFER` `{name, messages, groups, since, proof}` — `proof` is a message the account
  signed in that 1-1 chat (the app shows "Verified"). Kept only as an answer to our hello;
  nothing is stored before the user accepts in the review list (`recovery_offers` / `_accept` /
  `_decline` / `_dismiss`, event `recovery`).
- `RECOVER_ACCEPT` (signed like the hello) → `RECOVER_BATCH` `{items, done}`: only that friend's
  1-1 chat, last 183 days, text-like kinds, ≤ 200 items / 256 KB per frame, ≤ 5,000 messages /
  8 MB, 3 transfers per friend per day. Then a group welcome per shared group; the group's own
  sync brings its history. An epoch-0 group key from a plain member is accepted when it opens a
  held envelope someone else signed (the creator may be the one restoring).
- Tombstones: rows with `deleted=1`, a `expires` timer, or cleared/purged are never served. The
  friend keeps the signed wire copy of received messages in `msg_wire`; SQLite triggers drop it
  when the message is deleted, edited, given a timer or removed. Own messages without a wire
  copy are taken on the friend's word (the authenticated connection), see "Left / limits".
- IP privacy unchanged: the friend reaches the restored device the usual ways (LAN, its public
  inbox if findable by ID, or the user re-adding the friend by ID); accepting an offer makes them
  friends again, which is when addresses may be revealed.
- Tests: `core/tests/recovery_e2e.py` (5 steps), unit tests in `node/recovery.rs`,
  `app/test/friend_recovery_test.dart`.
