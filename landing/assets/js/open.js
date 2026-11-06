/* Lumora /open/ page: the fallback for shared links and QR codes
   (getlumora.pages.dev/add/…, /join/…, /remote/… are rewritten here by _redirects,
   the address bar keeps the link). Everything happens in the browser from the
   address: no request is made for it. Same rules as the app (app/lib/core/links.dart).
   Loads before app.js, which adds the English strings below and the download button. */
(function () {
  "use strict";
  window.LUMORA_I18N = {
    "op.title.add": "A Lumora friend invite",
    "op.title.join": "An invite to a Lumora group",
    "op.title.remote": "Remote computer help",
    "op.title.other": "Open in Lumora",
    "op.lead.add": "A friend wants to connect with you on Lumora. Open it with Lumora to see who it is and send a friend request.",
    "op.lead.join": "You are invited to a group on Lumora. Open it with Lumora to see the group, then tap Join.",
    "op.lead.remote": "Open it with Lumora to connect to this computer. You still need the temporary password the other person reads out to you.",
    "op.lead.other": "This link is for the Lumora app.",
    "op.idLabel": "Lumora ID",
    "op.idHint.add": "Doesn't open? In Lumora, choose Add friend and type this ID.",
    "op.idHint.remote": "Doesn't open? In Lumora, open Remote control and type this ID.",
    "op.broken": "This link looks incomplete. Ask the sender to share it again.",
    "op.open": "Open with Lumora",
    "op.get": "Get Lumora free",
    "op.stepsTitle": "Don't have Lumora yet?",
    "op.step1": "Download and install Lumora. Free, no sign-up.",
    "op.step2": "Come back to this page and tap “Open with Lumora”, or scan the QR code again with Lumora.",
    "op.other": "See versions for other devices"
  };

  function digits9(s) {
    var d = String(s || "").replace(/[\s.\-·]/g, "");
    return /^\d{9}$/.test(d) ? d : null;
  }

  /* {kind, app, id} or null (never throws) */
  function parse(loc) {
    try {
      var segs = loc.pathname.split("/").filter(function (x) { return x; }).map(decodeURIComponent);
      if (segs.length !== 2) return null;
      var kind = segs[0].toLowerCase(), arg = segs[1];
      var q = null, m = /[?&]id=([^&#]*)/.exec(loc.search || "");
      if (m) { q = digits9(decodeURIComponent(m[1])); if (!q) return null; }
      if (kind === "add") {
        var a = arg.toLowerCase();
        if (/^[a-z2-7]{52}$/.test(a)) return { kind: kind, app: "lumora://add/" + a + (q ? "?id=" + q : ""), id: q };
        var id = digits9(arg);
        if (!id || (q && q !== id)) return null;
        return { kind: kind, app: "lumora://add/" + id, id: id };
      }
      if (kind === "join") {
        var t = arg.toLowerCase();
        return /^[a-z0-9]{8,4096}$/.test(t) ? { kind: kind, app: "lumora://join/" + t, id: null } : null;
      }
      if (kind === "remote") {
        var r = digits9(arg);
        return r ? { kind: kind, app: "lumora://remote/" + r, id: r } : null;
      }
    } catch (e) { /* a broken address renders the generic page */ }
    return null;
  }

  function guessKind(loc) {
    var k = (loc.pathname.split("/").filter(function (x) { return x; })[0] || "").toLowerCase();
    return k === "add" || k === "join" || k === "remote" ? k : "other";
  }

  function init() {
    var link = parse(window.location);
    var kind = link ? link.kind : guessKind(window.location);
    var nodes = document.querySelectorAll(".js-kind");
    Array.prototype.forEach.call(nodes, function (n) {
      var k = n.getAttribute("data-kind");
      var show = k === kind || (k === "other" && kind === "other");
      if (n.parentNode && n.parentNode.id === "op-id") show = k === kind;
      n.hidden = !show;
    });
    var open = document.getElementById("op-open");
    var broken = document.getElementById("op-broken");
    if (link) {
      if (open) open.href = link.app;
      if (link.id) {
        var box = document.getElementById("op-id"), val = document.getElementById("op-id-value");
        if (box && val) {
          val.textContent = link.id.slice(0, 3) + " " + link.id.slice(3, 6) + " " + link.id.slice(6);
          box.hidden = false;
        }
      }
    } else {
      if (open) open.hidden = true;
      if (broken && kind !== "other") broken.hidden = false;
    }
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();
