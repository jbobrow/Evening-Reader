import Foundation

/// The page-side half of highlighting: marks passages, hands one back when the reader
/// makes it, and finds one again later.
///
/// A highlight is anchored by a character offset counted through the article's own text,
/// not by a selector into its tree. The tree is not stable — the emoji pass rewrites text
/// nodes, the picture pass adds classes, and every mark already on the page splits a text
/// node in two — but the text is: the document is rebuilt from the same stored
/// `body.html` on every open. Offsets survive all of that, and the one thing they do not
/// survive, a re-extracted body, is caught by looking for the passage itself and taking
/// the occurrence nearest where it used to be.
enum HighlightMarker {

    static func script(handler: String) -> String {
        """
        window.__agHL = (function () {
          var post = function (payload) {
            try { window.webkit.messageHandlers.\(handler).postMessage(payload); } catch (e) {}
          };

          var root = function () { return document.querySelector("article") || document.body; };

          // Every text node under the article, in order, with the offset each one starts
          // at. Rebuilt on every call rather than cached: marking a passage splits the
          // nodes it lands in, so any index outlives at most one operation. The *text* it
          // measures is unchanged by that, which is the whole point of counting it.
          var index = function () {
            var walker = document.createTreeWalker(root(), NodeFilter.SHOW_TEXT, {
              acceptNode: function (node) {
                var tag = node.parentNode ? node.parentNode.nodeName : "";
                if (tag === "SCRIPT" || tag === "STYLE") return NodeFilter.FILTER_REJECT;
                return NodeFilter.FILTER_ACCEPT;
              }
            });
            var nodes = [], at = 0, text = "", node;
            while ((node = walker.nextNode())) {
              var value = node.nodeValue || "";
              nodes.push({ node: node, start: at, end: at + value.length });
              text += value;
              at += value.length;
            }
            return { nodes: nodes, text: text };
          };

          var inMark = function (node) {
            var el = node.parentNode;
            while (el && el !== document.body) {
              if (el.nodeName === "MARK" && el.classList.contains("ag-hl")) return true;
              el = el.parentNode;
            }
            return false;
          };

          // Take every mark back out, leaving the text exactly as it was. `normalize`
          // rejoins the halves a split left behind, so the next index is the same one the
          // offsets were written against.
          var strip = function () {
            var marks = root().querySelectorAll("mark.ag-hl");
            for (var i = 0; i < marks.length; i++) {
              var mark = marks[i], parent = mark.parentNode;
              if (!parent) continue;
              while (mark.firstChild) { parent.insertBefore(mark.firstChild, mark); }
              parent.removeChild(mark);
              parent.normalize();
            }
          };

          // Wrap [start, end) in <mark>, however many elements it runs across. Each
          // covered text node is split down to just the covered part and that part is
          // wrapped on its own — a single Range cannot be surrounded once it crosses an
          // element boundary, which any passage longer than a sentence does.
          var wrap = function (start, end, id, hasNote) {
            var idx = index();
            var pieces = [];
            for (var i = 0; i < idx.nodes.length; i++) {
              var entry = idx.nodes[i];
              if (entry.end <= start || entry.start >= end) continue;
              if (inMark(entry.node)) continue;      // an overlapping mark already has it
              var from = Math.max(0, start - entry.start);
              var to = Math.min(entry.node.nodeValue.length, end - entry.start);
              if (to <= from) continue;
              pieces.push({ node: entry.node, from: from, to: to });
            }
            for (var j = 0; j < pieces.length; j++) {
              var piece = pieces[j], node = piece.node;
              if (piece.to < node.nodeValue.length) { node.splitText(piece.to); }
              var target = piece.from > 0 ? node.splitText(piece.from) : node;
              var mark = document.createElement("mark");
              mark.className = hasNote ? "ag-hl ag-hl-note" : "ag-hl";
              mark.setAttribute("data-hl", id);
              target.parentNode.replaceChild(mark, target);
              mark.appendChild(target);
            }
            return pieces.length > 0;
          };

          // Where a stored passage sits now. The offset is a hint, checked before it is
          // trusted; if it no longer spells the passage, the nearest occurrence that does
          // wins, and if the passage has gone from the document entirely the mark is
          // simply not drawn — the highlight itself is still in the list.
          var locate = function (text, passage, hint) {
            if (!passage) return -1;
            if (typeof hint === "number" && text.substr(hint, passage.length) === passage) {
              return hint;
            }
            var target = (typeof hint === "number") ? hint : 0;
            var best = -1, closest = Infinity, at = text.indexOf(passage);
            while (at !== -1) {
              var distance = Math.abs(at - target);
              if (distance < closest) { closest = distance; best = at; }
              at = text.indexOf(passage, at + 1);
            }
            return best;
          };

          // Where a Range boundary falls in the same count. A boundary can land on an
          // element rather than on text — between two paragraphs, say — in which case it
          // means the first text inside the child it points at.
          var offsetOf = function (idx, container, offset) {
            var i;
            if (container.nodeType === 3) {
              for (i = 0; i < idx.nodes.length; i++) {
                if (idx.nodes[i].node === container) return idx.nodes[i].start + offset;
              }
              return -1;
            }
            var child = container.childNodes[offset];
            if (!child) {
              var last = -1;
              for (i = 0; i < idx.nodes.length; i++) {
                if (container.contains(idx.nodes[i].node)) { last = idx.nodes[i].end; }
              }
              return last;
            }
            for (i = 0; i < idx.nodes.length; i++) {
              if (child === idx.nodes[i].node || child.contains(idx.nodes[i].node)) {
                return idx.nodes[i].start;
              }
            }
            return -1;
          };

          // The block a text node reads as part of — its paragraph, heading or list item:
          // the nearest ancestor that is laid out as a block rather than run inline.
          var blockOf = function (node) {
            var el = node.parentNode;
            while (el && el !== document.body) {
              var display = window.getComputedStyle(el).display;
              if (display && display.indexOf("inline") !== 0 && display !== "contents") return el;
              el = el.parentNode;
            }
            return document.body;
          };

          // Where [start, end) passes from one block into the next, counted from
          // `start`. The text alone cannot say: two paragraphs saved with nothing
          // between their tags spell "the end.The next", and it is only the elements
          // that know a break stood there. Whitespace-only nodes — the indentation
          // between tags — belong to no paragraph a reader sees, and are passed over.
          var breaksIn = function (idx, start, end) {
            var out = [], last = null;
            for (var i = 0; i < idx.nodes.length; i++) {
              var entry = idx.nodes[i];
              if (entry.end <= start || entry.start >= end) continue;
              if (!entry.node.nodeValue.trim()) continue;
              var block = blockOf(entry.node);
              if (last && block !== last) out.push(Math.max(entry.start, start) - start);
              last = block;
            }
            return out;
          };

          // Which chapter the passage came out of, for a book. Nothing else has one.
          var chapterAt = function (node) {
            var el = node.nodeType === 1 ? node : node.parentNode;
            while (el && el !== document.body) {
              if (el.classList && el.classList.contains("ag-chapter")) {
                var title = el.querySelector(".ag-chapter-title");
                return title ? title.textContent.trim() : "";
              }
              el = el.parentNode;
            }
            return "";
          };

          return {
            /// Draw the whole set, replacing whatever is drawn now.
            ///
            /// A passage marked before its breaks were kept has them worked out here,
            /// while it is found, and handed back for the app to keep — so the quote
            /// reads properly from then on. Found first and wrapped
            /// after: wrapping splits the nodes the breaks are read from.
            apply: function (list) {
              strip();
              var idx = index(), found = [], owed = {}, owes = false;
              for (var i = 0; i < list.length; i++) {
                var item = list[i];
                var start = locate(idx.text, item.text, item.offset);
                if (start < 0) continue;
                found.push({ item: item, start: start });
                if (!item.hasBreaks) {
                  owed[item.id] = breaksIn(idx, start, start + item.text.length);
                  owes = true;
                }
              }
              for (var j = 0; j < found.length; j++) {
                var hit = found[j];
                wrap(hit.start, hit.start + hit.item.text.length, hit.item.id, !!hit.item.note);
              }
              if (owes) post({ name: "highlightBreaks", value: owed });
            },

            /// Hand back what is selected right now, anchored, for the app to save.
            ///
            /// The passage is read out of the index rather than taken from the selection's
            /// own string: `String(selection)` inserts breaks of its own where the
            /// selection crosses a block, and a passage that does not match the document
            /// character for character is one the offset cannot be checked against.
            capture: function () {
              var sel = window.getSelection();
              if (!sel || sel.isCollapsed || sel.rangeCount === 0) return;
              var range = sel.getRangeAt(0);
              var idx = index();
              var start = offsetOf(idx, range.startContainer, range.startOffset);
              var end = offsetOf(idx, range.endContainer, range.endOffset);
              if (start < 0 || end < 0 || end <= start) return;
              var passage = idx.text.substring(start, end);
              if (!passage.trim()) return;
              post({
                name: "highlight",
                text: passage,
                offset: start,
                breaks: breaksIn(idx, start, end),
                progress: window.__ag ? window.__ag.progress() : 0,
                chapter: chapterAt(range.startContainer)
              });
            },

            /// Bring one into view — the jump from the highlights list.
            reveal: function (id) {
              var mark = root().querySelector('mark.ag-hl[data-hl="' + id + '"]');
              if (mark) { mark.scrollIntoView({ block: "center" }); }
            }
          };
        })();

        // A mark is the one thing on the page that a tap means something particular on:
        // it opens its own note rather than putting the chrome away.
        document.addEventListener("click", function (e) {
          var mark = e.target && e.target.closest && e.target.closest("mark.ag-hl");
          if (!mark) return;
          var sel = window.getSelection ? String(window.getSelection()) : "";
          if (sel.length) return;
          e.preventDefault();
          try {
            window.webkit.messageHandlers.\(handler).postMessage({
              name: "markTap", value: mark.getAttribute("data-hl")
            });
          } catch (err) {}
        });
        """
    }
}
