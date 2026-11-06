//! Lumora relay server.
//!
//! A relay is a *last resort* path: nodes only use it after direct UDP/QUIC paths
//! failed (see `NetConfig::relay_delay_ms` in lumora-core) and for signaling.
//! Everything it forwards is end-to-end encrypted (QUIC/TLS datagrams or sealed
//! envelopes); the relay only authenticates *who* is connected (Ed25519 HELLO) and
//! moves opaque bytes between authenticated sessions.
//!
//! Wire format: `lumora-core/src/net/relay_proto.rs` (shared verbatim, see below).

#[path = "../../lumora-core/src/net/relay_proto.rs"]
#[allow(dead_code)]
pub mod relay_proto;

pub mod config;
mod mailbox;
mod server;
pub mod stun;

pub use config::Config;
pub use server::{start, Relay};
