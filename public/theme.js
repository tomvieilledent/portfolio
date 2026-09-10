/* Bascule clair / sombre, persistée (localStorage). Sans préférence
   enregistrée, on suit le système. Chargé en <head> (bloquant) : le
   data-theme est posé avant le 1er rendu, donc pas de flash. */
(function () {
  var KEY = "vlldnt:theme";
  var root = document.documentElement;
  var mq = window.matchMedia("(prefers-color-scheme: dark)");

  function stored() { try { return localStorage.getItem(KEY); } catch (e) { return null; } }
  function effective() {
    var s = stored();
    return s === "light" || s === "dark" ? s : (mq.matches ? "dark" : "light");
  }
  function apply(v) {
    if (v === "light" || v === "dark") root.setAttribute("data-theme", v);
    else root.removeAttribute("data-theme");
  }
  apply(stored());

  document.addEventListener("DOMContentLoaded", function () {
    var btn = document.getElementById("theme-toggle");
    if (!btn) return;
    function refresh() {
      var cur = effective();
      btn.dataset.theme = cur;
      btn.setAttribute("aria-label", cur === "dark" ? "Passer en mode clair" : "Passer en mode sombre");
    }
    btn.hidden = false;
    refresh();
    btn.addEventListener("click", function () {
      var next = effective() === "dark" ? "light" : "dark";
      apply(next);
      try { localStorage.setItem(KEY, next); } catch (e) {}
      refresh();
    });
  });

  // Si l'utilisateur n'a pas fait de choix, suivre les changements système.
  mq.addEventListener && mq.addEventListener("change", function () {
    if (!stored()) { apply(null); var b = document.getElementById("theme-toggle"); if (b) b.dataset.theme = effective(); }
  });
})();
