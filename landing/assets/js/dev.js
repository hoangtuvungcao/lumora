/* Lumora developer pages: tiny syntax highlighter, copy buttons, tabs, docs search (search.json) and
   on-page table of contents highlighting; tabs (Python/JavaScript choice
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
      var label = function (done) { return done ? (lang() === "en" ? "Copied" : "Đã sao chép") : (lang() === "en" ? "Copy" : "Sao chép"); };
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
        Array.prototype.forEach.call(document.querySelectorAll(".code__copy"), function (b) { b.textContent = lang() === "en" ? "Copy" : "Sao chép"; });
      }, 0);
    });
    setTimeout(function () {
      Array.prototype.forEach.call(document.querySelectorAll(".code__copy"), function (b) { b.textContent = lang() === "en" ? "Copy" : "Sao chép"; });
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
    initSearch(lang);
    initToc();
    /* collapsed (phone) menus close once a link inside them is followed */
    Array.prototype.forEach.call(document.querySelectorAll(".docs-mnav, .docs-mtoc"), function (d) {
      d.addEventListener("click", function (e) { if (e.target.closest("a")) d.open = false; });
    });
  }

  /* ---- on-page table of contents: highlight the section being read ---- */
  function initToc() {
    var links = Array.prototype.slice.call(document.querySelectorAll(".docs-toc a[href^='#']"));
    if (!links.length || !("IntersectionObserver" in window)) return;
    var byId = {}, targets = [];
    links.forEach(function (a) {
      var t = document.getElementById(decodeURIComponent(a.getAttribute("href").slice(1)));
      if (t) { byId[t.id] = a; targets.push(t); }
    });
    var visible = {};
    function mark() {
      var cur = null;
      for (var i = 0; i < targets.length; i++) { if (visible[targets[i].id]) { cur = targets[i].id; break; } }
      if (!cur) return;
      links.forEach(function (a) { a.classList.remove("is-active"); a.removeAttribute("aria-current"); });
      byId[cur].classList.add("is-active"); byId[cur].setAttribute("aria-current", "location");
    }
    var io = new IntersectionObserver(function (es) {
      es.forEach(function (e) { visible[e.target.id] = e.isIntersecting; });
      mark();
    }, { rootMargin: "-80px 0px -60% 0px" });
    targets.forEach(function (t) { io.observe(t); });
  }

  /* ---- client-side search over /developers/search.json (built with the pages) ---- */
  function fold(t) {
    return t.replace(/[đĐ]/g, "d").normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();
  }
  function initSearch(lang) {
    var input = document.getElementById("docs-q"), list = document.getElementById("docs-results");
    if (!input || !list || !window.fetch) return;
    var index = null, loading = false, items = [], sel = -1;
    function load() {
      if (index || loading) return;
      loading = true;
      fetch("/developers/search.json").then(function (r) { return r.json(); }).then(function (j) { index = j; run(); }, function () { loading = false; });
    }
    function close() { list.hidden = true; input.setAttribute("aria-expanded", "false"); input.removeAttribute("aria-activedescendant"); sel = -1; }
    function select(i) {
      sel = i;
      Array.prototype.forEach.call(list.children, function (li, j) { li.setAttribute("aria-selected", String(i === j)); });
      if (i >= 0 && list.children[i]) { input.setAttribute("aria-activedescendant", list.children[i].id); list.children[i].scrollIntoView({ block: "nearest" }); }
    }
    function run() {
      var q = fold(input.value.trim());
      if (!q) { close(); return; }
      if (!index) { load(); return; }
      var words = q.split(/\s+/), L = lang() === "en" ? 1 : 0;
      items = [];
      index.forEach(function (e) {
        var title = fold(e.t[0] + " " + e.t[1]), score = 0;
        for (var i = 0; i < words.length; i++) {
          var w = words[i];
          if (title.indexOf(w) >= 0) score += 3; else if (e.k.indexOf(w) >= 0) score += 1; else return;
        }
        if (e.u.indexOf("#") < 0) score += 1;
        items.push({ e: e, s: score });
      });
      items.sort(function (a, b) { return b.s - a.s; });
      items = items.slice(0, 8);
      list.textContent = "";
      if (!items.length) {
        var none = document.createElement("li");
        none.className = "docs-results__empty"; none.setAttribute("role", "option"); none.id = "docs-r-none";
        none.textContent = L ? "No results" : "Không tìm thấy kết quả";
        list.appendChild(none);
      }
      items.forEach(function (it, i) {
        var li = document.createElement("li"), a = document.createElement("a"), small = document.createElement("small");
        li.setAttribute("role", "option"); li.id = "docs-r-" + i;
        a.href = it.e.u; a.textContent = it.e.t[L] || it.e.t[0];
        small.textContent = it.e.p[L] || it.e.p[0];
        a.appendChild(small); li.appendChild(a); list.appendChild(li);
      });
      list.hidden = false; input.setAttribute("aria-expanded", "true"); sel = -1;
    }
    input.addEventListener("focus", load);
    input.addEventListener("input", run);
    input.addEventListener("keydown", function (e) {
      var n = items.length;
      if (e.key === "ArrowDown" && n) { e.preventDefault(); select((sel + 1) % n); }
      else if (e.key === "ArrowUp" && n) { e.preventDefault(); select((sel - 1 + n) % n); }
      else if (e.key === "Enter" && n) { e.preventDefault(); location.href = items[Math.max(sel, 0)].e.u; close(); }
      else if (e.key === "Escape") { close(); }
    });
    document.addEventListener("click", function (e) { if (!e.target.closest(".docs-search")) close(); });
    list.addEventListener("click", function (e) { if (e.target.closest("a")) close(); });
    document.addEventListener("keydown", function (e) {
      if (e.key !== "/" || e.ctrlKey || e.metaKey || e.altKey) return;
      var t = e.target, tag = t && t.tagName;
      if (tag === "INPUT" || tag === "TEXTAREA" || (t && t.isContentEditable)) return;
      e.preventDefault(); input.focus();
    });
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init); else init();
})();
