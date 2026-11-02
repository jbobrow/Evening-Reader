import Foundation

/// Prepares arbitrary live web pages for the amber panel.
///
/// The color conversion itself is *not* done here. An earlier version applied an SVG
/// `feColorMatrix` duotone to `<html>`, but page elements that get their own
/// compositing layer — Wikipedia's sticky table-of-contents and appearance panels are
/// the canonical example — are composited outside the root's filter and survive it
/// untouched, leaking white boxes and blue links onto the panel. Since the app's one
/// rule is that nothing may introduce a second hue, a filter that *usually* works is
/// not good enough: the grayscale + amber mapping is applied natively to the whole
/// rendered web view instead (see `BrowseScreen`), which page content cannot escape.
///
/// What is left for the DOM is the part that has to happen in page coordinates: the
/// pixel grid, and the pictures that have to opt out of night's flip.
struct WebTint {

    static func script(showGrid: Bool, isNight: Bool) -> String {
        let gridOpacity = showGrid ? "0.5" : "0"
        // Night's polarity flip is a negative `.contrast()` over the whole rendered view
        // (see `BrowseScreen`), which reads as a page turning to ink — right for text and
        // backgrounds, wrong for a photograph or a video frame, which comes out looking
        // like a photo negative. Pre-inverting those elements here cancels the flip
        // algebraically: `contrast(-k)` of `1 - x` is exactly `contrast(k)` of `x` (given
        // grayscale weights that sum to 1, so `luma(invert(c)) == 1 - luma(c)` too), so a
        // pixel that arrives pre-inverted comes out the other side reading as a positive
        // again, tinted by the same ink as everything else. Applied to the element
        // directly rather than to an ancestor, so it holds regardless of whether the
        // element got its own compositing layer.
        //
        // `!important`, because a site's own filter on the element — a brightness
        // tweak, a blur-up placeholder — is set inline as often as not, and an inline
        // style beats an ordinary rule. What it does not beat is an important one.
        let mediaInvert = isNight
            ? "img, video, canvas { filter: invert(1) !important; }"
            : ""

        return """
        (function () {
          // No background is set on the page. One that declares none already sits on
          // white — the web view is opaque and white behind it (see `BrowserModel`) — and
          // setting one on <html> was worse than redundant: it stops the body's own
          // background standing in for the canvas, so the body paints as an ordinary
          // box over anything a page puts at a negative z-index. Kindle's reader keeps
          // its pages there, and read as a blank white sheet.
          var styleID = 'ag-page-style';
          var style = document.getElementById(styleID);
          if (!style) {
            style = document.createElement('style');
            style.id = styleID;
            (document.head || document.documentElement).appendChild(style);
          }
          style.textContent = [
            // WebKit's own control bar reaches fullscreen through an internal path, not
            // through the JS methods overridden below, so it cannot be redirected into
            // the in-page version — and what it opens is a window the filter cannot
            // reach. The button is taken away instead; a site's own fullscreen control
            // still works, because that one does go through JS.
            'video::-webkit-media-controls-fullscreen-button { display: none !important; }',
            'html::after {',
            '  content: ""; position: fixed; inset: 0; pointer-events: none;',
            '  z-index: 2147483000; mix-blend-mode: multiply; opacity: \(gridOpacity);',
            '  background-image:',
            '    repeating-linear-gradient(0deg, rgba(0,0,0,0.055) 0 1px, transparent 1px 2px),',
            '    repeating-linear-gradient(90deg, rgba(0,0,0,0.055) 0 1px, transparent 1px 2px);',
            '}',
            '\(mediaInvert)'
          ].join('\\n');

          // The media rule again, inside every shadow root.
          //
          // A page's stylesheet stops at a shadow boundary, and a player built as a web
          // component keeps its <video> behind one — which is how a video came to be
          // the one thing on a page still showing as a negative at night. Roots opened
          // from here on are caught as they are made; roots that already exist, and
          // the ones the parser made, are found by walking. One shared sheet, adopted
          // by each root rather than appended to it, so a component that rewrites its
          // own contents does not throw the rule out with them — and so a change of
          // polarity is one edit rather than one per root.
          (function () {
            var S = window.__agShadow;
            if (!S) {
              S = window.__agShadow = { css: '', sheet: null, roots: [] };
              try { S.sheet = new CSSStyleSheet(); } catch (e) { S.sheet = null; }
              S.style = function (root) {
                try {
                  if (S.sheet) {
                    if (root.adoptedStyleSheets.indexOf(S.sheet) < 0) {
                      root.adoptedStyleSheets = root.adoptedStyleSheets.concat([S.sheet]);
                    }
                  } else {
                    var el = root.querySelector('style#ag-media-style');
                    if (!el) {
                      el = document.createElement('style');
                      el.id = 'ag-media-style';
                      root.appendChild(el);
                    }
                    el.textContent = S.css;
                  }
                } catch (e) {}
              };
              S.adopt = function (root) {
                if (!root || root.__agAdopted) return;
                root.__agAdopted = true;
                S.roots.push(root);
                S.style(root);
              };
              S.sweep = function (node) {
                if (!node || !node.querySelectorAll) return;
                var all = node.querySelectorAll('*');
                for (var i = 0; i < all.length; i++) {
                  var r = all[i].shadowRoot;
                  if (r && !r.__agAdopted) { S.adopt(r); S.sweep(r); }
                }
              };
              var orig = Element.prototype.attachShadow;
              if (orig) {
                Element.prototype.attachShadow = function (init) {
                  var root = orig.call(this, init);
                  S.adopt(root);
                  return root;
                };
              }
            }
            S.css = '\(mediaInvert)';
            if (S.sheet) { try { S.sheet.replaceSync(S.css); } catch (e) {} }
            S.roots.forEach(S.style);
            S.sweep(document);
          })();

          // Which field has the focus, and whether it is one AutoFill has anything
          // for — a password, or a name or address that stands beside one.
          (function () {
            if (window.__agFieldReporter) return;
            window.__agFieldReporter = true;
            var loginLike = function (el) {
              if (!el || !/^input$/i.test(el.tagName || "")) return false;
              var type = String(el.type || "").toLowerCase();
              var auto = String(el.getAttribute("autocomplete") || "").toLowerCase();
              if (type === "password" || type === "email") return true;
              if (/username|password|email|one-time-code|tel/.test(auto)) return true;
              var form = el.form || (el.closest ? el.closest("form") : null);
              return !!(form && form.querySelector && form.querySelector('input[type="password"]'));
            };
            var report = function (el) {
              try {
                window.webkit.messageHandlers.browse.postMessage({ name: "field", login: loginLike(el) });
              } catch (e) {}
            };
            document.addEventListener("focusin", function (e) { report(e.target); }, { capture: true, passive: true });
            var active = document.activeElement;
            if (active && /^(input|textarea)$/i.test(active.tagName || "")) report(active);

            // Paste, offered over an empty field as it is taken up or tapped — the small
            // callout the system shows there, which the app draws itself since the
            // system's is suppressed. Only the field's box is sent; whether there is
            // anything to paste is the app's to know, and the offer is withdrawn by the
            // first edit or by the field letting go.
            var textTypes = /^(text|search|url|email|tel|password|number)$/;
            var empty = function (el) {
              if (!el || el.disabled || el.readOnly) return false;
              var tag = (el.tagName || "").toLowerCase();
              if (tag === "textarea") return !el.value;
              if (tag === "input") return textTypes.test(String(el.type || "text").toLowerCase()) && !el.value;
              return !!el.isContentEditable && !(el.textContent || "").trim();
            };
            var offered = null;
            var say = function (payload) {
              payload.name = "pasteOffer";
              try { window.webkit.messageHandlers.browse.postMessage(payload); } catch (e) {}
            };
            var offer = function (el) {
              if (!empty(el)) { withdraw(); return; }
              offered = el;
              // Over the caret, which in an empty field sits just inside its leading
              // edge — not over the middle of a field that may run the width of the page.
              var b = el.getBoundingClientRect(), cs = getComputedStyle(el);
              var rtl = cs.direction === "rtl";
              var inset = (parseFloat(rtl ? cs.paddingRight : cs.paddingLeft) || 0)
                + (parseFloat(rtl ? cs.borderRightWidth : cs.borderLeftWidth) || 0);
              say({ x: rtl ? b.right - inset : b.left + inset, y: b.top, w: 0, h: b.height });
            };
            var withdraw = function () {
              if (!offered) return;
              offered = null;
              say({});
            };
            // After a beat, so the page has scrolled the field into view for the keyboard.
            document.addEventListener("focusin", function (e) {
              var el = e.target;
              setTimeout(function () { if (document.activeElement === el) offer(el); }, 250);
            }, { capture: true, passive: true });
            document.addEventListener("click", function (e) {
              var el = document.activeElement;
              if (el && el === e.target) offer(el);
            }, { capture: true, passive: true });
            document.addEventListener("input", withdraw, { capture: true, passive: true });
            document.addEventListener("focusout", withdraw, { capture: true, passive: true });
            // The callout is drawn in the page's coordinates, so it follows the field.
            var follow = function () { if (offered) offer(offered); };
            window.addEventListener("scroll", follow, { capture: true, passive: true });
            window.addEventListener("resize", follow, { passive: true });
          })();

          // Each frame says hello once, so a change of polarity can be sent to it
          // later: script run against the web view reaches the top document only, and
          // the frames a page is built from — an embedded player, an ad — would keep
          // the old rule until they were reloaded.
          if (!window.__agFrameSaid) {
            window.__agFrameSaid = true;
            try { window.webkit.messageHandlers.browse.postMessage({ name: 'frame' }); } catch (e) {}
          }

          \(SelectionReporter.script(handler: "browse"))

          \(DocumentPager.script(handler: "browse"))

          // A plain tap on the page — not a link, a control, a drag or a selection —
          // is reported, so the bar can come back.
          (function () {
            if (window.__agTapReporter) return;
            window.__agTapReporter = true;
            var x0 = 0, y0 = 0, t0 = 0;
            // When a finger was last on the page, for the scroll listener below.
            var touching = false, lastTouch = 0;
            var controls = 'a,button,input,textarea,select,label,video,audio,summary,'
              + 'iframe,[role=button],[role=link],[onclick],[contenteditable]';
            document.addEventListener('touchstart', function (e) {
              touching = true;
              lastTouch = Date.now();
              if (e.touches.length !== 1) { t0 = 0; return; }
              x0 = e.touches[0].clientX; y0 = e.touches[0].clientY; t0 = Date.now();
            }, { passive: true, capture: true });
            var lift = function (e) {
              touching = e.touches.length > 0;
              lastTouch = Date.now();
            };
            document.addEventListener('touchmove', function () { lastTouch = Date.now(); }, { passive: true, capture: true });
            document.addEventListener('touchcancel', lift, { passive: true, capture: true });
            document.addEventListener('touchend', function (e) {
              lift(e);
              if (!t0) return;
              var t = e.changedTouches[0], held = Date.now() - t0;
              t0 = 0;
              if (held > 350 || Math.abs(t.clientX - x0) > 10 || Math.abs(t.clientY - y0) > 10) return;
              var el = document.elementFromPoint(t.clientX, t.clientY);
              if (el && el.closest && el.closest(controls)) return;
              var sel = window.getSelection && window.getSelection();
              if (sel && !sel.isCollapsed) return;
              window.webkit.messageHandlers.browse.postMessage({ name: 'tap' });
            }, { passive: true, capture: true });

            // Scrolling, wherever it happens. An app-like page scrolls a box of its own
            // and the document never moves, so the web view's own scroll view would
            // never know. Listening in the capture phase hears every box. Only a change
            // of direction, past a little travel, is reported — never every frame.
            //
            // And only scrolling the reader did: under a finger, or in the glide after
            // one. A page that scrolls itself — as a reader app does when it lays its
            // pages out again for a new window size — is not asking for the bar.
            var tops = new WeakMap(), run = 0, shown = true;
            var say = function (show) {
              if (show === shown) return;
              shown = show;
              window.webkit.messageHandlers.browse.postMessage({ name: 'chrome', show: show });
            };
            document.addEventListener('scroll', function (e) {
              var el = (e.target === document) ? (document.scrollingElement || document.documentElement) : e.target;
              if (!el || typeof el.scrollTop !== 'number') return;
              var top = el.scrollTop, prev = tops.get(el);
              tops.set(el, top);
              if (prev === undefined) return;
              if (!touching && Date.now() - lastTouch > 1200) { run = 0; return; }
              var d = top - prev;
              if (Math.abs(d) < 1) return;
              run = ((d > 0) === (run > 0)) ? run + d : d;
              if (top <= 8) { say(true); run = 0; return; }
              if (run > 24 && top > 80) { say(false); run = 0; }
              else if (run < -24) { say(true); run = 0; }
            }, { passive: true, capture: true });
          })();

          // Fullscreen, kept inside the page.
          //
          // The real thing is presented in a window of its own, above everything the app
          // draws, and nothing can filter that window's contents from outside — a video
          // that went fullscreen would be the only thing on screen in full colour. So
          // the page is given a fullscreen of its own instead: the video is pinned over
          // the whole page and everything else in it is hidden, the site's own player
          // included, and the app draws the controls — play, where you are, and the way
          // out — over it (see `VideoControls`). It is all still the page, so the
          // panel's tint is still on it.
          //
          // Leaving is the app's to do, in its own order: the phone turned back upright
          // first, and only then the video let go of. Let go of while the glass is still
          // turning, a playing video can be left drawing nothing where it lands.
          //
          // Only the top document. A player in a frame could only fill its frame, which
          // is no fullscreen at all, so there the request is refused.
          (function () {
            if (window.__agFullscreen) return;
            window.__agFullscreen = true;

            var isTop = window.top === window;
            var refuse = function () { return Promise.reject(new Error("disabled")); };
            var ignore = function () {};
            // What the page asked for, as the page will ask after it, and what is pinned
            // for it: the video inside it when there is one, else the element itself.
            var current = null;
            var pinned = null;

            var css = document.createElement('style');
            css.id = 'ag-fullscreen-style';
            css.textContent = [
              '.ag-fs { position: fixed !important; inset: 0 !important;',
              '  width: 100vw !important; height: 100vh !important;',
              '  max-width: none !important; max-height: none !important;',
              '  margin: 0 !important; transform: none !important;',
              '  z-index: 2147482000 !important; background: #000 !important; }',
              'video.ag-fs { object-fit: contain !important; }',
              // A box with a transform, a filter or the like is what a fixed element
              // inside it is placed against, and one that hides its overflow cuts it
              // off at its own edges — YouTube's player does both — so those round
              // what is pinned are set aside while it is.
              '.ag-fs-around { transform: none !important; filter: none !important;',
              '  perspective: none !important; contain: none !important;',
              '  will-change: auto !important; backdrop-filter: none !important;',
              '  overflow: visible !important; clip-path: none !important; mask: none !important; }',
              // The page under the video is black, not the page's own white, wherever
              // the video does not reach.
              'html.ag-fs-on, html.ag-fs-on body { overflow: hidden !important;',
              '  background: #000 !important; }',
              // A page's own fixed bars can sit in a higher layer than the video,
              // whatever its z-index, so the rest of the page is hidden rather than
              // covered.
              'html.ag-fs-on body :not(.ag-fs, .ag-fs *) { visibility: hidden !important; }',
              'html.ag-fs-on .ag-fs { visibility: visible !important; }'
            ].join('\\n');
            (document.head || document.documentElement).appendChild(css);

            var post = function (message) {
              try { window.webkit.messageHandlers.browse.postMessage(message); } catch (e) {}
            };
            var videoIn = function (el) {
              return el.tagName === 'VIDEO' ? el : (el.querySelector && el.querySelector('video'));
            };
            // Where the video is, for the app's controls: a few times a second while it
            // plays, and at once when it starts, stops or is moved.
            var lastReport = 0;
            var report = function (force) {
              if (!pinned || pinned.tagName !== 'VIDEO') return;
              var now = Date.now();
              if (!force && now - lastReport < 250) return;
              lastReport = now;
              post({ name: 'video', time: pinned.currentTime || 0,
                     duration: isFinite(pinned.duration) ? pinned.duration : 0,
                     paused: pinned.paused });
            };
            var watched = ['timeupdate', 'play', 'pause', 'seeked', 'durationchange', 'ended'];
            var onVideo = function (e) { report(e.type !== 'timeupdate'); };

            // Players measure themselves on resize; the box the video is in just
            // changed. The page is not sent fullscreen events of its own: a player told
            // its video went fullscreen and came back rebuilds around it, and YouTube's
            // was left drawing nothing where the video landed. Its controls are hidden
            // with the rest of the page anyway — the app's stand in for them.
            var nudge = function () {
              setTimeout(function () { window.dispatchEvent(new Event('resize')); }, 0);
              setTimeout(function () { window.dispatchEvent(new Event('resize')); }, 350);
            };
            var around = function (el, on) {
              for (var p = el.parentElement; p && p !== document.documentElement; p = p.parentElement) {
                p.classList.toggle('ag-fs-around', on);
              }
            };
            var release = function () {
              if (!current) return;
              watched.forEach(function (t) { pinned.removeEventListener(t, onVideo); });
              pinned.classList.remove('ag-fs');
              around(pinned, false);
              current = null;
              pinned = null;
              document.documentElement.classList.remove('ag-fs-on');
              nudge();
              post({ name: 'fullscreen', on: false });
            };
            // The page asked to leave: the app does it, in its order.
            var askToLeave = function () {
              if (current) post({ name: 'fullscreenLeave' });
            };
            var enter = function (el) {
              // A player can ask twice as it sets itself up; what is up stays up.
              if (current && (current === el || pinned === el || el.contains(pinned))) return;
              if (current) release();
              current = el;
              pinned = videoIn(el) || el;
              pinned.classList.add('ag-fs');
              around(pinned, true);
              document.documentElement.classList.add('ag-fs-on');
              watched.forEach(function (t) { pinned.addEventListener(t, onVideo); });
              nudge();
              post({ name: 'fullscreen', on: true, video: pinned.tagName === 'VIDEO' });
              report(true);
            };
            // The app's side of the controls.
            window.__agVideo = {
              release: release,
              toggle: function () {
                if (!pinned || pinned.tagName !== 'VIDEO') return;
                if (pinned.paused) { try { pinned.play(); } catch (e) {} } else { pinned.pause(); }
              },
              seek: function (t) {
                if (!pinned || pinned.tagName !== 'VIDEO') return;
                try { pinned.currentTime = t; } catch (e) {}
                report(true);
              },
              // The phone turned sideways with a video playing: that video, the
              // largest one playing if there are several, goes fullscreen. Says
              // whether there was one.
              enterPlaying: function () {
                if (current || !isTop) return false;
                var best = null, bestArea = 0;
                var list = document.getElementsByTagName('video');
                for (var i = 0; i < list.length; i++) {
                  var v = list[i];
                  if (v.paused || v.ended || v.readyState < 2) continue;
                  var r = v.getBoundingClientRect();
                  var area = r.width * r.height;
                  if (area > bestArea) { best = v; bestArea = area; }
                }
                if (!best || bestArea < 100 * 60) return false;
                enter(best);
                return true;
              }
            };

            if (isTop) {
              Element.prototype.requestFullscreen = function () { enter(this); return Promise.resolve(); };
              Element.prototype.webkitRequestFullscreen = function () { enter(this); };
              Element.prototype.webkitRequestFullScreen = function () { enter(this); };
              document.exitFullscreen = function () { askToLeave(); return Promise.resolve(); };
              document.webkitExitFullscreen = askToLeave;
              document.webkitCancelFullScreen = askToLeave;
              if (window.HTMLVideoElement) {
                HTMLVideoElement.prototype.webkitEnterFullscreen = function () { enter(this); };
                HTMLVideoElement.prototype.webkitEnterFullScreen = function () { enter(this); };
                HTMLVideoElement.prototype.webkitExitFullscreen = askToLeave;
                HTMLVideoElement.prototype.webkitExitFullScreen = askToLeave;
                try {
                  Object.defineProperty(HTMLVideoElement.prototype, 'webkitDisplayingFullscreen', {
                    configurable: true,
                    get: function () { return !!pinned && pinned === this; }
                  });
                } catch (e) {}
              }
            } else {
              Element.prototype.requestFullscreen = refuse;
              Element.prototype.webkitRequestFullscreen = ignore;
              Element.prototype.webkitRequestFullScreen = ignore;
              if (window.HTMLVideoElement) {
                HTMLVideoElement.prototype.webkitEnterFullscreen = ignore;
                HTMLVideoElement.prototype.webkitEnterFullScreen = ignore;
              }
            }
            // Pages check these to decide whether to offer the control at all, and
            // which state their own control should show.
            var define = function (name, get) {
              try { Object.defineProperty(document, name, { configurable: true, get: get }); }
              catch (e) {}
            };
            define('fullscreenEnabled', function () { return isTop; });
            define('webkitFullscreenEnabled', function () { return isTop; });
            define('fullscreenElement', function () { return current; });
            define('webkitFullscreenElement', function () { return current; });
            define('webkitCurrentFullScreenElement', function () { return current; });
            define('webkitIsFullScreen', function () { return !!current; });
            define('fullscreen', function () { return !!current; });

            var pinAll = function (list) {
              for (var i = 0; i < list.length; i++) {
                list[i].setAttribute("playsinline", "");
                list[i].setAttribute("webkit-playsinline", "");
              }
            };
            var pin = function () {
              pinAll(document.getElementsByTagName("video"));
              // Players built as web components keep their <video> behind a shadow
              // boundary, where getElementsByTagName does not look.
              var S = window.__agShadow;
              if (S) {
                S.sweep(document);
                for (var i = 0; i < S.roots.length; i++) {
                  try { pinAll(S.roots[i].querySelectorAll("video")); } catch (e) {}
                }
              }
            };
            pin();
            if (window.MutationObserver && document.documentElement) {
              // Settled rather than on every mutation: a walk of the whole tree is
              // the wrong price for each node a busy page adds.
              var pending;
              new MutationObserver(function () {
                clearTimeout(pending);
                pending = setTimeout(pin, 300);
              }).observe(document.documentElement, { childList: true, subtree: true });
            }
          })();


          // Remove the retired duotone plumbing if it is still in the document from a
          // page that was tinted before this build.
          ['ag-duotone-svg', 'ag-duotone-style'].forEach(function (id) {
            var el = document.getElementById(id);
            if (el && el.parentNode) { el.parentNode.removeChild(el); }
          });
        })();
        """
    }
}
