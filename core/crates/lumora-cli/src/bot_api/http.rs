//! Small HTTP helpers for the Bot API: a minimal HTTP/1.1 client (webhook deliveries, over
//! TCP or TLS with the Mozilla roots) and request parameter parsing (query string,
//! urlencoded form, JSON, multipart/form-data) the way Bot API clients send them.

use anyhow::{anyhow, bail, Result};
use serde_json::{Map, Value};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

/// Response bodies read by the client are cut here.
const MAX_RESPONSE: u64 = 1 << 20;

pub struct Response {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Response {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers.iter().find(|(k, _)| k.eq_ignore_ascii_case(name)).map(|(_, v)| v.as_str())
    }
}

/// `method url` with `headers` and `body`; `Connection: close`, one request per connection.
pub async fn request(method: &str, url: &str, headers: &[(&str, &str)], body: &[u8], timeout: Duration) -> Result<Response> {
    let (tls, rest) = if let Some(r) = url.strip_prefix("https://") {
        (true, r)
    } else if let Some(r) = url.strip_prefix("http://") {
        (false, r)
    } else {
        bail!("the URL must start with http:// or https://");
    };
    let (authority, path) = match rest.find(['/', '?']) {
        Some(i) if rest[i..].starts_with('?') => (&rest[..i], format!("/{}", &rest[i..])),
        Some(i) => (&rest[..i], rest[i..].to_string()),
        None => (rest, "/".to_string()),
    };
    let authority = authority.rsplit('@').next().unwrap_or(authority); // no user:pass@
    anyhow::ensure!(!authority.is_empty(), "the URL has no host");
    let (host, port) = if let Some(v6) = authority.strip_prefix('[') {
        let (h, after) = v6.split_once(']').ok_or_else(|| anyhow!("bad IPv6 host"))?;
        let port = match after.strip_prefix(':') {
            Some(p) => p.parse::<u16>()?,
            None => if tls { 443 } else { 80 },
        };
        (h.to_string(), port)
    } else {
        match authority.rsplit_once(':') {
            Some((h, p)) => (h.to_string(), p.parse::<u16>()?),
            None => (authority.to_string(), if tls { 443 } else { 80 }),
        }
    };
    let mut head = format!("{method} {path} HTTP/1.1\r\nHost: {authority}\r\nContent-Length: {}\r\nUser-Agent: lumora-bot-api\r\nConnection: close\r\n", body.len());
    for (k, v) in headers {
        anyhow::ensure!(!k.contains(['\r', '\n']) && !v.contains(['\r', '\n']), "bad header");
        head.push_str(&format!("{k}: {v}\r\n"));
    }
    head.push_str("\r\n");
    let mut req = head.into_bytes();
    req.extend_from_slice(body);
    let fut = async {
        let tcp = tokio::net::TcpStream::connect((host.as_str(), port)).await?;
        let raw = if tls {
            let mut roots = tokio_rustls::rustls::RootCertStore::empty();
            roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
            let cfg = tokio_rustls::rustls::ClientConfig::builder_with_provider(Arc::new(tokio_rustls::rustls::crypto::ring::default_provider()))
                .with_safe_default_protocol_versions()?
                .with_root_certificates(roots)
                .with_no_client_auth();
            let name = tokio_rustls::rustls::pki_types::ServerName::try_from(host.clone())?;
            let s = tokio_rustls::TlsConnector::from(Arc::new(cfg)).connect(name, tcp).await?;
            exchange(s, &req).await?
        } else {
            exchange(tcp, &req).await?
        };
        parse_response(&raw)
    };
    tokio::time::timeout(timeout, fut).await.map_err(|_| anyhow!("timed out after {} s", timeout.as_secs()))?
}

async fn exchange<S: AsyncRead + AsyncWrite + Unpin>(mut s: S, req: &[u8]) -> Result<Vec<u8>> {
    s.write_all(req).await?;
    s.flush().await?;
    let mut resp = Vec::new();
    // a TLS peer that closes without close_notify still gave us the whole response
    let r = (&mut s).take(MAX_RESPONSE + 64 * 1024).read_to_end(&mut resp).await;
    if resp.is_empty() {
        r?;
        bail!("empty response");
    }
    Ok(resp)
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || hay.len() < needle.len() {
        return None;
    }
    let first = needle[0];
    let mut i = 0;
    while i + needle.len() <= hay.len() {
        match hay[i..hay.len() - needle.len() + 1].iter().position(|&b| b == first) {
            Some(k) => i += k,
            None => return None,
        }
        if &hay[i..i + needle.len()] == needle {
            return Some(i);
        }
        i += 1;
    }
    None
}

fn parse_response(raw: &[u8]) -> Result<Response> {
    let end = find(raw, b"\r\n\r\n").ok_or_else(|| anyhow!("bad HTTP response"))?;
    let head = String::from_utf8_lossy(&raw[..end]);
    let mut lines = head.split("\r\n");
    let status: u16 = lines.next().and_then(|l| l.split_whitespace().nth(1)).and_then(|c| c.parse().ok()).ok_or_else(|| anyhow!("bad HTTP status line"))?;
    let headers: Vec<(String, String)> =
        lines.filter_map(|l| l.split_once(':')).map(|(k, v)| (k.trim().to_string(), v.trim().to_string())).collect();
    let mut body = raw[end + 4..].to_vec();
    let chunked = headers.iter().any(|(k, v)| k.eq_ignore_ascii_case("transfer-encoding") && v.to_ascii_lowercase().contains("chunked"));
    if chunked {
        body = dechunk(&body);
    } else if let Some(n) = headers.iter().find(|(k, _)| k.eq_ignore_ascii_case("content-length")).and_then(|(_, v)| v.parse::<usize>().ok()) {
        body.truncate(n);
    }
    body.truncate(MAX_RESPONSE as usize);
    Ok(Response { status, headers, body })
}

/// Decode a chunked body (whatever the webhook server sends: never panics, never more
/// than [`MAX_RESPONSE`] bytes; a chunk size like `ffffffffffffffff` just ends the body).
fn dechunk(mut b: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    while let Some(nl) = find(b, b"\r\n") {
        let size = std::str::from_utf8(&b[..nl]).ok().and_then(|s| usize::from_str_radix(s.split(';').next().unwrap_or("").trim(), 16).ok());
        let Some(size) = size else { break };
        let Some(end) = (nl + 2).checked_add(size) else { break };
        if size == 0 || b.len() < end || out.len().saturating_add(size) > MAX_RESPONSE as usize {
            break;
        }
        out.extend_from_slice(&b[nl + 2..end]);
        b = &b[end.saturating_add(2).min(b.len())..];
    }
    out
}

// ----------------------------------------------------------------------------- parameters

/// A file part of a multipart request.
pub struct Upload {
    pub filename: String,
    pub data: Vec<u8>,
}

/// Method parameters from the query string and the body (JSON, form or multipart).
#[derive(Default)]
pub struct Params {
    pub map: Map<String, Value>,
    pub files: HashMap<String, Upload>,
}

impl Params {
    pub fn parse(query: Option<&str>, content_type: Option<&str>, body: &[u8]) -> Result<Params, String> {
        let mut p = Params::default();
        if let Some(q) = query {
            for (k, v) in form_urlencoded::parse(q.as_bytes()) {
                p.map.insert(k.into_owned(), Value::String(v.into_owned()));
            }
        }
        let ct = content_type.unwrap_or("").to_ascii_lowercase();
        if body.iter().all(|b| b.is_ascii_whitespace()) {
            return Ok(p);
        }
        if ct.starts_with("application/json") || (ct.is_empty() && body.first() == Some(&b'{')) {
            match serde_json::from_slice::<Value>(body) {
                Ok(Value::Object(m)) => p.map.extend(m),
                Ok(_) => return Err("Bad Request: the JSON body must be an object".into()),
                Err(e) => return Err(format!("Bad Request: invalid JSON body: {e}")),
            }
        } else if ct.starts_with("multipart/form-data") {
            let boundary = content_type
                .unwrap_or("")
                .split(';')
                .filter_map(|x| x.trim().split_once('='))
                .find(|(k, _)| k.eq_ignore_ascii_case("boundary"))
                .map(|(_, v)| v.trim_matches('"').to_string())
                .ok_or("Bad Request: multipart body without a boundary")?;
            multipart(body, &boundary, &mut p)?;
        } else {
            for (k, v) in form_urlencoded::parse(body) {
                p.map.insert(k.into_owned(), Value::String(v.into_owned()));
            }
        }
        Ok(p)
    }

    pub fn get(&self, k: &str) -> Option<&Value> {
        self.map.get(k).filter(|v| !v.is_null())
    }

    /// A string parameter (numbers are given as text too).
    pub fn str(&self, k: &str) -> Option<String> {
        match self.get(k)? {
            Value::String(s) => Some(s.clone()),
            Value::Number(n) => Some(n.to_string()),
            Value::Bool(b) => Some(b.to_string()),
            _ => None,
        }
    }

    pub fn int(&self, k: &str) -> Option<i64> {
        match self.get(k)? {
            Value::Number(n) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)),
            Value::String(s) => s.trim().parse().ok(),
            _ => None,
        }
    }

    pub fn float(&self, k: &str) -> Option<f64> {
        match self.get(k)? {
            Value::Number(n) => n.as_f64(),
            Value::String(s) => s.trim().parse().ok(),
            _ => None,
        }
    }

    pub fn bool(&self, k: &str) -> bool {
        match self.get(k) {
            Some(Value::Bool(b)) => *b,
            Some(Value::String(s)) => matches!(s.trim().to_ascii_lowercase().as_str(), "true" | "1" | "yes"),
            Some(Value::Number(n)) => n.as_i64().unwrap_or(0) != 0,
            _ => false,
        }
    }

    /// A JSON parameter: an object/array, or a string holding JSON (form / multipart).
    pub fn json(&self, k: &str) -> Result<Option<Value>, String> {
        match self.get(k) {
            None => Ok(None),
            Some(Value::String(s)) if s.trim().is_empty() => Ok(None),
            Some(Value::String(s)) => serde_json::from_str(s).map(Some).map_err(|e| format!("Bad Request: can't parse {k} JSON: {e}")),
            Some(v) => Ok(Some(v.clone())),
        }
    }
}

fn multipart(body: &[u8], boundary: &str, p: &mut Params) -> Result<(), String> {
    let delim = format!("--{boundary}");
    let sep = format!("\r\n--{boundary}");
    let bad = || "Bad Request: malformed multipart body".to_string();
    let mut pos = find(body, delim.as_bytes()).ok_or_else(bad)? + delim.len();
    loop {
        let rest = &body[pos..];
        if rest.starts_with(b"--") {
            return Ok(());
        }
        let rest = rest.strip_prefix(b"\r\n").ok_or_else(bad)?;
        let hend = find(rest, b"\r\n\r\n").ok_or_else(bad)?;
        let head = String::from_utf8_lossy(&rest[..hend]).to_string();
        let data_start = hend + 4;
        let dend = find(&rest[data_start..], sep.as_bytes()).ok_or_else(bad)?;
        let data = &rest[data_start..data_start + dend];
        let mut name = None;
        let mut filename = None;
        for line in head.split("\r\n") {
            let Some((k, v)) = line.split_once(':') else { continue };
            if !k.trim().eq_ignore_ascii_case("content-disposition") {
                continue;
            }
            for part in v.split(';').skip(1) {
                if let Some((pk, pv)) = part.trim().split_once('=') {
                    let pv = pv.trim().trim_matches('"').to_string();
                    match pk.trim().to_ascii_lowercase().as_str() {
                        "name" => name = Some(pv),
                        "filename" => filename = Some(pv),
                        _ => {}
                    }
                }
            }
        }
        if let Some(name) = name {
            match filename {
                Some(f) => {
                    p.files.insert(name, Upload { filename: f, data: data.to_vec() });
                }
                None => {
                    p.map.insert(name, Value::String(String::from_utf8_lossy(data).into_owned()));
                }
            }
        }
        pos += 2 + data_start + dend + sep.len();
        if pos > body.len() {
            return Err(bad());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A hostile webhook server's chunk sizes never panic (overflow) or allocate past the cap.
    #[test]
    fn dechunk_survives_hostile_sizes() {
        assert_eq!(dechunk(b"5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"), b"hello world");
        assert_eq!(dechunk(b"ffffffffffffffff\r\nabc"), b"");
        assert_eq!(dechunk(b"fffffffffffffffe\r\nabc"), b"");
        assert_eq!(dechunk(b"3\r\nabc\r\nffffffffffffffff\r\nxyz"), b"abc");
        assert_eq!(dechunk(b"10\r\nshort"), b"");
        assert_eq!(dechunk(b"zz\r\n"), b"");
        let big = format!("{:x}\r\n", MAX_RESPONSE as usize + 1);
        let mut raw = big.into_bytes();
        raw.extend(std::iter::repeat_n(b'a', MAX_RESPONSE as usize + 1));
        assert!(dechunk(&raw).is_empty(), "over the size limit");
        let resp = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nffffffffffffffff\r\nx";
        assert_eq!(parse_response(resp).unwrap().status, 200);
    }

    #[test]
    fn params_from_every_encoding() {
        let p = Params::parse(Some("chat_id=d%3Aabc&x=1"), Some("application/json"), br#"{"text":"hi","n":5}"#).unwrap();
        assert_eq!(p.str("chat_id").as_deref(), Some("d:abc"));
        assert_eq!(p.str("text").as_deref(), Some("hi"));
        assert_eq!(p.int("n"), Some(5));
        let p = Params::parse(None, Some("application/x-www-form-urlencoded"), b"text=a+b%21&disable_notification=true").unwrap();
        assert_eq!(p.str("text").as_deref(), Some("a b!"));
        assert!(p.bool("disable_notification"));
        let body = b"--XX\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\nd:p\r\n--XX\r\nContent-Disposition: form-data; name=\"photo\"; filename=\"a.png\"\r\nContent-Type: image/png\r\n\r\n\x89PNG\r\n\r\n--XX--\r\n";
        let p = Params::parse(None, Some("multipart/form-data; boundary=XX"), body).unwrap();
        assert_eq!(p.str("chat_id").as_deref(), Some("d:p"));
        let f = &p.files["photo"];
        assert_eq!((f.filename.as_str(), f.data.as_slice()), ("a.png", &b"\x89PNG\r\n"[..]));
        assert!(Params::parse(None, Some("application/json"), b"[1]").is_err());
    }

    #[test]
    fn response_parsing() {
        let r = parse_response(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n").unwrap();
        assert_eq!((r.status, r.body.as_slice()), (200, &b"abcde"[..]));
        let r = parse_response(b"HTTP/1.1 500 X\r\nContent-Length: 2\r\n\r\nokjunk").unwrap();
        assert_eq!((r.status, r.body.as_slice()), (500, &b"ok"[..]));
    }
}
