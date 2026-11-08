//! Mail that doesn't fit one signal, and files carried by mail.
//!
//! When two devices can't connect (both behind symmetric NATs — most mobile networks — and
//! no friend can relay), everything between them goes as sealed signaling mail (Nostr live
//! mail, relay mailboxes, a friend's peer relay). One signal carries ≤ 12 KB, so:
//!
//! * **Big mail** (a photo message with its preview, a sticker…) is cut into pieces
//!   (`Ext MAIL_PART`, each its own sealed signal) and put back together by the recipient,
//!   which then opens it like any other mail. Before this, anything over 12 KB waited for a
//!   connection that never came — the photo message itself never arrived.
//! * **Files up to [`MAX_MAIL_FILE`]** (photos, voice messages, documents) are asked for by
//!   mail (`Ext FILE_MAIL_REQ` with the chunks still missing) and sent back chunk by chunk
//!   (`Ext FILE_MAIL_CHUNK`, paced), written at their place in the `.part` file and checked
//!   against the offer's hash like a streamed download. Lost chunks are asked for again.
//!   Bigger files wait for a direct path (and resume from where they stopped).
//!
//! Only mail is used: no server of ours, nothing new learns who talks to whom; every piece
//! is end-to-end sealed to the recipient device exactly like a text message.

use super::*;
use crate::proto::ext;
use serde_bytes::ByteBuf;
use std::collections::BTreeSet;

/// Bytes of the sealed mail per piece (a piece's own signal stays ≤ `NOSTR_MAIL_MAX`).
const PART_BYTES: usize = 9 * 1024;
/// Biggest mail sent in pieces (a chat message is ≤ 160 KB).
pub(super) const MAX_PARTED_MAIL: usize = 256 * 1024;
/// File bytes per chunk.
pub(super) const FILE_CHUNK: usize = 8 * 1024;
/// Biggest file carried by mail (signaling is slow: ~50 KB/s).
pub(crate) const MAX_MAIL_FILE: u64 = 8 * 1024 * 1024;
/// Pieces / chunks sent per second (public signaling relays limit bursts).
const PER_SECOND: u64 = 12;
/// Unfinished pieced mail kept per sender / for this long.
const PARTS_PER_SENDER: usize = 8;
const PARTS_TTL: Duration = Duration::from_secs(600);
/// A download by mail with nothing new for this long asks again for what is missing...
const RX_STALL: Duration = Duration::from_secs(12);
/// ...and gives up (paused: resumed by a connection or the user) after this long.
const RX_GIVE_UP: Duration = Duration::from_secs(15 * 60);

#[derive(Serialize, Deserialize)]
struct Part {
    id: [u8; 16],
    idx: u32,
    total: u32,
    data: ByteBuf,
}

#[derive(Serialize, Deserialize)]
struct FileReq {
    file_id: [u8; 16],
    /// Chunk numbers still missing (empty = all of them).
    chunks: Vec<u32>,
}

#[derive(Serialize, Deserialize)]
struct FileChunk {
    file_id: [u8; 16],
    idx: u32,
    total: u32,
    data: ByteBuf,
}

struct PartBuf {
    total: u32,
    got: HashMap<u32, Vec<u8>>,
    at: Instant,
}

struct Rx {
    /// Chunks received.
    got: BTreeSet<u32>,
    total: u32,
    started: Instant,
    last: Instant,
}

#[derive(Default)]
pub(crate) struct State {
    parts: Mutex<HashMap<(PeerId, [u8; 16]), PartBuf>>,
    /// Downloads by mail, by the sender's (wire) file id.
    rx: Mutex<HashMap<[u8; 16], Rx>>,
    /// Files being sent by mail: (file, device).
    tx: Mutex<std::collections::HashSet<([u8; 16], PeerId)>>,
}

fn chunks_of(size: u64) -> u32 {
    size.div_ceil(FILE_CHUNK as u64).max(1) as u32
}

impl Node {
    // ------------------------------------------------------------ big mail in pieces

    /// `sealed` (a sealed mail for `to`) as signals of ≤ 12 KB each.
    pub(super) fn mail_pieces(&self, to: &PeerId, sealed: &[u8]) -> Vec<Vec<u8>> {
        if sealed.len() > MAX_PARTED_MAIL {
            return vec![];
        }
        let id: [u8; 16] = crate::crypto::random_bytes();
        let pieces: Vec<&[u8]> = sealed.chunks(PART_BYTES).collect();
        let total = pieces.len() as u32;
        pieces
            .into_iter()
            .enumerate()
            .filter_map(|(i, d)| {
                let m = proto::ext(ext::MAIL_PART, &Part { id, idx: i as u32, total, data: ByteBuf::from(d.to_vec()) });
                let inner = seal_to(&self.id, to, &rmp_serde::to_vec(&m).ok()?).ok()?;
                seal_to(&self.id, to, &rmp_serde::to_vec(&Signal::Mail { payload: inner }).ok()?).ok()
            })
            .collect()
    }

    /// Sends a big sealed mail in pieces, paced (Nostr live mail and the other signal paths).
    pub(super) async fn send_mail_pieces(self: &Arc<Self>, to: PeerId, sealed: Vec<u8>) {
        for env in self.mail_pieces(&to, &sealed) {
            self.net.send_signal(&to, env, &[]).await;
            tokio::time::sleep(Duration::from_millis(1000 / PER_SECOND)).await;
        }
    }

    /// One piece of a big mail from device `dev`: kept until all are here, then the whole
    /// mail is opened as if it had come in one signal.
    pub(super) async fn on_mail_part(self: &Arc<Self>, dev: PeerId, body: &[u8]) -> Result<()> {
        let p: Part = proto::ext_body(body)?;
        anyhow::ensure!(p.total > 0 && p.idx < p.total && p.total as usize * PART_BYTES <= MAX_PARTED_MAIL + PART_BYTES, "bad mail piece");
        anyhow::ensure!(p.data.len() <= PART_BYTES, "mail piece too big");
        let whole = {
            let mut m = self.fmail.parts.lock();
            m.retain(|_, b| b.at.elapsed() < PARTS_TTL);
            if !m.contains_key(&(dev, p.id)) && m.keys().filter(|(d, _)| *d == dev).count() >= PARTS_PER_SENDER {
                return Ok(()); // a sender can't make us hold more than a few unfinished mails
            }
            let b = m.entry((dev, p.id)).or_insert_with(|| PartBuf { total: p.total, got: HashMap::new(), at: Instant::now() });
            if b.total != p.total {
                return Ok(());
            }
            b.got.insert(p.idx, p.data.into_vec());
            if b.got.len() as u32 == b.total {
                let b = m.remove(&(dev, p.id)).unwrap();
                Some((0..b.total).filter_map(|i| b.got.get(&i).cloned()).flatten().collect::<Vec<u8>>())
            } else {
                None
            }
        };
        if let Some(sealed) = whole {
            Box::pin(self.on_mail(&sealed)).await?;
        }
        Ok(())
    }

    // ------------------------------------------------------------ files by mail

    /// Receiver: a download just started (`accept_file`). If the sender doesn't start
    /// streaming it over a connection soon (none can be made), ask for it by mail, and
    /// keep asking for what is missing until it is complete.
    pub(super) fn file_mail_watch(self: &Arc<Self>, local: [u8; 16]) {
        let Some(row) = self.store.file_get(&local) else { return };
        if row.direction != 1 || row.size as u64 > MAX_MAIL_FILE || row.size <= 0 {
            return;
        }
        let Ok(sender) = PeerId::from_str_any(&row.peer) else { return };
        let wire = self.store.file_wire_id(&local).unwrap_or(local);
        let me = self.clone();
        tokio::spawn(async move {
            // a connection streams it faster: give it a few seconds first
            tokio::time::sleep(Duration::from_secs(if me.peers_of(&sender).is_empty() { 2 } else { 8 })).await;
            loop {
                let Some(row) = me.store.file_get(&local) else { return };
                if row.state != 1 {
                    me.fmail.rx.lock().remove(&wire);
                    return;
                }
                let streaming = me.files.active.lock().contains_key(&local);
                let (ask, give_up) = {
                    let mut rx = me.fmail.rx.lock();
                    match rx.get(&wire) {
                        None if streaming => (None, false),
                        None => {
                            let total = chunks_of(row.size as u64);
                            rx.insert(wire, Rx { got: BTreeSet::new(), total, started: Instant::now(), last: Instant::now() });
                            (Some(vec![]), false)
                        }
                        Some(r) if r.last.elapsed() >= RX_STALL => {
                            let missing: Vec<u32> = (0..r.total).filter(|i| !r.got.contains(i)).take(2048).collect();
                            (Some(missing), r.started.elapsed() > RX_GIVE_UP)
                        }
                        Some(_) => (None, false),
                    }
                };
                if give_up {
                    tracing::info!("file {} by mail: giving up for now (resumes with a connection)", hex::encode(local));
                    me.fmail.rx.lock().remove(&wire);
                    let _ = me.store.file_update(&local, 5, row.progress);
                    me.emit_file(&local);
                    return;
                }
                if let Some(chunks) = ask {
                    if let Some(r) = me.fmail.rx.lock().get_mut(&wire) {
                        r.last = Instant::now();
                    }
                    let m = proto::ext(ext::FILE_MAIL_REQ, &FileReq { file_id: wire, chunks });
                    // every device of the sender: only the one holding the file answers
                    let mut devs: Vec<PeerId> = me.store.devices_of(&sender).into_iter().map(|d| d.device).collect();
                    if !devs.contains(&sender) {
                        devs.push(sender);
                    }
                    for d in devs {
                        me.send_sealed_signal(&d, &m).await;
                    }
                }
                tokio::time::sleep(Duration::from_secs(4)).await;
            }
        });
    }

    /// Sender: device `dev` (of account `from`) asks for one of my files by mail.
    pub(super) async fn on_file_mail_req(self: &Arc<Self>, dev: PeerId, from: PeerId, body: &[u8]) -> Result<()> {
        let r: FileReq = proto::ext_body(body)?;
        let Some(row) = self.store.file_get(&r.file_id) else { return Ok(()) }; // not mine / another device's
        anyhow::ensure!(row.direction == 0 && row.state != 7 && !row.path.is_empty(), "not our file");
        anyhow::ensure!(self.peer_may_fetch(&row, &from), "requester not allowed");
        anyhow::ensure!(row.size > 0 && row.size as u64 <= MAX_MAIL_FILE, "too big for mail");
        let key = (r.file_id, dev);
        if !self.fmail.tx.lock().insert(key) {
            return Ok(()); // already sending to it (it asks again only when it stalls)
        }
        let total = chunks_of(row.size as u64);
        let chunks: Vec<u32> = if r.chunks.is_empty() { (0..total).collect() } else { r.chunks.into_iter().filter(|i| *i < total).take(4096).collect() };
        tracing::info!("file {} by mail to {dev:?}: {} chunks", hex::encode(r.file_id), chunks.len());
        let me = self.clone();
        tokio::spawn(async move {
            let res: Result<()> = async {
                use tokio::io::{AsyncReadExt, AsyncSeekExt};
                let mut f = tokio::fs::File::open(&row.path).await?;
                let mut buf = vec![0u8; FILE_CHUNK];
                for idx in chunks {
                    f.seek(std::io::SeekFrom::Start(idx as u64 * FILE_CHUNK as u64)).await?;
                    let mut n = 0;
                    while n < FILE_CHUNK {
                        let k = f.read(&mut buf[n..]).await?;
                        if k == 0 {
                            break;
                        }
                        n += k;
                    }
                    let m = proto::ext(ext::FILE_MAIL_CHUNK, &FileChunk { file_id: r.file_id, idx, total, data: ByteBuf::from(buf[..n].to_vec()) });
                    me.send_sealed_signal(&dev, &m).await;
                    tokio::time::sleep(Duration::from_millis(1000 / PER_SECOND)).await;
                }
                Ok(())
            }
            .await;
            if let Err(e) = res {
                tracing::warn!("file by mail to {dev:?}: {e:#}");
            }
            me.fmail.tx.lock().remove(&key);
        });
        Ok(())
    }

    /// Receiver: one chunk of a file asked for by mail.
    pub(super) async fn on_file_mail_chunk(self: &Arc<Self>, dev: PeerId, from: PeerId, body: &[u8]) -> Result<()> {
        let c: FileChunk = proto::ext_body(body)?;
        let Some(row) = self.file_row_for(&from, &c.file_id) else { return Ok(()) };
        if row.state != 1 || row.direction != 1 {
            return Ok(()); // done (perhaps streamed meanwhile), paused or cancelled
        }
        let total = chunks_of(row.size as u64);
        let last_len = row.size as u64 - (total as u64 - 1) * FILE_CHUNK as u64;
        let want = if c.idx + 1 == total { last_len as usize } else { FILE_CHUNK };
        anyhow::ensure!(c.total == total && c.idx < total && c.data.len() == want, "bad file chunk");
        let local = hex::decode(&row.id).ok().and_then(|v| <[u8; 16]>::try_from(v.as_slice()).ok()).ok_or_else(|| anyhow!("bad id"))?;
        // the .part file, written at the chunk's place
        let part = if row.path.is_empty() || !row.path.ends_with(".lumora-part") {
            self.downloads_dir().join(format!(".{}.lumora-part", row.id))
        } else {
            std::path::PathBuf::from(&row.path)
        };
        {
            use std::io::{Seek, Write};
            if let Some(d) = part.parent() {
                std::fs::create_dir_all(d)?;
            }
            let mut f = std::fs::OpenOptions::new().create(true).write(true).truncate(false).open(&part)?;
            f.seek(std::io::SeekFrom::Start(c.idx as u64 * FILE_CHUNK as u64))?;
            f.write_all(&c.data)?;
        }
        let (count, complete) = {
            let mut rx = self.fmail.rx.lock();
            let r = rx.entry(c.file_id).or_insert_with(|| Rx { got: BTreeSet::new(), total, started: Instant::now(), last: Instant::now() });
            r.got.insert(c.idx);
            r.last = Instant::now();
            (r.got.len() as u32, r.got.len() as u32 == r.total)
        };
        let got_bytes = if complete { row.size } else { (count as i64 * FILE_CHUNK as i64).min(row.size) };
        let mut r2 = row.clone();
        r2.path = part.to_string_lossy().to_string();
        r2.progress = got_bytes;
        self.store.file_put(&r2)?;
        if !complete {
            if count % 8 == 0 {
                self.emit_file(&local);
            }
            return Ok(());
        }
        self.fmail.rx.lock().remove(&c.file_id);
        let part2 = part.clone();
        let hash = tokio::task::spawn_blocking(move || super::files::hash_file(&part2)).await??;
        let ok = hex::encode(hash) == row.hash;
        let mut r3 = r2.clone();
        if ok {
            let dir = part.parent().map(|p| p.to_path_buf()).unwrap_or_else(|| self.downloads_dir());
            let (p2, name) = (part.clone(), row.name.clone());
            let final_path = tokio::task::spawn_blocking(move || super::files::place_final(&p2, &dir, &name)).await??;
            r3.path = final_path.to_string_lossy().to_string();
            r3.state = 2;
            r3.progress = row.size;
            tracing::info!("file {} received by mail ({} chunks)", row.id, total);
        } else {
            let _ = std::fs::remove_file(&part);
            r3.path = String::new();
            r3.state = 3;
            r3.progress = 0;
        }
        self.store.file_put(&r3)?;
        let id: [u8; 16] = crate::crypto::random_bytes();
        self.deliver_dev(dev, id, PeerMsg::FileDone { file_id: c.file_id, ok }, false).await;
        self.emit_file(&local);
        Ok(())
    }
}
