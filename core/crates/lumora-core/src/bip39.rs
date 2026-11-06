//! BIP39 (English) encoding of the 32-byte identity secret as 24 words.
//!
//! 256 bits of entropy + an 8-bit checksum (first byte of SHA-256(entropy)) = 264 bits,
//! cut into 24 indexes of 11 bits into the official 2048-word English list
//! (`bip39_english.txt`, SHA-256 `2f5eed53…3b24dbda`, identical to
//! <https://github.com/bitcoin/bips/blob/master/bip-0039/english.txt>).
//!
//! The entropy *is* the identity secret: there is no PBKDF2 "BIP39 seed" step, so an
//! account maps 1:1 between these words and the older base32 phrase.

use sha2::{Digest, Sha256};
use std::sync::OnceLock;

/// Number of words in a Lumora recovery phrase.
pub const WORDS: usize = 24;

const RAW: &str = include_str!("bip39_english.txt");

/// The official English wordlist (2048 words, sorted).
pub fn wordlist() -> &'static [&'static str] {
    static LIST: OnceLock<Vec<&'static str>> = OnceLock::new();
    LIST.get_or_init(|| {
        let v: Vec<&'static str> = RAW.lines().map(str::trim).filter(|w| !w.is_empty()).collect();
        debug_assert_eq!(v.len(), 2048);
        v
    })
}

/// Index of `token` (already lower-case): an exact word, or — as BIP39 allows — a
/// prefix of at least 4 letters, which always names exactly one word.
pub fn lookup(token: &str) -> Option<usize> {
    let list = wordlist();
    if let Ok(i) = list.binary_search(&token) {
        return Some(i);
    }
    if token.len() < 4 {
        return None;
    }
    let i = list.partition_point(|w| *w < token);
    list.get(i).filter(|w| w.starts_with(token))?;
    // 4-letter prefixes are unique in the English list, so this can't be ambiguous;
    // check anyway so a different list can't silently pick the wrong word.
    let ambiguous = list.get(i + 1).is_some_and(|w| w.starts_with(token));
    (!ambiguous).then_some(i)
}

/// 32 bytes → 24 words separated by single spaces.
pub fn encode(entropy: &[u8; 32]) -> String {
    let list = wordlist();
    let check = Sha256::digest(entropy)[0];
    let mut bits = [0u8; 33];
    bits[..32].copy_from_slice(entropy);
    bits[32] = check;
    (0..WORDS).map(|i| list[index_at(&bits, i)]).collect::<Vec<_>>().join(" ")
}

/// The 11-bit group `i` of `bits` (big-endian).
fn index_at(bits: &[u8; 33], i: usize) -> usize {
    let mut v = 0usize;
    for b in i * 11..i * 11 + 11 {
        v = (v << 1) | ((bits[b / 8] >> (7 - b % 8)) & 1) as usize;
    }
    v
}

/// Why a list of words is not a valid phrase.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DecodeError {
    /// Not 24 words (the count found).
    Count(usize),
    /// Word at this 1-based position is not on the list.
    Word(usize),
    /// All words are known but the checksum doesn't match (a word was miswritten).
    Checksum,
}

/// The words of a phrase as typed / pasted: lower-cased, split on whitespace,
/// commas or dashes, with list numbering ("1.", "7)", "12:") dropped.
pub fn tokens(text: &str) -> Vec<String> {
    text.to_lowercase()
        .split(|c: char| c.is_whitespace() || matches!(c, ',' | ';' | '-' | '/' | '|'))
        .map(|t| t.trim_start_matches(|c: char| c.is_ascii_digit()).trim_start_matches(['.', ')', ':']))
        .filter(|t| !t.is_empty())
        .map(String::from)
        .collect()
}

/// 24 words → the 32-byte entropy (checksum verified).
pub fn decode(words: &[String]) -> Result<[u8; 32], DecodeError> {
    if words.len() != WORDS {
        return Err(DecodeError::Count(words.len()));
    }
    let mut bits = [0u8; 33];
    for (i, w) in words.iter().enumerate() {
        let idx = lookup(w).ok_or(DecodeError::Word(i + 1))?;
        for k in 0..11 {
            if idx >> (10 - k) & 1 == 1 {
                let b = i * 11 + k;
                bits[b / 8] |= 1 << (7 - b % 8);
            }
        }
    }
    let entropy: [u8; 32] = bits[..32].try_into().expect("32 bytes");
    if Sha256::digest(entropy)[0] != bits[32] {
        return Err(DecodeError::Checksum);
    }
    Ok(entropy)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Official BIP39 vectors (trezor/python-mnemonic `vectors.json`, English, 256-bit).
    const VECTORS: &[(&str, &str)] = &[
        ("0000000000000000000000000000000000000000000000000000000000000000", "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art"),
        ("7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f", "legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth title"),
        ("8080808080808080808080808080808080808080808080808080808080808080", "letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic bless"),
        ("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote"),
        ("68a79eaca2324873eacc50cb9c6eca8cc68ea5d936f98787c60c7ebc74e6ce7c", "hamster diagram private dutch cause delay private meat slide toddler razor book happy fancy gospel tennis maple dilemma loan word shrug inflict delay length"),
        ("9f6a2878b2520799a44ef18bc7df394e7061a224d2c33cd015b157d746869863", "panda eyebrow bullet gorilla call smoke muffin taste mesh discover soft ostrich alcohol speed nation flash devote level hobby quick inner drive ghost inside"),
        ("066dca1a2bb7e8a1db2832148ce9933eea0f3ac9548d793112d9a95c9407efad", "all hour make first leader extend hole alien behind guard gospel lava path output census museum junior mass reopen famous sing advance salt reform"),
        ("f585c11aec520db57dd353c69554b21a89b20fb0650966fa0a9d6f74fd989d8f", "void come effort suffer camp survey warrior heavy shoot primary clutch crush open amazing screen patrol group space point ten exist slush involve unfold"),
    ];

    #[test]
    fn official_wordlist() {
        assert_eq!(hex::encode(Sha256::digest(RAW.as_bytes())), "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda");
        let l = wordlist();
        assert_eq!(l.len(), 2048);
        assert!(l.windows(2).all(|w| w[0] < w[1]), "sorted, unique");
        let mut p: Vec<_> = l.iter().map(|w| &w[..w.len().min(4)]).collect();
        p.dedup();
        assert_eq!(p.len(), 2048, "4-letter prefixes are unique");
    }

    #[test]
    fn official_vectors() {
        for (h, words) in VECTORS {
            let e: [u8; 32] = hex::decode(h).unwrap().try_into().unwrap();
            assert_eq!(encode(&e), *words);
            assert_eq!(decode(&tokens(words)).unwrap(), e);
        }
    }

    #[test]
    fn parsing_rules() {
        let (h, words) = VECTORS[4];
        let e: [u8; 32] = hex::decode(h).unwrap().try_into().unwrap();
        // case, newlines, numbering, 4-letter prefixes
        let messy = words
            .split(' ')
            .enumerate()
            .map(|(i, w)| if i % 3 == 0 { format!("{}. {}", i + 1, &w[..w.len().min(4)].to_uppercase()) } else { w.to_string() })
            .collect::<Vec<_>>()
            .join("\n  ");
        assert_eq!(decode(&tokens(&messy)).unwrap(), e);
        assert_eq!(lookup("aban"), Some(0));
        assert_eq!(lookup("act"), wordlist().iter().position(|w| *w == "act"));
        assert_eq!(lookup("ab"), None);
        assert_eq!(lookup("abandonx"), None);
        // errors
        let mut w = tokens(words);
        w[6] = "lumora".into();
        assert_eq!(decode(&w), Err(DecodeError::Word(7)));
        let mut w = tokens(words);
        w.swap(0, 1);
        assert_eq!(decode(&w), Err(DecodeError::Checksum));
        assert_eq!(decode(&tokens("abandon abandon")), Err(DecodeError::Count(2)));
    }
}
