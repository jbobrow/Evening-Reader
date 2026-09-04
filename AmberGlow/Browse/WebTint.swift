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
/// white base a duotone expects, and the pixel grid.
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
        let mediaInvert = isNight
            ? "img, video, canvas { filter: invert(1); }"
            : ""

        return """
        (function () {
          // A page that never declares its own background should sit on white, so the
          // native ramp maps it to the top of the glow rather than to transparent black.
          var styleID = 'ag-page-style';
          var style = document.getElementById(styleID);
          if (!style) {
            style = document.createElement('style');
            style.id = styleID;
            (document.head || document.documentElement).appendChild(style);
          }
          style.textContent = [
            'html { background: #ffffff !important; }',
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

          \(SelectionReporter.script(handler: "browse"))

          \(DocumentPager.script(handler: "browse"))

          // A plain tap on the page — not a link, a control, a drag or a selection —
          // is reported, so the bar can come back.
          (function () {
            if (window.__agTapReporter) return;
            window.__agTapReporter = true;
            var x0 = 0, y0 = 0, t0 = 0;
            var controls = 'a,button,input,textarea,select,label,video,audio,summary,'
              + 'iframe,[role=button],[role=link],[onclick],[contenteditable]';
            document.addEventListener('touchstart', function (e) {
              if (e.touches.length !== 1) { t0 = 0; return; }
              x0 = e.touches[0].clientX; y0 = e.touches[0].clientY; t0 = Date.now();
            }, { passive: true, capture: true });
            document.addEventListener('touchend', function (e) {
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
              var d = top - prev;
              if (Math.abs(d) < 1) return;
              run = ((d > 0) === (run > 0)) ? run + d : d;
              if (top <= 8) { say(true); run = 0; return; }
              if (run > 24 && top > 80) { say(false); run = 0; }
              else if (run < -24) { say(true); run = 0; }
            }, { passive: true, capture: true });
          })();

          // Fullscreen is refused.
          //
          // It is presented in a window of its own, above everything the app draws, and
          // nothing can filter that window's contents from outside — a video that went
          // fullscreen would be the only thing on screen in full colour. Every route to
          // it is closed here, and video is pinned inline instead.
          (function () {
            if (window.__agNoFullscreen) return;
            window.__agNoFullscreen = true;

            var refuse = function () { return Promise.reject(new Error("disabled")); };
            var ignore = function () {};

            Element.prototype.requestFullscreen = refuse;
            Element.prototype.webkitRequestFullscreen = ignore;
            Element.prototype.webkitRequestFullScreen = ignore;
            if (window.HTMLVideoElement) {
              HTMLVideoElement.prototype.webkitEnterFullscreen = ignore;
              HTMLVideoElement.prototype.webkitEnterFullScreen = ignore;
            }
            // Pages check these to decide whether to offer the control at all.
            try {
              Object.defineProperty(document, "fullscreenEnabled",
                { configurable: true, get: function () { return false; } });
              Object.defineProperty(document, "webkitFullscreenEnabled",
                { configurable: true, get: function () { return false; } });
            } catch (e) {}

            var pin = function () {
              var list = document.getElementsByTagName("video");
              for (var i = 0; i < list.length; i++) {
                list[i].setAttribute("playsinline", "");
                list[i].setAttribute("webkit-playsinline", "");
              }
            };
            pin();
            if (window.MutationObserver && document.documentElement) {
              new MutationObserver(pin).observe(document.documentElement,
                                                { childList: true, subtree: true });
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
