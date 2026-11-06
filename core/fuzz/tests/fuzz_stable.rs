//! Stable-Rust driver for the fuzz targets (no nightly, no libFuzzer):
//! 1. replays every stored input in `regressions/<target>/` (crashes found and fixed —
//!    each one must keep passing) and `corpus/<target>/` when present;
//! 2. runs a seeded random + mutation search (quickcheck-style) over every target.
//!
//! `FUZZ_ITERS=200000 cargo test --release -- --nocapture` for a longer run.

use std::path::Path;

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        // xorshift64*
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n.max(1) as u64) as usize
    }
}

fn files(dir: &Path) -> Vec<Vec<u8>> {
    let mut v: Vec<_> = std::fs::read_dir(dir).map(|d| d.flatten().map(|e| e.path()).collect()).unwrap_or_default();
    v.sort();
    v.into_iter().filter(|p| p.is_file()).filter_map(|p| std::fs::read(p).ok()).collect()
}

/// Interesting fragments: MessagePack headers, JSON, the wire magic numbers.
const TOKENS: &[&[u8]] = &[
    b"\x81\xa4Chat", b"\x81\xa7Wrapped\x92", b"\x81\xa4Ping\x91\x01", b"\xdc\xff\xff", b"\xdd\xff\xff\xff\xff", b"\xc4\xff",
    b"\xc5\xff\xff", b"\xc6\xff\xff\xff\xff", b"\xde\xff\xff", b"\x00LPV\x01", b"\x21\x12\xa4\x42", b"\x00\x01\x00\x00",
    b"\x01\x01\x00\x0c", b"\x00\x20\x00\x08", b"lumora_bot_", b"lumora://join/", b"lumora://link/", b"[\"EVENT\",\"s\",{",
    b"{\"content\":\"{\\\"peer\\\":\\\"", b"\"$peer\"", b"\"$gid\"", b"\"$gconv\"", b"{\"peer\":\"$peer\",\"text\":\"x\"}",
    b"abandon ", b"zoo ", b"-", b"\n", b"\xff\xff\xff\xff", b"\x00\x00\x00\x10",
];

fn mutate(r: &mut Rng, seed: &[u8]) -> Vec<u8> {
    let mut v = seed.to_vec();
    for _ in 0..=r.below(6) {
        match r.below(7) {
            0 if !v.is_empty() => {
                let i = r.below(v.len());
                v[i] ^= 1 << r.below(8);
            }
            1 if !v.is_empty() => {
                let i = r.below(v.len());
                v[i] = r.next() as u8;
            }
            2 => {
                let t = TOKENS[r.below(TOKENS.len())];
                let i = r.below(v.len() + 1);
                v.splice(i..i, t.iter().copied());
            }
            3 if !v.is_empty() => {
                let i = r.below(v.len());
                let n = r.below(v.len() - i + 1);
                v.drain(i..i + n);
            }
            4 => {
                let n = r.below(64);
                v.extend((0..n).map(|_| r.next() as u8));
            }
            5 if !v.is_empty() => {
                // duplicate a slice (repetition / nesting)
                let i = r.below(v.len());
                let n = r.below((v.len() - i).min(64) + 1);
                let s: Vec<u8> = v[i..i + n].to_vec();
                for _ in 0..r.below(8) {
                    v.extend_from_slice(&s);
                }
            }
            _ => v.truncate(r.below(v.len() + 1)),
        }
    }
    v.truncate(1 << 16);
    v
}

fn run(name: &str, f: fn(&[u8]), iters: usize) {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let mut seeds = files(&root.join("regressions").join(name));
    let n_reg = seeds.len();
    for s in &seeds {
        f(s);
    }
    let corpus = files(&root.join("corpus").join(name));
    for s in &corpus {
        f(s);
    }
    seeds.extend(corpus.into_iter().take(2000));
    seeds.push(Vec::new());
    let mut r = Rng(0x9E37_79B9_7F4A_7C15 ^ name.len() as u64 ^ (name.as_bytes()[0] as u64) << 32);
    for i in 0..iters {
        let input = if i % 4 == 0 {
            (0..r.below(512)).map(|_| r.next() as u8).collect()
        } else {
            let s = &seeds[r.below(seeds.len())];
            mutate(&mut r, s)
        };
        let res = std::panic::catch_unwind(|| f(&input));
        if res.is_err() {
            let out = std::env::temp_dir().join(format!("lumora-fuzz-{name}-{i}.bin"));
            let _ = std::fs::write(&out, &input);
            panic!("{name}: input #{i} panicked; saved to {}", out.display());
        }
    }
    eprintln!("{name}: {n_reg} regressions + {iters} generated inputs ok");
}

fn iters(default: usize) -> usize {
    std::env::var("FUZZ_ITERS").ok().and_then(|s| s.parse().ok()).unwrap_or(default)
}

macro_rules! target_tests {
    ($($name:ident: $n:expr),* $(,)?) => {$(
        #[test]
        fn $name() {
            run(stringify!($name), lumora_fuzz::$name, iters($n));
        }
    )*};
}

target_tests! {
    peer_frame: 20_000,
    chat_group: 5_000,
    group_fold: 1_000,
    file_preview: 20_000,
    bot_token: 3_000,
    invite: 3_000,
    recovery_phrase: 3_000,
    relay_proto: 20_000,
    stun: 20_000,
    nostr: 10_000,
    push_bridge: 10_000,
    api_json: 300,
}

#[test]
fn every_target_has_a_test() {
    assert_eq!(lumora_fuzz::TARGETS.len(), 12);
}
