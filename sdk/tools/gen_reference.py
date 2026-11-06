#!/usr/bin/env python3
"""Generate the SDK API references from the source docstrings (single source of truth).

  docs/src/bots/reference-python.md   from sdk/python/lumora_bot.py  (docstrings, Google style)
  docs/src/bots/reference-js.md       from sdk/js/lumora-bot.mjs     (JSDoc)

    python3 sdk/tools/gen_reference.py           # write both files
    python3 sdk/tools/gen_reference.py --check   # exit 1 if they are out of date (used by tests)

The website (branding/tools/build_pages.py) renders these files to /developers/reference/python/
and /developers/reference/js/.
"""
import importlib.util
import sys as _sys
_sys.dont_write_bytecode = True
import inspect
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SDK = ROOT / "sdk"
OUT = ROOT / "docs" / "src" / "bots"

# Bot methods grouped for reading; names are Python's, JS uses the camelCase twin.
BOT_GROUPS = [
    ("Handlers", "handlers", ["command", "on_message", "on_text", "on_callback", "on_new_user", "on_new_member", "on_member_left",
                              "on_added_to_group", "on_file", "on_reminder_due", "on_checklist", "on_event", "middleware", "use",
                              "on_error", "on_start"]),
    ("Sending messages", "sending", ["send", "send_file", "send_poll", "send_sticker", "send_location", "update_live_location",
                                      "send_contact", "send_voice", "broadcast"]),
    ("Checklists and reminders", "tasks", ["send_checklist", "checklist_toggle", "checklist_add", "checklist", "send_reminder",
                                           "reminder_cancel", "reminders"]),
    ("Message actions", "actions", ["edit_message", "delete_message", "pin_message", "pinned_messages", "react", "forward_message",
                                    "messages", "typing", "mark_read", "schedule_message", "scheduled_messages", "cancel_scheduled"]),
    ("Files", "files", ["files", "accept_file", "cancel_file", "download_file"]),
    ("Groups", "groups", ["groups", "group_info", "group_access", "member_role", "group_ban", "group_unban", "group_remove",
                          "group_settings", "set_slow_mode", "group_purge_member", "group_leave", "search_groups"]),
    ("Users and profile", "users", ["users", "contacts", "name_of", "cached_name", "resolve_username", "block_user", "unblock_user",
                                    "set_profile", "set_commands"]),
    ("Jobs (scheduled tasks)", "jobs", ["every", "daily", "after", "cancel"]),
    ("Lifecycle", "lifecycle", ["start", "run", "stop"]),
    ("Low-level API", "lowlevel", ["call", "acall", "aio"]),
]


def camel(n):
    head, *rest = n.split("_")
    return head + "".join(p[:1].upper() + p[1:] for p in rest)


def first_line(doc):
    for para in (doc or "").strip().split("\n\n"):
        t = " ".join(x.strip() for x in para.splitlines()).strip()
        if t:
            m = re.match(r"(.+?\.)(\s|$)", t)
            return (m.group(1) if m else t).rstrip(":")
    return ""


def rst(text):
    """Inline RST → Markdown."""
    text = re.sub(r":(?:class|meth|func|attr):`~?([^`]+)`", lambda m: f"`{m.group(1).split('.')[-1]}`", text)
    return text.replace("``", "`")


# ----------------------------------------------------------------------------- Python


def py_doc(doc):
    """Google-style docstring → Markdown."""
    doc = inspect.cleandoc(doc or "")
    out, lines, i = [], doc.splitlines(), 0
    section = None
    while i < len(lines):
        ln = lines[i]
        s = ln.strip()
        if s in ("Args:", "Arguments:", "Parameters:", "Returns:", "Raises:", "Attributes:", "Yields:"):
            section = s[:-1]
            out.append(f"\n**{ {'Args': 'Parameters', 'Arguments': 'Parameters'}.get(section, section) }**\n")
            i += 1
            continue
        if s.endswith("::") and (s == "Example::" or s == "Examples::" or True):
            lead = s[:-2].rstrip()
            if lead and lead not in ("Example", "Examples"):
                out.append(rst(lead) + ":")
            elif lead:
                out.append(f"\n**{lead}**\n")
            i += 1
            block = []
            while i < len(lines) and (not lines[i].strip() or lines[i].startswith("    ") or lines[i].startswith("\t")):
                block.append(lines[i][4:] if lines[i].startswith("    ") else lines[i])
                i += 1
            while block and not block[-1].strip():
                block.pop()
            while block and not block[0].strip():
                block.pop(0)
            out.append("\n```python\n" + "\n".join(block) + "\n```\n")
            section = None
            continue
        if section and ln.startswith("    ") and not ln.startswith("        "):
            m = re.match(r"\s{4}([\w*]+)(?:\s*\([^)]*\))?:\s*(.*)", ln)
            if m and section in ("Parameters", "Args", "Arguments", "Raises", "Attributes"):
                out.append(f"- `{m.group(1)}`: {rst(m.group(2))}")
            else:
                out.append(rst(s) if section != "Returns" else rst(s))
            i += 1
            continue
        if section and ln.startswith("        "):
            out[-1] += " " + rst(s)
            i += 1
            continue
        if not s:
            section = None if section and (i + 1 >= len(lines) or not lines[i + 1].startswith("    ")) else section
            out.append("")
            i += 1
            continue
        section = None
        out.append(rst(re.sub(r"^\* ", "- ", s)))
        i += 1
    md = "\n".join(out)
    return re.sub(r"\n{3,}", "\n\n", md).strip()


def py_sig(fn, name):
    try:
        sig = inspect.signature(fn)
    except (TypeError, ValueError):
        return f"{name}(…)"
    parts, star = [], False
    for p in sig.parameters.values():
        if p.name == "self":
            continue
        if p.kind == p.KEYWORD_ONLY and not star:
            parts.append("*")
            star = True
        if p.kind == p.VAR_POSITIONAL:
            star = True
            parts.append("*" + p.name)
            continue
        if p.kind == p.VAR_KEYWORD:
            parts.append("**" + p.name)
            continue
        t = p.name
        if p.annotation is not p.empty:
            ann = p.annotation if isinstance(p.annotation, str) else inspect.formatannotation(p.annotation)
            t += f": {ann.strip(chr(34)).strip(chr(39))}"
        if p.default is not p.empty:
            d = repr(p.default)
            if isinstance(p.default, str):
                d = '"' + p.default.replace('"', '\\"') + '"'
            t += f" = {d}"
        parts.append(t)
    return f"{name}({', '.join(parts)})"


def gen_python():
    spec = importlib.util.spec_from_file_location("lumora_bot_ref", SDK / "python" / "lumora_bot.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["lumora_bot_ref"] = mod
    spec.loader.exec_module(mod)
    out = [
        "# Python SDK reference",
        "",
        f"`lumora_bot` {mod.__version__} · Python 3.8+ · one file, no dependencies. "
        "Generated from the docstrings in `sdk/python/lumora_bot.py` by `sdk/tools/gen_reference.py`; do not edit by hand.",
        "",
        "```python",
        "from lumora_bot import Bot, Button, LumoraError",
        "```",
        "",
    ]

    def member(cls, name, anchor_prefix, heading="####"):
        obj = inspect.getattr_static(cls, name)
        if isinstance(obj, property):
            out.append(f"{heading} `{name}` {{#{anchor_prefix}-{name.replace('_', '-')}}}\n")
            out.append("*property*\n")
            out.append(py_doc(obj.__doc__) + "\n")
            return
        fn = getattr(cls, name)
        out.append(f"{heading} `{py_sig(fn, name)}` {{#{anchor_prefix}-{name.replace('_', '-')}}}\n")
        if inspect.iscoroutinefunction(fn):
            out.append("*async*\n")
        doc = fn.__doc__ or ""
        if name == "use":
            doc = "Same as `middleware` (the name used by the JavaScript SDK)."
        out.append(py_doc(doc) + "\n")

    def public(cls):
        names = []
        for n, v in cls.__dict__.items():
            if n.startswith("_") and n != "__init__":
                continue
            if callable(v) or isinstance(v, property):
                names.append(n)
        return names

    # --- Bot
    bot = mod.Bot
    out.append("## Bot {#bot}\n")
    sig = py_sig(bot.__init__, "Bot")
    out.append("```python\n" + sig.replace("(", "(\n    ", 1).replace(", ", ",\n    ")[:-1] + ",\n)\n```\n")
    out.append(py_doc(bot.__doc__) + "\n")
    seen = set()
    for title, slug, names in BOT_GROUPS:
        present = [n for n in names if n in bot.__dict__]
        if not present:
            continue
        out.append(f"### {title} {{#bot-{slug}}}\n")
        out.append("| Method | Description |\n|---|---|")
        for n in present:
            obj = inspect.getattr_static(bot, n)
            d = first_line(obj.__doc__ if not isinstance(obj, property) else obj.__doc__) if n != "use" else "Same as `middleware`."
            out.append(f"| [`{n}`](#bot-{n.replace('_', '-')}) | {rst(d)} |")
        out.append("")
        for n in present:
            member(bot, n, "bot")
            seen.add(n)
    rest = [n for n in public(bot) if n not in seen and n != "__init__"]
    if rest:
        out.append("### Other {#bot-other}\n")
        for n in rest:
            member(bot, n, "bot")

    # --- other classes
    for cname in ["Context", "Storage", "Roles", "Button", "LumoraError", "LumoraTimeout", "RunnerStopped", "NotAllowedForBots"]:
        cls = getattr(mod, cname)
        base = ", ".join(b.__name__ for b in cls.__bases__ if b is not object)
        out.append(f"## {cname} {{#{cname.lower()}}}\n")
        if base:
            out.append(f"*class* `{cname}({base})`\n")
        out.append(py_doc(cls.__doc__) + "\n")
        for n in public(cls):
            if n == "__init__":
                if cname in ("Button", "LumoraError"):
                    out.append(f"`{py_sig(cls.__init__, cname)}`\n")
                continue
            member(cls, n, cname.lower())

    # --- helpers and constants
    out.append("## Helpers {#helpers}\n")
    for fname in ["gid_of", "conv_of", "is_group_conv", "is_blocked_command"]:
        fn = getattr(mod, fname)
        out.append(f"#### `{py_sig(fn, fname)}` {{#{fname.replace('_', '-')}}}\n")
        out.append(py_doc(fn.__doc__) + "\n")
    out.append("## Constants {#constants}\n")
    out.append("| Name | Value | Meaning |\n|---|---|---|")
    consts = [("MAX_TEXT_BYTES", "Text message size (UTF-8 bytes)"), ("MAX_BUTTON_ROWS", "Button rows"),
              ("MAX_BUTTONS_PER_ROW", "Buttons per row"), ("MAX_BUTTON_TEXT", "Button text length"),
              ("MAX_BUTTON_DATA", "Button data length"), ("MAX_PREVIEW_TEXT_BYTES", "File preview text"),
              ("MAX_PREVIEW_IMAGE_BYTES", "File preview picture"), ("MAX_CHECKLIST_ITEMS", "Checklist items"),
              ("MAX_TASK_TEXT", "Checklist item / reminder title length"), ("MAX_REMINDER_NOTE", "Reminder note length")]
    for n, what in consts:
        out.append(f"| `{n}` | {getattr(mod, n)} | {what} |")
    out.append("")
    return "\n".join(out).rstrip() + "\n"


# ----------------------------------------------------------------------------- JavaScript

JSDOC = re.compile(r"/\*\*(.*?)\*/", re.S)


def js_parse(src):
    """Yield (class or None, kind, name, signature, doc) for documented public symbols."""
    lines = src.splitlines()
    text = src
    cls = None
    items = []
    # class ranges: "export class X" … first "^}" after it
    ranges = []
    for m in re.finditer(r"^export class (\w+)[^\n]*\{\s*$", text, re.M):
        end = re.compile(r"^\}", re.M).search(text, m.end())
        ranges.append((m.start(), end.start() if end else len(text), m.group(1)))

    def class_at(pos):
        for a, b, n in ranges:
            if a <= pos <= b:
                return n
        return None
    for m in JSDOC.finditer(text):
        after = text[m.end():]
        line = after.lstrip("\n ").split("\n", 1)[0].strip()
        doc = m.group(1)
        cls = class_at(m.start())
        mm = re.match(r"export (?:async )?function (\w+)\s*\(([^)]*)\)", line)
        if mm:
            items.append((None, "function", mm.group(1), f"{mm.group(1)}({mm.group(2)})", doc))
            continue
        mm = re.match(r"export class (\w+)", line)
        if mm:
            items.append((mm.group(1), "class", mm.group(1), "", doc))
            continue
        mm = re.match(r"export const (\w+)\s*=\s*(.+?);?$", line)
        if mm:
            items.append((None, "const", mm.group(1), mm.group(2), doc))
            continue
        if not cls:
            continue
        mm = re.match(r"(static\s+)?(async\s+)?(get\s+)?([A-Za-z]\w*)\s*\(([^)]*)\)?", line)
        if mm and mm.group(4) not in ("if", "for", "while", "switch", "catch", "function", "return"):
            name = mm.group(4)
            if name == "constructor":
                items.append((cls, "constructor", name, f"new {cls}({mm.group(5)})", doc))
            elif mm.group(3):
                items.append((cls, "property", name, name, doc))
            else:
                items.append((cls, "async" if mm.group(2) else "method", name, f"{name}({mm.group(5)})", doc))
            continue
        mm = re.match(r"this\.([A-Za-z]\w*)\s*=", line)
        if mm:
            items.append((cls, "field", mm.group(1), mm.group(1), doc))
    del lines
    return items


def js_doc(raw):
    body = [re.sub(r"^\s*\* ?", "", ln) for ln in raw.strip("\n").splitlines()]
    body = [ln.rstrip() for ln in body]
    desc, params, returns, examples, throws, types = [], [], [], [], [], []
    cur = desc
    for ln in body:
        # several tags may share one line ("@param … @returns …")
        parts = re.split(r"\s(?=@(?:param|returns?|example|throws|type)\b)", " " + ln) if "@" in ln else [ln]
        for part in parts:
            p = part.strip() if part.strip().startswith("@") else part
            if p.startswith(" "):
                p = p[1:]
            m = re.match(r"@param\s+(\{(?:[^{}]|\{[^{}]*\})*\})\s+(\[?[\w.$]+(?:=[^\]]*)?\]?)\s*-?\s*(.*)", p)
            if m:
                params.append([m.group(2), m.group(1)[1:-1], m.group(3)])
                cur = params
                continue
            m = re.match(r"@returns?\s+\{([^}]*)\}\s*(.*)", p)
            if m:
                returns.append([m.group(1), m.group(2)])
                cur = returns
                continue
            m = re.match(r"@throws\s+\{([^}]*)\}\s*(.*)", p)
            if m:
                throws.append([m.group(1), m.group(2)])
                cur = throws
                continue
            m = re.match(r"@type\s+\{([^}]*)\}", p)
            if m:
                types.append(m.group(1))
                continue
            if p.startswith("@example"):
                examples.append([])
                cur = examples
                rest = p[len("@example"):].strip()
                if rest:
                    examples[-1].append(rest)
                continue
            if cur is examples:
                examples[-1].append(p)
            elif any(cur is x for x in (params, returns, throws)):
                if p.strip():
                    cur[-1][-1] += " " + p.strip()
            else:
                desc.append(p)
    out = ["\n".join(desc).strip()]
    if types:
        out.append(f"\n*Type:* `{types[0]}`")
    if params:
        out.append("\n**Parameters**\n")
        for name, typ, d in params:
            opt = name.startswith("[")
            nm = name.strip("[]").split("=")[0]
            default = name.strip("[]").split("=", 1)[1] if "=" in name else None
            extra = " (optional" + (f", default `{default}`" if default else "") + ")" if opt else ""
            out.append(f"- `{nm}` `{typ}`{extra}: {d.strip()}")
    if returns:
        typ, d = returns[0]
        out.append(f"\n**Returns** `{typ}`: {d.strip()}")
    if throws:
        out.append("\n**Throws**\n")
        for typ, d in throws:
            out.append(f"- `{typ}`: {d.strip()}")
    for ex in examples:
        while ex and not ex[-1].strip():
            ex.pop()
        out.append("\n```js\n" + "\n".join(ex) + "\n```")
    return "\n".join(out).strip()


def gen_js():
    src = (SDK / "js" / "lumora-bot.mjs").read_text(encoding="utf-8")
    version = re.search(r'export const VERSION = "([^"]+)"', src).group(1)
    items = js_parse(src)
    out = [
        "# JavaScript SDK reference",
        "",
        f"`lumora-bot` {version} · Node.js 18+ · ES module, no dependencies, TypeScript types in `lumora-bot.d.ts`. "
        "Generated from the JSDoc in `sdk/js/lumora-bot.mjs` by `sdk/tools/gen_reference.py`; do not edit by hand. "
        "Every method that talks to Lumora returns a `Promise`.",
        "",
        "```js",
        'import { Bot, Button, LumoraError } from "lumora-bot";',
        "```",
        "",
    ]
    by_class = {}
    for cls, kind, name, sig, doc in items:
        by_class.setdefault(cls, []).append((kind, name, sig, doc))

    def anchor(c, n):
        return f"{c.lower()}-{re.sub(r'([A-Z])', lambda m: '-' + m.group(1).lower(), n)}"

    def doc_sig(name, sig, doc):
        ps = re.findall(r"@param\s+\{(?:[^{}]|\{[^{}]*\})*\}\s+(\[?[\w$]+)", doc)
        if not ps:
            return re.sub(r"\{[^)]*\}\s*=\s*\{\}", "options?", sig)
        args = ", ".join(p.lstrip("[") + ("?" if p.startswith("[") else "") for p in ps)
        return f"{sig.split('(')[0]}({args})"

    def emit(c, kind, name, sig, doc):
        if kind not in ("property", "field"):
            sig = doc_sig(name, sig, doc)
        tag = {"async": "*async*", "property": "*property*", "field": "*property*"}.get(kind)
        head = f"`{sig}`" if kind not in ("property", "field") else f"`{name}`"
        out.append(f"#### {head} {{#{anchor(c, name)}}}\n")
        if tag:
            out.append(tag + "\n")
        out.append(js_doc(doc) + "\n")

    order = ["Bot", "Context", "Storage", "Roles", "LumoraError", "LumoraTimeout", "RunnerStopped", "NotAllowedForBots"]
    for c in order:
        members = by_class.get(c, [])
        cdoc = next((d for k, n, s, d in members if k == "class"), "")
        ctor = next(((s, d) for k, n, s, d in members if k == "constructor"), None)
        out.append(f"## {c} {{#{c.lower()}}}\n")
        if ctor:
            out.append(f"`{doc_sig(c, ctor[0], ctor[1])}`\n")
        out.append(js_doc(cdoc) + "\n")
        rest = [(k, n, s, d) for k, n, s, d in members if k not in ("class", "constructor") and not n.startswith("_")]
        if c == "Bot":
            seen = set()
            names = {n: (k, n, s, d) for k, n, s, d in rest}
            for title, slug, pnames in BOT_GROUPS:
                present = [camel(p) for p in pnames if camel(p) in names]
                if not present:
                    continue
                out.append(f"### {title} {{#bot-{slug}}}\n")
                out.append("| Method | Description |\n|---|---|")
                for n in present:
                    out.append(f"| [`{n}`](#{anchor('bot', n)}) | {first_line(js_doc(names[n][3]))} |")
                out.append("")
                for n in present:
                    emit("Bot", *names[n])
                    seen.add(n)
            others = [x for x in rest if x[1] not in seen]
            if others:
                out.append("### Properties and other members {#bot-other}\n")
                for x in others:
                    emit("Bot", *x)
        else:
            for x in rest:
                emit(c, *x)
    out.append("## Helpers {#helpers}\n")
    for kind, name, sig, doc in by_class.get(None, []):
        if kind == "function":
            out.append(f"#### `{sig}` {{#{re.sub(r'([A-Z])', lambda m: '-' + m.group(1).lower(), name)}}}\n")
            out.append(js_doc(doc) + "\n")
    consts = [(n, s, d) for k, n, s, d in by_class.get(None, []) if k == "const"]
    if consts:
        out.append("## Constants {#constants}\n")
        out.append("| Name | Value | Meaning |\n|---|---|---|")
        for n, s, d in consts:
            out.append(f"| `{n}` | `{s}` | {first_line(js_doc(d))} |")
        out.append("")
    return "\n".join(out).rstrip() + "\n"


def main():
    check = "--check" in sys.argv
    targets = {OUT / "reference-python.md": gen_python(), OUT / "reference-js.md": gen_js()}
    stale = []
    for path, text in targets.items():
        if check:
            if not path.exists() or path.read_text(encoding="utf-8") != text:
                stale.append(path.name)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
            print(f"wrote {path.relative_to(ROOT)} ({len(text.splitlines())} lines)")
    if check:
        if stale:
            print("out of date: " + ", ".join(stale) + " (run python3 sdk/tools/gen_reference.py)")
            sys.exit(1)
        print("API references are up to date")


if __name__ == "__main__":
    main()
