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

  /* ---------- 0. a post on X ---------- */

  // A post on X is no article, and scored as one it comes out badly: the whole post a
  // single paragraph, set between the author's picture and the count of its likes, and
  // an author's thread cut off after its first post. So a post's page is read on its own
  // terms, post by post, from either page X serves: the one for a reader signed out,
  // and the one for a reader signed in to the browser, whose posts are marked up
  // differently and found by their test ids.
  var X_HOST = /(^|\.)(x|twitter)\.com$/i;
  var X_STATUS = /^\/([A-Za-z0-9_]{1,15})\/status(?:es)?\/(\d+)/;
  var X_RESERVED = /^(i|home|explore|search|notifications|messages|settings|compose|hashtag|intent|login|signup|tos|privacy)$/i;
  // The pictures a post carries: its photographs, and the stills of its videos and GIFs.
  // Not the avatars, the emoji, or a link card's thumbnail.
  var X_MEDIA = /^https:\/\/pbs\.twimg\.com\/(media|ext_tw_video_thumb|amplify_video_thumb|tweet_video_thumb)\//;

  function esc(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }

  function readPostOnX() {
    if (!X_HOST.test(location.hostname)) return null;
    var here = location.pathname.match(X_STATUS);
    if (!here) return null;

    function answer(fields) {
      var out = {
        ok: false, reason: "", url: location.href, title: "", byline: "", site: "X",
        published: "", excerpt: "", leadImage: "", wordCount: 0, length: 0,
        html: "", markdown: "", source: "amber"
      };
      for (var k in fields) out[k] = fields[k];
      return JSON.stringify(out);
    }

    // A long-form X Article is a document, with its own headings and lists, and
    // Defuddle has a reader made for it. Not ready, as far as this pass goes.
    if (document.querySelector("[data-testid='twitterArticleReadView']")) {
      return answer({ reason: "x-article" });
    }

    function shown(el) { return el.getClientRects().length > 0; }
    function outside(el, without) { return !without || !without.contains(el); }
    function pathOf(a) {
      try {
        var u = new URL(a.href);
        return X_HOST.test(u.hostname) ? u.pathname : "";
      } catch (e) { return ""; }
    }

    // A post is an <article> on both pages. Signed out, a quoted post is an <article>
    // inside it; signed in, it is a link-like block holding a second post's name and text.
    var posts = [].slice.call(document.querySelectorAll("article")).filter(function (a) {
      return !(a.parentElement && a.parentElement.closest("article")) && shown(a);
    });
    // Signed in, the posts arrive after the page does. Not yet, rather than a reading
    // of the empty shell around them: the host tries again, and then asks Defuddle.
    if (!posts.length) return answer({ reason: "x-not-ready" });

    function innerQuote(post) {
      var inner = post.querySelector("article");
      if (inner) return inner;
      var blocks = post.querySelectorAll("div[role='link']");
      for (var i = 0; i < blocks.length; i++) {
        if (blocks[i].querySelector("[data-testid='User-Name'],[data-testid='tweetText']")) return blocks[i];
      }
      return null;
    }

    // The post's own words. Signed in, they are marked as such. Signed out, they are the
    // one block the page sets with its line breaks kept — the post's own newlines, which
    // are its paragraphs.
    function textsOf(scope, without) {
      var found = [].slice.call(scope.querySelectorAll("[data-testid='tweetText']"));
      // Signed in, a post with no words has none: every scrap of type on that page keeps
      // its line breaks, down to the dot between a name and a date.
      if (!found.length && !document.querySelector("[data-testid='tweet']")) {
        found = [].slice.call(scope.querySelectorAll("div,span,p")).filter(function (el) {
          var ws = window.getComputedStyle(el).whiteSpace;
          return (ws === "pre-wrap" || ws === "pre-line" || ws === "break-spaces") && !el.closest("a,button");
        });
      }
      found = found.filter(function (el) { return outside(el, without) && shown(el) && txt(el); });
      return found.filter(function (el) {
        return !found.some(function (other) { return other !== el && other.contains(el); });
      });
    }

    // The quoted post, with whatever around it belongs to it alone — signed out, the
    // link laid over it to its own page sits beside it rather than in it.
    function quoteOf(post) {
      var inner = innerQuote(post);
      if (!inner) return null;
      var own = textsOf(post, inner);
      var whole = inner;
      while (whole.parentElement && whole.parentElement !== post) {
        var up = whole.parentElement;
        if (own.some(function (t) { return up.contains(t); })) break;
        if (txt(up) !== txt(whole)) break;
        if (up.querySelectorAll("img,video").length !== whole.querySelectorAll("img,video").length) break;
        whole = up;
      }
      return { post: inner, whole: whole };
    }

    // Who wrote it: the first link to a profile, and its first link with a name in it
    // rather than the handle.
    function authorOf(scope, without) {
      var anchors = scope.querySelectorAll("a[href]");
      var handle = "", name = "";
      for (var i = 0; i < anchors.length; i++) {
        var a = anchors[i];
        if (!outside(a, without)) continue;
        var m = pathOf(a).match(/^\/([A-Za-z0-9_]{1,15})\/?$/);
        if (!m || X_RESERVED.test(m[1])) continue;
        if (!handle) handle = m[1];
        if (m[1].toLowerCase() !== handle.toLowerCase()) continue;
        var said = txt(a);
        if (said && said.charAt(0) !== "@") { name = said; break; }
      }
      // Signed in, a quoted post is one link as a whole, with none inside it: the handle
      // is in its avatar's test id, and the name is the first thing under User-Name.
      if (!handle) {
        var avatar = scope.querySelector("[data-testid^='UserAvatar-Container-']");
        if (avatar && outside(avatar, without)) {
          handle = attr(avatar, "data-testid").replace("UserAvatar-Container-", "");
        }
      }
      if (!name) {
        var names = scope.querySelector("[data-testid='User-Name']");
        if (names && outside(names, without)) {
          name = ((names.innerText || "").split("\n").map(function (l) { return l.trim(); })
            .filter(function (l) { return l && l.charAt(0) !== "@" && l !== "\u00b7"; })[0]) || "";
        }
      }
      return { handle: handle, name: name || handle };
    }

    function statusOf(scope, without, handle) {
      var anchors = scope.querySelectorAll("a[href]");
      for (var i = 0; i < anchors.length; i++) {
        if (!outside(anchors[i], without)) continue;
        var m = pathOf(anchors[i]).match(X_STATUS);
        if (m && (!handle || m[1].toLowerCase() === handle.toLowerCase())) return m[2];
      }
      return "";
    }

    // A link's words as the page shows them. Signed in, the rest of its address is in
    // the link too, set too small to see: "https://", and what comes after the "…".
    function shownText(a) {
      var out = "";
      var walker = document.createTreeWalker(a, NodeFilter.SHOW_TEXT, null);
      while (walker.nextNode()) {
        var holder = walker.currentNode.parentElement;
        if (parseFloat(window.getComputedStyle(holder).fontSize) >= 1) out += walker.currentNode.nodeValue;
      }
      return out;
    }

    // Where a link really goes, as against X's own redirect, which works but says
    // nothing. Signed out, the address is the link's title. Signed in, it is the link's
    // whole text, seen and unseen.
    function destination(a) {
      var title = attr(a, "title");
      if (/^https?:\/\//i.test(title)) return title;
      var whole = (a.textContent || "").trim().replace(/\u2026$/, "");
      if (/^https?:\/\/\S+$/i.test(whole)) return whole;
      return a.href;
    }

    // The words as runs of text, each run knowing whether it is bold, italic or a
    // link. The page draws a post's emphasis in its own type — Premium posts have it —
    // so it is told by its weight and slant on the page rather than by a tag.
    function runsOf(root) {
      var runs = [];
      var base = window.getComputedStyle(root);
      var baseBold = parseInt(base.fontWeight, 10) >= 600;
      var baseItalic = base.fontStyle === "italic";
      function push(run) {
        var last = runs[runs.length - 1];
        if (last && !last.href && !run.href && last.bold === run.bold && last.italic === run.italic) {
          last.text += run.text;
        } else {
          runs.push(run);
        }
      }
      (function walk(node, bold, italic) {
        for (var c = node.firstChild; c; c = c.nextSibling) {
          if (c.nodeType === 3) {
            push({ text: c.nodeValue.replace(/ /g, " "), bold: bold, italic: italic });
            continue;
          }
          if (c.nodeType !== 1 || c.hasAttribute("hidden")) continue;
          // Emoji are pictures, signed in, and say what they are in their alt.
          if (c.tagName === "IMG") {
            if (attr(c, "alt")) push({ text: attr(c, "alt"), bold: bold, italic: italic });
            continue;
          }
          if (c.tagName === "BR") { push({ text: "\n", bold: bold, italic: italic }); continue; }
          var cs = window.getComputedStyle(c);
          if (cs.display === "none") continue;
          if (c.tagName === "A") {
            var label = shownText(c).replace(/\s+/g, " ").trim();
            if (!label || /^show more$/i.test(label)) continue;
            runs.push({ text: label, href: destination(c), bold: bold, italic: italic });
            continue;
          }
          walk(c,
               bold || (!baseBold && parseInt(cs.fontWeight, 10) >= 600),
               italic || (!baseItalic && cs.fontStyle === "italic"));
        }
      })(root, false, false);
      return runs;
    }

    // Lines, split at the post's own newlines.
    function linesOf(runs) {
      var lines = [[]];
      runs.forEach(function (run) {
        if (run.href) { lines[lines.length - 1].push(run); return; }
        run.text.split("\n").forEach(function (piece, i) {
          if (i) lines.push([]);
          if (piece) lines[lines.length - 1].push({ text: piece, bold: run.bold, italic: run.italic });
        });
      });
      return lines;
    }

    function plain(line) {
      return line.map(function (run) { return run.text; }).join("");
    }

    function inline(line) {
      return line.map(function (run) {
        var h = esc(run.text);
        if (run.href) h = "<a href=\"" + esc(run.href) + "\">" + h + "</a>";
        if (run.italic) h = "<em>" + h + "</em>";
        if (run.bold) h = "<strong>" + h + "</strong>";
        return h;
      }).join("");
    }

    // A post written with a list or a quotation in it, as plain text — "1." and "-" at
    // the start of its lines, or ">" — is set as one.
    var LINE_KINDS = [
      { kind: "ol", marker: /^\s*(\d{1,3})[.)]\s+/ },
      { kind: "ul", marker: /^\s*[-•‣◦▪*–]\s+/ },
      { kind: "quote", marker: /^\s*>\s?/ }
    ];

    function kindOf(line) {
      var said = plain(line);
      for (var i = 0; i < LINE_KINDS.length; i++) {
        var m = said.match(LINE_KINDS[i].marker);
        if (m && said.length > m[0].length) return { kind: LINE_KINDS[i].kind, marker: m };
      }
      return { kind: "p", marker: null };
    }

    function withoutMarker(line, length) {
      var out = [];
      line.forEach(function (run) {
        if (length > 0 && !run.href) {
          var cut = Math.min(length, run.text.length);
          length -= cut;
          run = { text: run.text.slice(cut), bold: run.bold, italic: run.italic };
          if (!run.text) return;
        }
        out.push(run);
      });
      return out;
    }

    // Blocks from lines: a blank line ends a paragraph, a single newline is a line break
    // within one, and a run of list lines is a list — one list across the blank lines
    // some people leave between its items.
    function blocksOf(lines) {
      var blocks = [];
      var open = null;
      lines.forEach(function (line) {
        if (!plain(line).trim()) { if (open && open.kind !== "ol" && open.kind !== "ul") open = null; else if (open) open.gap = true; return; }
        var k = kindOf(line);
        if (!open || open.kind !== k.kind || (open.gap && k.kind !== "ol" && k.kind !== "ul")) {
          open = { kind: k.kind, items: [], start: k.kind === "ol" ? parseInt(k.marker[1], 10) : 1 };
          blocks.push(open);
        }
        open.gap = false;
        open.items.push(k.marker ? withoutMarker(line, k.marker[0].length) : line);
      });
      return blocks.map(function (b) {
        if (b.kind === "p") return "<p>" + b.items.map(inline).join("<br>") + "</p>";
        if (b.kind === "quote") return "<blockquote><p>" + b.items.map(inline).join("<br>") + "</p></blockquote>";
        var start = b.kind === "ol" && b.start !== 1 ? " start=\"" + b.start + "\"" : "";
        return "<" + b.kind + start + ">" + b.items.map(function (item) {
          return "<li>" + inline(item) + "</li>";
        }).join("") + "</" + b.kind + ">";
      }).join("");
    }

    // A video's still, rather than a photograph. The page puts a player in place of the
    // still only after a while, and before that it is a bare picture like any other —
    // except that a photograph, on either page, is a link to its own "/photo/1".
    function isVideoStill(el, src) {
      if (el.tagName === "VIDEO" || /video_thumb\//.test(src)) return true;
      if (el.closest("[data-testid='videoPlayer'],[data-testid='videoComponent']")) return true;
      return !el.closest("a[href*='/photo/']");
    }

    function mediaOf(scope, without, link) {
      var html = "", seen = {};
      var found = scope.querySelectorAll("img,video");
      for (var i = 0; i < found.length; i++) {
        var el = found[i];
        if (!outside(el, without)) continue;
        var src = el.tagName === "VIDEO" ? attr(el, "poster") : (el.currentSrc || el.src || "");
        try { src = new URL(src, document.baseURI).href; } catch (e) { continue; }
        if (!X_MEDIA.test(src)) continue;
        var key = src.split("?")[0].replace(/:\w+$/, "");
        if (seen[key]) continue;
        seen[key] = true;
        var video = isVideoStill(el, src);
        if (!video && /\/media\//.test(src)) {
          try {
            var large = new URL(src);
            if (large.searchParams.has("name")) { large.searchParams.set("name", "large"); src = large.href; }
          } catch (e) {}
        }
        var alt = el.tagName === "IMG" ? attr(el, "alt") : "";
        if (/^(image|embedded video)$/i.test(alt)) alt = "";
        var img = "<img src=\"" + esc(src) + "\"" + (alt ? " alt=\"" + esc(alt) + "\"" : "") + ">";
        // A video cannot be kept, but its still can, and a way back to it.
        html += video
          ? "<figure>" + img + "<figcaption><a href=\"" + esc(link) + "\">Video on X</a></figcaption></figure>"
          : "<figure>" + img + "</figure>";
      }
      return html;
    }

    // A link X shows as a card, with its address taken out of the words.
    function cardOf(scope, without, texts) {
      var anchors = scope.querySelectorAll("[data-testid='card.wrapper'] a[href], a[href^='https://t.co/']");
      for (var i = 0; i < anchors.length; i++) {
        var a = anchors[i];
        if (!outside(a, without) || texts.some(function (t) { return t.contains(a); })) continue;
        var lines = (a.innerText || "").split(/\n+/).map(function (l) { return l.trim(); }).filter(Boolean);
        var domain = "", words = [];
        lines.forEach(function (l) {
          var d = l.replace(/^from\s+/i, "");
          if (!domain && /^[a-z0-9-]+(\.[a-z0-9-]+)+$/i.test(d)) domain = d;
          else words.push(l);
        });
        if (!words.length) continue;
        // A large card sets only its title over its picture, and names the site in its label.
        if (!domain) {
          var named = attr(a, "aria-label").match(/^([a-z0-9-]+(?:\.[a-z0-9-]+)+)\s/i);
          if (named) domain = named[1];
        }
        return "<p><a href=\"" + esc(a.href) + "\">" + esc(words[0]) + "</a>" +
          (domain ? " — " + esc(domain) : "") + "</p>";
      }
      return "";
    }

    function render(scope, without, link, headline) {
      var texts = textsOf(scope, without);
      var html = "";
      texts.forEach(function (t, i) {
        var lines = linesOf(runsOf(t));
        if (i === 0 && headline) lines = lines.slice(headline);
        html += blocksOf(lines);
      });
      return html + cardOf(scope, without, texts) + mediaOf(scope, without, link);
    }

    function quoteHTML(quote) {
      var who = authorOf(quote.post, null);
      var id = statusOf(quote.whole, null, who.handle);
      var head = who.name ? "<strong>" + esc(who.name) + "</strong>" +
        (who.handle && who.handle !== who.name ? " @" + esc(who.handle) : "") : "";
      var link = id && who.handle ? "https://x.com/" + who.handle + "/status/" + id : "";
      if (link) head = "<a href=\"" + esc(link) + "\">" + head + "</a>";
      return "<blockquote>" + (head ? "<p>" + head + "</p>" : "") + render(quote.post, null, link || location.href, 0) + "</blockquote>";
    }

    // The post the address names, and the author's own posts on either side of it: the
    // thread it belongs to, up to the first reply from anyone else. Until the named post
    // is on the page, nothing else on it is any use — the next post down, read in its
    // place, is a thread's second half under its own headline.
    var focal = -1;
    for (var f = 0; f < posts.length; f++) {
      var fq = quoteOf(posts[f]);
      if (statusOf(posts[f], fq && fq.whole, "") === here[2]) { focal = f; break; }
    }
    if (focal < 0) return answer({ reason: "x-not-ready" });
    var focalQuote = quoteOf(posts[focal]);
    var author = authorOf(posts[focal], focalQuote && focalQuote.whole);
    var same = function (p) {
      var q = quoteOf(p);
      return authorOf(p, q && q.whole).handle.toLowerCase() === author.handle.toLowerCase();
    };
    var from = focal, to = focal;
    while (from > 0 && same(posts[from - 1])) from--;
    while (to < posts.length - 1 && same(posts[to + 1])) to++;
    var thread = posts.slice(from, to + 1);

    // A first line set apart, short, and not a sentence — no stop at its end — is the
    // post's own headline, "File over app", and is its title rather than a line of it.
    var firstQuote = quoteOf(thread[0]);
    var firstTexts = textsOf(thread[0], firstQuote && firstQuote.whole);
    var firstLines = firstTexts.length ? linesOf(runsOf(firstTexts[0])).map(plain) : [];
    var headline = 0, title = "";
    if (firstLines.length > 2 && firstLines[0].trim().length <= 90 && !firstLines[1].trim() &&
        !/[.!?…:,;—–-]["'”’)]*$/.test(firstLines[0].trim()) &&
        firstLines.slice(2).join("").trim()) {
      title = firstLines[0].trim();
      headline = 2;
    }

    var html = "";
    thread.forEach(function (post, i) {
      var quote = quoteOf(post);
      var id = statusOf(post, quote && quote.whole, author.handle);
      var link = id ? "https://x.com/" + author.handle + "/status/" + id : location.href;
      html += render(post, quote && quote.whole, link, i === 0 ? headline : 0);
      if (quote) html += quoteHTML(quote);
    });

    // Read back as text with a space at every block's end, so a list's items, and the
    // paragraph before it, do not run together into one word for the excerpt and count.
    var holder = document.createElement("div");
    holder.innerHTML = html.replace(/(<br>|<\/(p|li|blockquote)>)/g, "$1 ");
    [].slice.call(holder.querySelectorAll("figcaption")).forEach(function (c) { c.remove(); });
    var said = txt(holder);
    var picture = holder.querySelector("img");
    if (!said && !picture) return answer({ reason: "x-not-ready" });

    // Otherwise the opening sentence, which is what a post is known by — from its first
    // line alone, so a list that follows cannot lend it its "1."
    if (!title) {
      var opening = (firstLines.filter(function (l) { return l.trim(); })[0] || "").replace(/\s+/g, " ").trim();
      var sentence = opening.match(/^(.{20,}?[.!?…])(\s|$)/);
      title = sentence ? sentence[1] : opening;
      if (title.length > 100) title = title.slice(0, 100).replace(/\s+\S*$/, "") + "…";
      if (!title) title = author.name + " on X";
    }

    // The post's own date. Signed in, its quoted post's comes first on the page.
    var stamps = [].slice.call(thread[0].querySelectorAll("time[datetime]")).filter(function (t) {
      return outside(t, firstQuote && firstQuote.whole);
    });
    var published = (stamps[0] && attr(stamps[0], "datetime")) || meta(["article:published_time"]);

    // For the Defuddle pass, which writes the Markdown note from this same reading
    // rather than from its own.
    window.__agPostOnX = html;

    return answer({
      ok: true,
      title: title,
      byline: author.name,
      published: published,
      excerpt: said.slice(0, 320),
      leadImage: picture ? picture.getAttribute("src") : "",
      wordCount: said ? said.split(/\s+/).length : 0,
      length: said.length,
      html: html
    });
  }

  var onX = readPostOnX();
  if (onX) return onX;

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
