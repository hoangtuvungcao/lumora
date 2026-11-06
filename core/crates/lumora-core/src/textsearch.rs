//! Message search that works the way people type: any case, with or without Vietnamese
//! (and other Latin) diacritics, precomposed (NFC) or decomposed (NFD) input alike —
//! "tieng viet", "TIẾNG VIỆT" and "Tiếng Việt" all find "Tiếng Việt". Only what the user
//! wrote is searched (the text, a file's name, a poll / checklist / reminder title…),
//! never the JSON field names or ids of the stored body.

use serde_json::Value;

/// `s` lower-cased, without diacritics, whitespace collapsed to single spaces.
pub fn fold(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut space = true; // (no leading space)
    for c in s.chars() {
        if ('\u{0300}'..='\u{036f}').contains(&c) {
            continue; // combining marks (NFD input)
        }
        if c.is_whitespace() {
            if !space {
                out.push(' ');
                space = true;
            }
            continue;
        }
        space = false;
        for l in c.to_lowercase() {
            out.push(base_letter(l));
        }
    }
    if out.ends_with(' ') {
        out.pop();
    }
    out
}

fn base_letter(c: char) -> char {
    if c.is_ascii() {
        return c;
    }
    match FOLD.binary_search_by(|(k, _)| k.cmp(&c)) {
        Ok(i) => FOLD[i].1,
        Err(_) => c,
    }
}

/// The words of a stored message body (JSON) worth searching, by message kind.
pub fn searchable(kind: &str, body: &Value) -> String {
    let s = |k: &str| body.get(k).and_then(|v| v.as_str()).unwrap_or("");
    match kind {
        "text" => s("text").to_string(),
        "file" => format!("{} {}", s("name"), s("caption")),
        "location" => s("label").to_string(),
        "contact" => s("name").to_string(),
        "poll" => {
            let opts: Vec<&str> = body.get("options").and_then(|o| o.as_array()).map(|a| a.iter().filter_map(|x| x.as_str()).collect()).unwrap_or_default();
            format!("{} {}", s("question"), opts.join(" "))
        }
        "checklist" => {
            let items: Vec<&str> = body
                .get("items")
                .and_then(|o| o.as_array())
                .map(|a| a.iter().filter_map(|x| x.get("text").and_then(|t| t.as_str()).or_else(|| x.as_str())).collect())
                .unwrap_or_default();
            format!("{} {}", s("title"), items.join(" "))
        }
        "reminder" => format!("{} {}", s("title"), s("note")),
        _ => String::new(),
    }
}

/// Does a stored message (kind + JSON body text) match the folded query `q`?
pub fn matches(kind: &str, body_json: &str, q: &str) -> bool {
    if q.is_empty() {
        return false;
    }
    // cheap pre-check on the raw JSON with the query's longest plain word (JSON escapes
    // never split one): most rows end here without being parsed
    if let Some(w) = q.split(|c: char| !c.is_alphanumeric()).max_by_key(|w| w.len()).filter(|w| !w.is_empty()) {
        if body_json.len() < 4096 && !fold(body_json).contains(w) {
            return false;
        }
    }
    let Ok(body) = serde_json::from_str::<Value>(body_json) else { return false };
    let text = searchable(kind, &body);
    !text.is_empty() && fold(&text).contains(q)
}

/// Lower-case Latin letters with diacritics → their base letter (generated from Unicode NFD).
const FOLD: &[(char, char)] = &[
    ('\u{00df}', 's'), ('\u{00e0}', 'a'), ('\u{00e1}', 'a'), ('\u{00e2}', 'a'), ('\u{00e3}', 'a'), ('\u{00e4}', 'a'), ('\u{00e5}', 'a'), ('\u{00e7}', 'c'),
    ('\u{00e8}', 'e'), ('\u{00e9}', 'e'), ('\u{00ea}', 'e'), ('\u{00eb}', 'e'), ('\u{00ec}', 'i'), ('\u{00ed}', 'i'), ('\u{00ee}', 'i'), ('\u{00ef}', 'i'),
    ('\u{00f1}', 'n'), ('\u{00f2}', 'o'), ('\u{00f3}', 'o'), ('\u{00f4}', 'o'), ('\u{00f5}', 'o'), ('\u{00f6}', 'o'), ('\u{00f8}', 'o'), ('\u{00f9}', 'u'),
    ('\u{00fa}', 'u'), ('\u{00fb}', 'u'), ('\u{00fc}', 'u'), ('\u{00fd}', 'y'), ('\u{00ff}', 'y'), ('\u{0101}', 'a'), ('\u{0103}', 'a'), ('\u{0105}', 'a'),
    ('\u{0107}', 'c'), ('\u{0109}', 'c'), ('\u{010b}', 'c'), ('\u{010d}', 'c'), ('\u{010f}', 'd'), ('\u{0111}', 'd'), ('\u{0113}', 'e'), ('\u{0115}', 'e'),
    ('\u{0117}', 'e'), ('\u{0119}', 'e'), ('\u{011b}', 'e'), ('\u{011d}', 'g'), ('\u{011f}', 'g'), ('\u{0121}', 'g'), ('\u{0123}', 'g'), ('\u{0125}', 'h'),
    ('\u{0127}', 'h'), ('\u{0129}', 'i'), ('\u{012b}', 'i'), ('\u{012d}', 'i'), ('\u{012f}', 'i'), ('\u{0135}', 'j'), ('\u{0137}', 'k'), ('\u{013a}', 'l'),
    ('\u{013c}', 'l'), ('\u{013e}', 'l'), ('\u{0142}', 'l'), ('\u{0144}', 'n'), ('\u{0146}', 'n'), ('\u{0148}', 'n'), ('\u{014d}', 'o'), ('\u{014f}', 'o'),
    ('\u{0151}', 'o'), ('\u{0155}', 'r'), ('\u{0157}', 'r'), ('\u{0159}', 'r'), ('\u{015b}', 's'), ('\u{015d}', 's'), ('\u{015f}', 's'), ('\u{0161}', 's'),
    ('\u{0163}', 't'), ('\u{0165}', 't'), ('\u{0167}', 't'), ('\u{0169}', 'u'), ('\u{016b}', 'u'), ('\u{016d}', 'u'), ('\u{016f}', 'u'), ('\u{0171}', 'u'),
    ('\u{0173}', 'u'), ('\u{0175}', 'w'), ('\u{0177}', 'y'), ('\u{017a}', 'z'), ('\u{017c}', 'z'), ('\u{017e}', 'z'), ('\u{0180}', 'b'), ('\u{01a1}', 'o'),
    ('\u{01b0}', 'u'), ('\u{01ce}', 'a'), ('\u{01d0}', 'i'), ('\u{01d2}', 'o'), ('\u{01d4}', 'u'), ('\u{01d6}', 'u'), ('\u{01d8}', 'u'), ('\u{01da}', 'u'),
    ('\u{01dc}', 'u'), ('\u{01df}', 'a'), ('\u{01e1}', 'a'), ('\u{01e7}', 'g'), ('\u{01e9}', 'k'), ('\u{01eb}', 'o'), ('\u{01ed}', 'o'), ('\u{01f0}', 'j'),
    ('\u{01f5}', 'g'), ('\u{01f9}', 'n'), ('\u{01fb}', 'a'), ('\u{0201}', 'a'), ('\u{0203}', 'a'), ('\u{0205}', 'e'), ('\u{0207}', 'e'), ('\u{0209}', 'i'),
    ('\u{020b}', 'i'), ('\u{020d}', 'o'), ('\u{020f}', 'o'), ('\u{0211}', 'r'), ('\u{0213}', 'r'), ('\u{0215}', 'u'), ('\u{0217}', 'u'), ('\u{0219}', 's'),
    ('\u{021b}', 't'), ('\u{021f}', 'h'), ('\u{0227}', 'a'), ('\u{0229}', 'e'), ('\u{022b}', 'o'), ('\u{022d}', 'o'), ('\u{022f}', 'o'), ('\u{0231}', 'o'),
    ('\u{0233}', 'y'), ('\u{0268}', 'i'), ('\u{0289}', 'u'), ('\u{1e01}', 'a'), ('\u{1e03}', 'b'), ('\u{1e05}', 'b'), ('\u{1e07}', 'b'), ('\u{1e09}', 'c'),
    ('\u{1e0b}', 'd'), ('\u{1e0d}', 'd'), ('\u{1e0f}', 'd'), ('\u{1e11}', 'd'), ('\u{1e13}', 'd'), ('\u{1e15}', 'e'), ('\u{1e17}', 'e'), ('\u{1e19}', 'e'),
    ('\u{1e1b}', 'e'), ('\u{1e1d}', 'e'), ('\u{1e1f}', 'f'), ('\u{1e21}', 'g'), ('\u{1e23}', 'h'), ('\u{1e25}', 'h'), ('\u{1e27}', 'h'), ('\u{1e29}', 'h'),
    ('\u{1e2b}', 'h'), ('\u{1e2d}', 'i'), ('\u{1e2f}', 'i'), ('\u{1e31}', 'k'), ('\u{1e33}', 'k'), ('\u{1e35}', 'k'), ('\u{1e37}', 'l'), ('\u{1e39}', 'l'),
    ('\u{1e3b}', 'l'), ('\u{1e3d}', 'l'), ('\u{1e3f}', 'm'), ('\u{1e41}', 'm'), ('\u{1e43}', 'm'), ('\u{1e45}', 'n'), ('\u{1e47}', 'n'), ('\u{1e49}', 'n'),
    ('\u{1e4b}', 'n'), ('\u{1e4d}', 'o'), ('\u{1e4f}', 'o'), ('\u{1e51}', 'o'), ('\u{1e53}', 'o'), ('\u{1e55}', 'p'), ('\u{1e57}', 'p'), ('\u{1e59}', 'r'),
    ('\u{1e5b}', 'r'), ('\u{1e5d}', 'r'), ('\u{1e5f}', 'r'), ('\u{1e61}', 's'), ('\u{1e63}', 's'), ('\u{1e65}', 's'), ('\u{1e67}', 's'), ('\u{1e69}', 's'),
    ('\u{1e6b}', 't'), ('\u{1e6d}', 't'), ('\u{1e6f}', 't'), ('\u{1e71}', 't'), ('\u{1e73}', 'u'), ('\u{1e75}', 'u'), ('\u{1e77}', 'u'), ('\u{1e79}', 'u'),
    ('\u{1e7b}', 'u'), ('\u{1e7d}', 'v'), ('\u{1e7f}', 'v'), ('\u{1e81}', 'w'), ('\u{1e83}', 'w'), ('\u{1e85}', 'w'), ('\u{1e87}', 'w'), ('\u{1e89}', 'w'),
    ('\u{1e8b}', 'x'), ('\u{1e8d}', 'x'), ('\u{1e8f}', 'y'), ('\u{1e91}', 'z'), ('\u{1e93}', 'z'), ('\u{1e95}', 'z'), ('\u{1e96}', 'h'), ('\u{1e97}', 't'),
    ('\u{1e98}', 'w'), ('\u{1e99}', 'y'), ('\u{1ea1}', 'a'), ('\u{1ea3}', 'a'), ('\u{1ea5}', 'a'), ('\u{1ea7}', 'a'), ('\u{1ea9}', 'a'), ('\u{1eab}', 'a'),
    ('\u{1ead}', 'a'), ('\u{1eaf}', 'a'), ('\u{1eb1}', 'a'), ('\u{1eb3}', 'a'), ('\u{1eb5}', 'a'), ('\u{1eb7}', 'a'), ('\u{1eb9}', 'e'), ('\u{1ebb}', 'e'),
    ('\u{1ebd}', 'e'), ('\u{1ebf}', 'e'), ('\u{1ec1}', 'e'), ('\u{1ec3}', 'e'), ('\u{1ec5}', 'e'), ('\u{1ec7}', 'e'), ('\u{1ec9}', 'i'), ('\u{1ecb}', 'i'),
    ('\u{1ecd}', 'o'), ('\u{1ecf}', 'o'), ('\u{1ed1}', 'o'), ('\u{1ed3}', 'o'), ('\u{1ed5}', 'o'), ('\u{1ed7}', 'o'), ('\u{1ed9}', 'o'), ('\u{1edb}', 'o'),
    ('\u{1edd}', 'o'), ('\u{1edf}', 'o'), ('\u{1ee1}', 'o'), ('\u{1ee3}', 'o'), ('\u{1ee5}', 'u'), ('\u{1ee7}', 'u'), ('\u{1ee9}', 'u'), ('\u{1eeb}', 'u'),
    ('\u{1eed}', 'u'), ('\u{1eef}', 'u'), ('\u{1ef1}', 'u'), ('\u{1ef3}', 'y'), ('\u{1ef5}', 'y'), ('\u{1ef7}', 'y'), ('\u{1ef9}', 'y'),
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vietnamese_any_case_with_or_without_marks() {
        let t = "Tiếng Việt có dấu: Chúc mừng năm mới, Đà Nẵng!";
        for q in ["tiếng việt", "TIẾNG VIỆT", "tieng viet", "Tieng Viet", "chuc mung nam moi", "da nang", "đà nẵng", "ĐÀ NẴNG"] {
            assert!(fold(t).contains(&fold(q)), "{q}");
        }
        // decomposed input (macOS / some keyboards) folds the same
        let nfd = "Tie\u{0302}\u{0301}ng Vie\u{0323}\u{0302}t";
        assert_eq!(fold(nfd), "tieng viet");
        assert_eq!(fold("  a \n\t b  "), "a b");
        assert!(!fold(t).contains(&fold("tieng anh")));
    }

    #[test]
    fn only_what_the_user_wrote() {
        let body = r#"{"text":"xin chào"}"#;
        assert!(matches("text", body, &fold("xin chao")));
        assert!(!matches("text", body, "text"), "a JSON key is not text");
        assert!(!matches("text", body, ""));
        assert!(matches("file", r#"{"name":"Báo cáo quý.pdf","file_id":"ab"}"#, &fold("bao cao")));
        assert!(!matches("file", r#"{"name":"x.pdf","file_id":"abcdef"}"#, "abcdef"));
        assert!(matches("checklist", r#"{"title":"Việc","items":[{"id":1,"text":"Mua sữa"}]}"#, &fold("mua sua")));
        assert!(matches("poll", r#"{"question":"Đi đâu?","options":["Hà Nội","Huế"]}"#, &fold("ha noi")));
        assert!(matches("reminder", r#"{"title":"Họp","note":"phòng số 2"}"#, &fold("phong so")));
        assert!(!matches("sticker", r#"{"emoji":"x"}"#, "x"));
    }
}
