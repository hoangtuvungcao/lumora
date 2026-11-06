//! Open the input injector for the primary display and (only with `--yes`)
//! move the pointer in a tiny 20 px square around the screen centre.
//!
//! cargo run -p lumora-media --example input_test            # just open the injector
//! cargo run -p lumora-media --example input_test -- --yes   # also move the mouse a little
//! LUMORA_INPUT=uinput|portal|xtest overrides backend selection.

use std::time::Duration;

fn main() {
    let yes = std::env::args().any(|a| a == "--yes");
    let displays = lumora_media::list_displays();
    let display = displays.iter().find(|d| d.primary).cloned().or_else(|| displays.first().cloned()).unwrap_or_else(|| {
        lumora_media::DisplayInfo { width: 1920, height: 1080, ..Default::default() }
    });
    println!("displays: {}", serde_json::to_string(&displays).unwrap_or_default());
    println!("target display: {} {}x{}+{}+{}", display.name, display.width, display.height, display.x, display.y);

    let mut inj = match lumora_media::open_injector(&display) {
        Ok(i) => i,
        Err(e) => {
            eprintln!("open_injector failed: {e:#}");
            let d = lumora_media::diag::diagnostics();
            for c in d.checks.iter().filter(|c| !c.ok) {
                eprintln!("- [{}] {}: {}", c.id, c.title, c.detail);
                for s in &c.fix_steps {
                    eprintln!("    $ {s}");
                }
            }
            std::process::exit(1);
        }
    };
    println!("injector opened, backend = {}", inj.backend());
    if !yes {
        // Optionally keep the virtual devices alive for inspection
        // (e.g. `grep -A4 Lumora /proc/bus/input/devices`).
        let args: Vec<String> = std::env::args().collect();
        if let Some(secs) = args.iter().position(|a| a == "--hold").and_then(|i| args.get(i + 1)).and_then(|s| s.parse::<u64>().ok()) {
            println!("holding devices for {secs}s");
            std::thread::sleep(Duration::from_secs(secs));
        }
        println!("(pass --yes to move the mouse in a 20px square)");
        return;
    }
    let (w, h) = (display.width.max(1) as f64, display.height.max(1) as f64);
    let (cx, cy) = (0.5, 0.5);
    let dx = 20.0 / w;
    let dy = 20.0 / h;
    for (x, y) in [(cx, cy), (cx + dx, cy), (cx + dx, cy + dy), (cx, cy + dy), (cx, cy)] {
        if let Err(e) = inj.mouse_move_abs(x, y) {
            eprintln!("mouse_move_abs failed: {e:#}");
            std::process::exit(1);
        }
        println!("moved to ({:.0}, {:.0})", x * w, y * h);
        std::thread::sleep(Duration::from_millis(250));
    }
    println!("done");
}
