/* "Buy me a coffee" on every page. Clicking opens Ko-fi's tipping panel in a pop-up; nothing from Ko-fi loads until
 * then (privacy, and the site's Content-Security-Policy only allows Ko-fi as a frame). A honey pill at bottom left on
 * desktop, a round cup at bottom right on phones. Middle-click or a blocked frame still reaches Ko-fi via the link. */
(function () {
  var KOFI = "https://ko-fi.com/kaikaushik";
  var a = document.createElement("a");
  a.className = "coffee";
  a.href = KOFI;
  a.target = "_blank";
  a.rel = "noopener";
  a.setAttribute("aria-haspopup", "dialog");
  a.setAttribute("aria-label", "Buy me a coffee");
  a.innerHTML =
    '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 8h12v5.5A4.5 4.5 0 0 1 11.5 18h-3A4.5 4.5 0 0 1 4 13.5z"/>' +
    '<path d="M16 9.5h1.6a2.4 2.4 0 0 1 0 4.8H16"/><path d="M8.2 11.2c.9-.9 2.6-.4 1.8 1.3l-1.8 1.8-1.8-1.8c-.8-1.7.9-2.2 1.8-1.3z" class="coffee__heart"/></svg>' +
    '<span>Buy me a coffee</span>';

  var panel = null;
  function open() {
    if (!panel) {
      panel = document.createElement("div");
      panel.className = "coffee-panel";
      panel.setAttribute("role", "dialog");
      panel.setAttribute("aria-label", "Buy me a coffee on Ko-fi");
      panel.innerHTML =
        '<button class="coffee-panel__close" type="button" aria-label="Close">' +
        '<svg viewBox="0 0 12 12" aria-hidden="true"><path d="M2 2l8 8M10 2l-8 8"/></svg></button>' +
        '<iframe title="Ko-fi" src="' + KOFI + '/?hidefeed=true&widget=true&embed=true" loading="eager"></iframe>';
      panel.querySelector(".coffee-panel__close").addEventListener("click", close);
      document.body.appendChild(panel);
    }
    requestAnimationFrame(function () { panel.classList.add("is-open"); });
    a.setAttribute("aria-expanded", "true");
  }
  function close() {
    if (!panel) return;
    panel.classList.remove("is-open");
    a.setAttribute("aria-expanded", "false");
    a.focus();
  }
  a.addEventListener("click", function (e) {
    if (e.metaKey || e.ctrlKey || e.shiftKey || e.button === 1) return;  // new-tab clicks just follow the link
    e.preventDefault();
    if (panel && panel.classList.contains("is-open")) close(); else open();
  });
  document.addEventListener("keydown", function (e) { if (e.key === "Escape") close(); });

  function add() { document.body.appendChild(a); }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", add); else add();
})();
