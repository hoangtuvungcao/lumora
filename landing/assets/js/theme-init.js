/* Runs before first paint: apply a saved theme/lang choice to avoid a flash. */
(function () {
  var d = document.documentElement, t = null, l = null;
  d.className += " js";
  try { t = localStorage.getItem("lumora-theme"); l = localStorage.getItem("lumora-lang"); } catch (e) {}
  if (t === "light" || t === "dark") d.setAttribute("data-theme", t);
  var q = /[?&]lang=(en|vi)\b/.exec(location.search);
  if (q) l = q[1];
  if (l === "en") {
    /* styles.css hides the page while this is set; app.js removes it once English is applied.
       Failsafe: never keep the page hidden for more than 800 ms (e.g. if app.js fails to load). */
    d.setAttribute("data-lang-pending", "en");
    setTimeout(function () { d.removeAttribute("data-lang-pending"); }, 800);
  }
})();
