#!/usr/bin/env python3
"""Vendor libvpx and generate everything its own `configure` would.

Usage: python3 -I tools/gen_build.py <libvpx checkout> [--vendor]

* `--vendor` copies the source subset Lumora needs (VP8 + VP9, encoder +
  decoder, C + x86/Arm SIMD) to core/third_party/libvpx.
* Always (re)writes gen/<variant>/: the rtcd headers, the list of C files to
  compile with the ISA each needs, and vpx_version.h. build.rs writes
  vpx_config.h itself from gen/<variant>/config.txt (it depends on the target
  compiler/OS).

We never run libvpx's configure/perl: this script re-implements the small
subset of make/perl it needs (mk conditionals, rtcd specialisation), so the
build only needs a C compiler (cc crate) — no perl, nasm/yasm or make — and
cross-compiles to every Lumora target, MSVC included.

Variants:
* generic      — plain C (any target).
* x86_64       — C + SSE2..AVX2 intrinsics (no .asm files), runtime CPU detection.
* arm64        — C + NEON intrinsics (NEON is baseline on AArch64), static dispatch.
"""
import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CRATE = os.path.dirname(HERE)
CORE = os.path.dirname(os.path.dirname(CRATE))
VENDOR = os.path.join(CORE, "third_party", "libvpx")
VERSION = (1, 17, 0)

DIRS = ["vpx", "vpx_dsp", "vpx_mem", "vpx_ports", "vpx_scale", "vpx_util", "vp8", "vp9", "third_party/x86inc"]
# .asm files that are only %include'd, never assembled on their own
ASM_INCLUDE_ONLY = {"vpx_ports/x86_abi_support.asm", "third_party/x86inc/x86inc.asm",
                    "vpx_dsp/x86/bitdepth_conversion_sse2.asm"}
TOP_FILES = ["LICENSE", "PATENTS", "AUTHORS", "README", "CHANGELOG"]
SKIP_DIR_NAMES = {"mips", "ppc", "loongarch", "riscv"}

ARCH_LIST = "arm aarch64 mips x86 x86_64 ppc loongarch riscv".split()
EXT_AARCH64 = "neon neon_dotprod neon_i8mm sve sve2".split()
EXT_X86 = "mmx sse sse2 sse3 ssse3 sse4_1 avx avx2 avx512".split()
EXT_ALL = ["neon_asm"] + EXT_AARCH64 + "mips32 dspr2 msa mips64 x86_asm".split() + EXT_X86 + ["vsx", "mmi", "lsx", "lasx", "rvv"]
HAVE_LIST = EXT_ALL + "vpx_ports pthread_h pthread_setname_np unistd_h".split()
CONFIG_LIST = """dependency_tracking external_build install_docs install_bins install_libs install_srcs debug gprof gcov
rvct gcc msvs pic big_endian codec_srcs debug_libs dequant_tokens dc_recon runtime_cpu_detect postproc vp9_postproc
multithread internal_stats vp8_encoder vp8_decoder vp9_encoder vp9_decoder vp8 vp9 encoders decoders static_msvcrt
spatial_resampling realtime_only onthefly_bitpacking error_concealment shared static small postproc_visualizer
os_support unit_tests webm_io libyuv decode_perf_tests encode_perf_tests multi_res_encoding temporal_denoising
vp9_temporal_denoising coefficient_range_checking vp9_highbitdepth better_hw_compatibility experimental size_limit
always_adjust_bpm bitstream_debug mismatch_debug fp_mb_stats emulate_hardware non_greedy_mv
collect_component_timing""".split()

# Feature selection (same spirit as `configure --enable-realtime-only --disable-...`).
CONFIG_ON = set("""pic codec_srcs multithread vp8_encoder vp8_decoder vp9_encoder vp9_decoder vp8 vp9 encoders decoders
spatial_resampling realtime_only static os_support temporal_denoising""".split())
# Placeholders filled in by build.rs per target: gcc msvs pthread_h unistd_h pthread_setname_np

VARIANTS = {
    "generic": {"arch": None, "exts": [], "rtcd": False},
    # intrinsics only — used when no assembler (nasm/yasm) is available
    "x86_64": {"arch": "x86_64", "exts": ["mmx", "sse", "sse2", "sse3", "ssse3", "sse4_1", "avx", "avx2"], "rtcd": True},
    # intrinsics + libvpx's hand-written x86 assembly (nasm) — the fast path
    "x86_64-asm": {"arch": "x86_64", "exts": ["mmx", "sse", "sse2", "sse3", "ssse3", "sse4_1", "avx", "avx2"], "rtcd": True, "asm": True},
    "arm64": {"arch": "aarch64", "exts": ["neon"], "rtcd": False},
}
# compiler flags per ISA (gcc/clang; build.rs maps them for MSVC)
ISA_OF_SUFFIX = [("_avx512", "avx512"), ("_avx2", "avx2"), ("_avx", "avx"), ("_sse4", "sse4_1"), ("_ssse3", "ssse3"),
                 ("_sse3", "sse3"), ("_sse2", "sse2"), ("_mmx", "mmx"), ("_neon", "neon")]


def config_values(variant):
    v = VARIANTS[variant]
    cfg = {}
    for a in ARCH_LIST:
        cfg["VPX_ARCH_" + a.upper()] = "yes" if (v["arch"] == a or (a == "x86" and False)) else "no"
    for h in HAVE_LIST:
        cfg["HAVE_" + h.upper()] = "yes" if h in v["exts"] else "no"
    cfg["HAVE_VPX_PORTS"] = "yes"
    cfg["HAVE_X86_ASM"] = "yes" if v.get("asm") else "no"
    cfg["HAVE_PTHREAD_H"] = "yes"
    cfg["HAVE_UNISTD_H"] = "yes"
    for c in CONFIG_LIST:
        cfg["CONFIG_" + c.upper()] = "yes" if c in CONFIG_ON else "no"
    cfg["CONFIG_RUNTIME_CPU_DETECT"] = "yes" if v["rtcd"] else "no"
    return cfg


# ----------------------------------------------------------------- make subset

def mk_lines(path):
    with open(path) as f:
        text = f.read().replace("\\\n", " ")
    return text.splitlines()


def expand(s, cfg, vars_):
    # $(or $(A),$(B)) → yes if any is yes
    def rep_or(m):
        parts = [expand(p, cfg, vars_).strip() for p in m.group(1).split(",")]
        return next((p for p in parts if p), "")
    for _ in range(4):
        s = re.sub(r"\$\(or ([^()]*(?:\([^()]*\)[^()]*)*)\)", rep_or, s)
    def rep_var(m):
        name = m.group(1)
        if name in cfg:
            # config.mk only defines enabled options ("yes"); disabled ones are empty,
            # which matters for tests like $(VPX_ARCH_X86)$(VPX_ARCH_X86_64) == yes
            return cfg[name] if cfg[name] == "yes" else ""
        return " ".join(vars_.get(name, []))
    for _ in range(4):
        s = re.sub(r"\$\(([A-Za-z0-9_\-]+)\)", rep_var, s)
    def rep_filter_out(m):
        drop = set(m.group(1).split())
        return " ".join(x for x in m.group(2).split() if x not in drop)
    s = re.sub(r"\$\(filter-out ([^,()]*),([^()]*)\)", rep_filter_out, s)
    return s


def eval_cond(line, cfg, vars_):
    m = re.match(r"\s*(ifeq|ifneq)\s*\((.*)\)\s*$", line)
    kind, body = m.group(1), m.group(2)
    if body.startswith("$(filter"):
        fm = re.match(r"\$\(filter\s+(\S+),(.*)\)\s*,\s*(.*)$", body)
        word, lst, rhs = fm.group(1), expand(fm.group(2), cfg, vars_).split(), fm.group(3).strip()
        lhs = word if word in lst else ""
    else:
        lhs, rhs = [expand(x, cfg, vars_).strip() for x in body.split(",", 1)]
    eq = lhs == rhs
    return eq if kind == "ifeq" else not eq


def run_mk(path, cfg, vars_):
    stack = []
    for raw in mk_lines(path):
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        s = line.strip()
        if s.startswith("ifeq") or s.startswith("ifneq"):
            active = all(stack)
            stack.append(active and eval_cond(s, cfg, vars_))
            continue
        if s == "else":
            parent = all(stack[:-1])
            stack[-1] = parent and not stack[-1]
            continue
        if s.startswith("endif"):
            stack.pop()
            continue
        if not all(stack):
            continue
        if s.startswith("$(eval") or s.startswith("include") or s.startswith("$(call"):
            continue
        m = re.match(r"([A-Za-z0-9_\-\$\(\)]+)\s*(\+=|:=|=)\s*(.*)$", s)
        if not m:
            continue
        name = expand(m.group(1), cfg, vars_)
        vals = expand(m.group(3), cfg, vars_).split()
        if m.group(2) == "+=":
            vars_.setdefault(name, []).extend(vals)
        else:
            vars_[name] = vals


def enabled(vars_, name):
    rm = set(vars_.get(name + "_REMOVE-yes", []))
    return [x for x in vars_.get(name + "-yes", []) if x not in rm]


def source_list(src, variant):
    cfg = config_values(variant)
    out = []
    v = {}
    run_mk(os.path.join(src, "vpx/vpx_codec.mk"), cfg, v)
    out += ["vpx/" + x for x in enabled(v, "API_SRCS")]
    for d, mk, var in [("vpx_mem", "vpx_mem.mk", "MEM_SRCS"), ("vpx_scale", "vpx_scale.mk", "SCALE_SRCS"),
                       ("vpx_ports", "vpx_ports.mk", "PORTS_SRCS"), ("vpx_dsp", "vpx_dsp.mk", "DSP_SRCS"),
                       ("vpx_util", "vpx_util.mk", "UTIL_SRCS")]:
        v = {}
        run_mk(os.path.join(src, d, mk), cfg, v)
        out += [d + "/" + x for x in enabled(v, var)]
    v = {"VP8_PREFIX": ["vp8/"]}
    run_mk(os.path.join(src, "vp8/vp8_common.mk"), cfg, v)
    run_mk(os.path.join(src, "vp8/vp8cx.mk"), cfg, v)
    run_mk(os.path.join(src, "vp8/vp8dx.mk"), cfg, v)
    out += ["vp8/" + x for x in dict.fromkeys(enabled(v, "VP8_CX_SRCS") + enabled(v, "VP8_DX_SRCS"))]
    v = {"VP9_PREFIX": ["vp9/"]}
    run_mk(os.path.join(src, "vp9/vp9_common.mk"), cfg, v)
    run_mk(os.path.join(src, "vp9/vp9cx.mk"), cfg, v)
    run_mk(os.path.join(src, "vp9/vp9dx.mk"), cfg, v)
    out += ["vp9/" + x for x in dict.fromkeys(enabled(v, "VP9_CX_SRCS") + enabled(v, "VP9_DX_SRCS"))]
    if variant == "x86_64":  # (the asm variant assembles emms_mmx.asm instead)
        # vpx_clear_system_state(): libvpx uses emms_mmx.asm on x86_64; the C
        # version (_mm_empty) used for 32-bit x86 is equivalent.
        out.append("vpx_ports/emms_mmx.c")
    srcs = []
    for f in dict.fromkeys(out):
        f = os.path.normpath(f)
        if f.endswith(".c") or (f.endswith(".asm") and VARIANTS[variant].get("asm") and f not in ASM_INCLUDE_ONLY):
            if not os.path.exists(os.path.join(src, f)):
                raise SystemExit(f"missing source {f}")
            srcs.append(f)
    return srcs


def isa_of(path):
    if path.endswith(".asm"):
        return "asm"
    base = os.path.basename(path)
    for suf, isa in ISA_OF_SUFFIX:
        if suf in base:
            return isa
    if "/x86/" in path:
        return "sse2"
    if "/arm/" in path:
        return "neon"
    return "c"


# ----------------------------------------------------------------- rtcd subset

class Rtcd:
    def __init__(self, cfg, arch, exts):
        self.cfg = cfg
        self.arch = arch
        self.exts = exts
        self.funcs = {}  # name -> (ret, args)
        self.order = []
        self.vars = {}  # "<fn>_<opt>" -> implementation name
        self.forward = []
        self.scal = {}  # perl scalar variables ($sse2_x86_64 = 'sse2')

    def cond(self, expr):
        e = expr
        e = re.sub(r'vpx_config\("([A-Z0-9_]+)"\)\s*(eq|ne)\s*"(\w*)"',
                   lambda m: str((self.cfg.get(m.group(1), "") == m.group(3)) == (m.group(2) == "eq")), e)
        e = re.sub(r'\$opts\{arch\}\s*(eq|ne)\s*"(\w*)"',
                   lambda m: str(((self.arch or "") == m.group(2)) == (m.group(1) == "eq")), e)
        e = e.replace("&&", " and ").replace("||", " or ").replace("!", " not ")
        return eval(e, {"__builtins__": {}}, {"True": True, "False": False})

    def run(self, path):
        text = open(path).read()
        # forward-decl heredocs
        for m in re.finditer(r"print <<EOF\n(.*?)\nEOF", text, re.S):
            self.forward.append(m.group(1))
        text = re.sub(r"sub \w+\(\) \{\s*print <<EOF\n.*?\nEOF\n\s*\}", "", text, flags=re.S)
        # statements, keeping braces as tokens
        text = re.sub(r"#[^\n]*", "", text)
        toks = re.findall(r'if\s*\((?:[^()]|\([^()]*\))*\)\s*\{|\}\s*else\s*\{|\}|[^;{}]+;', text)
        stack = []
        for t in toks:
            t = t.strip()
            if t.startswith("if"):
                c = re.match(r"if\s*\((.*)\)\s*\{$", t, re.S).group(1)
                active = all(s for s in stack)
                stack.append(active and self.cond(c))
            elif re.match(r"\}\s*else\s*\{", t):
                parent = all(s for s in stack[:-1])
                stack[-1] = parent and not stack[-1]
            elif t == "}":
                stack.pop()
            else:
                if not all(stack):
                    continue
                self.stmt(" ".join(t.rstrip(";").split()))

    def stmt(self, s):
        m = re.match(r'add_proto (.*)$', s)
        if m:
            # perl: add_proto(@ret_words, name, args) — name is the second-to-last arg
            args = []
            for q, lit in re.findall(r'qw/(.*?)/|"(.*?)"', m.group(1)):
                args += q.split() if q else [lit]
            name, ret, sig = args[-2], " ".join(args[:-2]), args[-1]
            if name not in self.funcs:
                self.order.append(name)
            self.funcs[name] = (ret, sig)
            self.vars[name + "_c"] = name + "_c"
            return
        m = re.match(r"specialize qw/(.*?)/((?:\s*,\s*\"\$\w+\")*)$", s)
        if m:
            words = m.group(1).split()
            extra = [self.scal.get(x, "") for x in re.findall(r"\$(\w+)", m.group(2))]
            for opt in words[1:] + [x for x in extra if x]:
                self.vars[f"{words[0]}_{opt}"] = f"{words[0]}_{opt}"
            return
        m = re.match(r"((?:\$\w+\s*=\s*)+)('[^']*'|\"[^\"]*\"|\w+)$", s)
        if m:
            names = re.findall(r"\$(\w+)", m.group(1))
            val = m.group(2)
            for n in names:
                if val[0] in "'\"":
                    self.scal[n] = val[1:-1]
                else:
                    self.vars[n] = val
            return
        if s in ("1", "") or s.startswith("forward_decls") or s.startswith("print"):
            return
        raise SystemExit(f"unhandled rtcd statement: {s!r}")

    def header(self, sym, include_asm_free):
        out = []
        guard = sym.upper() + "_H_"
        out.append("// Generated by lumora-vpx-sys/tools/gen_build.py from libvpx %d.%d.%d. Do not edit.\n" % VERSION)
        out.append(f"#ifndef {guard}\n#define {guard}\n\n#ifdef RTCD_C\n#define RTCD_EXTERN\n#else\n#define RTCD_EXTERN extern\n#endif\n")
        out += self.forward
        out.append('\n#ifdef __cplusplus\nextern "C" {\n#endif\n')
        sets = []
        for fn in sorted(self.funcs):
            ret, args = self.funcs[fn]
            impls = [("c", self.vars[fn + "_c"])]
            for opt in self.exts:
                impl = self.vars.get(f"{fn}_{opt}")
                if impl and include_asm_free(impl):
                    impls.append((opt, impl))
            for _, impl in impls:
                out.append(f"{ret} {impl}({args});")
            if self.arch is None or not VARIANT_RTCD:
                best = impls[-1][1]
                out.append(f"#define {fn} {best}\n")
            else:
                # runtime dispatch, lowest to highest preference (exts are ordered)
                if len(impls) == 1:
                    out.append(f"#define {fn} {impls[0][1]}\n")
                    continue
                out.append(f"RTCD_EXTERN {ret} (*{fn})({args});\n")
                sets.append(f"    {fn} = {impls[0][1]};")
                for opt, impl in impls[1:]:
                    if impl == impls[0][1]:
                        continue
                    sets.append(f"    if (flags & HAS_{opt.upper()}) {fn} = {impl};")
        out.append(f"void {sym}(void);\n")
        if self.arch == "x86_64" and VARIANT_RTCD:
            out.append('#include "vpx_config.h"\n\n#ifdef RTCD_C\n#include "vpx_ports/x86.h"\nstatic void setup_rtcd_internal(void)\n{\n    int flags = x86_simd_caps();\n\n    (void)flags;\n')
        else:
            out.append('#include "vpx_config.h"\n\n#ifdef RTCD_C\nstatic void setup_rtcd_internal(void)\n{\n')
        out += sets
        out.append("}\n#endif\n")
        out.append('\n#ifdef __cplusplus\n}  // extern "C"\n#endif\n\n#endif\n')
        return "\n".join(out)


VARIANT_RTCD = False

# x86 specialisations implemented only in .asm files that the generic
# `cglobal` scan above cannot attribute (found by linking; re-check on update).
X86_ASM_ONLY = {"vp9_block_error_sse2", "vpx_fdct8x8_ssse3", "vpx_hadamard_8x8_ssse3"}


def asm_symbols(src):
    """Functions implemented only in .asm (we don't assemble) — never dispatch to them."""
    syms = set()
    for root, _, files in os.walk(src):
        for f in files:
            if f.endswith(".asm"):
                for line in open(os.path.join(root, f), errors="replace"):
                    m = re.match(r"\s*cglobal\s+(\w+)", line)
                    if m:
                        syms.add(m.group(1))
                    m = re.match(r"\s*global\s+sym\((\w+)\)", line)
                    if m:
                        syms.add(m.group(1))
                    m = re.match(r"\s*(?:SAD\w*|SADNXN4D|HIGH_SADNXN4D|\w+_FN)\s+(\d+),\s*(\d+)", line)
    return syms


def c_defined(src, srcs):
    """Names of functions defined in the C files we compile (cheap regex)."""
    names = set()
    for f in srcs:
        text = open(os.path.join(src, f), errors="replace").read()
        for m in re.finditer(r"^[\w \*]*?\b(\w+)\s*\([^;{]*\)\s*\{", text, re.M):
            names.add(m.group(1))
        # function-generating macros: collect every identifier that ends with an ISA suffix
        for m in re.finditer(r"\b(\w+_(?:c|sse2|sse3|ssse3|sse4_1|avx|avx2|neon))\b", text):
            names.add(m.group(1))
        for m in re.finditer(r"##\s*_(\w+)", text):
            pass
    return names


def generate(src, variant):
    global VARIANT_RTCD
    v = VARIANTS[variant]
    VARIANT_RTCD = v["rtcd"]
    cfg = config_values(variant)
    srcs = source_list(src, variant)
    outdir = os.path.join(CRATE, "gen", variant)
    os.makedirs(outdir, exist_ok=True)
    no_asm = variant == "x86_64"
    asm = asm_symbols(src) if no_asm else set()

    def ok(impl):
        return not no_asm or (impl not in asm and impl not in X86_ASM_ONLY)

    for sym, defs, name in [("vpx_dsp_rtcd", "vpx_dsp/vpx_dsp_rtcd_defs.pl", "vpx_dsp_rtcd.h"),
                            ("vp8_rtcd", "vp8/common/rtcd_defs.pl", "vp8_rtcd.h"),
                            ("vp9_rtcd", "vp9/common/vp9_rtcd_defs.pl", "vp9_rtcd.h"),
                            ("vpx_scale_rtcd", "vpx_scale/vpx_scale_rtcd.pl", "vpx_scale_rtcd.h")]:
        r = Rtcd(cfg, v["arch"], v["exts"])
        r.run(os.path.join(src, defs))
        with open(os.path.join(outdir, name), "w") as f:
            f.write(r.header(sym, ok))
    with open(os.path.join(outdir, "sources.txt"), "w") as f:
        for s in srcs:
            f.write(f"{isa_of(s)} {s}\n")
    with open(os.path.join(outdir, "config.txt"), "w") as f:
        for k, val in cfg.items():
            f.write(f"{k} {1 if val == 'yes' else 0}\n")
    print(f"{variant}: {len(srcs)} C files")


def write_version():
    maj, mi, pa = VERSION
    with open(os.path.join(CRATE, "gen", "vpx_version.h"), "w") as f:
        f.write(f"""// Generated by lumora-vpx-sys/tools/gen_build.py. Do not edit.
#define VERSION_MAJOR  {maj}
#define VERSION_MINOR  {mi}
#define VERSION_PATCH  {pa}
#define VERSION_EXTRA  "lumora"
#define VERSION_PACKED ((VERSION_MAJOR<<16)|(VERSION_MINOR<<8)|(VERSION_PATCH))
#define VERSION_STRING_NOSP "v{maj}.{mi}.{pa}"
#define VERSION_STRING      " v{maj}.{mi}.{pa}"
""")


def vendor(src):
    if os.path.exists(VENDOR):
        shutil.rmtree(VENDOR)
    os.makedirs(VENDOR)
    for f in TOP_FILES:
        shutil.copy2(os.path.join(src, f), VENDOR)
    for d in DIRS:
        for root, dirs, files in os.walk(os.path.join(src, d)):
            dirs[:] = [x for x in dirs if x not in SKIP_DIR_NAMES]
            rel = os.path.relpath(root, src)
            os.makedirs(os.path.join(VENDOR, rel), exist_ok=True)
            for f in files:
                if f.endswith((".c", ".h", ".mk", ".pl", ".asm")) or f in ("LICENSE", "README.libvpx"):
                    shutil.copy2(os.path.join(root, f), os.path.join(VENDOR, rel, f))


def main():
    src = os.path.abspath(sys.argv[1])
    if "--vendor" in sys.argv:
        vendor(src)
        src = VENDOR
    for variant in VARIANTS:
        generate(src, variant)
    write_version()


if __name__ == "__main__":
    main()
