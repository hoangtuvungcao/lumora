//! Location sharing (static + live), voice messages, contact cards and 24 h stories.

use super::*;
use crate::proto::{Body, MsgAction};
use crate::store::FileRow;

fn story_bytes(id: &[u8; 16], author: &PeerId, created: u64, text: &str, image: &[u8], bg: &str) -> Vec<u8> {
    let mut v = b"lumora-story-v1".to_vec();
    v.extend_from_slice(id);
    v.extend_from_slice(&author.0);
    v.extend_from_slice(&created.to_le_bytes());
    v.extend_from_slice(text.as_bytes());
    v.extend_from_slice(blake3::hash(image).as_bytes());
    v.extend_from_slice(bg.as_bytes());
    v
}

fn shrink_image(path: &std::path::Path, max: u32, quality: u8) -> Result<Vec<u8>> {
    let img = image::ImageReader::open(path)?.with_guessed_format()?.decode()?;
    let img = if img.width() > max || img.height() > max { img.thumbnail(max, max) } else { img };
    let mut out = std::io::Cursor::new(Vec::new());
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, quality).encode_image(&img.to_rgb8())?;
    Ok(out.into_inner())
}

impl Node {
    // ------------------------------------------------------------ location

    /// `live_minutes` = 0 → one-off location; otherwise live sharing until expiry.
    pub async fn send_location(self: &Arc<Self>, conv: &str, lat: f64, lon: f64, accuracy_m: f32, label: &str, live_minutes: u64) -> Result<Value> {
        anyhow::ensure!((-90.0..=90.0).contains(&lat) && (-180.0..=180.0).contains(&lon), crate::i18n::user_err("err.bad_location"));
        let live_until = if live_minutes > 0 { now_ms() + live_minutes.min(8 * 60) * 60_000 } else { 0 };
        self.send_body(conv, Body::Location { lat, lon, accuracy_m, label: label.chars().take(120).collect(), live_until }, None, None).await
    }

    pub async fn update_live_location(self: &Arc<Self>, conv: &str, msg_id: [u8; 16], lat: f64, lon: f64, accuracy_m: f32, stop: bool) -> Result<()> {
        let m = self.store.message(&msg_id).ok_or_else(|| crate::i18n::user_err("err.message_not_found"))?;
        anyhow::ensure!(m.kind == "location" && m.author == self.me.to_base32(), crate::i18n::user_err("err.not_your_location"));
        let until = m.body["live_until"].as_u64().unwrap_or(0);
        let stop = stop || (until > 0 && now_ms() > until);
        self.message_action(conv, msg_id, MsgAction::LiveLocation { target: msg_id, lat, lon, accuracy_m, stop }).await
    }

    // ------------------------------------------------------------ voice & contacts

    pub async fn send_voice(self: &Arc<Self>, conv: &str, path: &str, duration_ms: u32, wave: Vec<u8>) -> Result<Value> {
        let p = PathBuf::from(path);
        let meta = tokio::fs::metadata(&p).await.map_err(|e| crate::i18n::user_err("err.file_unreadable").detail(e))?;
        anyhow::ensure!(meta.len() <= 32 * 1024 * 1024, crate::i18n::user_err("err.voice_too_long"));
        let bytes = tokio::fs::read(&p).await.map_err(|e| crate::i18n::user_err("err.file_unreadable").detail(e))?;
        let hash = *blake3::hash(&bytes).as_bytes();
        let file_id: [u8; 16] = crate::crypto::random_bytes();
        let peer = match parse_conv(conv)? {
            ConvRef::Direct(p) => p,
            _ => self.me,
        };
        self.store.file_put(&FileRow {
            id: hex::encode(file_id),
            conv: conv.into(),
            peer: peer.to_base32(),
            name: format!("voice-{}.ogg", &hex::encode(file_id)[..8]),
            size: meta.len() as i64,
            hash: hex::encode(hash),
            path: p.to_string_lossy().into(),
            direction: 0,
            state: 0,
            progress: 0,
            created: now_ms() as i64,
        })?;
        let wave: Vec<u8> = wave.into_iter().take(64).collect();
        self.send_body(conv, Body::Voice { file_id, duration_ms, size: meta.len(), hash, wave }, None, None).await
    }

    pub async fn send_contact_card(self: &Arc<Self>, conv: &str, peer: PeerId) -> Result<Value> {
        let name = if peer == self.me {
            self.name()
        } else {
            self.store.contact(&peer).map(|c| c.name).unwrap_or_else(|| peer.short_id_fmt())
        };
        self.send_body(conv, Body::Contact { peer, name }, None, None).await
    }

    // ------------------------------------------------------------ stories

    pub async fn post_story(self: &Arc<Self>, text: &str, image_path: Option<&str>, bg: &str) -> Result<Value> {
        let image = match image_path {
            Some(p) if !p.is_empty() => {
                let p = PathBuf::from(p);
                tokio::task::spawn_blocking(move || shrink_image(&p, 1080, 72)).await?.map_err(|e| crate::i18n::user_err("err.image_unreadable").detail(format!("{e:#}")))?
            }
            _ => vec![],
        };
        anyhow::ensure!(!text.trim().is_empty() || !image.is_empty(), crate::i18n::user_err("err.story_empty"));
        anyhow::ensure!(image.len() <= 600 * 1024, crate::i18n::user_err("err.image_too_large").with("max", "600 KB"));
        let max = crate::store::MAX_STORIES_PER_AUTHOR;
        anyhow::ensure!(self.store.story_count(&self.me) < max, crate::i18n::user_err("err.story_limit").with("max", max));
        let id: [u8; 16] = crate::crypto::random_bytes();
        let created = now_ms();
        let text: String = text.chars().take(700).collect();
        let bg: String = bg.chars().take(40).collect();
        let sig = self.signer.sign(&story_bytes(&id, &self.me, created, &text, &image, &bg));
        self.store.story_put(&id, &self.me, created as i64, &text, &image, &bg)?;
        let msg = PeerMsg::Story { id, author: self.me, created, text, image, bg, sig };
        for f in self.store.friend_ids() {
            let mid: [u8; 16] = blake3::derive_key("lumora story slot", &[&id[..], &f.0[..]].concat())[..16].try_into().unwrap();
            self.deliver(f, mid, msg.clone(), false).await;
        }
        self.emit("story", json!({"id": hex::encode(id), "author": self.me.to_base32()}));
        Ok(json!({"id": hex::encode(id)}))
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) fn on_story(&self, from: PeerId, id: [u8; 16], author: PeerId, created: u64, text: String, image: Vec<u8>, bg: String, sig: Vec<u8>) -> Result<()> {
        anyhow::ensure!(author == from && self.store.is_friend(&from), "story from non-friend");
        anyhow::ensure!(self.verify_content(&author, &story_bytes(&id, &author, created, &text, &image, &bg), &sig), "bad story signature");
        if now_ms().saturating_sub(created) > 86_400_000 || image.len() > 600 * 1024 {
            return Ok(());
        }
        // a story dated in the future would stay up (and sort first) past its 24 h
        let created = created.min(now_ms());
        if self.store.story_put(&id, &author, created as i64, &text, &image, &bg)? {
            self.emit("story", json!({"id": hex::encode(id), "author": author.to_base32()}));
        }
        Ok(())
    }

    pub async fn story_seen(self: &Arc<Self>, id: [u8; 16]) -> Result<()> {
        self.store.story_mark_seen(&id)?;
        if let Some(author) = self.store.story_author(&id) {
            if author != self.me && !self.status_is("invisible") {
                let mid: [u8; 16] = crate::crypto::random_bytes();
                self.deliver(author, mid, PeerMsg::StorySeen { id }, false).await;
            }
        }
        Ok(())
    }

    pub(super) fn on_story_seen(&self, from: PeerId, id: [u8; 16]) -> Result<()> {
        if self.store.story_author(&id) == Some(self.me) {
            self.store.story_view(&id, &from)?;
            self.emit("story_view", json!({"id": hex::encode(id), "viewer": from.to_base32()}));
        }
        Ok(())
    }
}
