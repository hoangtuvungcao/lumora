//! User-made sticker packs (PNG / WebP / animated GIF), content-addressed by BLAKE3.
//!
//! Sending a sticker carries its bytes inline once per message; every receiver caches it
//! by hash, so the same sticker sent a thousand times is stored once. Unused received
//! stickers are evicted after 60 days, and beyond `store::STICKER_CACHE_MAX` (~200 MB) the
//! least recently used go first — never those saved into one of your packs.

use super::*;
use crate::proto::Body;

const MAX_STATIC: usize = 512 * 1024;
const MAX_ANIMATED: usize = 1024 * 1024;

fn sniff(data: &[u8]) -> Option<(&'static str, bool)> {
    if data.starts_with(b"\x89PNG") {
        // APNG has an acTL chunk
        let animated = data.windows(4).take(4096).any(|w| w == b"acTL");
        Some(("image/png", animated))
    } else if data.starts_with(b"GIF8") {
        // more than one Graphic Control Extension ⇒ animated
        let frames = data.windows(3).filter(|w| *w == [0x21, 0xF9, 0x04]).take(2).count();
        Some(("image/gif", frames > 1))
    } else if data.len() > 12 && &data[..4] == b"RIFF" && &data[8..12] == b"WEBP" {
        let animated = data.windows(4).take(256).any(|w| w == b"ANIM");
        Some(("image/webp", animated))
    } else if data.starts_with(&[0xFF, 0xD8]) {
        Some(("image/jpeg", false))
    } else {
        None
    }
}

/// Validate / shrink an image into a sticker: static images are scaled to ≤512 px PNG.
fn prepare(path: &std::path::Path) -> Result<(String, Vec<u8>, bool)> {
    let data = std::fs::read(path).map_err(|e| crate::i18n::user_err("err.file_unreadable").detail(e))?;
    let (mime, animated) = sniff(&data).ok_or_else(|| crate::i18n::user_err("err.sticker_format"))?;
    if animated {
        anyhow::ensure!(data.len() <= MAX_ANIMATED, crate::i18n::user_err("err.image_too_large").with("max", "1 MB"));
        return Ok((mime.to_string(), data, true));
    }
    if data.len() <= MAX_STATIC && mime != "image/jpeg" {
        return Ok((mime.to_string(), data, false));
    }
    let img = image::load_from_memory(&data).map_err(|e| crate::i18n::user_err("err.image_unreadable").detail(e))?;
    let img = if img.width() > 512 || img.height() > 512 { img.thumbnail(512, 512) } else { img };
    let mut out = std::io::Cursor::new(Vec::new());
    img.write_to(&mut out, image::ImageFormat::Png)?;
    let out = out.into_inner();
    anyhow::ensure!(out.len() <= MAX_STATIC, crate::i18n::user_err("err.sticker_too_large"));
    Ok(("image/png".into(), out, false))
}

#[derive(Serialize, Deserialize)]
struct PackFile {
    v: u8,
    name: String,
    items: Vec<PackItem>,
}

#[derive(Serialize, Deserialize)]
struct PackItem {
    mime: String,
    emoji: String,
    animated: bool,
    #[serde(with = "serde_bytes")]
    data: Vec<u8>,
}

impl Node {
    pub fn sticker_pack_create(&self, name: &str) -> Result<Value> {
        let id = hex::encode(crate::crypto::random_bytes::<8>());
        let name: String = name.trim().chars().take(48).collect();
        anyhow::ensure!(!name.is_empty(), crate::i18n::user_err("err.name_empty"));
        self.store.sticker_pack_create(&id, &name)?;
        Ok(json!({"id": id, "name": name}))
    }

    pub async fn sticker_add(&self, pack: &str, path: &str, emoji: &str) -> Result<Value> {
        let p = PathBuf::from(path);
        let (mime, data, animated) = tokio::task::spawn_blocking(move || prepare(&p)).await??;
        let hash = *blake3::hash(&data).as_bytes();
        self.store.sticker_blob_put(&hash, &mime, &data)?;
        self.store.sticker_add(&hash, pack, &mime, emoji, animated)?;
        Ok(json!({"hash": hex::encode(hash), "mime": mime, "animated": animated, "bytes": data.len()}))
    }

    /// Save a sticker someone sent us into one of our packs.
    pub fn sticker_save(&self, hash_hex: &str, pack: &str) -> Result<()> {
        let hash: [u8; 32] = hex::decode(hash_hex)?.try_into().map_err(|_| anyhow!("bad hash"))?;
        let (mime, data) = self.store.sticker_blob(&hash).ok_or_else(|| crate::i18n::user_err("err.sticker_not_found"))?;
        let animated = sniff(&data).map(|(_, a)| a).unwrap_or(false);
        self.store.sticker_add(&hash, pack, &mime, "", animated)
    }

    pub async fn send_sticker(self: &Arc<Self>, conv: &str, hash_hex: &str) -> Result<Value> {
        let hash: [u8; 32] = hex::decode(hash_hex)?.try_into().map_err(|_| anyhow!("bad hash"))?;
        let (mime, data) = self.store.sticker_blob(&hash).ok_or_else(|| crate::i18n::user_err("err.sticker_not_found"))?;
        let animated = sniff(&data).map(|(_, a)| a).unwrap_or(false);
        self.store.sticker_blob_put(&hash, &mime, &data)?; // touch "used"
        let emoji = self
            .store
            .sticker_packs()?
            .iter()
            .flat_map(|p| p["stickers"].as_array().cloned().unwrap_or_default())
            .find(|s| s["hash"].as_str() == Some(hash_hex))
            .and_then(|s| s["emoji"].as_str().map(String::from))
            .unwrap_or_default();
        self.send_body(conv, Body::Sticker { pack: "custom".into(), id: String::new(), hash, mime, data, emoji, animated }, None, None).await
    }

    /// Cache the bytes of a received custom sticker (verified against its hash).
    pub(super) fn cache_sticker(&self, body: &Body) {
        if let Body::Sticker { hash, mime, data, .. } = body {
            if !data.is_empty() && data.len() <= MAX_ANIMATED && blake3::hash(data).as_bytes() == hash && sniff(data).is_some() {
                let new = !self.store.sticker_blob_has(hash);
                let _ = self.store.sticker_blob_put(hash, mime, data);
                if new {
                    // bounded cache: least recently used received stickers go first
                    let _ = self.store.sticker_cache_enforce(crate::store::STICKER_CACHE_MAX);
                }
            }
        }
    }

    pub fn sticker_pack_export(&self, pack: &str, out: &str) -> Result<Value> {
        let packs = self.store.sticker_packs()?;
        let p = packs.iter().find(|p| p["id"].as_str() == Some(pack)).ok_or_else(|| crate::i18n::user_err("err.pack_not_found"))?;
        let mut items = vec![];
        for s in p["stickers"].as_array().cloned().unwrap_or_default() {
            let h = hex::decode(s["hash"].as_str().unwrap_or(""))?;
            if let Some((mime, data)) = self.store.sticker_blob(&h) {
                items.push(PackItem { mime, emoji: s["emoji"].as_str().unwrap_or("").into(), animated: s["animated"].as_bool().unwrap_or(false), data });
            }
        }
        let f = PackFile { v: 1, name: p["name"].as_str().unwrap_or("Stickers").into(), items };
        let bytes = rmp_serde::to_vec(&f)?;
        std::fs::write(out, &bytes).map_err(|e| crate::i18n::user_err("err.file_unwritable").detail(e))?;
        Ok(json!({"path": out, "bytes": bytes.len(), "count": f.items.len()}))
    }

    pub fn sticker_pack_import(&self, path: &str) -> Result<Value> {
        let bytes = std::fs::read(path).map_err(|e| crate::i18n::user_err("err.file_unreadable").detail(e))?;
        anyhow::ensure!(bytes.len() <= 130 * 1024 * 1024, crate::i18n::user_err("err.not_sticker_pack"));
        let f: PackFile = crate::proto::from_slice_capped(&bytes).map_err(|e| crate::i18n::user_err("err.not_sticker_pack").detail(e))?;
        let created = self.sticker_pack_create(&f.name)?;
        let id = created["id"].as_str().unwrap_or("").to_string();
        let mut n = 0;
        for it in f.items.into_iter().take(120) {
            let Some((mime, animated)) = sniff(&it.data) else { continue };
            let limit = if animated { MAX_ANIMATED } else { MAX_STATIC };
            if it.data.len() > limit {
                continue;
            }
            let hash = *blake3::hash(&it.data).as_bytes();
            self.store.sticker_blob_put(&hash, mime, &it.data)?;
            self.store.sticker_add(&hash, &id, mime, &it.emoji.chars().take(8).collect::<String>(), animated)?;
            n += 1;
        }
        Ok(json!({"id": id, "name": f.name, "count": n}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn sniffing() {
        assert_eq!(sniff(b"\x89PNG\r\n\x1a\n...."), Some(("image/png", false)));
        let gif = [b"GIF89a".as_ref(), &[0x21, 0xF9, 0x04, 0, 0x21, 0xF9, 0x04]].concat();
        assert_eq!(sniff(&gif), Some(("image/gif", true)));
        assert_eq!(sniff(b"hello"), None);
    }
}
