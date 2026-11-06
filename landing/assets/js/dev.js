/* Lumora developer pages: tiny syntax highlighter, copy buttons, tabs (Python/JavaScript choice
   is shared by every tab group on the page and remembered). Page text is bilingual in the HTML
   (.l-vi / .l-en blocks, shown by html[lang]); page titles come from data-title-en/data-desc-en. */
(function () {
  "use strict";

  var KW = {
    py: "and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return True try while with yield",
    js: "async await break case catch class const continue default delete do else export extends false finally for from function if import in instanceof let new null of return static super switch this throw true try typeof undefined var void while yield",
    json: "true false null",
    bash: "export cd sudo chmod docker pip npm node python3 systemctl journalctl",
    bat: "set nssm",
    ini: "",
    dockerfile: "FROM WORKDIR COPY RUN ENV USER VOLUME CMD STOPSIGNAL"
  };
  var esc = function (t) { return t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); };
  function highlight(code, lang) {
    var kw = new RegExp("^(?:" + (KW[lang] || "").split(" ").join("|") + ")$");
    if (lang === "text") return esc(code);
    var lineComment = /^(py|bash|ini|dockerfile)$/.test(lang) ? "#[^\\n]*" : lang === "bat" ? "(?:REM|::)[^\\n]*" : "\\/\\/[^\\n]*";
    var re = new RegExp([
      "(" + lineComment + "|\\/\\*[\\s\\S]*?\\*\\/)",                      // 1 comment
      "(\"\"\"[\\s\\S]*?\"\"\"|'''[\\s\\S]*?'''|f?\"(?:\\\\.|[^\"\\\\\\n])*\"|f?'(?:\\\\.|[^'\\\\\\n])*'|`(?:\\\\.|[^`\\\\])*`)", // 2 string
      "(@[A-Za-z_][\\w.]*)",                                              // 3 decorator
      "(\\b\\d+(?:\\.\\d+)?\\b)",                                          // 4 number
      "([A-Za-z_$][\\w$]*)(?=\\s*\\()",                                  // 5 function call
      "([A-Za-z_$][\\w$]*)"                                               // 6 identifier
    ].join("|"), "g");
    var out = "", last = 0, m;
    while ((m = re.exec(code))) {
      out += esc(code.slice(last, m.index));
      var t = esc(m[0]), cls = null;
      if (m[1]) cls = "c"; else if (m[2]) cls = "s"; else if (m[3] && lang !== "json") cls = "d";
      else if (m[4]) cls = "n";
      else if (m[5]) cls = kw.test(m[5]) ? "k" : "f";
      else if (m[6] && kw.test(m[6])) cls = "k";
      out += cls ? '<span class="tok-' + cls + '">' + t + "</span>" : t;
      last = re.lastIndex;
    }
    return out + esc(code.slice(last));
  }

  function init() {
    var lang = function () { return document.documentElement.lang === "en" ? "en" : "vi"; };
    Array.prototype.forEach.call(document.querySelectorAll("pre > code[data-lang]"), function (c) {
      c.innerHTML = highlight(c.textContent, c.getAttribute("data-lang"));
    });
    Array.prototype.forEach.call(document.querySelectorAll("pre.code"), function (pre) {
      var b = document.createElement("button");
      b.type = "button"; b.className = "code__copy";
      var label = function (done) { return done ? (lang() === "en" ? "Copied" : "Đã chép") : (lang() === "en" ? "Copy" : "Chép"); };
      b.textContent = label(false);
      b.addEventListener("click", function () {
        var text = pre.querySelector("code").textContent;
        if (!navigator.clipboard) return;
        navigator.clipboard.writeText(text).then(function () {
          b.textContent = label(true); b.classList.add("is-done");
          setTimeout(function () { b.textContent = label(false); b.classList.remove("is-done"); }, 1500);
        }, function () {});
      });
      var box = document.createElement("div"); box.className = "codebox";
      pre.parentNode.insertBefore(box, pre); box.appendChild(pre); box.appendChild(b);
    });
    var lt = document.getElementById("lang-toggle");
    if (lt) lt.addEventListener("click", function () {
      setTimeout(function () {
        Array.prototype.forEach.call(document.querySelectorAll(".code__copy"), function (b) { b.textContent = lang() === "en" ? "Copy" : "Chép"; });
      }, 0);
    });
    setTimeout(function () {
      Array.prototype.forEach.call(document.querySelectorAll(".code__copy"), function (b) { b.textContent = lang() === "en" ? "Copy" : "Chép"; });
    }, 0);
    var groups = [];
    var stored = null;
    try { stored = window.localStorage.getItem("lumora-dev-tab"); } catch (e) {}
    function syncAll(key) {
      groups.forEach(function (g) { g.selectKey(key); });
      try { window.localStorage.setItem("lumora-dev-tab", key); } catch (e) {}
    }
    Array.prototype.forEach.call(document.querySelectorAll("[data-tabs]"), function (box) {
      var btns = box.querySelectorAll("[role=tab]"), panels = box.querySelectorAll("[role=tabpanel]");
      function select(i) {
        Array.prototype.forEach.call(btns, function (b, j) { b.setAttribute("aria-selected", String(i === j)); b.tabIndex = i === j ? 0 : -1; });
        Array.prototype.forEach.call(panels, function (p, j) { p.hidden = i !== j; });
      }
      function pick(i) {
        var key = btns[i].getAttribute("data-sync");
        if (key) syncAll(key); else select(i);
      }
      groups.push({ selectKey: function (key) {
        Array.prototype.forEach.call(btns, function (b, i) { if (b.getAttribute("data-sync") === key) select(i); });
      } });
      Array.prototype.forEach.call(btns, function (b, i) {
        b.addEventListener("click", function () { pick(i); });
        b.addEventListener("keydown", function (e) {
          if (e.key === "ArrowRight" || e.key === "ArrowLeft") { var n = (i + (e.key === "ArrowRight" ? 1 : btns.length - 1)) % btns.length; pick(n); btns[n].focus(); }
        });
      });
      select(0);
    });
    if (stored) groups.forEach(function (g) { g.selectKey(stored); });
    /* small screens: keep the current section of the developer navigation in view */
    var nav = document.querySelector(".devnav"), cur = nav && nav.querySelector("[aria-current=page]");
    if (nav && cur && nav.scrollWidth > nav.clientWidth) nav.scrollLeft = cur.offsetLeft - (nav.clientWidth - cur.offsetWidth) / 2;
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init); else init();
})();
