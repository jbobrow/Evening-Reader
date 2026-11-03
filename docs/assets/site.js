/* Evening Reader — the lights, the glow, and what the screens show.
 *
 * Three settings:
 *   the lights   the page itself, paper or ink (the button in the header). Until the
 *                reader chooses, it follows the system's light or dark appearance.
 *   the warmth   the glow on every screen, from paper white to orange amber. Every
 *                visit starts at Amber: the screens come on from paper white and
 *                warm to it. This one is not kept.
 *   the screens  Paper or Night: what the devices show, whatever the lights.
 *
 * Runs in the <head>, so a remembered setting is there on the first frame rather
 * than arriving after it. */
(function () {
    "use strict";

    var root = document.documentElement;
    var KEY = { theme: "evening-reader.theme", screens: "evening-reader.screens" };
    var AMBER = 0.87;

    function load(key) { try { return localStorage.getItem(key); } catch (e) { return null; } }
    function keep(key, value) { try { localStorage.setItem(key, value); } catch (e) {} }
    function clamp(v) { return Math.min(Math.max(v, 0), 1); }

    // The slider's own gradient (the same stops as --warmth-ramp in site.css): paper at
    // the cold end, warming through cream and apricot to orange amber.
    var RAMP = ["#f4f3f1", "#faf0de", "#ffebcb", "#fee5c0", "#fedfb4", "#ffd7a7", "#ffcf99",
                "#ffc68c", "#ffbc7e", "#ffb16d", "#ffa55a", "#ff9942", "#fa8f2e"];
    function rgb(hex) { return [1, 3, 5].map(function (i) { return parseInt(hex.slice(i, i + 2), 16); }); }
    function ramp(t) {
        var x = clamp(t) * (RAMP.length - 1);
        var i = Math.min(Math.floor(x), RAMP.length - 2), f = x - i;
        var a = rgb(RAMP[i]), b = rgb(RAMP[i + 1]);
        return "rgb(" + a.map(function (v, j) { return Math.round(v + (b[j] - v) * f); }).join(", ") + ")";
    }

    function warmthName(w) {
        if (w < 0.2) { return "Paper white"; }
        if (w < 0.45) { return "Cream"; }
        if (w < 0.7) { return "Apricot"; }
        if (w < 0.88) { return "Amber"; }
        return "Orange amber";
    }

    // ── The lights ──
    var systemDark = false;
    try { systemDark = window.matchMedia("(prefers-color-scheme: dark)").matches; } catch (e) {}
    var theme = load(KEY.theme) || (systemDark ? "dark" : "light");

    function applyTheme(t) {
        theme = t;
        root.setAttribute("data-theme", t);
        var meta = document.querySelector('meta[name="theme-color"]');
        if (meta) { meta.setAttribute("content", t === "dark" ? "#0E0E10" : "#F4F3F1"); }
        var button = document.querySelector(".lights");
        if (button) { button.setAttribute("aria-label", t === "dark" ? "Turn the lights on" : "Turn the lights off"); }
    }
    applyTheme(theme);

    // ── The warmth ──
    var warmth = AMBER;

    // The front page comes on: its screens start at paper white and warm to the
    // reader's glow over a couple of seconds, unless they asked for less motion. The
    // other pages are simply there.
    var reduced = false;
    try { reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches; } catch (e) {}
    var opening = !reduced && /(^|\/)(index\.html)?$/.test(location.pathname);

    function applyWarmth(w) {
        root.style.setProperty("--glass", ramp(w));
        var out = document.getElementById("warmth-name");
        if (out) { out.textContent = warmthName(w); }
    }
    applyWarmth(opening ? 0 : warmth);

    // ── The screens ──
    var screens = load(KEY.screens) === "night" ? "night" : "paper";

    function applyScreens(s) {
        screens = s;
        var pictures = document.querySelectorAll("img[data-night]");
        for (var i = 0; i < pictures.length; i++) {
            var img = pictures[i];
            if (!img.hasAttribute("data-paper")) { img.setAttribute("data-paper", img.getAttribute("src")); }
            img.setAttribute("src", img.getAttribute(s === "night" ? "data-night" : "data-paper"));
        }
        var buttons = document.querySelectorAll("[data-screens]");
        for (var j = 0; j < buttons.length; j++) {
            buttons[j].setAttribute("aria-pressed", buttons[j].getAttribute("data-screens") === s ? "true" : "false");
        }
    }

    function bind() {
        applyTheme(theme);
        applyScreens(screens);

        var lights = document.querySelector(".lights");
        if (lights) {
            lights.addEventListener("click", function () {
                var next = theme === "dark" ? "light" : "dark";
                applyTheme(next);
                keep(KEY.theme, next);
            });
        }

        var picks = document.querySelectorAll("[data-screens]");
        for (var i = 0; i < picks.length; i++) {
            picks[i].addEventListener("click", function (event) {
                var s = event.currentTarget.getAttribute("data-screens");
                applyScreens(s);
                keep(KEY.screens, s);
            });
        }

        var slider = document.getElementById("warmth");
        var animating = false;
        if (slider) {
            slider.value = Math.round((opening ? 0 : warmth) * 100);
            applyWarmth(opening ? 0 : warmth);   // the label too, now it is on the page
            slider.addEventListener("input", function () {
                animating = false;
                warmth = clamp(slider.value / 100);
                applyWarmth(warmth);
            });
        }

        // Turn the fades on only after the first frame, so a remembered setting does
        // not fade in on arrival.
        requestAnimationFrame(function () { requestAnimationFrame(function () { root.classList.add("ready"); }); });

        if (!slider || !opening) { if (slider) { applyWarmth(warmth); } return; }
        animating = true;
        var target = warmth, start = null, duration = 2400;
        function ease(t) { return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2; }
        function frame(now) {
            if (!animating) { return; }
            if (start === null) { start = now; }
            var t = Math.min(1, (now - start) / duration);
            var w = target * ease(t);
            applyWarmth(w);
            slider.value = Math.round(w * 100);
            if (t < 1) { requestAnimationFrame(frame); } else { animating = false; }
        }
        slider.value = 0;
        requestAnimationFrame(frame);
    }

    if (document.readyState === "loading") { document.addEventListener("DOMContentLoaded", bind); }
    else { bind(); }
})();
