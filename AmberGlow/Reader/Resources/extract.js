/*
 * Amber Glow reader extraction.
 *
 * Density-scored article extraction in the Readability tradition, written for this
 * app so there is no vendored dependency. Returns a JSON string; the host reads it
 * off evaluateJavaScript.
 */
(function () {
  "use strict";

  var UNLIKELY = /(^|[\s_-])(ad|ads|advert|banner|breadcrumb|catlinks|combx|comment|community|cookie|disqus|editsection|extra|foot|footer|footnote|gdpr|hatnote|header|legends|masthead|mbox|media|meta|modal|navbox|newsletter|nav|paywall|popup|printfooter|promo|related|scroll|share|shopping|shortdescription|shoutbox|sidebar|siteSub|skyscraper|social|sponsor|subscribe|teaser|tags|toc|tool|widget)([\s_-]|$)/i;
  var MAYBE = /(and|article|body|column|content|entry|main|page|post|story|text|blog)/i;
  var POSITIVE = /(article|body|content|entry|hentry|h-entry|main|page|post|story|text|blog|column)/i;
  var NEGATIVE = /(hidden|banner|combx|comment|contact|foot|footer|gdpr|masthead|media|meta|outbrain|promo|related|scroll|share|shoutbox|sidebar|skyscraper|sponsor|shopping|tags|widget)/i;

  var STRIP = "script,style,noscript,template,link,meta,svg,canvas,iframe,object,embed," +
    "form,input,textarea,select,button,label,nav,footer,aside,dialog,ins," +
    "[aria-hidden='true'],[hidden],[role='navigation'],[role='banner']," +
    "[role='complementary'],[role='search'],[role='dialog'],[role='alert']," +
    // Text for screen readers only — "(opens a new tab)" after a link, "Image:"
    // before a figure. Meant to be heard and not seen, and in a reader it is seen.
    ".sr-only,.visually-hidden,.visuallyhidden,.screen-reader-text,.screen-reader-only," +
    ".a11y-hidden,.u-visually-hidden,.sr-only-focusable,[data-ag-unseen]";

  var KEEP = {
    P: 1, H1: 1, H2: 1, H3: 1, H4: 1, H5: 1, H6: 1, UL: 1, OL: 1, LI: 1,
    BLOCKQUOTE: 1, PRE: 1, CODE: 1, FIGURE: 1, FIGCAPTION: 1, IMG: 1, A: 1,
    STRONG: 1, B: 1, EM: 1, I: 1, U: 1, S: 1, BR: 1, HR: 1, SPAN: 1, DIV: 1,
    TABLE: 1, THEAD: 1, TBODY: 1, TFOOT: 1, TR: 1, TD: 1, TH: 1, CAPTION: 1,
    SUP: 1, SUB: 1, MARK: 1, SMALL: 1, DL: 1, DT: 1, DD: 1, TIME: 1, ABBR: 1,
    PICTURE: 1, SOURCE: 1
  };

  function txt(el) {
    return (el.textContent || "").replace(/\s+/g, " ").trim();
  }

  function attr(el, name) {
    return (el && el.getAttribute && el.getAttribute(name)) || "";
  }

  function signature(el) {
    return (attr(el, "class") + " " + attr(el, "id") + " " + attr(el, "itemprop")).toLowerCase();
  }

  function meta(names) {
    for (var i = 0; i < names.length; i++) {
      var n = names[i];
      var el = document.querySelector("meta[property='" + n + "']") ||
        document.querySelector("meta[name='" + n + "']") ||
        document.querySelector("meta[itemprop='" + n + "']");
      if (el) {
        var c = (el.getAttribute("content") || "").trim();
        if (c) return c;
      }
    }
    return "";
  }

  function linkDensity(el) {
    var total = txt(el).length;
    if (!total) return 1;
    var linked = 0;
    var anchors = el.querySelectorAll("a");
    for (var i = 0; i < anchors.length; i++) linked += txt(anchors[i]).length;
    return linked / total;
  }

  /* ---------- 1. working copy ---------- */

  // The same screen-reader-only text, wherever a site did it without one of the usual
  // class names. It can only be told apart on the live page, where it has a computed
  // style: clipped to nothing, a pixel square, or set in no size at all. Marked here,
  // on the page itself, so the copy about to be taken carries the mark and the strip
  // below can take it out with the rest.
  var candidates = document.body ? document.body.querySelectorAll("span,small,a,em,i,b,strong,div,p,li") : [];
  for (var c = 0; c < candidates.length; c++) {
    var cand = candidates[c];
    if (!cand.textContent || !cand.textContent.trim()) continue;
    var cs = window.getComputedStyle(cand);
    var clipped = cs.position === "absolute" && (
      /rect\(\s*0(px)?[\s,]+0(px)?[\s,]+0(px)?[\s,]+0(px)?\s*\)/.test(cs.clip || "") ||
      /inset\(\s*(50%|100%)/.test(cs.clipPath || "") ||
      ((parseFloat(cs.width) <= 1 || parseFloat(cs.height) <= 1) && cs.overflow === "hidden"));
    if (clipped || cs.fontSize === "0px") cand.setAttribute("data-ag-unseen", "1");
  }

  // The same page laid out more than once, for different widths, with all but one
  // put away: a headline block for phones and another for desktops, or a graphic
  // drawn at three sizes (ai2html's artboards). Only the one on show is read. Kept to
  // short runs of text, so a passage the page folds away behind "Read more" is not
  // lost with them.
  var everything = document.body ? document.body.getElementsByTagName("*") : [];
  for (var hv = 0; hv < everything.length; hv++) {
    var hidden = everything[hv];
    if (hidden.closest("[data-ag-unseen]")) continue;
    if (/^(SCRIPT|STYLE|TEMPLATE|NOSCRIPT|BR)$/.test(hidden.tagName)) continue;
    if (window.getComputedStyle(hidden).display !== "none") continue;
    if ((hidden.textContent || "").replace(/\s+/g, " ").trim().length > 600) continue;
    hidden.setAttribute("data-ag-unseen", "1");
  }

  // Words set over a picture — a map's place names, a chart's labels — belong to the
  // picture, and out of it they are a column of fragments: "Russia", "Crossed the",
  // "Bering Strait". On the live page they can be told by where they sit: placed
  // absolutely, on top of an image that holds them.
  var pictures = document.body ? document.body.querySelectorAll("img,picture,svg") : [];
  var drawn = [];
  for (var pi = 0; pi < pictures.length; pi++) {
    var pr = pictures[pi].getBoundingClientRect();
    if (pr.width >= 200 && pr.height >= 120) drawn.push(pr);
  }
  if (drawn.length) {
    var floating = document.body.querySelectorAll("div,p,span");
    for (var fi = 0; fi < floating.length; fi++) {
      var label = floating[fi];
      if (label.closest("[data-ag-unseen]")) continue;
      var words = (label.textContent || "").replace(/\s+/g, " ").trim();
      if (!words || words.length > 160) continue;
      if (window.getComputedStyle(label).position !== "absolute") continue;
      var lr = label.getBoundingClientRect();
      if (!lr.width || !lr.height) continue;
      var cx = lr.left + lr.width / 2, cy = lr.top + lr.height / 2;
      for (var di = 0; di < drawn.length; di++) {
        var r = drawn[di];
        if (cx >= r.left && cx <= r.right && cy >= r.top && cy <= r.bottom) {
          label.setAttribute("data-ag-unseen", "1");
          break;
        }
      }
    }
  }

  var doc = document.cloneNode(true);
  var body = doc.body;
  if (!body) return JSON.stringify({ ok: false, reason: "no-body" });

  var doomed = body.querySelectorAll(STRIP);
  for (var i = doomed.length - 1; i >= 0; i--) {
    var d = doomed[i];
    // A <header>/<footer> inside the article body can be legitimate; only outer ones go.
    if (d.parentNode) d.parentNode.removeChild(d);
  }

  var all = body.getElementsByTagName("*");
  for (var j = all.length - 1; j >= 0; j--) {
    var el = all[j];
    if (!el.parentNode) continue;
    var sig = signature(el);
    if (sig && UNLIKELY.test(sig) && !MAYBE.test(sig) &&
        el.tagName !== "BODY" && el.tagName !== "ARTICLE" &&
        !el.querySelector("article")) {
      el.parentNode.removeChild(el);
    }
  }

  /* ---------- 2. score candidates ---------- */

  function tagBase(tag) {
    switch (tag) {
      case "ARTICLE": return 30;
      case "MAIN": return 20;
      case "SECTION": return 8;
      case "DIV": return 5;
      case "PRE": case "BLOCKQUOTE": case "TD": return 3;
      case "ADDRESS": case "OL": case "UL": case "DL": case "DD": case "DT":
      case "LI": case "FORM": return -3;
      case "H1": case "H2": case "H3": case "H4": case "H5": case "H6": return -5;
      default: return 0;
    }
  }

  var scores = [];   // parallel arrays keep this fast without a Map dependency
  var nodes = [];

  function scoreOf(node) {
    var idx = nodes.indexOf(node);
    if (idx === -1) {
      nodes.push(node);
      var base = tagBase(node.tagName);
      var sig2 = signature(node);
      if (POSITIVE.test(sig2)) base += 25;
      if (NEGATIVE.test(sig2)) base -= 25;
      scores.push(base);
      return scores.length - 1;
    }
    return idx;
  }

  var blocks = body.querySelectorAll("p,pre,blockquote,article,section,div>br+br");
  for (var k = 0; k < blocks.length; k++) {
    var block = blocks[k];
    var text = txt(block);
    if (text.length < 25) continue;

    var contentScore = 1;
    contentScore += Math.min(Math.floor(text.length / 100), 4);
    contentScore += (text.match(/[,、，.;:]/g) || []).length * 0.25;

    var parent = block.parentNode;
    var grand = parent ? parent.parentNode : null;
    if (parent && parent.tagName) scores[scoreOf(parent)] += contentScore;
    if (grand && grand.tagName && grand.tagName !== "BODY") {
      scores[scoreOf(grand)] += contentScore / 2;
    }
  }

  var best = null, bestScore = 0;
  for (var m = 0; m < nodes.length; m++) {
    var candidate = nodes[m];
    var adjusted = scores[m] * (1 - linkDensity(candidate));
    if (adjusted > bestScore) { bestScore = adjusted; best = candidate; }
  }

  if (!best) {
    best = doc.querySelector("article") || doc.querySelector("main") || body;
  }

  /* ---------- 3. pull in sibling blocks that belong to the same article ---------- */

  var container = doc.createElement("div");
  var threshold = Math.max(10, bestScore * 0.2);
  var siblings = best.parentNode ? best.parentNode.children : [best];

  for (var s = 0; s < siblings.length; s++) {
    var sib = siblings[s];
    var take = sib === best;
    if (!take) {
      var si = nodes.indexOf(sib);
      if (si !== -1 && scores[si] >= threshold) take = true;
      if (!take && sib.tagName === "P") {
        var t = txt(sib);
        if (t.length > 80 && linkDensity(sib) < 0.25) take = true;
      }
      if (!take && (sib.tagName === "FIGURE" || sib.tagName === "IMG")) take = true;
    }
    if (take) container.appendChild(sib.cloneNode(true));
  }
  if (!container.childNodes.length) container.appendChild(best.cloneNode(true));

  /* ---------- 4. sanitize ---------- */

  function absolutize(value) {
    if (!value) return "";
    try { return new URL(value, document.baseURI).href; } catch (e) { return value; }
  }

  function imageSource(node) {
    var candidates = ["src", "data-src", "data-original", "data-lazy-src", "data-hi-res-src"];
    for (var c = 0; c < candidates.length; c++) {
      var v = attr(node, candidates[c]);
      if (v && v.indexOf("data:image/gif") !== 0) return absolutize(v);
    }
    var set = attr(node, "srcset") || attr(node, "data-srcset");
    if (set) {
      var first = set.split(",")[0].trim().split(/\s+/)[0];
      if (first) return absolutize(first);
    }
    return "";
  }

  function clean(node) {
    var children = [].slice.call(node.children || []);
    for (var c = 0; c < children.length; c++) clean(children[c]);

    var tag = node.tagName;
    if (!tag) return;

    if (!KEEP[tag]) {
      unwrap(node);
      return;
    }

    if (tag === "IMG") {
      var src = imageSource(node);
      var alt = attr(node, "alt");
      var w = parseInt(attr(node, "width") || "0", 10);
      var h = parseInt(attr(node, "height") || "0", 10);
      stripAttributes(node);
      if (!src || (w && w < 64) || (h && h < 64)) {
        if (node.parentNode) node.parentNode.removeChild(node);
        return;
      }
      node.setAttribute("src", src);
      if (alt) node.setAttribute("alt", alt);
      node.setAttribute("loading", "lazy");
      return;
    }

    if (tag === "SOURCE") {
      if (node.parentNode) node.parentNode.removeChild(node);
      return;
    }

    if (tag === "A") {
      var href = absolutize(attr(node, "href"));
      stripAttributes(node);
      if (href && href.indexOf("javascript:") !== 0) {
        node.setAttribute("href", href);
      } else {
        unwrap(node);
        return;
      }
      return;
    }

    stripAttributes(node);

    // A site's own highlighter — <mark> — is the author's emphasis, and it arrives
    // in the site's colour: the browser paints a bare <mark> yellow, and yellow is
    // the one thing that cannot be on the panel. The reader's own marks are <mark>
    // too, and are told apart by a class; a page's are made into emphasis instead.
    if (tag === "MARK") { rename(node, "strong"); return; }

    // Drop wrappers and leftovers that carry nothing.
    var emptyish = !txt(node) && !node.querySelector("img");
    if (emptyish && tag !== "BR" && tag !== "HR" && tag !== "IMG") {
      if (node.parentNode) node.parentNode.removeChild(node);
      return;
    }

    // A DIV or SPAN that survived is just noise around its children.
    if ((tag === "DIV" || tag === "SPAN") && node.parentNode) {
      var onlyInline = node.querySelector("p,h1,h2,h3,h4,h5,h6,ul,ol,blockquote,pre,figure,table,img");
      if (onlyInline) unwrap(node);
      else if (tag === "DIV") rename(node, "p");
    }
  }

  function stripAttributes(node) {
    var names = [];
    for (var a = 0; a < node.attributes.length; a++) names.push(node.attributes[a].name);
    for (var b = 0; b < names.length; b++) node.removeAttribute(names[b]);
  }

  function unwrap(node) {
    var parent = node.parentNode;
    if (!parent) return;
    while (node.firstChild) parent.insertBefore(node.firstChild, node);
    parent.removeChild(node);
  }

  function rename(node, tagName) {
    var replacement = doc.createElement(tagName);
    while (node.firstChild) replacement.appendChild(node.firstChild);
    if (node.parentNode) node.parentNode.replaceChild(replacement, node);
  }

  clean(container);

  // What a page sets where an advertisement goes — "Advertisement", "Skip
  // advertisement", "Story continues below" — standing on its own as a paragraph. The
  // advertisement itself is long gone by here; its label is all that was left.
  var AD_LABEL = /^(advertisement|advertisements|skip advertisement|sponsored|sponsored content|ad|story continues below( advertisement)?|continue reading( the main story)?( below)?|article continues below( advertisement)?|scroll to continue( with content)?)$/i;
  var labelled = container.querySelectorAll("p,div,span,h1,h2,h3,h4,h5,h6,small,aside");
  for (var al = labelled.length - 1; al >= 0; al--) {
    var adLabel = labelled[al];
    if (adLabel.parentNode && AD_LABEL.test(txt(adLabel).replace(/[.:]$/, ""))) {
      adLabel.parentNode.removeChild(adLabel);
    }
  }

  // A frame whose picture never arrived, kept for its caption alone, says what is in
  // a photograph that is not there.
  // A figure that holds something else — a table, a block of code, a quotation — is
  // more than its caption, and stays.
  var frames = container.querySelectorAll("figure");
  for (var fr = frames.length - 1; fr >= 0; fr--) {
    var frame = frames[fr];
    if (!frame.parentNode || frame.querySelector("img,table,pre,blockquote,ul,ol")) continue;
    var caption = frame.querySelector("figcaption");
    if (txt(frame) === (caption ? txt(caption) : "")) frame.parentNode.removeChild(frame);
  }

  // Collapse runs of empty paragraphs the unwrapping may have produced.
  var ps = container.querySelectorAll("p,div,span,li");
  for (var p = ps.length - 1; p >= 0; p--) {
    var pel = ps[p];
    if (!txt(pel) && !pel.querySelector("img") && pel.parentNode) {
      pel.parentNode.removeChild(pel);
    }
  }

  /* ---------- 5. metadata ---------- */

  var title = meta(["og:title", "twitter:title", "dc.title"]);
  if (!title) {
    var h1 = doc.querySelector("article h1") || doc.querySelector("h1");
    if (h1) title = txt(h1);
  }
  if (!title) title = (document.title || "").trim();
  // Trim a trailing " | Site Name" only when the tail really is the site's name.
  var siteName = meta(["og:site_name", "application-name"]);
  var hostParts = location.hostname.replace(/^www\./, "").split(".");
  var hostToken = hostParts.length > 1 ? hostParts[hostParts.length - 2] : hostParts[0];
  var separator = title.match(/^(.{4,})\s+[|\u2014\u2013\u00b7\-:]\s+(.{2,45})$/);
  if (separator) {
    var tail = separator[2].toLowerCase().replace(/[^a-z0-9]/g, "");
    var candidates = [siteName.toLowerCase().replace(/[^a-z0-9]/g, ""),
                      hostToken.toLowerCase().replace(/[^a-z0-9]/g, "")];
    for (var ti = 0; ti < candidates.length; ti++) {
      var cand = candidates[ti];
      if (!cand || cand.length < 3) continue;
      var same = tail === cand ||
        (cand.length >= 4 && tail.indexOf(cand) !== -1) ||
        (tail.length >= 4 && cand.indexOf(tail) !== -1);
      if (same) {
        title = separator[1].trim();
        break;
      }
    }
  }

  // A name, wherever the page gives one. Several of the usual places hold a link to
  // the author's page instead — The Times puts one in article:author — which is no
  // byline, so an address is passed over for the next place, and only as a last
  // resort made into a name from its last path segment ("/by/jonathan-wolfe").
  function isAddress(v) { return /^(https?:)?\/\//i.test(v) || /^www\./i.test(v); }

  function schemaAuthor() {
    var blocks = document.querySelectorAll("script[type='application/ld+json']");
    for (var b = 0; b < blocks.length; b++) {
      var data;
      try { data = JSON.parse(blocks[b].textContent || ""); } catch (e) { continue; }
      var queue = [].concat(data);
      while (queue.length) {
        var item = queue.shift();
        if (!item || typeof item !== "object") continue;
        if (item["@graph"]) queue = queue.concat(item["@graph"]);
        var who = item.author || item.creator;
        if (!who) continue;
        var names = [].concat(who).map(function (w) {
          return typeof w === "string" ? w : (w && w.name) || "";
        }).filter(function (n) { return n && !isAddress(n); });
        if (names.length) return names.join(", ");
      }
    }
    return "";
  }

  var bylineSources = [
    function () { return meta(["author", "byl", "dc.creator", "parsely-author", "sailthru.author"]); },
    schemaAuthor,
    function () {
      var el = doc.querySelector("[rel='author'],[itemprop='author'],.byline,.author,.c-byline");
      return el ? txt(el) : "";
    },
    function () { return meta(["article:author", "og:article:author", "twitter:creator"]); }
  ];
  var byline = "", bylineAddress = "";
  for (var bs = 0; bs < bylineSources.length && !byline; bs++) {
    var found = (bylineSources[bs]() || "").trim();
    if (!found) continue;
    if (isAddress(found)) { bylineAddress = bylineAddress || found; continue; }
    byline = found;
  }
  if (!byline && bylineAddress) {
    var slug = bylineAddress.replace(/[?#].*$/, "").replace(/\/+$/, "").split("/").pop() || "";
    if (/^[a-z]+(-[a-z]+){1,3}$/i.test(slug)) {
      byline = slug.split("-").map(function (w) {
        return w.charAt(0).toUpperCase() + w.slice(1);
      }).join(" ");
    }
  }
  byline = byline.replace(/^\s*(by|By|BY)\s+/, "").replace(/^@/, "").slice(0, 120);

  var site = siteName || location.hostname.replace(/^www\./, "");
  var published = meta(["article:published_time", "og:article:published_time", "date", "dc.date", "datePublished"]);
  var lead = absolutize(meta(["og:image", "twitter:image", "twitter:image:src"]));

  var articleText = txt(container);
  var excerpt = meta(["og:description", "description", "twitter:description"]) ||
    articleText.slice(0, 320);

  // A block said a second time is the page's own repetition — a headline and its
  // summary set once over the lead picture and again under it — and is read once.
  var seenBlocks = {};
  var repeatable = container.querySelectorAll("h1,h2,h3,p,figcaption,blockquote");
  for (var rb = 0; rb < repeatable.length; rb++) {
    var rep = repeatable[rb];
    if (!rep.parentNode || rep.querySelector("img")) continue;
    var said = txt(rep);
    // A short line said twice can be meant — a refrain, a "* * *" — so only a
    // heading, a caption or a paragraph of some length counts as a repeat.
    if (said.length < (rep.tagName === "P" ? 80 : 20)) continue;
    if (seenBlocks[said]) { rep.parentNode.removeChild(rep); continue; }
    seenBlocks[said] = true;
  }

  // The headline is shown above the article already. One at the top of the body is
  // that headline again, even when it is worded differently from the title the page
  // gives for sharing — so the first heading goes whenever nothing of the article
  // comes before it.
  var firstHeading = container.querySelector("h1,h2");
  if (firstHeading) {
    var before = "";
    var walker = doc.createTreeWalker(container, NodeFilter.SHOW_TEXT, null);
    while (walker.nextNode()) {
      if (firstHeading.contains(walker.currentNode)) break;
      before += walker.currentNode.nodeValue;
      if (before.replace(/\s+/g, "").length > 40) break;
    }
    var leads = before.replace(/\s+/g, "").length <= 40;
    var sameAsTitle = title && txt(firstHeading).slice(0, 60) === title.slice(0, 60);
    if ((leads && firstHeading.tagName === "H1") || sameAsTitle) {
      firstHeading.parentNode.removeChild(firstHeading);
    }
  }

  // Comments a page's tools leave in its markup ("Generated by ai2html") are no part
  // of the article.
  var notes = doc.createTreeWalker(container, NodeFilter.SHOW_COMMENT, null);
  var comments = [];
  while (notes.nextNode()) comments.push(notes.currentNode);
  for (var cm = 0; cm < comments.length; cm++) comments[cm].parentNode.removeChild(comments[cm]);

  articleText = txt(container);
  var words = articleText ? articleText.split(/\s+/).length : 0;

  return JSON.stringify({
    ok: articleText.length >= 400,
    reason: articleText.length >= 400 ? "" : "too-short",
    url: location.href,
    title: title,
    byline: byline,
    site: site,
    published: published,
    excerpt: excerpt.trim(),
    leadImage: lead,
    wordCount: words,
    length: articleText.length,
    html: container.innerHTML,
    // Filled in by the Defuddle pass, which is where Markdown comes from; declared
    // here so both extractors answer with the same shape.
    markdown: "",
    source: "amber"
  });
})();
