//! Community 2.0 fold rules (docs/src/dev/community2-contract.md, pending-v108 items 1, 2,
//! 5, 7 and "admins have every permission").

use crate::community::{perm, EVERYONE};
use crate::devices::Signer;
use crate::group::*;
use crate::identity::{Identity, PeerId};

fn s() -> Signer {
    Signer::primary(&Identity::generate())
}

/// Clock values after the Community 2.0 cutoff.
fn t(i: u64) -> u64 {
    V2_RULES_HLC + (i << 16)
}

struct G {
    gid: Gid,
    ops: Vec<Signed>,
}

impl G {
    /// A group made by 1.0.8+: Community 2.0 rules from the start.
    fn new(owner: &Signer, members: &[&Signer], kind: u8) -> G {
        let (st, ops) = create_v2(owner, t(0), "Nhóm", members.iter().map(|m| m.account()).collect(), kind).unwrap();
        assert!(st.ext.rules_v2);
        G { gid: st.gid, ops }
    }
    /// A group made by 1.0.7 (old rules until a `RulesV2`).
    fn old(owner: &Signer, members: &[&Signer], kind: u8) -> G {
        let (st, op) = create(owner, t(0), "Nhóm cũ", members.iter().map(|m| m.account()).collect(), kind).unwrap();
        G { gid: st.gid, ops: vec![op] }
    }
    fn op(&mut self, who: &Signer, at: u64, op: GroupOp) -> Signed {
        let o = Signed::new(who, self.gid, t(at), Payload::Op(op));
        self.ops.push(o.clone());
        o
    }
    fn st(&self) -> GroupState {
        GroupState::fold(self.gid, self.ops.clone()).unwrap()
    }
    fn applied(&self, o: &Signed) -> bool {
        self.st().ops.iter().any(|x| x.id == o.id)
    }
}

fn role_set(id: &str, perms: u32) -> GroupOp {
    GroupOp::RoleSet { id: id.into(), name: id.into(), color: "#22C55E".into(), perms, position: None }
}

#[test]
fn admins_have_every_permission_members_the_everyone_defaults() {
    let (a, b, c) = (s(), s(), s());
    let mut g = G::new(&a, &[&b, &c], 0);
    g.op(&a, 1, GroupOp::SetRole { peer: b.account(), role: Role::Admin });
    let st = g.st();
    assert_eq!(st.perms_of(&a.account()), perm::ALL);
    assert_eq!(st.perms_of(&b.account()), perm::ALL, "built-in admin: every permission, manage_community included");
    assert_eq!(st.perms_of(&c.account()), perm::everyone_default(0));
    // a plain member no longer renames / repaints a plain group (manage_community)
    let r = g.op(&c, 2, GroupOp::Rename { name: "của tôi".into() });
    let m = g.op(&c, 3, GroupOp::Cover { cover: vec![1, 2, 3] });
    assert!(!g.applied(&r) && !g.applied(&m));
    let r2 = g.op(&b, 4, GroupOp::Rename { name: "admin đổi".into() });
    assert!(g.applied(&r2));
    // @everyone given manage_community: members may again
    g.op(&a, 5, role_set(EVERYONE, perm::everyone_default(0) | perm::MANAGE_COMMUNITY));
    let r3 = g.op(&c, 6, GroupOp::Rename { name: "giờ thì được".into() });
    assert!(g.applied(&r3));
    assert_eq!(g.st().name, "giờ thì được");
    // ...never in a community
    let mut cg = G::new(&a, &[&c], 1);
    cg.op(&a, 1, role_set(EVERYONE, perm::ALL));
    assert_eq!(cg.st().perms_of(&c.account()) & perm::MANAGE_COMMUNITY, 0);
    // dissolve stays owner-only
    let d = g.op(&b, 7, GroupOp::Dissolve);
    assert!(!g.applied(&d));
}

#[test]
fn rights_roles_limit_an_admin_and_nobody_grants_what_it_lacks() {
    let (a, b, c, d) = (s(), s(), s(), s());
    let mut g = G::new(&a, &[&b, &c, &d], 0);
    g.op(&a, 1, GroupOp::SetRole { peer: b.account(), role: Role::Admin });
    let rid = format!("admin:{}", b.account().to_base32());
    g.op(&a, 2, role_set(&rid, perm::everyone_default(0) | perm::MANAGE_MESSAGES | perm::MANAGE_ROLES));
    g.op(&a, 3, GroupOp::MemberRoles { peer: b.account(), roles: vec![rid.clone()] });
    let st = g.st();
    assert_eq!(st.perms_of(&b.account()) & perm::KICK, 0);
    let kick = g.op(&b, 4, GroupOp::Remove { peer: c.account() });
    assert!(!g.applied(&kick), "no kick right");
    // b (manage_roles) makes a role but can't put kick into it, nor edit its own rights
    let ok = g.op(&b, 5, role_set("r_mod", perm::MANAGE_MESSAGES));
    let bad = g.op(&b, 6, role_set("r_kick", perm::KICK));
    let own = g.op(&b, 7, role_set(&rid, perm::ALL));
    assert!(g.applied(&ok) && !g.applied(&bad) && !g.applied(&own));
    // only the owner takes rights roles away (else the admin would fall back to "all")
    let strip = g.op(&b, 8, GroupOp::MemberRoles { peer: b.account(), roles: vec![] });
    assert!(!g.applied(&strip));
    // members get roles; a role's members gain its permissions
    g.op(&b, 9, GroupOp::MemberRoles { peer: c.account(), roles: vec!["r_mod".into(), "nope".into()] });
    let st = g.st();
    assert_eq!(st.ext.roles_of(&c.account()), ["r_mod".to_string()]);
    assert!(st.has(&c.account(), perm::MANAGE_MESSAGES));
    // deleting a role takes it from everyone
    g.op(&a, 10, GroupOp::RoleDelete { id: "r_mod".into() });
    assert!(!g.st().has(&c.account(), perm::MANAGE_MESSAGES));
    let builtin = g.op(&a, 11, GroupOp::RoleDelete { id: "admin".into() });
    assert!(!g.applied(&builtin));
}

#[test]
fn transfer_owner_and_succession_by_join_order() {
    let (a, b, c, d) = (s(), s(), s(), s());
    let mut g = G::new(&a, &[], 0);
    // c joins first, then b, then d (whatever their keys sort as)
    g.op(&a, 1, GroupOp::Add { peer: c.account() });
    g.op(&a, 2, GroupOp::Add { peer: b.account() });
    g.op(&a, 3, GroupOp::Add { peer: d.account() });
    let bad = g.op(&b, 4, GroupOp::TransferOwner { peer: b.account() });
    assert!(!g.applied(&bad), "only the owner hands over");
    let mut g2 = G { gid: g.gid, ops: g.ops.clone() };
    g.op(&a, 5, GroupOp::TransferOwner { peer: d.account() });
    let st = g.st();
    assert_eq!(st.owner, d.account());
    assert_eq!(st.role(&a.account()), Some(Role::Admin));
    assert_eq!(st.role(&d.account()), Some(Role::Owner));
    // the owner leaving anyway: the member who joined first takes over …
    g2.op(&a, 6, GroupOp::Leave);
    assert_eq!(g2.st().owner, c.account(), "succession by join order, not key order");
    // … an admin before any member
    let mut g3 = G { gid: g.gid, ops: g.ops[..5].to_vec() };
    g3.op(&a, 6, GroupOp::SetRole { peer: d.account(), role: Role::Admin });
    g3.op(&a, 7, GroupOp::Leave);
    assert_eq!(g3.st().owner, d.account());
}

#[test]
fn removed_members_come_back_only_through_admins() {
    let (a, b, c) = (s(), s(), s());
    let mut g = G::new(&a, &[&b, &c], 0);
    g.op(&a, 1, GroupOp::Remove { peer: c.account() });
    assert!(g.st().removed_by_admin(&c.account()));
    let by_member = g.op(&b, 2, GroupOp::Add { peer: c.account() });
    assert!(!g.applied(&by_member));
    let by_owner = g.op(&a, 3, GroupOp::Add { peer: c.account() });
    assert!(g.applied(&by_owner));
    // someone who left on their own may be added back by anyone allowed to invite
    // (members aren't by default: @everyone is given `invite` here)
    g.op(&a, 4, role_set(EVERYONE, perm::everyone_default(0) | perm::INVITE));
    g.op(&c, 4, GroupOp::Leave);
    let again = g.op(&b, 5, GroupOp::Add { peer: c.account() });
    assert!(g.applied(&again));
}

#[test]
fn timeouts_and_moderation_targets() {
    let (a, b, c, d) = (s(), s(), s(), s());
    let mut g = G::new(&a, &[&b, &c, &d], 1);
    g.op(&a, 1, GroupOp::SetRole { peer: b.account(), role: Role::Admin });
    g.op(&a, 2, role_set("r_mod", perm::TIMEOUT | perm::KICK));
    g.op(&a, 3, GroupOp::MemberRoles { peer: c.account(), roles: vec!["r_mod".into()] });
    let until = crate::util::hlc_to_ms(t(4)) + 60_000;
    let on_member = g.op(&c, 4, GroupOp::Timeout { peer: d.account(), until_ms: until });
    let on_admin = g.op(&c, 5, GroupOp::Timeout { peer: b.account(), until_ms: until });
    let on_owner = g.op(&b, 6, GroupOp::Timeout { peer: a.account(), until_ms: until });
    let on_self = g.op(&c, 7, GroupOp::Timeout { peer: c.account(), until_ms: until });
    assert!(g.applied(&on_member));
    assert!(!g.applied(&on_admin) && !g.applied(&on_owner) && !g.applied(&on_self));
    let st = g.st();
    let at = crate::util::hlc_to_ms(t(5));
    assert_eq!(st.post_refusal(&d.account(), "general", at, false), Some("err.timed_out"));
    assert_eq!(st.post_refusal(&d.account(), "general", until + 1, false), None);
    // content written before the timeout is judged by the rules of then
    let before = st.state_for(&d.account(), t(3));
    assert_eq!(before.post_refusal(&d.account(), "general", crate::util::hlc_to_ms(t(3)), false), None);
    // lifted
    g.op(&c, 8, GroupOp::Timeout { peer: d.account(), until_ms: 0 });
    assert_eq!(g.st().timeout_until(&d.account()), 0);
}

#[test]
fn channels_private_announce_rename_order() {
    let (a, b, c) = (s(), s(), s());
    let mut g = G::new(&a, &[&b, &c], 1);
    g.op(&a, 1, GroupOp::Channel { name: "mods".into(), voice: false, remove: false });
    g.op(&a, 2, role_set("r_mod", 0));
    g.op(&a, 3, GroupOp::MemberRoles { peer: b.account(), roles: vec!["r_mod".into()] });
    let upd = |name: &str| GroupOp::ChannelUpdate {
        name: name.into(),
        new_name: None,
        topic: None,
        category: None,
        position: None,
        private: None,
        allow_roles: None,
        announce: None,
    };
    let mut private = upd("mods");
    if let GroupOp::ChannelUpdate { private: p, allow_roles, topic, .. } = &mut private {
        *p = Some(true);
        *allow_roles = Some(vec!["r_mod".into(), "ghost".into()]);
        *topic = Some("chỉ điều hành".into());
    }
    g.op(&a, 4, private);
    let mut ann = upd("general");
    if let GroupOp::ChannelUpdate { announce, new_name, .. } = &mut ann {
        *announce = Some(true);
        *new_name = Some("Thông Báo".into());
    }
    g.op(&a, 5, ann);
    let by_member = g.op(&c, 6, upd("general"));
    assert!(!g.applied(&by_member), "manage_channels");
    let st = g.st();
    assert!(st.can_see(&b.account(), "mods") && !st.can_see(&c.account(), "mods") && st.can_see(&a.account(), "mods"));
    assert_eq!(st.chan_meta("mods").allow_roles, ["r_mod".to_string()]);
    let at = crate::util::hlc_to_ms(t(7));
    assert_eq!(st.post_refusal(&c.account(), "mods", at, false), Some("err.no_permission"));
    // renamed: the key (its conversation) stays
    assert_eq!(st.channel_name("general"), "thông-báo");
    assert_eq!(st.channel_key("thông-báo").unwrap().name, "general");
    assert_eq!(st.post_refusal(&c.account(), "general", at, false), Some("err.channel_readonly"));
    assert_eq!(st.post_refusal(&b.account(), "general", at, false), Some("err.channel_readonly"));
    assert_eq!(st.post_refusal(&a.account(), "general", at, false), None);
    // a name another channel shows is taken
    let mut clash = upd("mods");
    if let GroupOp::ChannelUpdate { new_name, .. } = &mut clash {
        *new_name = Some("thông-báo".into());
    }
    let clash = g.op(&a, 8, clash);
    assert!(!g.applied(&clash));
    // order: move "mods" first
    let mut mv = upd("mods");
    if let GroupOp::ChannelUpdate { position, .. } = &mut mv {
        *position = Some(0);
    }
    g.op(&a, 9, mv);
    let order: Vec<String> = g.st().channel_order().iter().map(|c| c.name.clone()).collect();
    assert_eq!(order, ["mods", "general", "voice"]);
    // media needs send_media
    g.op(&a, 10, role_set(EVERYONE, perm::VIEW_CHANNEL | perm::SEND_MESSAGES));
    assert_eq!(g.st().post_refusal(&c.account(), "", at, true), Some("err.no_permission"));
    assert_eq!(g.st().post_refusal(&c.account(), "", at, false), None);
}

#[test]
fn invite_revocation_and_join_approval() {
    let (a, b) = (s(), s());
    let mut g = G::new(&a, &[&b], 0);
    let id = crate::community::invite_id(b"sig-1");
    g.op(&a, 1, GroupOp::RevokeInvite { id: Some(id) });
    let st = g.st();
    assert!(st.invite_revoked(&id, Some(1), u64::MAX));
    let other = crate::community::invite_id(b"sig-2");
    assert!(!st.invite_revoked(&other, Some(1), u64::MAX));
    // "revoke all": every link made before it — managing the community, not just `invite`
    g.op(&a, 1, role_set(EVERYONE, perm::everyone_default(0) | perm::INVITE));
    let single = g.op(&b, 2, GroupOp::RevokeInvite { id: Some(crate::community::invite_id(b"sig-3")) });
    let all_by_member = g.op(&b, 2, GroupOp::RevokeInvite { id: None });
    assert!(g.applied(&single) && !g.applied(&all_by_member), "revoke-all needs manage_community");
    g.op(&a, 2, GroupOp::RevokeInvite { id: None });
    let st = g.st();
    let at = crate::util::hlc_to_ms(t(2));
    assert!(st.invite_revoked(&other, Some(at - 1), u64::MAX));
    assert!(!st.invite_revoked(&other, Some(at + 1), u64::MAX));
    let ap = g.op(&b, 3, GroupOp::JoinApproval { on: true });
    assert!(!g.applied(&ap), "members don't switch approval on");
    g.op(&a, 4, GroupOp::JoinApproval { on: true });
    assert!(g.st().ext.approve_joins);
}

#[test]
fn derived_state_survives_encoding_and_any_order() {
    let (a, b, c) = (s(), s(), s());
    let mut g = G::new(&a, &[&b, &c], 1);
    g.op(&a, 1, role_set("r_x", perm::PIN));
    g.op(&a, 2, GroupOp::MemberRoles { peer: c.account(), roles: vec!["r_x".into()] });
    g.op(&a, 3, GroupOp::Timeout { peer: b.account(), until_ms: u64::MAX / 2 });
    g.op(&a, 4, GroupOp::TransferOwner { peer: c.account() });
    let st = g.st();
    let back = GroupState::decode(&rmp_serde::to_vec(&st).unwrap()).unwrap();
    assert_eq!(back.ext.roles, st.ext.roles);
    assert_eq!(back.ext.member_roles, st.ext.member_roles);
    assert_eq!(back.ext.timeouts, st.ext.timeouts);
    assert_eq!(back.owner, c.account());
    let mut rev = g.ops.clone();
    rev.reverse();
    let st2 = GroupState::fold(g.gid, rev).unwrap();
    assert_eq!(st2.ext.member_roles, st.ext.member_roles);
    assert_eq!(st2.perms_of(&c.account()), perm::ALL);
    // the serialized form is unchanged (older versions read it as a fixed array)
    let raw = rmp_serde::to_vec(&st).unwrap();
    assert_eq!(&raw[..3], &[0xdc, 0, 20], "20 positional fields, as before");
}

/// #A: a group made by 1.0.7 keeps folding exactly as 1.0.7 does — whatever the date —
/// until an admin switches it with `RulesV2` (no date cutoff splitting mixed groups).
#[test]
fn old_groups_keep_the_old_rules_until_rules_v2() {
    let (a, b, c, bot) = (s(), s(), s(), s());
    let mut g = G::old(&a, &[&b, &c], 0);
    assert!(!g.st().ext.rules_v2);
    // a plain member renames a plain group (1.0.7: allowed, rate-limited)
    let ren = g.op(&c, 1, GroupOp::Rename { name: "thành viên đặt".into() });
    assert!(g.applied(&ren));
    // Community 2.0 kinds don't exist yet
    let r = g.op(&a, 2, role_set("r_x", perm::PIN));
    let tr = g.op(&a, 3, GroupOp::TransferOwner { peer: b.account() });
    assert!(!g.applied(&r) && !g.applied(&tr));
    // a banned bot keeps its bot flag (1.0.7 did not clear it)
    g.op(&a, 4, GroupOp::AddBot { peer: bot.account(), read_all: true });
    g.op(&a, 5, GroupOp::Ban { peer: bot.account() });
    assert!(g.st().bots.contains_key(&bot.account()));
    // only an admin switches; once only
    let by_member = g.op(&b, 6, GroupOp::RulesV2);
    assert!(!g.applied(&by_member));
    let up = g.op(&a, 7, GroupOp::RulesV2);
    assert!(g.applied(&up) && g.st().ext.rules_v2);
    let again = g.op(&a, 8, GroupOp::RulesV2);
    assert!(!g.applied(&again));
    // from then on: manage_community (not in the plain @everyone defaults)
    let ren2 = g.op(&c, 9, GroupOp::Rename { name: "nữa".into() });
    assert!(!g.applied(&ren2));
    let r2 = g.op(&a, 10, role_set("r_y", perm::PIN));
    assert!(g.applied(&r2));
    // succession: 1.0.7 picks by key order, the new rules by join order — the same op log
    // folds the same on both until the switch
    let (x, y) = (s(), s());
    let (lo, hi) = if x.account().0 < y.account().0 { (x, y) } else { (y, x) };
    let mut o = G::old(&a, &[], 0);
    o.op(&a, 1, GroupOp::Add { peer: hi.account() });
    o.op(&a, 2, GroupOp::Add { peer: lo.account() });
    o.op(&a, 3, GroupOp::Leave);
    assert_eq!(o.st().owner, lo.account(), "old rules: key order");
    let mut n = G::new(&a, &[], 0);
    n.op(&a, 1, GroupOp::Add { peer: hi.account() });
    n.op(&a, 2, GroupOp::Add { peer: lo.account() });
    n.op(&a, 3, GroupOp::Leave);
    assert_eq!(n.st().owner, hi.account(), "new rules: join order");
}

/// #3: an ex-owner's Dissolve only races its own Leave: once anyone acted after the Leave
/// (the successor), it is rejected — the same on every member.
#[test]
fn ex_owner_cannot_dissolve_once_the_successor_acted() {
    let (a, b) = (s(), s());
    let mut g = G::new(&a, &[&b], 0);
    g.op(&a, 1, GroupOp::Leave);
    let mut quiet = G { gid: g.gid, ops: g.ops.clone() };
    g.op(&b, 2, GroupOp::Rename { name: "của b".into() });
    let late = g.op(&a, 3, GroupOp::Dissolve);
    assert!(!g.applied(&late) && !g.st().dissolved(), "ex-owner dissolved the successor's group");
    // racing the Leave with nothing in between: still final
    let race = quiet.op(&a, 2, GroupOp::Dissolve);
    assert!(quiet.applied(&race) && quiet.st().dissolved());
}

/// #7: losing a role / a role losing permissions is a rights cut (backdated ops refused).
#[test]
fn rights_cut_counts_role_and_permission_losses() {
    let (a, b, c) = (s(), s(), s());
    let mut g = G::new(&a, &[&b, &c], 1);
    g.op(&a, 1, role_set("r_mod", perm::KICK | perm::MANAGE_ROLES));
    g.op(&a, 2, GroupOp::MemberRoles { peer: b.account(), roles: vec!["r_mod".into()] });
    let st = g.st();
    assert_eq!(st.rights_cut_after(&b.account(), t(2)), None);
    // a role given (no loss) is no cut; one taken away is
    g.op(&a, 3, role_set("r_pin", perm::PIN));
    g.op(&a, 4, GroupOp::MemberRoles { peer: b.account(), roles: vec!["r_mod".into(), "r_pin".into()] });
    assert_eq!(g.st().rights_cut_after(&b.account(), t(2)), None);
    g.op(&a, 5, GroupOp::MemberRoles { peer: b.account(), roles: vec!["r_pin".into()] });
    assert_eq!(g.st().rights_cut_after(&b.account(), t(2)), Some(t(5)));
    assert_eq!(g.st().rights_cut_after(&c.account(), t(2)), None, "c lost nothing");
    // a role made weaker / deleted
    let mut h = G::new(&a, &[&b, &c], 1);
    h.op(&a, 1, role_set("r_mod", perm::KICK));
    h.op(&a, 2, GroupOp::MemberRoles { peer: c.account(), roles: vec!["r_mod".into()] });
    h.op(&a, 3, role_set("r_mod", 0));
    assert_eq!(h.st().rights_cut_after(&c.account(), t(2)), Some(t(3)));
    h.op(&a, 4, role_set("r_mod", perm::KICK));
    h.op(&a, 5, GroupOp::RoleDelete { id: "r_mod".into() });
    assert_eq!(h.st().rights_cut_after(&c.account(), t(4)), Some(t(5)));
    // a timeout is one too
    h.op(&a, 6, GroupOp::Timeout { peer: b.account(), until_ms: crate::util::hlc_to_ms(t(6)) + 60_000 });
    assert_eq!(h.st().rights_cut_after(&b.account(), t(5)), Some(t(6)));
}

/// #8: a demoted admin's `admin:<peer>` rights role gives it nothing as a member.
#[test]
fn demoted_admin_keeps_no_hidden_rights_role() {
    let (a, b, c) = (s(), s(), s());
    let mut g = G::new(&a, &[&b, &c], 0);
    g.op(&a, 1, GroupOp::SetRole { peer: b.account(), role: Role::Admin });
    let rid = format!("admin:{}", b.account().to_base32());
    g.op(&a, 2, role_set(&rid, perm::everyone_default(0) | perm::KICK | perm::BAN));
    g.op(&a, 3, GroupOp::MemberRoles { peer: b.account(), roles: vec![rid.clone()] });
    assert!(g.st().has(&b.account(), perm::KICK));
    g.op(&a, 4, GroupOp::SetRole { peer: b.account(), role: Role::Member });
    let st = g.st();
    assert!(!st.has(&b.account(), perm::KICK) && !st.has(&b.account(), perm::BAN), "demoted admin kept its rights role");
    assert!(st.ext.roles_of(&b.account()).is_empty());
    let kick = g.op(&b, 5, GroupOp::Remove { peer: c.account() });
    assert!(!g.applied(&kick));
}

/// #9: `manage_bots` doesn't bring back someone an admin removed, nor turn a member into a
/// (privacy-mode) bot.
#[test]
fn manage_bots_is_no_back_door() {
    let (a, b, c, d) = (s(), s(), s(), s());
    let mut g = G::new(&a, &[&b, &c, &d], 1);
    g.op(&a, 1, role_set("r_bots", perm::MANAGE_BOTS));
    g.op(&a, 2, GroupOp::MemberRoles { peer: b.account(), roles: vec!["r_bots".into()] });
    g.op(&a, 3, GroupOp::Remove { peer: c.account() });
    let back = g.op(&b, 4, GroupOp::AddBot { peer: c.account(), read_all: true });
    assert!(!g.applied(&back) && !g.st().is_member(&c.account()), "removed member re-added as a bot");
    let convert = g.op(&b, 5, GroupOp::AddBot { peer: d.account(), read_all: false });
    assert!(!g.applied(&convert) && !g.st().is_private_bot(&d.account()));
    let by_admin = g.op(&a, 6, GroupOp::AddBot { peer: c.account(), read_all: true });
    assert!(g.applied(&by_admin));
}

/// Roles have a hierarchy: `manage_roles` never edits / deletes / takes away a role with
/// rights its holder lacks, nor touches an admin's roles.
#[test]
fn manage_roles_respects_the_hierarchy() {
    let (a, b, c, d) = (s(), s(), s(), s());
    let mut g = G::new(&a, &[&b, &c, &d], 1);
    g.op(&a, 1, role_set("r_roles", perm::MANAGE_ROLES));
    g.op(&a, 2, role_set("r_mod", perm::KICK | perm::BAN));
    g.op(&a, 3, GroupOp::MemberRoles { peer: b.account(), roles: vec!["r_roles".into()] });
    g.op(&a, 4, GroupOp::MemberRoles { peer: c.account(), roles: vec!["r_mod".into()] });
    g.op(&a, 5, GroupOp::SetRole { peer: d.account(), role: Role::Admin });
    let weaken = g.op(&b, 6, role_set("r_mod", 0));
    let delete = g.op(&b, 7, GroupOp::RoleDelete { id: "r_mod".into() });
    let strip = g.op(&b, 8, GroupOp::MemberRoles { peer: c.account(), roles: vec![] });
    let on_admin = g.op(&b, 9, GroupOp::MemberRoles { peer: d.account(), roles: vec!["r_roles".into()] });
    for (o, what) in [(&weaken, "weakened"), (&delete, "deleted"), (&strip, "took away"), (&on_admin, "changed an admin's roles")] {
        assert!(!g.applied(o), "manage_roles {what} a role above it");
    }
    assert!(g.st().has(&c.account(), perm::KICK));
    // within its own rights: fine
    g.op(&a, 10, role_set("r_low", perm::MANAGE_ROLES));
    let give = g.op(&b, 11, GroupOp::MemberRoles { peer: c.account(), roles: vec!["r_mod".into(), "r_low".into()] });
    assert!(g.applied(&give), "a role within its rights (r_mod untouched)");
}

/// #E: invite links are the admins' by default.
#[test]
fn everyone_cannot_invite_by_default() {
    let (a, b, c) = (s(), s(), s());
    let mut g = G::new(&a, &[&b], 0);
    assert!(!g.st().has(&b.account(), perm::INVITE));
    let add = g.op(&b, 1, GroupOp::Add { peer: c.account() });
    assert!(!g.applied(&add));
    // an old group keeps 1.0.7's "any member of a plain group adds"
    let mut o = G::old(&a, &[&b], 0);
    assert!(o.st().has(&b.account(), perm::INVITE));
    let add = o.op(&b, 1, GroupOp::Add { peer: c.account() });
    assert!(o.applied(&add));
}

/// #D: `never_valid` doesn't judge by the author's current role (it signed under another).
#[test]
fn never_valid_ignores_the_current_role() {
    let (a, b) = (s(), s());
    // (an old community, from before the 2.0 date: the clause this replaces judged those)
    let (st0, c) = create(&a, 10 << 8, "cũ", vec![b.account()], 1).unwrap();
    let promote = Signed::new(&a, st0.gid, 20 << 8, Payload::Op(GroupOp::SetRole { peer: b.account(), role: Role::Admin }));
    let pic = Signed::new(&b, st0.gid, 30 << 8, Payload::Op(GroupOp::Meta { avatar: vec![1; 10], description: "admin đặt".into() }));
    let demote = Signed::new(&a, st0.gid, 40 << 8, Payload::Op(GroupOp::SetRole { peer: b.account(), role: Role::Member }));
    let st = GroupState::fold(st0.gid, vec![c, promote, demote]).unwrap();
    assert!(!st.never_valid(&pic), "a valid picture (signed as admin) dropped for good");
    let mut held = vec![];
    let (st, ok) = st.with_op(pic, &mut held).unwrap();
    assert!(ok && st.avatar == vec![1; 10]);
}

/// #C: when the newest picture is rejected on a re-fold, the previous one shows — never an
/// empty picture from a stripped op.
#[test]
fn a_rejected_newest_picture_never_blanks_the_group_picture() {
    let (a, b) = (s(), s());
    let mut g = G::old(&a, &[&b], 1);
    g.op(&a, 1, GroupOp::SetRole { peer: b.account(), role: Role::Admin });
    let mut st = g.st();
    let mut held = vec![];
    for (i, who) in [(2u64, &a), (3, &a), (4, &a), (6, &b)] {
        let o = Signed::new(who, g.gid, t(i), Payload::Op(GroupOp::Meta { avatar: vec![i as u8; 8], description: String::new() }));
        let c = Signed::new(who, g.gid, t(i), Payload::Op(GroupOp::Cover { cover: vec![i as u8; 8] }));
        st = st.with_op(o, &mut held).unwrap().0;
        st = st.with_op(c, &mut held).unwrap().0;
    }
    assert_eq!(st.avatar, vec![6; 8]);
    // a demotion of b dated before its picture arrives late: b's picture is rejected
    let demote = Signed::new(&a, g.gid, t(5), Payload::Op(GroupOp::SetRole { peer: b.account(), role: Role::Member }));
    let (st, _) = st.with_op(demote, &mut held).unwrap();
    assert_eq!(st.avatar, vec![4; 8], "the group picture vanished");
    assert_eq!(st.cover(), &[4u8; 8][..], "the cover vanished");
    let back = GroupState::decode(&rmp_serde::to_vec(&st).unwrap()).unwrap();
    assert_eq!(back.avatar, vec![4; 8]);
}

/// #F: judging late content by the rules of its time doesn't re-fold the whole prefix per
/// message (catch-up on a big community must stay linear-ish).
#[test]
fn late_content_judgement_is_not_quadratic() {
    let (a, b) = (s(), s());
    let mut g = G::new(&a, &[&b], 1);
    // 2000 ops that change b's rights (timeouts on and off)
    for i in 1..=2000u64 {
        let until = if i % 2 == 1 { crate::util::hlc_to_ms(t(i)) + 30_000 } else { 0 };
        g.op(&a, i, GroupOp::Timeout { peer: b.account(), until_ms: until });
    }
    let st = g.st();
    assert_eq!(st.ops.len(), 2002);
    let start = std::time::Instant::now();
    // 5000 messages spread over that history, oldest first (as a catch-up delivers them)
    let mut refused = 0;
    for m in 0..5000u64 {
        let hlc = t(1) + ((m * 2000 / 5000) << 16) + 7;
        let at = st.state_for(&b.account(), hlc);
        refused += at.post_refusal(&b.account(), "general", crate::util::hlc_to_ms(hlc), false).is_some() as u32;
    }
    let took = start.elapsed();
    assert!(refused > 1000 && refused < 4000, "{refused}");
    assert!(took < std::time::Duration::from_secs(20), "late-content judgement took {took:?}");
}

#[test]
fn ops_made_before_the_cutoff_keep_their_rules() {
    let (a, b, c) = (s(), s(), s());
    // a plain group from before 2.0: a member renamed it, the owner left (old succession)
    let (st, op) = create(&a, 10 << 8, "cũ", vec![b.account(), c.account()], 0).unwrap();
    let ren = Signed::new(&b, st.gid, 20 << 8, Payload::Op(GroupOp::Rename { name: "thành viên đặt".into() }));
    let st = GroupState::fold(st.gid, vec![op, ren]).unwrap();
    assert_eq!(st.name, "thành viên đặt", "an old rename stays valid after the upgrade");
    let _ = PeerId([0; 32]);
}
