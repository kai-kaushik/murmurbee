/* Set the theme before first paint: saved choice, else the system preference. Loaded without defer, on purpose. */
(function () {
  var t = null;
  try { t = localStorage.getItem("mb-theme"); } catch (e) {}
  if (t !== "light" && t !== "dark") t = window.matchMedia && matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
  document.documentElement.setAttribute("data-theme", t);
})();
