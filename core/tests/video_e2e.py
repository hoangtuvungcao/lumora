"""Video call end-to-end: codec negotiation, time to first frame, H.264 → VP8 switch,
older peers. Spawns real `lumorad` nodes with a synthetic camera (LUMORA_TEST_CAMERA=1).

    python3 core/tests/video_e2e.py [--bin core/target/debug/lumorad]
        [--h264-bin BIN]   lumorad built with --features lumora-media/openh264-source
                           (dev-only H.264 on Linux; enables the H.264 + switch scenarios)
        [--legacy core/tests/bin/lumorad-legacy]

Bounds are loose for CI machines: first decoded frame < 1.5 s after the answer
(target < 1 s), switch gap < 400 ms (target < 200 ms). Measured values are printed.
"""
import argparse, os, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import e2e  # noqa: E402  (reuses the Node driver)

FIRST_FRAME_MAX_MS = float(os.environ.get("VIDEO_FIRST_FRAME_MAX_MS", "1500"))
SWITCH_GAP_MAX_MS = float(os.environ.get("VIDEO_SWITCH_GAP_MAX_MS", "400"))


class Node(e2e.Node):
    def __init__(self, name, binary, data, extra, env=None):
        self.env = dict(os.environ, LUMORA_TEST_CAMERA="1", **(env or {}))
        super().__init__(name, binary, data, extra)

    def start(self):
        import subprocess, threading
        args = [self.binary, "--data", self.data, "--name", self.name, "--no-dht", "--no-upnp", "--stdio"] + self.extra
        self.log = open(os.path.join(self.data, "node.log"), "a")
        self.p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log, text=True, bufsize=1, env=self.env)
        threading.Thread(target=self._reader, daemon=True).start()
        self.me = self.call("me")


def befriend(x, y):
    try:
        x.call("connect", peer=y.me["peer"], timeout=40)
    except RuntimeError:
        y.call("connect", peer=x.me["peer"], timeout=40)  # e.g. an older build finding a newer one
    x.call("add_contact", target=y.me["peer"], note="hi")
    y.wait_event(lambda e: e["event"] == "friend_request" and e["peer"] == x.me["peer"], 30, what="friend_request")
    y.call("accept_contact", peer=x.me["peer"])
    e2e.wait_until(lambda: any(c["peer"] == y.me["peer"] and c["status"] == 3 for c in x.call("contacts")), 20, "friends")


def video_call(caller, callee):
    """Start a video call; returns (call_id, t_answer)."""
    c = caller.call("call_start", conv=f"d:{callee.me['peer']}", video=True)
    callee.wait_event(lambda e: e["event"] == "call" and e["call_id"] == c["call_id"] and e["state"] == "incoming", 20, what="incoming call")
    callee.call("call_answer", call_id=c["call_id"], accept=True)
    return c["call_id"], time.time()


def first_frame(node, call_id, t0, timeout=10):
    e = node.wait_event(lambda e: e["event"] == "video_first_frame" and e["session"] == call_id, timeout, what="first decoded frame")
    return e, (time.time() - t0) * 1000.0


def end(caller, callee, call_id):
    caller.call("call_end", call_id=call_id)
    callee.wait_event(lambda e: e["event"] == "call" and e["call_id"] == call_id and e["state"] == "ended", 10, what="ended")
    time.sleep(0.5)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=os.path.join(e2e.ROOT, "target", "debug", "lumorad"))
    ap.add_argument("--h264-bin", default=None)
    ap.add_argument("--legacy", default=None)
    a = ap.parse_args()
    tmp = tempfile.mkdtemp(prefix="lumora-video-e2e-")
    os.environ["E2E_TMP"] = tmp
    extra = ["--no-nostr"]
    nodes = []

    def start(name, binary, env=None):
        d = os.path.join(tmp, name)
        os.makedirs(d)
        n = Node(name, binary, d, extra, env)
        nodes.append(n)
        return n

    measured = {}
    try:
        # LUMORA_NO_OS_H264=1: ignore VA-API/OS H.264 here → forced VP8
        vp8_only = {"LUMORA_NO_OS_H264": "1"}
        A = start("alice", a.bin, vp8_only)
        B = start("bob", a.bin, vp8_only)
        befriend(B, A)

        @e2e.step("VP8 video call (OS H.264 switched off): both sides decode within the bound")
        def _():
            caps = A.call("video_codec")["caps"]
            assert "vp8" in caps["enc"] and "vp8" in caps["dec"], caps
            call_id, t0 = video_call(A, B)
            ea, ms_a = first_frame(A, call_id, t0)
            eb, ms_b = first_frame(B, call_id, t0)
            measured["vp8 answer→first frame (caller side)"] = ms_a
            measured["vp8 answer→first frame (callee side)"] = ms_b
            assert ea["codec"] == "vp8" and eb["codec"] == "vp8", (ea, eb)
            assert ms_a < FIRST_FRAME_MAX_MS and ms_b < FIRST_FRAME_MAX_MS, (ms_a, ms_b)
            st = A.call("video_codec")
            assert st["encoder"]["format"] == "vp8" and st["decoder"]["format"] == "vp8", st
            end(A, B, call_id)
        _()

        P = start("hw1", a.bin)
        Q = start("hw2", a.bin)
        # the app probes at start-up (lumora_start); here: ask both and wait for the probe
        for n in (P, Q):
            for _ in range(50):
                hw_caps = n.call("video_codec")
                if hw_caps.get("h264") is not None or hw_caps.get("os_codec") is None:
                    break
                time.sleep(0.1)
        if "h264" in hw_caps["caps"]["hw_enc"]:
            befriend(Q, P)

            @e2e.step("hardware H.264 (VA-API / OS codec) on both sides is preferred, first frame within the bound")
            def _():
                call_id, t0 = video_call(P, Q)
                ep, ms_p = first_frame(P, call_id, t0)
                eq, ms_q = first_frame(Q, call_id, t0)
                measured[f"hw h264 ({ep['backend']}) answer→first frame"] = max(ms_p, ms_q)
                assert ep["codec"] == "h264" and eq["codec"] == "h264", (ep, eq)
                assert ep["hw"] and eq["hw"], (ep, eq)
                assert max(ms_p, ms_q) < FIRST_FRAME_MAX_MS, (ms_p, ms_q)
                end(P, Q, call_id)
            _()
        else:
            print("  (no hardware H.264 on this machine: hardware scenario skipped)")

        if a.h264_bin:
            hw = {"LUMORA_TEST_H264_HW": "1"}
            H1 = start("h1", a.h264_bin, hw)
            H2 = start("h2", a.h264_bin, dict(hw, LUMORA_FORCE_H264_FAIL="1"))
            befriend(H2, H1)

            @e2e.step("H.264 when both sides have it in 'hardware'; forced failure switches to VP8 on the next frame")
            def _():
                call_id, t0 = video_call(H1, H2)
                # H2's encoder fails after 3 frames → VP8 keyframe right away
                e, ms = first_frame(H1, call_id, t0)
                measured["h264 answer→first frame"] = ms
                assert e["codec"] == "h264", e
                assert ms < FIRST_FRAME_MAX_MS, ms
                sw = H1.wait_event(lambda e: e["event"] == "video_codec_switch" and e["session"] == call_id, 10, what="codec switch")
                measured["h264→vp8 switch gap"] = sw["gap_ms"]
                assert (sw["from"], sw["to"]) == ("h264", "vp8"), sw
                assert sw["gap_ms"] < SWITCH_GAP_MAX_MS, sw
                # H1 keeps sending H.264 (its encoder is fine)
                e2, _ = first_frame(H2, call_id, t0)
                assert e2["codec"] == "h264", e2
                end(H1, H2, call_id)
            _()

            if a.legacy:
                L = start("legacy", a.legacy)
                befriend(L, H1)

                @e2e.step("older peer (no caps): a build with H.264 sends it H.264")
                def _():
                    call_id, _ = video_call(H1, L)
                    L.wait_event(lambda e: e["event"] == "video_stream" and e.get("call_id") == call_id, 10, what="legacy receives video")
                    end(H1, L, call_id)
                _()

        if a.legacy:
            L2 = start("legacy2", a.legacy)
            befriend(L2, A)

            @e2e.step("older peer + no H.264 on this device: plain note, call continues with audio")
            def _():
                call_id, _ = video_call(A, L2)
                e = A.wait_event(lambda e: e["event"] == "video_note" and e["session"] == call_id, 10, what="video note")
                assert e["reason"] == "peer_needs_update", e
                end(A, L2, call_id)
            _()
    finally:
        for n in nodes:
            n.stop()
    print("\nmeasured:")
    for k, v in measured.items():
        print(f"  {k}: {v:.0f} ms")
    failed = [r for r in e2e.RESULTS if not r[1]]
    print(f"\n{len(e2e.RESULTS) - len(failed)}/{len(e2e.RESULTS)} passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
