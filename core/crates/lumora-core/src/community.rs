//! Community 2.0: permissions, roles, channel settings, timeouts, invite revocations
//! (docs/src/dev/community2-contract.md). Applies to communities (kind 1) and plain groups.
//!
//! None of this is stored in `GroupState`'s serialized form (an rmp array older versions
//! read): it is derived from the signed op log by the fold (`GroupState::ext`, rebuilt by
//! re-folding on load — see `GroupState::decode`).

use crate::identity::PeerId;
use std::collections::BTreeMap;

/// Permission bits (`group_roles[].perms`, `group_info.my_perms`), in the app's order.
pub mod perm {
    pub const VIEW_CHANNEL: u32 = 1 << 0;
    pub const SEND_MESSAGES: u32 = 1 << 1;
    pub const SEND_MEDIA: u32 = 1 << 2;
    pub const MANAGE_MESSAGES: u32 = 1 << 3;
    pub const MENTION_EVERYONE: u32 = 1 << 4;
    pub const CONNECT_VOICE: u32 = 1 << 5;
    pub const MANAGE_CHANNELS: u32 = 1 << 6;
    pub const MANAGE_ROLES: u32 = 1 << 7;
    pub const KICK: u32 = 1 << 8;
    pub const BAN: u32 = 1 << 9;
    pub const TIMEOUT: u32 = 1 << 10;
    pub const MANAGE_BOTS: u32 = 1 << 11;
    pub const INVITE: u32 = 1 << 12;
    pub const PIN: u32 = 1 << 13;
    pub const MANAGE_COMMUNITY: u32 = 1 << 14;
    pub const ALL: u32 = (1 << 15) - 1;

    pub const NAMES: [&str; 15] = [
        "view_channel",
        "send_messages",
        "send_media",
        "manage_messages",
        "mention_everyone",
        "connect_voice",
        "manage_channels",
        "manage_roles",
        "kick",
        "ban",
        "timeout",
        "manage_bots",
        "invite",
        "pin",
        "manage_community",
    ];

    /// Bits of the known names (unknown ones are ignored).
    pub fn from_names<S: AsRef<str>>(names: &[S]) -> u32 {
        names.iter().filter_map(|n| NAMES.iter().position(|x| *x == n.as_ref())).fold(0, |a, i| a | (1 << i))
    }

    pub fn names(bits: u32) -> Vec<&'static str> {
        NAMES.iter().enumerate().filter(|(i, _)| bits & (1 << i) != 0).map(|(_, n)| *n).collect()
    }

    /// `@everyone`'s permissions in a new community (kind 1) / plain group (kind 0).
    /// Invite links are the admins' (a role may give `invite` to others).
    pub fn everyone_default(kind: u8) -> u32 {
        let base = VIEW_CHANNEL | SEND_MESSAGES | SEND_MEDIA | CONNECT_VOICE;
        if kind == 1 {
            base
        } else {
            base | PIN
        }
    }
}

/// Built-in role ids.
pub const EVERYONE: &str = "everyone";
pub const ADMIN: &str = "admin";
/// Prefix of a plain group's per-admin rights role (`admin:<peer base32>`).
pub const ADMIN_RIGHTS_PREFIX: &str = "admin:";
/// Colour of the built-in admin role and per-admin roles (Lumora primary).
pub const ADMIN_COLOR: &str = "#6C5CE7";
/// Colour of `@everyone` and of roles without one.
pub const DEFAULT_COLOR: &str = "#9AA0C3";
/// Custom roles per group.
pub const MAX_ROLES: usize = 250;
/// Roles one member may hold.
pub const MAX_MEMBER_ROLES: usize = 32;
/// Revoked invite link ids kept per group.
pub const MAX_REVOKED: usize = 500;

/// A custom role (or a plain group's `admin:<peer>` rights role).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RoleDef {
    pub id: String,
    pub name: String,
    pub color: String,
    pub perms: u32,
}

/// Channel settings beyond its key (`Channel::name`, which never changes: it names the
/// channel's conversation).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ChanMeta {
    /// Shown name after a rename (None: the key).
    pub name: Option<String>,
    pub topic: String,
    pub category: String,
    pub position: Option<u32>,
    pub private: bool,
    pub allow_roles: Vec<String>,
    pub announce: bool,
}

/// Everything Community 2.0 adds to a group, derived from its op log.
#[derive(Clone, Debug, Default)]
pub struct Community {
    /// `@everyone`'s permissions once changed (None: the defaults for the group's kind).
    pub everyone: Option<u32>,
    /// Custom roles, lowest first (position = index + 1).
    pub roles: Vec<RoleDef>,
    /// Custom role ids per member / bot.
    pub member_roles: BTreeMap<PeerId, Vec<String>>,
    /// Timed out until (epoch ms).
    pub timeouts: BTreeMap<PeerId, u64>,
    /// Channel key → settings.
    pub chan: BTreeMap<String, ChanMeta>,
    /// Revoked invite link ids, and "every link made before" (epoch ms, 0 = none).
    pub revoked: Vec<[u8; 8]>,
    pub revoked_before_ms: u64,
    /// "Approve new members": invite-link joins wait for an admin.
    pub approve_joins: bool,
    /// Members an admin removed (only admins may add them back).
    pub removed: Vec<PeerId>,
    /// The group follows the Community 2.0 rules (a `RulesV2` op was applied).
    pub rules_v2: bool,
    /// Prefix fold snapshots (see `GroupState::prefix_state`): shared by clones, keyed by
    /// the prefix itself, so a stale entry is never used for another op log.
    pub snapshots: crate::group::Snapshots,
}

impl Community {
    pub fn role(&self, id: &str) -> Option<&RoleDef> {
        self.roles.iter().find(|r| r.id == id)
    }

    pub fn everyone_perms(&self, kind: u8) -> u32 {
        // (before the Community 2.0 rules every member of a plain group could add people:
        // the node-level checks of such a group keep that)
        let legacy = if self.rules_v2 { 0 } else { perm::INVITE };
        self.everyone.unwrap_or_else(|| perm::everyone_default(kind) | legacy)
    }

    pub fn roles_of(&self, p: &PeerId) -> &[String] {
        self.member_roles.get(p).map(|v| v.as_slice()).unwrap_or(&[])
    }

    /// Insert / move a custom role to `position` (1 = just above @everyone).
    pub fn place_role(&mut self, role: RoleDef, position: Option<u32>, new: bool) {
        let at = self.roles.iter().position(|r| r.id == role.id);
        match (at, position) {
            (Some(i), None) => self.roles[i] = role,
            (Some(i), Some(p)) => {
                self.roles.remove(i);
                let idx = (p.max(1) as usize - 1).min(self.roles.len());
                self.roles.insert(idx, role);
            }
            (None, Some(p)) => {
                let idx = (p.max(1) as usize - 1).min(self.roles.len());
                self.roles.insert(idx, role);
            }
            (None, None) => {
                debug_assert!(new);
                self.roles.insert(0, role);
            }
        }
    }

    pub fn delete_role(&mut self, id: &str) {
        self.roles.retain(|r| r.id != id);
        for v in self.member_roles.values_mut() {
            v.retain(|r| r != id);
        }
        self.member_roles.retain(|_, v| !v.is_empty());
        for c in self.chan.values_mut() {
            c.allow_roles.retain(|r| r != id);
        }
    }

    /// A member left / was removed: its roles and timeout go.
    pub fn forget_member(&mut self, p: &PeerId) {
        self.member_roles.remove(p);
        self.timeouts.remove(p);
    }

    pub fn is_revoked(&self, id: &[u8; 8], created_ms: Option<u64>, expires_ms: u64) -> bool {
        if self.revoked.contains(id) {
            return true;
        }
        if self.revoked_before_ms == 0 {
            return false;
        }
        match created_ms {
            Some(c) => c <= self.revoked_before_ms,
            // made on another device (no record here): links last at most 30 days, so one
            // that expires within 30 days of the revocation was made before it
            None => expires_ms <= self.revoked_before_ms + 30 * 86_400_000,
        }
    }
}

/// Id of an invite link (from its signature): what `RevokeInvite` names.
pub fn invite_id(sig: &[u8]) -> [u8; 8] {
    blake3::derive_key("lumora invite id v1", sig)[..8].try_into().unwrap_or([0; 8])
}

/// `#RRGGBB` (anything else: the default colour).
pub fn clean_color(c: &str) -> String {
    let c = c.trim();
    if c.len() == 7 && c.starts_with('#') && c[1..].chars().all(|x| x.is_ascii_hexdigit()) {
        c.to_uppercase()
    } else {
        DEFAULT_COLOR.to_string()
    }
}

#[cfg(test)]
#[path = "community_tests.rs"]
mod fold_tests;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn perm_names_roundtrip() {
        assert_eq!(perm::NAMES.len(), 15);
        let b = perm::from_names(&["send_media", "pin", "nope"]);
        assert_eq!(b, perm::SEND_MEDIA | perm::PIN);
        assert_eq!(perm::names(b), vec!["send_media", "pin"]);
        assert_eq!(perm::from_names(&perm::NAMES), perm::ALL);
        assert_eq!(perm::everyone_default(0) & perm::PIN, perm::PIN);
        assert_eq!(perm::everyone_default(1) & (perm::PIN | perm::MANAGE_COMMUNITY | perm::MENTION_EVERYONE), 0);
        assert_eq!(clean_color("#6c5ce7"), "#6C5CE7");
        assert_eq!(clean_color("red"), DEFAULT_COLOR);
    }

    #[test]
    fn role_placement() {
        let mut c = Community::default();
        let r = |id: &str| RoleDef { id: id.into(), name: id.into(), color: DEFAULT_COLOR.into(), perms: 0 };
        c.place_role(r("a"), None, true);
        c.place_role(r("b"), None, true); // new roles go just above @everyone
        assert_eq!(c.roles.iter().map(|r| r.id.as_str()).collect::<Vec<_>>(), ["b", "a"]);
        c.place_role(r("c"), Some(9), true); // past the top: highest custom role
        c.place_role(r("b"), Some(3), false);
        assert_eq!(c.roles.iter().map(|r| r.id.as_str()).collect::<Vec<_>>(), ["a", "c", "b"]);
        c.member_roles.insert(PeerId([1; 32]), vec!["a".into(), "c".into()]);
        c.chan.insert("x".into(), ChanMeta { allow_roles: vec!["c".into()], ..Default::default() });
        c.delete_role("c");
        assert_eq!(c.roles_of(&PeerId([1; 32])), ["a".to_string()]);
        assert!(c.chan["x"].allow_roles.is_empty());
    }
}
