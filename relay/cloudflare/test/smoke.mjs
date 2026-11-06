// Protocol smoke test against any Lumora relay (Cloudflare `wrangler dev` or the Rust relay).
//   RELAY_URL=ws://127.0.0.1:8787/ws node --experimental-websocket test/smoke.mjs   (Node 20)
//   RELAY_URL=ws://127.0.0.1:8443/ws node test/smoke.mjs                             (Node 22+)
import { generateKeyPairSync, sign } from "node:crypto";

const URL_ = process.env.RELAY_URL || "ws://127.0.0.1:8787/ws";
const T = { HELLO: 1, WELCOME: 2, DATA: 3, SIGNAL: 4, GONE: 5, ERROR: 6 };
const CTX = Buffer.from("lumora-relay-hello-v1");

function identity() {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const pk = Buffer.from(publicKey.export({ format: "jwk" }).x, "base64url");
  return { pk, privateKey };
}
function helloFrame(id, ts = Date.now(), signer = id) {
  const tsb = Buffer.alloc(8);
  tsb.writeBigUInt64BE(BigInt(ts));
  const sig = sign(null, Buffer.concat([CTX, id.pk, tsb]), signer.privateKey);
  return Buffer.concat([Buffer.from([T.HELLO]), id.pk, tsb, sig]);
}
const peerFrame = (t, peer, payload) => Buffer.concat([Buffer.from([t]), peer, Buffer.from(payload)]);

function open() {
  return new Promise((res, rej) => {
    const ws = new WebSocket(URL_);
    ws.binaryType = "arraybuffer";
    ws.queue = [];
    ws.waiters = [];
    ws.onmessage = (e) => {
      const b = Buffer.from(e.data);
      const w = ws.waiters.shift();
      w ? w(b) : ws.queue.push(b);
    };
    ws.onclose = () => ws.waiters.splice(0).forEach((w) => w(null));
    ws.onopen = () => res(ws);
    ws.onerror = rej;
  });
}
function next(ws, ms = 3000) {
  if (ws.queue.length) return Promise.resolve(ws.queue.shift());
  return new Promise((res) => {
    const t = setTimeout(() => {
      ws.waiters = ws.waiters.filter((w) => w !== f);
      res(null);
    }, ms);
    const f = (b) => {
      clearTimeout(t);
      res(b);
    };
    ws.waiters.push(f);
  });
}
async function connect(id) {
  const ws = await open();
  ws.send(helloFrame(id));
  const w = await next(ws);
  assert(w && w[0] === T.WELCOME, `WELCOME expected, got ${w && w[0]} ${w && w.subarray(1)}`);
  return ws;
}
function assert(c, m) {
  if (!c) {
    console.error("FAIL:", m);
    process.exit(1);
  }
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const a = identity(), b = identity(), c = identity();
const wa = await connect(a);
const wb = await connect(b);

wa.send(peerFrame(T.DATA, b.pk, "datagram"));
let f = await next(wb);
assert(f && f[0] === T.DATA && f.subarray(1, 33).equals(a.pk) && f.subarray(33).toString() === "datagram", "DATA forward");
console.log("ok  DATA forwarded with sender key");

wb.send(peerFrame(T.SIGNAL, a.pk, "envelope"));
f = await next(wa);
assert(f && f[0] === T.SIGNAL && f.subarray(1, 33).equals(b.pk), "SIGNAL forward");
console.log("ok  SIGNAL forwarded");

wa.send(peerFrame(T.DATA, c.pk, "x"));
wa.send(peerFrame(T.DATA, c.pk, "x"));
f = await next(wa);
assert(f && f[0] === T.GONE && f.subarray(1, 33).equals(c.pk), "GONE for absent peer");
assert((await next(wa, 300)) === null, "GONE rate limited");
console.log("ok  GONE (rate limited)");

wa.send(peerFrame(T.SIGNAL, c.pk, "for-later"));
await sleep(300);
const wc = await connect(c);
f = await next(wc);
assert(f && f[0] === T.SIGNAL && f.subarray(1, 33).equals(a.pk) && f.subarray(33).toString() === "for-later", "mailbox");
console.log("ok  mailbox delivered on HELLO");

const bad = await open();
bad.send(helloFrame(identity(), Date.now(), a));
f = await next(bad);
assert(f && f[0] === T.ERROR, "bad signature rejected");
console.log("ok  bad signature rejected:", f.subarray(1).toString());

const ts = Date.now() - 1;
const r1 = await open();
r1.send(helloFrame(b, ts));
await next(r1);
const r2 = await open();
r2.send(helloFrame(b, ts));
f = await next(r2);
assert(f && f[0] === T.ERROR && f.subarray(1).toString().includes("replay"), "replay rejected");
console.log("ok  replayed HELLO rejected");

for (const ws of [wa, wb, wc, bad, r1, r2]) ws.close();
console.log("all ok");
process.exit(0);
