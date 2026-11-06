// Coverage sanity check for the api_json target: which commands succeed on the corpus.
fn main() {
    let dir = std::env::args().nth(1).unwrap();
    let mut ok = std::collections::BTreeMap::<String, (u32, u32)>::new();
    for e in std::fs::read_dir(dir).unwrap().flatten() {
        let d = std::fs::read(e.path()).unwrap();
        if let Some((cmd, resp)) = lumora_fuzz::api_json_debug(&d) {
            let x = ok.entry(cmd).or_default();
            if resp["ok"] == true { x.0 += 1 } else { x.1 += 1 }
        }
    }
    let good = ok.values().filter(|v| v.0 > 0).count();
    println!("{good}/{} commands reached success: {:?}", ok.len(), ok.iter().filter(|(_, v)| v.0 == 0).map(|(k, _)| k).collect::<Vec<_>>());
}
