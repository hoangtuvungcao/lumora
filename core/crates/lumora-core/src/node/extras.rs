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

#[derive(serde::Serialize, serde::Deserialize, Default)]
pub(super) struct StoryDeleteMsg {
    #[serde(with = "serde_bytes", default)]
    pub id: Vec<u8>,
}

/// Synced (`privacy.*`) list of friends who never receive my Khoảnh khắc.
pub const STORY_HIDDEN_KEY: &str = "privacy.story_hidden";
/// Synced (`privacy.*`) list of my close friends (the "Bạn thân" audience).
pub const STORY_CLOSE_KEY: &str = "privacy.story_close";
/// Entries kept per list (an account has at most a few thousand friends).
const STORY_LIST_MAX: usize = 5000;

/// Who a new story goes to. The hidden list always wins.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StoryAudience {
    /// Every friend not on the hidden list.
    Friends,
    /// Only close friends (not on the hidden list).
    Close,
}

impl StoryAudience {
    pub fn parse(s: &str) -> Result<Self> {
        match s {
            "" | "friends" | "all" => Ok(StoryAudience::Friends),
            "close" | "close_friends" => Ok(StoryAudience::Close),
            _ => anyhow::bail!("unknown story audience '{s}' (friends | close)"),
        }
    }
}

/// The friends a story goes to: `friends` filtered by the audience and the hidden list.
pub(super) fn story_recipients(friends: Vec<PeerId>, audience: StoryAudience, hidden: &[PeerId], close: &[PeerId]) -> Vec<PeerId> {
    friends
        .into_iter()
        .filter(|f| !hidden.contains(f))
        .filter(|f| audience == StoryAudience::Friends || close.contains(f))
        .collect()
}

fn shrink_image(path: &std::path::Path, max: u32, quality: u8) -> Result<Vec<u8>> {
    let img = super::files::decode_upright(path)?;
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

    /// One of the synced story lists ([`STORY_HIDDEN_KEY`], [`STORY_CLOSE_KEY`]) as account ids.
    pub fn story_list(&self, key: &str) -> Vec<String> {
        self.story_peers(key).iter().map(|p| p.to_base32()).collect()
    }

    fn story_peers(&self, key: &str) -> Vec<PeerId> {
        self.store.kv_get_json::<Vec<String>>(key).unwrap_or_default().iter().filter_map(|x| PeerId::from_str_any(x).ok()).collect()
    }

    /// Replace a story list from the app: an array of account ids (bad entries skipped,
    /// duplicates removed, my own id never listed). Synced to my other devices.
    pub fn set_story_list(&self, key: &str, v: &Value) -> Result<()> {
        anyhow::ensure!(key == STORY_HIDDEN_KEY || key == STORY_CLOSE_KEY, "unknown story list");
        let arr = v.as_array().ok_or_else(|| anyhow!("story list must be an array of ids"))?;
        let mut out: Vec<String> = Vec::new();
        for p in arr.iter().filter_map(|x| x.as_str()).filter_map(|x| PeerId::from_str_any(x.trim()).ok()) {
            let b = p.to_base32();
            if p != self.me && !out.contains(&b) && out.len() < STORY_LIST_MAX {
                out.push(b);
            }
        }
        if self.store.kv_get_json::<Vec<String>>(key).unwrap_or_default() == out {
            return Ok(());
        }
        self.store.kv_set_json(key, &out)
    }

    pub async fn post_story(self: &Arc<Self>, text: &str, image_path: Option<&str>, bg: &str) -> Result<Value> {
        self.post_story_to(text, image_path, bg, StoryAudience::Friends).await
    }

    /// Post a Khoảnh khắc to `audience`; friends on my hidden list never get it.
    pub async fn post_story_to(self: &Arc<Self>, text: &str, image_path: Option<&str>, bg: &str, audience: StoryAudience) -> Result<Value> {
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
        self.store.story_mark_mine(&id)?;
        let msg = PeerMsg::Story { id, author: self.me, created, text, image, bg, sig };
        // my other devices show (and can take down) my story too
        let own = (!self.siblings().is_empty()).then_some(self.me);
        let to = story_recipients(self.store.friend_ids(), audience, &self.story_peers(STORY_HIDDEN_KEY), &self.story_peers(STORY_CLOSE_KEY));
        let sent = to.len();
        for f in to.into_iter().chain(own) {
            let mid: [u8; 16] = blake3::derive_key("lumora story slot", &[&id[..], &f.0[..]].concat())[..16].try_into().unwrap();
            self.deliver(f, mid, msg.clone(), false).await;
        }
        self.emit("story", json!({"id": hex::encode(id), "author": self.me.to_base32()}));
        Ok(json!({"id": hex::encode(id), "recipients": sent}))
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) fn on_story(&self, from: PeerId, id: [u8; 16], author: PeerId, created: u64, text: String, image: Vec<u8>, bg: String, sig: Vec<u8>) -> Result<()> {
        // a friend's story, or mine posted on another of my devices
        let own = from == self.me;
        anyhow::ensure!(author == from && (own || self.store.is_friend(&from)), "story from non-friend");
        anyhow::ensure!(self.verify_content(&author, &story_bytes(&id, &author, created, &text, &image, &bg), &sig), "bad story signature");
        if now_ms().saturating_sub(created) > 86_400_000 || image.len() > 600 * 1024 {
            return Ok(());
        }
        // a story dated in the future would stay up (and sort first) past its 24 h
        let created = created.min(now_ms());
        // taken down already (on this or another of my devices): a late copy stays out
        if self.store.story_gone(&id) {
            return Ok(());
        }
        if self.store.story_put(&id, &author, created as i64, &text, &image, &bg)? {
            if own {
                self.store.story_mark_mine(&id)?;
            }
            self.emit("story", json!({"id": hex::encode(id), "author": author.to_base32()}));
        }
        Ok(())
    }

    /// Take my story down: gone here, on my other devices and at every friend's.
    pub async fn story_delete(self: &Arc<Self>, id: [u8; 16]) -> Result<()> {
        anyhow::ensure!(self.store.story_author(&id) == Some(self.me), crate::i18n::user_err("err.story_not_yours"));
        self.store.story_delete(&id)?;
        self.emit("story_removed", json!({"id": hex::encode(id)}));
        let msg = proto::ext(proto::ext::STORY_DELETE, &StoryDeleteMsg { id: id.to_vec() });
        // my other devices only when I have some (else the copy would wait in the outbox forever)
        let own = (!self.siblings().is_empty()).then_some(self.me);
        for to in self.store.friend_ids().into_iter().chain(own) {
            let mid: [u8; 16] = blake3::derive_key("lumora story delete", &[&id[..], &to.0[..]].concat())[..16].try_into().unwrap();
            self.deliver(to, mid, msg.clone(), true).await;
        }
        Ok(())
    }

    /// `Ext STORY_DELETE` from account `from`: only the author's own story goes.
    pub(super) fn on_story_delete(&self, from: PeerId, body: &[u8]) -> Result<()> {
        let m: StoryDeleteMsg = proto::ext_body(body)?;
        let Ok(id) = <[u8; 16]>::try_from(m.id.as_slice()) else { return Ok(()) };
        if self.store.story_author(&id) == Some(from) && self.store.story_delete(&id)? {
            self.emit("story_removed", json!({"id": hex::encode(id)}));
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn story_audience_parse() {
        assert_eq!(StoryAudience::parse("friends").unwrap(), StoryAudience::Friends);
        assert_eq!(StoryAudience::parse("").unwrap(), StoryAudience::Friends);
        assert_eq!(StoryAudience::parse("close").unwrap(), StoryAudience::Close);
        assert!(StoryAudience::parse("public").is_err());
    }

    #[test]
    fn story_recipients_respect_hidden_and_close_lists() {
        let p = |i: u8| PeerId([i; 32]);
        let friends = vec![p(1), p(2), p(3), p(4)];
        let hidden = [p(2), p(9)];
        let close = [p(3), p(2), p(8)];
        // everyone minus the hidden ones
        assert_eq!(story_recipients(friends.clone(), StoryAudience::Friends, &hidden, &close), vec![p(1), p(3), p(4)]);
        // close friends only; hidden wins over close; a close "friend" who isn't a friend gets nothing
        assert_eq!(story_recipients(friends.clone(), StoryAudience::Close, &hidden, &close), vec![p(3)]);
        assert_eq!(story_recipients(friends.clone(), StoryAudience::Friends, &[], &[]), friends);
        assert!(story_recipients(friends, StoryAudience::Close, &[], &[]).is_empty());
    }
}
