//! Protects the identity key and the database key at rest.
//!
//! `keystore.json` holds `XChaCha20-Poly1305(KEK, identity_secret || db_key)`.
//! KEK comes from either:
//!  * a passphrase (Argon2id, 64 MiB, 3 passes) — strongest; nothing on disk can open it, or
//!  * the OS keychain (Secret Service / Windows Credential Manager / macOS Keychain),
//!    falling back to a 0600 key file when no keychain exists (reported as weaker).

use crate::crypto::{aead_decrypt, aead_encrypt, derive_passphrase_key, random_bytes};
use crate::identity::Identity;
use anyhow::{bail, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use zeroize::Zeroizing;

#[derive(Serialize, Deserialize)]
struct KeystoreFile {
    v: u32,
    mode: String,
    salt: String,
    wrapped: String,
    /// keyed BLAKE3 of the public peer id (salted, so it doesn't reveal or link the
    /// account): lets "forgot password" check that a recovery phrase belongs to this data
    /// before setting it aside. Absent in keystores written by older versions.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    owner: String,
}

fn owner_tag(salt: &[u8; 16], peer: &crate::identity::PeerId) -> String {
    let mut k = [0u8; 32];
    k[..16].copy_from_slice(salt);
    let key = blake3::derive_key("lumora keystore owner v1", &k);
    hex::encode(blake3::keyed_hash(&key, &peer.0).as_bytes())
}

/// Write a file readable by this OS user only (0600 on Unix, created that way — never
/// world-readable even briefly), atomically via a temp file.
pub(crate) fn write_private(path: &Path, data: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let tmp = path.with_extension(format!("tmp{}", rand::random::<u32>()));
    let mut o = std::fs::OpenOptions::new();
    o.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        o.mode(0o600);
    }
    let r = (|| {
        let mut f = o.open(&tmp)?;
        f.write_all(data)?;
        f.sync_all()?;
        std::fs::rename(&tmp, path)
    })();
    if r.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    r
}

fn save(dir: &Path, f: &KeystoreFile) -> Result<()> {
    write_private(&ks_path(dir), &serde_json::to_vec_pretty(f)?)?;
    Ok(())
}

/// Does the recovery `phrase` belong to the (locked) identity in `dir`?
/// `None` = can't tell (no keystore, keystore from an older version, or not a valid phrase).
pub fn phrase_matches(dir: &Path, phrase: &str) -> Option<bool> {
    let f: KeystoreFile = serde_json::from_slice(&std::fs::read(ks_path(dir)).ok()?).ok()?;
    let salt: [u8; 16] = hex::decode(&f.salt).ok()?.try_into().ok()?;
    if f.owner.is_empty() {
        return None;
    }
    let id = Identity::from_recovery_phrase(phrase).ok()?;
    let want = hex::decode(&f.owner).ok()?;
    let got = hex::decode(owner_tag(&salt, &id.peer_id())).ok()?;
    Some(want.len() == got.len() && want.iter().zip(&got).fold(0u8, |a, (x, y)| a | (x ^ y)) == 0)
}

/// Add the owner tag to a keystore written by an older version (after a successful unlock).
pub fn ensure_owner_tag(dir: &Path, identity: &Identity) -> Result<()> {
    let mut f: KeystoreFile = serde_json::from_slice(&std::fs::read(ks_path(dir))?)?;
    let salt: [u8; 16] = hex::decode(&f.salt).ok().and_then(|v| v.try_into().ok()).ok_or_else(|| anyhow::anyhow!("bad salt"))?;
    let tag = owner_tag(&salt, &identity.peer_id());
    if f.owner != tag {
        f.owner = tag;
        save(dir, &f)?;
    }
    Ok(())
}

pub struct Unlocked {
    pub identity: Identity,
    pub db_key: Zeroizing<[u8; 32]>,
    pub protection: String,
}

fn ks_path(dir: &Path) -> PathBuf {
    dir.join("keystore.json")
}

pub fn exists(dir: &Path) -> bool {
    ks_path(dir).exists()
}

fn device_kek(dir: &Path, create: bool) -> Result<(Zeroizing<[u8; 32]>, String)> {
    let account = hex::encode(&blake3::hash(dir.to_string_lossy().as_bytes()).as_bytes()[..8]);
    #[cfg(all(feature = "os-keyring", not(target_os = "android")))]
    {
        if let Ok(entry) = keyring::Entry::new("lumora", &account) {
            // The Secret Service (D-Bus) can fail for a moment — right after login, or on a
            // busy machine. That is not "no key": retry, and never answer it with
            // "this device can no longer unlock your data" (nor replace the stored key).
            // A Secret Service that never answers must not freeze startup: each read is
            // bounded (the first one long enough for a "unlock your keyring" prompt).
            let entry = std::sync::Arc::new(entry);
            // `None`: no answer in time (then don't keep asking).
            let read = |limit: std::time::Duration| -> Option<keyring::Result<Vec<u8>>> {
                let (tx, rx) = std::sync::mpsc::channel();
                let e = entry.clone();
                std::thread::spawn(move || {
                    let _ = tx.send(e.get_secret());
                });
                rx.recv_timeout(limit).ok()
            };
            let hung = || Err(keyring::Error::PlatformFailure("keyring did not answer".into()));
            let mut got = read(std::time::Duration::from_secs(90)).unwrap_or_else(hung);
            let mut tries = 0;
            while tries < 5 && matches!(&got, Err(e) if !matches!(e, keyring::Error::NoEntry)) {
                if matches!(&got, Err(keyring::Error::PlatformFailure(m)) if m.to_string() == "keyring did not answer") {
                    break;
                }
                tries += 1;
                std::thread::sleep(std::time::Duration::from_millis(300));
                got = read(std::time::Duration::from_secs(5)).unwrap_or_else(hung);
            }
            let unavailable = matches!(&got, Err(e) if !matches!(e, keyring::Error::NoEntry));
            match got {
                Ok(s) if s.len() == 32 => {
                    let mut k = Zeroizing::new([0u8; 32]);
                    k.copy_from_slice(&s);
                    return Ok((k, "os-keychain".into()));
                }
                _ if unavailable && !create && !dir.join(".device_key").exists() => {
                    bail!(crate::i18n::user_err("err.keychain_unavailable"));
                }
                _ if create && !unavailable => {
                    let k = Zeroizing::new(random_bytes::<32>());
                    if entry.set_secret(&k[..]).is_ok() {
                        if let Ok(back) = entry.get_secret() {
                            if back == k[..] {
                                return Ok((k, "os-keychain".into()));
                            }
                        }
                    }
                }
                _ => {}
            }
        }
    }
    let _ = &account;
    let f = dir.join(".device_key");
    if let Ok(b) = std::fs::read(&f) {
        if b.len() == 32 {
            let mut k = Zeroizing::new([0u8; 32]);
            k.copy_from_slice(&b);
            return Ok((k, "device-file".into()));
        }
    }
    if !create {
        bail!(crate::i18n::user_err("err.device_key_missing"));
    }
    let k = Zeroizing::new(random_bytes::<32>());
    {
        use std::io::Write;
        let mut o = std::fs::OpenOptions::new();
        o.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            o.mode(0o600); // created private, never world-readable even briefly
        }
        o.open(&f)?.write_all(&k[..])?;
    }
    Ok((k, "device-file".into()))
}

fn kek_for(dir: &Path, mode: &str, salt: &[u8; 16], pass: Option<&str>, create: bool) -> Result<(Zeroizing<[u8; 32]>, String)> {
    match mode {
        "passphrase" => {
            let p = pass.filter(|p| !p.is_empty()).ok_or_else(|| crate::i18n::user_err("err.passphrase_required"))?;
            Ok((derive_passphrase_key(p, salt)?, "passphrase".into()))
        }
        _ => device_kek(dir, create),
    }
}

pub fn create(dir: &Path, identity: &Identity, pass: Option<&str>) -> Result<Unlocked> {
    create_with_db_key(dir, identity, pass, Zeroizing::new(random_bytes::<32>()))
}

pub fn create_with_db_key(dir: &Path, identity: &Identity, pass: Option<&str>, db_key: Zeroizing<[u8; 32]>) -> Result<Unlocked> {
    std::fs::create_dir_all(dir)?;
    let salt: [u8; 16] = random_bytes();
    let mode = if pass.map(|p| !p.is_empty()).unwrap_or(false) { "passphrase" } else { "device" };
    let (kek, protection) = kek_for(dir, mode, &salt, pass, true)?;
    let mut plain = Zeroizing::new(Vec::with_capacity(64));
    plain.extend_from_slice(&identity.secret_bytes()[..]);
    plain.extend_from_slice(&db_key[..]);
    let wrapped = aead_encrypt(&kek, &plain, b"lumora-keystore-v1");
    let owner = owner_tag(&salt, &identity.peer_id());
    let f = KeystoreFile { v: 1, mode: mode.into(), salt: hex::encode(salt), wrapped: hex::encode(wrapped), owner };
    save(dir, &f)?;
    Ok(Unlocked { identity: identity.clone(), db_key, protection })
}

pub fn needs_passphrase(dir: &Path) -> bool {
    std::fs::read(ks_path(dir))
        .ok()
        .and_then(|b| serde_json::from_slice::<KeystoreFile>(&b).ok())
        .map(|f| f.mode == "passphrase")
        .unwrap_or(false)
}

pub fn unlock(dir: &Path, pass: Option<&str>) -> Result<Unlocked> {
    let b = std::fs::read(ks_path(dir)).map_err(|e| crate::i18n::user_err("err.data_unreadable").detail(e))?;
    let f: KeystoreFile = serde_json::from_slice(&b).map_err(|e| crate::i18n::user_err("err.data_corrupt").detail(e))?;
    let salt: [u8; 16] = hex::decode(&f.salt)
        .ok()
        .and_then(|v| v.try_into().ok())
        .ok_or_else(|| crate::i18n::user_err("err.data_corrupt").detail("bad salt"))?;
    let (kek, mut protection) = kek_for(dir, &f.mode, &salt, pass, false)?;
    let wrapped = hex::decode(&f.wrapped)?;
    let mut opened = aead_decrypt(&kek, &wrapped, b"lumora-keystore-v1");
    if opened.is_err() && f.mode != "passphrase" {
        // device protection: the keychain may answer now although it failed when the
        // keystore was written (it then fell back to the key file) — try that file too
        if let Some(k) = std::fs::read(dir.join(".device_key")).ok().filter(|b| b.len() == 32) {
            let mut fk = Zeroizing::new([0u8; 32]);
            fk.copy_from_slice(&k);
            opened = aead_decrypt(&fk, &wrapped, b"lumora-keystore-v1");
            if opened.is_ok() {
                protection = "device-file".into();
            }
        }
    }
    let plain = Zeroizing::new(opened.map_err(|_| crate::i18n::user_err("err.wrong_passphrase"))?);
    anyhow::ensure!(plain.len() == 64, crate::i18n::user_err("err.data_corrupt"));
    let secret: [u8; 32] = plain[..32].try_into().unwrap();
    let mut db_key = Zeroizing::new([0u8; 32]);
    db_key.copy_from_slice(&plain[32..]);
    Ok(Unlocked { identity: Identity::from_secret(&secret), db_key, protection })
}

/// Re-wrap with a new passphrase (or None → device protection). DB key unchanged.
pub fn change_protection(dir: &Path, unlocked: &Unlocked, new_pass: Option<&str>) -> Result<String> {
    let salt: [u8; 16] = random_bytes();
    let mode = if new_pass.map(|p| !p.is_empty()).unwrap_or(false) { "passphrase" } else { "device" };
    let (kek, protection) = kek_for(dir, mode, &salt, new_pass, true)?;
    let mut plain = Zeroizing::new(Vec::with_capacity(64));
    plain.extend_from_slice(&unlocked.identity.secret_bytes()[..]);
    plain.extend_from_slice(&unlocked.db_key[..]);
    let wrapped = aead_encrypt(&kek, &plain, b"lumora-keystore-v1");
    let owner = owner_tag(&salt, &unlocked.identity.peer_id());
    let f = KeystoreFile { v: 1, mode: mode.into(), salt: hex::encode(salt), wrapped: hex::encode(wrapped), owner };
    save(dir, &f)?;
    if mode == "passphrase" {
        let _ = std::fs::remove_file(dir.join(".device_key"));
    }
    Ok(protection)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn passphrase_roundtrip() {
        let dir = std::env::temp_dir().join(format!("lumora-ks-{}", rand::random::<u64>()));
        let id = Identity::generate();
        let u = create(&dir, &id, Some("correct horse")).unwrap();
        assert!(needs_passphrase(&dir));
        assert!(unlock(&dir, Some("wrong")).is_err());
        let u2 = unlock(&dir, Some("correct horse")).unwrap();
        assert_eq!(u2.identity.peer_id(), id.peer_id());
        assert_eq!(*u2.db_key, *u.db_key);
        let raw = std::fs::read_to_string(dir.join("keystore.json")).unwrap();
        assert!(!raw.contains(&hex::encode(&id.secret_bytes()[..])));
        std::fs::remove_dir_all(dir).ok();
    }
}

// ---------------------------------------------------------------- backups

#[derive(Serialize, Deserialize)]
struct BackupPayload {
    #[serde(with = "serde_bytes")]
    secret: Vec<u8>,
    #[serde(with = "serde_bytes")]
    db_key: Vec<u8>,
    #[serde(with = "serde_bytes")]
    db: Vec<u8>,
    created: u64,
}

const BACKUP_MAGIC: &[u8; 9] = b"LUMORABK1";
/// Streamed backup: `MAGIC2 || salt(16) || u32 len || AEAD(header) || chunks`, each chunk
/// `u32 len || AEAD(kek, ≤1 MiB of the database, aad = MAGIC2 || salt || index || last)`
/// — never more than one chunk in memory, and truncation / reordering is detected.
const BACKUP_MAGIC2: &[u8; 9] = b"LUMORABK2";
const BACKUP_CHUNK: usize = 1 << 20;

#[derive(Serialize, Deserialize)]
struct BackupHeader {
    #[serde(with = "serde_bytes")]
    secret: Vec<u8>,
    #[serde(with = "serde_bytes")]
    db_key: Vec<u8>,
    created: u64,
}

fn chunk_aad(salt: &[u8; 16], index: u64, last: bool) -> Vec<u8> {
    let mut a = BACKUP_MAGIC2.to_vec();
    a.extend_from_slice(salt);
    a.extend_from_slice(&index.to_le_bytes());
    a.push(last as u8);
    a
}

/// Create `path` readable by this OS user only (0600 on Unix), failing if it exists.
fn create_private(path: &Path) -> std::io::Result<std::fs::File> {
    let mut o = std::fs::OpenOptions::new();
    o.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        o.mode(0o600);
    }
    o.open(path)
}

/// A consistent copy of the live database (WAL, other writers active): SQLCipher's
/// `sqlcipher_export` from a separate read connection — one read transaction, so the
/// copy is a snapshot, encrypted with the same key; writers are never blocked.
fn snapshot_db(dir: &Path, db_key: &[u8; 32], out: &Path) -> Result<()> {
    let c = rusqlite::Connection::open(dir.join("lumora.db"))?;
    let hexkey = Zeroizing::new(hex::encode(&db_key[..]));
    c.execute_batch(&format!("PRAGMA key = \"x'{}'\";", hexkey.as_str()))?;
    c.query_row("SELECT count(*) FROM sqlite_master", [], |r| r.get::<_, i64>(0))
        .map_err(|e| crate::i18n::user_err("err.data_corrupt").detail(e))?;
    c.busy_timeout(std::time::Duration::from_secs(30))?;
    // the snapshot file must not be readable by others even for a moment
    drop(create_private(out)?);
    let path = out.to_str().ok_or_else(|| anyhow::anyhow!("non-UTF-8 path"))?;
    c.execute("ATTACH DATABASE ?1 AS snap KEY ?2", rusqlite::params![path, format!("x'{}'", hexkey.as_str())])?;
    let r = c.query_row("SELECT sqlcipher_export('snap')", [], |_| Ok(()));
    let _ = c.execute_batch("DETACH DATABASE snap");
    r?;
    Ok(())
}

/// Write an encrypted, password-protected backup (identity + encrypted database).
pub fn export_backup(dir: &Path, unlocked: &Unlocked, out: &Path, password: &str) -> Result<u64> {
    use std::io::{Read, Write};
    // the backup leaves the device (cloud, USB…): it can be attacked offline
    anyhow::ensure!(password.chars().count() >= 8, crate::i18n::user_err("err.backup_pw_short"));
    let snap = dir.join(format!("lumora.db.backup{}", rand::random::<u32>()));
    let tmp = out.with_extension(format!("tmp{}", rand::random::<u32>()));
    let r = (|| -> Result<u64> {
        snapshot_db(dir, &unlocked.db_key, &snap)?;
        let salt: [u8; 16] = random_bytes();
        let kek = derive_passphrase_key(password, &salt)?;
        let header = Zeroizing::new(rmp_serde::to_vec(&BackupHeader {
            secret: unlocked.identity.secret_bytes().to_vec(),
            db_key: unlocked.db_key.to_vec(),
            created: crate::util::now_ms(),
        })?);
        let mut f = std::io::BufWriter::new(create_private(&tmp).map_err(|e| crate::i18n::user_err("err.file_unwritable").detail(e))?);
        let mut written = 0u64;
        let mut put = |f: &mut std::io::BufWriter<std::fs::File>, b: &[u8]| -> std::io::Result<()> {
            written += b.len() as u64;
            f.write_all(b)
        };
        put(&mut f, BACKUP_MAGIC2)?;
        put(&mut f, &salt)?;
        let h = aead_encrypt(&kek, &header, &chunk_aad(&salt, u64::MAX, false));
        put(&mut f, &(h.len() as u32).to_le_bytes())?;
        put(&mut f, &h)?;
        let mut db = std::fs::File::open(&snap)?;
        let mut buf = Zeroizing::new(vec![0u8; BACKUP_CHUNK]);
        let mut next = Zeroizing::new(vec![0u8; BACKUP_CHUNK]);
        let fill = |db: &mut std::fs::File, b: &mut [u8]| -> std::io::Result<usize> {
            let mut n = 0;
            while n < b.len() {
                match db.read(&mut b[n..])? {
                    0 => break,
                    k => n += k,
                }
            }
            Ok(n)
        };
        let mut n = fill(&mut db, &mut buf)?;
        let mut index = 0u64;
        loop {
            // read ahead one chunk to know whether this one is the last
            let m = if n == BACKUP_CHUNK { fill(&mut db, &mut next)? } else { 0 };
            let last = m == 0;
            let ct = aead_encrypt(&kek, &buf[..n], &chunk_aad(&salt, index, last));
            put(&mut f, &(ct.len() as u32).to_le_bytes())?;
            put(&mut f, &ct)?;
            if last {
                break;
            }
            std::mem::swap(&mut buf, &mut next);
            n = m;
            index += 1;
        }
        f.flush()?;
        f.into_inner().map_err(|e| e.into_error())?.sync_all()?;
        std::fs::rename(&tmp, out).map_err(|e| crate::i18n::user_err("err.file_unwritable").detail(e))?;
        Ok(written)
    })();
    let _ = std::fs::remove_file(&snap);
    if r.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    r
}

/// Restore a backup into an empty data dir; protects it with `new_pass` (or the device key).
pub fn import_backup(dir: &Path, file: &Path, password: &str, new_pass: Option<&str>) -> Result<Unlocked> {
    use std::io::{Read, Write};
    anyhow::ensure!(!exists(dir), crate::i18n::user_err("err.account_exists"));
    let mut f = std::io::BufReader::new(std::fs::File::open(file).map_err(|e| crate::i18n::user_err("err.file_unreadable").detail(e))?);
    let mut magic = [0u8; 9];
    f.read_exact(&mut magic).map_err(|_| crate::i18n::user_err("err.not_backup"))?;
    if &magic == BACKUP_MAGIC {
        drop(f);
        return import_backup_v1(dir, file, password, new_pass);
    }
    anyhow::ensure!(&magic == BACKUP_MAGIC2, crate::i18n::user_err("err.not_backup"));
    let corrupt = || crate::i18n::user_err("err.backup_corrupt");
    let mut salt = [0u8; 16];
    f.read_exact(&mut salt).map_err(|e| corrupt().detail(e))?;
    let kek = derive_passphrase_key(password, &salt)?;
    let read_block = |f: &mut std::io::BufReader<std::fs::File>| -> Result<Option<Vec<u8>>> {
        let mut len = [0u8; 4];
        match f.read_exact(&mut len) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
            Err(e) => return Err(corrupt().detail(e).into()),
        }
        let n = u32::from_le_bytes(len) as usize;
        anyhow::ensure!(n <= BACKUP_CHUNK + 64 * 1024, corrupt().detail("oversized block"));
        let mut b = vec![0u8; n];
        f.read_exact(&mut b).map_err(|e| corrupt().detail(e))?;
        Ok(Some(b))
    };
    let h = read_block(&mut f)?.ok_or_else(corrupt)?;
    let header = Zeroizing::new(aead_decrypt(&kek, &h, &chunk_aad(&salt, u64::MAX, false)).map_err(|_| crate::i18n::user_err("err.wrong_backup_password"))?);
    let p: BackupHeader = crate::proto::from_slice_capped(&header).map_err(|e| corrupt().detail(e))?;
    let secret: [u8; 32] = p.secret.as_slice().try_into().map_err(|_| corrupt())?;
    anyhow::ensure!(p.db_key.len() == 32, corrupt());
    let mut db_key = Zeroizing::new([0u8; 32]);
    db_key.copy_from_slice(&p.db_key);
    std::fs::create_dir_all(dir)?;
    let db_path = dir.join("lumora.db");
    let tmp = db_path.with_extension(format!("tmp{}", rand::random::<u32>()));
    let r = (|| -> Result<()> {
        let mut out = std::io::BufWriter::new(create_private(&tmp)?);
        let mut index = 0u64;
        loop {
            let ct = read_block(&mut f)?.ok_or_else(|| corrupt().detail("truncated backup"))?;
            // try "more follows" first, then "last chunk": the flag is authenticated
            let (plain, last) = match aead_decrypt(&kek, &ct, &chunk_aad(&salt, index, false)) {
                Ok(p) => (p, false),
                Err(_) => (aead_decrypt(&kek, &ct, &chunk_aad(&salt, index, true)).map_err(|_| corrupt().detail("damaged chunk"))?, true),
            };
            out.write_all(&plain)?;
            if last {
                break;
            }
            index += 1;
        }
        out.flush()?;
        out.into_inner().map_err(|e| e.into_error())?.sync_all()?;
        std::fs::rename(&tmp, &db_path)?;
        Ok(())
    })();
    if r.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    r?;
    create_with_db_key(dir, &Identity::from_secret(&secret), new_pass, db_key)
}

/// Backups written by older versions (one AEAD over the whole payload).
fn import_backup_v1(dir: &Path, file: &Path, password: &str, new_pass: Option<&str>) -> Result<Unlocked> {
    let f = std::fs::read(file).map_err(|e| crate::i18n::user_err("err.file_unreadable").detail(e))?;
    anyhow::ensure!(f.len() > 25 && &f[..9] == BACKUP_MAGIC, crate::i18n::user_err("err.not_backup"));
    let salt: [u8; 16] = f[9..25].try_into().unwrap();
    let kek = derive_passphrase_key(password, &salt)?;
    let plain = Zeroizing::new(aead_decrypt(&kek, &f[25..], BACKUP_MAGIC).map_err(|_| crate::i18n::user_err("err.wrong_backup_password"))?);
    let p: BackupPayload = crate::proto::from_slice_capped(&plain).map_err(|e| crate::i18n::user_err("err.backup_corrupt").detail(e))?;
    let secret: [u8; 32] = p.secret.as_slice().try_into().map_err(|_| crate::i18n::user_err("err.backup_corrupt"))?;
    anyhow::ensure!(p.db_key.len() == 32, crate::i18n::user_err("err.backup_corrupt"));
    let mut db_key = Zeroizing::new([0u8; 32]);
    db_key.copy_from_slice(&p.db_key);
    std::fs::create_dir_all(dir)?;
    write_private(&dir.join("lumora.db"), &p.db)?;
    create_with_db_key(dir, &Identity::from_secret(&secret), new_pass, db_key)
}

#[cfg(test)]
mod backup_tests {
    use super::*;

    /// The backup is a consistent snapshot even while the app keeps writing, it streams
    /// (several chunks), restores to a working database, and v1 backups still import.
    #[test]
    fn backup_snapshot_under_concurrent_writes_restores() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("d");
        let u = create(&dir, &Identity::generate(), None).unwrap();
        let store = std::sync::Arc::new(crate::store::Store::open(&dir.join("lumora.db"), &u.db_key).unwrap());
        let a = crate::identity::PeerId([5; 32]);
        store.ensure_conv("d:x", 0, "x").unwrap();
        // ~3 MB of history so the backup spans several chunks
        let big = "y".repeat(3000);
        for i in 0..1000u32 {
            store.insert_message(&i.to_be_bytes(), "d:x", &a, i as u64 + 1, "text", &serde_json::json!({"text": big}), 2, None, None).unwrap();
        }
        let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let writer = {
            let (s, stop) = (store.clone(), stop.clone());
            std::thread::spawn(move || {
                let mut i = 1_000_000u32;
                while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                    s.insert_message(&i.to_be_bytes(), "d:x", &a, i as u64, "text", &serde_json::json!({"text": "live"}), 2, None, None).unwrap();
                    i += 1;
                }
                i - 1_000_000
            })
        };
        let out = tmp.path().join("b.lumora");
        let n = export_backup(&dir, &u, &out, "a long backup pass").unwrap();
        stop.store(true, std::sync::atomic::Ordering::Relaxed);
        let live_writes = writer.join().unwrap();
        assert!(n > 2 * BACKUP_CHUNK as u64, "{n}");
        assert!(live_writes > 0);
        assert!(!std::fs::read_dir(&dir).unwrap().any(|e| e.unwrap().file_name().to_string_lossy().contains("backup")), "snapshot left behind");
        // restore and open it
        let dir2 = tmp.path().join("r");
        let u2 = import_backup(&dir2, &out, "a long backup pass", None).unwrap();
        assert_eq!(u2.identity.peer_id(), u.identity.peer_id());
        let s2 = crate::store::Store::open(&dir2.join("lumora.db"), &u2.db_key).unwrap();
        let msgs = s2.stats()["messages"].as_i64().unwrap();
        assert!(msgs >= 1000, "{msgs}");
        assert!(s2.message(&999u32.to_be_bytes()).is_some());
        // wrong password, truncation and tampering are refused
        assert!(import_backup(&tmp.path().join("r2"), &out, "wrong password!!", None).is_err());
        let raw = std::fs::read(&out).unwrap();
        let cut = tmp.path().join("cut.lumora");
        std::fs::write(&cut, &raw[..raw.len() - 1000]).unwrap();
        assert!(import_backup(&tmp.path().join("r3"), &cut, "a long backup pass", None).is_err());
        let mut bad = raw.clone();
        let mid = bad.len() / 2;
        bad[mid] ^= 1;
        std::fs::write(&cut, &bad).unwrap();
        assert!(import_backup(&tmp.path().join("r4"), &cut, "a long backup pass", None).is_err());
        // a backup made by an older version still restores
        let salt: [u8; 16] = random_bytes();
        let kek = derive_passphrase_key("a long backup pass", &salt).unwrap();
        let payload = BackupPayload { secret: u.identity.secret_bytes().to_vec(), db_key: u.db_key.to_vec(), db: b"old-db".to_vec(), created: 1 };
        let mut v1 = BACKUP_MAGIC.to_vec();
        v1.extend_from_slice(&salt);
        v1.extend(aead_encrypt(&kek, &rmp_serde::to_vec(&payload).unwrap(), BACKUP_MAGIC));
        std::fs::write(&cut, &v1).unwrap();
        let dir5 = tmp.path().join("r5");
        import_backup(&dir5, &cut, "a long backup pass", None).unwrap();
        assert_eq!(std::fs::read(dir5.join("lumora.db")).unwrap(), b"old-db");
    }
}

#[cfg(all(test, unix))]
mod security_tests {
    //! Adversarial tests from the security audit (keystore / backup at rest).
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn mode(p: &Path) -> u32 {
        std::fs::metadata(p).unwrap().permissions().mode() & 0o777
    }

    /// PoC: keystore.json and backups were created with the process umask (usually
    /// 0644), so any other local account could copy them and brute-force the password
    /// offline.
    #[test]
    fn keystore_and_backup_files_are_private() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("d");
        let id = Identity::generate();
        let u = create(&dir, &id, Some("correct horse")).unwrap();
        assert_eq!(mode(&ks_path(&dir)), 0o600, "keystore readable by other users");
        change_protection(&dir, &u, Some("battery staple")).unwrap();
        assert_eq!(mode(&ks_path(&dir)), 0o600, "re-wrapped keystore readable by other users");
        drop(crate::store::Store::open(&dir.join("lumora.db"), &u.db_key).unwrap());
        let out = tmp.path().join("backup.lumora");
        export_backup(&dir, &u, &out, "a long backup pass").unwrap();
        assert_eq!(mode(&out), 0o600, "backup readable by other users");
        let dir2 = tmp.path().join("restored");
        import_backup(&dir2, &out, "a long backup pass", None).unwrap();
        assert_eq!(mode(&dir2.join("lumora.db")), 0o600, "restored database readable by other users");
    }

    /// "Forgot password" must not accept just any valid recovery phrase.
    #[test]
    fn recovery_phrase_is_checked_against_the_locked_identity() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("d");
        let id = Identity::generate();
        let u = create(&dir, &id, Some("correct horse")).unwrap();
        assert_eq!(phrase_matches(&dir, &id.recovery_phrase()), Some(true));
        assert_eq!(phrase_matches(&dir, &Identity::generate().recovery_phrase()), Some(false));
        assert_eq!(phrase_matches(&dir, "not a phrase"), None);
        // keystore from an older version: unknown until the next successful unlock
        let mut f: KeystoreFile = serde_json::from_slice(&std::fs::read(ks_path(&dir)).unwrap()).unwrap();
        f.owner.clear();
        save(&dir, &f).unwrap();
        assert_eq!(phrase_matches(&dir, &id.recovery_phrase()), None);
        ensure_owner_tag(&dir, &u.identity).unwrap();
        assert_eq!(phrase_matches(&dir, &id.recovery_phrase()), Some(true));
        assert!(unlock(&dir, Some("correct horse")).is_ok());
        // the tag doesn't contain the peer id in the clear
        let raw = std::fs::read_to_string(ks_path(&dir)).unwrap();
        assert!(!raw.contains(&id.peer_id().to_base32()) && !raw.contains(&hex::encode(id.peer_id().0)));
    }

    #[test]
    fn backup_password_needs_eight_characters() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("d");
        let u = create(&dir, &Identity::generate(), None).unwrap();
        std::fs::write(dir.join("lumora.db"), b"db").unwrap();
        assert!(export_backup(&dir, &u, &tmp.path().join("b"), "1234567").is_err(), "7-character backup password accepted");
    }
}
