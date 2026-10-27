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

  /* ---------- Theme: light / dark with a radial wipe from the toggle ---------- */
  var THEME_MS = 1500;
  var themeBtn = document.querySelector("[data-theme-toggle]");
  var themeMeta = document.querySelector('meta[name="theme-color"]');
  function currentTheme() { return doc.getAttribute("data-theme") === "light" ? "light" : "dark"; }
  function syncThemeUI() {
    var t = currentTheme();
    if (themeBtn) themeBtn.setAttribute("aria-label", t === "dark" ? "Switch to light theme" : "Switch to dark theme");
    if (themeMeta) themeMeta.setAttribute("content", t === "dark" ? "#16130F" : "#FBF7F0");
  }
  function writeTheme(t, persist) {
    doc.setAttribute("data-theme", t);
    if (persist) { try { localStorage.setItem("mb-theme", t); } catch (e) {} }
    syncThemeUI();
  }
  function toggleTheme(origin) {
    var next = currentTheme() === "dark" ? "light" : "dark";
    if (reduceMQ.matches) { writeTheme(next, true); return; }
    if (document.startViewTransition) {
      var x = origin ? origin.x : window.innerWidth / 2;
      var y = origin ? origin.y : window.innerHeight / 2;
      var end = Math.hypot(Math.max(x, window.innerWidth - x), Math.max(y, window.innerHeight - y));
      doc.classList.add("theme-wipe");
      var vt = document.startViewTransition(function () { writeTheme(next, true); });
      vt.ready.then(function () {
        doc.animate(
          { "--transition-x": [x + "px", x + "px"], "--transition-y": [y + "px", y + "px"], "--transition-radius": ["0px", (end + 80) + "px"] },
          { duration: THEME_MS, easing: "cubic-bezier(0.4, 0, 0.2, 1)", pseudoElement: "::view-transition-new(root)", fill: "forwards" }
        );
      }).catch(function () {});
      vt.finished.finally(function () { doc.classList.remove("theme-wipe"); });
      return;
    }
    doc.classList.add("theme-fade");
    writeTheme(next, true);
    setTimeout(function () { doc.classList.remove("theme-fade"); }, 400);
  }
  if (themeBtn) {
    themeBtn.addEventListener("click", function (e) {
      var r = themeBtn.getBoundingClientRect();
      // keyboard activation has no pointer position: start from the button's centre
      var o = (e.detail && e.clientX) ? { x: e.clientX, y: e.clientY } : { x: r.left + r.width / 2, y: r.top + r.height / 2 };
      toggleTheme(o);
    });
  }
  // follow the system theme until the visitor picks one
  if (window.matchMedia) {
    var schemeMQ = window.matchMedia("(prefers-color-scheme: light)");
    var onScheme = function (e) {
      var saved = null;
      try { saved = localStorage.getItem("mb-theme"); } catch (err) {}
      if (saved !== "light" && saved !== "dark") writeTheme(e.matches ? "light" : "dark", false);
    };
    if (schemeMQ.addEventListener) schemeMQ.addEventListener("change", onScheme);
  }
  syncThemeUI();

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

  /* ---------- Hero demo: one spoken sentence, cleaned up in place ---------- */
  var line = document.querySelector("[data-say]");
  var bar = document.querySelector("[data-demo-bar]");
  var say = document.querySelector(".say");

  var TOKENS = [
    { words: ["Um,", "so"], tip: "Removes unneeded words", dir: "up" },
    { words: ["can"], cap: "C" },
    { words: ["we"] },
    { words: ["move,"], tip: "Delivers intent", dir: "down" },
    { words: ["sync"] }, { words: ["the"] }, { words: ["meeting"] }, { words: ["to"] },
    { words: ["tuesday,", "sorry,"], tip: "Corrects your mistakes", dir: "up" },
    { words: ["wednesday?"], cap: "W" }
  ];
  var nodes = [], subs = [], caps = [];
  var timers = [];
  var demoRunning = false;
  function later(fn, ms) { timers.push(setTimeout(fn, ms)); }
  function clearTimers() { timers.forEach(clearTimeout); timers = []; }
  function setBar(state) { if (bar) bar.className = "fbar" + (state ? " is-" + state : ""); }
  function el(tag, cls, txt) { var e = document.createElement(tag); if (cls) e.className = cls; if (txt != null) e.textContent = txt; return e; }

  function build() {
    line.textContent = "";
    line.classList.remove("is-fading");
    nodes = []; subs = []; caps = [];
    TOKENS.forEach(function (tok) {
      var w = el("span", "w");
      tok.words.forEach(function (word, i) {
        if (i) w.appendChild(document.createTextNode(" "));
        var sub = el("span", "ww");
        if (tok.cap && i === 0) {
          var cap = el("span", "cap");
          cap.appendChild(el("i", "cap__base", word.charAt(0)));
          cap.appendChild(el("i", "cap__alt", tok.cap));
          sub.appendChild(cap);
          sub.appendChild(document.createTextNode(word.slice(1)));
          caps.push(cap);
        } else {
          sub.textContent = word;
        }
        w.appendChild(sub);
        subs.push(sub);
      });
      line.appendChild(w);
      nodes.push({ el: w, tok: tok });
    });
    fitOneLine();
    // desktop: lock to the raw (longest) sentence so nothing below moves;
    // phones: ease the height between raw and clean so there is no big empty gap
    fitHeight(built && isNarrow());
    built = true;
  }
  var built = false;

  // Desktop: the whole spoken sentence sits on one line, shrinking to fit, so nothing reflows as it's cleaned.
  function fitOneLine() {
    line.style.fontSize = "";
    if (isNarrow()) { line.style.whiteSpace = ""; return; }
    line.style.whiteSpace = "nowrap";
    var need = line.scrollWidth, have = line.clientWidth;
    if (need > have) {
      line.style.fontSize = (parseFloat(getComputedStyle(line).fontSize) * have / need * 0.98) + "px";
    }
  }
  // same breakpoint as the stylesheet (window.innerWidth can read desktop-wide on iOS while loading)
  var narrowMQ = window.matchMedia("(max-width: 639.98px)");
  function isNarrow() { return narrowMQ.matches; }
  function fitHeight(animate) {
    var cur = line.offsetHeight;
    line.style.transition = "none";
    line.style.minHeight = "0px";
    var nat = line.offsetHeight;
    if (!animate) { line.style.minHeight = nat + "px"; void line.offsetWidth; line.style.transition = ""; return; }
    line.style.minHeight = cur + "px";
    void line.offsetWidth;
    line.style.transition = "";
    line.style.minHeight = nat + "px";
  }

  function strike(n) {
    // above on the first line, below elsewhere (and always below on phones), so bubbles never collide
    var firstLine = n.el.offsetTop <= nodes[0].el.offsetTop + 4;
    var dir = (!isNarrow() && firstLine) ? "up" : "down";
    n.dir = dir;
    n.el.classList.add("is-struck");
    var tip = el("span", "tip tip--" + dir, n.tok.tip);
    n.el.appendChild(tip);
    var lr = line.getBoundingClientRect(), tr = tip.getBoundingClientRect();
    if (tr.right > lr.right) tip.classList.add("tip--end");
    // never let two labels overlap: an earlier label in the way fades out as the new one arrives
    tr = tip.getBoundingClientRect();
    line.querySelectorAll(".tip.is-on").forEach(function (old) {
      var o = old.getBoundingClientRect();
      if (o.left < tr.right + 8 && tr.left < o.right + 8 && o.top < tr.bottom + 4 && tr.top < o.bottom + 4) old.classList.remove("is-on");
    });
    requestAnimationFrame(function () { tip.classList.add("is-on"); });
  }

  function settle(animate) {
    var kept = nodes.filter(function (n) { return !n.tok.tip; });
    var first = kept.map(function (n) { return n.el.getBoundingClientRect(); });
    nodes.forEach(function (n) { if (n.tok.tip) n.el.classList.add("is-gone"); });
    caps.forEach(function (c) { c.classList.add("is-up"); });
    if (!animate) return;
    kept.forEach(function (n, i) {
      var last = n.el.getBoundingClientRect();
      n.el.style.transition = "none";
      n.el.style.transform = "translate(" + (first[i].left - last.left) + "px," + (first[i].top - last.top) + "px)";
    });
    void line.offsetWidth;
    kept.forEach(function (n) {
      n.el.style.transition = "";
      n.el.classList.add("is-settle");
      n.el.style.transform = "";
    });
    if (isNarrow()) fitHeight(true);
    else liftBar(kept);
  }

  // Once the cleaned sentence is shorter, the flow bar glides up under its last line instead of leaving a gap.
  var sayBar = document.querySelector(".say__bar");
  function liftBar(kept) {
    if (!sayBar || !kept.length) return;
    var bottom = 0;
    kept.forEach(function (n) { bottom = Math.max(bottom, n.el.offsetTop + n.el.offsetHeight); });
    var padB = parseFloat(getComputedStyle(line).paddingBottom) || 0;
    var d = Math.max(0, line.offsetTop + line.offsetHeight - padB - bottom);
    sayBar.style.transform = d ? "translateY(" + (-d) + "px)" : "";
  }

  function cycle() {
    if (!demoRunning) return;
    if (sayBar) sayBar.style.transform = "";
    build();
    setBar("");
    var t = 700;
    later(function () { setBar("listening"); }, t);
    t += 400;
    subs.forEach(function (sub, k) { later(function () { sub.classList.add("is-on"); }, t + k * 300); });
    t += subs.length * 300 + 400;
    later(function () { setBar("finishing"); }, t);
    t += 300;
    var cuts = nodes.filter(function (n) { return n.tok.tip; });
    cuts.forEach(function (n, j) { later(function () { strike(n); }, t + j * 850); });
    t += cuts.length * 850 + 900;
    later(function () { cuts.forEach(function (n) { n.el.classList.add("is-out", n.dir === "up" ? "tip-up" : "tip-down"); }); }, t);
    t += 500;
    later(function () { settle(true); }, t);
    t += 900;
    later(function () { setBar(""); }, t);
    t += 3200;
    later(function () { line.classList.add("is-fading"); }, t);
    t += 600;
    later(cycle, t);
  }
  function startDemo() { if (demoRunning) return; demoRunning = true; cycle(); }
  function stopDemo() { demoRunning = false; clearTimers(); }
  var hint = document.querySelector(".scrollhint");
  if (hint) {
    var hideHint = function () { hint.classList.toggle("is-hidden", window.scrollY > 60); };
    window.addEventListener("scroll", hideHint, { passive: true }); window.addEventListener("load", hideHint); hideHint();
  }
  var replay = document.querySelector("[data-replay]");
  if (replay && !reduced) replay.addEventListener("click", function () { stopDemo(); startDemo(); });

  function showStatic() {
    build();
    subs.forEach(function (s2) { s2.classList.add("is-on"); });
    settle(false);
    fitHeight(false);
    var before = el("p", "say__before");
    before.innerHTML = "<s>Um, so</s> can we <s>move,</s> sync the meeting to <s>tuesday, sorry,</s> wednesday?";
    line.parentNode.insertBefore(before, line);
  }

  if (line && say) {
    if (reduced) {
      showStatic();
    } else if ("IntersectionObserver" in window) {
      var sayVisible = false;
      new IntersectionObserver(function (entries) {
        entries.forEach(function (e) { sayVisible = e.isIntersecting; sayVisible ? startDemo() : stopDemo(); });
      }, { threshold: 0.3 }).observe(say);
      document.addEventListener("visibilitychange", function () {
        if (document.hidden) stopDemo();
        else if (sayVisible) startDemo();
      });
      if (narrowMQ.addEventListener) narrowMQ.addEventListener("change", function () { if (demoRunning) { stopDemo(); startDemo(); } });
      var lastW = window.innerWidth, sayResize;
      window.addEventListener("resize", function () {
        if (window.innerWidth === lastW) return;
        lastW = window.innerWidth;
        clearTimeout(sayResize);
        sayResize = setTimeout(function () { if (demoRunning) { stopDemo(); startDemo(); } }, 200);
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

// Feature examples: what you said transforms into what MurmurBee typed, slowly, looping while on screen.
(function () {
  var groups = document.querySelectorAll("[data-morph]");
  if (!groups.length) return;
  // Each word folds and unfolds from its real width (a rough cap makes short words snap and long ones lag).
  function measure(g) {
    // Measure in the starting state, so the box can reserve the tallest (spoken) version: nothing below moves.
    var cls = ["is-strike", "is-done", "is-reset"].filter(function (c) { return g.classList.contains(c); });
    g.classList.remove("is-strike", "is-done", "is-reset");
    g.style.minHeight = "";
    g.querySelectorAll(".learn__line span").forEach(function (sp) {
      sp.style.setProperty("--w", "none");
      sp.style.maxWidth = "none";
      var w = sp.scrollWidth;
      sp.style.maxWidth = "";
      sp.style.setProperty("--w", Math.ceil(w + 2) + "px");
    });
    var spoken = g.offsetHeight;
    g.classList.add("is-done");
    var typed = g.offsetHeight;
    g.classList.remove("is-done");
    g.style.minHeight = Math.max(spoken, typed) + "px";
    cls.forEach(function (c) { g.classList.add(c); });
    // the strike sweeps across the cut words one after another
    g.querySelectorAll(".m-cut").forEach(function (sp, i) { sp.style.setProperty("--sd", (i * 0.45) + "s"); });
  }
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
    groups.forEach(function (g) { measure(g); g.classList.add("is-strike", "is-done"); });
    return;
  }
  function loop(g) {
    if (!g._on) { g._running = false; return; }
    g._running = true;
    g.classList.remove("is-strike", "is-done", "is-reset");
    measure(g);  // every loop, while the line is faded out: widths stay right after late fonts, zoom or resize
    var cuts = g.querySelectorAll(".m-cut").length;
    var t = 2200;                                   // read what was said
    setTimeout(function () { g.classList.add("is-strike"); }, t);
    t += 900 + cuts * 450 + 500;                    // strikes draw, one after another
    setTimeout(function () { g.classList.add("is-done"); }, t);
    t += 1600 + 4200;                               // fold, arrive, then hold the clean sentence
    setTimeout(function () { g.classList.add("is-reset"); }, t);
    t += 1000;                                      // soft fade before the next loop
    setTimeout(function () { loop(g); }, t);
  }
  var io = new IntersectionObserver(function (entries) {
    entries.forEach(function (e) {
      e.target._on = e.isIntersecting;
      if (e.isIntersecting && !e.target._running) loop(e.target);
    });
  }, { threshold: 0.4 });
  // Measure once the web fonts are in (otherwise widths are for the fallback font and words get clipped).
  (document.fonts && document.fonts.ready ? document.fonts.ready : Promise.resolve()).then(function () {
    groups.forEach(function (g) { measure(g); io.observe(g); });
  });
  var rt;
  function remeasure() { clearTimeout(rt); rt = setTimeout(function () { groups.forEach(measure); }, 200); }
  window.addEventListener("resize", remeasure);
  // fonts.ready can resolve before a font this text needs has even started loading; re-measure when it lands
  if (document.fonts && document.fonts.addEventListener) document.fonts.addEventListener("loadingdone", remeasure);
})();
