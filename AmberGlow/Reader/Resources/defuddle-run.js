/*
 * Defuddle, run against the page the extractor just loaded.
 *
 * Two jobs, one parse. The Markdown is what every saved article keeps as its
 * portable sidecar — a `body.md` that reads the same in Obsidian, or in any
 * editor, as it does here. The HTML is the second chance: a page the app's own
 * pass could not make sense of — a Substack post, a site that hides its article
 * behind a shell of framework markup — usually has a site-specific extractor
 * waiting for it here.
 *
 * `defuddle.js` is injected into the page before this runs. Returns the same
 * JSON shape `extract.js` does, so the host decodes one type either way.
 */
(function () {
  "use strict";

  var EMPTY = {
    ok: false, reason: "", url: location.href, title: "", byline: "", site: "",
    published: "", excerpt: "", leadImage: "", wordCount: 0, length: 0,
    html: "", markdown: "", source: "defuddle"
  };

  function bail(reason) {
    var out = {};
    for (var k in EMPTY) { out[k] = EMPTY[k]; }
    out.reason = reason;
    return JSON.stringify(out);
  }

  if (typeof Defuddle !== "function") { return bail("defuddle-missing"); }

  // Screen-reader-only text — "(opens a new tab)" after a link — taken off the page
  // before it is read, the same as the app's own pass does. `data-ag-unseen` is that
  // pass's mark for text the page renders invisible without one of the usual class
  // names; it runs first, so the marks are there to use.
  var UNSEEN = ".sr-only,.visually-hidden,.visuallyhidden,.screen-reader-text," +
    ".screen-reader-only,.a11y-hidden,.u-visually-hidden,.sr-only-focusable,[data-ag-unseen]";
  var unseen = document.querySelectorAll(UNSEEN);
  for (var u = unseen.length - 1; u >= 0; u--) {
    if (unseen[u].parentNode) { unseen[u].parentNode.removeChild(unseen[u]); }
  }

  var parsed;
  try {
    parsed = new Defuddle(document, {
      url: location.href,
      // One parse, both forms: `content` stays HTML, `contentMarkdown` comes back
      // beside it. Asking for `markdown: true` instead would replace the HTML the
      // reader still wants.
      separateMarkdown: true
    }).parse();
  } catch (e) {
    return bail("defuddle-threw");
  }
  if (!parsed || !parsed.content) { return bail("no-content"); }

  /* ---------- sanitize ---------- */

  // Parsed inert, not assigned into the live document: nothing in here runs, and
  // no image starts fetching, while it is being cleaned up.
  var doc = new DOMParser().parseFromString(
    "<div id='ag-root'>" + parsed.content + "</div>", "text/html");
  var root = doc.getElementById("ag-root");
  if (!root) { return bail("no-content"); }

  var STRIP = "script,style,noscript,template,link,meta,iframe,object,embed," +
    "form,input,textarea,select,button,dialog,canvas";
  var doomed = root.querySelectorAll(STRIP);
  for (var i = doomed.length - 1; i >= 0; i--) {
    if (doomed[i].parentNode) { doomed[i].parentNode.removeChild(doomed[i]); }
  }

  function absolutize(value) {
    if (!value) { return ""; }
    try { return new URL(value, document.baseURI).href; } catch (e) { return value; }
  }

  var all = root.getElementsByTagName("*");
  for (var j = 0; j < all.length; j++) {
    var el = all[j];
    var names = [];
    for (var a = 0; a < el.attributes.length; a++) { names.push(el.attributes[a].name); }
    for (var b = 0; b < names.length; b++) {
      var name = names[b];
      // Inline handlers and inline style: the first is code, the second fights the
      // reader's own palette, which is the whole point of the page.
      if (name.slice(0, 2).toLowerCase() === "on" || name.toLowerCase() === "style") {
        el.removeAttribute(name);
      }
    }
    if (el.hasAttribute("src")) { el.setAttribute("src", absolutize(el.getAttribute("src"))); }
    if (el.hasAttribute("href")) {
      var href = absolutize(el.getAttribute("href"));
      // A same-document link — a footnote reference — has to stay a fragment for the
      // reader's own click handler to catch it.
      var raw = el.getAttribute("href") || "";
      if (raw.charAt(0) === "#") { href = raw; }
      if (href.toLowerCase().indexOf("javascript:") === 0) { el.removeAttribute("href"); }
      else { el.setAttribute("href", href); }
    }
  }

  /* ---------- report ---------- */

  var text = (root.textContent || "").replace(/\s+/g, " ").trim();
  var markdown = (parsed.contentMarkdown || "").trim();

  // A lower bar than the app's own pass deliberately. This runs *because* that pass
  // came back empty-handed, and a short post that really is the whole page is a fair
  // capture — the strict threshold is what sent the page here in the first place.
  var enough = text.length >= 200;

  return JSON.stringify({
    ok: enough,
    reason: enough ? "" : "too-short",
    url: location.href,
    title: parsed.title || "",
    byline: (parsed.author || "").replace(/^\s*[Bb][Yy]\s+/, "").slice(0, 120),
    site: parsed.site || parsed.domain || "",
    published: parsed.published || "",
    excerpt: (parsed.description || text.slice(0, 320)).trim(),
    leadImage: absolutize(parsed.image || ""),
    wordCount: parsed.wordCount || (text ? text.split(/\s+/).length : 0),
    length: text.length,
    html: root.innerHTML,
    markdown: markdown,
    source: "defuddle"
  });
})();
