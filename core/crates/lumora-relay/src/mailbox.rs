//! In-memory store-and-forward of SIGNAL frames for offline peers.
//!
//! Items are complete SIGNAL frames whose peer field is already the *sender's* key,
//! so delivery is a plain write. Payloads are sealed envelopes the relay cannot read.

use std::collections::{HashMap, VecDeque};
use std::io::{Read, Write};
use std::path::Path;

const FILE_MAGIC: &[u8; 6] = b"LMBX1\n";

struct Item {
    expires_ms: u64,
    frame: Vec<u8>,
}

pub struct Mailbox {
    boxes: HashMap<[u8; 32], VecDeque<Item>>,
    total: usize,
    items: usize,
    /// Bytes stored per *sender* (the key in each frame), across all recipients.
    by_sender: HashMap<[u8; 32], usize>,
    pub max_items: usize,
    pub max_item: usize,
    pub max_total: usize,
    /// Bytes one sender may hold across all recipients (default `max_total / 32`), so a
    /// single key spraying random recipients can't fill the whole relay.
    pub max_per_sender: usize,
    pub ttl_ms: u64,
    pub dirty: bool,
}

/// The sender key of a stored SIGNAL frame (`type(1) || from(32) || payload`).
fn sender_of(frame: &[u8]) -> [u8; 32] {
    frame.get(1..33).and_then(|s| s.try_into().ok()).unwrap_or([0; 32])
}

#[derive(Debug, PartialEq, Eq)]
pub enum PutError {
    TooLarge,
    RecipientFull,
    RelayFull,
    SenderFull,
}

impl PutError {
    pub fn message(&self) -> &'static str {
        match self {
            PutError::TooLarge => "signal too large for mailbox",
            PutError::RecipientFull => "mailbox full for this peer",
            PutError::RelayFull => "relay mailbox full",
            PutError::SenderFull => "too much stored mail from this sender",
        }
    }
}

impl Mailbox {
    pub fn new(max_items: usize, max_item: usize, max_total: usize, ttl_ms: u64) -> Self {
        let max_per_sender = (max_total / 32).max(max_item + 33);
        Mailbox { boxes: HashMap::new(), total: 0, items: 0, by_sender: HashMap::new(), max_items, max_item, max_total, max_per_sender, ttl_ms, dirty: false }
    }

    fn forget(&mut self, frame: &[u8]) {
        self.total -= frame.len();
        self.items -= 1;
        let from = sender_of(frame);
        if let Some(b) = self.by_sender.get_mut(&from) {
            *b = b.saturating_sub(frame.len());
            if *b == 0 {
                self.by_sender.remove(&from);
            }
        }
    }

    pub fn stats(&self) -> (usize, usize, usize) {
        (self.boxes.len(), self.items, self.total)
    }

    /// Store `frame` (a SIGNAL frame: 1 + 32 + payload) for `to`.
    pub fn put(&mut self, to: [u8; 32], frame: Vec<u8>, now_ms: u64) -> Result<(), PutError> {
        self.put_until(to, frame, now_ms.saturating_add(self.ttl_ms), now_ms)
    }

    fn put_until(&mut self, to: [u8; 32], frame: Vec<u8>, expires_ms: u64, now_ms: u64) -> Result<(), PutError> {
        if frame.len().saturating_sub(33) > self.max_item {
            return Err(PutError::TooLarge);
        }
        if self.total + frame.len() > self.max_total {
            self.prune(now_ms);
            if self.total + frame.len() > self.max_total {
                return Err(PutError::RelayFull);
            }
        }
        let from = sender_of(&frame);
        if self.by_sender.get(&from).copied().unwrap_or(0) + frame.len() > self.max_per_sender {
            self.prune(now_ms);
            if self.by_sender.get(&from).copied().unwrap_or(0) + frame.len() > self.max_per_sender {
                return Err(PutError::SenderFull);
            }
        }
        let mut q = self.boxes.remove(&to).unwrap_or_default();
        if q.len() >= self.max_items {
            while q.front().is_some_and(|i| i.expires_ms <= now_ms) {
                let i = q.pop_front().unwrap();
                self.forget(&i.frame);
            }
        }
        if q.len() >= self.max_items {
            // Full: make room fairly. The sender holding the most items in this box loses
            // its oldest one, unless that is us (or a tie) — so one flooder can't lock a
            // victim's mailbox for the whole TTL.
            let mut counts: HashMap<[u8; 32], usize> = HashMap::new();
            for i in q.iter() {
                *counts.entry(sender_of(&i.frame)).or_default() += 1;
            }
            let mine = counts.get(&from).copied().unwrap_or(0);
            let top = counts.iter().filter(|(k, _)| **k != from).max_by_key(|(_, c)| **c).map(|(k, c)| (*k, *c));
            match top {
                Some((victim, c)) if c > mine => {
                    let pos = q.iter().position(|i| sender_of(&i.frame) == victim).expect("counted");
                    let i = q.remove(pos).expect("in range");
                    self.forget(&i.frame);
                }
                _ => {
                    if !q.is_empty() {
                        self.boxes.insert(to, q);
                    }
                    return Err(PutError::RecipientFull);
                }
            }
        }
        self.total += frame.len();
        self.items += 1;
        *self.by_sender.entry(from).or_default() += frame.len();
        q.push_back(Item { expires_ms, frame });
        self.boxes.insert(to, q);
        self.dirty = true;
        Ok(())
    }

    /// Remove and return every live item for `pk`, oldest first.
    pub fn take(&mut self, pk: &[u8; 32], now_ms: u64) -> Vec<Vec<u8>> {
        let Some(q) = self.boxes.remove(pk) else { return Vec::new() };
        self.dirty = true;
        let mut out = Vec::with_capacity(q.len());
        for i in q {
            self.forget(&i.frame);
            if i.expires_ms > now_ms {
                out.push(i.frame);
            }
        }
        out
    }

    /// Put back frames that could not be delivered (keeps a fresh TTL).
    pub fn restore(&mut self, pk: [u8; 32], frames: Vec<Vec<u8>>, now_ms: u64) {
        for f in frames {
            let _ = self.put(pk, f, now_ms);
        }
    }

    pub fn prune(&mut self, now_ms: u64) {
        let mut removed_bytes = 0;
        let mut removed_items = 0;
        let mut by_sender: Vec<([u8; 32], usize)> = Vec::new();
        self.boxes.retain(|_, q| {
            q.retain(|i| {
                let keep = i.expires_ms > now_ms;
                if !keep {
                    removed_bytes += i.frame.len();
                    removed_items += 1;
                    by_sender.push((sender_of(&i.frame), i.frame.len()));
                }
                keep
            });
            !q.is_empty()
        });
        if removed_items > 0 {
            self.total -= removed_bytes;
            self.items -= removed_items;
            self.dirty = true;
            for (from, n) in by_sender {
                if let Some(b) = self.by_sender.get_mut(&from) {
                    *b = b.saturating_sub(n);
                    if *b == 0 {
                        self.by_sender.remove(&from);
                    }
                }
            }
        }
    }

    /// Serialize: magic, then records `pk[32] expires_ms u64be len u32be frame`.
    pub fn serialize(&self) -> Vec<u8> {
        let mut v = Vec::with_capacity(FILE_MAGIC.len() + self.total + self.items * 44);
        v.extend_from_slice(FILE_MAGIC);
        for (pk, q) in &self.boxes {
            for i in q {
                v.extend_from_slice(pk);
                v.extend_from_slice(&i.expires_ms.to_be_bytes());
                v.extend_from_slice(&(i.frame.len() as u32).to_be_bytes());
                v.extend_from_slice(&i.frame);
            }
        }
        v
    }

    pub fn save_bytes(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
        let tmp = path.with_extension("tmp");
        {
            let mut f = std::fs::File::create(&tmp)?;
            f.write_all(bytes)?;
            f.sync_all()?;
        }
        std::fs::rename(tmp, path)
    }

    /// Load a file written by `serialize`; expired or malformed records are skipped.
    pub fn load(&mut self, path: &Path, now_ms: u64) -> std::io::Result<usize> {
        let mut data = Vec::new();
        std::fs::File::open(path)?.read_to_end(&mut data)?;
        if !data.starts_with(FILE_MAGIC) {
            return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, "not a lumora mailbox file"));
        }
        let mut p = FILE_MAGIC.len();
        let mut n = 0;
        while p + 44 <= data.len() {
            let pk: [u8; 32] = data[p..p + 32].try_into().unwrap();
            let exp = u64::from_be_bytes(data[p + 32..p + 40].try_into().unwrap());
            let len = u32::from_be_bytes(data[p + 40..p + 44].try_into().unwrap()) as usize;
            p += 44;
            let Some(frame) = data.get(p..p + len) else { break };
            p += len;
            if exp > now_ms && self.put_until(pk, frame.to_vec(), exp, now_ms).is_ok() {
                n += 1;
            }
        }
        self.dirty = false;
        Ok(n)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(n: usize) -> Vec<u8> {
        let mut f = vec![4u8];
        f.extend_from_slice(&[7u8; 32]);
        f.extend(std::iter::repeat_n(1u8, n));
        f
    }

    #[test]
    fn caps_and_ttl() {
        let mut m = Mailbox::new(2, 100, 1000, 1000);
        let pk = [1u8; 32];
        assert_eq!(m.put(pk, frame(101), 0), Err(PutError::TooLarge));
        m.put(pk, frame(10), 0).unwrap();
        m.put(pk, frame(10), 0).unwrap();
        assert_eq!(m.put(pk, frame(10), 0), Err(PutError::RecipientFull));
        // after TTL, room again
        m.put(pk, frame(10), 2000).unwrap();
        assert_eq!(m.take(&pk, 2000).len(), 1);
        assert_eq!(m.stats(), (0, 0, 0));
        let mut m = Mailbox::new(100, 100, 100, 1000);
        m.put(pk, frame(50), 0).unwrap();
        assert_eq!(m.put([2u8; 32], frame(50), 0), Err(PutError::RelayFull));
    }

    fn frame_from(sender: u8, n: usize) -> Vec<u8> {
        let mut f = frame(n);
        f[1..33].copy_from_slice(&[sender; 32]);
        f
    }

    /// Abuse: one sender used to fill a victim's box (RecipientFull for everyone else
    /// for the whole TTL) or, spraying random recipients, the whole relay.
    #[test]
    fn one_sender_cannot_lock_a_mailbox_or_the_relay() {
        let victim = [1u8; 32];
        let mut m = Mailbox::new(10, 100, 1_000_000, 1000);
        for _ in 0..10 {
            m.put(victim, frame_from(0xAA, 10), 0).unwrap();
        }
        // the flooder can't add more…
        assert_eq!(m.put(victim, frame_from(0xAA, 10), 0), Err(PutError::RecipientFull));
        // …but a friend's mail still gets in, displacing the flooder's oldest items
        for _ in 0..5 {
            m.put(victim, frame_from(0xBB, 10), 0).unwrap();
        }
        // fair share reached (5/5): no further eviction in either direction
        assert_eq!(m.put(victim, frame_from(0xBB, 10), 0), Err(PutError::RecipientFull));
        let got = m.take(&victim, 0);
        assert_eq!(got.iter().filter(|f| f[1] == 0xBB).count(), 5);
        assert_eq!(m.stats(), (0, 0, 0));
        // a single sender spraying random recipients is capped well below the relay total
        let mut m = Mailbox::new(10, 100, 32 * 1000, 1000);
        assert_eq!(m.max_per_sender, 1000);
        let mut stored = 0;
        for i in 0..100u8 {
            if m.put([i; 32], frame_from(0xCC, 67), 0).is_ok() {
                stored += 1;
            }
        }
        assert_eq!(stored, 10, "100-byte frames, 1000-byte sender cap");
        assert_eq!(m.put([200; 32], frame_from(0xCC, 67), 0), Err(PutError::SenderFull));
        m.put([200; 32], frame_from(0xDD, 67), 0).unwrap();
        // expiry frees the sender's quota
        m.put([201; 32], frame_from(0xCC, 67), 5000).unwrap();
    }

    #[test]
    fn persist_roundtrip() {
        let dir = std::env::temp_dir().join(format!("lumora-mbx-{}", std::process::id()));
        let mut m = Mailbox::new(10, 100, 10_000, 1000);
        m.put([1u8; 32], frame(5), 0).unwrap();
        m.put([2u8; 32], frame(6), 0).unwrap();
        Mailbox::save_bytes(&dir, &m.serialize()).unwrap();
        let mut m2 = Mailbox::new(10, 100, 10_000, 1000);
        assert_eq!(m2.load(&dir, 10).unwrap(), 2);
        assert_eq!(m2.take(&[2u8; 32], 10), vec![frame(6)]);
        let _ = std::fs::remove_file(&dir);
    }
}
