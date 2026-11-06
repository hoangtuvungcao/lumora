//! Builds the vendored libvpx (core/third_party/libvpx, VP8 + VP9) as a static
//! library with the `cc` crate only — no configure/make/perl/nasm needed, so it
//! cross-compiles to every Lumora target (Linux, Windows MSVC/GNU, macOS, iOS,
//! Android). The file lists and rtcd headers come from `tools/gen_build.py`.
//!
//! SIMD: AArch64 uses NEON intrinsics (baseline there). x86_64 uses libvpx's
//! hand-written assembly (needs `nasm` ≥ 2.14 or `yasm`: `$NASM`, else on PATH)
//! plus the SSE2..AVX2 intrinsics, with run-time CPU detection — about 2-3x
//! faster than intrinsics alone. Without an assembler it falls back to the
//! intrinsics with a build warning (`LUMORA_VPX_REQUIRE_ASM=1` makes that an
//! error, as release CI does). Everything else (and `LUMORA_VPX_GENERIC=1`)
//! builds the portable C code.

use std::fmt::Write as _;
use std::path::{Path, PathBuf};

fn main() {
    let manifest = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let src = manifest.join("../../third_party/libvpx").canonicalize().expect("core/third_party/libvpx is missing");
    let out = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    let arch = std::env::var("CARGO_CFG_TARGET_ARCH").unwrap();
    let os = std::env::var("CARGO_CFG_TARGET_OS").unwrap();
    let env = std::env::var("CARGO_CFG_TARGET_ENV").unwrap_or_default();
    let msvc = env == "msvc";
    let force_generic = std::env::var("LUMORA_VPX_GENERIC").map(|v| v == "1").unwrap_or(false);
    let assembler = if arch == "x86_64" && !force_generic { find_assembler() } else { None };
    let variant = match arch.as_str() {
        _ if force_generic => "generic",
        "aarch64" => "arm64",
        "x86_64" if assembler.is_some() => "x86_64-asm",
        "x86_64" => {
            if std::env::var("LUMORA_VPX_REQUIRE_ASM").is_ok_and(|v| v == "1") {
                panic!("LUMORA_VPX_REQUIRE_ASM=1 but neither nasm nor yasm was found (set NASM=/path/to/nasm)");
            }
            println!("cargo:warning=libvpx: no nasm/yasm found — building x86_64 without its assembly (VP8/VP9 2-3x slower). Install nasm or set NASM=/path/to/nasm.");
            "x86_64"
        }
        _ => "generic",
    };
    println!("cargo:rerun-if-env-changed=LUMORA_VPX_GENERIC");
    println!("cargo:rerun-if-env-changed=LUMORA_VPX_REQUIRE_ASM");
    println!("cargo:rerun-if-env-changed=NASM");
    println!("cargo:rerun-if-env-changed=PATH");
    println!("cargo:rerun-if-changed=gen");
    println!("cargo:rerun-if-changed=build.rs");

    let gen = manifest.join("gen").join(variant);
    let inc = out.join("include");
    std::fs::create_dir_all(&inc).unwrap();
    for h in ["vpx_dsp_rtcd.h", "vp8_rtcd.h", "vp9_rtcd.h", "vpx_scale_rtcd.h"] {
        std::fs::copy(gen.join(h), inc.join(h)).unwrap();
    }
    std::fs::copy(manifest.join("gen/vpx_version.h"), inc.join("vpx_version.h")).unwrap();
    write_config(&gen.join("config.txt"), &inc.join("vpx_config.h"), &os, msvc);
    // the assembler's view of the same configuration (libvpx: "X equ 0|1")
    let cfg_h = std::fs::read_to_string(inc.join("vpx_config.h")).unwrap();
    let cfg_asm: String = cfg_h
        .lines()
        .filter_map(|l| {
            let mut it = l.split_whitespace();
            match (it.next(), it.next(), it.next()) {
                (Some("#define"), Some(k), Some(v @ ("0" | "1"))) => Some(format!("{k} equ {v}\n")),
                _ => None,
            }
        })
        .collect();
    std::fs::write(inc.join("vpx_config.asm"), cfg_asm).unwrap();

    let sources = std::fs::read_to_string(gen.join("sources.txt")).unwrap();
    let mut groups: std::collections::BTreeMap<String, Vec<PathBuf>> = Default::default();
    for line in sources.lines() {
        let (isa, file) = line.split_once(' ').unwrap();
        groups.entry(isa.to_string()).or_default().push(src.join(file));
    }

    let base = || {
        let mut b = cc::Build::new();
        b.include(&inc).include(&src).warnings(false).define("NDEBUG", None);
        // speed matters more than size for a video codec, even in debug builds
        b.opt_level(2).debug(false);
        if msvc {
            b.flag("/wd4996");
        } else {
            b.flag_if_supported("-fno-strict-aliasing");
            b.flag_if_supported("-Wno-unused-function");
        }
        b
    };
    let mut objects = Vec::new();
    if let (Some(asm), Some(files)) = (assembler.as_ref(), groups.remove("asm")) {
        let fmt = match os.as_str() {
            "windows" => "win64",
            "macos" | "ios" => "macho64",
            _ => "elf64",
        };
        let objdir = out.join("asm");
        std::fs::create_dir_all(&objdir).unwrap();
        for f in files {
            let rel = f.strip_prefix(&src).unwrap().to_string_lossy().replace(['/', '\\'], "_");
            let obj = objdir.join(format!("{rel}.o"));
            let st = std::process::Command::new(asm)
                .arg("-f")
                .arg(fmt)
                .arg(format!("-I{}/", src.display()))
                .arg(format!("-I{}/", inc.display()))
                .arg("-o")
                .arg(&obj)
                .arg(&f)
                .status()
                .unwrap_or_else(|e| panic!("cannot run {}: {e}", asm.display()));
            assert!(st.success(), "assembling {} failed", f.display());
            objects.push(obj);
        }
    }
    for (isa, files) in &groups {
        let mut b = base();
        for f in isa_flags(isa, msvc) {
            b.flag(f);
        }
        b.files(files);
        objects.extend(b.compile_intermediates());
    }
    let mut lib = base();
    lib.objects(objects);
    lib.compile("vpx");
    if os == "linux" || os == "android" {
        println!("cargo:rustc-link-lib=m");
    }
    if os == "linux" {
        println!("cargo:rustc-link-lib=pthread");
    }
}

/// nasm (≥ 2.14, what libvpx's own build prefers) or yasm: `$NASM`, else PATH.
fn find_assembler() -> Option<PathBuf> {
    let ok = |p: &Path| std::process::Command::new(p).arg("-v").output().is_ok_and(|o| o.status.success() && !String::from_utf8_lossy(&o.stdout).contains("Apple"));
    if let Some(p) = std::env::var_os("NASM").map(PathBuf::from) {
        if ok(&p) {
            return Some(p);
        }
        println!("cargo:warning=NASM={} does not run", p.display());
    }
    ["nasm", "yasm"].into_iter().map(PathBuf::from).find(|p| ok(p))
}

fn isa_flags(isa: &str, msvc: bool) -> Vec<&'static str> {
    if msvc {
        return match isa {
            "avx" => vec!["/arch:AVX"],
            "avx2" => vec!["/arch:AVX2"],
            _ => vec![], // SSE2..SSE4.1 intrinsics need no flag on x64 MSVC
        };
    }
    match isa {
        "mmx" => vec!["-mmmx"],
        "sse2" => vec!["-msse2"],
        "sse3" => vec!["-msse3"],
        "ssse3" => vec!["-mssse3"],
        "sse4_1" => vec!["-msse4.1"],
        "avx" => vec!["-mavx"],
        "avx2" => vec!["-mavx2"],
        _ => vec![],
    }
}

/// vpx_config.h from the generated feature list plus target specifics.
fn write_config(list: &Path, dst: &Path, os: &str, msvc: bool) {
    let windows = os == "windows";
    let mut h = String::from("/* Generated by lumora-vpx-sys build.rs. */\n#ifndef VPX_CONFIG_H\n#define VPX_CONFIG_H\n");
    if msvc {
        h.push_str("#define RESTRICT\n#define INLINE __inline\n");
    } else {
        h.push_str("#define RESTRICT __restrict\n#define INLINE inline\n");
    }
    for line in std::fs::read_to_string(list).unwrap().lines() {
        let (k, v) = line.split_once(' ').unwrap();
        let v = match k {
            "HAVE_PTHREAD_H" => !windows,
            "HAVE_UNISTD_H" => !msvc,
            "HAVE_PTHREAD_SETNAME_NP" => false,
            "CONFIG_GCC" => !msvc,
            "CONFIG_MSVS" => msvc,
            // refuse absurd frame sizes from a hostile peer (memory), see DECODE_*_LIMIT
            "CONFIG_SIZE_LIMIT" => true,
            _ => v == "1",
        };
        let _ = writeln!(h, "#define {k} {}", v as u8);
    }
    h.push_str("#define DECODE_WIDTH_LIMIT 4096\n#define DECODE_HEIGHT_LIMIT 4096\n#endif\n");
    std::fs::write(dst, h).unwrap();
}
