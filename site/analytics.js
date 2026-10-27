/* Website analytics with consent.
 *
 * Before anyone answers the cookie banner (and after "no thanks"), PostHog runs cookieless: it keeps its ids in
 * memory only, so visits and clicks are counted but nothing is stored on the device. After "OK", PostHog switches to
 * normal persistence and session recordings, and Google Analytics loads. The choice is kept in localStorage.
 *
 * These keys are public by design: they can only send events, not read data.
 */
(function () {
  var POSTHOG_KEY = "phc_AxA9apJcmvy3nG3sdzsoQ8ictiL6Q7h38A9pgh2gQRjX";
  var POSTHOG_HOST = "https://eu.i.posthog.com";
  var GA_ID = "G-LBW0248SL5";
  var CHOICE_KEY = "mb-cookies";  // "yes" | "no"

  var local = /^(localhost|127\.0\.0\.1|\[::1\])$/.test(location.hostname);
  if (!POSTHOG_KEY || !GA_ID) {
    if (local) throw new Error("POSTHOG_KEY / GA_ID variable required by PostHog is missing or un-configured, this causes events to be silently missed. This error stops appearing once POSTHOG_KEY / GA_ID is configured");
    return;
  }

  function getChoice() { try { return localStorage.getItem(CHOICE_KEY); } catch (e) { return null; } }
  function setChoice(v) { try { localStorage.setItem(CHOICE_KEY, v); } catch (e) {} }
  var choice = getChoice();

  // ---- PostHog (official snippet) ----
  !function(t,e){var o,n,p,r;e.__SV||(window.posthog=e,e._i=[],e.init=function(i,s,a){function g(t,e){var o=e.split(".");2==o.length&&(t=t[o[0]],e=o[1]),t[e]=function(){t.push([e].concat(Array.prototype.slice.call(arguments,0)))}}(p=t.createElement("script")).type="text/javascript",p.crossOrigin="anonymous",p.async=!0,p.src=s.api_host.replace(".i.posthog.com","-assets.i.posthog.com")+"/static/array.js",(r=t.getElementsByTagName("script")[0]).parentNode.insertBefore(p,r);var u=e;for(void 0!==a?u=e[a]=[]:a="posthog",u.people=u.people||[],Object.defineProperty(u,"toString",{configurable:!0,enumerable:!0,writable:!0,value:function(t){var e="posthog";return"posthog"!==a&&(e+="."+a),t||(e+=" (stub)"),e}}),Object.defineProperty(u.people,"toString",{configurable:!0,enumerable:!0,writable:!0,value:function(){return u.toString(1)+".people (stub)"}}),o="init capture register register_once register_for_session unregister unregister_for_session getFeatureFlag getFeatureFlagResult isFeatureEnabled reloadFeatureFlags updateEarlyAccessFeatureEnrollment getEarlyAccessFeatures on onFeatureFlags onSessionId getSurveys getActiveMatchingSurveys renderSurvey canRenderSurvey getNextSurveyStep identify setPersonProperties group resetGroups setPersonPropertiesForFlags resetPersonPropertiesForFlags setGroupPropertiesForFlags resetGroupPropertiesForFlags reset get_distinct_id getGroups get_session_id get_session_replay_url alias set_config startSessionRecording stopSessionRecording sessionRecordingStarted captureException loadToolbar get_property getSessionProperty createPersonProfile opt_in_capturing opt_out_capturing has_opted_in_capturing has_opted_out_capturing clear_opt_in_out_capturing debug".split(" "),n=0;n<o.length;n++)g(u,o[n]);e._i.push([i,s,a])},e.__SV=1)}(document,window.posthog||[]);

  posthog.init(POSTHOG_KEY, {
    api_host: POSTHOG_HOST,
    person_profiles: "identified_only",
    persistence: choice === "yes" ? "localStorage+cookie" : "memory",
    disable_session_recording: choice !== "yes",
    capture_pageview: true,
    capture_pageleave: true
  });

  // ---- Google Analytics: only after "OK" ----
  var gaLoaded = false;
  function loadGA() {
    if (gaLoaded) return;
    gaLoaded = true;
    var s = document.createElement("script");
    s.async = true;
    s.src = "https://www.googletagmanager.com/gtag/js?id=" + GA_ID;
    document.head.appendChild(s);
    window.dataLayer = window.dataLayer || [];
    window.gtag = function () { dataLayer.push(arguments); };
    gtag("js", new Date());
    gtag("config", GA_ID);
  }

  function accept() {
    setChoice("yes");
    posthog.set_config({ persistence: "localStorage+cookie" });
    posthog.startSessionRecording();
    loadGA();
    posthog.capture("cookies_answered", { choice: "yes" });
  }
  function decline() {
    setChoice("no");
    posthog.capture("cookies_answered", { choice: "no" });
  }
  if (choice === "yes") loadGA();

  // ---- Named events (autocapture records every click too; these make the funnels easy to read) ----
  function track(name, props) {
    posthog.capture(name, props);
    if (gaLoaded && window.gtag) gtag("event", name, props);
  }
  function placement(el) {
    if (el.closest(".nav")) return "nav";
    var sec = el.closest("section[id], section[class]");
    if (sec) return sec.id || sec.className.split(" ").pop();
    return el.closest("footer") ? "footer" : "page";
  }
  document.addEventListener("click", function (e) {
    var a = e.target.closest && e.target.closest("a, button, summary");
    if (!a) return;
    var href = a.getAttribute("href") || "";
    if (/\.dmg($|\?)/.test(href)) track("download_clicked", { placement: placement(a), page: location.pathname });
    else if (/github\.com\/kai-kaushik\/murmurbee\/?$/.test(href)) track("github_clicked", { placement: placement(a), page: location.pathname });
    else if (/ko-fi\.com/.test(href)) track("tip_clicked", { placement: placement(a) });
    else if (a.tagName === "SUMMARY" && a.closest(".faq")) {
      if (!a.parentNode.open) track("faq_opened", { question: a.textContent.trim() });
    }
    else if (a.hasAttribute("data-theme-toggle")) track("theme_toggled", { to: document.documentElement.getAttribute("data-theme") === "dark" ? "light" : "dark" });
  }, true);

  // ---- The banner ----
  if (choice === "yes" || choice === "no") return;
  function showBanner() {
    var box = document.createElement("div");
    box.className = "cookie";
    box.setAttribute("role", "region");
    box.setAttribute("aria-label", "Cookies");
    box.innerHTML =
      '<img class="cookie__bee" src="/assets/murmurbee-bee.svg" alt="" width="30" height="29">' +
      '<p class="cookie__text">Buzz buzz, I\u2019m collecting cookies.</p>' +
      '<span class="cookie__btns"><button class="cookie__nah" type="button">Nah</button>' +
        '<button class="btn btn--honey cookie__ok" type="button">OK</button></span>';
    document.body.appendChild(box);
    document.documentElement.classList.add("cookie-open");
    requestAnimationFrame(function () { requestAnimationFrame(function () { box.classList.add("is-in"); }); });
    function close(fn) {
      fn();
      box.classList.remove("is-in");
      document.documentElement.classList.remove("cookie-open");
      setTimeout(function () { box.remove(); }, 400);
    }
    box.querySelector(".cookie__ok").addEventListener("click", function () { close(accept); });
    box.querySelector(".cookie__nah").addEventListener("click", function () { close(decline); });
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", function () { setTimeout(showBanner, 900); });
  else setTimeout(showBanner, 900);
})();
