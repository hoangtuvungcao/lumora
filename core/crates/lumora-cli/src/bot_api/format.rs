//! `parse_mode` → Lumora's own text markup.
//!
//! Lumora apps draw `**bold**`, `_italic_`, `~~strike~~`, `` `code` ``, ```` ```block``` ````
//! and `||spoiler||` in every text message, plus tappable links. The three Bot API parse modes
//! are translated into that markup; what Lumora can't draw is kept as plain text:
//! underline (the text stays, unstyled), links with a label (`label (url)`), custom emoji
//! (the fallback emoji), block quotes (plain lines).

/// Translate `text` written for `parse_mode` (case-insensitive; `None`/empty = as is).
pub fn to_lumora(text: &str, parse_mode: Option<&str>) -> Result<String, String> {
    match parse_mode.map(|m| m.trim().to_ascii_lowercase()).as_deref() {
        None | Some("") => Ok(text.to_string()),
        Some("markdownv2") => Ok(markdown(text, true)),
        Some("markdown") => Ok(markdown(text, false)),
        Some("html") => Ok(html(text)),
        Some(other) => Err(format!("Bad Request: unsupported parse_mode '{other}' (use MarkdownV2, Markdown or HTML)")),
    }
}

/// MarkdownV2 (`v2`) or legacy Markdown.
fn markdown(text: &str, v2: bool) -> String {
    let c: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len() + 8);
    md_run(&c, 0, c.len(), v2, &mut out);
    out
}

fn md_run(c: &[char], mut i: usize, end: usize, v2: bool, out: &mut String) {
    while i < end {
        let ch = c[i];
        let next = c.get(i + 1).copied().filter(|_| i + 1 < end);
        match ch {
            '\\' if next.is_some() => {
                out.push(next.unwrap_or_default());
                i += 2;
            }
            '`' if c[i..end].starts_with(&['`', '`', '`']) => {
                // pre block: ```lang\n…``` — the language tag is dropped
                let body_start = i + 3;
                let close = find_seq(c, body_start, end, &['`', '`', '`']).unwrap_or(end);
                let mut body: String = unescape_code(&c[body_start..close], v2);
                if let Some(nl) = body.find('\n') {
                    if !body[..nl].contains(' ') && nl < 32 {
                        body = body[nl + 1..].to_string();
                    }
                }
                out.push_str("```\n");
                out.push_str(&body);
                if !body.ends_with('\n') {
                    out.push('\n');
                }
                out.push_str("```");
                i = (close + 3).min(end);
            }
            '`' => {
                let close = find_char(c, i + 1, end, '`', v2).unwrap_or(end);
                out.push('`');
                out.push_str(&unescape_code(&c[i + 1..close], v2));
                out.push('`');
                i = (close + 1).min(end);
            }
            '[' => {
                // [label](url)
                if let Some(rb) = find_char(c, i + 1, end, ']', true) {
                    if c.get(rb + 1) == Some(&'(') {
                        if let Some(rp) = find_char(c, rb + 2, end, ')', true) {
                            let mut label = String::new();
                            md_run(c, i + 1, rb, v2, &mut label);
                            let url: String = unescape_code(&c[rb + 2..rp], true);
                            push_link(out, &label, &url);
                            i = rp + 1;
                            continue;
                        }
                    }
                }
                out.push('[');
                i += 1;
            }
            '*' => {
                out.push_str("**");
                i += 1;
            }
            '_' if v2 && next == Some('_') => {
                // __underline__: no underline in Lumora, keep the text
                i += 2;
            }
            '_' => {
                out.push('_');
                i += 1;
            }
            '~' if v2 => {
                out.push_str("~~");
                i += 1;
            }
            '|' if v2 && next == Some('|') => {
                out.push_str("||");
                i += 2;
            }
            '!' if v2 && next == Some('[') => {
                // ![👍](tg://emoji?id=…): custom emoji → its fallback emoji
                if let Some(rb) = find_char(c, i + 2, end, ']', true) {
                    if c.get(rb + 1) == Some(&'(') {
                        if let Some(rp) = find_char(c, rb + 2, end, ')', true) {
                            md_run(c, i + 2, rb, v2, out);
                            i = rp + 1;
                            continue;
                        }
                    }
                }
                out.push('!');
                i += 1;
            }
            '>' if v2 && (i == 0 || c[i - 1] == '\n') => {
                // block quote marker: dropped (plain lines)
                i += 1;
                if c.get(i) == Some(&'>') {
                    i += 1; // expandable quote ">>"? keep it simple
                }
            }
            _ => {
                out.push(ch);
                i += 1;
            }
        }
    }
}

fn push_link(out: &mut String, label: &str, url: &str) {
    let label = label.trim();
    if url.starts_with("tg://user?id=") || url.is_empty() {
        out.push_str(label); // mentions by numeric user id mean nothing here
    } else if label.is_empty() || label == url {
        out.push_str(url);
    } else {
        out.push_str(label);
        out.push_str(" (");
        out.push_str(url);
        out.push(')');
    }
}

/// Index of `ch` in `c[from..end]`, skipping backslash escapes when `esc`.
fn find_char(c: &[char], from: usize, end: usize, ch: char, esc: bool) -> Option<usize> {
    let mut i = from;
    while i < end {
        if esc && c[i] == '\\' {
            i += 2;
            continue;
        }
        if c[i] == ch {
            return Some(i);
        }
        i += 1;
    }
    None
}

fn find_seq(c: &[char], from: usize, end: usize, seq: &[char]) -> Option<usize> {
    let mut i = from;
    while i + seq.len() <= end {
        if c[i] == '\\' {
            i += 2;
            continue;
        }
        if c[i..].starts_with(seq) {
            return Some(i);
        }
        i += 1;
    }
    None
}

/// Inside code (and URLs) MarkdownV2 only escapes `` ` `` and `\` (and `)`).
fn unescape_code(c: &[char], v2: bool) -> String {
    let mut s = String::with_capacity(c.len());
    let mut i = 0;
    while i < c.len() {
        if v2 && c[i] == '\\' && i + 1 < c.len() {
            s.push(c[i + 1]);
            i += 2;
        } else {
            s.push(c[i]);
            i += 1;
        }
    }
    s
}

/// Bot API HTML: b/strong, i/em, s/strike/del, u/ins, code, pre, a href, tg-spoiler,
/// span class="tg-spoiler", blockquote, tg-emoji; entities &lt; &gt; &amp; &quot; &#N; &#xN;.
/// Unknown tags are dropped (their text is kept).
fn html(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    // open <a> tags: (position in `out` where the label starts, href)
    let mut links: Vec<(usize, String)> = Vec::new();
    let mut in_pre = 0usize;
    while let Some(lt) = rest.find(['<', '&']) {
        out.push_str(&rest[..lt]);
        rest = &rest[lt..];
        if rest.starts_with('&') {
            let semi = rest.find(';').filter(|&k| k <= 10);
            match semi.and_then(|k| entity(&rest[1..k]).map(|ch| (k, ch))) {
                Some((k, ch)) => {
                    out.push(ch);
                    rest = &rest[k + 1..];
                }
                None => {
                    out.push('&');
                    rest = &rest[1..];
                }
            }
            continue;
        }
        let Some(gt) = rest.find('>') else {
            out.push_str(rest);
            rest = "";
            break;
        };
        let tag = &rest[1..gt];
        rest = &rest[gt + 1..];
        let closing = tag.starts_with('/');
        let tag = tag.trim_start_matches('/').trim();
        let name: String = tag.split(|c: char| c.is_whitespace()).next().unwrap_or("").to_ascii_lowercase();
        match name.as_str() {
            "b" | "strong" => out.push_str("**"),
            "i" | "em" => out.push('_'),
            "s" | "strike" | "del" => out.push_str("~~"),
            "tg-spoiler" => out.push_str("||"),
            "span" if closing || tag.contains("tg-spoiler") => out.push_str("||"),
            "code" if in_pre == 0 => out.push('`'),
            "pre" => {
                if closing {
                    in_pre = in_pre.saturating_sub(1);
                    if !out.ends_with('\n') {
                        out.push('\n');
                    }
                    out.push_str("```");
                } else {
                    in_pre += 1;
                    out.push_str("```\n");
                }
            }
            "a" => {
                if closing {
                    if let Some((start, href)) = links.pop() {
                        let label = out.split_off(start);
                        push_link(&mut out, &label, &href);
                    }
                } else {
                    links.push((out.len(), attr(tag, "href").unwrap_or_default()));
                }
            }
            "br" => out.push('\n'),
            _ => {} // u, ins, blockquote, tg-emoji and unknown tags: text only
        }
    }
    out.push_str(rest);
    out
}

fn attr(tag: &str, name: &str) -> Option<String> {
    let i = tag.find(&format!("{name}="))?;
    let v = &tag[i + name.len() + 1..];
    let (q, v) = match v.chars().next()? {
        '"' => ('"', &v[1..]),
        '\'' => ('\'', &v[1..]),
        _ => (' ', v),
    };
    let end = v.find(q).unwrap_or(v.len());
    Some(html(&v[..end]))
}

fn entity(name: &str) -> Option<char> {
    Some(match name {
        "lt" => '<',
        "gt" => '>',
        "amp" => '&',
        "quot" => '"',
        "apos" => '\'',
        "nbsp" => '\u{a0}',
        _ => {
            let n = name.strip_prefix('#')?;
            let v = match n.strip_prefix(['x', 'X']) {
                Some(h) => u32::from_str_radix(h, 16).ok()?,
                None => n.parse().ok()?,
            };
            char::from_u32(v)?
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_is_untouched() {
        assert_eq!(to_lumora("a *b* _c_", None).unwrap(), "a *b* _c_");
        assert!(to_lumora("x", Some("bbcode")).is_err());
    }

    #[test]
    fn markdown_v2() {
        let t = to_lumora(r"*bold* _it_ __under__ ~gone~ ||secret|| `x\`y` [Lumora](https://example.com/a\)b) 1\.5\!", Some("MarkdownV2")).unwrap();
        assert_eq!(t, "**bold** _it_ under ~~gone~~ ||secret|| `x`y` Lumora (https://example.com/a)b) 1.5!");
        let t = to_lumora("```rust\nfn main() {}\n```", Some("MarkdownV2")).unwrap();
        assert_eq!(t, "```\nfn main() {}\n```");
        assert_eq!(to_lumora("[https://a.b](https://a.b)", Some("MarkdownV2")).unwrap(), "https://a.b");
    }

    #[test]
    fn markdown_legacy() {
        let t = to_lumora("*bold* _it_ ~x~ `c` [t](http://u)", Some("markdown")).unwrap();
        assert_eq!(t, "**bold** _it_ ~x~ `c` t (http://u)");
    }

    #[test]
    fn html_mode() {
        let t = to_lumora(
            r#"<b>B</b> <i>I</i> <u>U</u> <s>S</s> <tg-spoiler>P</tg-spoiler> <code>a&lt;b</code> <a href="https://x.y/?a=1&amp;b=2">link</a> &#9731;"#,
            Some("HTML"),
        )
        .unwrap();
        assert_eq!(t, "**B** _I_ U ~~S~~ ||P|| `a<b` link (https://x.y/?a=1&b=2) ☃");
        let t = to_lumora("<pre><code class=\"language-py\">print(1)</code></pre>", Some("HTML")).unwrap();
        assert_eq!(t, "```\nprint(1)\n```");
        assert_eq!(to_lumora("a & b <unknown>c</unknown>", Some("HTML")).unwrap(), "a & b c");
    }
}
