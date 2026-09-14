/* The app's ramp, on the page.
 *
 * Every colour on the site is produced by the same function the app draws with:
 * a grey level (0 ink … 1 brightest) mapped through warmth, glow and contrast into
 * one amber. The glow and contrast are the app's defaults; the warmth is the reader's
 * to set, and is kept between visits. The pictures are greyscale and drawn with a
 * multiply blend, so they take the page's colour too — the way the app puts a
 * picture on its panel.
 *
 * This runs before the page is laid out, so a remembered warmth is there on the
 * first frame rather than arriving after it. */
(function () {
    "use strict";

    var GLOW = 0.80, CONTRAST = 0.30;
    var TOKENS = {
        "page": 0.88, "page-dim": 0.80, "page-raised": 0.955, "bloom": 1.0,
        "ink": 0.045, "ink-strong": 0.0, "ink-muted": 0.34, "ink-faint": 0.52,
        "rule": 0.68, "fill": 0.76, "fill-active": 0.18
    };

    function clamp(v) { return Math.min(Math.max(v, 0), 1); }
    function lerp(a, b, t) { return a + (b - a) * clamp(t); }

    function hsb(h, s, b) {
        if (s <= 0) { return [b, b, b]; }
        var hh = (h - Math.floor(h)) * 6, i = Math.floor(hh), f = hh - i;
        var p = b * (1 - s), q = b * (1 - s * f), t = b * (1 - s * (1 - f));
        switch (i % 6) {
            case 0: return [b, t, p];
            case 1: return [q, b, p];
            case 2: return [p, b, t];
            case 3: return [p, q, b];
            case 4: return [t, p, b];
            default: return [b, p, q];
        }
    }

    // AmberPalette.rgb(_:), paper polarity.
    function rgb(level, warmth) {
        var hue = lerp(39 / 360, 25.5 / 360, warmth);
        var saturation = lerp(0.24, 0.97, warmth);
        var c = lerp(0.55, 1.55, CONTRAST);
        var l = clamp(0.5 + (clamp(level) - 0.5) * c);
        l = Math.pow(l, 1.06) * lerp(0.46, 1.0, GLOW);
        var s = saturation * (1 - 0.30 * Math.pow(l, 2.4));
        return hsb(hue, clamp(s), clamp(l)).map(function (v) { return Math.round(v * 255); });
    }

    function hex(c) { return "#" + c.map(function (v) { return (v < 16 ? "0" : "") + v.toString(16); }).join(""); }

    function warmthName(w) {
        if (w < 0.2) { return "Warm beige"; }
        if (w < 0.45) { return "Sand"; }
        if (w < 0.7) { return "Amber"; }
        if (w < 0.88) { return "Deep amber"; }
        return "Orange amber";
    }

    var root = document.documentElement;

    function apply(warmth) {
        var style = root.style;
        for (var name in TOKENS) { style.setProperty("--" + name, hex(rgb(TOKENS[name], warmth))); }
        style.setProperty("--page-rgb", rgb(0.88, warmth).join(", "));
        style.setProperty("--bloom-rgb", rgb(1.0, warmth).join(", "));
        style.setProperty("--ink-rgb", rgb(0.045, warmth).join(", "));

        var stops = [];
        for (var i = 0; i <= 12; i++) { stops.push(hex(rgb(i / 12, warmth))); }
        style.setProperty("--ramp", "linear-gradient(90deg, " + stops.join(", ") + ")");

        var meta = document.querySelector('meta[name="theme-color"]');
        if (meta) { meta.setAttribute("content", hex(rgb(0.88, warmth))); }

        var label = document.getElementById("warmth-name");
        if (label) { label.textContent = warmthName(warmth); }
    }

    var saved = 0.87;
    try {
        var kept = parseFloat(localStorage.getItem("evening-reader.warmth"));
        if (!isNaN(kept)) { saved = clamp(kept); }
    } catch (e) {}
    apply(saved);

    function bind() {
        var slider = document.getElementById("warmth");
        if (!slider) { return; }
        slider.value = Math.round(saved * 100);
        apply(saved);
        slider.addEventListener("input", function () {
            var w = clamp(slider.value / 100);
            apply(w);
            try { localStorage.setItem("evening-reader.warmth", String(w)); } catch (e) {}
        });
    }

    if (document.readyState === "loading") { document.addEventListener("DOMContentLoaded", bind); }
    else { bind(); }
})();
