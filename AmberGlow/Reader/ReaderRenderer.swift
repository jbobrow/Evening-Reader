import Foundation

/// Builds the reader document. Everything adjustable lives in CSS custom properties so
/// the panel and type controls can be applied live, without reloading and losing the
/// reader's place on the page.
struct ReaderRenderer {

    static func styleVariables(palette: AmberPalette, settings: DisplaySettings) -> [String: String] {
        [
            "--page": palette.pageHex,
            "--page-dim": palette.pageDimHex,
            "--page-raised": palette.pageRaisedHex,
            "--ink": palette.inkHex,
            "--ink-strong": palette.inkStrongHex,
            "--ink-muted": palette.inkMutedHex,
            "--rule": palette.ruleHex,
            "--size": String(format: "%.2fpx", settings.bodyPointSize),
            "--lh": String(format: "%.3f", settings.lineHeight),
            "--measure": String(format: "%.0fpx", settings.readerColumnPoints),
            "--family": settings.typeface.cssStack,
            "--grid": settings.showTexture ? "1" : "0",
            "--img-filter": palette.polarity == .night ? "url(#ag-ink-night)" : "url(#ag-ink)",
            "--img-photo-filter": palette.polarity == .night ? "url(#ag-photo-night)" : "url(#ag-ink)"
        ]
    }

    /// JS that pushes a new set of variables into an already-loaded document.
    static func applyStyleScript(palette: AmberPalette, settings: DisplaySettings) -> String {
        let pairs = styleVariables(palette: palette, settings: settings)
            .map { "\"\($0.key)\":\"\($0.value)\"" }
            .joined(separator: ",")
        return """
        window.__ag && window.__ag.apply({\(pairs)});
        window.__ag && window.__ag.nightMatrices("\(nightInkMatrix(palette))",
                                                 "\(nightPhotoMatrix(palette))");
        """
    }

    /// Night, for drawings: rgb = the ink colour, alpha = 1 - luma. Dark strokes become
    /// ink and the paper around them goes transparent, which is the same inversion the
    /// type gets — a line drawing reads as amber on black instead of as a white card.
    static func nightInkMatrix(_ palette: AmberPalette) -> String {
        let (r, g, b) = palette.rgb(0.045)
        return String(format: "0 0 0 0 %.4f  0 0 0 0 %.4f  0 0 0 0 %.4f  -0.2126 -0.7152 -0.0722 0 1",
                      r, g, b)
    }

    /// Night, for photographs: rgb = the ink colour, alpha = luma. The picture stays a
    /// positive — light stays light — and simply lands on the ramp. Inverting a
    /// photograph turns a sky black and a shadow bright, which is unreadable; it only
    /// flatters drawings, where the paper is not part of the picture.
    static func nightPhotoMatrix(_ palette: AmberPalette) -> String {
        let (r, g, b) = palette.rgb(0.045)
        return String(format: "0 0 0 0 %.4f  0 0 0 0 %.4f  0 0 0 0 %.4f  0.2126 0.7152 0.0722 0 0",
                      r, g, b)
    }

    static func document(article: SavedArticle, body: String,
                         palette: AmberPalette, settings: DisplaySettings) -> String {
        let vars = styleVariables(palette: palette, settings: settings)
            .sorted { $0.key < $1.key }
            .map { "      \($0.key): \($0.value);" }
            .joined(separator: "\n")

        var meta: [String] = []
        if article.isBook {
            // A book's byline already carries the author; what an article's meta line
            // spends on a byline, a book spends on the publisher and how long it is —
            // there is no "published" date worth showing for most of them, and no
            // fetch date worth pretending is one.
            if let publisher = article.siteName, !publisher.isEmpty { meta.append(escape(publisher)) }
            meta.append(escape(article.lengthLabel))
            if let count = article.chapterCount, count > 0 {
                meta.append(escape(count == 1 ? "1 chapter" : "\(count) chapters"))
            }
        } else {
            let dateLine = (article.publishedAt ?? article.addedAt)
                .formatted(date: .abbreviated, time: .omitted)
            if let byline = article.byline, !byline.isEmpty { meta.append(escape(byline)) }
            if let site = article.siteName, !site.isEmpty { meta.append(escape(site)) }
            else { meta.append(escape(article.sourceLabel)) }
            meta.append(escape(article.lengthLabel))
            meta.append(escape(dateLine))
        }
        let coverImg = article.isBook ? coverImageTag(article) : ""

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
        <title>\(escape(article.displayTitle))</title>
        <style>
        :root {
        \(vars)
        }
        * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
        /* The document paints no background of its own. The app's GlowSurface is the
           only surface in the app, and it carries the backlight bloom and the pixel
           lattice; a fill here would sit on top of that, flattening the bloom and
           leaving a seam wherever the web view's bounds end. */
        html { -webkit-text-size-adjust: none; background: transparent; }
        body {
          margin: 0;
          background: transparent;
          color: var(--ink);
          font-family: var(--family);
          font-size: var(--size);
          line-height: var(--lh);
          font-synthesis-weight: none;
          text-rendering: optimizeLegibility;
        }
        ::selection { background: var(--rule); color: var(--ink-strong); }

        .wrap {
          max-width: var(--measure);
          margin: 0 auto;
          /* Two things set the space above the title. The `em` floor keeps it in
             proportion to the text, so turning the reading size up does not leave the
             title crowded — and it is what holds in landscape, where there is little
             height to give away. The `vh` term lets a taller screen take more: the same
             inset that sits right on an 11" reads as tight on a 13", where the page is
             bigger but a fixed margin is not. */
          padding: max(3.4em, 6vh) 30px 180px;
        }
        header.ag-head { margin: 0 0 34px; }
        header.ag-head h1 {
          font-size: 2.05em;
          line-height: 1.16;
          font-weight: 600;
          letter-spacing: -0.012em;
          margin: 0 0 14px;
          color: var(--ink-strong);
          text-wrap: balance;
        }
        header.ag-head .ag-meta {
          font-family: -apple-system, ui-sans-serif, sans-serif;
          font-size: 0.72em;
          letter-spacing: 0.06em;
          text-transform: uppercase;
          color: var(--ink-muted);
          display: flex;
          flex-wrap: wrap;
          gap: 0 10px;
        }
        header.ag-head .ag-meta span:not(:last-child)::after { content: " ·"; }
        header.ag-head hr { margin: 22px 0 0; }
        header.ag-head .ag-byline {
          font-family: -apple-system, ui-sans-serif, sans-serif;
          font-size: 0.86em;
          color: var(--ink-muted);
          margin: -6px 0 16px;
        }

        p { margin: 0 0 1.1em; }
        p:first-child { margin-top: 0; }
        h1, h2, h3, h4, h5, h6 {
          color: var(--ink-strong);
          line-height: 1.24;
          margin: 1.9em 0 0.6em;
          font-weight: 600;
          letter-spacing: -0.006em;
        }
        h2 { font-size: 1.42em; }
        h3 { font-size: 1.18em; }
        h4, h5, h6 { font-size: 1.02em; }
        a { color: var(--ink); text-decoration: underline; text-decoration-thickness: 1px; text-underline-offset: 3px; text-decoration-color: var(--rule); }
        strong, b { font-weight: 650; }
        ul, ol { margin: 0 0 1.1em; padding-left: 1.35em; }
        li { margin: 0 0 0.42em; }
        blockquote {
          margin: 1.5em 0;
          padding: 0.1em 0 0.1em 1.2em;
          border-left: 3px solid var(--rule);
          color: var(--ink-muted);
          font-style: italic;
        }
        hr { border: 0; border-top: 1px solid var(--rule); margin: 2.2em 0; }
        pre {
          background: var(--page-dim);
          border: 1px solid var(--rule);
          border-radius: 8px;
          padding: 14px 16px;
          overflow-x: auto;
          font-family: ui-monospace, "SF Mono", Menlo, monospace;
          font-size: 0.84em;
          line-height: 1.5;
        }
        code { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 0.86em; }
        p > code, li > code { background: var(--page-dim); padding: 0.1em 0.32em; border-radius: 4px; }
        /* Images join the panel: stripped of their own color, then tinted by the glow.
           The tint is a blend, so it needs something opaque to land on. The document
           itself is transparent (the app's GlowSurface is the only surface), so each
           image carries its own page-coloured tile and isolates the blend to it —
           otherwise white areas of a diagram would blend with nothing and stay white. */
        /* Images become ink on the page rather than pictures sitting on it.
           A blend mode would need something opaque underneath, and anything opaque we
           could put there is a flat colour, which shows as a rectangle against the
           backlight bloom. So the filter turns luminance into *alpha* instead: white
           goes fully transparent, black goes fully opaque. Composited normally over the
           surface that is really there, that is exactly a multiply — bloom included —
           and it needs no backdrop and no palette-dependent values. */
        /* Emoji arrive as colour bitmaps from the system font — the one thing in the
           type that the ramp does not reach. They get the same luminance-to-ink filter
           the pictures do, so they read as a mark on the page rather than a sticker. */
        .ag-emoji {
          filter: var(--img-filter);
        }
        img {
          display: block;
          max-width: 100%;
          height: auto;
          margin: 1.6em auto;
          filter: contrast(1.04) var(--img-filter);
          opacity: 0.94;
        }
        /* Photographs opt out of the inversion. On paper both filters are the same, so
           this only parts company at night. */
        img.ag-photo { filter: contrast(1.04) var(--img-photo-filter); }
        figure { margin: 1.7em 0; }
        figcaption ol, figcaption ul, figcaption li { text-align: left; }
        figcaption {
          font-family: -apple-system, ui-sans-serif, sans-serif;
          font-size: 0.76em;
          line-height: 1.45;
          color: var(--ink-muted);
          text-align: center;
          margin-top: 0.5em;
        }
        table { width: 100%; border-collapse: collapse; margin: 1.5em 0; font-size: 0.9em; }
        th, td { border: 1px solid var(--rule); padding: 8px 10px; text-align: left; }
        th { background: var(--page-dim); font-weight: 600; }
        sup, sub { font-size: 0.7em; }

        /* A book's cover, standing in place of the article header's hairline. It gets the
           same ink treatment every other picture in the reader does — a cover in its own
           full colour would be the one thing on the page fighting the amber ramp instead
           of joining it — just held to a sane size, since a cover is usually drawn for a
           bookstore thumbnail, not a phone-width column. */
        img.ag-cover {
          max-width: min(100%, 320px);
          margin: 0 auto 2.4em;
          border-radius: 2px;
        }
        /* Chapters read as a book rather than one long article: each one opens with
           room to breathe and a rule above it, except the first, which already has the
           book's own header just above. */
        .ag-chapter { margin-top: 3.2em; padding-top: 1.6em; border-top: 1px solid var(--rule); }
        .ag-chapter:first-of-type { margin-top: 0; padding-top: 0; border-top: none; }
        .ag-chapter-title {
          font-size: 1.5em;
          line-height: 1.24;
          font-weight: 600;
          letter-spacing: -0.008em;
          margin: 0 0 0.7em;
          color: var(--ink-strong);
        }
        /* A footnote reads as an aside, not as body text picking up again. */
        .ag-footnote {
          font-size: 0.88em;
          color: var(--ink-muted);
          border-top: 1px solid var(--rule);
          margin-top: 1.6em;
          padding-top: 1em;
        }
        .ag-noteref { font-size: 0.7em; vertical-align: super; text-decoration: none; }
        </style>
        </head>
        <body>
        <svg width="0" height="0" style="position:absolute" aria-hidden="true">
          <filter id="ag-ink" color-interpolation-filters="sRGB">
            <!-- rgb = black, alpha = 1 - luma  ->  page * luma (a multiply) -->
            <feColorMatrix type="matrix" values="
              0 0 0 0 0
              0 0 0 0 0
              0 0 0 0 0
              -0.2126 -0.7152 -0.0722 0 1"/>
          </filter>
          <filter id="ag-ink-night" color-interpolation-filters="sRGB">
            <!-- Drawings: rgb = ink, alpha = 1 - luma. Set live; see nightMatrices(). -->
            <feColorMatrix id="ag-ink-night-matrix" type="matrix"
              values="\(nightInkMatrix(palette))"/>
          </filter>
          <filter id="ag-photo-night" color-interpolation-filters="sRGB">
            <!-- Photographs: rgb = ink, alpha = luma, so the picture stays a positive. -->
            <feColorMatrix id="ag-photo-night-matrix" type="matrix"
              values="\(nightPhotoMatrix(palette))"/>
          </filter>
        </svg>
        <div class="wrap">
        <header class="ag-head">
          \(coverImg)
          <h1>\(escape(article.displayTitle))</h1>
          \(article.isBook ? bylineLine(article) : "")
          <div class="ag-meta">\(meta.map { "<span>\($0)</span>" }.joined())</div>
          <hr>
        </header>
        <article>
        \(body)
        </article>
        </div>
        <script>
        window.__ag = {
          apply: function (vars) {
            var root = document.documentElement;
            for (var key in vars) { root.style.setProperty(key, vars[key]); }
          },
          progress: function () {
            var h = document.documentElement;
            var max = h.scrollHeight - window.innerHeight;
            return max > 0 ? Math.min(1, Math.max(0, window.scrollY / max)) : 0;
          },
          nightMatrices: function (line, photo) {
            var a = document.getElementById("ag-ink-night-matrix");
            if (a) { a.setAttribute("values", line); }
            var b = document.getElementById("ag-photo-night-matrix");
            if (b) { b.setAttribute("values", photo); }
          },
          restore: function (fraction) {
            var h = document.documentElement;
            var max = h.scrollHeight - window.innerHeight;
            if (max > 0 && fraction > 0.001) { window.scrollTo(0, max * fraction); }
          },
          // A book's chapters, so the contents sheet can jump to one and a same-document
          // link (a footnote, a cross-reference) can be followed without leaving the page.
          goto: function (anchor) {
            var el = document.getElementById(anchor);
            if (el) { el.scrollIntoView({ block: "start" }); }
          },
          chapter: function () {
            var sections = document.getElementsByClassName("ag-chapter");
            var current = sections.length ? sections[0].id : "";
            for (var i = 0; i < sections.length; i++) {
              if (sections[i].getBoundingClientRect().top <= 1) { current = sections[i].id; }
              else { break; }
            }
            return current;
          }
        };
        var post = function (name, value) {
          try { window.webkit.messageHandlers.reader.postMessage({ name: name, value: value }); } catch (e) {}
        };
        var ticking = false;
        var lastChapter = "";
        window.addEventListener("scroll", function () {
          if (ticking) return;
          ticking = true;
          requestAnimationFrame(function () {
            ticking = false;
            post("progress", window.__ag.progress());
            var here = window.__ag.chapter();
            if (here && here !== lastChapter) { lastChapter = here; post("chapter", here); }
          });
        }, { passive: true });
        \(SelectionReporter.script(handler: "reader"))
        \(DocumentPager.script(handler: "reader"))

        // Which pictures may be inverted at night.
        //
        // Inverting suits a drawing, where the paper is not part of the picture and the
        // strokes are the whole of it. It ruins a photograph: the sky goes black, the
        // shadows light up, and the subject is unreadable. So each image is looked at
        // once and marked, and only the drawings keep the inversion.
        //
        // Two signals, either of which is enough. Ink on paper is bimodal — nearly every
        // pixel sits hard against black or against white, with only the antialiased
        // edges in between. Flat artwork like a chart may not be bimodal but has very
        // few distinct tones. A photograph is neither.
        (function () {
          var LINE = "ag-line", PHOTO = "ag-photo";

          var judge = function (img) {
            try {
              var w = Math.max(1, Math.min(96, img.naturalWidth || 0));
              var h = Math.max(1, Math.min(96, img.naturalHeight || 0));
              var canvas = document.createElement("canvas");
              canvas.width = w; canvas.height = h;
              var ctx = canvas.getContext("2d", { willReadFrequently: true });
              // Nearest-neighbour, not averaged. Scaling a dithered engraving down with
              // smoothing on blends its blacks and whites into a spread of greys, and a
              // drawing then measures exactly like a photograph — which is the one thing
              // this has to tell apart.
              ctx.imageSmoothingEnabled = false;
              ctx.webkitImageSmoothingEnabled = false;
              ctx.drawImage(img, 0, 0, w, h);
              var data = ctx.getImageData(0, 0, w, h).data;
              var seen = new Uint8Array(256), distinct = 0, mid = 0, total = 0;
              for (var i = 0; i < data.length; i += 4) {
                if (data[i + 3] < 8) continue;          // transparent, not part of the art
                var l = (data[i] * 0.2126 + data[i + 1] * 0.7152 + data[i + 2] * 0.0722) | 0;
                if (!seen[l]) { seen[l] = 1; distinct++; }
                if (l >= 64 && l < 192) mid++;
                total++;
              }
              if (!total) return PHOTO;
              // Mid-tone density is what tells these apart. Counting distinct levels does
              // not: a line engraving saved as JPEG carries ringing artifacts across the
              // whole histogram, and measures 203 distinct levels against a photograph's
              // 253. Where they do differ is the middle of the range — that engraving
              // puts 10% of its pixels there, the photograph 59%, because ink on paper is
              // mostly ink or mostly paper and a photograph lives in the greys.
              return (mid / total < 0.30 || distinct <= 16) ? LINE : PHOTO;
            } catch (e) {
              // Cross-origin images taint the canvas and cannot be read. Fall back to
              // what the file type implies: drawings tend to arrive as SVG, GIF or PNG,
              // photographs as JPEG.
              var src = String(img.currentSrc || img.src || "").toLowerCase();
              return /\\.(svg|gif|png)(\\?|#|$)/.test(src) ? LINE : PHOTO;
            }
          };

          var mark = function (img) {
            if (img.__agJudged) return;
            if (!img.complete || !img.naturalWidth) return;
            img.__agJudged = true;
            img.classList.add(judge(img));
          };

          var sweep = function () {
            var list = document.getElementsByTagName("img");
            for (var i = 0; i < list.length; i++) {
              var img = list[i];
              mark(img);
              if (!img.__agBound) {
                img.__agBound = true;
                img.addEventListener("load", function () { mark(this); }, { once: true });
              }
            }
          };

          sweep();
          document.addEventListener("DOMContentLoaded", sweep);
          window.addEventListener("load", sweep);
        })();

        // Wrap emoji so the filter above has something to hold on to. Done here rather
        // than in Swift so no HTML has to be parsed to find the text.
        (function () {
          var EMOJI = /\\p{Extended_Pictographic}(\\uFE0F|\\uFE0E)?(\\u200D\\p{Extended_Pictographic}(\\uFE0F|\\uFE0E)?)*/gu;
          var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
            acceptNode: function (node) {
              if (!node.nodeValue || !node.nodeValue.trim()) return NodeFilter.FILTER_REJECT;
              var p = node.parentNode;
              if (!p || p.classList.contains("ag-emoji")) return NodeFilter.FILTER_REJECT;
              var tag = p.nodeName;
              if (tag === "SCRIPT" || tag === "STYLE") return NodeFilter.FILTER_REJECT;
              return EMOJI.test(node.nodeValue) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
            }
          });
          var targets = [];
          while (walker.nextNode()) { targets.push(walker.currentNode); }
          targets.forEach(function (node) {
            var frag = document.createDocumentFragment();
            var text = node.nodeValue;
            var last = 0;
            EMOJI.lastIndex = 0;
            var m;
            while ((m = EMOJI.exec(text)) !== null) {
              if (m.index > last) {
                frag.appendChild(document.createTextNode(text.slice(last, m.index)));
              }
              var span = document.createElement("span");
              span.className = "ag-emoji";
              span.textContent = m[0];
              frag.appendChild(span);
              last = m.index + m[0].length;
            }
            if (last < text.length) {
              frag.appendChild(document.createTextNode(text.slice(last)));
            }
            node.parentNode.replaceChild(frag, node);
          });
        })();

        window.addEventListener("load", function () {
          post("ready", 1);
          // Every image has either finished loading or failed by the time this fires,
          // which the earlier "ready" post — sent as soon as DOMContentLoaded, before a
          // single picture has necessarily laid out — cannot promise. See settleScroll().
          post("settled", 1);
        });
        document.addEventListener("DOMContentLoaded", function () { post("ready", 1); });

        // An in-document link — a footnote, a table-of-contents entry, a cross-reference
        // — is still, to WKWebView, a link, and `decidePolicyFor` treats every activated
        // link the same way: cancel the navigation and send it to `onOpenLink`, which
        // opens the amber browser. That is right for a link out to the web and wrong for
        // one that only means "scroll to this id" — so a same-document href is handled
        // here, before it becomes a navigation at all.
        document.addEventListener("click", function (e) {
          var a = e.target && e.target.closest && e.target.closest("a");
          if (!a) return;
          var href = a.getAttribute("href") || "";
          if (href.charAt(0) !== "#" || href.length < 2) return;
          e.preventDefault();
          window.__ag.goto(href.slice(1));
        });

        // A bare tap on the page toggles the app's chrome. Anything that is really a
        // scroll, a link, or a text selection must not count, so the gesture is judged
        // on distance and duration rather than on the click event alone.
        var tapX = 0, tapY = 0, tapAt = 0, tapEligible = false;
        document.addEventListener("pointerdown", function (e) {
          tapX = e.clientX; tapY = e.clientY; tapAt = Date.now();
          tapEligible = !(e.target && e.target.closest && e.target.closest("a"));
        }, { passive: true });
        document.addEventListener("pointerup", function (e) {
          if (!tapEligible) return;
          if (Date.now() - tapAt > 400) return;
          if (Math.abs(e.clientX - tapX) > 8 || Math.abs(e.clientY - tapY) > 8) return;
          var sel = window.getSelection ? String(window.getSelection()) : "";
          if (sel.length) return;
          post("tap", 1);
        }, { passive: true });
        </script>
        </body>
        </html>
        """
    }

    private static func coverImageTag(_ article: SavedArticle) -> String {
        guard let asset = article.coverAsset else { return "" }
        let extra = article.coverAssetClass.map { " \($0)" } ?? ""
        return "<img class=\"ag-cover\(extra)\" src=\"\(OfflineAssets.scheme)://\(article.id.uuidString)/\(escape(asset))\" alt=\"\">"
    }

    private static func bylineLine(_ article: SavedArticle) -> String {
        guard let byline = article.byline, !byline.isEmpty else { return "" }
        return "<div class=\"ag-byline\">\(escape(byline))</div>"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
