//! Community 2.0 on the node (docs/src/dev/community2-contract.md): roles, channel
//! settings, timeouts, ownership transfer, invite links (ids, revocation, "approve new
//! members"), invitations waiting for my answer ("who can add me") and the privacy
//! choices "who can call me" / "who sees me online" / "mentions only".
//!
//! The rules themselves are enforced by every member's fold (`crate::group`); the checks
//! here only turn a refusal into the right message before anything is sent.

use super::*;
use crate::community::{self as cm, perm};
use crate::group::{clean_channel_name, GroupOp, Payload, Role};

/// "Who can call me": everyone | friends | nobody (account setting, synced).
pub const WHO_CAN_CALL_KEY: &str = "privacy.calls";
/// "Who can add me to groups": friends | nobody — others' invitations wait for my answer.
pub const WHO_CAN_ADD_KEY: &str = "privacy.group_add";
/// "Who sees me online": friends | nobody.
pub const WHO_SEES_ONLINE_KEY: &str = "privacy.online";
/// Muted chats that still notify @mentions / replies to me (JSON list of convs, synced).
pub const MENTIONS_ONLY_KEY: &str = "privacy.mentions_only";
/// Invitations waiting for my answer (this device: every device gets its own sealed copy).
const INVITES_KEY: &str = "group.invites";
const MAX_INVITES: usize = 50;
const MAX_INVITES_PER_SENDER: usize = 5;
/// Join requests ("approve new members") this device received as the link's inviter.
const JOIN_REQ_PREFIX: &str = "group.joinreq.";
const MAX_JOIN_REQUESTS: usize = 200;
/// Invite links made on this device.
const LINKS_PREFIX: &str = "group.links.";
const MAX_LINKS: usize = 100;
/// Calls from strangers (with "everyone"): a few per caller, then dropped.
const STRANGER_CALLS_PER_10MIN: usize = 3;

type StrangerCalls = HashMap<(PeerId, PeerId), Vec<Instant>>;
static STRANGER_CALLS: Mutex<Option<StrangerCalls>> = parking_lot::const_mutex(None);

/// Group calls I may join without having been rung, per (this device, call id):
/// (conv, the caller's device, video).
type Available = HashMap<(PeerId, [u8; 16]), (String, PeerId, bool)>;
static AVAILABLE: Mutex<Option<Available>> = parking_lot::const_mutex(None);

/// `Ext GROUP_JOIN_DENIED`: the inviter turned an invite-link join down (`reason`:
/// revoked | removed | denied).
#[derive(Serialize, Deserialize, Default)]
pub(crate) struct JoinDeniedMsg {
    #[serde(default, with = "serde_bytes")]
    pub gid: Vec<u8>,
    #[serde(default)]
    pub reason: String,
}

/// `Ext GROUP_JOIN_REQUEST`: a join request (or its end, `drop`) kept by the link's
/// inviter, copied to every other admin holding `invite` (and my own other devices), so
/// any of them can approve or decline it. Carries no address of anyone.
#[derive(Serialize, Deserialize, Default)]
pub(crate) struct JoinRequestFwd {
    #[serde(default, with = "serde_bytes")]
    pub gid: Vec<u8>,
    #[serde(default, with = "serde_bytes")]
    pub peer: Vec<u8>,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub at: u64,
    #[serde(default)]
    pub drop: bool,
}

/// `Ext CALL_AVAILABLE`: a plain group call that doesn't ring this member — it may join.
#[derive(Serialize, Deserialize, Default)]
pub(crate) struct CallAvailableMsg {
    #[serde(default, with = "serde_bytes")]
    pub call_id: Vec<u8>,
    #[serde(default, with = "serde_bytes")]
    pub gid: Vec<u8>,
    #[serde(default)]
    pub video: bool,
}

#[derive(Serialize, Deserialize, Clone)]
struct PendingInvite {
    gid: String,
    name: String,
    kind: u8,
    by: String,
    by_name: String,
    at: u64,
    members: usize,
    /// the device it came from, and the welcome (sealed copy already opened)
    from: String,
    #[serde(with = "serde_bytes")]
    body: Vec<u8>,
}

#[derive(Serialize, Deserialize, Clone)]
struct MyLink {
    id: String,
    link: String,
    created: u64,
    expires: u64,
}

fn gid_hex(g: &Gid) -> String {
    hex::encode(g)
}

fn no_perm() -> anyhow::Error {
    crate::i18n::user_err("err.no_permission").into()
}

fn arg_s<'a>(v: &'a Value, k: &str) -> Result<&'a str> {
    v.get(k).and_then(|x| x.as_str()).ok_or_else(|| anyhow!("missing '{k}'"))
}

fn arg_gid(v: &Value) -> Result<Gid> {
    let h = hex::decode(arg_s(v, "gid")?)?;
    h.try_into().map_err(|_| anyhow!("'gid' must be 32 hex chars"))
}

fn arg_peer(v: &Value, k: &str) -> Result<PeerId> {
    PeerId::from_str_any(arg_s(v, k)?)
}

fn arg_strs(v: &Value, k: &str) -> Option<Vec<String>> {
    v.get(k).and_then(|x| x.as_array()).map(|a| a.iter().filter_map(|x| x.as_str()).map(String::from).collect())
}

/// Community 2.0 commands (and the ones it extends); None: not one of them.
pub async fn community_api(node: &Arc<Node>, cmd: &str, r: &Value) -> Result<Option<Value>> {
    let opt_s = |k: &str| r.get(k).and_then(|x| x.as_str()).map(String::from);
    let opt_b = |k: &str| r.get(k).and_then(|x| x.as_bool());
    let opt_u = |k: &str| r.get(k).and_then(|x| x.as_u64());
    Ok(Some(match cmd {
        "group_roles" => Value::Array(node.group_roles_json(&node.group_live(&arg_gid(r)?)?)),
        "group_role_set" => {
            let perms = arg_strs(r, "perms").unwrap_or_default();
            node.group_role_set(arg_gid(r)?, opt_s("id"), opt_s("name").unwrap_or_default(), opt_s("color"), &perms, opt_u("position").map(|p| p as u32)).await?
        }
        "group_role_delete" => {
            node.group_role_delete(arg_gid(r)?, arg_s(r, "id")?).await?;
            Value::Null
        }
        "group_member_roles" => {
            node.group_member_roles(arg_gid(r)?, arg_peer(r, "peer")?, arg_strs(r, "roles").unwrap_or_default()).await?;
            Value::Null
        }
        "group_timeout" => {
            node.group_timeout(arg_gid(r)?, arg_peer(r, "peer")?, opt_u("until_ms").unwrap_or(0)).await?;
            Value::Null
        }
        "group_channel_update" => {
            let op = GroupOp::ChannelUpdate {
                name: arg_s(r, "name")?.to_string(),
                new_name: opt_s("new_name"),
                topic: opt_s("topic"),
                category: opt_s("category"),
                position: opt_u("position").map(|p| p as u32),
                private: opt_b("private"),
                allow_roles: arg_strs(r, "allow_roles"),
                announce: opt_b("announce"),
            };
            node.group_channel_update(arg_gid(r)?, op).await?;
            Value::Null
        }
        "group_channel" => {
            node.group_channel_ex(arg_gid(r)?, arg_s(r, "name")?, opt_b("voice").unwrap_or(false), opt_b("remove").unwrap_or(false), opt_s("category"), opt_s("topic")).await?;
            Value::Null
        }
        "group_transfer_owner" => {
            node.group_transfer_owner(arg_gid(r)?, arg_peer(r, "peer")?).await?;
            Value::Null
        }
        "create_invite" => node.create_invite_link(arg_gid(r)?, opt_u("hours").unwrap_or(168))?,
        "group_invite_links" => Value::Array(node.group_invite_links(&arg_gid(r)?)?),
        "group_revoke_invite" => {
            node.group_revoke_invite(arg_gid(r)?, opt_s("id")).await?;
            Value::Null
        }
        "group_join_deny" => {
            node.group_join_deny(arg_gid(r)?, arg_peer(r, "peer")?)?;
            Value::Null
        }
        "group_settings" => {
            let gid = arg_gid(r)?;
            if let Some(on) = opt_b("approve_joins") {
                node.group_join_approval(gid, on).await?;
            }
            if r.get("slow_mode_s").is_some() || r.get("admins_only").is_some() {
                node.group_settings(gid, opt_u("slow_mode_s").map(|x| x as u32), opt_b("admins_only")).await?;
            }
            Value::Null
        }
        "group_invites" => Value::Array(node.group_invites()),
        "group_invite_answer" => node.group_invite_answer(arg_gid(r)?, opt_b("accept").unwrap_or(false)).await?,
        "call_answer" => {
            // a call offered with a "Join" banner: joining makes it an incoming call that
            // is answered at once; dismissing it is local (nothing is sent)
            let id: [u8; 16] = hex::decode(arg_s(r, "call_id")?)?.try_into().map_err(|_| anyhow!("bad call id"))?;
            let Some((conv, from, video)) = AVAILABLE.lock().as_mut().and_then(|m| m.remove(&(node.device, id))) else { return Ok(None) };
            // it also rings here (e.g. invited after the banner): the normal answer, never
            // a silent no-op
            if node.remote.calls.lock().contains_key(&id) {
                return Ok(None);
            }
            if opt_b("accept").unwrap_or(true) {
                node.remote.calls.lock().insert(id, node.available_as_incoming(id, conv, from, video));
                return Ok(None); // the normal answer follows
            }
            Value::Null
        }
        "call_start" => {
            let ring = r.get("ring").and_then(|x| x.as_array()).map(|a| a.iter().filter_map(|x| x.as_str()).filter_map(|x| PeerId::from_str_any(x).ok()).collect::<Vec<_>>());
            node.call_start_ring(arg_s(r, "conv")?, opt_b("video").unwrap_or(false), ring).await?
        }
        _ => return Ok(None),
    }))
}

impl Node {
    /// A group I'm in, not dissolved.
    pub(crate) fn group_live(&self, gid: &Gid) -> Result<GroupState> {
        let g = self.groups.read().get(gid).cloned().ok_or_else(|| crate::i18n::user_err("err.group_not_found"))?;
        anyhow::ensure!(!g.dissolved(), crate::i18n::user_err("err.group_not_found"));
        anyhow::ensure!(g.is_member(&self.me), crate::i18n::user_err("err.not_member"));
        Ok(g)
    }

    // ------------------------------------------------------------ privacy choices

    fn privacy_choice(&self, key: &str, allowed: &[&str], default: &str) -> String {
        self.store.kv_get(key).and_then(|v| String::from_utf8(v).ok()).filter(|v| allowed.contains(&v.as_str())).unwrap_or_else(|| default.to_string())
    }

    pub(crate) fn who_can_call(&self) -> String {
        self.privacy_choice(WHO_CAN_CALL_KEY, &["everyone", "friends", "nobody"], "friends")
    }

    pub(crate) fn who_can_add(&self) -> String {
        self.privacy_choice(WHO_CAN_ADD_KEY, &["friends", "nobody"], "friends")
    }

    pub(crate) fn who_sees_online(&self) -> String {
        self.privacy_choice(WHO_SEES_ONLINE_KEY, &["friends", "nobody"], "friends")
    }

    /// `None`: never set on this account (the app's own list fills it); `Some([])`: cleared.
    pub(crate) fn mentions_only(&self) -> Option<Vec<String>> {
        self.store.kv_get_json(MENTIONS_ONLY_KEY)
    }

    /// `settings_set` for the privacy choices; true if one of them was given.
    pub(crate) fn set_privacy_choices(&self, r: &Value) -> Result<bool> {
        let mut any = false;
        for (k, key, allowed) in [
            ("who_can_call", WHO_CAN_CALL_KEY, &["everyone", "friends", "nobody"][..]),
            ("who_can_add", WHO_CAN_ADD_KEY, &["friends", "nobody"][..]),
            ("who_sees_online", WHO_SEES_ONLINE_KEY, &["friends", "nobody"][..]),
        ] {
            if let Some(v) = r.get(k).and_then(|x| x.as_str()) {
                anyhow::ensure!(allowed.contains(&v), "'{k}' must be one of {}", allowed.join("|"));
                self.store.kv_set(key, v.as_bytes())?;
                any = true;
                if k == "who_sees_online" {
                    // friends see the change now (profile status "offline" for "nobody")
                    self.set_profile(None, None, None, None)?;
                }
            }
        }
        if let Some(list) = r.get("mentions_only").and_then(|x| x.as_array()) {
            let mut convs: Vec<String> = vec![];
            for c in list.iter().filter_map(|x| x.as_str()) {
                if !c.is_empty() && c.len() <= 200 && !convs.iter().any(|x| x == c) && convs.len() < 1000 {
                    convs.push(c.to_string());
                }
            }
            self.store.kv_set_json(MENTIONS_ONLY_KEY, &convs)?;
            any = true;
        }
        Ok(any)
    }

    /// Does "who can call me" let `acct` call here at all? (no rate limit, no side effect:
    /// a peer it refuses leaves no trace here — no ringing, no call log line, no chat)
    pub(crate) fn call_permitted_from(&self, acct: &PeerId) -> bool {
        if *acct == self.me {
            return true;
        }
        match self.who_can_call().as_str() {
            "nobody" => false,
            "everyone" => true,
            _ => self.store.is_friend(acct),
        }
    }

    /// May `acct`'s call ring here? ("who can call me"; strangers are also rate limited)
    pub(crate) fn call_allowed_from(&self, acct: &PeerId) -> bool {
        if *acct == self.me {
            return true;
        }
        let friend = self.store.is_friend(acct);
        match self.who_can_call().as_str() {
            "nobody" => false,
            "everyone" if !friend => {
                let mut g = STRANGER_CALLS.lock();
                let m = g.get_or_insert_with(HashMap::new);
                if m.len() > 1024 {
                    m.retain(|_, v| v.iter().any(|t| t.elapsed() < Duration::from_secs(600)));
                }
                let v = m.entry((self.me, *acct)).or_default();
                v.retain(|t| t.elapsed() < Duration::from_secs(600));
                if v.len() >= STRANGER_CALLS_PER_10MIN {
                    return false;
                }
                v.push(Instant::now());
                true
            }
            "everyone" => true,
            _ => friend,
        }
    }

    /// Does `p` show as online to me? Only friends ever do (everyone's choice is "friends"
    /// or "nobody"), and not while their status says offline ("nobody" / invisible).
    pub(crate) fn shows_online(&self, p: &PeerId) -> bool {
        if *p == self.me {
            return true;
        }
        if !self.is_online(p) {
            return false;
        }
        match self.store.contact(p) {
            Some(c) => c.status == 3 && c.presence != "offline",
            None => false,
        }
    }

    // ------------------------------------------------------------ roles

    pub(crate) fn group_roles_json(&self, g: &GroupState) -> Vec<Value> {
        let n = g.ext.roles.len() as u32;
        let mut out = vec![json!({"id": cm::ADMIN, "name": crate::i18n::tr("role.admin"), "color": cm::ADMIN_COLOR,
                                  "perms": perm::names(perm::ALL), "position": n + 1, "builtin": true})];
        for (i, r) in g.ext.roles.iter().enumerate().rev() {
            out.push(json!({"id": r.id, "name": r.name, "color": r.color, "perms": perm::names(r.perms), "position": i as u32 + 1, "builtin": false}));
        }
        out.push(json!({"id": cm::EVERYONE, "name": "@everyone", "color": cm::DEFAULT_COLOR,
                        "perms": perm::names(g.ext.everyone_perms(g.kind)), "position": 0, "builtin": true}));
        out
    }

    /// What `group_info` adds for Community 2.0 (roles, my permissions, join requests).
    pub(crate) fn community_info(&self, g: &GroupState, v: &mut Value) {
        v["roles"] = Value::Array(self.group_roles_json(g));
        v["my_perms"] = json!(perm::names(g.perms_of(&self.me)));
        v["approve_joins"] = json!(g.ext.approve_joins);
        let reqs: Vec<Value> = if g.has(&self.me, perm::INVITE) {
            self.join_requests(&g.gid).into_iter().filter(|r| r["peer"].as_str().and_then(|p| PeerId::from_str_any(p).ok()).is_some_and(|p| !g.is_member(&p))).collect()
        } else {
            vec![]
        };
        v["join_requests"] = Value::Array(reqs);
    }

    pub async fn group_role_set(self: &Arc<Self>, gid: Gid, id: Option<String>, name: String, color: Option<String>, perms: &[String], position: Option<u32>) -> Result<Value> {
        let g = self.group_live(&gid)?;
        if !g.has(&self.me, perm::MANAGE_ROLES) {
            return Err(no_perm());
        }
        let mine = g.perms_of(&self.me);
        let mut bits = perm::from_names(perms);
        let id = match id.filter(|i| !i.is_empty()) {
            Some(i) if i == cm::ADMIN => bail!(crate::i18n::user_err("err.builtin_role")),
            Some(i) if i == cm::EVERYONE => {
                if g.kind == 1 {
                    bits &= !perm::MANAGE_COMMUNITY;
                }
                if (bits & !g.ext.everyone_perms(g.kind)) & !mine != 0 {
                    return Err(no_perm());
                }
                self.publish(gid, Payload::Op(GroupOp::RoleSet { id: i.clone(), name: String::new(), color: String::new(), perms: bits, position: None })).await?;
                return Ok(json!({"id": i}));
            }
            Some(i) if i.starts_with(cm::ADMIN_RIGHTS_PREFIX) => {
                PeerId::from_str_any(&i[cm::ADMIN_RIGHTS_PREFIX.len()..])?;
                if g.role(&self.me) != Some(Role::Owner) {
                    return Err(no_perm());
                }
                i
            }
            Some(i) => {
                anyhow::ensure!(g.ext.role(&i).is_some(), crate::i18n::user_err("err.role_not_found"));
                i
            }
            None => format!("r_{}", hex::encode(crate::crypto::random_bytes::<6>())),
        };
        let existing = g.ext.role(&id).cloned();
        if existing.is_none() && !id.starts_with(cm::ADMIN_RIGHTS_PREFIX) {
            anyhow::ensure!(!name.trim().is_empty(), crate::i18n::user_err("err.bad_name"));
            anyhow::ensure!(g.ext.roles.len() < cm::MAX_ROLES, crate::i18n::user_err("err.too_many_roles"));
        }
        if (bits & !existing.as_ref().map(|r| r.perms).unwrap_or(0)) & !mine != 0 {
            return Err(no_perm()); // nobody grants what they don't hold
        }
        let color = color.or_else(|| existing.map(|r| r.color)).unwrap_or_else(|| cm::DEFAULT_COLOR.to_string());
        self.publish(gid, Payload::Op(GroupOp::RoleSet { id: id.clone(), name, color, perms: bits, position })).await?;
        Ok(json!({"id": id}))
    }

    pub async fn group_role_delete(self: &Arc<Self>, gid: Gid, id: &str) -> Result<()> {
        let g = self.group_live(&gid)?;
        anyhow::ensure!(id != cm::ADMIN && id != cm::EVERYONE, crate::i18n::user_err("err.builtin_role"));
        if !g.has(&self.me, perm::MANAGE_ROLES) || (id.starts_with(cm::ADMIN_RIGHTS_PREFIX) && g.role(&self.me) != Some(Role::Owner)) {
            return Err(no_perm());
        }
        anyhow::ensure!(g.ext.role(id).is_some(), crate::i18n::user_err("err.role_not_found"));
        self.publish(gid, Payload::Op(GroupOp::RoleDelete { id: id.to_string() })).await?;
        Ok(())
    }

    pub async fn group_member_roles(self: &Arc<Self>, gid: Gid, peer: PeerId, roles: Vec<String>) -> Result<()> {
        let g = self.group_live(&gid)?;
        if !g.has(&self.me, perm::MANAGE_ROLES) {
            return Err(no_perm());
        }
        anyhow::ensure!(g.is_member(&peer), crate::i18n::user_err("err.not_member"));
        self.publish(gid, Payload::Op(GroupOp::MemberRoles { peer, roles })).await?;
        Ok(())
    }

    pub async fn group_timeout(self: &Arc<Self>, gid: Gid, peer: PeerId, until_ms: u64) -> Result<()> {
        let g = self.group_live(&gid)?;
        anyhow::ensure!(g.is_member(&peer), crate::i18n::user_err("err.not_member"));
        if !g.has(&self.me, perm::TIMEOUT) || !g.may_moderate(&self.me, &peer) {
            return Err(no_perm());
        }
        self.publish(gid, Payload::Op(GroupOp::Timeout { peer, until_ms })).await?;
        Ok(())
    }

    /// `op`: a `ChannelUpdate` naming the channel by the name it shows (or its key).
    pub async fn group_channel_update(self: &Arc<Self>, gid: Gid, op: GroupOp) -> Result<()> {
        let g = self.group_live(&gid)?;
        if !g.has(&self.me, perm::MANAGE_CHANNELS) {
            return Err(no_perm());
        }
        let GroupOp::ChannelUpdate { name, new_name, topic, category, position, private, allow_roles, announce } = op else { bail!("not a channel update") };
        let key = g.channel_key(&name).map(|c| c.name.clone()).ok_or_else(|| crate::i18n::user_err("err.channel_not_found"))?;
        let new_name = new_name.map(|n| clean_channel_name(&n)).filter(|n| !n.is_empty());
        if let Some(n) = &new_name {
            if g.channel_key(n).is_some_and(|c| c.name != key) {
                bail!(crate::i18n::user_err("err.channel_exists"));
            }
        }
        self.publish(gid, Payload::Op(GroupOp::ChannelUpdate { name: key, new_name, topic, category, position, private, allow_roles, announce })).await?;
        Ok(())
    }

    /// Create (with an optional category / topic) or remove a channel.
    pub async fn group_channel_ex(self: &Arc<Self>, gid: Gid, name: &str, voice: bool, remove: bool, category: Option<String>, topic: Option<String>) -> Result<()> {
        let g = self.group_live(&gid)?;
        if !g.has(&self.me, perm::MANAGE_CHANNELS) {
            return Err(no_perm());
        }
        if remove {
            let key = g.channel_key(name).map(|c| c.name.clone()).ok_or_else(|| crate::i18n::user_err("err.channel_not_found"))?;
            self.publish(gid, Payload::Op(GroupOp::Channel { name: key, voice, remove: true })).await?;
            return Ok(());
        }
        let shown = clean_channel_name(name);
        anyhow::ensure!(!shown.is_empty(), crate::i18n::user_err("err.channel_empty"));
        anyhow::ensure!(g.channel_key(&shown).is_none(), crate::i18n::user_err("err.channel_exists"));
        // the key names its conversation for good: a renamed channel may still hold this one
        let key = if g.channels.iter().any(|c| c.name == shown) { format!("{}~{}", shown.chars().take(24).collect::<String>(), hex::encode(crate::crypto::random_bytes::<2>())) } else { shown.clone() };
        self.publish(gid, Payload::Op(GroupOp::Channel { name: key.clone(), voice, remove: false })).await?;
        let category = category.filter(|c| !c.trim().is_empty());
        let topic = topic.filter(|t| !t.trim().is_empty());
        if key != shown || category.is_some() || topic.is_some() {
            let new_name = (key != shown).then_some(shown);
            self.publish(gid, Payload::Op(GroupOp::ChannelUpdate { name: key, new_name, topic, category, position: None, private: None, allow_roles: None, announce: None })).await?;
        }
        Ok(())
    }

    pub async fn group_transfer_owner(self: &Arc<Self>, gid: Gid, peer: PeerId) -> Result<()> {
        let g = self.group_live(&gid)?;
        anyhow::ensure!(g.role(&self.me) == Some(Role::Owner), crate::i18n::user_err("err.owner_only"));
        anyhow::ensure!(peer != self.me && g.is_member(&peer) && !g.bots.contains_key(&peer), crate::i18n::user_err("err.not_member"));
        self.publish(gid, Payload::Op(GroupOp::TransferOwner { peer })).await?;
        Ok(())
    }

    pub async fn group_join_approval(self: &Arc<Self>, gid: Gid, on: bool) -> Result<()> {
        let g = self.group_live(&gid)?;
        anyhow::ensure!(g.has(&self.me, perm::MANAGE_COMMUNITY), crate::i18n::user_err("err.admin_only"));
        if g.ext.approve_joins != on {
            self.publish(gid, Payload::Op(GroupOp::JoinApproval { on })).await?;
        }
        if !on {
            let _ = self.store.kv_del(&format!("{JOIN_REQ_PREFIX}{}", gid_hex(&gid)));
        }
        Ok(())
    }

    // ------------------------------------------------------------ invite links

    /// A new invite link (needs `invite`): `{id, link, created, expires}`.
    pub fn create_invite_link(&self, gid: Gid, hours: u64) -> Result<Value> {
        let g = self.group_live(&gid)?;
        if !g.has(&self.me, perm::INVITE) {
            return Err(crate::i18n::user_err(if g.kind == 1 { "err.admin_only_add" } else { "err.no_permission" }).into());
        }
        let (link, sig, expires) = self.sign_invite(&g, hours)?;
        let l = MyLink { id: hex::encode(cm::invite_id(&sig)), link, created: now_ms(), expires };
        let key = format!("{LINKS_PREFIX}{}", gid_hex(&gid));
        let mut all: Vec<MyLink> = self.store.kv_get_json(&key).unwrap_or_default();
        all.retain(|x| x.expires > now_ms());
        all.push(l.clone());
        if all.len() > MAX_LINKS {
            all.drain(..all.len() - MAX_LINKS);
        }
        self.store.kv_set_json(&key, &all)?;
        Ok(serde_json::to_value(l)?)
    }

    pub(crate) fn invite_created(&self, gid: &Gid, id: &[u8; 8]) -> Option<u64> {
        let all: Vec<MyLink> = self.store.kv_get_json(&format!("{LINKS_PREFIX}{}", gid_hex(gid))).unwrap_or_default();
        let id = hex::encode(id);
        all.into_iter().find(|l| l.id == id).map(|l| l.created)
    }

    /// The live invite links I made for `gid`.
    pub fn group_invite_links(&self, gid: &Gid) -> Result<Vec<Value>> {
        let g = self.group_live(gid)?;
        let all: Vec<MyLink> = self.store.kv_get_json(&format!("{LINKS_PREFIX}{}", gid_hex(gid))).unwrap_or_default();
        let now = now_ms();
        Ok(all
            .into_iter()
            .filter(|l| {
                let id: [u8; 8] = hex::decode(&l.id).ok().and_then(|b| b.try_into().ok()).unwrap_or([0; 8]);
                l.expires > now && !g.invite_revoked(&id, Some(l.created), l.expires)
            })
            .filter_map(|l| serde_json::to_value(l).ok())
            .collect())
    }

    /// Revoke link `id` (hex), or every link made so far (needs `invite`).
    pub async fn group_revoke_invite(self: &Arc<Self>, gid: Gid, id: Option<String>) -> Result<()> {
        let g = self.group_live(&gid)?;
        if !g.has(&self.me, perm::INVITE) {
            return Err(no_perm());
        }
        let id = match id.filter(|i| !i.is_empty()) {
            Some(h) => Some(<[u8; 8]>::try_from(hex::decode(&h)?.as_slice()).map_err(|_| anyhow!("'id' must be 16 hex chars"))?),
            None => None,
        };
        // every link at once (others' too): managing the community
        if id.is_none() && !g.has(&self.me, perm::MANAGE_COMMUNITY) {
            return Err(no_perm());
        }
        self.publish(gid, Payload::Op(GroupOp::RevokeInvite { id })).await?;
        Ok(())
    }

    /// Someone used one of my links (signature already checked). Admits them, keeps the
    /// request for approval, or turns it down.
    pub(crate) async fn admit_by_link(self: &Arc<Self>, from: PeerId, gid: Gid, expires: u64, sig: &[u8]) -> Result<()> {
        let Some(g) = self.groups.read().get(&gid).cloned() else { return Ok(()) };
        if g.dissolved() || !g.is_member(&self.me) || g.is_member(&from) || self.store.is_blocked(&from) {
            return Ok(());
        }
        let id = cm::invite_id(sig);
        let reason = if g.invite_revoked(&id, self.invite_created(&gid, &id), expires) || !g.has(&self.me, perm::INVITE) {
            Some("revoked")
        } else if g.banned.contains(&from) || g.removed_by_admin(&from) {
            Some("removed")
        } else {
            None
        };
        if let Some(reason) = reason {
            self.send_join_denied(from, gid, reason);
            return Ok(());
        }
        // (a leaked link must not let a flood of fresh identities join without bound)
        if !self.join_allowed(&gid) {
            return Ok(());
        }
        if g.ext.approve_joins {
            let key = format!("{JOIN_REQ_PREFIX}{}", gid_hex(&gid));
            let mut reqs: Vec<Value> = self.store.kv_get_json(&key).unwrap_or_default();
            let p = from.to_base32();
            if !reqs.iter().any(|r| r["peer"].as_str() == Some(p.as_str())) {
                let (name, at) = (self.display(&from), now_ms());
                // (`direct`: the joiner asked me — I'm the one who tells it a "no")
                reqs.push(json!({"peer": p, "name": name, "at": at, "direct": true}));
                if reqs.len() > MAX_JOIN_REQUESTS {
                    reqs.remove(0);
                }
                self.store.kv_set_json(&key, &reqs)?;
                self.emit("group_join_request", json!({"gid": gid_hex(&gid), "peer": p, "name": name}));
                if let Ok(v) = self.group_info(&gid) {
                    self.emit("group", v);
                }
                // every other admin with `invite` sees it too (not only the link's maker)
                self.forward_join_request(&g, from, name, at, false);
            }
            return Ok(());
        }
        self.group_add(gid, from).await
    }

    fn join_requests(&self, gid: &Gid) -> Vec<Value> {
        self.store.kv_get_json(&format!("{JOIN_REQ_PREFIX}{}", gid_hex(gid))).unwrap_or_default()
    }

    /// An approved / handled request leaves the list.
    pub(crate) fn drop_join_request(&self, gid: &Gid, peer: &PeerId) -> bool {
        let key = format!("{JOIN_REQ_PREFIX}{}", gid_hex(gid));
        let mut reqs = self.join_requests(gid);
        let n = reqs.len();
        let p = peer.to_base32();
        reqs.retain(|r| r["peer"].as_str() != Some(p.as_str()));
        if reqs.len() != n {
            let _ = self.store.kv_set_json(&key, &reqs);
            true
        } else {
            false
        }
    }

    pub fn group_join_deny(&self, gid: Gid, peer: PeerId) -> Result<()> {
        let g = self.group_live(&gid)?;
        if !g.has(&self.me, perm::INVITE) {
            return Err(no_perm());
        }
        if self.drop_join_request(&gid, &peer) {
            self.send_join_denied(peer, gid, "denied");
            self.forward_join_request(&g, peer, String::new(), now_ms(), true);
        }
        if let Ok(v) = self.group_info(&gid) {
            self.emit("group", v);
        }
        Ok(())
    }

    fn send_join_denied(&self, to: PeerId, gid: Gid, reason: &str) {
        tracing::info!("join of {to:?} to group {} turned down ({reason})", gid_hex(&gid));
        let msg = proto::ext(proto::ext::GROUP_JOIN_DENIED, &JoinDeniedMsg { gid: gid.to_vec(), reason: reason.into() });
        if self.send_now(&to, msg.clone()) {
            return;
        }
        // decided later (another admin, the joiner gone offline): reliable delivery — a
        // stranger only ever gets sealed mail, never a dial (deliver_dev / may_reveal_addrs)
        if let Some(me) = self.self_ref.lock().as_ref().and_then(|w| w.upgrade()) {
            tokio::spawn(async move { me.deliver(to, crate::crypto::random_bytes(), msg, true).await });
        }
    }

    /// Who handles join requests besides me: admins (and the owner) holding `invite`, and
    /// my own other devices — never the joiner.
    fn join_approvers(&self, g: &GroupState, joiner: &PeerId) -> Vec<PeerId> {
        let mut v: Vec<PeerId> = g.members.iter().filter(|(p, r)| **r >= Role::Admin && **p != self.me && *p != joiner && g.has(p, perm::INVITE)).map(|(p, _)| *p).collect();
        v.push(self.me);
        v
    }

    /// Copy a join request (or `drop`: it was handled) to the other approvers.
    pub(crate) fn forward_join_request(&self, g: &GroupState, joiner: PeerId, name: String, at: u64, drop: bool) {
        let Some(me) = self.self_ref.lock().as_ref().and_then(|w| w.upgrade()) else { return };
        let to = self.join_approvers(g, &joiner);
        let msg = proto::ext(proto::ext::GROUP_JOIN_REQUEST, &JoinRequestFwd { gid: g.gid.to_vec(), peer: joiner.0.to_vec(), name, at, drop });
        tokio::spawn(async move {
            for a in to {
                me.deliver(a, crate::crypto::random_bytes(), msg.clone(), true).await;
            }
        });
    }

    /// Another admin's (or my other device's) copy of a join request.
    pub(crate) fn on_join_request_fwd(&self, from: PeerId, body: &[u8]) -> Result<()> {
        let m: JoinRequestFwd = proto::ext_body(body)?;
        let gid: Gid = m.gid.as_slice().try_into().map_err(|_| anyhow!("bad gid"))?;
        let joiner = PeerId(m.peer.as_slice().try_into().map_err(|_| anyhow!("bad peer"))?);
        let Some(g) = self.groups.read().get(&gid).cloned() else { return Ok(()) };
        let approver = |p: &PeerId| *p == self.me || (g.role(p).is_some_and(|r| r >= Role::Admin) && g.has(p, perm::INVITE));
        // both ends must be approvers in the group as every member folds it
        if g.dissolved() || !g.is_member(&self.me) || !approver(&from) || !approver(&self.me) || joiner == self.me {
            return Ok(());
        }
        let changed = if m.drop {
            // another approver turned it down: if the joiner asked me, I tell it
            let direct = self.join_requests(&gid).iter().any(|r| r["peer"].as_str() == Some(joiner.to_base32().as_str()) && r["direct"].as_bool() == Some(true));
            let dropped = self.drop_join_request(&gid, &joiner);
            if dropped && direct && !g.is_member(&joiner) {
                self.send_join_denied(joiner, gid, "denied");
            }
            dropped
        } else {
            if !g.ext.approve_joins || g.is_member(&joiner) || g.banned.contains(&joiner) || self.store.is_blocked(&joiner) {
                return Ok(());
            }
            let key = format!("{JOIN_REQ_PREFIX}{}", gid_hex(&gid));
            let mut reqs: Vec<Value> = self.store.kv_get_json(&key).unwrap_or_default();
            let p = joiner.to_base32();
            if reqs.iter().any(|r| r["peer"].as_str() == Some(p.as_str())) {
                false
            } else {
                let name: String = m.name.chars().take(64).collect();
                reqs.push(json!({"peer": p, "name": name, "at": m.at.min(now_ms())}));
                if reqs.len() > MAX_JOIN_REQUESTS {
                    reqs.remove(0);
                }
                self.store.kv_set_json(&key, &reqs)?;
                self.emit("group_join_request", json!({"gid": gid_hex(&gid), "peer": p, "name": name}));
                true
            }
        };
        if changed {
            if let Ok(v) = self.group_info(&gid) {
                self.emit("group", v);
            }
        }
        Ok(())
    }

    /// The inviter turned my join down: only for a join I asked for.
    pub(crate) fn on_join_denied(&self, from: PeerId, body: &[u8]) -> Result<()> {
        let m: JoinDeniedMsg = proto::ext_body(body)?;
        let gid: Gid = m.gid.as_slice().try_into().map_err(|_| anyhow!("bad gid"))?;
        let key = format!("join.pending.{}", gid_hex(&gid));
        if self.store.kv_get(&key).as_deref() != Some(b"1") {
            return Ok(());
        }
        // only from the one I asked (the link's maker / the admin I asked to join): anyone
        // else could cancel my join with a forged "no" (other approvers' decisions reach me
        // through that one)
        let via = format!("join.via.{}", gid_hex(&gid));
        if self.store.kv_get(&via).as_deref() != Some(from.to_base32().as_bytes()) {
            return Ok(());
        }
        let _ = self.store.kv_set(&key, b"");
        let _ = self.store.kv_del(&via);
        let code = match m.reason.as_str() {
            "revoked" => "err.invite_revoked",
            "removed" => "err.removed_admin_only",
            _ => "err.join_denied",
        };
        self.emit("group_join_denied", json!({"gid": gid_hex(&gid), "by": from.to_base32(), "reason": m.reason, "code": code, "text": crate::i18n::tr(code)}));
        Ok(())
    }

    // ------------------------------------------------------------ invitations ("who can add me")

    /// May `sender` add me to a group right away? Otherwise its invitation waits.
    pub(crate) fn may_add_me(&self, sender: &PeerId) -> bool {
        *sender == self.me || (self.who_can_add() == "friends" && self.store.is_friend(sender))
    }

    /// Keep a welcome as an invitation waiting for my answer.
    pub(crate) fn hold_group_invite(&self, sender: PeerId, from: PeerId, st: &GroupState, body: Vec<u8>) -> Result<()> {
        if self.store.is_blocked(&sender) || self.group_blocked(&st.gid) || st.dissolved() {
            return Ok(());
        }
        let mut list: Vec<PendingInvite> = self.store.kv_get_json(INVITES_KEY).unwrap_or_default();
        let gid = gid_hex(&st.gid);
        let by = sender.to_base32();
        list.retain(|i| i.gid != gid);
        if list.iter().filter(|i| i.by == by).count() >= MAX_INVITES_PER_SENDER {
            return Ok(());
        }
        let inv = PendingInvite {
            gid: gid.clone(),
            name: st.name.clone(),
            kind: st.kind,
            by: by.clone(),
            by_name: self.display(&sender),
            at: now_ms(),
            members: st.members.len(),
            from: from.to_base32(),
            body,
        };
        list.push(inv.clone());
        if list.len() > MAX_INVITES {
            list.remove(0);
        }
        self.store.kv_set_json(INVITES_KEY, &list)?;
        tracing::info!("group {gid}: invitation from {sender:?} waits for an answer");
        self.emit("group_invite", Self::invite_json(&inv));
        Ok(())
    }

    fn invite_json(i: &PendingInvite) -> Value {
        json!({"gid": i.gid, "name": i.name, "kind": i.kind, "by": i.by, "by_name": i.by_name, "at": i.at, "members": i.members})
    }

    pub fn group_invites(&self) -> Vec<Value> {
        let list: Vec<PendingInvite> = self.store.kv_get_json(INVITES_KEY).unwrap_or_default();
        list.iter().map(Self::invite_json).collect()
    }

    /// I'm in the group now (another way): its invitation is moot.
    pub(crate) fn drop_group_invite(&self, gid: &Gid) {
        let mut list: Vec<PendingInvite> = self.store.kv_get_json(INVITES_KEY).unwrap_or_default();
        let n = list.len();
        let g = gid_hex(gid);
        list.retain(|i| i.gid != g);
        if list.len() != n {
            let _ = self.store.kv_set_json(INVITES_KEY, &list);
            self.emit("group_invites", json!({}));
        }
    }

    /// Accept (join) or decline an invitation. Declining never joins: nothing of the group
    /// is stored, no member is dialled or learns an address; the inviter alone gets my
    /// signed Leave (sealed mail), so the group stops counting me in.
    pub async fn group_invite_answer(self: &Arc<Self>, gid: Gid, accept: bool) -> Result<Value> {
        let list: Vec<PendingInvite> = self.store.kv_get_json(INVITES_KEY).unwrap_or_default();
        let g = gid_hex(&gid);
        let inv = list.iter().find(|i| i.gid == g).cloned().ok_or_else(|| crate::i18n::user_err("err.group_not_found"))?;
        self.drop_group_invite(&gid);
        // already in it (another of my devices accepted): declining here must not take the
        // whole account out
        if self.groups.read().get(&gid).is_some_and(|st| st.is_member(&self.me)) {
            return Ok(if accept { json!({"conv": format!("g:{g}")}) } else { Value::Null });
        }
        let sender = PeerId::from_str_any(&inv.by)?;
        if !accept {
            self.decline_group_invite(sender, &inv.body).await?;
            return Ok(Value::Null);
        }
        let from = PeerId::from_str_any(&inv.from)?;
        self.welcome_body(sender, from, inv.body, true).await?;
        if !self.groups.read().get(&gid).is_some_and(|st| st.is_member(&self.me)) {
            bail!(crate::i18n::user_err("err.group_not_found"));
        }
        Ok(json!({"conv": format!("g:{g}")}))
    }

    /// My Leave for a group I was added to but never joined, sealed under the welcome's key
    /// and handed to the inviter only (it applies and gossips it like any op).
    async fn decline_group_invite(self: &Arc<Self>, inviter: PeerId, body: &[u8]) -> Result<()> {
        let w: crate::group::Welcome = proto::from_slice_capped(body)?;
        let st = GroupState::fold(w.gid, w.ops)?;
        if !st.is_member(&self.me) || w.key == [0u8; 32] || st.dissolved() {
            return Ok(());
        }
        let leave = crate::group::Signed::new(&self.signer, w.gid, self.hlc.tick(), Payload::Op(GroupOp::Leave));
        let env = crate::group::seal_envelope(&w.key, w.epoch, &leave)?;
        tracing::info!("group {}: invitation from {inviter:?} declined", gid_hex(&w.gid));
        self.deliver(inviter, leave.id, PeerMsg::Group { gid: w.gid, env }, true).await;
        Ok(())
    }

    // ------------------------------------------------------------ plain group calls

    /// `call_start` with `ring`: in a plain group only the members listed ring; everyone
    /// else gets a "Join" banner (`call` state "available"). Elsewhere as `call_start`.
    pub async fn call_start_ring(self: &Arc<Self>, conv: &str, video: bool, ring: Option<Vec<PeerId>>) -> Result<Value> {
        let plain_group = match parse_conv(conv) {
            Ok(ConvRef::Group(g, ch)) if ch.is_empty() => self.groups.read().get(&g).is_some_and(|st| st.kind == 0 && !st.dissolved()).then_some(g),
            _ => None,
        };
        match (plain_group, ring) {
            (Some(_), Some(r)) => self.call_start_ex(conv, video, Some(r)).await,
            _ => self.call_start(conv, video).await,
        }
    }

    /// Tell `members` (their devices) about a call they may join; the devices told.
    pub(crate) fn offer_group_call(self: &Arc<Self>, call_id: [u8; 16], gid: Gid, video: bool, members: Vec<PeerId>) -> Vec<PeerId> {
        let mut devs: Vec<PeerId> = vec![];
        for m in members.into_iter().take(256) {
            for d in self.delivery_targets(&m).into_iter().take(crate::devices::MAX_DEVICES) {
                if d != self.device && self.account_of(&d) != self.me {
                    devs.push(d);
                }
            }
        }
        let msg = proto::ext(proto::ext::CALL_AVAILABLE, &CallAvailableMsg { call_id: call_id.to_vec(), gid: gid.to_vec(), video });
        // Builds before 1.0.8 don't know the banner: right behind it (same ordered control
        // stream) the plain invite, which rings them as before. A device that understood
        // the banner ignores an invite for a call it holds a banner of (`banner_call_from`).
        let invite = PeerMsg::CallInvite { call_id, video, group: Some(gid) };
        let mut told = vec![];
        for d in devs {
            // live connection: no address involved
            if self.send_now_dev(&d, msg.clone()) {
                #[cfg(feature = "media")]
                super::media_pipe::send_caps_to(self, &d);
                self.send_now_dev(&d, invite.clone());
                told.push(d);
                continue;
            }
            // IP privacy: a dial reveals my addresses — only to devices that may learn them;
            // the others (public-group strangers) get the banner once they connect to me
            if !self.may_reveal_addrs(&d) {
                continue;
            }
            told.push(d);
            let me = self.clone();
            let msg = msg.clone();
            let invite = invite.clone();
            tokio::spawn(async move {
                if let Ok(pc) = me.connect(d).await {
                    if pc.ctl.send(msg).await.is_ok() {
                        #[cfg(feature = "media")]
                        super::media_pipe::send_caps(&me, &pc);
                        let _ = pc.ctl.send(invite).await;
                    }
                }
            });
        }
        told
    }

    pub(crate) fn on_call_available(&self, from: PeerId, acct: PeerId, body: &[u8]) -> Result<()> {
        let m: CallAvailableMsg = proto::ext_body(body)?;
        let gid: Gid = m.gid.as_slice().try_into().map_err(|_| anyhow!("bad gid"))?;
        let call_id: [u8; 16] = m.call_id.as_slice().try_into().map_err(|_| anyhow!("bad call id"))?;
        let members = self.group_members(&gid);
        if !members.contains(&acct) || !members.contains(&self.me) || acct == self.me || self.store.is_blocked(&acct) {
            return Ok(());
        }
        self.note_available_call(call_id, gid, m.video, from);
        Ok(())
    }

    /// A group call I may join (not rung): a "Join" banner (`call` state "available").
    pub(crate) fn note_available_call(&self, call_id: [u8; 16], gid: Gid, video: bool, from: PeerId) {
        if self.remote.calls.lock().contains_key(&call_id) {
            return;
        }
        let conv = format!("g:{}", hex::encode(gid));
        {
            let mut g = AVAILABLE.lock();
            let m = g.get_or_insert_with(HashMap::new);
            if m.len() > 64 {
                m.clear(); // (stale offers whose end we never heard)
            }
            m.insert((self.device, call_id), (conv.clone(), from, video));
        }
        let acct = self.account_of(&from);
        self.emit("call", json!({"call_id": hex::encode(call_id), "conv": conv, "state": "available", "video": video,
                                 "from": acct.to_base32(), "peer": acct.to_base32(),
                                 "participants": [{"peer": from.to_base32(), "account": acct.to_base32(), "name": self.display(&acct)}]}));
    }

    /// Device `from` offered me call `call_id` as a "Join" banner (its invite then only
    /// stands in for builds that don't know banners: it must not ring here).
    pub(crate) fn banner_call_from(&self, call_id: &[u8; 16], from: &PeerId) -> bool {
        AVAILABLE.lock().as_ref().is_some_and(|m| m.get(&(self.device, *call_id)).is_some_and(|(_, f, _)| f == from))
    }

    /// The caller hung up a call offered to me.
    pub(crate) fn available_call_ended(&self, call_id: &[u8; 16], from: &PeerId) {
        let gone = {
            let mut g = AVAILABLE.lock();
            match g.as_mut() {
                Some(m) if m.get(&(self.device, *call_id)).is_some_and(|(_, f, _)| f == from) => m.remove(&(self.device, *call_id)),
                _ => None,
            }
        };
        if let Some((conv, _, video)) = gone {
            self.emit("call", json!({"call_id": hex::encode(call_id), "conv": conv, "state": "ended", "video": video, "participants": []}));
        }
    }

    fn available_as_incoming(&self, id: [u8; 16], conv: String, from: PeerId, video: bool) -> Arc<super::remote::Call> {
        use std::sync::atomic::AtomicBool;
        Arc::new(super::remote::Call {
            id,
            conv,
            peers: Mutex::new(vec![from]),
            video,
            state: Mutex::new("incoming".into()),
            mic: AtomicBool::new(true),
            cam: AtomicBool::new(video),
            screen: AtomicBool::new(false),
            started: Instant::now(),
            answered: Mutex::new(None),
            stop: Arc::new(AtomicBool::new(false)),
            incoming_from: Some(from),
            media_started: AtomicBool::new(false),
            invited: Mutex::new(vec![]),
            room: false,
            speaking: Mutex::new(vec![]),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn quiet_node(dir: &std::path::Path) -> Arc<Node> {
        Node::start(NodeConfig {
            data_dir: dir.join("data"),
            enable_lan: false,
            enable_upnp: false,
            enable_dht: false,
            enable_nostr: false,
            relays: Some(vec![]),
            nostr: Some(vec![]),
            stun: Some(vec![]),
            ..Default::default()
        })
        .await
        .unwrap()
    }

    /// Security fix 4: offering a group call ("Join" banner) never dials a member who may
    /// not learn my addresses (a public group's stranger); friends are still told.
    #[tokio::test]
    async fn group_call_banner_never_dials_strangers() {
        let tmp = tempfile::tempdir().unwrap();
        let n = quiet_node(tmp.path()).await;
        let stranger = crate::identity::Identity::generate().peer_id();
        let friend = crate::identity::Identity::generate().peer_id();
        n.store.upsert_contact(&friend, Some("Bạn"), Some(3)).unwrap();
        assert!(!n.may_reveal_addrs(&stranger) && n.may_reveal_addrs(&friend));
        let told = n.offer_group_call([1; 16], [2; 16], false, vec![stranger, friend]);
        assert_eq!(told, vec![friend], "only the friend is dialed");
        tokio::time::sleep(Duration::from_millis(200)).await;
        assert!(!n.solicited.lock().contains_key(&stranger), "a dial would have revealed my addresses");
        assert!(!n.may_reveal_addrs(&stranger));
        n.shutdown();
    }

    /// pending-v108 items 3, 5, 6, 13: the privacy choices, their defaults and the rules.
    #[tokio::test]
    async fn privacy_choices_and_who_may_ring() {
        let tmp = tempfile::tempdir().unwrap();
        let n = quiet_node(tmp.path()).await;
        assert_eq!(n.mentions_only(), None, "never set");
        assert_eq!((n.who_can_call().as_str(), n.who_can_add().as_str(), n.who_sees_online().as_str()), ("friends", "friends", "friends"));
        let stranger = crate::identity::Identity::generate().peer_id();
        assert!(!n.call_allowed_from(&stranger), "strangers never ring by default");
        assert!(n.call_allowed_from(&n.me));
        assert!(!n.may_add_me(&stranger));
        assert!(!n.shows_online(&stranger), "a stranger never shows online");
        n.set_privacy_choices(&json!({"who_can_call": "everyone", "mentions_only": ["g:ab", "g:ab", ""]})).unwrap();
        assert_eq!(n.mentions_only(), Some(vec!["g:ab".to_string()]));
        // regression: cleared ≠ never set (else the app re-adopts its stale local list)
        n.set_privacy_choices(&json!({"mentions_only": []})).unwrap();
        assert_eq!(n.mentions_only(), Some(vec![]));
        // everyone: strangers ring, but only a few times per 10 minutes
        let rang = (0..10).filter(|_| n.call_allowed_from(&stranger)).count();
        assert_eq!(rang, STRANGER_CALLS_PER_10MIN);
        n.set_privacy_choices(&json!({"who_can_call": "nobody", "who_can_add": "nobody", "who_sees_online": "nobody"})).unwrap();
        assert!(!n.call_allowed_from(&crate::identity::Identity::generate().peer_id()));
        assert!(n.set_privacy_choices(&json!({"who_can_add": "everyone"})).is_err(), "not a choice");
        // the choices are account settings (synced to my other devices)
        for k in [WHO_CAN_CALL_KEY, WHO_CAN_ADD_KEY, WHO_SEES_ONLINE_KEY, MENTIONS_ONLY_KEY] {
            assert!(crate::store::sync::kv_synced(k), "{k}");
        }
        n.shutdown();
    }

    /// Regression (1.0.8): a stranger whose call "who can call me" never let ring leaves no
    /// trace — the call log line he sends after it ends makes no chat and no "missed call";
    /// a friend's still does.
    #[tokio::test]
    async fn blocked_call_leaves_no_trace() {
        use crate::proto::Body;
        let (t1, t2) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let (r, s) = (quiet_node(t1.path()).await, quiet_node(t2.path()).await);
        let conv = super::super::direct_conv(&s.me);
        let scope = super::super::chat::dm_scope(&r.me, &s.me);
        let missed = || Body::Call { video: false, duration_s: 0, missed: true };
        let has_conv = |r: &Arc<Node>| r.store.conversations().unwrap().iter().any(|c| c.id == conv);
        // default "friends": a stranger's call record is dropped; so is it under "nobody"
        for who in ["friends", "nobody"] {
            r.set_privacy_choices(&json!({"who_can_call": who})).unwrap();
            assert!(!r.call_permitted_from(&s.me));
            r.on_direct_chat_offline(s.me, s.device, s.new_chat_msg(&scope, missed(), None, None)).await.unwrap();
            assert!(!has_conv(&r), "{who}: the blocked stranger's call made a chat");
            assert!(r.store.messages(&conv, None, 50).unwrap().is_empty(), "{who}: missed-call line");
        }
        // a plain message from the same stranger still arrives (only call records are dropped)
        r.on_direct_chat_offline(s.me, s.device, s.new_chat_msg(&scope, Body::Text { text: "chào".into() }, None, None)).await.unwrap();
        assert_eq!(r.store.messages(&conv, None, 50).unwrap().len(), 1);
        // "everyone": logged; and a friend's missed call is logged under "friends"
        r.set_privacy_choices(&json!({"who_can_call": "everyone"})).unwrap();
        r.on_direct_chat_offline(s.me, s.device, s.new_chat_msg(&scope, missed(), None, None)).await.unwrap();
        r.set_privacy_choices(&json!({"who_can_call": "friends"})).unwrap();
        r.store.upsert_contact(&s.me, Some("s"), Some(3)).unwrap();
        assert!(r.call_permitted_from(&s.me));
        r.on_direct_chat_offline(s.me, s.device, s.new_chat_msg(&scope, missed(), None, None)).await.unwrap();
        let calls = r.store.messages(&conv, None, 50).unwrap().into_iter().filter(|m| m.kind == "call").count();
        assert_eq!(calls, 2, "allowed callers' missed calls are logged");
        // the check has no side effect (it never eats a stranger's ring allowance)
        r.set_privacy_choices(&json!({"who_can_call": "everyone"})).unwrap();
        let stranger = crate::identity::Identity::generate().peer_id();
        for _ in 0..10 {
            assert!(r.call_permitted_from(&stranger));
        }
        assert!(r.call_allowed_from(&stranger));
        r.shutdown();
        s.shutdown();
    }

    /// Regression (1.0.8 review): answering a call that has a "Join" banner *and* rings
    /// here must reach the normal answer, not stop at the banner.
    #[tokio::test]
    async fn call_answer_with_banner_and_ringing_call() {
        let tmp = tempfile::tempdir().unwrap();
        let n = quiet_node(tmp.path()).await;
        let (id, from, gid) = ([7u8; 16], crate::identity::Identity::generate().peer_id(), [3u8; 16]);
        n.note_available_call(id, gid, false, from);
        let c = n.available_as_incoming(id, format!("g:{}", hex::encode(gid)), from, false);
        n.remote.calls.lock().insert(id, c);
        for accept in [true, false] {
            AVAILABLE.lock().get_or_insert_with(HashMap::new).insert((n.device, id), (String::new(), from, false));
            let r = community_api(&n, "call_answer", &json!({"call_id": hex::encode(id), "accept": accept})).await.unwrap();
            assert!(r.is_none(), "accept={accept}: the normal call_answer must run");
            assert!(n.remote.calls.lock().contains_key(&id));
        }
        // a banner alone: joining makes it an incoming call answered by the normal path
        let other = [9u8; 16];
        n.note_available_call(other, gid, false, from);
        assert!(community_api(&n, "call_answer", &json!({"call_id": hex::encode(other)})).await.unwrap().is_none());
        assert!(n.remote.calls.lock().contains_key(&other));
        // dismissing a banner alone is local
        n.note_available_call([10u8; 16], gid, false, from);
        let r = community_api(&n, "call_answer", &json!({"call_id": hex::encode([10u8; 16]), "accept": false})).await.unwrap();
        assert_eq!(r, Some(Value::Null));
        n.shutdown();
    }

    fn queued(n: &Node, dev: &PeerId, kind: u16) -> usize {
        n.store
            .outbox_for(dev)
            .unwrap()
            .into_iter()
            .filter(|(_, p)| matches!(rmp_serde::from_slice::<PeerMsg>(p), Ok(PeerMsg::Wrapped { inner, .. }) if matches!(*inner, PeerMsg::Ext { kind: k, .. } if k == kind)))
            .count()
    }

    fn fwd_body(gid: &Gid, joiner: &PeerId, drop: bool) -> Vec<u8> {
        let PeerMsg::Ext { body, .. } = proto::ext(proto::ext::GROUP_JOIN_REQUEST, &JoinRequestFwd { gid: gid.to_vec(), peer: joiner.0.to_vec(), name: "Joiner".into(), at: now_ms(), drop }) else { panic!() };
        body
    }

    /// Integration item 3: a join request kept by the link's maker reaches every other
    /// admin holding `invite` (never plain members or the joiner), they keep it, and a
    /// decision on one admin clears it on the others.
    #[tokio::test(flavor = "multi_thread")]
    async fn join_requests_reach_every_admin_with_invite() {
        let tmp = tempfile::tempdir().unwrap();
        let n = quiet_node(tmp.path()).await;
        let (admin, member, joiner) = (crate::identity::Identity::generate().peer_id(), crate::identity::Identity::generate().peer_id(), crate::identity::Identity::generate().peer_id());
        let conv = n.create_group("G", vec![admin, member], 0).await.unwrap();
        let gid: Gid = hex::decode(conv["gid"].as_str().unwrap()).unwrap().try_into().unwrap();
        n.group_join_approval(gid, true).await.unwrap();
        n.groups.write().get_mut(&gid).unwrap().members.insert(admin, Role::Admin);
        let g = n.groups.read().get(&gid).cloned().unwrap();
        assert!(g.ext.approve_joins);
        n.forward_join_request(&g, joiner, "Joiner".into(), now_ms(), false);
        tokio::time::sleep(Duration::from_millis(300)).await;
        assert_eq!(queued(&n, &admin, proto::ext::GROUP_JOIN_REQUEST), 1, "the other admin got no copy");
        assert_eq!(queued(&n, &member, proto::ext::GROUP_JOIN_REQUEST), 0, "a plain member got the request");
        assert_eq!(queued(&n, &joiner, proto::ext::GROUP_JOIN_REQUEST), 0);
        // receiving side: only from an approver
        n.on_join_request_fwd(member, &fwd_body(&gid, &joiner, false)).unwrap();
        assert!(n.join_requests(&gid).is_empty(), "taken from a plain member");
        n.on_join_request_fwd(admin, &fwd_body(&gid, &joiner, false)).unwrap();
        assert_eq!(n.join_requests(&gid).len(), 1);
        n.on_join_request_fwd(admin, &fwd_body(&gid, &joiner, false)).unwrap();
        assert_eq!(n.join_requests(&gid).len(), 1, "no duplicates");
        assert_eq!(n.group_info(&gid).unwrap()["join_requests"].as_array().map(|a| a.len()), Some(1));
        // handled on another admin: gone here too
        n.on_join_request_fwd(admin, &fwd_body(&gid, &joiner, true)).unwrap();
        assert!(n.join_requests(&gid).is_empty());
        // declined here: the joiner is told (queued: not connected) and the others drop it
        n.on_join_request_fwd(admin, &fwd_body(&gid, &joiner, false)).unwrap();
        n.group_join_deny(gid, joiner).unwrap();
        tokio::time::sleep(Duration::from_millis(300)).await;
        assert!(n.join_requests(&gid).is_empty());
        assert_eq!(queued(&n, &joiner, proto::ext::GROUP_JOIN_DENIED), 1, "the joiner was not told");
        assert_eq!(queued(&n, &admin, proto::ext::GROUP_JOIN_REQUEST), 2, "the other admin kept a handled request");
        n.shutdown();
    }

    /// A "join denied" counts only from the one I asked to join: anyone else's is ignored.
    #[tokio::test]
    async fn join_denial_only_from_the_inviter() {
        let tmp = tempfile::tempdir().unwrap();
        let n = quiet_node(tmp.path()).await;
        let gid: Gid = crate::crypto::random_bytes();
        let (inviter, stranger) = (crate::identity::Identity::generate().peer_id(), crate::identity::Identity::generate().peer_id());
        n.store.kv_set(&format!("join.pending.{}", gid_hex(&gid)), b"1").unwrap();
        n.store.kv_set(&format!("join.via.{}", gid_hex(&gid)), inviter.to_base32().as_bytes()).unwrap();
        let PeerMsg::Ext { body, .. } = proto::ext(proto::ext::GROUP_JOIN_DENIED, &JoinDeniedMsg { gid: gid.to_vec(), reason: "denied".into() }) else { panic!() };
        n.on_join_denied(stranger, &body).unwrap();
        assert_eq!(n.store.kv_get(&format!("join.pending.{}", gid_hex(&gid))).as_deref(), Some(&b"1"[..]), "a stranger cancelled my join");
        n.on_join_denied(inviter, &body).unwrap();
        assert_eq!(n.store.kv_get(&format!("join.pending.{}", gid_hex(&gid))).as_deref(), Some(&b""[..]));
        n.shutdown();
    }
}
