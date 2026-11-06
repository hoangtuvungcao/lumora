//! Print Lumora's environment diagnostics as JSON.
//!
//! cargo run -p lumora-media --example diag

fn main() {
    let d = lumora_media::diag::diagnostics();
    match serde_json::to_string_pretty(&d) {
        Ok(s) => println!("{s}"),
        Err(e) => eprintln!("cannot serialise diagnostics: {e}"),
    }
    eprintln!("all_ok = {}", d.all_ok());
}
