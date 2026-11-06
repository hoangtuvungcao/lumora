//! "BotFather": users create child bots inside the app (like Telegram's @BotFather).
//!
//! A bot is its own identity. Its *token* bundles the bot's secret key plus an ownership
//! proof signed by the creator, so every client can show "Bot by @owner" and nobody can
//! fake it. The bot's public handle `@name·tag` is derived from the **owner + bot name**,
//! so revoking a leaked token (new key) keeps the same handle; runners holding the old
//! token notice the newer record and shut themselves down.

use super::*;
use data_encoding::BASE32_NOPAD;

const TOKEN_PREFIX: &str = "lumora_bot_";

#[derive(Serialize, Deserialize, Clone)]
pub struct BotToken {
    pub v: u8,
    #[serde(with = "serde_bytes")]
    pub secret: Vec<u8>,
    pub name: String,
    pub username: String,
    pub owner: PeerId,
    pub created: u64,
    #[serde(with = "serde_bytes")]
    pub owner_sig: Vec<u8>,
}

/// Ownership statement signed by the creator.
pub fn ownership_bytes(bot: &PeerId, username: &str, created: u64) -> Vec<u8> {
    format!("lumora-bot-owner-v1|{}|{}|{}", bot.to_base32(), username, created).into_bytes()
}

/// Stable tag for a bot handle: from owner + bot username (survives token revocation).
pub fn bot_tag(owner: &PeerId, username: &str) -> String {
    let mut h = blake3::Hasher::new_derive_key("lumora bot tag v1");
    h.update(&owner.0);
    h.update(username.as_bytes());
    BASE32_NOPAD.encode(&h.finalize().as_bytes()[..5]).to_lowercase()[..6].to_string()
}

impl BotToken {
    pub fn encode(&self) -> String {
        format!("{TOKEN_PREFIX}{}", BASE32_NOPAD.encode(&rmp_serde::to_vec(self).unwrap_or_default()).to_lowercase())
    }
    pub fn decode(s: &str) -> Result<BotToken> {
        let bad = || crate::i18n::user_err("err.bad_bot_token");
        let body = s.trim().strip_prefix(TOKEN_PREFIX).ok_or_else(|| bad().detail("missing lumora_bot_ prefix"))?;
        let raw = BASE32_NOPAD.decode(body.to_uppercase().as_bytes()).map_err(|e| bad().detail(e))?;
        let t: BotToken = crate::proto::from_slice_capped(&raw).map_err(|e| bad().detail(e))?;
        anyhow::ensure!(t.secret.len() == 32, bad().detail("bad secret length"));
        let bot = t.identity().peer_id();
        anyhow::ensure!(
            crate::devices::verify_by(&t.owner, &ownership_bytes(&bot, &t.username, t.created), &t.owner_sig).is_some(),
            bad().detail("owner signature invalid")
        );
        Ok(t)
    }
    pub fn identity(&self) -> Identity {
        let mut k = [0u8; 32];
        k.copy_from_slice(&self.secret);
        Identity::from_secret(&k)
    }
}

impl Node {
    fn my_bots(&self) -> Vec<BotToken> {
        self.store
            .kv_get("botfather.bots")
            .and_then(|v| crate::proto::from_slice_capped(&v).ok())
            .unwrap_or_default()
    }

    fn save_bots(&self, bots: &[BotToken]) -> Result<()> {
        self.store.kv_set("botfather.bots", &rmp_serde::to_vec(bots)?)
    }

    fn bot_json(&self, t: &BotToken) -> Value {
        let p = t.identity().peer_id();
        json!({
            "name": t.name, "username": t.username,
            "handle": format!("@{}·{}", t.username, bot_tag(&t.owner, &t.username)),
            "peer": p.to_base32(), "short_id": p.short_id_fmt(), "created": t.created,
        })
    }

    fn new_token(&self, name: &str, username: &str) -> BotToken {
        let bot = Identity::generate();
        let created = now_ms();
        let sig = self.signer.sign(&ownership_bytes(&bot.peer_id(), username, created));
        BotToken { v: 1, secret: bot.secret_bytes().to_vec(), name: name.into(), username: username.into(), owner: self.me, created, owner_sig: sig }
    }

    /// /newbot
    pub fn bot_create(&self, name: &str, username: &str) -> Result<Value> {
        let name: String = name.trim().chars().take(48).collect();
        let username = username.trim().trim_start_matches('@').to_lowercase();
        anyhow::ensure!(!name.is_empty(), crate::i18n::user_err("err.name_empty"));
        anyhow::ensure!(crate::net::nostr::valid_username(&username), crate::i18n::user_err("err.username_invalid"));
        anyhow::ensure!(username.ends_with("bot"), crate::i18n::user_err("err.bot_username_suffix"));
        let mut bots = self.my_bots();
        anyhow::ensure!(bots.len() < 20, crate::i18n::user_err("err.bot_limit").with("max", 20));
        anyhow::ensure!(!bots.iter().any(|b| b.username == username), crate::i18n::user_err("err.bot_exists"));
        let t = self.new_token(&name, &username);
        bots.push(t.clone());
        self.save_bots(&bots)?;
        let mut v = self.bot_json(&t);
        v["token"] = json!(t.encode());
        Ok(v)
    }

    /// /mybots
    pub fn bot_list(&self) -> Vec<Value> {
        self.my_bots().iter().map(|t| self.bot_json(t)).collect()
    }

    pub fn bot_token(&self, username: &str) -> Result<String> {
        self.my_bots().into_iter().find(|b| b.username == username).map(|t| t.encode()).ok_or_else(|| crate::i18n::user_err("err.bot_not_found").into())
    }

    /// /revoke — new key + token, same @handle; old runners stop by themselves.
    pub fn bot_revoke(&self, username: &str) -> Result<Value> {
        let mut bots = self.my_bots();
        let i = bots.iter().position(|b| b.username == username).ok_or_else(|| crate::i18n::user_err("err.bot_not_found"))?;
        let name = bots[i].name.clone();
        bots[i] = self.new_token(&name, username);
        self.save_bots(&bots)?;
        let mut v = self.bot_json(&bots[i]);
        v["token"] = json!(bots[i].encode());
        Ok(v)
    }

    /// /deletebot — forget it and tombstone its directory entry.
    pub fn bot_delete(&self, username: &str) -> Result<()> {
        let mut bots = self.my_bots();
        let Some(i) = bots.iter().position(|b| b.username == username) else { anyhow::bail!(crate::i18n::user_err("err.bot_not_found")) };
        let t = bots.remove(i);
        self.save_bots(&bots)?;
        if let Some(pool) = self.net.nostr.read().clone() {
            pool.unpublish_user_as(&t.identity(), username);
        }
        Ok(())
    }

    /// Runner side: apply the token's identity facts (name, username, ownership proof).
    pub fn apply_bot_token(&self, t: &BotToken) -> Result<()> {
        anyhow::ensure!(t.identity().peer_id() == self.me, crate::i18n::user_err("err.bot_token_mismatch"));
        self.store.kv_set_json(
            "bot.owner",
            &json!({"owner": t.owner.to_base32(), "username": t.username, "created": t.created, "sig": hex::encode(&t.owner_sig)}),
        )?;
        self.set_name(&t.name)?;
        self.store.kv_set("profile.username", t.username.as_bytes())?;
        if !self.is_bot() {
            self.set_bot(vec![], vec![], "", true)?;
        }
        Ok(())
    }

    /// Ownership proof as published in the bot's profile / directory record.
    pub fn bot_owner_proof(&self) -> Option<Value> {
        self.store.kv_get_json::<Value>("bot.owner")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn token_roundtrip_and_forgery() {
        let owner = Identity::generate();
        let bot = Identity::generate();
        let created = 123;
        let sig = owner.sign(&ownership_bytes(&bot.peer_id(), "shop_bot", created)).to_vec();
        let t = BotToken { v: 1, secret: bot.secret_bytes().to_vec(), name: "Shop".into(), username: "shop_bot".into(), owner: owner.peer_id(), created, owner_sig: sig };
        let back = BotToken::decode(&t.encode()).unwrap();
        assert_eq!(back.identity().peer_id(), bot.peer_id());
        let mut forged = t.clone();
        forged.username = "other_bot".into();
        assert!(BotToken::decode(&forged.encode()).is_err());
        assert_eq!(bot_tag(&owner.peer_id(), "shop_bot").len(), 6);
    }
}
