/* "Buy me a coffee" on every page: our own button linking to Ko-fi, so no third-party script runs on the site.
 * A honey pill at bottom left on desktop, a round cup at bottom right on phones. */
(function () {
  var a = document.createElement("a");
  a.className = "coffee";
  a.href = "https://ko-fi.com/kaikaushik";
  a.target = "_blank";
  a.rel = "noopener";
  a.setAttribute("aria-label", "Buy me a coffee on Ko-fi");
  a.innerHTML =
    '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 8h12v5.5A4.5 4.5 0 0 1 11.5 18h-3A4.5 4.5 0 0 1 4 13.5z"/>' +
    '<path d="M16 9.5h1.6a2.4 2.4 0 0 1 0 4.8H16"/><path d="M8.2 11.2c.9-.9 2.6-.4 1.8 1.3l-1.8 1.8-1.8-1.8c-.8-1.7.9-2.2 1.8-1.3z" class="coffee__heart"/></svg>' +
    '<span>Buy me a coffee</span>';
  function add() { document.body.appendChild(a); }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", add); else add();
})();
