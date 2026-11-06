//! Command-line / environment configuration.

use clap::builder::BoolishValueParser;
use clap::Parser;
use std::net::SocketAddr;
use std::path::PathBuf;

/// Every flag can also be set through the environment variable shown in `--help`.
#[derive(Parser, Debug, Clone)]
#[command(
    name = "lumora-relay",
    version,
    about = "Lumora relay: authenticated WebSocket forwarder, signal mailbox and STUN responder. \
             Payloads are end-to-end encrypted; the relay never decrypts."
)]
pub struct Config {
    /// HTTP(S) listen address (WebSocket endpoint is /ws, stats at /health).
    #[arg(long, env = "LUMORA_RELAY_LISTEN", default_value = "0.0.0.0:8443")]
    pub listen: SocketAddr,

    /// PEM certificate chain; enables native TLS (wss://) together with --tls-key.
    #[arg(long, env = "LUMORA_RELAY_TLS_CERT", requires = "tls_key")]
    pub tls_cert: Option<PathBuf>,

    /// PEM private key for --tls-cert.
    #[arg(long, env = "LUMORA_RELAY_TLS_KEY", requires = "tls_cert")]
    pub tls_key: Option<PathBuf>,

    /// Trust CF-Connecting-IP / X-Forwarded-For (only behind your own reverse proxy).
    #[arg(long, env = "LUMORA_RELAY_TRUST_PROXY", value_parser = BoolishValueParser::new(),
          num_args = 0..=1, default_value = "false", default_missing_value = "true")]
    pub trust_proxy: bool,

    /// UDP port of the STUN binding responder (0 disables).
    #[arg(long, env = "LUMORA_RELAY_STUN_PORT", default_value_t = 3478)]
    pub stun_port: u16,

    /// IP the STUN responder binds to (use "::" for dual-stack where available).
    #[arg(long, env = "LUMORA_RELAY_STUN_BIND", default_value = "0.0.0.0")]
    pub stun_bind: std::net::IpAddr,

    /// Maximum number of authenticated clients.
    #[arg(long, env = "LUMORA_RELAY_MAX_CLIENTS", default_value_t = 10_000)]
    pub max_clients: usize,

    /// Per-client DATA bandwidth in bytes/second (0 = unlimited).
    #[arg(long, env = "LUMORA_RELAY_BANDWIDTH", default_value_t = 2 * 1024 * 1024)]
    pub bandwidth: u64,

    /// Per-client DATA burst in bytes (token bucket size).
    #[arg(long, env = "LUMORA_RELAY_BURST", default_value_t = 4 * 1024 * 1024)]
    pub burst: u64,

    /// Per-client SIGNAL frames per second (burst = 2x). 0 = unlimited.
    #[arg(long, env = "LUMORA_RELAY_SIGNAL_RATE", default_value_t = 20.0)]
    pub signal_rate: f64,

    /// Maximum WebSocket frame size in bytes accepted from clients.
    #[arg(long, env = "LUMORA_RELAY_MAX_FRAME", default_value_t = 64 * 1024)]
    pub max_frame: usize,

    /// Close sessions that send nothing (not even a ping) for this many seconds.
    #[arg(long, env = "LUMORA_RELAY_IDLE_TIMEOUT", default_value_t = 90)]
    pub idle_timeout: u64,

    /// Seconds a new connection has to send its HELLO.
    #[arg(long, env = "LUMORA_RELAY_HELLO_TIMEOUT", default_value_t = 10)]
    pub hello_timeout: u64,

    /// Private relay mode: file with one permitted public key per line
    /// (64-char hex or Lumora base32 peer id; '#' starts a comment).
    #[arg(long, env = "LUMORA_RELAY_ALLOW")]
    pub allow: Option<PathBuf>,

    /// Store SIGNAL frames for offline peers and deliver them on their next HELLO.
    #[arg(long, env = "LUMORA_RELAY_MAILBOX", value_parser = BoolishValueParser::new(),
          num_args = 0..=1, default_value = "true", default_missing_value = "true")]
    pub mailbox: bool,

    /// Mailbox: maximum stored signals per recipient.
    #[arg(long, env = "LUMORA_RELAY_MAILBOX_MAX_ITEMS", default_value_t = 200)]
    pub mailbox_max_items: usize,

    /// Mailbox: maximum size of one stored signal payload in bytes.
    #[arg(long, env = "LUMORA_RELAY_MAILBOX_MAX_ITEM", default_value_t = 64 * 1024)]
    pub mailbox_max_item: usize,

    /// Mailbox: time to live of a stored signal, in seconds (default 7 days).
    #[arg(long, env = "LUMORA_RELAY_MAILBOX_TTL", default_value_t = 7 * 24 * 3600)]
    pub mailbox_ttl: u64,

    /// Mailbox: total memory cap in bytes across all recipients.
    #[arg(long, env = "LUMORA_RELAY_MAILBOX_TOTAL", default_value_t = 256 * 1024 * 1024)]
    pub mailbox_total: usize,

    /// Mailbox: persist to this file (loaded at start, saved every minute and on shutdown).
    #[arg(long, env = "LUMORA_RELAY_MAILBOX_FILE")]
    pub mailbox_file: Option<PathBuf>,

    /// Per-session outbound queue length (frames). DATA is dropped when full; a client
    /// too slow to take SIGNAL frames is disconnected (its signals go to the mailbox).
    #[arg(long, env = "LUMORA_RELAY_QUEUE", default_value_t = 1024)]
    pub queue_len: usize,

    /// Emit logs as JSON lines (default: human-readable). Filter with RUST_LOG.
    #[arg(long, env = "LUMORA_RELAY_LOG_JSON", value_parser = BoolishValueParser::new(),
          num_args = 0..=1, default_value = "false", default_missing_value = "true")]
    pub log_json: bool,
}

impl Default for Config {
    /// Built-in defaults (ignores environment variables).
    fn default() -> Self {
        Config {
            listen: "0.0.0.0:8443".parse().unwrap(),
            tls_cert: None,
            tls_key: None,
            trust_proxy: false,
            stun_port: 3478,
            stun_bind: std::net::IpAddr::from([0, 0, 0, 0]),
            max_clients: 10_000,
            bandwidth: 2 * 1024 * 1024,
            burst: 4 * 1024 * 1024,
            signal_rate: 20.0,
            max_frame: 64 * 1024,
            idle_timeout: 90,
            hello_timeout: 10,
            allow: None,
            mailbox: true,
            mailbox_max_items: 200,
            mailbox_max_item: 64 * 1024,
            mailbox_ttl: 7 * 24 * 3600,
            mailbox_total: 256 * 1024 * 1024,
            mailbox_file: None,
            queue_len: 1024,
            log_json: false,
        }
    }
}
