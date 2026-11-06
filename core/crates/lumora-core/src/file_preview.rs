//! Previews of non-media files shown *before* download: the first page of a PDF, the first
//! lines of a text/code file (page and line counts included).
//!
//! # Wire format (no protocol change)
//! MessagePack structs are positional, so adding a field to `Body::File` (or `ChatMsg`,
//! `MsgMeta`, …) would make older peers fail to decode the whole message, and a new
//! `MsgAction`/`PeerMsg` variant is dropped by them (plus it needs ordering, storage and
//! authorisation of its own). Instead the preview rides **inside the existing
//! `Body::File.thumb` bytes**, which until now only carried a JPEG for photos/videos:
//!
//! ```text
//! thumb = MAGIC "\0LPV" | version u8 | MessagePack MAP (rmp_serde::to_vec_named) of FilePreview
//! ```
//!
//! * Photos and videos keep a plain JPEG thumb (older apps draw it), never the container.
//! * Older apps only draw `thumb` for image/video files, so for a PDF or a `.py` they ignore
//!   it: they keep showing name + size, exactly as before.
//! * It is signed together with the message, reaches groups, offline mailboxes and forwards
//!   with no extra round trip, and arrives atomically with the file offer.
//! * The payload is map-encoded, so fields can be added later without breaking anyone
//!   (unknown keys are ignored, missing ones default).
//!
//! The receiver validates everything (`FilePreview::sanitized`): text ≤ 4 KB with control
//! characters removed (except `\n`, `\t`) as well as bidi overrides; the picture must be a
//! JPEG/PNG/WebP ≤ 64 KB. Senders should keep the whole container ≤ ~48 KB so the message
//! still fits one relay mailbox frame (64 KB) for offline delivery.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

pub const MAGIC: &[u8; 4] = b"\0LPV";
const VERSION: u8 = 1;
/// Receiver cap for the text snippet (bytes of UTF-8).
pub const MAX_TEXT: usize = 4 * 1024;
/// Receiver cap for the preview picture.
pub const MAX_IMG: usize = 64 * 1024;
/// Anything bigger than this is not a valid container.
pub const MAX_CONTAINER: usize = MAX_IMG + MAX_TEXT + 1024;
/// What senders put in the snippet (≈ the first 40–60 lines of code).
pub const SNIPPET_BYTES: usize = 2 * 1024;
/// Line counting reads at most this much of a file (bigger files report `lines = 0`).
const MAX_COUNT_BYTES: u64 = 64 << 20;

#[derive(Serialize, Deserialize, Debug, Clone, Default, PartialEq)]
#[serde(default)]
pub struct FilePreview {
    /// "pdf" | "text" | "video" | … (lowercase token; the app decides how to draw it)
    pub kind: String,
    /// First lines of a text/code file (UTF-8, sanitised).
    pub text: String,
    /// Page count (PDF), 0 = unknown.
    pub pages: u32,
    /// Line count of the whole file (text), 0 = unknown.
    pub lines: u32,
    /// Small JPEG/PNG/WebP of the first page / poster frame.
    #[serde(with = "serde_bytes")]
    pub img: Vec<u8>,
}

impl FilePreview {
    pub fn is_empty(&self) -> bool {
        self.text.is_empty() && self.img.is_empty() && self.pages == 0 && self.lines == 0
    }

    /// Enforce the caps and strip anything dangerous; `None` when nothing useful is left.
    pub fn sanitized(mut self) -> Option<Self> {
        let k: String = self.kind.trim().to_ascii_lowercase();
        self.kind = if !k.is_empty() && k.len() <= 16 && k.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-') { k } else { "file".into() };
        self.text = clean_text(&self.text, MAX_TEXT);
        if self.img.len() > MAX_IMG || !is_image(&self.img) {
            self.img.clear();
        }
        self.pages = self.pages.min(1_000_000);
        if self.is_empty() {
            None
        } else {
            Some(self)
        }
    }

    /// The bytes that go into `Body::File.thumb`.
    pub fn encode(&self) -> Vec<u8> {
        let mut v = MAGIC.to_vec();
        v.push(VERSION);
        v.extend(rmp_serde::to_vec_named(self).unwrap_or_default());
        v
    }

    /// Parse a container (any version: the payload is a map, so newer ones still decode).
    pub fn decode(b: &[u8]) -> Option<Self> {
        if b.len() > MAX_CONTAINER || b.len() < MAGIC.len() + 1 || !b.starts_with(MAGIC) {
            return None;
        }
        crate::proto::from_slice_capped::<FilePreview>(&b[MAGIC.len() + 1..]).ok()?.sanitized()
    }

    /// Fields exposed to the app next to `thumb` (the picture itself is `thumb`).
    pub fn to_json(&self) -> Value {
        json!({"kind": self.kind, "text": self.text, "pages": self.pages, "lines": self.lines})
    }

    /// API input `{kind, text, pages, lines}` (+ optional picture bytes).
    pub fn from_json(v: &Value, img: Vec<u8>) -> Option<Self> {
        let n = |k: &str| v.get(k).and_then(|x| x.as_u64()).unwrap_or(0).min(u32::MAX as u64) as u32;
        FilePreview {
            kind: v.get("kind").and_then(|x| x.as_str()).unwrap_or("").into(),
            text: v.get("text").and_then(|x| x.as_str()).unwrap_or("").into(),
            pages: n("pages"),
            lines: n("lines"),
            img,
        }
        .sanitized()
    }
}

/// Split a received `thumb` into (picture to show, preview). A plain picture passes through
/// (when within the cap); a container yields its picture and the preview.
pub fn split_thumb(thumb: &[u8]) -> (Vec<u8>, Option<FilePreview>) {
    if thumb.starts_with(MAGIC) {
        return match FilePreview::decode(thumb) {
            Some(mut p) => (std::mem::take(&mut p.img), Some(p)),
            None => (vec![], None),
        };
    }
    if thumb.len() > MAX_IMG {
        return (vec![], None);
    }
    (thumb.to_vec(), None)
}

/// JPEG, PNG or WebP magic bytes.
pub fn is_image(b: &[u8]) -> bool {
    b.starts_with(&[0xFF, 0xD8, 0xFF]) || b.starts_with(b"\x89PNG\r\n\x1a\n") || (b.len() >= 12 && &b[..4] == b"RIFF" && &b[8..12] == b"WEBP")
}

/// Unicode bidi embedding/override/isolate controls ("Trojan Source"): never shown.
fn is_bidi_control(c: char) -> bool {
    matches!(c, '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}' | '\u{200E}' | '\u{200F}' | '\u{061C}')
}

/// Normalise line ends, drop control characters except `\n`/`\t` (and bidi overrides), and
/// cut to at most `max` bytes on a character boundary.
pub fn clean_text(s: &str, max: usize) -> String {
    let mut out = String::with_capacity(s.len().min(max));
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        let c = match c {
            '\r' => {
                if chars.peek() == Some(&'\n') {
                    continue;
                }
                '\n'
            }
            '\n' | '\t' => c,
            c if c.is_control() || is_bidi_control(c) || c == '\u{FEFF}' => continue,
            c => c,
        };
        if out.len() + c.len_utf8() > max {
            break;
        }
        out.push(c);
    }
    out
}

/// Extensions previewed as text/code (HTML and SVG are text too: never rendered).
pub const TEXT_EXTS: &[&str] = &[
    "txt", "md", "markdown", "py", "js", "mjs", "cjs", "ts", "tsx", "jsx", "dart", "rs", "go", "java", "kt", "kts", "swift", "c", "cc",
    "cpp", "cxx", "h", "hh", "hpp", "cs", "rb", "php", "lua", "json", "yaml", "yml", "xml", "html", "htm", "css", "scss", "csv", "tsv", "log",
    "sh", "bash", "zsh", "ps1", "bat", "sql", "ini", "toml", "cfg", "conf", "env", "gradle", "properties", "svg", "tex", "srt", "vtt",
];

pub fn is_text_name(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    match lower.rsplit_once('.') {
        Some((stem, ext)) if !stem.is_empty() || lower.starts_with('.') => TEXT_EXTS.contains(&ext),
        _ => matches!(lower.as_str(), "makefile" | "dockerfile" | "readme" | "license"),
    }
}

/// First `max` bytes of `head` as text, or `None` when it looks binary (NUL bytes, invalid
/// UTF-8, or more than 2 % control characters) — e.g. a ZIP renamed to `.txt`.
/// The cut is UTF-8 safe and prefers a line end in the second half of the window.
pub fn snippet(head: &[u8], max: usize) -> Option<String> {
    let head = head.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(head);
    if head.contains(&0) {
        return None;
    }
    let s = match std::str::from_utf8(head) {
        Ok(s) => s,
        // a multi-byte character cut by the read window is fine; anything else is not UTF-8
        Err(e) if e.error_len().is_none() && head.len() - e.valid_up_to() < 4 => std::str::from_utf8(&head[..e.valid_up_to()]).ok()?,
        Err(_) => return None,
    };
    let total = s.chars().count();
    let ctrl = s.chars().filter(|c| c.is_control() && !matches!(c, '\n' | '\r' | '\t' | '\u{0C}' | '\u{1B}')).count();
    if total > 0 && ctrl * 50 > total {
        return None;
    }
    let mut end = s.len().min(max);
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    let mut cut = &s[..end];
    if end < s.len() {
        if let Some(i) = cut.rfind('\n') {
            if i >= end / 2 {
                cut = &cut[..i];
            }
        }
    }
    Some(clean_text(cut, max))
}

/// Core-side text preview (used when the app didn't supply one, e.g. bots and the CLI).
pub fn text_preview(path: &std::path::Path) -> Option<FilePreview> {
    use std::io::Read;
    let mut f = std::fs::File::open(path).ok()?;
    let mut head = vec![0u8; 8 * 1024];
    let mut n = 0;
    while n < head.len() {
        match f.read(&mut head[n..]) {
            Ok(0) => break,
            Ok(k) => n += k,
            Err(_) => return None,
        }
    }
    head.truncate(n);
    let text = snippet(&head, SNIPPET_BYTES)?;
    let lines = count_lines(path).unwrap_or(0);
    FilePreview { kind: "text".into(), text, lines, ..Default::default() }.sanitized()
}

/// Number of lines (a last line without `\n` counts); `None` for files over 64 MB.
pub fn count_lines(path: &std::path::Path) -> Option<u32> {
    use std::io::Read;
    let meta = std::fs::metadata(path).ok()?;
    if meta.len() > MAX_COUNT_BYTES {
        return None;
    }
    let mut f = std::fs::File::open(path).ok()?;
    let mut buf = vec![0u8; 256 * 1024];
    let (mut lines, mut last) = (0u64, b'\n');
    loop {
        let k = f.read(&mut buf).ok()?;
        if k == 0 {
            break;
        }
        lines += buf[..k].iter().filter(|&&b| b == b'\n').count() as u64;
        last = buf[k - 1];
    }
    if last != b'\n' {
        lines += 1;
    }
    Some(lines.min(u32::MAX as u64) as u32)
}

#[cfg(test)]
mod tests {
    use super::*;

    const JPEG: &[u8] = &[0xFF, 0xD8, 0xFF, 0xE0, 0, 16, b'J', b'F', b'I', b'F'];

    #[test]
    fn container_roundtrip_and_caps() {
        let p = FilePreview { kind: "pdf".into(), pages: 12, img: JPEG.to_vec(), ..Default::default() };
        let b = p.encode();
        assert!(b.starts_with(MAGIC));
        assert_eq!(FilePreview::decode(&b).unwrap(), p);
        let (img, pv) = split_thumb(&b);
        assert_eq!(img, JPEG);
        let pv = pv.unwrap();
        assert!(pv.img.is_empty() && pv.pages == 12);

        // oversized text is cut to 4 KB on a char boundary
        let big = FilePreview { kind: "text".into(), text: "ắ".repeat(5000), lines: 3, ..Default::default() };
        let got = FilePreview::decode(&big.encode()).unwrap();
        assert!(got.text.len() <= MAX_TEXT && got.text.len() > MAX_TEXT - 3);
        assert!(got.text.chars().all(|c| c == 'ắ'));

        // an oversized picture is dropped, the rest survives
        let mut huge = JPEG.to_vec();
        huge.resize(MAX_IMG + 1, 0);
        let p = FilePreview { kind: "pdf".into(), pages: 2, img: huge, ..Default::default() };
        let got = FilePreview { img: p.img.clone(), ..p.clone() }.sanitized().unwrap();
        assert!(got.img.is_empty() && got.pages == 2);

        // a container over the hard cap is rejected outright
        let mut b = MAGIC.to_vec();
        b.push(1);
        b.resize(MAX_CONTAINER + 1, 0);
        assert!(FilePreview::decode(&b).is_none());
        assert_eq!(split_thumb(&b), (vec![], None));
        // plain thumbs: within cap pass through, oversized ones are dropped
        assert_eq!(split_thumb(JPEG).0, JPEG);
        assert!(split_thumb(&vec![0xFF; MAX_IMG + 1]).0.is_empty());
        // a picture that isn't one (e.g. a script) is dropped
        let p = FilePreview { kind: "pdf".into(), pages: 1, img: b"<script>".to_vec(), ..Default::default() }.sanitized().unwrap();
        assert!(p.img.is_empty());
    }

    #[test]
    fn body_json_exposes_preview_and_wire_layout_is_unchanged() {
        use crate::proto::Body;
        let pv = FilePreview { kind: "pdf".into(), pages: 12, img: JPEG.to_vec(), ..Default::default() };
        let b = Body::File { file_id: [1; 16], name: "a.pdf".into(), size: 9, mime: "application/pdf".into(), hash: [2; 32], thumb: pv.encode(), width: 480, height: 679 };
        let j = b.to_json();
        assert_eq!(j["preview"]["pages"], 12);
        assert_eq!(j["preview"]["kind"], "pdf");
        assert_eq!(data_encoding::BASE64.decode(j["thumb"].as_str().unwrap().as_bytes()).unwrap(), JPEG);
        // same 8-element positional layout an older decoder expects
        #[derive(Deserialize)]
        #[allow(dead_code)]
        enum OldBody {
            Text { text: String },
            File { file_id: [u8; 16], name: String, size: u64, mime: String, hash: [u8; 32], #[serde(with = "serde_bytes")] thumb: Vec<u8>, width: u32, height: u32 },
        }
        let old: OldBody = crate::proto::from_slice_capped(&rmp_serde::to_vec(&b).unwrap()).unwrap();
        assert!(matches!(old, OldBody::File { width: 480, .. }));
        // a plain photo thumb has no preview key
        let photo = Body::File { file_id: [1; 16], name: "a.jpg".into(), size: 9, mime: "image/jpeg".into(), hash: [2; 32], thumb: JPEG.to_vec(), width: 1, height: 1 };
        assert!(photo.to_json().get("preview").is_none());
    }

    #[test]
    fn sanitises_control_chars_and_kind() {
        let p = FilePreview { kind: "<b>EVIL</b>".into(), text: "a\u{0}b\r\nc\u{1B}[31md\te\u{202E}f\rg".into(), ..Default::default() }.sanitized().unwrap();
        assert_eq!(p.kind, "file");
        assert_eq!(p.text, "ab\nc[31md\tef\ng");
        assert!(FilePreview { kind: "text".into(), ..Default::default() }.sanitized().is_none());
        assert_eq!(FilePreview::from_json(&json!({"kind": "TEXT", "text": "x", "lines": 9}), vec![]).unwrap().kind, "text");
    }

    #[test]
    fn future_fields_are_ignored_and_missing_ones_default() {
        #[derive(Serialize)]
        struct Future {
            kind: String,
            text: String,
            something_new: Vec<u32>,
        }
        let mut b = MAGIC.to_vec();
        b.push(7);
        b.extend(rmp_serde::to_vec_named(&Future { kind: "text".into(), text: "hi".into(), something_new: vec![1, 2] }).unwrap());
        let p = FilePreview::decode(&b).unwrap();
        assert_eq!((p.text.as_str(), p.lines, p.pages), ("hi", 0, 0));
        // garbage after the magic never panics
        for i in 0..500u32 {
            let mut g = MAGIC.to_vec();
            g.extend((0..(i % 61)).map(|j| ((i * 31 + j * 7) % 256) as u8));
            let _ = FilePreview::decode(&g);
        }
    }

    #[test]
    fn snippet_cuts_utf8_safely_and_refuses_binary() {
        // multibyte cut at the window edge
        let s = "xin chào thế giới ".repeat(200);
        let sn = snippet(s.as_bytes(), 100).unwrap();
        assert!(sn.len() <= 100 && s.starts_with(&sn));
        // a window ending mid-character (read buffer) is still text
        let b = "ếếếế".as_bytes();
        assert_eq!(snippet(&b[..b.len() - 1], 100).unwrap(), "ếếế");
        // prefers a line end in the second half
        let code = "def f():\n    return 1\n\nprint(f())\n";
        assert_eq!(snippet(code.as_bytes(), 30).unwrap(), "def f():\n    return 1\n");
        // BOM stripped, CRLF normalised
        assert_eq!(snippet(b"\xEF\xBB\xBFa\r\nb", 100).unwrap(), "a\nb");
        // binary: NUL, invalid UTF-8, lots of control chars
        assert!(snippet(b"PK\x03\x04\x14\x00\x00\x00", 100).is_none());
        assert!(snippet(&[0xC3, 0x28, b'a', b'b', b'c', b'd', b'e'], 100).is_none());
        assert!(snippet(&[0x01u8, 0x02, 0x03, b'a', b'b'], 100).is_none());
        assert_eq!(snippet(b"", 100).unwrap(), "");
    }

    #[test]
    fn text_files_and_line_counts() {
        assert!(is_text_name("main.py") && is_text_name("Cargo.TOML") && is_text_name("Makefile") && is_text_name("x.svg"));
        assert!(!is_text_name("a.pdf") && !is_text_name("py") && !is_text_name("photo.jpg"));
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("a.py");
        std::fs::write(&p, "import os\nprint(os.name)\nx = 1").unwrap();
        let pv = text_preview(&p).unwrap();
        assert_eq!((pv.kind.as_str(), pv.lines), ("text", 3));
        assert!(pv.text.starts_with("import os\n"));
        let bin = d.path().join("fake.txt");
        std::fs::write(&bin, b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR").unwrap();
        assert!(text_preview(&bin).is_none());
    }
}
