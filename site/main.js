/* MurmurBee — small progressive enhancements. No dependencies. */
(function () {
  "use strict";

  var doc = document.documentElement;
  doc.classList.add("js");
  var reduceMQ = window.matchMedia("(prefers-reduced-motion: reduce)");
  var reduced = reduceMQ.matches;

  /* ---------- Nav border on scroll ---------- */
  var nav = document.querySelector(".nav");
  function onScrollNav() {
    if (nav) nav.classList.toggle("is-scrolled", window.scrollY > 8);
  }

  /* ---------- Placeholder download link (DMG not published yet) ---------- */
  document.querySelectorAll('a[href="#"]').forEach(function (a) {
    a.addEventListener("click", function (e) { e.preventDefault(); });
  });

  /* ---------- Reveal on scroll ---------- */
  var revealTargets = document.querySelectorAll(".section__head, .intro__title, .band__head, .band__visual, .privacy__list li, .faq__list, .download__inner");
  if ("IntersectionObserver" in window && !reduced) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { e.target.classList.add("is-in"); io.unobserve(e.target); }
      });
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.08 });
    revealTargets.forEach(function (el) { el.classList.add("reveal"); io.observe(el); });
  }

  /* ---------- Charts: run once when scrolled into view ---------- */
  var charts = document.querySelectorAll("[data-race], [data-wpm]");
  if (reduced || !("IntersectionObserver" in window)) {
    charts.forEach(function (c) { c.classList.add("is-run"); });
  } else {
    var chartIO = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { e.target.classList.add("is-run"); chartIO.unobserve(e.target); }
      });
    }, { threshold: 0.45 });
    charts.forEach(function (c) { chartIO.observe(c); });
  }

  /* 100-word accuracy grid: ~97–98 of every 100 words right */
  var grid = document.querySelector("[data-acc-grid]");
  if (grid) {
    var frag = document.createDocumentFragment();
    for (var g = 0; g < 100; g++) {
      var dot = document.createElement("i");
      if (g === 97) dot.className = "is-mid";
      else if (g > 97) dot.className = "is-off";
      frag.appendChild(dot);
    }
    grid.appendChild(frag);
  }

  /* ---------- Hero scene: dictating into Mail ---------- */
  var bar = document.querySelector("[data-demo-bar]");
  var field = document.querySelector("[data-demo-text]");

  var WORDS = ["um", "so", "can", "we", "move", "the", "sync", "to", "tuesday,", "sorry,", "wednesday", "at", "3"];
  var CUT = { 0: 1, 1: 1, 8: 1, 9: 1 };
  var CLEAN = "Can we move the sync to Wednesday at 3?";

  var timers = [];
  var demoRunning = false;
  function later(fn, ms) { timers.push(setTimeout(fn, ms)); }
  function clearTimers() { timers.forEach(clearTimeout); timers = []; }
  function setBar(state) { bar.className = "fbar" + (state ? " is-" + state : ""); }

  function renderRaw(n, cut) {
    field.className = "dictation__text is-raw";
    field.textContent = "";
    for (var i = 0; i < n; i++) {
      var el = document.createElement(cut && CUT[i] ? "s" : "span");
      el.textContent = WORDS[i];
      field.appendChild(el);
      if (i < n - 1) field.appendChild(document.createTextNode(" "));
    }
  }
  function renderClean() {
    field.className = "dictation__text";
    field.textContent = CLEAN;
    void field.offsetWidth;
    field.classList.add("is-clean");
  }

  function cycle() {
    if (!demoRunning) return;
    setBar("");
    field.textContent = "";
    var t = 1400;
    later(function () { setBar("listening"); }, t);
    t += 500;
    WORDS.forEach(function (_, i) { later(function () { renderRaw(i + 1, false); }, t + i * 300); });
    t += WORDS.length * 300 + 500;
    later(function () { setBar("finishing"); renderRaw(WORDS.length, true); }, t);
    t += 900;
    later(function () { setBar(""); renderClean(); }, t);
    t += 4200;
    later(cycle, t);
  }
  function startDemo() { if (demoRunning) return; demoRunning = true; cycle(); }
  function stopDemo() { demoRunning = false; clearTimers(); }

  if (bar && field) {
    var scene = document.querySelector(".scene");
    if (reduced) {
      renderClean();
    } else if ("IntersectionObserver" in window) {
      new IntersectionObserver(function (entries) {
        entries.forEach(function (e) { e.isIntersecting ? startDemo() : stopDemo(); });
      }, { threshold: 0.3 }).observe(scene);
      document.addEventListener("visibilitychange", function () {
        if (document.hidden) stopDemo();
        else {
          var r = scene.getBoundingClientRect();
          if (r.bottom > 0 && r.top < window.innerHeight) startDemo();
        }
      });
    } else {
      startDemo();
    }
  }

  /* ---------- Dotted flight trail (How it works) ---------- */
  var stage = document.querySelector("[data-trail]");
  var svg = stage && stage.querySelector(".trail");
  var trailState = null;

  function f(n) { return Math.round(n * 10) / 10; }
  function P(x, y) { return f(x) + " " + f(y); }

  function buildTrail() {
    if (!svg) return;
    var sr = stage.getBoundingClientRect();
    var W = sr.width, H = sr.height;
    var nums = stage.querySelectorAll(".step__num");
    var nodes = Array.prototype.map.call(nums, function (n) {
      var r = n.getBoundingClientRect();
      return { x: r.left - sr.left + r.width / 2, y: r.top - sr.top + r.height / 2 };
    });
    if (nodes.length !== 3) return;
    var a = nodes[0], b = nodes[1], c = nodes[2];
    var wide = Math.abs(a.y - c.y) < 4; // horizontal layout
    var d = "", end;

    if (wide) {
      var Y = a.y, gap = b.x - a.x, mid = a.x + gap / 2;
      var r = Math.min(40, gap * 0.11), k = r * 0.5523;
      var By = Y - 62, Yc = By - r;
      var sx = Math.max(10, a.x - gap * 0.55), sy = Y - 96;
      end = { x: Math.min(W - 40, c.x + gap * 0.48), y: Y - 108 };
      d = "M " + P(sx, sy) +
        " C " + P(sx + gap * 0.22, sy) + " " + P(a.x - gap * 0.22, Y) + " " + P(a.x, Y) +
        // to the bottom of the loop
        " C " + P(a.x + gap * 0.24, Y) + " " + P(mid - gap * 0.2, By) + " " + P(mid, By) +
        // a little counter-clockwise loop
        " C " + P(mid + k, By) + " " + P(mid + r, Yc + k) + " " + P(mid + r, Yc) +
        " C " + P(mid + r, Yc - k) + " " + P(mid + k, Yc - r) + " " + P(mid, Yc - r) +
        " C " + P(mid - k, Yc - r) + " " + P(mid - r, Yc - k) + " " + P(mid - r, Yc) +
        " C " + P(mid - r, Yc + k) + " " + P(mid - k, By) + " " + P(mid, By) +
        // down into step 2
        " C " + P(mid + gap * 0.2, By) + " " + P(b.x - gap * 0.24, Y) + " " + P(b.x, Y) +
        // gentle arc up and over into step 3
        " C " + P(b.x + gap * 0.32, Y - 118) + " " + P(c.x - gap * 0.32, Y - 118) + " " + P(c.x, Y) +
        // lift off toward the bee
        " C " + P(c.x + gap * 0.18, Y + 8) + " " + P(end.x - gap * 0.2, end.y + 40) + " " + P(end.x, end.y);
    } else {
      var x = a.x, sway = 22;
      var top = Math.max(0, a.y - 70);
      end = { x: x + 4, y: H - 24 };
      function seg(p, q, dir) {
        var h = q.y - p.y;
        return " C " + P(p.x + sway * dir, p.y + h * 0.3) + " " + P(q.x + sway * dir, q.y - h * 0.3) + " " + P(q.x, q.y);
      }
      // small loop between step 1 and 2
      var ly = a.y + (b.y - a.y) / 2, lr = 13, lk = lr * 0.5523, lx = x + lr;
      d = "M " + P(x, top) + seg({ x: x, y: top }, a, -1) +
        " C " + P(x, a.y + (ly - a.y) * 0.5) + " " + P(x, ly - 10) + " " + P(x, ly) +
        // loop (circle to the right of the line)
        " C " + P(x, ly + lk) + " " + P(lx - lk, ly + lr) + " " + P(lx, ly + lr) +
        " C " + P(lx + lk, ly + lr) + " " + P(lx + lr, ly + lk) + " " + P(lx + lr, ly) +
        " C " + P(lx + lr, ly - lk) + " " + P(lx + lk, ly - lr) + " " + P(lx, ly - lr) +
        " C " + P(lx - lk, ly - lr) + " " + P(x, ly - lk) + " " + P(x, ly) +
        " C " + P(x, ly + 10) + " " + P(x, b.y - (b.y - ly) * 0.5) + " " + P(b.x, b.y) +
        seg(b, c, 1) +
        " C " + P(x - sway, c.y + 60) + " " + P(end.x - sway, end.y - 50) + " " + P(end.x, end.y);
    }

    svg.setAttribute("viewBox", "0 0 " + f(W) + " " + f(H));
    var mask = svg.querySelector("mask");
    mask.setAttribute("x", "-50"); mask.setAttribute("y", "-50");
    mask.setAttribute("width", f(W + 100)); mask.setAttribute("height", f(H + 100));
    svg.querySelectorAll("path").forEach(function (p) { p.setAttribute("d", d); });

    var reveal = svg.querySelector(".trail__reveal");
    var len = reveal.getTotalLength();
    reveal.style.strokeDasharray = len + " " + (len + 40);

    // path length at each step node, so steps light up as the bee passes
    var marks = nodes.map(function (n) {
      var best = 0, bestD = Infinity;
      for (var s = 0; s <= 300; s++) {
        var L = (s / 300) * len, pt = reveal.getPointAtLength(L);
        var dd = (pt.x - n.x) * (pt.x - n.x) + (pt.y - n.y) * (pt.y - n.y);
        if (dd < bestD) { bestD = dd; best = L; }
      }
      return best;
    });

    trailState = { len: len, reveal: reveal, marks: marks, steps: stage.querySelectorAll(".step"), bee: stage.querySelector("[data-trail-bee]") };
    stage.classList.add("is-ready");
    updateTrail();
  }

  function updateTrail() {
    if (!trailState) return;
    var p;
    if (reduced) {
      p = 1;
    } else {
      var r = stage.getBoundingClientRect(), vh = window.innerHeight;
      var startAt = vh * 0.85, endAt = vh * 0.55;
      p = (startAt - r.top) / (r.height + startAt - endAt);
      p = Math.max(0, Math.min(1, p));
    }
    var s = trailState, L = Math.max(0.001, s.len * p);
    s.reveal.style.strokeDashoffset = f(s.len - L);

    var pt = s.reveal.getPointAtLength(L);
    var ahead = s.reveal.getPointAtLength(Math.min(s.len, L + 6));
    var behind = s.reveal.getPointAtLength(Math.max(0, L - 6));
    var ang = Math.atan2(ahead.y - behind.y, ahead.x - behind.x) * 180 / Math.PI;
    // the artwork already flies up-and-right (~-28deg), so rotate relative to that
    var flip = Math.abs(ang) > 100;
    var heading = flip ? (ang > 0 ? 180 - ang : -180 - ang) : ang;
    var tilt = Math.max(-24, Math.min(24, heading + 28));
    if (flip) tilt = -tilt;
    if (s.bee) {
      s.bee.style.transform = "translate(" + f(pt.x) + "px," + f(pt.y) + "px) rotate(" + f(tilt) + "deg)" + (flip ? " scaleX(-1)" : "");
    }
    s.steps.forEach(function (step, i) { step.classList.toggle("is-lit", L >= s.marks[i] - 2); });
  }

  /* ---------- Scroll / resize plumbing ---------- */
  var ticking = false;
  function onScroll() {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(function () { ticking = false; onScrollNav(); updateTrail(); });
  }
  var resizeT;
  function onResize() { clearTimeout(resizeT); resizeT = setTimeout(buildTrail, 120); }

  window.addEventListener("scroll", onScroll, { passive: true });
  window.addEventListener("resize", onResize);
  onScrollNav();

  function initTrail() { buildTrail(); }
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(initTrail);
  else window.addEventListener("load", initTrail);
  window.addEventListener("load", buildTrail);

  if (reduceMQ.addEventListener) {
    reduceMQ.addEventListener("change", function (e) { reduced = e.matches; updateTrail(); });
  }
})();
