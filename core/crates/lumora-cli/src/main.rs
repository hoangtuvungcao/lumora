//! `lumorad` — headless Lumora node.
//!
//!   lumorad --data DIR [--name N] [--port P] [--relay URL]... [--no-nostr] [--no-dht] [--no-upnp] [--no-lan] [--no-lan-multicast] [--no-mdns] --stdio
//!
//! First start only: `--restore-backup FILE PASSWORD`, or `--restore-phrase "24 words"`
//! (also read from `LUMORA_RESTORE_PHRASE`, which keeps it out of `ps`; the legacy
//! base32 phrase is accepted too).
//!
//! With `--stdio` it reads one JSON request per line on stdin and prints responses and
//! events as JSON lines on stdout (contract: docs/src/dev/api.md). Used by tests and the NAT lab.
//!
//! `--link-pending` starts a new device waiting to be linked into an existing account
//! (`link_start`). Once approved the node asks to be restarted (`link_state: restart`):
//! lumorad stops it and starts it again in the same process, now as a device of the account.
use lumora_core::node::{Node, NodeConfig};
use std::io::{BufRead, Write};
use std::sync::Arc;

fn usage() -> ! {
    eprintln!("usage: lumorad --data DIR [--name N] [--port P] [--relay URL]... [--passphrase P] [--no-nostr] [--no-dht] [--no-upnp] [--no-lan] [--no-lan-multicast] [--no-mdns] [--relay-delay MS] [--restore-phrase WORDS | --restore-backup FILE PW] [--link-pending] [--stdio]");
    std::process::exit(2)
}

enum Exit {
    Quit,
    Restart,
    /// signed out of the account (`device_revoked`)
    Reset,
}

fn main() -> anyhow::Result<()> {
    let mut cfg = NodeConfig::default();
    let mut relays = Vec::new();
    let mut args = std::env::args().skip(1);
    if let Ok(t) = std::env::var("LUMORA_BOT_TOKEN") {
        cfg.bot_token = Some(t); // safer than a command-line argument (not visible in `ps`)
    }
    if let Ok(p) = std::env::var("LUMORA_RESTORE_PHRASE") {
        cfg.recovery_phrase = Some(p); // same reason
    }
    let mut stdio = false;
    while let Some(a) = args.next() {
        match a.as_str() {
            "--data" => cfg.data_dir = args.next().unwrap_or_else(|| usage()).into(),
            "--name" => cfg.name = args.next(),
            "--port" => cfg.port = args.next().and_then(|p| p.parse().ok()).unwrap_or_else(|| usage()),
            "--relay" => relays.push(args.next().unwrap_or_else(|| usage())),
            "--nostr" => cfg.nostr = Some(args.next().unwrap_or_else(|| usage()).split(',').map(String::from).collect()),
            "--stun" => {
                cfg.stun = Some(args.next().unwrap_or_else(|| usage()).split(',').map(|x| x.trim().to_string()).filter(|x| !x.is_empty()).collect())
            }
            "--passphrase" => cfg.passphrase = args.next(),
            "--downloads" => cfg.downloads_dir = args.next().map(Into::into),
            "--relay-delay" => cfg.relay_delay_ms = args.next().and_then(|p| p.parse().ok()).unwrap_or_else(|| usage()),
            "--restore-phrase" => cfg.recovery_phrase = Some(args.next().unwrap_or_else(|| usage())),
            "--restore-backup" => {
                let f = args.next().unwrap_or_else(|| usage());
                let pw = args.next().unwrap_or_else(|| usage());
                cfg.restore_backup = Some((f, pw));
            }
            "--no-nostr" | "--no-directory" => cfg.enable_nostr = false,
            "--bot-token" => cfg.bot_token = Some(args.next().unwrap_or_else(|| usage())),
            "--no-dht" => cfg.enable_dht = false,
            "--no-upnp" => cfg.enable_upnp = false,
            "--no-lan" => cfg.enable_lan = false,
            "--no-lan-multicast" => cfg.lan_multicast = false,
            "--no-mdns" => cfg.mdns = false,
            "--link-pending" => cfg.link_pending = true,
            "--stdio" => stdio = true,
            "-h" | "--help" => usage(),
            _ => usage(),
        }
    }
    if !relays.is_empty() {
        cfg.relays = Some(relays);
    }
    let filter = std::env::var("LUMORA_LOG").unwrap_or_else(|_| "info,quinn=warn,rustls=warn,mainline=warn".into());
    tracing_subscriber::fmt().with_env_filter(filter).with_writer(std::io::stderr).init();

    // stdin is read by one thread for the life of the process; requests are handed to
    // whichever node instance is running (a link approval restarts the node in-process)
    let (req_tx, mut req_rx) = tokio::sync::mpsc::unbounded_channel::<String>();
    if stdio {
        std::thread::spawn(move || {
            for line in std::io::stdin().lock().lines() {
                let Ok(line) = line else { break };
                if req_tx.send(line).is_err() {
                    break;
                }
            }
        });
    }
    loop {
        // a fresh runtime per node instance: stopping it ends every task of the old one
        let rt = tokio::runtime::Builder::new_multi_thread().enable_all().build()?;
        let r = rt.block_on(run(cfg.clone(), stdio, &mut req_rx));
        rt.shutdown_timeout(std::time::Duration::from_secs(2));
        match r? {
            Exit::Quit => break,
            Exit::Restart => {
                cfg.link_pending = false;
                eprintln!("lumorad: restarting (linked / promoted device)");
            }
            Exit::Reset => {
                // signed out of the account: the next start wipes its data (fresh install)
                cfg.link_pending = false;
                cfg.recovery_phrase = None;
                cfg.restore_backup = None;
                eprintln!("lumorad: this device was signed out of its account — starting fresh");
            }
        }
    }
    Ok(())
}

async fn run(cfg: NodeConfig, stdio: bool, req_rx: &mut tokio::sync::mpsc::UnboundedReceiver<String>) -> anyhow::Result<Exit> {
    let node = match Node::start(cfg).await {
        Ok(n) => n,
        Err(e) => {
            let f = lumora_core::i18n::error_fields(&e);
            eprintln!("lumorad: could not start: {}", f["error"].as_str().unwrap_or_default());
            if let Some(d) = f.get("detail").and_then(|d| d.as_str()) {
                eprintln!("  details: {d}");
            }
            std::process::exit(1);
        }
    };
    #[cfg(feature = "media")]
    lumora_core::node::media_pipe::warm_up(&node);
    eprintln!("lumorad ready: {} ({})", node.me.short_id_fmt(), node.me);
    let restart = Arc::new(tokio::sync::Notify::new());
    let reset = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let mut ev = node.subscribe();
    let r2 = restart.clone();
    let reset2 = reset.clone();
    tokio::spawn(async move {
        loop {
            match ev.recv().await {
                Ok(e) => {
                    {
                        let mut out = std::io::stdout().lock();
                        let _ = writeln!(out, "{}", e);
                        let _ = out.flush();
                    }
                    if e["event"] == "link_state" && e["state"] == "restart" {
                        r2.notify_one();
                    }
                    if e["event"] == "device_revoked" {
                        reset2.store(true, std::sync::atomic::Ordering::SeqCst);
                        r2.notify_one();
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(_) => break,
            }
        }
    });
    let exit = if stdio {
        loop {
            tokio::select! {
                line = req_rx.recv() => {
                    let Some(line) = line else { break Exit::Quit }; // stdin closed: graceful exit
                    if line.trim().is_empty() {
                        continue;
                    }
                    let req: serde_json::Value = match serde_json::from_str(&line) {
                        Ok(v) => v,
                        Err(e) => {
                            println!("{}", serde_json::json!({"ok": false, "error": format!("request is not valid JSON: {e}"), "code": "bad_request"}));
                            continue;
                        }
                    };
                    let n = node.clone();
                    tokio::spawn(async move {
                        let resp = lumora_core::api::handle(&n, &req).await;
                        let mut out = std::io::stdout().lock();
                        let _ = writeln!(out, "{}", resp);
                        let _ = out.flush();
                    });
                }
                _ = restart.notified() => {
                    // let the final events/acks go out first
                    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
                    break if reset.load(std::sync::atomic::Ordering::SeqCst) { Exit::Reset } else { Exit::Restart };
                }
            }
        }
    } else {
        tokio::select! {
            r = tokio::signal::ctrl_c() => { r?; Exit::Quit }
            _ = restart.notified() => if reset.load(std::sync::atomic::Ordering::SeqCst) { Exit::Reset } else { Exit::Restart },
        }
    };
    node.shutdown();
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    Ok(exit)
}
