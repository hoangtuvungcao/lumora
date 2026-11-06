"""Lumora Bot SDK for Python: build bots for the Lumora messenger.

A bot is a normal Lumora account run by your code through **Lumora Bot Runner**
(``lumorad``). Users find it by its 9-digit ID or ``@name·tag`` and chat with it like
with any friend; messages are end-to-end encrypted and there is no central API.

Quick start::

    from lumora_bot import Bot

    bot = Bot()                                 # token from LUMORA_BOT_TOKEN (BotFather)

    @bot.command("start", "Start")
    def start(ctx):
        ctx.reply("Hi! Pick one:", buttons=[[("👍 Like", "like"), ("Website", "https://example.com")]])

    @bot.on_callback(data="like")
    def liked(ctx):
        ctx.reply("Thanks!")

    @bot.on_text(r"(?i)hello|hi")
    def hello(ctx):
        ctx.reply(f"Hello {ctx.sender_name}!")

    bot.run()

Everything is synchronous and thread-based: handlers run on a small pool, one at a time
per conversation, so a slow handler never blocks the network or other chats. ``async def``
handlers work too (they run on a private event loop) and ``bot.aio`` turns every method
into an awaitable.

Requirements: Python 3.8+ and the ``lumorad`` binary (``LUMORAD=/path/to/lumorad`` or
``Bot(binary=...)``). Resource use: about 30 MB RAM per bot, close to 0 % CPU when idle.

License: MIT.
"""
from __future__ import annotations

import asyncio
import base64
import collections
import datetime as _dt
import functools
import heapq
import inspect
import itertools
import json
import logging
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Callable, Dict, Iterable, List, Optional, Pattern, Sequence, Tuple, Union

__version__ = "1.1.0"
__all__ = [
    "Bot", "Context", "Storage", "Roles", "LumoraError", "LumoraTimeout", "RunnerStopped",
    "NotAllowedForBots", "Button", "gid_of", "conv_of", "is_group_conv", "__version__",
]

log = logging.getLogger("lumora_bot")

# ----------------------------------------------------------------------------- types

ButtonSpec = Union[Tuple[str, str], Dict[str, str], "Button"]
"""One button: ``("Text", "callback-data")``, ``("Text", "https://link")``, a dict
``{"text", "data"?, "url"?}`` or a :class:`Button`."""
Buttons = Union[Sequence[Sequence[ButtonSpec]], Sequence[ButtonSpec], None]
"""Rows of buttons (max 8×8). A single flat row is accepted too."""
When = Union[_dt.datetime, _dt.timedelta, int, float]
"""A point in time: ``datetime`` (naive = local time), ``timedelta`` from now, or epoch
milliseconds (``int``/``float``)."""
Handler = Callable[["Context"], Any]

#: Text message size limit enforced by Lumora (UTF-8 bytes).
MAX_TEXT_BYTES = 64 * 1024
#: Button limits enforced by Lumora.
MAX_BUTTON_ROWS = 8
MAX_BUTTONS_PER_ROW = 8
MAX_BUTTON_TEXT = 64
MAX_BUTTON_DATA = 64
#: File preview caps (receivers drop anything bigger).
MAX_PREVIEW_TEXT_BYTES = 4 * 1024
MAX_PREVIEW_IMAGE_BYTES = 64 * 1024
#: Checklist / reminder limits.
MAX_CHECKLIST_ITEMS = 100
MAX_TASK_TEXT = 200
MAX_REMINDER_NOTE = 1000

# Commands a bot must never run. Remote control, recovery phrase, backups and passwords
# belong to people, not bots; calls need a human on the other end.
_BLOCKED = frozenset({
    "recovery_phrase", "export_backup", "change_passphrase", "ui_secret_get", "ui_secret_set",
    "push_register", "push_unregister", "push_status", "call_start", "call_answer", "voice_join",
    "bot_create", "bot_token", "bot_revoke", "bot_delete",
})
_BLOCKED_PREFIXES = ("remote_",)


def is_blocked_command(cmd: str) -> bool:
    """True when ``cmd`` is a core command bots may not use (remote control, recovery
    phrase, backups, passwords, calls, BotFather management)."""
    return cmd in _BLOCKED or cmd.startswith(_BLOCKED_PREFIXES)


# ----------------------------------------------------------------------------- errors


class LumoraError(RuntimeError):
    """Error returned by Lumora (or raised by the SDK).

    Attributes:
        code: Stable machine key, e.g. ``"err.slow_mode"``, ``"err.admin_only"``,
            ``"internal"``, or ``"sdk.*"`` for errors raised by the SDK itself.
        message: Plain sentence in the bot's language (``Bot(lang=...)``), safe to show.
        detail: Technical cause (may be ``None``). Log it, don't show it to users.
        cmd: The command that failed (``"send_message"``…), when known.
    """

    def __init__(self, message: str, code: Optional[str] = None, detail: Optional[str] = None, cmd: Optional[str] = None):
        self.message = message or "error"
        self.code = code or "internal"
        self.detail = detail
        self.cmd = cmd
        super().__init__(self.message + (f" ({detail})" if detail else ""))

    def to_dict(self) -> Dict[str, Any]:
        """``{"error", "code", "detail", "cmd"}`` for structured logs."""
        return {"error": self.message, "code": self.code, "detail": self.detail, "cmd": self.cmd}


class LumoraTimeout(LumoraError, TimeoutError):
    """A request got no answer in time (code ``sdk.timeout``)."""


class RunnerStopped(LumoraError):
    """Lumora Bot Runner is not running, or stopped while a request was pending
    (code ``sdk.runner_stopped``)."""


class NotAllowedForBots(LumoraError):
    """The command is not available to bots (code ``sdk.not_for_bots``)."""


# ----------------------------------------------------------------------------- helpers


def gid_of(conv_or_gid: str) -> str:
    """Group id (32 hex chars) from a group conversation id (``g:<gid>`` or
    ``g:<gid>#channel``) or a bare gid. Raises ``ValueError`` for direct chats."""
    s = conv_or_gid.strip()
    if s.startswith("g:"):
        s = s[2:].split("#", 1)[0]
    if not re.fullmatch(r"[0-9a-f]{32}", s):
        raise ValueError(f"not a group: {conv_or_gid!r}")
    return s


def conv_of(peer_or_gid: str) -> str:
    """Conversation id for a user (``d:<peer>``) or a group gid (``g:<gid>``).
    Conversation ids are returned unchanged."""
    s = peer_or_gid.strip()
    if s[:2] in ("d:", "g:", "s:"):
        return s
    return ("g:" if re.fullmatch(r"[0-9a-f]{32}", s) else "d:") + s


def is_group_conv(conv: str) -> bool:
    """True for group / community channel conversations (``g:…``)."""
    return conv.startswith("g:")


def _ms(when: When) -> int:
    if isinstance(when, _dt.timedelta):
        return int((time.time() + when.total_seconds()) * 1000)
    if isinstance(when, _dt.datetime):
        return int(when.timestamp() * 1000)
    return int(when)


def _clip_utf8(text: str, limit: int) -> str:
    b = text.encode("utf-8")
    if len(b) <= limit:
        return text
    return b[:limit].decode("utf-8", "ignore")


class Button(dict):
    """An inline button. ``Button("Buy", data="buy:42")`` or ``Button("Site", url="https://…")``.

    ``text`` and ``data`` are at most 64 characters. Pressing a data button sends a
    ``callback`` to the bot (``@bot.on_callback``); a URL button opens the link.
    """

    def __init__(self, text: str, data: str = "", url: str = ""):
        super().__init__(text=str(text), data=str(data), url=str(url))


def _buttons(rows: Buttons) -> List[List[Dict[str, str]]]:
    lst: List[Any] = list(rows or [])
    if lst and isinstance(lst[0], (tuple, dict)):  # one flat row
        lst = [lst]
    out = []
    for row in lst:
        r = []
        for b in row:
            if isinstance(b, dict):
                r.append({"text": str(b.get("text", "")), "data": str(b.get("data", "") or ""), "url": str(b.get("url", "") or "")})
            else:
                text, data = b
                if str(data).startswith(("http://", "https://")):
                    r.append({"text": str(text), "data": "", "url": str(data)})
                else:
                    r.append({"text": str(text), "data": str(data), "url": ""})
        out.append(r)
    if len(out) > MAX_BUTTON_ROWS or any(len(r) > MAX_BUTTONS_PER_ROW for r in out):
        raise LumoraError("Too many buttons (max 8 rows × 8).", "sdk.bad_buttons")
    for b in itertools.chain.from_iterable(out):
        if len(b["text"]) > MAX_BUTTON_TEXT or len(b["data"]) > MAX_BUTTON_DATA:
            raise LumoraError("Button text and data must be at most 64 characters.", "sdk.bad_buttons", b["text"][:20])
    return out


# ----------------------------------------------------------------------------- storage


class Storage(dict):
    """A ``dict`` saved as JSON in the bot's data folder (``bot-storage.json``).

    Setting or deleting a top-level key saves the file atomically. If you change a nested
    value in place (``bot.storage["list"].append(x)``) call :meth:`save` afterwards, or use
    :meth:`update_key`. Values must be JSON-serialisable. Thread-safe.
    """

    def __init__(self, path: str):
        super().__init__()
        self._path = path
        self._lock = threading.RLock()
        try:
            with open(path, encoding="utf-8") as f:
                super().update(json.load(f))
        except (OSError, ValueError):
            pass

    def save(self) -> None:
        """Write the whole store to disk now (atomic replace)."""
        with self._lock:
            tmp = self._path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(dict(self), f, ensure_ascii=False)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, self._path)

    def __setitem__(self, k, v):
        with self._lock:
            super().__setitem__(k, v)
            self.save()

    def __delitem__(self, k):
        with self._lock:
            super().__delitem__(k)
            self.save()

    def setdefault(self, k, default=None):
        with self._lock:
            if k not in self:
                super().__setitem__(k, default)
                self.save()
            return super().__getitem__(k)

    def update(self, *a, **kw):  # type: ignore[override]
        with self._lock:
            super().update(*a, **kw)
            self.save()

    def pop(self, k, *default):  # type: ignore[override]
        with self._lock:
            had = k in self
            v = super().pop(k, *default)
            if had:
                self.save()
            return v

    def update_key(self, key: str, fn: Callable[[Any], Any], default: Any = None) -> Any:
        """Atomically replace ``storage[key]`` with ``fn(old)`` and save. Returns the new value.

        Example: ``bot.storage.update_key("visits", lambda n: n + 1, 0)``
        """
        with self._lock:
            new = fn(self.get(key, default))
            super().__setitem__(key, new)
            self.save()
            return new


class Roles:
    """Bot-level roles (``"mod"``, ``"vip"``…) kept in storage: user → set of roles.

    These are *your bot's* roles, separate from group admins. Bot admins
    (``Bot(admins=[...])``) pass every role check.
    """

    def __init__(self, storage: Storage):
        self._s = storage
        self._s.setdefault("__roles__", {})

    def grant(self, peer: str, role: str) -> None:
        """Give ``role`` to user ``peer``."""
        def f(r):
            r = dict(r or {})
            r.setdefault(peer, [])
            if role not in r[peer]:
                r[peer] = r[peer] + [role]
            return r
        self._s.update_key("__roles__", f, {})

    def revoke(self, peer: str, role: str) -> None:
        """Take ``role`` away from user ``peer``."""
        def f(r):
            r = dict(r or {})
            r[peer] = [x for x in r.get(peer, []) if x != role]
            if not r[peer]:
                r.pop(peer)
            return r
        self._s.update_key("__roles__", f, {})

    def of(self, peer: str) -> set:
        """Roles of ``peer`` (a set, empty when none)."""
        return set(self._s.get("__roles__", {}).get(peer, []))

    def members(self, role: str) -> List[str]:
        """Users that have ``role``."""
        return [p for p, rs in self._s.get("__roles__", {}).items() if role in rs]


# ----------------------------------------------------------------------------- context


class Context:
    """What a handler receives: the event plus shortcuts to answer it.

    Common attributes (empty / ``None`` when not relevant to the event):

    * ``kind``: ``"command"``, ``"message"``, ``"callback"``, ``"new_user"``,
      ``"new_member"``, ``"member_left"``, ``"added_to_group"``, ``"file"``,
      ``"reminder_due"``, ``"checklist"``, ``"job"`` or the raw event name.
    * ``conv``: conversation id (``d:<peer>`` direct chat, ``g:<gid>`` group).
    * ``sender``: the user who caused the event; ``sender_name``: their display name.
    * ``text``, ``command``, ``args``, ``match`` (regex match of ``on_text``).
    * ``data``: button data (callbacks). ``msg_id``: message id.
    * ``msg_kind`` and ``body``: message kind (``"text"``, ``"file"``, ``"location"``…) and body.
    * ``is_group``, ``gid``: group chat and its id.
    * ``file``: file info (``on_file``); ``reminder``; ``checklist`` and ``changes``;
      ``member`` (``on_new_member``).
    * ``event``: the raw event dict.
    """

    def __init__(self, bot: "Bot", event: dict, kind: str = ""):
        self.bot = bot
        self.event = event
        self.kind = kind or event.get("event", "")
        # callbacks: answer where the button is (a group member may never have opened a
        # direct chat with the bot, and bots can't start one)
        self.conv: str = (event.get("msg_conv") if event.get("event") == "callback" else None) or event.get("conv") or event.get("msg_conv") or ""
        self.sender: str = event.get("author") or event.get("from") or ""
        body = event.get("body")
        self.body: Dict[str, Any] = body if isinstance(body, dict) else {}
        self.msg_kind: str = event.get("kind", "") if "body" in event else ""
        self.text: str = self.body.get("text", "") if isinstance(self.body.get("text", ""), str) else ""
        self.data: str = event.get("data", "")
        self.msg_id: str = event.get("msg_id") or event.get("id") or ""
        self.reply_to: Optional[str] = event.get("reply_to")
        self.silent: bool = bool(event.get("silent"))
        self.match: Optional[re.Match] = None
        self.file: Optional[Dict[str, Any]] = None
        self.reminder: Optional[Dict[str, Any]] = None
        self.checklist: Optional[Dict[str, Any]] = None
        self.changes: List[Dict[str, Any]] = []
        self.member: Optional[Dict[str, Any]] = None
        self.command: Optional[str] = None
        self.args: str = ""
        parts = self.text.strip().split(maxsplit=1)
        if parts and parts[0].startswith("/") and len(parts[0]) > 1:
            self.command = parts[0][1:].split("@")[0]
            self._command_target = parts[0][1:].split("@", 1)[1].lower() if "@" in parts[0] else ""
            self.args = parts[1] if len(parts) > 1 else ""
        else:
            self._command_target = ""
        self.handled = False

    # -- who / where
    @property
    def is_group(self) -> bool:
        """True when the event happened in a group or community channel."""
        return is_group_conv(self.conv)

    @property
    def gid(self) -> Optional[str]:
        """Group id for group events, else ``None``."""
        return gid_of(self.conv) if self.is_group else None

    @property
    def sender_name(self) -> str:
        """Display name of :attr:`sender` (falls back to the 9-digit ID)."""
        return self.bot.name_of(self.sender) if self.sender else ""

    @property
    def is_admin(self) -> bool:
        """True when the sender is one of this bot's admins (``Bot(admins=[...])``)."""
        return self.sender in self.bot.admin_peers

    def has_role(self, role: str) -> bool:
        """True when the sender has bot role ``role`` (bot admins always do)."""
        return self.is_admin or role in self.bot.roles.of(self.sender)

    @property
    def is_group_admin(self) -> bool:
        """True when the sender is an admin or the owner of the current group."""
        if not self.is_group or not self.sender:
            return False
        return self.bot.member_role(self.conv, self.sender) in ("admin", "owner")

    @property
    def aio(self) -> "_Aio":
        """Awaitable versions of this context's methods: ``await ctx.aio.reply("hi")``."""
        return _Aio(self)

    # -- answering
    def reply(self, text: str, buttons: Buttons = None, reply: bool = False, *, silent: bool = False,
              mentions: Optional[Sequence[str]] = None, mention_all: bool = False) -> dict:
        """Send ``text`` to the same conversation.

        Args:
            text: Message text (max 64 KB).
            buttons: Inline buttons, see :class:`Button`.
            reply: Quote the message being answered.
            silent: Deliver without sound or notification.
            mentions: Users (peer ids) to mention.
            mention_all: Mention everyone in a group.

        Returns:
            The sent message.
        """
        return self.bot.send(self.conv, text, buttons=buttons, reply_to=self.msg_id if reply and self.msg_id else None,
                             silent=silent, mentions=mentions, mention_all=mention_all)

    def reply_file(self, path: str, preview: Union[str, Dict[str, Any], None] = None, *, thumb: Optional[str] = None) -> dict:
        """Send a file to the same conversation (see :meth:`Bot.send_file`)."""
        return self.bot.send_file(self.conv, path, preview=preview, thumb=thumb)

    def send_file(self, path: str) -> dict:
        """Send a file to the same conversation (kept for older bots; prefer :meth:`reply_file`)."""
        return self.reply_file(path)

    def reply_checklist(self, title: str, items: Sequence[str], *, silent: bool = False) -> dict:
        """Send a checklist to the same conversation."""
        return self.bot.send_checklist(self.conv, title, items, silent=silent)

    def reply_reminder(self, title: str, at: When, note: str = "", *, silent: bool = False) -> dict:
        """Send a reminder to the same conversation."""
        return self.bot.send_reminder(self.conv, title, at, note=note, silent=silent)

    def reply_poll(self, question: str, options: Sequence[str]) -> dict:
        """Send a poll to the same conversation."""
        return self.bot.send_poll(self.conv, question, options)

    def react(self, emoji: str, on: bool = True) -> None:
        """React to the current message with ``emoji`` (``on=False`` removes it)."""
        self.bot.react(self.conv, self.msg_id, emoji, on)

    def edit(self, text: str) -> None:
        """Edit the current message. For callbacks that is the bot's message whose button
        was pressed, so ``ctx.edit("Done ✅")`` updates it in place."""
        self.bot.edit_message(self.event.get("msg_conv") or self.conv, self.msg_id, text)

    def delete(self, for_everyone: bool = True) -> None:
        """Delete the current message (others' messages in groups need admin rights)."""
        self.bot.delete_message(self.event.get("msg_conv") or self.conv, self.msg_id, for_everyone=for_everyone)

    def pin(self, on: bool = True) -> None:
        """Pin (or unpin) the current message."""
        self.bot.pin_message(self.event.get("msg_conv") or self.conv, self.msg_id, on)

    def typing(self, on: bool = True) -> None:
        """Show (or hide) "typing…" in this conversation."""
        self.bot.typing(self.conv, on)

    def download(self, dir: Optional[str] = None, timeout: float = 300) -> str:
        """Download the file of this message (``on_file``) and return its local path."""
        if not self.file:
            raise LumoraError("This message has no file.", "sdk.no_file")
        return self.bot.download_file(self.file["file_id"], dir=dir, timeout=timeout)

    def __repr__(self) -> str:
        return f"<Context {self.kind} conv={self.conv[:14]}… sender={self.sender[:8]}…>"


class _Aio:
    """Wraps an object so that every method call returns an awaitable (runs in a thread)."""

    def __init__(self, target):
        self._t = target

    def __getattr__(self, name):
        fn = getattr(self._t, name)
        if not callable(fn):
            return fn

        async def call(*a, **kw):
            loop = asyncio.get_running_loop()
            return await loop.run_in_executor(None, functools.partial(fn, *a, **kw))
        return call


# ----------------------------------------------------------------------------- runtime pieces


class _Pacer:
    """Send pacing (GCRA): ≤ ``rate`` messages/s overall, and per chat a burst of
    ``chat_burst`` then ``chat_rate``/s. Reservations are taken in call order, so
    concurrent senders queue fairly instead of racing."""

    def __init__(self, rate: float, chat_rate: float = 1.0, chat_burst: int = 5):
        self.set_rate(rate)
        self._cT = 1.0 / chat_rate
        self._ctau = (max(1, chat_burst) - 1) * self._cT
        self._tat: Dict[str, float] = {}
        self._lock = threading.Lock()

    def set_rate(self, rate: float) -> None:
        rate = max(0.1, float(rate))
        self._gT = 1.0 / rate
        self._gtau = (max(1.0, rate) - 1) * self._gT

    def reserve(self, key: str) -> float:
        """Reserve the next slot for ``key``; returns how long to wait (seconds)."""
        with self._lock:
            now = time.monotonic()
            g = max(self._tat.get("*", now), now)
            c = max(self._tat.get(key, now), now)
            t = max(now, g - self._gtau, c - self._ctau)
            self._tat["*"] = max(g, t) + self._gT
            self._tat[key] = max(c, t) + self._cT
            if len(self._tat) > 5000:
                self._tat = {k: v for k, v in self._tat.items() if v > now}
            return t - now

    def wait(self, key: str) -> None:
        d = self.reserve(key)
        if d > 0:
            time.sleep(d)


class _KeyedRunner:
    """Thread pool that runs jobs with the same key one after another (in order) and jobs
    with different keys in parallel. Used so each conversation's events stay ordered."""

    def __init__(self, workers: int):
        self._pool = ThreadPoolExecutor(max_workers=max(1, workers), thread_name_prefix="lumora-bot")
        self._lock = threading.Lock()
        self._idle = threading.Condition(self._lock)
        self._queues: Dict[Any, collections.deque] = {}
        self._inflight = 0
        self._closed = False

    def submit(self, key: Any, fn: Callable, *a) -> bool:
        with self._lock:
            if self._closed:
                return False
            self._inflight += 1
            if key is None:
                key = object()
            q = self._queues.get(key)
            if q is not None:
                q.append((fn, a))
                return True
            self._queues[key] = collections.deque([(fn, a)])
        self._pool.submit(self._drain, key)
        return True

    def _drain(self, key):
        while True:
            with self._lock:
                q = self._queues[key]
                if not q:
                    del self._queues[key]
                    return
                fn, a = q.popleft()
            try:
                fn(*a)
            except Exception:  # pragma: no cover - _dispatch already catches
                log.exception("unexpected error in worker")
            finally:
                with self._lock:
                    self._inflight -= 1
                    self._idle.notify_all()

    def close(self, timeout: float) -> bool:
        """Stop accepting work and wait up to ``timeout`` s for running handlers."""
        with self._lock:
            self._closed = True
            done = self._idle.wait_for(lambda: self._inflight == 0, timeout)
        self._pool.shutdown(wait=False)
        return done


class _Jobs:
    """Tiny scheduler thread for ``every`` / ``daily`` / ``after`` jobs."""

    def __init__(self, bot: "Bot"):
        self._bot = bot
        self._heap: List[Tuple[float, int, dict]] = []
        self._cv = threading.Condition()
        self._seq = itertools.count()
        self._stop = False
        self._thread: Optional[threading.Thread] = None

    def add(self, job: dict) -> dict:
        with self._cv:
            heapq.heappush(self._heap, (job["next"], next(self._seq), job))
            self._cv.notify()
        return job

    def start(self):
        if not self._thread:
            self._thread = threading.Thread(target=self._loop, name="lumora-bot-jobs", daemon=True)
            self._thread.start()

    def stop(self):
        with self._cv:
            self._stop = True
            self._cv.notify()

    def _loop(self):
        while True:
            with self._cv:
                while not self._stop and (not self._heap or self._heap[0][0] > time.time()):
                    self._cv.wait(None if not self._heap else max(0.0, self._heap[0][0] - time.time()))
                if self._stop:
                    return
                _, _, job = heapq.heappop(self._heap)
            if job.get("cancelled"):
                continue
            self._bot._runner.submit(("job", job["name"]), self._bot._run_job, job)
            nxt = job["reschedule"]()
            if nxt is not None:
                job["next"] = nxt
                self.add(job)


class _JsonFormatter(logging.Formatter):
    def format(self, r: logging.LogRecord) -> str:
        d = {"ts": round(r.created, 3), "level": r.levelname.lower(), "logger": r.name, "msg": r.getMessage()}
        for k, v in r.__dict__.items():
            if k.startswith("lb_"):
                d[k[3:]] = v
        if r.exc_info:
            d["exc"] = self.formatException(r.exc_info)
        return json.dumps(d, ensure_ascii=False, default=str)


def _setup_logging(json_logs: Optional[bool], level: Optional[str]) -> None:
    if log.handlers:
        return
    env_fmt = os.environ.get("LUMORA_BOT_LOG_FORMAT", "").lower()
    use_json = json_logs if json_logs is not None else env_fmt == "json"
    h = logging.StreamHandler(sys.stderr)
    h.setFormatter(_JsonFormatter() if use_json else logging.Formatter("%(asctime)s [lumora-bot] %(levelname)s %(message)s"))
    log.addHandler(h)
    log.propagate = False
    log.setLevel((level or os.environ.get("LUMORA_BOT_LOG_LEVEL") or "INFO").upper())


def _x(**kw) -> Dict[str, Any]:
    """Structured log fields (``extra=``)."""
    return {"lb_" + k: v for k, v in kw.items()}


# ----------------------------------------------------------------------------- handler registry


class _Route:
    __slots__ = ("fn", "pattern", "data", "kinds", "chats", "exts", "specific")

    def __init__(self, fn, pattern=None, data=None, kinds=None, chats="all", exts=None):
        self.fn = fn
        self.pattern: Optional[Pattern] = re.compile(pattern) if isinstance(pattern, str) else pattern
        self.data = data
        self.kinds = tuple(kinds) if kinds else None
        self.chats = chats
        self.exts = tuple(e.lower().lstrip(".") for e in exts) if exts else None
        self.specific = self.pattern is not None or data is not None or self.exts is not None


def _chat_ok(chats: str, ctx: Context) -> bool:
    return chats == "all" or (chats == "group") == ctx.is_group


def _deco(register: Callable[..., None], fn: Optional[Callable], **kw):
    """Support both ``@bot.on_x`` and ``@bot.on_x(...)``."""
    if fn is not None and callable(fn):
        register(fn, **kw)
        return fn

    def wrap(f):
        register(f, **kw)
        return f
    return wrap


# ----------------------------------------------------------------------------- bot


class Bot:
    """A Lumora bot.

    Args:
        name: Display name for a bot made without BotFather (testing). Not needed with a token.
        data_dir: Folder for the bot's identity, messages, storage and downloads. Keep it
            private and back it up; one folder per bot.
        binary: Path to ``lumorad`` (default: ``$LUMORAD``, then ``lumorad`` on ``PATH``).
        token: BotFather token (default: ``$LUMORA_BOT_TOKEN``). Never hard-code it in
            public code.
        about: Short description shown on the bot's profile.
        lan: Also find users on the local network.
        public_directory: Let people find the bot by ID / ``@name`` (turn off for tests).
        workers: Handler threads (events of one conversation always run in order).
        extra_args: Extra ``lumorad`` arguments.
        admins: Bot admins: peer ids or ``@name·tag`` handles. They may use
            ``admin_only`` commands and pass every role check.
        rate_per_sec: Overall send rate (default 15/s; per chat: burst 5, then 1/s).
        downloads_dir: Where received files are saved (default ``<data_dir>/downloads``).
        auto_restart: Restart Lumora Bot Runner if it exits unexpectedly.
        allow_groups: Accept being added to groups.
        lang: ``"vi"`` or ``"en"``: language of error messages and system texts.
        log_json: Log as JSON lines (default: ``$LUMORA_BOT_LOG_FORMAT == "json"``).
        log_level: ``"DEBUG"``, ``"INFO"``… (default ``$LUMORA_BOT_LOG_LEVEL`` or INFO).
        runner_log: File for Lumora Bot Runner's own log (default ``<data_dir>/runner.log``;
            ``""`` to discard).
        help_command: Answer ``/help`` with the command list when you don't define one.
        deny_text: Reply sent when someone uses a command they are not allowed to.
    """

    def __init__(self, name: str = "", data_dir: str = "./lumora-bot", binary: Optional[str] = None,
                 token: Optional[str] = None,
                 about: str = "", lan: bool = True, public_directory: bool = True, workers: int = 4,
                 extra_args: Optional[List[str]] = None, admins: Optional[List[str]] = None,
                 rate_per_sec: float = 15.0, *, downloads_dir: Optional[str] = None, auto_restart: bool = True,
                 allow_groups: bool = True, lang: Optional[str] = None, log_json: Optional[bool] = None,
                 log_level: Optional[str] = None, runner_log: Optional[str] = None, help_command: bool = True,
                 deny_text: str = "⛔ Bạn không có quyền dùng lệnh này. / You are not allowed to use this command."):
        _setup_logging(log_json, log_level)
        #: The SDK's logger (``logging.getLogger("lumora_bot")``); use it in handlers too.
        self.log = log
        # token from the in-app BotFather (recommended): name/@username come from it
        self.token = token or os.environ.get("LUMORA_BOT_TOKEN")
        if not name and not self.token:
            raise ValueError("give the bot a name, or a token created in the app (BotFather)")
        self.name = name
        self.data_dir = data_dir
        self.binary = binary or os.environ.get("LUMORAD") or shutil.which("lumorad") or "lumorad"
        self.about = about
        self.extra = list(extra_args or [])
        if not lan:
            self.extra.append("--no-lan")
        if not public_directory:
            self.extra.append("--no-directory")
        self.downloads_dir = downloads_dir or os.path.join(data_dir, "downloads")
        self.auto_restart = auto_restart
        self.allow_groups = allow_groups
        self.lang = lang
        self.help_command = help_command
        self.deny_text = deny_text
        self.runner_log = os.path.join(data_dir, "runner.log") if runner_log is None else runner_log
        self._commands: Dict[str, Tuple[Callable, str, bool, str]] = {}
        self._admin_specs = list(admins or [])
        self.admin_peers: set = set()
        os.makedirs(data_dir, exist_ok=True)
        self.storage = Storage(os.path.join(data_dir, "bot-storage.json"))
        self.roles = Roles(self.storage)
        self._rate = rate_per_sec
        self._pacer = _Pacer(rate_per_sec)
        self._routes: Dict[str, List[_Route]] = collections.defaultdict(list)
        self._raw: Dict[str, List[Callable]] = collections.defaultdict(list)
        self._middleware: List[Callable] = []
        self._error_handlers: List[Callable] = []
        self._start_hooks: List[Callable] = []
        self._runner = _KeyedRunner(workers)
        self._jobs = _Jobs(self)
        self._lock = threading.Lock()
        self._wlock = threading.Lock()
        self._cv = threading.Condition()
        self._resp: Dict[int, dict] = {}
        self._pending: set = set()
        self._next = 1
        self._proc: Optional[subprocess.Popen] = None
        self._gen = 0
        self._ready = threading.Event()
        self._stopping = threading.Event()
        self._stopped = threading.Event()
        self._restarts: List[float] = []
        self._started = False
        self._loop: Optional[asyncio.AbstractEventLoop] = None
        self._groups: Dict[str, Dict[str, Dict[str, Any]]] = {}
        self._names: Dict[str, str] = {}
        self._checklists: "collections.OrderedDict[str, dict]" = collections.OrderedDict()
        self._file_waiters: Dict[str, threading.Event] = {}
        self.me: dict = {}

    # ================================================================== handlers (decorators)
    def command(self, name: str, description: str = "", admin_only: bool = False, role: Optional[str] = None,
                *, chats: str = "all", hidden: bool = False):
        """Register ``/name``.

        Args:
            name: Command name without ``/`` (``/name@yourbot`` works too in groups).
            description: Shown in the app's command menu and ``/help``.
            admin_only: Only bot admins may use it (hidden from the menu).
            role: Only users with this bot role (or admins) may use it (hidden from the menu).
            chats: ``"all"``, ``"private"`` (direct chats only) or ``"group"``.
            hidden: Keep it out of the command menu.

        Example::

            @bot.command("ban", "Ban a user", admin_only=True, chats="group")
            def ban(ctx): ...
        """
        def deco(fn):
            def guarded(ctx):
                if (admin_only and not ctx.is_admin) or (role and not ctx.has_role(role)):
                    return ctx.reply(self.deny_text)
                return self._call_handler(fn, ctx)
            self._commands[name.lstrip("/")] = (guarded, description, admin_only or bool(role) or hidden, chats)
            return fn
        return deco

    def on_message(self, fn: Optional[Handler] = None, *, pattern: Union[str, Pattern, None] = None,
                   kinds: Optional[Sequence[str]] = ("text",), chats: str = "all"):
        """Handle incoming messages that are not commands.

        Usable bare (``@bot.on_message``: every text message) or with filters.

        Args:
            pattern: Regex searched in the text; the first matching handler wins and
                catch-all handlers don't run. The match is in ``ctx.match``.
            kinds: Message kinds: ``"text"`` (default), ``"file"``, ``"voice"``,
                ``"sticker"``, ``"location"``, ``"contact"``, ``"poll"``, ``"checklist"``,
                ``"reminder"``; ``None`` = all.
            chats: ``"all"``, ``"private"`` or ``"group"``.
        """
        return _deco(lambda f, **k: self._routes["message"].append(_Route(f, **k)), fn,
                     pattern=pattern, kinds=kinds, chats=chats)

    def on_text(self, pattern: Union[str, Pattern], *, chats: str = "all"):
        """Handle text messages matching ``pattern`` (regex, searched anywhere in the text).

        Example::

            @bot.on_text(r"(?i)\\bprice\\b")
            def price(ctx): ctx.reply("From 25k")
        """
        return self.on_message(pattern=pattern, kinds=("text",), chats=chats)

    def on_callback(self, fn: Optional[Handler] = None, *, data: Optional[str] = None,
                    pattern: Union[str, Pattern, None] = None):
        """Handle inline button presses on the bot's messages.

        Args:
            data: Only buttons whose data equals this. A value ending in ``*`` matches by
                prefix (``data="buy:*"``).
            pattern: Regex matched against the data (``ctx.match``).
        """
        return _deco(lambda f, **k: self._routes["callback"].append(_Route(f, **k)), fn, data=data, pattern=pattern)

    def on_new_user(self, fn: Handler) -> Handler:
        """Called when someone starts a chat with the bot for the first time
        (``ctx.conv`` is their direct chat)."""
        self._routes["new_user"].append(_Route(fn))
        return fn

    def on_new_member(self, fn: Handler) -> Handler:
        """Called when someone joins a group the bot is in (``ctx.member`` = ``{peer, name,
        role}``, ``ctx.sender`` = the new member, ``ctx.conv`` = the group). ``name`` is the
        9-digit ID when the bot doesn't know the person yet: greet them with
        ``mentions=[ctx.sender]`` instead. Needs full access ("read all") in that group: a
        privacy-mode bot is not told about membership changes."""
        self._routes["new_member"].append(_Route(fn))
        return fn

    def on_member_left(self, fn: Handler) -> Handler:
        """Called when a member leaves or is removed from a group (full access needed)."""
        self._routes["member_left"].append(_Route(fn))
        return fn

    def on_added_to_group(self, fn: Handler) -> Handler:
        """Called when a group admin adds the bot to a group (``ctx.conv`` = the group)."""
        self._routes["added_to_group"].append(_Route(fn))
        return fn

    def on_file(self, fn: Optional[Handler] = None, *, extensions: Optional[Sequence[str]] = None, chats: str = "all"):
        """Handle received files. ``ctx.file`` has ``file_id``, ``name``, ``size``, ``mime``
        and ``preview`` (``{kind, text, pages, lines}`` or ``None``, available before
        downloading). Call ``ctx.download()`` to get the file on disk.

        Args:
            extensions: Only these file extensions, e.g. ``["txt", "csv"]``.
        """
        return _deco(lambda f, **k: self._routes["file"].append(_Route(f, **k)), fn, exts=extensions, chats=chats)

    def on_reminder_due(self, fn: Handler) -> Handler:
        """Called when a reminder in one of the bot's chats is due. ``ctx.reminder`` has
        ``title``, ``note``, ``at_ms``, ``author``, ``mine`` and ``late``."""
        self._routes["reminder_due"].append(_Route(fn))
        return fn

    def on_checklist(self, fn: Handler) -> Handler:
        """Called when someone ticks / unticks checklist items or items are added.
        ``ctx.checklist`` = ``{msg_id, conv, title, items: [{id, text, done, by, at}],
        done, total}``; ``ctx.changes`` = ``[{item, text, done, by}]``. Changes made by the
        bot itself are not reported."""
        self._routes["checklist"].append(_Route(fn))
        return fn

    def on_event(self, name: str):
        """Low-level: receive every raw event ``name`` (``"message_update"``, ``"typing"``,
        ``"*"`` for all). ``ctx.event`` is the raw dict. Runs in addition to other handlers."""
        def deco(fn):
            self._raw[name].append(fn)
            return fn
        return deco

    def middleware(self, fn: Callable[[Context, Callable[[], Any]], Any]):
        """Wrap every handled update. ``fn(ctx, next)`` must call ``next()`` to continue;
        not calling it stops the update (useful for bans, per-user limits, logging).

        Example::

            @bot.middleware
            def timing(ctx, next):
                t = time.time(); r = next(); log.info("%s took %.0f ms", ctx.kind, (time.time()-t)*1000); return r
        """
        self._middleware.append(fn)
        return fn

    use = middleware  # same name as the JavaScript SDK

    def on_error(self, fn: Callable[[Context, BaseException], Any]):
        """Called with ``(ctx, exception)`` when a handler raises. The error is logged anyway."""
        self._error_handlers.append(fn)
        return fn

    def on_start(self, fn: Callable[[], Any]):
        """Called once the bot is online (and again after an automatic restart)."""
        self._start_hooks.append(fn)
        return fn

    # ================================================================== jobs
    def every(self, seconds: float, fn: Optional[Callable[[], Any]] = None, *, first_in: Optional[float] = None):
        """Run ``fn()`` every ``seconds`` (decorator or direct call). Returns the job;
        ``bot.cancel(job)`` stops it."""
        def add(f):
            nxt = time.time() + (seconds if first_in is None else first_in)
            job = {"name": getattr(f, "__name__", "job"), "fn": f, "next": nxt}
            job["reschedule"] = lambda: job["next"] + seconds if job["next"] + seconds > time.time() else time.time() + seconds
            self._jobs.add(job)
            return job
        if fn is not None:
            return add(fn)
        return lambda f: (add(f), f)[1]

    def daily(self, at: str, fn: Optional[Callable[[], Any]] = None):
        """Run ``fn()`` every day at local time ``"HH:MM"`` (decorator or direct call)."""
        hh, mm = (int(x) for x in at.split(":"))

        def nxt_after(t: float) -> float:
            d = _dt.datetime.fromtimestamp(t)
            n = d.replace(hour=hh, minute=mm, second=0, microsecond=0)
            if n <= d:
                n += _dt.timedelta(days=1)
            return n.timestamp()

        def add(f):
            job = {"name": getattr(f, "__name__", "daily"), "fn": f, "next": nxt_after(time.time())}
            job["reschedule"] = lambda: nxt_after(job["next"] + 1)
            self._jobs.add(job)
            return job
        if fn is not None:
            return add(fn)
        return lambda f: (add(f), f)[1]

    def after(self, seconds: float, fn: Callable[[], Any]) -> dict:
        """Run ``fn()`` once, ``seconds`` from now. Returns the job."""
        job = {"name": getattr(fn, "__name__", "once"), "fn": fn, "next": time.time() + seconds, "reschedule": lambda: None}
        return self._jobs.add(job)

    def cancel(self, job: dict) -> None:
        """Cancel a job returned by :meth:`every`, :meth:`daily` or :meth:`after`."""
        job["cancelled"] = True
        job["reschedule"] = lambda: None

    def _run_job(self, job: dict) -> None:
        if job.get("cancelled") or self._stopping.is_set():
            return
        ctx = Context(self, {"event": "job"}, "job")
        self._call_handler(lambda _c: job["fn"](), ctx)

    # ================================================================== low-level API
    def call(self, cmd: str, timeout: float = 60, **args) -> Any:
        """Run any command of the Lumora JSON API and return its ``data``.

        Commands bots may not use (remote control, recovery phrase, backups, passwords,
        calls) raise :class:`NotAllowedForBots`.

        Raises:
            LumoraError: the command failed (``.code``, ``.message``, ``.detail``).
            LumoraTimeout: no answer within ``timeout`` seconds.
            RunnerStopped: Lumora Bot Runner is not running.
        """
        if is_blocked_command(cmd):
            raise NotAllowedForBots("This command is not available to bots.", "sdk.not_for_bots", cmd, cmd)
        return self._call(cmd, args, timeout)

    async def acall(self, cmd: str, timeout: float = 60, **args) -> Any:
        """Awaitable :meth:`call` (runs in a thread, safe from any event loop)."""
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(None, functools.partial(self.call, cmd, timeout, **args))

    @property
    def aio(self) -> "_Aio":
        """Awaitable versions of every method: ``await bot.aio.send(conv, "hi")``."""
        return _Aio(self)

    def _call(self, cmd: str, args: dict, timeout: float = 60, wait_ready: bool = True) -> Any:
        deadline = time.monotonic() + timeout
        if wait_ready and not self._ready.is_set():
            if self._stopped.is_set() or not self._ready.wait(timeout):
                raise RunnerStopped("Lumora Bot Runner is not running.", "sdk.runner_stopped", None, cmd)
        proc = self._proc
        if not proc or proc.poll() is not None or not proc.stdin:
            raise RunnerStopped("Lumora Bot Runner is not running.", "sdk.runner_stopped", None, cmd)
        with self._lock:
            rid = self._next
            self._next += 1
        req = dict(args)
        req.update(id=rid, cmd=cmd)
        line = json.dumps(req, ensure_ascii=False) + "\n"
        with self._cv:
            self._pending.add(rid)
        try:
            with self._wlock:
                proc.stdin.write(line)
                proc.stdin.flush()
        except (OSError, ValueError) as e:
            with self._cv:
                self._pending.discard(rid)
            raise RunnerStopped("Lumora Bot Runner is not running.", "sdk.runner_stopped", str(e), cmd)
        with self._cv:
            ok = self._cv.wait_for(lambda: rid in self._resp, max(0.0, deadline - time.monotonic()))
            self._pending.discard(rid)
            if not ok:
                raise LumoraTimeout(f"No answer from Lumora Bot Runner for '{cmd}'.", "sdk.timeout", None, cmd)
            r = self._resp.pop(rid)
        if not r.get("ok"):
            # "error" is a plain sentence; "code" is stable; "detail" has the technical cause
            cls = RunnerStopped if r.get("code") == "sdk.runner_stopped" else LumoraError
            raise cls(r.get("error") or "error", r.get("code"), r.get("detail"), cmd)
        return r.get("data")

    def _send_cmd(self, conv: str, cmd: str, args: dict, timeout: float = 60) -> Any:
        self._pacer.wait(conv)
        return self.call(cmd, timeout=timeout, **args)

    # ================================================================== messages
    def send(self, conv: str, text: str, buttons: Buttons = None, reply_to: Optional[str] = None, *,
             silent: bool = False, mentions: Optional[Sequence[str]] = None, mention_all: bool = False,
             ttl_ms: Optional[int] = None) -> dict:
        """Send a text message (paced so receivers never see the bot as spam).

        Args:
            conv: Conversation id (``d:<peer>``, ``g:<gid>``). A bare peer id is accepted.
            text: Up to 64 KB of UTF-8 text.
            buttons: Inline buttons (rows; max 8×8, text/data ≤ 64 chars).
            reply_to: Message id to quote.
            silent: No sound or notification on the receivers' devices.
            mentions: Peer ids to mention (they get a mention notification).
            mention_all: Mention everyone (groups).
            ttl_ms: Disappear this many ms after being read.

        Returns:
            The sent message (``id``, ``conv``, ``ts``…).
        """
        conv = conv_of(conv)
        args: Dict[str, Any] = {"conv": conv, "text": text, "buttons": _buttons(buttons)}
        if reply_to:
            args["reply_to"] = reply_to
        if silent:
            args["silent"] = True
        if mentions:
            args["mentions"] = list(mentions)
        if mention_all:
            args["mention_all"] = True
        if ttl_ms:
            args["ttl_ms"] = int(ttl_ms)
        return self._send_cmd(conv, "send_message", args)

    def send_file(self, conv: str, path: str, *, preview: Union[str, Dict[str, Any], None] = None,
                  thumb: Optional[str] = None) -> dict:
        """Send a file. Text/code files get an automatic preview of their first lines.

        Args:
            conv: Conversation id.
            path: Local file path (readable by Lumora Bot Runner).
            preview: Custom preview shown before download: a text snippet (``str``) or
                ``{"kind": "text"|"pdf"|…, "text", "pages", "lines"}``. Text is cut to 4 KB.
            thumb: Path to a JPEG/PNG/WebP picture ≤ 64 KB shown with the file (e.g. a
                chart or the first page of a PDF).

        Returns:
            The file transfer entry (``id``, ``name``, ``size``, ``state``…).
        """
        conv = conv_of(conv)
        args: Dict[str, Any] = {"conv": conv, "path": os.path.abspath(path)}
        if preview is not None:
            p = {"kind": "text", "text": preview} if isinstance(preview, str) else dict(preview)
            if isinstance(p.get("text"), str):
                p["text"] = _clip_utf8(p["text"], MAX_PREVIEW_TEXT_BYTES)
            args["preview"] = p
        if thumb:
            with open(thumb, "rb") as f:
                b = f.read()
            if len(b) > MAX_PREVIEW_IMAGE_BYTES:
                raise LumoraError("The preview picture must be at most 64 KB.", "sdk.preview_too_large", f"{len(b)} bytes", "send_file")
            args["thumb_b64"] = base64.b64encode(b).decode()
        return self._send_cmd(conv, "send_file", args, timeout=120)

    def send_poll(self, conv: str, question: str, options: Sequence[str]) -> dict:
        """Send a poll (2–10 options, question ≤ 300 chars). Votes arrive as
        ``message_update`` events (``reactions.__votes``)."""
        conv = conv_of(conv)
        return self._send_cmd(conv, "send_poll", {"conv": conv, "question": question, "options": list(options)})

    def send_checklist(self, conv: str, title: str, items: Sequence[str], *, silent: bool = False) -> dict:
        """Send a checklist (1–100 items, ≤ 200 chars each). Anyone in the chat can tick
        items; see :meth:`on_checklist`.

        Returns:
            The message; ``body.items`` = ``[{id, text}]`` (ids start at 1).
        """
        conv = conv_of(conv)
        m = self._send_cmd(conv, "send_checklist", {"conv": conv, "title": title, "items": list(items), "silent": silent})
        self._remember_checklist(m)
        return m

    def checklist_toggle(self, conv: str, msg_id: str, item: int, done: bool = True) -> None:
        """Tick (``done=True``) or untick item ``item`` (its id) of a checklist."""
        self.call("checklist_toggle", conv=conv_of(conv), msg_id=msg_id, item=int(item), done=bool(done))

    def checklist_add(self, conv: str, msg_id: str, items: Sequence[str]) -> None:
        """Add items to a checklist the bot sent."""
        self.call("checklist_add", conv=conv_of(conv), msg_id=msg_id, items=list(items))

    def checklist(self, conv: str, msg_id: str) -> Optional[dict]:
        """Current state of a checklist: ``{msg_id, conv, title, items: [{id, text, done,
        by, at}], done, total}`` or ``None`` if not found."""
        st = self._checklists.get(msg_id)
        if st is None:
            st = self._load_checklist(conv_of(conv), msg_id)
        return self._checklist_view(st) if st else None

    def send_reminder(self, conv: str, title: str, at: When, note: str = "", *, silent: bool = False) -> dict:
        """Send a reminder. Everyone in the chat (and the bot) gets ``reminder_due`` at
        ``at``.

        Args:
            title: ≤ 200 chars. note: ≤ 1000 chars.
            at: ``datetime``, ``timedelta`` from now, or epoch ms. Must be in the future.
        """
        conv = conv_of(conv)
        return self._send_cmd(conv, "send_reminder", {"conv": conv, "title": title, "at_ms": _ms(at), "note": note, "silent": silent})

    def reminder_cancel(self, conv: str, msg_id: str) -> None:
        """Cancel a reminder the bot sent."""
        self.call("reminder_cancel", conv=conv_of(conv), msg_id=msg_id)

    def reminders(self) -> List[dict]:
        """Upcoming reminders known to the bot (soonest first):
        ``[{conv, msg_id, at_ms, title, note, author}]``."""
        return self.call("reminders")

    def send_sticker(self, conv: str, pack: str = "", sticker: str = "", *, hash: Optional[str] = None) -> dict:
        """Send a built-in sticker (``pack``, ``sticker``) or a custom one by ``hash``."""
        conv = conv_of(conv)
        args = {"conv": conv, "hash": hash} if hash else {"conv": conv, "pack": pack, "sticker": sticker}
        return self._send_cmd(conv, "send_sticker", args)

    def send_location(self, conv: str, lat: float, lon: float, label: str = "", *, accuracy_m: float = 0,
                      live_minutes: int = 0) -> dict:
        """Send a location (``live_minutes > 0``: live location you update with
        :meth:`update_live_location`, max 8 h)."""
        conv = conv_of(conv)
        return self._send_cmd(conv, "send_location", {"conv": conv, "lat": lat, "lon": lon, "label": label,
                                                       "accuracy_m": accuracy_m, "live_minutes": live_minutes})

    def update_live_location(self, conv: str, msg_id: str, lat: float, lon: float, *, accuracy_m: float = 0,
                             stop: bool = False) -> None:
        """Move a live location, or end it (``stop=True``)."""
        self.call("update_live_location", conv=conv_of(conv), msg_id=msg_id, lat=lat, lon=lon, accuracy_m=accuracy_m, stop=stop)

    def send_contact(self, conv: str, peer: str) -> dict:
        """Send a contact card of user ``peer`` (or of the bot itself)."""
        conv = conv_of(conv)
        return self._send_cmd(conv, "send_contact", {"conv": conv, "peer": peer})

    def send_voice(self, conv: str, path: str, duration_ms: int, wave: Optional[Sequence[int]] = None) -> dict:
        """Send a voice message (Ogg/Opus file ≤ 32 MB; ``wave``: 0–255 bars for the waveform)."""
        conv = conv_of(conv)
        return self._send_cmd(conv, "send_voice", {"conv": conv, "path": os.path.abspath(path),
                                                    "duration_ms": int(duration_ms), "wave": list(wave or [])})

    def edit_message(self, conv: str, msg_id: str, text: str) -> None:
        """Edit the text of one of the bot's messages."""
        self.call("edit_message", conv=conv_of(conv), msg_id=msg_id, text=text)

    def delete_message(self, conv: str, msg_id: str, for_everyone: bool = True) -> None:
        """Delete a message. In groups, deleting others' messages needs admin rights."""
        self.call("delete_message", conv=conv_of(conv), msg_id=msg_id, for_everyone=for_everyone)

    def pin_message(self, conv: str, msg_id: str, on: bool = True) -> None:
        """Pin (``on=True``) or unpin a message."""
        self.call("pin_message", conv=conv_of(conv), msg_id=msg_id, on=on)

    def pinned_messages(self, conv: str) -> List[dict]:
        """Pinned messages of a conversation."""
        return self.call("pinned_messages", conv=conv_of(conv))

    def react(self, conv: str, msg_id: str, emoji: str, on: bool = True) -> None:
        """Add (or remove) an emoji reaction."""
        self.call("react", conv=conv_of(conv), msg_id=msg_id, emoji=emoji, on=on)

    def forward_message(self, msg_id: str, to_conv: str) -> dict:
        """Forward a message to another conversation."""
        to_conv = conv_of(to_conv)
        return self._send_cmd(to_conv, "forward_message", {"msg_id": msg_id, "to_conv": to_conv})

    def messages(self, conv: str, limit: int = 50, before: Optional[int] = None) -> List[dict]:
        """Recent messages of a conversation, oldest first. File messages carry
        ``body.preview`` and ``file`` (``state``, ``path`` once downloaded)."""
        args: Dict[str, Any] = {"conv": conv_of(conv), "limit": int(limit)}
        if before is not None:
            args["before"] = before
        return self.call("messages", **args)

    def typing(self, conv: str, on: bool = True) -> None:
        """Show (or hide) "typing…"."""
        self.call("typing", conv=conv_of(conv), on=on)

    def mark_read(self, conv: str) -> None:
        """Mark a conversation as read."""
        self.call("mark_read", conv=conv_of(conv))

    def schedule_message(self, conv: str, text: str, at: When) -> dict:
        """Let Lumora send ``text`` at ``at`` (kept while the bot runs; ≤ 500 pending).
        Returns ``{id, conv, text, at}``."""
        return self.call("schedule_message", conv=conv_of(conv), text=text, at=_ms(at))

    def scheduled_messages(self) -> List[dict]:
        """Pending scheduled messages."""
        return self.call("scheduled_messages")

    def cancel_scheduled(self, sched_id: str) -> None:
        """Cancel a scheduled message."""
        self.call("cancel_scheduled", sched_id=sched_id)

    # ================================================================== files
    def files(self) -> List[dict]:
        """All file transfers (``id``, ``conv``, ``name``, ``size``, ``state``, ``path``,
        ``direction``, ``preview``…). ``state``: 0 offered, 1 transferring, 2 done,
        3 failed, 4 cancelled, 5 paused."""
        return self.call("files")

    def accept_file(self, file_id: str, dir: Optional[str] = None) -> None:
        """Start (or resume) downloading a received file into ``dir``
        (default: ``downloads_dir``)."""
        args: Dict[str, Any] = {"file_id": file_id}
        if dir:
            args["dir"] = os.path.abspath(dir)
        self.call("accept_file", **args)

    def cancel_file(self, file_id: str) -> None:
        """Stop a transfer."""
        self.call("cancel_file", file_id=file_id)

    def download_file(self, file_id: str, dir: Optional[str] = None, timeout: float = 300) -> str:
        """Download a received file and wait until it is complete. Returns the local path.

        Small files from users are downloaded automatically; this also works for those.

        Raises:
            LumoraError: ``sdk.download_failed`` (failed / cancelled) or ``sdk.timeout``.
        """
        ev = self._file_waiters.setdefault(file_id, threading.Event())
        try:
            f = self._file_entry(file_id)
            if not (f and f.get("state") == 2 and f.get("path") and os.path.exists(f["path"])):
                self.accept_file(file_id, dir)
            deadline = time.monotonic() + timeout
            while True:
                f = self._file_entry(file_id)
                if f and f.get("state") == 2 and f.get("path"):
                    return f["path"]
                if f and f.get("state") in (3, 4):
                    raise LumoraError("The file could not be downloaded.", "sdk.download_failed", f"state {f.get('state')}", "accept_file")
                left = deadline - time.monotonic()
                if left <= 0:
                    raise LumoraTimeout("The download did not finish in time.", "sdk.timeout", file_id, "accept_file")
                ev.wait(min(1.0, left))
                ev.clear()
        finally:
            self._file_waiters.pop(file_id, None)

    def _file_entry(self, file_id: str) -> Optional[dict]:
        for f in self.files():
            if f.get("id") == file_id:
                return f
        return None

    # ================================================================== groups
    def groups(self) -> List[dict]:
        """Groups the bot is in (``gid``, ``conv``, ``name``, ``members``, ``my_role``,
        ``bots`` [{peer, read_all}], ``slow_mode_s``…)."""
        return self.call("groups")

    def group_info(self, group: str) -> dict:
        """Details of a group (``group``: gid or ``g:`` conversation id)."""
        return self.call("group_info", gid=gid_of(group))

    def group_access(self, group: str) -> dict:
        """What the bot may do in a group: ``{"read_all": bool, "admin": bool}``.
        ``read_all`` = an admin allowed "read all messages" (full access); ``admin`` = the
        bot is a group admin (needed for ban / slow mode / purge / delete others')."""
        g = self.group_info(group)
        me = self.me.get("peer")
        bot = next((b for b in g.get("bots", []) if b.get("peer") == me), None)
        return {"read_all": bot is None or bool(bot.get("read_all")), "admin": g.get("my_role") in ("admin", "owner")}

    def member_role(self, group: str, peer: str) -> Optional[str]:
        """Role of ``peer`` in a group: ``"owner"``, ``"admin"``, ``"member"`` or ``None``."""
        gid = gid_of(group)
        members = self._groups.get(gid)
        if members is None or peer not in members:
            try:
                self._track_group(self.group_info(gid))
            except LumoraError:
                return None
            members = self._groups.get(gid, {})
        m = members.get(peer)
        return m.get("role") if m else None

    def group_ban(self, group: str, peer: str, ban: bool = True) -> None:
        """Ban (or unban) a member: removes them and stops them from rejoining.
        The bot must be a group admin with full access."""
        self.call("group_ban", gid=gid_of(group), peer=peer, ban=ban)

    def group_unban(self, group: str, peer: str) -> None:
        """Lift a ban."""
        self.group_ban(group, peer, False)

    def group_remove(self, group: str, peer: str) -> None:
        """Remove (kick) a member; they may be added again. Needs admin rights."""
        self.call("group_remove", gid=gid_of(group), peer=peer)

    def group_settings(self, group: str, *, slow_mode_s: Optional[int] = None, admins_only: Optional[bool] = None) -> None:
        """Change group settings (admin): ``slow_mode_s`` (seconds between two messages of
        a member, 0 = off) and ``admins_only`` (only admins may post)."""
        args: Dict[str, Any] = {"gid": gid_of(group)}
        if slow_mode_s is not None:
            args["slow_mode_s"] = int(slow_mode_s)
        if admins_only is not None:
            args["admins_only"] = bool(admins_only)
        self.call("group_settings", **args)

    def set_slow_mode(self, group: str, seconds: int) -> None:
        """Shortcut for ``group_settings(group, slow_mode_s=seconds)``."""
        self.group_settings(group, slow_mode_s=seconds)

    def group_purge_member(self, group: str, peer: str) -> None:
        """Delete every message of ``peer`` in the group (admin; e.g. after spam)."""
        self.call("group_purge_member", gid=gid_of(group), peer=peer)

    def group_leave(self, group: str) -> None:
        """Leave a group."""
        self.call("group_leave", gid=gid_of(group))

    def search_groups(self, query: str) -> List[dict]:
        """Find public groups by ``@handle`` or ``@handle·tag`` (read-only; bots join a
        group only when one of its admins adds them)."""
        return self.call("search_groups", q=query)

    # ================================================================== users / profile
    def users(self) -> List[str]:
        """Everyone who started a chat with the bot (peer ids)."""
        return [c["peer"] for c in self.call("contacts") if c.get("status") == 3]

    def contacts(self) -> List[dict]:
        """Full user entries (``peer``, ``short_id``, ``name``, ``handle``, ``online``…)."""
        return self.call("contacts")

    def name_of(self, peer: str) -> str:
        """Display name of a user (cached; falls back to the 9-digit ID)."""
        if self._names.get(peer):
            return self._names[peer]
        try:
            for c in self.call("contacts"):
                self._names[c["peer"]] = c.get("alias") or c.get("name") or c.get("short_id") or c["peer"][:8]
        except LumoraError:
            pass
        return self._names.get(peer) or peer[:8]

    def resolve_username(self, handle: str) -> List[dict]:
        """Look up ``@name`` / ``@name·tag``: ``[{peer, handle, name?, contact}]``."""
        return self.call("resolve_username", handle=handle)

    def block_user(self, peer: str) -> None:
        """Block a user: they can no longer message the bot."""
        self.call("block_contact", peer=peer)

    def unblock_user(self, peer: str) -> None:
        """Unblock a user."""
        self.call("unblock_contact", peer=peer)

    def set_profile(self, *, name: Optional[str] = None, bio: Optional[str] = None, avatar: Optional[str] = None) -> dict:
        """Update the bot's profile. ``avatar``: path to an image (≤ 96 KB)."""
        args: Dict[str, Any] = {}
        if name is not None:
            args["name"] = name
        if bio is not None:
            args["bio"] = bio
        if avatar:
            with open(avatar, "rb") as f:
                args["avatar"] = base64.b64encode(f.read()).decode()
        return self.call("set_profile", **args)

    def set_commands(self) -> None:
        """Publish the command menu again (done automatically at start)."""
        pub = [{"command": c, "description": d} for c, (_, d, hidden, chats) in self._commands.items() if not hidden and chats != "group"]
        grp = [{"command": c, "description": d} for c, (_, d, hidden, chats) in self._commands.items() if not hidden and chats != "private"]
        self.call("set_bot", commands=pub, group_commands=grp, about=self.about, auto_accept=True, allow_groups=self.allow_groups)

    def broadcast(self, text: str, buttons: Buttons = None, *, silent: bool = False,
                  users: Optional[Iterable[str]] = None, on_progress: Optional[Callable[[int, int], Any]] = None) -> int:
        """Send ``text`` to every user (or ``users``), paced (≈ 15 messages/s).

        Returns:
            How many users received it. Failures are logged and skipped.
        """
        targets = list(users) if users is not None else self.users()
        n = 0
        for i, p in enumerate(targets, 1):
            if self._stopping.is_set():
                break
            try:
                self.send(conv_of(p), text, buttons=buttons, silent=silent)
                n += 1
            except LumoraError as e:
                log.warning("broadcast to %s… failed: %s", p[:10], e, extra=_x(event="broadcast_failed", peer=p, **e.to_dict()))
            if on_progress:
                on_progress(i, len(targets))
        return n

    # ================================================================== lifecycle
    def start(self) -> "Bot":
        """Start Lumora Bot Runner and go online (non-blocking). See :meth:`run`."""
        os.makedirs(self.data_dir, exist_ok=True)
        os.makedirs(self.downloads_dir, exist_ok=True)
        self._stopping.clear()
        self._stopped.clear()
        self._started = False
        self._spawn()
        self._started = True
        self._jobs.start()
        return self

    def _spawn(self) -> None:
        args = [self.binary, "--data", self.data_dir, "--stdio", "--downloads", os.path.abspath(self.downloads_dir), *self.extra]
        env = dict(os.environ)
        if self.token:
            env["LUMORA_BOT_TOKEN"] = self.token  # via environment, never on the command line
        else:
            args[3:3] = ["--name", self.name]
        err: Any = subprocess.DEVNULL
        if self.runner_log:
            try:
                if os.path.exists(self.runner_log) and os.path.getsize(self.runner_log) > 10 << 20:
                    os.replace(self.runner_log, self.runner_log + ".1")
                err = open(self.runner_log, "a", encoding="utf-8")
            except OSError:
                err = subprocess.DEVNULL
        try:
            proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err,
                                    text=True, encoding="utf-8", bufsize=1, env=env)
        except FileNotFoundError:
            raise RunnerStopped(f"Lumora Bot Runner not found: {self.binary}. Set LUMORAD=/path/to/lumorad.",
                                "sdk.runner_missing", self.binary) from None
        finally:
            if err is not subprocess.DEVNULL:
                err.close()
        self._ready.clear()
        self._gen += 1
        self._proc = proc
        threading.Thread(target=self._reader, args=(proc, self._gen), name="lumora-bot-reader", daemon=True).start()
        try:
            self._setup()
        except LumoraError as e:
            if isinstance(e, (RunnerStopped, LumoraTimeout)):
                hint = f" See {self.runner_log}." if self.runner_log else ""
                try:
                    proc.kill()
                except OSError:
                    pass
                raise RunnerStopped("Lumora Bot Runner could not start." + hint, "sdk.runner_failed", e.detail or e.message) from None
            raise
        self._ready.set()
        for fn in self._start_hooks:
            self._runner.submit(("start",), self._call_handler, lambda _c, fn=fn: fn(), Context(self, {"event": "start"}, "start"))

    def _setup(self) -> None:
        self.me = self._call("me", {}, 30, wait_ready=False)
        if self.lang:
            self._call("set_lang", {"lang": self.lang}, 10, wait_ready=False)
        self.admin_peers = set()
        for a in self._admin_specs:
            if a.startswith("@"):
                try:
                    found = self._call("resolve_username", {"handle": a}, 30, wait_ready=False)
                    if len(found) == 1:
                        self.admin_peers.add(found[0]["peer"])
                    else:
                        log.warning("admin %s: %d matches, use the full @name·tag", a, len(found), extra=_x(event="admin_unresolved"))
                except LumoraError as e:
                    log.warning("admin %s: %s", a, e, extra=_x(event="admin_unresolved", **e.to_dict()))
            else:
                self.admin_peers.add(a)
        # admin-only commands are hidden from the public command menu
        pub = [{"command": c, "description": d} for c, (_, d, hidden, chats) in self._commands.items() if not hidden and chats != "group"]
        grp = [{"command": c, "description": d} for c, (_, d, hidden, chats) in self._commands.items() if not hidden and chats != "private"]
        self._call("set_bot", {"commands": pub, "group_commands": grp, "about": self.about, "auto_accept": True,
                               "allow_groups": self.allow_groups}, 30, wait_ready=False)
        try:
            for g in self._call("groups", {}, 30, wait_ready=False) or []:
                self._track_group(g)
        except LumoraError:
            pass

    def run(self) -> None:
        """Start and block until stopped (Ctrl+C, SIGTERM or :meth:`stop`). Shuts down
        gracefully: running handlers finish, then Lumora Bot Runner exits."""
        self.start()
        label = self.me.get("handle") or self.me.get("name") or self.name
        print(f"🤖 {label} is online — ID {self.me['short_id']}  ({self.me['peer']})", flush=True)
        log.info("online as %s", label, extra=_x(event="online", peer=self.me.get("peer"), version=self.me.get("version")))
        if threading.current_thread() is threading.main_thread():
            for sig in (signal.SIGTERM, getattr(signal, "SIGHUP", None)):
                if sig is not None:
                    try:
                        signal.signal(sig, self._on_signal)
                    except (ValueError, OSError):
                        pass
        try:
            while not self._stopped.wait(0.5):
                pass
        except KeyboardInterrupt:
            pass
        finally:
            self.stop()

    def _on_signal(self, *_: Any) -> None:
        self._stopped.set()  # run() wakes up and calls stop()

    def stop(self, timeout: float = 10) -> None:
        """Stop gracefully: no new events, wait up to ``timeout`` s for running handlers,
        then close Lumora Bot Runner (it saves everything and exits)."""
        if self._stopping.is_set() and self._proc is None:
            return
        self._stopping.set()
        self._jobs.stop()
        if not self._runner.close(timeout):
            log.warning("some handlers were still running after %.0f s", timeout, extra=_x(event="shutdown_timeout"))
        proc, self._proc = self._proc, None
        self._ready.clear()
        if proc:
            try:
                if proc.stdin:
                    proc.stdin.close()
                proc.wait(timeout=5)
            except Exception:
                proc.kill()
        try:
            self.storage.save()
        except OSError:
            pass
        if self._loop:
            self._loop.call_soon_threadsafe(self._loop.stop)
        self._stopped.set()
        log.info("stopped", extra=_x(event="stopped"))

    # ================================================================== reader / restart
    def _reader(self, proc: subprocess.Popen, gen: int) -> None:
        assert proc.stdout
        for line in proc.stdout:
            try:
                v = json.loads(line)
            except ValueError:
                continue
            if "event" in v:
                self._on_event(v)
            elif "id" in v:
                with self._cv:
                    if v["id"] in self._pending:
                        self._resp[v["id"]] = v
                        self._cv.notify_all()
        code = proc.wait()
        if gen != self._gen:
            return
        self._ready.clear()
        with self._cv:  # fail everything that was waiting for this process
            for rid in list(self._pending):
                self._resp[rid] = {"id": rid, "ok": False, "error": "Lumora Bot Runner stopped.", "code": "sdk.runner_stopped",
                                   "detail": f"exit code {code}"}
            self._cv.notify_all()
        if self._stopping.is_set():
            return
        log.error("Lumora Bot Runner exited (code %s)", code, extra=_x(event="runner_exit", exit_code=code))
        if not self.auto_restart or not self._started:
            self._stopped.set()
            return
        threading.Thread(target=self._restart_loop, name="lumora-bot-restart", daemon=True).start()

    def _restart_loop(self) -> None:
        delay = 1.0
        while not self._stopping.is_set():
            now = time.time()
            self._restarts = [t for t in self._restarts if now - t < 600] + [now]
            if len(self._restarts) > 20:
                log.critical("Lumora Bot Runner keeps crashing; giving up", extra=_x(event="restart_giveup"))
                self._stopped.set()
                return
            if self._stopping.wait(delay):
                return
            try:
                self._spawn()
                log.info("Lumora Bot Runner restarted", extra=_x(event="runner_restarted"))
                return
            except LumoraError as e:
                log.error("restart failed: %s", e, extra=_x(event="restart_failed", **e.to_dict()))
                delay = min(delay * 2, 30.0)

    # ================================================================== dispatch
    def _on_event(self, ev: dict) -> None:
        kind = ev.get("event")
        # cheap state kept in the reader thread (ordering matters)
        if kind == "file" and ev.get("id") in self._file_waiters:
            self._file_waiters[ev["id"]].set()
        if kind == "contact" and ev.get("peer"):
            self._names[ev["peer"]] = ev.get("alias") or ev.get("name") or self._names.get(ev["peer"], "")
        if self._stopping.is_set():
            return
        key = ev.get("conv") or ev.get("msg_conv") or ev.get("gid") or ev.get("peer")
        self._runner.submit(key, self._dispatch, ev)

    def _dispatch(self, ev: dict) -> None:
        kind = ev.get("event", "")
        for name in (kind, "*"):
            for fn in self._raw.get(name, ()):
                self._call_handler(fn, Context(self, ev, kind))
        try:
            if kind == "message":
                self._dispatch_message(ev)
            elif kind == "callback":
                self._dispatch_callback(ev)
            elif kind == "bot_user":
                ctx = Context(self, {"event": "bot_user", "conv": "d:" + ev["peer"], "from": ev["peer"]}, "new_user")
                if ev.get("name"):
                    self._names[ev["peer"]] = ev["name"]
                self._run_routes("new_user", ctx)
            elif kind == "group":
                self._dispatch_group(ev)
            elif kind == "reminder_due":
                ctx = Context(self, {"event": kind, "conv": ev.get("conv"), "msg_id": ev.get("msg_id"), "author": ev.get("author")}, "reminder_due")
                ctx.reminder = {k: ev.get(k) for k in ("title", "note", "at_ms", "author", "mine", "late", "conv", "msg_id")}
                ctx.text = ev.get("title") or ""
                self._run_routes("reminder_due", ctx)
            elif kind == "message_update":
                self._dispatch_update(ev)
        except Exception as e:  # pragma: no cover - defensive
            log.exception("dispatch error: %r", e, extra=_x(event="dispatch_error"))

    def _run(self, ctx: Context, final: Callable[[Context], Any]) -> None:
        chain = list(self._middleware)

        def step(i: int):
            if i < len(chain):
                return self._call_handler(lambda c: chain[i](c, lambda: step(i + 1)), ctx)
            return self._call_handler(final, ctx)
        step(0)

    def _call_handler(self, fn: Callable, ctx: Context) -> Any:
        try:
            r = fn(ctx)
            if inspect.isawaitable(r):
                r = asyncio.run_coroutine_threadsafe(_await(r), self._event_loop()).result()
            return r
        except Exception as e:
            fields = e.to_dict() if isinstance(e, LumoraError) else {"error": repr(e)}
            log.error("handler error in %s: %s", getattr(fn, "__name__", "handler"), e, exc_info=not isinstance(e, LumoraError),
                      extra=_x(event="handler_error", kind=ctx.kind, conv=ctx.conv, **fields))
            for h in self._error_handlers:
                try:
                    h(ctx, e)
                except Exception:
                    log.exception("on_error handler failed")
            return None

    def _event_loop(self) -> asyncio.AbstractEventLoop:
        with self._lock:
            if self._loop is None:
                self._loop = asyncio.new_event_loop()
                threading.Thread(target=self._loop.run_forever, name="lumora-bot-asyncio", daemon=True).start()
            return self._loop

    def _run_routes(self, name: str, ctx: Context, select: Optional[Callable[[_Route], Any]] = None) -> bool:
        routes = self._routes.get(name, [])
        if not routes:
            return False

        def final(c: Context):
            specific = [r for r in routes if r.specific]
            for r in specific:
                m = select(r) if select else True
                if m:
                    if m is not True and hasattr(m, "group"):
                        c.match = m
                    c.handled = True
                    return self._call_handler(r.fn, c)
            for r in routes:
                if not r.specific and (select is None or select(r) is not None):
                    c.handled = True
                    self._call_handler(r.fn, c)
        self._run(ctx, final)
        return True

    def _addressed_elsewhere(self, ctx: Context) -> bool:
        t = ctx._command_target
        if not t:
            return False
        uname = (self.me.get("username") or "").lower()
        name = (self.me.get("name") or self.name or "").lower().replace(" ", "")
        return not (t == uname or t == name or (uname and t.startswith(uname)))

    def _dispatch_message(self, ev: dict) -> None:
        if ev.get("mine"):
            if ev.get("kind") == "checklist":
                self._remember_checklist(ev)
            return
        mk = ev.get("kind", "")
        if mk == "system":
            return
        ctx = Context(self, ev, "message")
        if mk == "checklist":
            self._remember_checklist(ev)
        if mk == "text" and ctx.command is not None:
            if self._addressed_elsewhere(ctx):
                return
            entry = self._commands.get(ctx.command)
            if entry is not None:
                fn, _, _, chats = entry
                if not _chat_ok(chats, ctx):
                    return
                ctx.kind = "command"
                self._run(ctx, lambda c: fn(c))
                return
            if ctx.command == "help" and self.help_command:
                ctx.kind = "command"
                lines = [f"/{c} — {d}" for c, (_, d, hidden, chats) in self._commands.items()
                         if (not hidden or ctx.is_admin) and _chat_ok(chats, ctx)]
                self._run(ctx, lambda c: c.reply("\n".join(lines) or "No commands"))
                return
        if mk in ("file", "voice"):
            ctx.file = dict(ctx.body)
            ctx.file["state"] = (ev.get("file") or {}).get("state")
            ctx.file["path"] = (ev.get("file") or {}).get("path") or None
            ctx.file.setdefault("preview", None)
            if mk == "file" and self._routes.get("file"):
                ext = os.path.splitext(ctx.file.get("name") or "")[1].lower().lstrip(".")
                fctx = Context(self, ev, "file")
                fctx.file = ctx.file
                self._run_routes("file", fctx, lambda r: True if (r.exts is None or ext in r.exts) and _chat_ok(r.chats, fctx) else None)
                if fctx.handled:
                    return

        def sel(r: _Route):
            if r.kinds is not None and mk not in r.kinds:
                return None
            if not _chat_ok(r.chats, ctx):
                return None
            if r.pattern is not None:
                return r.pattern.search(ctx.text) if mk == "text" else None
            return True
        self._run_routes("message", ctx, sel)

    def _dispatch_callback(self, ev: dict) -> None:
        ctx = Context(self, ev, "callback")

        def sel(r: _Route):
            if r.data is not None:
                if r.data.endswith("*"):
                    return True if ctx.data.startswith(r.data[:-1]) else None
                return True if ctx.data == r.data else None
            if r.pattern is not None:
                return r.pattern.search(ctx.data)
            return True
        self._run_routes("callback", ctx, sel)

    def _track_group(self, g: dict) -> Tuple[Optional[Dict[str, dict]], Dict[str, dict]]:
        gid = str(g.get("gid") or "")
        new = {m["peer"]: m for m in g.get("members", [])}
        if g.get("owner") in new:
            new[g["owner"]] = dict(new[g["owner"]], role="owner")
        for p, m in new.items():
            if m.get("name"):
                self._names[p] = m["name"]
        old = self._groups.get(gid)
        self._groups[gid] = new
        return old, new

    def _dispatch_group(self, ev: dict) -> None:
        me = self.me.get("peer")
        old, new = self._track_group(ev)
        conv = ev.get("conv") or ("g:" + ev.get("gid", ""))
        if old is None:
            if me in new:
                ctx = Context(self, {"event": "group", "conv": conv, "from": ev.get("owner")}, "added_to_group")
                ctx.member = new.get(me)
                self._run_routes("added_to_group", ctx)
            return
        for p in new.keys() - old.keys():
            if p == me:
                continue
            ctx = Context(self, {"event": "group", "conv": conv, "from": p}, "new_member")
            ctx.member = new[p]
            self._run_routes("new_member", ctx)
        for p in old.keys() - new.keys():
            if p == me:
                continue
            ctx = Context(self, {"event": "group", "conv": conv, "from": p}, "member_left")
            ctx.member = old[p]
            self._run_routes("member_left", ctx)

    # ---- checklists
    def _remember_checklist(self, m: dict) -> None:
        mid = m.get("id")
        if not mid or (m.get("kind") and m.get("kind") != "checklist"):
            return
        body = m.get("body") or {}
        st = self._checklists.get(mid) or {"msg_id": mid, "conv": m.get("conv"), "title": "", "items": [], "checks": {}}
        st["title"] = body.get("title", st["title"])
        st["items"] = body.get("items", st["items"])
        if isinstance(m.get("reactions"), dict) and isinstance(m["reactions"].get("__checks"), dict):
            st["checks"] = dict(m["reactions"]["__checks"])
        self._checklists[mid] = st
        self._checklists.move_to_end(mid)
        while len(self._checklists) > 2000:
            self._checklists.popitem(last=False)

    def _load_checklist(self, conv: str, msg_id: str) -> Optional[dict]:
        try:
            for m in self.messages(conv, limit=500):
                if m.get("id") == msg_id and m.get("kind") == "checklist":
                    self._remember_checklist(m)
                    return self._checklists.get(msg_id)
        except LumoraError:
            pass
        return None

    @staticmethod
    def _checklist_view(st: dict) -> dict:
        items = []
        for it in st.get("items", []):
            c = st.get("checks", {}).get(str(it.get("id")), {})
            items.append({"id": it.get("id"), "text": it.get("text"), "done": bool(c.get("done")), "by": c.get("by"), "at": c.get("at")})
        return {"msg_id": st["msg_id"], "conv": st.get("conv"), "title": st.get("title"), "items": items,
                "done": sum(1 for i in items if i["done"]), "total": len(items)}

    def _dispatch_update(self, ev: dict) -> None:
        mid, conv = str(ev.get("id") or ""), str(ev.get("conv") or "")
        reactions: Dict[str, Any] = ev["reactions"] if isinstance(ev.get("reactions"), dict) else {}
        body: Dict[str, Any] = ev["body"] if isinstance(ev.get("body"), dict) else {}
        is_checks = isinstance(reactions.get("__checks"), dict)
        is_items = isinstance(body.get("items"), list) and "title" in body
        if not mid or not (is_checks or is_items):
            return
        st = self._checklists.get(mid) or self._load_checklist(conv, mid)
        if st is None:
            return
        me = self.me.get("peer")
        changes = []
        if is_checks:
            new_checks = reactions["__checks"]
            texts = {str(i.get("id")): i.get("text") for i in st.get("items", [])}
            for k, v in new_checks.items():
                old = st["checks"].get(k)
                if old != v and v.get("by") != me:
                    changes.append({"item": int(k), "text": texts.get(k), "done": bool(v.get("done")), "by": v.get("by")})
            st["checks"] = dict(new_checks)
        if is_items:
            old_ids = {i.get("id") for i in st.get("items", [])}
            st["items"] = body["items"]
            st["title"] = body.get("title", st["title"])
            for it in body["items"]:
                if it.get("id") not in old_ids:
                    changes.append({"item": it.get("id"), "text": it.get("text"), "added": True, "by": None})
        if not changes:
            return
        ctx = Context(self, {"event": "message_update", "conv": conv, "msg_id": mid,
                             "from": next((c["by"] for c in reversed(changes) if c.get("by")), "")}, "checklist")
        ctx.checklist = self._checklist_view(st)
        ctx.changes = changes
        ctx.text = st.get("title") or ""
        self._run_routes("checklist", ctx)


async def _await(r):
    return await r
