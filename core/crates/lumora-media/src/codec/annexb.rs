//! H.264 Annex-B helpers shared by every codec backend: NAL splitting,
//! SPS/PPS caching (so every keyframe is self-contained), AVCC ↔ Annex-B
//! conversion (VideoToolbox) and a minimal SPS parser for the picture size.

/// NAL unit types we care about.
pub const NAL_IDR: u8 = 5;
pub const NAL_SPS: u8 = 7;
pub const NAL_PPS: u8 = 8;

/// Iterate over the NAL units of an Annex-B buffer (payload without start code).
pub fn nals(data: &[u8]) -> impl Iterator<Item = &[u8]> {
    let mut starts = Vec::new(); // (start of start code, start of payload)
    let mut i = 0;
    while i + 3 <= data.len() {
        if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
            let sc = if i > 0 && data[i - 1] == 0 { i - 1 } else { i };
            starts.push((sc, i + 3));
            i += 3;
        } else {
            i += 1;
        }
    }
    let n = starts.len();
    (0..n).map(move |k| {
        let (_, p) = starts[k];
        let end = if k + 1 < n { starts[k + 1].0 } else { data.len() };
        &data[p..end.max(p)]
    })
}

pub fn nal_type(nal: &[u8]) -> u8 {
    nal.first().map(|b| b & 0x1f).unwrap_or(0)
}

/// Does this access unit contain an IDR slice?
pub fn has_idr(data: &[u8]) -> bool {
    nals(data).any(|n| nal_type(n) == NAL_IDR)
}

/// Remembers the latest SPS/PPS seen in the output of an encoder and makes sure
/// every IDR access unit carries them (a receiver can join on any keyframe).
#[derive(Default)]
pub struct ParamSets {
    pub sps: Vec<u8>,
    pub pps: Vec<u8>,
}

impl ParamSets {
    /// Record SPS/PPS found in `data` (Annex-B).
    pub fn learn(&mut self, data: &[u8]) {
        for n in nals(data) {
            match nal_type(n) {
                NAL_SPS => self.sps = n.to_vec(),
                NAL_PPS => self.pps = n.to_vec(),
                _ => {}
            }
        }
    }

    /// `data` with SPS/PPS prepended if it is a keyframe without them.
    pub fn complete_keyframe(&mut self, data: Vec<u8>) -> Vec<u8> {
        self.learn(&data);
        let (mut sps, mut pps) = (false, false);
        for n in nals(&data) {
            match nal_type(n) {
                NAL_SPS => sps = true,
                NAL_PPS => pps = true,
                _ => {}
            }
        }
        if (sps && pps) || self.sps.is_empty() || self.pps.is_empty() {
            return data;
        }
        let mut out = Vec::with_capacity(data.len() + self.sps.len() + self.pps.len() + 8);
        out.extend_from_slice(&[0, 0, 0, 1]);
        out.extend_from_slice(&self.sps);
        out.extend_from_slice(&[0, 0, 0, 1]);
        out.extend_from_slice(&self.pps);
        out.extend_from_slice(&data);
        out
    }
}

/// Length-prefixed (AVCC, `len_size` bytes big-endian) → Annex-B, appended to `out`.
#[allow(dead_code)]
pub fn avcc_to_annexb(src: &[u8], len_size: usize, out: &mut Vec<u8>) -> anyhow::Result<()> {
    let mut i = 0;
    while i < src.len() {
        anyhow::ensure!(i + len_size <= src.len(), "truncated AVCC length");
        let mut n = 0usize;
        for k in 0..len_size {
            n = (n << 8) | src[i + k] as usize;
        }
        i += len_size;
        anyhow::ensure!(i + n <= src.len(), "AVCC NAL overruns buffer");
        out.extend_from_slice(&[0, 0, 0, 1]);
        out.extend_from_slice(&src[i..i + n]);
        i += n;
    }
    Ok(())
}

/// Annex-B → AVCC with 4-byte big-endian lengths, skipping SPS/PPS/AUD (they go
/// into the format description on Apple platforms).
#[allow(dead_code)]
pub fn annexb_to_avcc_slices(src: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(src.len() + 16);
    for n in nals(src) {
        let t = nal_type(n);
        if n.is_empty() || t == NAL_SPS || t == NAL_PPS || t == 9 {
            continue;
        }
        out.extend_from_slice(&(n.len() as u32).to_be_bytes());
        out.extend_from_slice(n);
    }
    out
}

/// Remove emulation-prevention bytes (00 00 03 → 00 00).
fn unescape(nal: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(nal.len());
    let mut zeros = 0;
    for &b in nal {
        if zeros >= 2 && b == 3 {
            zeros = 0;
            continue;
        }
        zeros = if b == 0 { zeros + 1 } else { 0 };
        out.push(b);
    }
    out
}

struct Bits<'a> {
    d: &'a [u8],
    pos: usize,
}

impl Bits<'_> {
    fn bit(&mut self) -> anyhow::Result<u32> {
        let byte = *self.d.get(self.pos / 8).ok_or_else(|| anyhow::anyhow!("SPS truncated"))?;
        let b = (byte >> (7 - (self.pos % 8))) & 1;
        self.pos += 1;
        Ok(b as u32)
    }
    fn bits(&mut self, n: u32) -> anyhow::Result<u32> {
        let mut v = 0;
        for _ in 0..n {
            v = (v << 1) | self.bit()?;
        }
        Ok(v)
    }
    fn ue(&mut self) -> anyhow::Result<u32> {
        let mut zeros = 0;
        while self.bit()? == 0 {
            zeros += 1;
            anyhow::ensure!(zeros <= 31, "bad Exp-Golomb code in SPS");
        }
        Ok(((1u64 << zeros) - 1 + self.bits(zeros)? as u64) as u32)
    }
    fn se(&mut self) -> anyhow::Result<i32> {
        let k = self.ue()? as i64;
        Ok(if k % 2 == 1 { ((k + 1) / 2) as i32 } else { -(k / 2) as i32 })
    }
}

/// Largest `pic_width_in_mbs` / `pic_height_in_map_units` (8192 px) we parse;
/// bigger values are rejected before any arithmetic on them.
pub const MAX_SPS_MBS: u32 = 512;

/// Skip one scaling list (7.3.2.1.1.1); `delta_scale` must be in -128..=127.
fn skip_scaling_list(r: &mut Bits, size: usize) -> anyhow::Result<()> {
    let (mut last, mut next) = (8i32, 8i32);
    for _ in 0..size {
        if next != 0 {
            let delta = r.se()?;
            anyhow::ensure!((-128..=127).contains(&delta), "bad delta_scale in SPS");
            next = (last + delta + 256) % 256;
        }
        last = if next == 0 { last } else { next };
    }
    Ok(())
}

/// Display size (after cropping) from an SPS NAL (with the 1-byte NAL header).
/// Every value from the bitstream is range-checked before it is used in
/// arithmetic (peer data): no overflow, no implausible sizes.
pub fn sps_dimensions(sps: &[u8]) -> anyhow::Result<(u32, u32)> {
    anyhow::ensure!(nal_type(sps) == NAL_SPS, "not an SPS");
    let d = unescape(&sps[1..]);
    let mut r = Bits { d: &d, pos: 0 };
    let profile = r.bits(8)?;
    r.bits(16)?; // constraint flags + level
    anyhow::ensure!(r.ue()? < 32, "bad SPS id");
    let mut chroma_format = 1;
    if matches!(profile, 100 | 110 | 122 | 244 | 44 | 83 | 86 | 118 | 128 | 138 | 139 | 134 | 135) {
        chroma_format = r.ue()?;
        anyhow::ensure!(chroma_format <= 3, "bad chroma_format_idc");
        if chroma_format == 3 {
            r.bit()?;
        }
        r.ue()?; // bit depth luma
        r.ue()?; // bit depth chroma
        r.bit()?; // qpprime bypass
        if r.bit()? == 1 {
            let n = if chroma_format == 3 { 12 } else { 8 };
            for i in 0..n {
                if r.bit()? == 1 {
                    skip_scaling_list(&mut r, if i < 6 { 16 } else { 64 })?;
                }
            }
        }
    }
    anyhow::ensure!(r.ue()? <= 12, "bad log2_max_frame_num"); // log2_max_frame_num_minus4
    let poc_type = r.ue()?;
    if poc_type == 0 {
        anyhow::ensure!(r.ue()? <= 12, "bad log2_max_poc_lsb");
    } else if poc_type == 1 {
        r.bit()?;
        r.se()?;
        r.se()?;
        let n = r.ue()?;
        anyhow::ensure!(n <= 255, "bad SPS");
        for _ in 0..n {
            r.se()?;
        }
    } else {
        anyhow::ensure!(poc_type == 2, "bad pic_order_cnt_type");
    }
    r.ue()?; // max refs
    r.bit()?; // gaps allowed
    let w_mbs = r.ue()?;
    let h_map = r.ue()?;
    anyhow::ensure!(w_mbs < MAX_SPS_MBS && h_map < MAX_SPS_MBS, "SPS picture size out of range");
    let (w_mbs, h_map) = (w_mbs + 1, h_map + 1);
    let frame_mbs_only = r.bit()?;
    anyhow::ensure!((2 - frame_mbs_only) * h_map <= MAX_SPS_MBS, "SPS picture size out of range");
    if frame_mbs_only == 0 {
        r.bit()?;
    }
    r.bit()?; // direct 8x8
    let (sub_w, sub_h) = match chroma_format {
        0 => (1, 2 - frame_mbs_only),
        1 => (2, 2 * (2 - frame_mbs_only)),
        2 => (2, 2 - frame_mbs_only),
        _ => (1, 2 - frame_mbs_only),
    };
    // all ≤ 2 * 512 * 16: no overflow below
    let coded_w = w_mbs * 16;
    let coded_h = (2 - frame_mbs_only) * h_map * 16;
    let (mut crop_w, mut crop_h) = (0u64, 0u64);
    if r.bit()? == 1 {
        let (cl, cr, ct, cb) = (r.ue()? as u64, r.ue()? as u64, r.ue()? as u64, r.ue()? as u64);
        crop_w = (cl + cr) * sub_w as u64;
        crop_h = (ct + cb) * sub_h as u64;
    }
    anyhow::ensure!(crop_w < coded_w as u64 && crop_h < coded_h as u64, "SPS cropping larger than the picture");
    let (w, h) = (coded_w - crop_w as u32, coded_h - crop_h as u32);
    Ok((w, h))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn split_and_prepend() {
        let au = [0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 9, 9];
        let v: Vec<_> = nals(&au).map(nal_type).collect();
        assert_eq!(v, vec![7, 8, 5]);
        assert!(has_idr(&au));
        let mut ps = ParamSets::default();
        ps.learn(&au);
        let idr_only = vec![0, 0, 1, 0x65, 7];
        let full = ps.complete_keyframe(idr_only);
        assert_eq!(nals(&full).map(nal_type).collect::<Vec<_>>(), vec![7, 8, 5]);
        // P-frame stays untouched by `learn`.
        assert!(!has_idr(&[0, 0, 1, 0x41, 0]));
    }

    #[test]
    fn avcc_roundtrip() {
        let au = [0, 0, 0, 1, 0x67, 1, 2, 0, 0, 0, 1, 0x65, 9, 9];
        let avcc = annexb_to_avcc_slices(&au);
        assert_eq!(avcc, vec![0, 0, 0, 3, 0x65, 9, 9]);
        let mut back = Vec::new();
        avcc_to_annexb(&avcc, 4, &mut back).unwrap();
        assert_eq!(back, vec![0, 0, 0, 1, 0x65, 9, 9]);
        assert!(avcc_to_annexb(&[0, 0, 0, 9, 1], 4, &mut back).is_err());
    }

    #[test]
    fn sps_size() {
        // Baseline 1280x720 (x264-style SPS).
        let sps = [0x67, 0x42, 0xc0, 0x1f, 0xda, 0x01, 0x40, 0x16, 0xe8, 0x06, 0xd0, 0xa1, 0x35];
        assert_eq!(sps_dimensions(&sps).unwrap(), (1280, 720));
        assert!(sps_dimensions(&[0x67]).is_err());
    }

    /// Minimal Exp-Golomb writer for crafting (hostile) SPS NALs in tests.
    #[derive(Default)]
    pub(crate) struct TestBits {
        bits: Vec<bool>,
    }

    impl TestBits {
        pub fn u(&mut self, n: u32, v: u64) -> &mut Self {
            for i in (0..n).rev() {
                self.bits.push((v >> i) & 1 == 1);
            }
            self
        }
        /// Exp-Golomb code of `v` (up to 2^32 - 2).
        pub fn ue(&mut self, v: u64) -> &mut Self {
            let x = v + 1;
            let len = 64 - x.leading_zeros();
            self.u(len - 1, 0).u(len, x)
        }
        pub fn se(&mut self, v: i64) -> &mut Self {
            self.ue(if v > 0 { 2 * v as u64 - 1 } else { 2 * v.unsigned_abs() })
        }
        /// NAL with header byte `hdr`, stop bit, emulation prevention.
        pub fn nal(&mut self, hdr: u8) -> Vec<u8> {
            self.bits.push(true);
            while !self.bits.len().is_multiple_of(8) {
                self.bits.push(false);
            }
            let mut out = vec![hdr];
            let mut zeros = 0;
            for byte in self.bits.chunks(8).map(|c| c.iter().fold(0u8, |a, &b| (a << 1) | b as u8)) {
                if zeros >= 2 && byte <= 3 {
                    out.push(3);
                    zeros = 0;
                }
                zeros = if byte == 0 { zeros + 1 } else { 0 };
                out.push(byte);
            }
            out
        }
    }

    /// Baseline SPS (profile 66, poc type 2) with the given raw values.
    fn sps(w_mbs_m1: u64, h_map_m1: u64, frame_mbs_only: bool, crop: Option<[u64; 4]>) -> Vec<u8> {
        let mut b = TestBits::default();
        b.u(8, 66).u(16, 0x1f).ue(0).ue(0).ue(2).ue(1).u(1, 0).ue(w_mbs_m1).ue(h_map_m1).u(1, frame_mbs_only as u64);
        if !frame_mbs_only {
            b.u(1, 0);
        }
        b.u(1, 1);
        match crop {
            Some(c) => {
                b.u(1, 1);
                for v in c {
                    b.ue(v);
                }
            }
            None => {
                b.u(1, 0);
            }
        }
        b.u(1, 0).nal(0x67)
    }

    #[test]
    fn sps_hostile_values_are_rejected_without_overflow() {
        // sane: 1920x1080 via crop of 1088
        assert_eq!(sps_dimensions(&sps(119, 67, true, Some([0, 0, 0, 4]))).unwrap(), (1920, 1080));
        // 4096x2304 exactly (the decode cap)
        assert_eq!(sps_dimensions(&sps(255, 143, true, None)).unwrap(), (4096, 2304));
        // largest parseable: 512 MBs (8192) — parse ok, the decode cap rejects it
        assert_eq!(sps_dimensions(&sps(511, 511, true, None)).unwrap(), (8192, 8192));
        assert!(super::super::check_decode_dims(8192, 8192).is_err());
        // more than 512 MBs, up to the largest Exp-Golomb value
        for big in [512, 4096, 1 << 20, u32::MAX as u64 - 1] {
            assert!(sps_dimensions(&sps(big, 10, true, None)).is_err(), "w {big}");
            assert!(sps_dimensions(&sps(10, big, true, None)).is_err(), "h {big}");
        }
        // field coding doubles the height: 2 * 300 map units is too many
        assert!(sps_dimensions(&sps(10, 299, false, None)).is_err());
        assert_eq!(sps_dimensions(&sps(10, 255, false, None)).unwrap(), (176, 8192));
        // cropping: huge values, sum overflow, crop ≥ picture
        let max = u32::MAX as u64 - 1;
        for c in [[max, max, 0, 0], [0, 0, max, max], [8, 0, 0, 0], [0, 0, 8, 0], [4, 4, 0, 0], [max, 0, 0, 0]] {
            assert!(sps_dimensions(&sps(0, 0, true, Some(c))).is_err(), "crop {c:?}");
        }
        assert_eq!(sps_dimensions(&sps(0, 0, true, Some([3, 4, 7, 0]))).unwrap(), (2, 2));
        // huge delta_scale in a scaling list (High profile)
        let mut b = TestBits::default();
        b.u(8, 100).u(16, 0x28).ue(0).ue(1).ue(0).ue(0).u(1, 0).u(1, 1).u(1, 1).se(i32::MIN as i64 + 1);
        assert!(sps_dimensions(&b.nal(0x67)).is_err());
        let mut b = TestBits::default();
        b.u(8, 100).u(16, 0x28).ue(0).ue(1).ue(0).ue(0).u(1, 0).u(1, 1).u(1, 1).se(i32::MAX as i64);
        assert!(sps_dimensions(&b.nal(0x67)).is_err());
        // huge log2_max_frame_num / poc lsb / poc type
        let mut b = TestBits::default();
        b.u(8, 66).u(16, 0x1f).ue(0).ue(u32::MAX as u64 - 1);
        assert!(sps_dimensions(&b.nal(0x67)).is_err());
        let mut b = TestBits::default();
        b.u(8, 66).u(16, 0x1f).ue(0).ue(0).ue(0).ue(u32::MAX as u64 - 1);
        assert!(sps_dimensions(&b.nal(0x67)).is_err());
        let mut b = TestBits::default();
        b.u(8, 66).u(16, 0x1f).ue(0).ue(0).ue(7);
        assert!(sps_dimensions(&b.nal(0x67)).is_err());
        // truncated everywhere: never panics
        let full = sps(119, 67, true, Some([0, 0, 0, 4]));
        for n in 1..full.len() {
            let _ = sps_dimensions(&full[..n]);
        }
        // the hand-made 8192x8192 SPS used by the Media Foundation test
        let sps8k = [0x67, 0x42, 0xc0, 0x33, 0xda, 0x00, 0x20, 0x00, 0x04, 0x01, 0x90];
        assert_eq!(sps_dimensions(&sps8k).unwrap(), (8192, 8192));
        // the AU check used before any decoder sees peer data
        let au = [&[0u8, 0, 0, 1][..], &sps(511, 511, true, None)].concat();
        assert!(super::super::check_h264_au(&au).is_err());
        let au = [&[0u8, 0, 0, 1][..], &sps(119, 67, true, None)].concat();
        assert!(super::super::check_h264_au(&au).is_ok());
    }
}
