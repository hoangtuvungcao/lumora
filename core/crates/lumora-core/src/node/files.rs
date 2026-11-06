//! File transfer: unlimited size, streaming (constant memory), resumable, BLAKE3-verified.

use super::*;
use serde::{Deserialize, Serialize};
use crate::file_preview::{FilePreview, MAX_IMG as FP_MAX_IMG};
use crate::proto::Body;
use crate::store::FileRow;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use tokio::io::{AsyncSeekExt, AsyncWriteExt};

const CHUNK: usize = 256 * 1024;

#[derive(Default)]
pub struct Transfers {
    active: Mutex<HashMap<[u8; 16], Arc<Active>>>,
    /// Outgoing streams, one per (file, requester): in a group several members fetch the
    /// same file, and one slow/malicious member must not block (or cancel) the others.
    sending: Mutex<HashMap<SendKey, Arc<Active>>>,
}

/// (file id, requester)
type SendKey = ([u8; 16], PeerId);

impl Transfers {
    fn sending_for(&self, file_id: &[u8; 16]) -> Vec<Arc<Active>> {
        self.sending.lock().iter().filter(|((f, _), _)| f == file_id).map(|(_, a)| a.clone()).collect()
    }
}

pub struct Active {
    cancel: AtomicBool,
    bytes: AtomicU64,
    rate: Mutex<RateMeter>,
}

impl Active {
    fn new(offset: u64) -> Self {
        Active { cancel: AtomicBool::new(false), bytes: AtomicU64::new(offset), rate: Mutex::new(RateMeter::new(offset)) }
    }

    /// Smoothed transfer speed (bytes/s).
    fn speed_bps(&self) -> u64 {
        self.rate.lock().sample(self.bytes.load(Ordering::Relaxed), Instant::now())
    }
}

/// Exponentially weighted transfer rate with a ~2 s time constant; correct for any
/// sampling interval (each sample is weighted by 1 − e^(−Δt/τ)).
pub(crate) struct RateMeter {
    last_t: Instant,
    last_bytes: u64,
    ewma: Option<f64>,
}

impl RateMeter {
    const TAU_S: f64 = 2.0;

    fn new(bytes: u64) -> Self {
        RateMeter { last_t: Instant::now(), last_bytes: bytes, ewma: None }
    }

    fn sample(&mut self, bytes: u64, now: Instant) -> u64 {
        let dt = now.saturating_duration_since(self.last_t).as_secs_f64();
        if dt >= 0.2 {
            let inst = bytes.saturating_sub(self.last_bytes) as f64 / dt;
            let a = 1.0 - (-dt / Self::TAU_S).exp();
            self.ewma = Some(match self.ewma {
                Some(e) => e + a * (inst - e),
                None => inst,
            });
            self.last_t = now;
            self.last_bytes = bytes;
        }
        self.ewma.unwrap_or(0.0).max(0.0) as u64
    }
}

/// Invisible / direction-changing characters: "invoice\u{202E}fdp.exe" would be shown as
/// "invoiceexe.pdf" (Unicode RTL-override trick), zero-width ones hide parts of a name.
fn is_hidden_char(c: char) -> bool {
    matches!(c, '\u{00AD}' | '\u{061C}' | '\u{180E}' | '\u{200B}'..='\u{200F}' | '\u{202A}'..='\u{202E}' | '\u{2060}'..='\u{2064}' | '\u{2066}'..='\u{2069}' | '\u{206A}'..='\u{206F}' | '\u{FEFF}' | '\u{FFF9}'..='\u{FFFB}')
}

/// Windows device names (`CON`, `NUL.txt`, `COM1.jpg`…) open a device instead of a file.
fn is_windows_device(name: &str) -> bool {
    let stem = name.split('.').next().unwrap_or("").trim_end_matches(' ').to_ascii_uppercase();
    matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$" | "CLOCK$")
        || ((stem.starts_with("COM") || stem.starts_with("LPT"))
            && stem.chars().count() == 4
            && stem.chars().last().map(|c| c.is_ascii_digit() || "¹²³".contains(c)).unwrap_or(false))
}

/// File name from a peer → a single, harmless path component: no directories (`../`,
/// `C:\`, UNC), no control/invisible/bidi characters, no Windows device names, no
/// trailing dots/spaces, at most 200 bytes (extension kept).
fn sanitize(name: &str) -> String {
    let base = name.rsplit(['/', '\\']).next().unwrap_or("file");
    let s: String =
        base.chars().filter(|c| !c.is_control() && !is_hidden_char(*c) && !matches!(c, ':' | '*' | '?' | '"' | '<' | '>' | '|')).collect();
    let mut s = s.trim_matches(|c| c == '.' || c == ' ').to_string();
    const MAX_BYTES: usize = 200;
    if s.len() > MAX_BYTES {
        let ext = match s.rfind('.') {
            Some(i) if i > 0 && s.len() - i <= 16 => s[i..].to_string(),
            _ => String::new(),
        };
        let mut stem: String = String::new();
        for c in s[..s.len() - ext.len()].chars() {
            if stem.len() + c.len_utf8() + ext.len() > MAX_BYTES {
                break;
            }
            stem.push(c);
        }
        s = format!("{}{ext}", stem.trim_end_matches(['.', ' ']));
    }
    if s.is_empty() {
        return "file".into();
    }
    if is_windows_device(&s) {
        s.insert(0, '_');
    }
    s
}

/// Move a verified download to `dir/name` (or "name (1)"…) without ever replacing an
/// existing file: an exists()-then-rename could overwrite a file created meanwhile (two
/// downloads with the same name, or a file/symlink planted in the folder).
fn place_final(part: &std::path::Path, dir: &std::path::Path, name: &str) -> std::io::Result<PathBuf> {
    let (stem, ext) = match name.rfind('.') {
        Some(i) if i > 0 => (&name[..i], &name[i..]),
        _ => (name, ""),
    };
    for i in 0..10_000u32 {
        let cand = match i {
            0 => dir.join(name),
            9_999 => dir.join(format!("{stem}-{}{ext}", rand::random::<u32>())),
            _ => dir.join(format!("{stem} ({i}){ext}")),
        };
        match std::fs::hard_link(part, &cand) {
            Ok(()) => {
                let _ = std::fs::remove_file(part);
                return Ok(cand);
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(_) => {
                // no hard links here (FAT/exFAT cards, some Android storage): plain rename
                if std::fs::symlink_metadata(&cand).is_ok() {
                    continue;
                }
                std::fs::rename(part, &cand)?;
                return Ok(cand);
            }
        }
    }
    Err(std::io::Error::other("no free file name"))
}

/// The resume offset in a file stream header comes from the sender: it must not point
/// past the declared size or past what we already have (no sparse holes, no truncation
/// tricks, no huge `set_len`).
fn check_stream_offset(offset: u64, size: u64, have: u64) -> Result<()> {
    anyhow::ensure!(offset <= size && offset <= have, "bad resume offset {offset} (have {have}, size {size})");
    Ok(())
}

fn hash_file(path: &std::path::Path) -> Result<[u8; 32]> {
    let mut h = blake3::Hasher::new();
    let f = std::fs::File::open(path)?;
    h.update_reader(std::io::BufReader::with_capacity(1 << 20, f))?;
    Ok(*h.finalize().as_bytes())
}

/// 320 px JPEG preview, ≤ ~20 KB.
/// Decoder limits for pictures we didn't make ourselves (forwarding a received photo
/// decodes a peer's file): a tiny PNG/GIF can declare 30 000 × 30 000 px.
fn thumb_limits() -> image::Limits {
    let mut l = image::Limits::default();
    l.max_image_width = Some(16_384);
    l.max_image_height = Some(16_384);
    l.max_alloc = Some(192 << 20);
    l
}

/// Decode a picture upright: phone cameras store portrait shots sideways plus an EXIF
/// orientation tag, which a plain decode ignores.
pub(super) fn decode_upright(path: &std::path::Path) -> anyhow::Result<image::DynamicImage> {
    use image::ImageDecoder;
    let mut r = image::ImageReader::open(path)?.with_guessed_format()?;
    r.limits(thumb_limits());
    let mut dec = r.into_decoder()?;
    let orientation = dec.orientation().unwrap_or(image::metadata::Orientation::NoTransforms);
    let mut img = image::DynamicImage::from_decoder(dec)?;
    img.apply_orientation(orientation);
    Ok(img)
}

fn make_thumb(path: &std::path::Path) -> Option<(Vec<u8>, u32, u32)> {
    let img = decode_upright(path).ok()?;
    let (w, h) = (img.width(), img.height());
    let t = img.thumbnail(320, 320).to_rgb8();
    let mut out = std::io::Cursor::new(Vec::new());
    let mut enc = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, 60);
    enc.encode_image(&t).ok()?;
    let b = out.into_inner();
    if b.len() > 48 * 1024 {
        return None;
    }
    Some((b, w, h))
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StoragePolicy {
    /// Max bytes of downloaded media kept by Lumora (0 = unlimited).
    pub max_cache: u64,
    /// Delete downloaded media not opened for this many days (0 = never).
    pub media_days: u64,
    /// Auto-download limit in direct chats (bytes).
    pub auto_direct: u64,
    /// Auto-download limit in groups (bytes; thumbnails always shown).
    pub auto_group: u64,
    /// Default history window for communities, days (0 = forever).
    pub community_days: u64,
}

impl Default for StoragePolicy {
    fn default() -> Self {
        StoragePolicy { max_cache: 5 << 30, media_days: 0, auto_direct: 25 << 20, auto_group: 2 << 20, community_days: 30 }
    }
}

/// App-supplied previews for [`Node::send_file_with`] (all optional).
#[derive(Clone, Debug, Default)]
pub struct FileExtras {
    /// JPEG/PNG/WebP ≤ 64 KB: video poster frame or the first page of a PDF.
    pub thumb: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub preview: Option<FilePreview>,
}

impl FileExtras {
    /// From API arguments `{thumb_b64|thumb, width, height, preview:{kind,text,pages,lines}}`.
    pub fn from_args(r: &Value) -> Self {
        let thumb = ["thumb_b64", "thumb"]
            .iter()
            .find_map(|k| r.get(*k).and_then(|x| x.as_str()))
            .map(|t| t.split_once(',').map(|(_, b)| b).unwrap_or(t))
            .and_then(|t| data_encoding::BASE64.decode(t.trim().as_bytes()).ok())
            .unwrap_or_default();
        let n = |k: &str| r.get(k).and_then(|x| x.as_u64()).unwrap_or(0).min(65_535) as u32;
        let preview = r.get("preview").filter(|v| v.is_object()).and_then(|v| FilePreview::from_json(v, vec![]));
        FileExtras { thumb, width: n("width"), height: n("height"), preview }
    }

    /// Re-use the preview of a stored file message (forwarding: the core can't re-render a PDF).
    pub fn from_body(body: &Value) -> Self {
        let mut e = Self::from_args(body);
        if let Some(p) = e.preview.as_mut() {
            p.img = std::mem::take(&mut e.thumb);
        }
        e
    }
}

pub(crate) fn mime_of(name: &str) -> &'static str {
    let ext = name.rsplit('.').next().unwrap_or("").to_lowercase();
    match ext.as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "mp4" => "video/mp4",
        "mov" => "video/quicktime",
        "webm" => "video/webm",
        "mkv" => "video/x-matroska",
        "heic" => "image/heic",
        "svg" => "image/svg+xml",
        "doc" | "docx" => "application/msword",
        "xls" | "xlsx" => "application/vnd.ms-excel",
        "ppt" | "pptx" => "application/vnd.ms-powerpoint",
        "rar" => "application/x-rar-compressed",
        "7z" => "application/x-7z-compressed",
        "apk" => "application/vnd.android.package-archive",
        "mp3" => "audio/mpeg",
        "ogg" | "opus" => "audio/ogg",
        "pdf" => "application/pdf",
        "zip" => "application/zip",
        "txt" => "text/plain",
        _ => "application/octet-stream",
    }
}

impl Node {
    pub fn downloads_dir(&self) -> PathBuf {
        if let Some(d) = self.store.kv_get("files.dir").and_then(|v| String::from_utf8(v).ok()) {
            return PathBuf::from(d);
        }
        self.cfg
            .downloads_dir
            .clone()
            .or_else(|| dirs::download_dir().map(|d| d.join("Lumora")))
            .unwrap_or_else(|| self.cfg.data_dir.join("downloads"))
    }

    fn file_json(&self, f: &FileRow) -> Value {
        let mut v = serde_json::to_value(f).unwrap_or(Value::Null);
        if let Ok(id) = hex::decode(&f.id) {
            if let Ok(arr) = <[u8; 16]>::try_from(id.as_slice()) {
                let a = self.files.active.lock().get(&arr).cloned().or_else(|| self.files.sending_for(&arr).into_iter().max_by_key(|a| a.bytes.load(Ordering::Relaxed)));
                if let Some(a) = a {
                    v["progress"] = json!(a.bytes.load(Ordering::Relaxed));
                    v["speed_bps"] = json!(a.speed_bps());
                }
            }
        }
        v
    }

    fn emit_file(&self, id: &[u8; 16]) {
        if let Some(f) = self.store.file_get(id) {
            self.emit("file", self.file_json(&f));
        }
    }

    pub async fn send_file(self: &Arc<Self>, conv: &str, path: &str) -> Result<Value> {
        self.send_file_with(conv, path, FileExtras::default()).await
    }

    /// `send_file` with previews made by the app (it can render PDFs, the core can't):
    /// a JPEG (video poster / PDF first page) and/or a [`FilePreview`]. Text files get a
    /// core-made snippet when the app sent none. See file_preview.rs for the wire format.
    pub async fn send_file_with(self: &Arc<Self>, conv: &str, path: &str, extras: FileExtras) -> Result<Value> {
        let p = PathBuf::from(path);
        let meta = tokio::fs::metadata(&p).await.map_err(|e| crate::i18n::user_err("err.file_unreadable").detail(e))?;
        anyhow::ensure!(meta.is_file(), crate::i18n::user_err("err.not_a_file"));
        let p2 = p.clone();
        let hash = tokio::task::spawn_blocking(move || hash_file(&p2)).await??;
        let file_id: [u8; 16] = crate::crypto::random_bytes();
        let name = sanitize(&p.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default());
        let peer = match parse_conv(conv)? {
            ConvRef::Direct(p) => p,
            ConvRef::Group(..) | ConvRef::Saved => self.me,
        };
        let row = FileRow {
            id: hex::encode(file_id),
            conv: conv.to_string(),
            peer: peer.to_base32(),
            name: name.clone(),
            size: meta.len() as i64,
            hash: hex::encode(hash),
            path: p.to_string_lossy().to_string(),
            direction: 0,
            state: 0,
            progress: 0,
            created: now_ms() as i64,
        };
        self.store.file_put(&row)?;
        let mime = mime_of(&name);
        let (thumb, width, height) = self.file_thumb(&p, &name, mime, meta.len(), extras).await;
        self.send_body(conv, Body::File { file_id, name: name.clone(), size: meta.len(), mime: mime.into(), hash, thumb, width, height }, None, None)
            .await?;
        self.emit_file(&file_id);
        Ok(self.file_json(&row))
    }

    /// API entry: `send_file {conv, path, thumb_b64?, width?, height?, preview?}`.
    pub async fn send_file_args(self: &Arc<Self>, conv: &str, path: &str, args: &Value) -> Result<Value> {
        self.send_file_with(conv, path, FileExtras::from_args(args)).await
    }

    /// What goes into `Body::File.{thumb,width,height}`: photos/videos keep a plain JPEG
    /// (older apps draw it), every other file a validated preview container.
    async fn file_thumb(&self, p: &std::path::Path, name: &str, mime: &str, size: u64, extras: FileExtras) -> (Vec<u8>, u32, u32) {
        let app_pic = |b: Vec<u8>| if b.len() <= FP_MAX_IMG && crate::file_preview::is_image(&b) { b } else { vec![] };
        if mime.starts_with("image/") {
            let made = if size <= 64 * 1024 * 1024 {
                let p3 = p.to_path_buf();
                tokio::task::spawn_blocking(move || make_thumb(&p3)).await.ok().flatten()
            } else {
                None
            };
            return made.unwrap_or_else(|| (app_pic(extras.thumb), extras.width, extras.height));
        }
        if mime.starts_with("video/") {
            return (app_pic(extras.thumb), extras.width, extras.height);
        }
        let mut pv = extras.preview;
        if pv.is_none() && crate::file_preview::is_text_name(name) {
            let p3 = p.to_path_buf();
            pv = tokio::task::spawn_blocking(move || crate::file_preview::text_preview(&p3)).await.ok().flatten();
        }
        let pic = app_pic(extras.thumb);
        let pv = match pv {
            Some(mut x) => {
                if x.img.is_empty() {
                    x.img = pic;
                }
                Some(x)
            }
            None if !pic.is_empty() => Some(FilePreview { kind: "file".into(), img: pic, ..Default::default() }),
            None => None,
        };
        match pv.and_then(|x| x.sanitized()) {
            Some(x) => (x.encode(), extras.width, extras.height),
            None => (vec![], 0, 0),
        }
    }

    pub(super) fn on_file_offer(&self, from: PeerId, wire_id: [u8; 16], name: String, size: u64, hash: [u8; 32], conv: String) -> Result<()> {
        if self.file_row_for(&from, &wire_id).is_some() {
            return Ok(());
        }
        // file ids are chosen by senders: if another peer (or we) already used this one,
        // this sender's file gets its own local id instead of being shadowed by the squatter
        let file_id = if self.store.file_get(&wire_id).is_none() { wire_id } else { local_file_id(&from, &wire_id) };
        let name = sanitize(&name);
        let row = FileRow {
            id: hex::encode(file_id),
            conv,
            peer: from.to_base32(),
            name,
            size: size as i64,
            hash: hex::encode(hash),
            path: String::new(),
            direction: 1,
            state: 0,
            progress: 0,
            created: now_ms() as i64,
        };
        self.store.file_put(&row)?;
        if file_id != wire_id {
            self.store.file_set_wire_id(&file_id, &wire_id)?;
        }
        self.emit_file(&file_id);
        // 1) dedupe: same content already on disk (forwards in groups) → reuse, no download.
        // Only copies this sender/chat already gave us: otherwise anyone knowing a hash could
        // probe whether we hold a file (no FileRequest = "yes") or get the message linked to
        // one of our own originals.
        if let Some(existing) = self.store.file_dedupe_source(&hex::encode(hash), &row.conv, &from, row.size) {
            let same_size = std::fs::symlink_metadata(&existing).map(|m| m.is_file() && m.len() == size).unwrap_or(false);
            if same_size {
                let mut r2 = row.clone();
                r2.path = existing;
                r2.state = 2;
                r2.progress = size as i64;
                self.store.file_put(&r2)?;
                self.emit_file(&file_id);
                return Ok(());
            }
        }
        // 2) auto-download policy: direct chats vs groups, and never when disk is low
        let pol = self.storage_policy();
        let in_group = row.conv.starts_with("g:");
        let limit = if in_group { pol.auto_group } else { pol.auto_direct };
        let trusted = self.store.is_friend(&from) || in_group;
        if size <= limit && trusted && !self.low_disk() {
            if let Some(me) = self.arc_hint() {
                tokio::spawn(async move {
                    let _ = me.accept_file(&file_id, None).await;
                });
            }
        }
        Ok(())
    }

    /// Weak self-reference for spawning from `&self` contexts.
    fn arc_hint(&self) -> Option<Arc<Node>> {
        self.self_ref.lock().as_ref().and_then(|w| w.upgrade())
    }

    pub async fn accept_file(self: &Arc<Self>, file_id: &[u8; 16], dir: Option<PathBuf>) -> Result<()> {
        let mut row = self.store.file_get(file_id).ok_or_else(|| crate::i18n::user_err("err.file_not_found"))?;
        // 7 = a copy kept on my other device (also my own uploads made there)
        anyhow::ensure!(row.direction == 1 || row.state == 7, crate::i18n::user_err("err.not_incoming_file"));
        if row.state == 2 && std::path::Path::new(&row.path).exists() {
            return Ok(());
        }
        // 7: copied from my other device's history — fetch it from there
        let from_sibling = row.state == 7;
        if row.state == 6 || row.state == 2 || row.state == 7 {
            row.path = String::new(); // removed locally → download again
        }
        let dir = dir.unwrap_or_else(|| self.downloads_dir());
        tokio::fs::create_dir_all(&dir).await.map_err(|e| crate::i18n::user_err("err.folder_unwritable").detail(e))?;
        // free space check (best effort)
        if let Ok(avail) = free_space(&dir) {
            anyhow::ensure!(avail > row.size as u64 + 64 * 1024 * 1024, crate::i18n::user_err("err.disk_full"));
        }
        if row.path.is_empty() {
            row.path = dir.join(format!(".{}.lumora-part", row.id)).to_string_lossy().to_string();
        }
        let offset = tokio::fs::metadata(&row.path).await.map(|m| m.len()).unwrap_or(0).min(row.size as u64);
        row.state = 1;
        row.progress = offset as i64;
        self.store.file_put(&row)?;
        self.emit_file(file_id);
        let wire = self.store.file_wire_id(file_id).unwrap_or(*file_id);
        if from_sibling {
            let sibs: Vec<PeerId> = self.connected_peers().iter().filter(|p| p.own).map(|p| p.peer).collect();
            anyhow::ensure!(!sibs.is_empty(), crate::i18n::user_err("err.file_on_other_device"));
            for d in sibs {
                self.send_now_dev(&d, PeerMsg::FileRequest { file_id: *file_id, offset });
            }
            return Ok(());
        }
        let peer = PeerId::from_str_any(&row.peer)?;
        let id: [u8; 16] = crate::crypto::random_bytes();
        self.deliver(peer, id, PeerMsg::FileRequest { file_id: wire, offset }, false).await;
        Ok(())
    }

    pub fn cancel_file(&self, file_id: &[u8; 16]) -> Result<()> {
        if let Some(a) = self.files.active.lock().get(file_id) {
            a.cancel.store(true, Ordering::SeqCst);
        }
        for a in self.files.sending_for(file_id) {
            a.cancel.store(true, Ordering::SeqCst);
        }
        if let Some(row) = self.store.file_get(file_id) {
            self.store.file_update(file_id, 4, row.progress)?;
            if let Ok(p) = PeerId::from_str_any(&row.peer) {
                let wire = self.store.file_wire_id(file_id).unwrap_or(*file_id);
                self.send_now(&p, PeerMsg::FileCancel { file_id: wire });
            }
        }
        self.emit_file(file_id);
        Ok(())
    }

    /// Pause = stop the stream but keep the partial file (resume with `accept_file`).
    pub fn pause_file(&self, file_id: &[u8; 16]) -> Result<()> {
        if let Some(a) = self.files.active.lock().get(file_id) {
            a.cancel.store(true, Ordering::SeqCst);
        }
        for a in self.files.sending_for(file_id) {
            a.cancel.store(true, Ordering::SeqCst);
        }
        if let Some(row) = self.store.file_get(file_id) {
            if row.state == 1 || row.state == 0 {
                self.store.file_update(file_id, 5, row.progress)?;
            }
        }
        self.emit_file(file_id);
        Ok(())
    }

    /// May `peer` fetch our outgoing file `row`? (It must be part of the conversation.)
    fn peer_may_fetch(&self, row: &FileRow, peer: &PeerId) -> bool {
        match parse_conv(&row.conv) {
            Ok(ConvRef::Direct(p)) => p == *peer,
            Ok(ConvRef::Group(gid, _)) => self.group_members(&gid).contains(peer),
            _ => false,
        }
    }

    /// FileCancel from `from` (single-device peer).
    #[cfg(test)]
    pub(super) fn on_file_cancel(&self, from: &PeerId, wire_id: &[u8; 16]) {
        self.file_cancel_from(from, from, false, wire_id)
    }

    /// FileCancel from device `dev` of `from` (`own`: one of my devices): only the other
    /// end of that transfer may stop it.
    pub(super) fn file_cancel_from(&self, from: &PeerId, dev: &PeerId, own: bool, wire_id: &[u8; 16]) {
        // incoming from `from` (its namespace), else our own upload (we chose the id)
        let Some(row) = self.file_row_for(from, wire_id).or_else(|| self.store.file_get(wire_id).filter(|r| r.direction == 0 || own)) else { return };
        let Some(local) = hex::decode(&row.id).ok().and_then(|v| <[u8; 16]>::try_from(v.as_slice()).ok()) else { return };
        let file_id = &local;
        if row.direction == 1 {
            // incoming: only the sender (or my device serving its copy)
            if PeerId::from_str_any(&row.peer).ok() != Some(*from) && !own {
                return;
            }
            if let Some(a) = self.files.active.lock().get(file_id) {
                a.cancel.store(true, Ordering::SeqCst);
            }
            if row.state != 2 {
                let _ = self.store.file_update(file_id, 4, row.progress);
            }
        } else {
            // outgoing: stop that requester's stream; in a group the others keep theirs
            if !self.peer_may_fetch(&row, from) && !own {
                return;
            }
            if let Some(a) = self.files.sending.lock().get(&(*file_id, *dev)) {
                a.cancel.store(true, Ordering::SeqCst);
            }
            if row.state != 2 && row.conv.starts_with("d:") {
                let _ = self.store.file_update(file_id, 4, row.progress);
            }
        }
        self.emit_file(file_id);
    }

    /// FileDone from `from` (the receiver verified the hash): only a peer the file was
    /// shared with; in groups one member can't mark the upload failed for everyone.
    pub(super) fn on_file_done(&self, from: &PeerId, file_id: &[u8; 16], ok: bool) {
        if *from == self.me {
            return; // my other device fetched its copy: nothing changes here
        }
        if let Some(row) = self.store.file_get(file_id) {
            if row.direction == 0 && self.peer_may_fetch(&row, from) && (ok || row.conv.starts_with("d:")) {
                let _ = self.store.file_update(file_id, if ok { 2 } else { 3 }, if ok { row.size } else { row.progress });
                self.emit_file(file_id);
            }
        }
    }

    pub(super) async fn on_file_request(self: &Arc<Self>, pc: Arc<PeerConn>, file_id: [u8; 16], offset: u64) -> Result<()> {
        let row = self.store.file_get(&file_id).ok_or_else(|| anyhow!("unknown file"))?;
        // my own devices may fetch any copy I hold (history moved to a new device)
        let sibling_copy = pc.own && row.direction == 1 && row.state == 2 && !row.path.is_empty();
        anyhow::ensure!((row.direction == 0 && row.state != 7) || sibling_copy, "not our file");
        // authorise: the requester must be part of the conversation the file was shared in
        anyhow::ensure!(pc.own || self.peer_may_fetch(&row, &pc.account), "requester not allowed");
        let key = (file_id, pc.peer);
        let active = Arc::new(Active::new(offset));
        {
            let mut sending = self.files.sending.lock();
            if sending.contains_key(&key) {
                return Ok(()); // already sending to this peer (duplicate / re-sent request)
            }
            sending.insert(key, active.clone());
        }
        let node = self.clone();
        pc.busy.fetch_add(1, Ordering::Relaxed);
        tokio::spawn(async move {
            let r: Result<()> = async {
                let mut f = tokio::fs::File::open(&row.path).await?;
                f.seek(std::io::SeekFrom::Start(offset)).await?;
                let mut s = pc.conn.open_uni().await?;
                s.set_priority(-1)?; // chat/control first
                let mut hdr = vec![proto::STREAM_FILE];
                hdr.extend_from_slice(&file_id);
                hdr.extend_from_slice(&offset.to_be_bytes());
                s.write_all(&hdr).await?;
                node.store.file_update(&file_id, 1, offset as i64)?;
                let mut buf = vec![0u8; CHUNK];
                let mut last_emit = Instant::now();
                use tokio::io::AsyncReadExt;
                loop {
                    if active.cancel.load(Ordering::SeqCst) {
                        let _ = s.reset(1u32.into());
                        anyhow::bail!("cancelled");
                    }
                    let n = f.read(&mut buf).await?;
                    if n == 0 {
                        break;
                    }
                    s.write_all(&buf[..n]).await?;
                    let done = active.bytes.fetch_add(n as u64, Ordering::Relaxed) + n as u64;
                    if last_emit.elapsed() > Duration::from_millis(300) {
                        last_emit = Instant::now();
                        let _ = node.store.file_update(&file_id, 1, done as i64);
                        node.emit_file(&file_id);
                    }
                }
                s.finish()?;
                let _ = s.stopped().await;
                Ok(())
            }
            .await;
            pc.busy.fetch_sub(1, Ordering::Relaxed);
            node.files.sending.lock().remove(&key);
            if let Err(e) = r {
                tracing::info!("file send ended: {e:#}");
                if let Some(row) = node.store.file_get(&file_id) {
                    if row.state == 1 {
                        let _ = node.store.file_update(&file_id, 5, row.progress);
                    }
                }
            }
            node.emit_file(&file_id);
        });
        Ok(())
    }

    pub(super) async fn receive_file_stream(self: &Arc<Self>, pc: &Arc<PeerConn>, mut recv: quinn::RecvStream) -> Result<()> {
        let mut hdr = [0u8; 24];
        recv.read_exact(&mut hdr).await?;
        let wire_id: [u8; 16] = hdr[..16].try_into().unwrap();
        let offset = u64::from_be_bytes(hdr[16..24].try_into().unwrap());
        // from the sender (any of its devices), or from my own device holding a copy
        let row = self
            .file_row_for(&pc.account, &wire_id)
            .or_else(|| if pc.own { self.store.file_get(&wire_id) } else { None })
            .ok_or_else(|| anyhow!("unexpected file"))?;
        let file_id: [u8; 16] = hex::decode(&row.id).ok().and_then(|v| v.try_into().ok()).ok_or_else(|| anyhow!("bad file id"))?;
        anyhow::ensure!((row.direction == 1 || pc.own) && row.state == 1, "file not accepted");
        anyhow::ensure!(pc.own || PeerId::from_str_any(&row.peer)? == pc.account, "wrong sender");
        let part = PathBuf::from(&row.path);
        // never write through a link planted at the partial file's name
        let have = match tokio::fs::symlink_metadata(&part).await {
            Ok(m) => {
                anyhow::ensure!(m.file_type().is_file(), "partial download is not a regular file");
                m.len()
            }
            Err(_) => 0,
        };
        check_stream_offset(offset, row.size as u64, have)?;
        let active = Arc::new(Active::new(offset));
        {
            let mut a = self.files.active.lock();
            anyhow::ensure!(!a.contains_key(&file_id), "transfer already running");
            a.insert(file_id, active.clone());
        }
        let opened: Result<tokio::fs::File> = async {
            if let Some(dir) = part.parent() {
                tokio::fs::create_dir_all(dir).await?;
            }
            let mut o = tokio::fs::OpenOptions::new();
            o.create(true).write(true).truncate(false);
            // the check above can race: refuse to follow a link swapped in meanwhile
            #[cfg(unix)]
            o.custom_flags(libc::O_NOFOLLOW);
            let mut f = o.open(&part).await?;
            f.set_len(offset).await?;
            f.seek(std::io::SeekFrom::Start(offset)).await?;
            Ok(f)
        }
        .await;
        let mut f = match opened {
            Ok(f) => f,
            Err(e) => {
                self.files.active.lock().remove(&file_id);
                return Err(e);
            }
        };
        pc.busy.fetch_add(1, Ordering::Relaxed);
        let _busy = BusyGuard(pc.clone());
        let mut buf = vec![0u8; CHUNK];
        let mut last_emit = Instant::now();
        let size = row.size as u64;
        let res: Result<()> = async {
            loop {
                if active.cancel.load(Ordering::SeqCst) {
                    let _ = recv.stop(1u32.into());
                    anyhow::bail!("cancelled");
                }
                let n = match recv.read(&mut buf).await? {
                    Some(n) => n,
                    None => break,
                };
                let done = active.bytes.load(Ordering::Relaxed) + n as u64;
                anyhow::ensure!(done <= size, "sender sent more than announced");
                f.write_all(&buf[..n]).await?;
                active.bytes.store(done, Ordering::Relaxed);
                if last_emit.elapsed() > Duration::from_millis(300) {
                    last_emit = Instant::now();
                    let _ = self.store.file_update(&file_id, 1, done as i64);
                    self.emit_file(&file_id);
                }
            }
            f.flush().await?;
            f.sync_all().await?;
            Ok(())
        }
        .await;
        self.files.active.lock().remove(&file_id);
        let got = active.bytes.load(Ordering::Relaxed);
        if let Err(e) = res {
            let paused = self.store.file_get(&file_id).map(|r| r.state == 5).unwrap_or(false);
            let st = if paused { 5 } else if e.to_string().contains("cancel") { 4 } else { 5 };
            self.store.file_update(&file_id, st, got as i64)?;
            self.emit_file(&file_id);
            return Err(e);
        }
        if got != size {
            self.store.file_update(&file_id, 5, got as i64)?;
            self.emit_file(&file_id);
            return Ok(()); // paused/interrupted: resumable
        }
        let part2 = part.clone();
        let hash = tokio::task::spawn_blocking(move || hash_file(&part2)).await??;
        let ok = hex::encode(hash) == row.hash;
        if ok {
            let dir = part.parent().map(|p| p.to_path_buf()).unwrap_or_else(|| self.downloads_dir());
            let (p2, name) = (part.clone(), row.name.clone());
            let final_path = tokio::task::spawn_blocking(move || place_final(&p2, &dir, &name)).await??;
            let mut r2 = row.clone();
            r2.path = final_path.to_string_lossy().to_string();
            r2.state = 2;
            r2.progress = size as i64;
            self.store.file_put(&r2)?;
        } else {
            let _ = tokio::fs::remove_file(&part).await;
            let mut r2 = row.clone();
            r2.path = String::new();
            r2.state = 3;
            r2.progress = 0;
            self.store.file_put(&r2)?;
        }
        let id: [u8; 16] = crate::crypto::random_bytes();
        self.deliver_dev(pc.peer, id, PeerMsg::FileDone { file_id: wire_id, ok }, false).await;
        self.emit_file(&file_id);
        Ok(())
    }

    pub fn storage_policy(&self) -> StoragePolicy {
        self.store.kv_get_json("storage.policy").unwrap_or_default()
    }

    pub fn set_storage_policy(&self, p: &StoragePolicy) -> Result<()> {
        self.store.kv_set_json("storage.policy", p)
    }

    pub fn low_disk(&self) -> bool {
        free_space(&self.downloads_dir()).map(|f| f < (1u64 << 30)).unwrap_or(false)
    }

    /// Enforce the media cache policy: oldest received files first, messages are kept and
    /// the file can be fetched again from the sender (state 6 = removed locally).
    pub fn clean_media(&self, force_conv: Option<&str>) -> Result<Value> {
        let pol = self.storage_policy();
        let rows = self.store.received_files()?;
        let mut total: u64 = rows.iter().map(|r| r.size as u64).sum();
        let now = now_ms() as i64;
        let mut freed = 0u64;
        let mut removed = 0u64;
        let dl = self.downloads_dir();
        for r in rows.iter() {
            let too_old = pol.media_days > 0 && now - r.created > pol.media_days as i64 * 86_400_000;
            let over = pol.max_cache > 0 && total > pol.max_cache;
            let forced = force_conv.map(|c| r.conv == c || c == "*").unwrap_or(false);
            if !(too_old || over || forced) {
                continue;
            }
            // only delete files Lumora owns (inside its downloads dir) and not shared by another row
            let p = std::path::Path::new(&r.path);
            if p.starts_with(&dl) && self.store.path_refcount(&r.path) <= 1 {
                let _ = std::fs::remove_file(p);
            }
            if let Ok(id) = hex::decode(&r.id) {
                let _ = self.store.file_update(&id, 6, 0);
            }
            total = total.saturating_sub(r.size as u64);
            freed += r.size as u64;
            removed += 1;
        }
        Ok(json!({"freed_bytes": freed, "removed_files": removed, "cache_bytes": total}))
    }

    /// The file row a file/voice message refers to — only when that message's author is
    /// the one who offered it: a peer re-using someone else's `file_id` (first offer wins)
    /// must not get its content shown under, or forwarded as, the other person's message.
    pub(super) fn file_of_message(&self, m: &crate::store::StoredMessage) -> Option<FileRow> {
        let wire: [u8; 16] = hex::decode(m.body["file_id"].as_str()?).ok()?.try_into().ok()?;
        let author = PeerId::from_str_any(&m.author).ok()?;
        self.file_row_for(&author, &wire)
    }

    /// The file row `sender` offered under its `file_id`: ids are per-sender (a row is
    /// keyed by the wire id, or by [`local_file_id`] when another peer used it first).
    /// Our own uploads (`sender == me`) are keyed by the id we chose.
    pub(super) fn file_row_for(&self, sender: &PeerId, wire: &[u8; 16]) -> Option<FileRow> {
        if *sender == self.me {
            return self.store.file_get(wire).filter(|f| f.direction == 0);
        }
        let mine = |f: &FileRow| f.direction == 1 && f.peer == sender.to_base32();
        self.store.file_get(wire).filter(mine).or_else(|| self.store.file_get(&local_file_id(sender, wire)).filter(mine))
    }

    /// Local id (hex) of a message's file when it differs from the sender's wire id —
    /// also before the offer is stored (same rule as `on_file_offer`).
    pub(super) fn local_file_ref(&self, m: &crate::store::StoredMessage) -> Option<String> {
        let wire: [u8; 16] = hex::decode(m.body["file_id"].as_str()?).ok()?.try_into().ok()?;
        let author = PeerId::from_str_any(&m.author).ok()?;
        if author == self.me {
            return None;
        }
        let local = match self.file_row_for(&author, &wire) {
            Some(f) => hex::decode(&f.id).ok()?.try_into().ok()?,
            None if self.store.file_get(&wire).is_some() => local_file_id(&author, &wire),
            None => wire,
        };
        (local != wire).then(|| hex::encode(local))
    }

    /// Forget the files of messages that are going away (clear history, purge member):
    /// same rules as "delete for everyone".
    pub(super) fn forget_files_of(&self, msgs: &[crate::store::StoredMessage]) {
        for m in msgs {
            if let Some(row) = self.file_of_message(m) {
                self.forget_file(&row);
            }
        }
    }

    /// "Delete for everyone": blank the message and, for a file message, forget its file —
    /// stop transfers, remove the copy Lumora downloaded (never a sender's original or a
    /// copy the user saved elsewhere) and drop the row so it can't be requested any more.
    pub(super) fn delete_message_everywhere(&self, target: &[u8; 16], author: Option<&PeerId>) -> Result<bool> {
        let file = self.store.message(target).filter(|m| m.kind == "file" || m.kind == "voice").and_then(|m| self.file_of_message(&m));
        if !self.store.delete_message(target, author)? {
            return Ok(false);
        }
        if let Some(row) = file {
            self.forget_file(&row);
        }
        Ok(true)
    }

    fn forget_file(&self, row: &FileRow) {
        let Some(fid) = hex::decode(&row.id).ok().and_then(|v| <[u8; 16]>::try_from(v.as_slice()).ok()) else { return };
        if let Some(a) = self.files.active.lock().get(&fid) {
            a.cancel.store(true, Ordering::SeqCst);
        }
        for a in self.files.sending_for(&fid) {
            a.cancel.store(true, Ordering::SeqCst);
        }
        if row.direction == 1 && !row.path.is_empty() {
            let p = std::path::Path::new(&row.path);
            let part = p.file_name().map(|n| n.to_string_lossy().ends_with(".lumora-part")).unwrap_or(false);
            if (part || p.starts_with(self.downloads_dir())) && self.store.path_refcount(&row.path) <= 1 {
                let _ = std::fs::remove_file(p);
            }
        }
        let _ = self.store.file_delete(&fid);
        let mut gone = row.clone();
        gone.state = 6;
        gone.path = String::new();
        self.emit("file", self.file_json(&gone));
    }

    pub fn files_list(&self) -> Result<Vec<Value>> {
        let rows = self.store.files(200)?;
        // previews live in the file messages (one query per conversation)
        let convs: std::collections::HashSet<&str> = rows.iter().map(|r| r.conv.as_str()).collect();
        let mut previews: HashMap<String, Value> = HashMap::new();
        for c in convs {
            for body in self.store.file_preview_bodies(c) {
                if let (Some(id), Some(p)) = (body["file_id"].as_str(), body.get("preview")) {
                    previews.insert(id.to_string(), p.clone());
                }
            }
        }
        Ok(rows
            .iter()
            .map(|f| {
                let mut v = self.file_json(f);
                let wire = || hex::decode(&f.id).ok().and_then(|id| self.store.file_wire_id(&id)).map(hex::encode);
                if let Some(p) = previews.remove(&f.id).or_else(|| wire().and_then(|w| previews.remove(&w))) {
                    v["preview"] = p;
                }
                v
            })
            .collect())
    }
}

struct BusyGuard(Arc<PeerConn>);
impl Drop for BusyGuard {
    fn drop(&mut self) {
        self.0.busy.fetch_sub(1, Ordering::Relaxed);
    }
}

impl Node {
    /// Resume interrupted incoming transfers from this peer (called on connect).
    pub(super) fn resume_transfers(self: &Arc<Self>, peer: &PeerId) {
        let Ok(rows) = self.store.files(500) else { return };
        for r in rows {
            if r.direction == 1 && (r.state == 5 || r.state == 1) && r.peer == peer.to_base32() {
                let Ok(id) = hex::decode(&r.id) else { continue };
                let Ok(id) = <[u8; 16]>::try_from(id.as_slice()) else { continue };
                if self.files.active.lock().contains_key(&id) {
                    continue;
                }
                let me = self.clone();
                tokio::spawn(async move {
                    tokio::time::sleep(Duration::from_millis(500)).await;
                    let _ = me.accept_file(&id, None).await;
                });
            }
        }
    }
}

/// Local id of a file `sender` offered as `wire` when that id was already taken here
/// (see [`Node::file_row_for`]). Local state only: the wire keeps the sender's id.
pub(crate) fn local_file_id(sender: &PeerId, wire: &[u8; 16]) -> [u8; 16] {
    let mut h = blake3::Hasher::new_derive_key("lumora local file id v1");
    h.update(&sender.0);
    h.update(wire);
    h.finalize().as_bytes()[..16].try_into().unwrap()
}

/// Bytes available to us on the volume holding `dir` (or its nearest existing parent).
fn free_space(dir: &std::path::Path) -> Result<u64> {
    let mut p = dir;
    while !p.exists() {
        p = p.parent().ok_or_else(|| anyhow!("no existing folder"))?;
    }
    free_space_os(p)
}

#[cfg(unix)]
#[allow(clippy::unnecessary_cast)] // field widths differ between Linux, Android and Apple
fn free_space_os(dir: &std::path::Path) -> Result<u64> {
    use std::os::unix::ffi::OsStrExt;
    let c = std::ffi::CString::new(dir.as_os_str().as_bytes())?;
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: `c` is a valid NUL-terminated path and `st` a writable statvfs.
    let r = unsafe { libc::statvfs(c.as_ptr(), &mut st) };
    anyhow::ensure!(r == 0, "statvfs: {}", std::io::Error::last_os_error());
    Ok((st.f_bavail as u64).saturating_mul(st.f_frsize as u64))
}

#[cfg(windows)]
fn free_space_os(dir: &std::path::Path) -> Result<u64> {
    use std::os::windows::ffi::OsStrExt;
    let w: Vec<u16> = dir.as_os_str().encode_wide().chain(std::iter::once(0)).collect();
    let mut avail: u64 = 0;
    // SAFETY: `w` is NUL-terminated UTF-16; the other out-pointers may be null.
    let ok = unsafe {
        windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW(w.as_ptr(), &mut avail, std::ptr::null_mut(), std::ptr::null_mut())
    };
    anyhow::ensure!(ok != 0, "GetDiskFreeSpaceExW: {}", std::io::Error::last_os_error());
    Ok(avail)
}

#[cfg(not(any(unix, windows)))]
fn free_space_os(_dir: &std::path::Path) -> Result<u64> {
    anyhow::bail!("free space unknown on this platform")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn sanitize_names() {
        assert_eq!(sanitize("../../etc/passwd"), "passwd");
        assert_eq!(sanitize("C:\\x\\a<b>.txt"), "ab.txt");
        assert_eq!(sanitize("..."), "file");
    }

    #[test]
    fn rate_meter_smooths_towards_the_real_speed() {
        let t0 = Instant::now();
        let mut m = RateMeter { last_t: t0, last_bytes: 0, ewma: None };
        // steady 1 MB/s sampled every 300 ms
        let mut out = 0;
        for i in 1..=20u64 {
            out = m.sample(i * 300_000, t0 + Duration::from_millis(300 * i));
        }
        assert!((out as i64 - 1_000_000).abs() < 10_000, "{out}");
        // speed drops to 0: after ~2 s the estimate has fallen by ≈ 1 − 1/e
        for i in 21..=27u64 {
            out = m.sample(20 * 300_000, t0 + Duration::from_millis(300 * i));
        }
        assert!(out > 250_000 && out < 450_000, "{out}");
        // samples closer than 200 ms don't change the estimate
        assert_eq!(m.sample(99_999_999, t0 + Duration::from_millis(300 * 27 + 50)), out);
        assert_eq!(sanitize("ảnh đẹp.png"), "ảnh đẹp.png");
    }
}

#[cfg(test)]
mod security_tests {
    //! Adversarial tests from the security audit (file transfer receive path).
    use super::*;
    use crate::proto::MsgAction;

    async fn node(tmp: &std::path::Path) -> Arc<Node> {
        let cfg = NodeConfig {
            data_dir: tmp.join("data"),
            downloads_dir: Some(tmp.join("dl")),
            enable_lan: false,
            enable_upnp: false,
            enable_dht: false,
            enable_nostr: false,
            relays: Some(vec![]),
            nostr: Some(vec![]),
            stun: Some(vec![]),
            ..Default::default()
        };
        Node::start(cfg).await.unwrap()
    }

    fn row(id: u8, conv: &str, peer: &PeerId, path: &str, hash: [u8; 32], direction: i64, state: i64) -> FileRow {
        FileRow {
            id: hex::encode([id; 16]),
            conv: conv.into(),
            peer: peer.to_base32(),
            name: "f.bin".into(),
            size: 10,
            hash: hex::encode(hash),
            path: path.into(),
            direction,
            state,
            progress: 0,
            created: id as i64,
        }
    }

    #[test]
    fn hostile_file_names() {
        // RTL override: "invoice\u{202E}fdp.exe" is displayed as "invoiceexe.pdf"
        assert_eq!(sanitize("invoice\u{202E}fdp.exe"), "invoicefdp.exe");
        assert_eq!(sanitize("a\u{200B}b\u{2066}c\u{FEFF}.txt"), "abc.txt");
        for dev in ["CON", "nul.txt", "Com1.jpg", "LPT9", "aux.tar.gz", "CONIN$", "prn .txt"] {
            assert!(sanitize(dev).starts_with('_'), "Windows device name kept: {dev} → {}", sanitize(dev));
        }
        assert_eq!(sanitize("report.pdf. . ."), "report.pdf");
        assert_eq!(sanitize("x\0y.txt"), "xy.txt");
        assert_eq!(sanitize("\\\\server\\share\\evil.lnk"), "evil.lnk");
        assert_eq!(sanitize("..\\..\\Windows\\win.ini"), "win.ini");
        let long = format!("{}.jpg", "ả".repeat(300));
        let s = sanitize(&long);
        assert!(s.len() <= 200 && s.ends_with(".jpg"), "{} bytes: {s}", s.len());
        assert_eq!(sanitize("\u{202E}\u{200B}"), "file");
    }

    /// PoC: a peer that knows the BLAKE3 of a file (e.g. it received it from me) offers
    /// "the same" file; the receiver links the offer to its own copy without downloading —
    /// the message then points at my private original (which "delete" or "clear media"
    /// may later act on), and the missing FileRequest tells the attacker I have the file.
    #[tokio::test]
    async fn dedupe_never_links_to_my_originals_or_other_chats() {
        let tmp = tempfile::tempdir().unwrap();
        let n = node(tmp.path()).await;
        let bob = Identity::generate().peer_id();
        let mallory = Identity::generate().peer_id();
        let secret = tmp.path().join("secret.pdf");
        std::fs::write(&secret, b"top secret").unwrap();
        let h = hash_file(&secret).unwrap();
        n.store.file_put(&row(1, &direct_conv(&bob), &bob, secret.to_str().unwrap(), h, 0, 2)).unwrap();
        n.on_file_offer(mallory, [2u8; 16], "x.pdf".into(), 10, h, direct_conv(&mallory)).unwrap();
        let r = n.store.file_get(&[2u8; 16]).unwrap();
        assert_ne!(r.path, secret.to_str().unwrap(), "offer linked to my private original");
        assert_ne!(r.state, 2, "possession oracle: completed without a download");
        // a file received from someone else, in another chat
        let dl = n.downloads_dir();
        std::fs::create_dir_all(&dl).unwrap();
        let got = dl.join("photo.jpg");
        std::fs::write(&got, b"holiday!!!").unwrap();
        let h2 = hash_file(&got).unwrap();
        n.store.file_put(&row(3, &direct_conv(&bob), &bob, got.to_str().unwrap(), h2, 1, 2)).unwrap();
        n.on_file_offer(mallory, [4u8; 16], "y.jpg".into(), 10, h2, direct_conv(&mallory)).unwrap();
        assert_ne!(n.store.file_get(&[4u8; 16]).unwrap().state, 2, "possession oracle across chats");
        // the same sender re-sharing in the same chat is still deduplicated (no re-download)
        n.on_file_offer(bob, [5u8; 16], "photo.jpg".into(), 10, h2, direct_conv(&bob)).unwrap();
        let r5 = n.store.file_get(&[5u8; 16]).unwrap();
        assert_eq!((r5.state, r5.path.as_str()), (2, got.to_str().unwrap()));
        n.shutdown();
    }

    /// PoC: FileCancel / FileDone were accepted from any connected peer.
    #[tokio::test]
    async fn only_the_transfer_partner_can_cancel_or_finish() {
        let tmp = tempfile::tempdir().unwrap();
        let n = node(tmp.path()).await;
        let bob = Identity::generate().peer_id();
        let mallory = Identity::generate().peer_id();
        n.store.file_put(&row(6, &direct_conv(&bob), &bob, "", [0; 32], 1, 1)).unwrap();
        n.on_file_cancel(&mallory, &[6u8; 16]);
        assert_eq!(n.store.file_get(&[6u8; 16]).unwrap().state, 1, "a stranger cancelled my download");
        n.store.file_put(&row(7, &direct_conv(&bob), &bob, "/x", [0; 32], 0, 1)).unwrap();
        n.on_file_done(&mallory, &[7u8; 16], false);
        assert_eq!(n.store.file_get(&[7u8; 16]).unwrap().state, 1, "a stranger marked my upload failed");
        n.on_file_done(&bob, &[7u8; 16], true);
        assert_eq!(n.store.file_get(&[7u8; 16]).unwrap().state, 2);
        n.shutdown();
    }

    /// PoC: "delete for everyone" blanked the message but left the received file on disk
    /// (and in the Files screen), and the sender kept serving it to the other side.
    #[tokio::test]
    async fn delete_for_everyone_removes_the_received_file() {
        let tmp = tempfile::tempdir().unwrap();
        let n = node(tmp.path()).await;
        let bob = Identity::generate().peer_id();
        let conv = direct_conv(&bob);
        let dl = n.downloads_dir();
        std::fs::create_dir_all(&dl).unwrap();
        let got = dl.join("doc.pdf");
        std::fs::write(&got, b"0123456789").unwrap();
        n.store.file_put(&row(8, &conv, &bob, got.to_str().unwrap(), [0; 32], 1, 2)).unwrap();
        n.store.ensure_conv(&conv, 0, "Bob").unwrap();
        let mid = [9u8; 16];
        n.store.insert_message(&mid, &conv, &bob, 1, "file", &json!({"file_id": hex::encode([8u8; 16]), "name": "doc.pdf"}), 2, None, None).unwrap();
        n.apply_action(&conv, &bob, &MsgAction::Delete { target: mid }).unwrap();
        assert!(n.store.message(&mid).unwrap().deleted);
        assert!(!got.exists(), "file deleted for everyone is still on disk");
        assert!(n.store.file_get(&[8u8; 16]).is_none(), "file deleted for everyone still listed");
        // my own upload: the row goes (no more FileRequests served), my original stays
        let orig = tmp.path().join("mine.txt");
        std::fs::write(&orig, b"0123456789").unwrap();
        n.store.file_put(&row(10, &conv, &bob, orig.to_str().unwrap(), [0; 32], 0, 2)).unwrap();
        let mid2 = [11u8; 16];
        n.store.insert_message(&mid2, &conv, &n.me, 2, "file", &json!({"file_id": hex::encode([10u8; 16])}), 2, None, None).unwrap();
        n.apply_action(&conv, &n.me.clone(), &MsgAction::Delete { target: mid2 }).unwrap();
        assert!(orig.exists(), "my original was deleted");
        assert!(n.store.file_get(&[10u8; 16]).is_none(), "deleted upload can still be requested");
        n.shutdown();
    }

    /// PoC: file ids are chosen by the sender and the first offer wins, so a group member
    /// could re-use Bob's `file_id` with its own content and have it shown (and forwarded)
    /// as Bob's attachment.
    #[tokio::test]
    async fn a_reused_file_id_is_not_shown_under_someone_elses_message() {
        let tmp = tempfile::tempdir().unwrap();
        let n = node(tmp.path()).await;
        let bob = Identity::generate().peer_id();
        let mallory = Identity::generate().peer_id();
        let conv = direct_conv(&bob);
        n.store.file_put(&row(12, &conv, &mallory, "/tmp/evil.exe", [0; 32], 1, 2)).unwrap();
        let mid = [13u8; 16];
        n.store.insert_message(&mid, &conv, &bob, 1, "file", &json!({"file_id": hex::encode([12u8; 16])}), 2, None, None).unwrap();
        let m = n.store.message(&mid).unwrap();
        assert!(n.msg_json(&m)["file"].is_null(), "Bob's message shows Mallory's file");
        n.shutdown();
    }

    /// PoC (before): Mallory re-used Bob's file id first → Bob's offer was ignored and his
    /// real file could never be downloaded. Ids are now per sender (local state only).
    #[tokio::test]
    async fn a_squatted_file_id_does_not_block_the_real_senders_file() {
        let tmp = tempfile::tempdir().unwrap();
        let n = node(tmp.path()).await;
        let bob = Identity::generate().peer_id();
        let mallory = Identity::generate().peer_id();
        // (a direct chat with strangers: nothing auto-downloads in this test)
        let conv = direct_conv(&bob);
        let x = [0x42u8; 16];
        n.store.ensure_conv(&conv, 0, "Bob").unwrap();
        // Bob's message is stored (and shown) before Mallory's squatting offer is processed
        let (mb, mm) = ([20u8; 16], [21u8; 16]);
        n.on_file_offer(mallory, x, "evil.exe".into(), 10, [7; 32], conv.clone()).unwrap();
        n.store.insert_message(&mm, &conv, &mallory, 1, "file", &json!({"file_id": hex::encode(x), "name": "evil.exe"}), 2, None, None).unwrap();
        n.store.insert_message(&mb, &conv, &bob, 2, "file", &json!({"file_id": hex::encode(x), "name": "report.pdf"}), 2, None, None).unwrap();
        let local = local_file_id(&bob, &x);
        // the app addresses Bob's file by its local id, even before the offer arrives
        assert_eq!(n.msg_json(&n.store.message(&mb).unwrap())["body"]["file_id"], json!(hex::encode(local)));
        n.on_file_offer(bob, x, "report.pdf".into(), 10, [8; 32], conv.clone()).unwrap();
        let rb = n.file_row_for(&bob, &x).expect("Bob's file has its own record");
        assert_eq!((rb.id.as_str(), rb.name.as_str()), (hex::encode(local).as_str(), "report.pdf"));
        assert_eq!(n.store.file_wire_id(&local), Some(x), "requests still use Bob's id on the wire");
        assert_eq!(n.file_row_for(&mallory, &x).unwrap().name, "evil.exe");
        let jb = n.msg_json(&n.store.message(&mb).unwrap());
        assert_eq!((jb["body"]["file_id"].as_str(), jb["body"]["wire_file_id"].as_str()), (Some(hex::encode(local).as_str()), Some(hex::encode(x).as_str())));
        assert!(!jb["file"].is_null());
        let jm = n.msg_json(&n.store.message(&mm).unwrap());
        assert_eq!(jm["body"]["file_id"], json!(hex::encode(x)), "the first sender keeps the plain id");
        // Bob's file can be downloaded: accepting marks it transferring and asks Bob for `x`
        let _ = tokio::time::timeout(Duration::from_secs(5), n.accept_file(&local, None)).await;
        assert_eq!(n.store.file_get(&local).unwrap().state, 1);
        assert_eq!(n.store.file_get(&x).unwrap().state, 0, "Mallory's record untouched");
        // a cancel from Bob about `x` hits Bob's transfer, not Mallory's
        n.on_file_cancel(&bob, &x);
        assert_eq!(n.store.file_get(&local).unwrap().state, 4);
        assert_eq!(n.store.file_get(&x).unwrap().state, 0);
        n.shutdown();
    }

    /// Existing databases: the new column is added, old rows keep their ids (wire = id).
    #[test]
    fn file_id_migration_keeps_existing_rows() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("db");
        let key = zeroize::Zeroizing::new([3u8; 32]);
        let bob = Identity::generate().peer_id();
        {
            let st = crate::store::Store::open(&path, &key).unwrap();
            st.file_put(&row(30, &direct_conv(&bob), &bob, "", [0; 32], 1, 0)).unwrap();
        }
        let st = crate::store::Store::open(&path, &key).unwrap(); // migration runs again: idempotent
        assert_eq!(st.file_wire_id(&[30u8; 16]), Some([30u8; 16]));
        assert!(st.file_get(&[30u8; 16]).is_some());
    }

    fn received(n: &Node, id: u8, conv: &str, from: &PeerId, name: &str) -> (std::path::PathBuf, [u8; 16]) {
        let dl = n.downloads_dir();
        std::fs::create_dir_all(&dl).unwrap();
        let p = dl.join(name);
        std::fs::write(&p, b"0123456789").unwrap();
        n.store.file_put(&row(id, conv, from, p.to_str().unwrap(), [id; 32], 1, 2)).unwrap();
        let mid = [id.wrapping_add(100); 16];
        n.store.insert_message(&mid, conv, from, id as u64, "file", &json!({"file_id": hex::encode([id; 16])}), 2, None, None).unwrap();
        (p, mid)
    }

    #[tokio::test]
    async fn clear_history_removes_downloaded_copies_only() {
        let tmp = tempfile::tempdir().unwrap();
        let n = node(tmp.path()).await;
        let bob = Identity::generate().peer_id();
        let conv = direct_conv(&bob);
        n.store.ensure_conv(&conv, 0, "Bob").unwrap();
        let (got, _) = received(&n, 40, &conv, &bob, "a.jpg");
        // a copy the user saved elsewhere ("save as") and my own original stay
        let saved = tmp.path().join("saved.pdf");
        std::fs::write(&saved, b"0123456789").unwrap();
        n.store.file_put(&row(41, &conv, &bob, saved.to_str().unwrap(), [0; 32], 1, 2)).unwrap();
        n.store.insert_message(&[141u8; 16], &conv, &bob, 41, "file", &json!({"file_id": hex::encode([41u8; 16])}), 2, None, None).unwrap();
        let mine = tmp.path().join("mine.txt");
        std::fs::write(&mine, b"0123456789").unwrap();
        n.store.file_put(&row(42, &conv, &bob, mine.to_str().unwrap(), [0; 32], 0, 2)).unwrap();
        n.store.insert_message(&[142u8; 16], &conv, &n.me, 42, "file", &json!({"file_id": hex::encode([42u8; 16])}), 2, None, None).unwrap();
        n.clear_local(&conv, u64::MAX >> 1, false).unwrap();
        assert!(!got.exists(), "downloaded copy kept after clearing the chat");
        assert!(saved.exists() && mine.exists(), "a saved copy / my original was deleted");
        assert!(n.store.file_get(&[40u8; 16]).is_none());
        // clearing for me keeps my own upload offered: Bob still has the message and may not
        // have downloaded it yet
        assert!(n.store.file_get(&[42u8; 16]).is_some(), "my upload was withdrawn by a clear-for-me");
        n.shutdown();
    }

    #[tokio::test]
    async fn purging_a_member_removes_their_downloaded_files() {
        let tmp = tempfile::tempdir().unwrap();
        let n = node(tmp.path()).await;
        let (spam, ok) = (Identity::generate().peer_id(), Identity::generate().peer_id());
        let conv = format!("g:{}", hex::encode([2u8; 32]));
        n.store.ensure_conv(&conv, 1, "G").unwrap();
        let (bad, _) = received(&n, 50, &conv, &spam, "spam.zip");
        let (good, _) = received(&n, 51, &conv, &ok, "menu.pdf");
        // what the PurgeAuthor handler runs before blanking the messages
        let files = n.store.file_messages(&conv, i64::MAX, Some(&spam)).unwrap();
        n.forget_files_of(&files);
        assert!(!bad.exists() && good.exists());
        n.shutdown();
    }

    #[test]
    fn free_space_is_known_without_a_shell() {
        let tmp = tempfile::tempdir().unwrap();
        assert!(free_space(&tmp.path().join("not/yet/created")).unwrap() > 0);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn partial_file_open_refuses_a_swapped_in_link() {
        let tmp = tempfile::tempdir().unwrap();
        let target = tmp.path().join("victim");
        std::fs::write(&target, b"keep").unwrap();
        let part = tmp.path().join(".x.lumora-part");
        std::os::unix::fs::symlink(&target, &part).unwrap();
        let mut o = tokio::fs::OpenOptions::new();
        o.create(true).write(true).truncate(false).custom_flags(libc::O_NOFOLLOW);
        assert!(o.open(&part).await.is_err());
        assert_eq!(std::fs::read(&target).unwrap(), b"keep");
    }

    #[test]
    fn resume_offset_from_the_sender_is_bounded() {
        assert!(check_stream_offset(0, 10, 0).is_ok());
        assert!(check_stream_offset(5, 10, 5).is_ok());
        assert!(check_stream_offset(u64::MAX / 2, 10, 0).is_err(), "huge set_len / sparse file");
        assert!(check_stream_offset(8, 10, 5).is_err(), "hole in the partial file");
        assert!(check_stream_offset(11, 10, 20).is_err());
    }

    /// PoC: a 60-byte PNG declaring 10 000 × 10 000 RGBA made the thumbnailer allocate
    /// 400 MB (forwarding a received "photo").
    #[test]
    fn decompression_bomb_is_refused_before_allocating() {
        fn crc32(b: &[u8]) -> u32 {
            let mut c = !0u32;
            for &x in b {
                c ^= x as u32;
                for _ in 0..8 {
                    c = if c & 1 != 0 { 0xEDB8_8320 ^ (c >> 1) } else { c >> 1 };
                }
            }
            !c
        }
        let mut png = b"\x89PNG\r\n\x1a\n".to_vec();
        let mut ihdr = b"IHDR".to_vec();
        ihdr.extend_from_slice(&10_000u32.to_be_bytes());
        ihdr.extend_from_slice(&10_000u32.to_be_bytes());
        ihdr.extend_from_slice(&[8, 6, 0, 0, 0]);
        png.extend_from_slice(&13u32.to_be_bytes());
        png.extend_from_slice(&ihdr);
        png.extend_from_slice(&crc32(&ihdr).to_be_bytes());
        // a few bytes of zlib data: the decoder reads up to the first IDAT before sizing
        let idat = b"IDAT\x78\x9c\x63\x00\x00".to_vec();
        png.extend_from_slice(&5u32.to_be_bytes());
        png.extend_from_slice(&idat);
        png.extend_from_slice(&crc32(&idat).to_be_bytes());
        let mut r = image::ImageReader::new(std::io::Cursor::new(png)).with_guessed_format().unwrap();
        r.limits(thumb_limits());
        let res = r.decode();
        assert!(matches!(res, Err(image::ImageError::Limits(_))), "{:?}", res.map(|i| (i.width(), i.height())));
    }

    #[cfg(unix)]
    #[test]
    fn final_name_never_replaces_an_existing_file_or_link() {
        let tmp = tempfile::tempdir().unwrap();
        let d = tmp.path();
        std::fs::write(d.join("a.txt"), b"keep me").unwrap();
        std::os::unix::fs::symlink("/etc/passwd", d.join("a (1).txt")).unwrap();
        let part = d.join(".x.lumora-part");
        std::fs::write(&part, b"new").unwrap();
        let p = place_final(&part, d, "a.txt").unwrap();
        assert_eq!(p, d.join("a (2).txt"));
        assert_eq!(std::fs::read(d.join("a.txt")).unwrap(), b"keep me");
        assert!(std::fs::symlink_metadata(d.join("a (1).txt")).unwrap().file_type().is_symlink());
        assert_eq!(std::fs::read(&p).unwrap(), b"new");
        assert!(!part.exists());
    }
}
