//! `lumora-push`: optional APNs wake-up bridge for Lumora on iPhone. See docs/src/ops/push.md.

use std::net::SocketAddr;
use std::path::PathBuf;

use clap::Parser;
use lumora_push::apns::{load_p8, ApnsClient, ApnsConfig, APNS_PRODUCTION, APNS_SANDBOX};
use lumora_push::server::{serve, Bridge, BridgeConfig, Limits};
use lumora_push::{b64, KeyPair};

#[derive(Parser, Debug)]
#[command(name = "lumora-push", version, about = "Lumora push bridge: wakes iPhones with content-free APNs pushes. \
It never sees messages, contacts or who is talking to whom.")]
struct Args {
    /// Listen address.
    #[arg(long, env = "LUMORA_PUSH_LISTEN", default_value = "0.0.0.0:8099")]
    listen: SocketAddr,
    /// Directory for the bridge key (created on first start) and the dead-token list.
    #[arg(long, env = "LUMORA_PUSH_STATE", default_value = "./lumora-push-state")]
    state: PathBuf,
    /// App bundle id(s) this bridge serves (APNs topic), comma separated.
    #[arg(long, env = "LUMORA_PUSH_TOPIC", value_delimiter = ',', default_value = "vn.lumora.lumora")]
    topic: Vec<String>,
    /// APNs auth key (.p8) from App Store Connect › Users and Access › Keys.
    #[arg(long, env = "LUMORA_PUSH_APNS_KEY")]
    apns_key: Option<PathBuf>,
    /// Key ID of that .p8 key (10 characters).
    #[arg(long, env = "LUMORA_PUSH_APNS_KEY_ID", default_value = "")]
    apns_key_id: String,
    /// Apple Developer Team ID (10 characters).
    #[arg(long, env = "LUMORA_PUSH_TEAM_ID", default_value = "")]
    team_id: String,
    #[arg(long, env = "LUMORA_PUSH_APNS_URL", default_value = APNS_PRODUCTION)]
    apns_url: String,
    #[arg(long, env = "LUMORA_PUSH_APNS_SANDBOX_URL", default_value = APNS_SANDBOX)]
    apns_sandbox_url: String,
    /// Dry run: write pushes to this file (JSON lines) instead of sending them to Apple.
    #[arg(long, env = "LUMORA_PUSH_APNS_LOG")]
    apns_log: Option<PathBuf>,
    /// Trust X-Forwarded-For (only behind your own reverse proxy).
    #[arg(long, env = "LUMORA_PUSH_TRUST_PROXY")]
    trust_proxy: bool,
    /// Print the bridge public key (for the app's build config) and exit.
    #[arg(long)]
    print_public_key: bool,
}

fn load_or_create_key(dir: &PathBuf) -> std::io::Result<KeyPair> {
    std::fs::create_dir_all(dir)?;
    let p = dir.join("bridge.key");
    if let Ok(s) = std::fs::read_to_string(&p) {
        if let Some(k) = lumora_push::key32(&s) {
            return Ok(KeyPair::from_secret(k));
        }
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, format!("{} is not a bridge key", p.display())));
    }
    let k = KeyPair::generate();
    #[cfg(unix)]
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut f = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&p)?;
        writeln!(f, "{}", b64(&k.secret))?;
    }
    #[cfg(not(unix))]
    std::fs::write(&p, format!("{}\n", b64(&k.secret)))?;
    Ok(k)
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .init();
    let a = Args::parse();
    let keypair = match load_or_create_key(&a.state) {
        Ok(k) => k,
        Err(e) => {
            eprintln!("error: bridge key: {e}");
            std::process::exit(2);
        }
    };
    if a.print_public_key {
        println!("{}", b64(&keypair.public));
        return;
    }
    let key_pkcs8 = match &a.apns_key {
        Some(p) => match std::fs::read(p).map_err(|e| e.to_string()).and_then(|b| load_p8(&b).map_err(|e| e.0)) {
            Ok(k) => Some(k),
            Err(e) => {
                eprintln!("error: APNs key {}: {e}", p.display());
                std::process::exit(2);
            }
        },
        None => None,
    };
    if key_pkcs8.is_some() && (a.apns_key_id.len() != 10 || a.team_id.len() != 10) {
        eprintln!("error: --apns-key-id and --team-id (10 characters each) are required with --apns-key");
        std::process::exit(2);
    }
    let apns = match ApnsClient::new(ApnsConfig {
        production_url: a.apns_url,
        sandbox_url: a.apns_sandbox_url,
        key_id: a.apns_key_id,
        team_id: a.team_id,
        key_pkcs8,
        dry_run_log: a.apns_log.clone(),
    }) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("error: {e}");
            std::process::exit(2);
        }
    };
    let bridge = Bridge::new(
        BridgeConfig {
            keypair: keypair.clone(),
            topics: a.topic.clone(),
            limits: Limits::default(),
            dead_file: Some(a.state.join("dead-tokens.txt")),
            gen_file: Some(a.state.join("generations.txt")),
            trust_proxy: a.trust_proxy,
        },
        apns,
    );
    let listener = match tokio::net::TcpListener::bind(a.listen).await {
        Ok(l) => l,
        Err(e) => {
            eprintln!("error: listen {}: {e}", a.listen);
            std::process::exit(2);
        }
    };
    tracing::info!(
        "lumora-push on {} · topics {:?} · public key {} · {}",
        a.listen,
        a.topic,
        b64(&keypair.public),
        if a.apns_log.is_some() { "DRY RUN (no pushes sent)" } else { "sending to APNs" }
    );
    if let Err(e) = serve(listener, bridge).await {
        eprintln!("error: {e}");
        std::process::exit(1);
    }
}
