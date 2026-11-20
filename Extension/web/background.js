// "Save to Evening Reader" for Chrome and Safari on the Mac.
//
// The article is read out of the page the reader has open — with the app's own
// extraction scripts, `extract.js` and Defuddle, so it comes out as it would in the app,
// and with whatever the reader is signed in to see. The native side — a native messaging
// host in Chrome, the extension's own handler in Safari — stores it in the library in
// iCloud the way the app stores a page it fetched itself, so it arrives on every device
// ready to read, offline, without Evening Reader having been opened.
//
// A page that can't be read here — a link saved from a context menu, the browser's own
// pages, anything the scripts can't make sense of — is queued by address instead, the
// same as the share sheet does on the phone, and the app fetches it when it next opens.

const api = globalThis.browser ?? globalThis.chrome;

// Chrome looks the host up by this name; Safari ignores it and talks to the extension's
// own handler.
const HOST = "com.jonbobrow.eveningreader";

// Where to get the helper: the Mac app, Evening Reader Helper, which sets Chrome up when
// it's opened.
const HELPER_PAGE = "https://eveningreader.jonbobrow.com/mac.html";

api.runtime.onInstalled.addListener(async () => {
  await api.contextMenus.removeAll();
  api.contextMenus.create({
    id: "save-page",
    title: "Save Page to Evening Reader",
    contexts: ["page"],
  });
  api.contextMenus.create({
    id: "save-link",
    title: "Save Link to Evening Reader",
    contexts: ["link"],
  });
});

api.action.onClicked.addListener((tab) => {
  save(tab.url, tab.title, tab.id, true);
});

api.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId === "save-link") {
    // A link's own text is rarely its title, and its page isn't open to be read; the
    // app fetches it and names it.
    save(info.linkUrl, null, tab?.id, false);
  } else {
    save(info.pageUrl ?? tab?.url, tab?.title, tab?.id, true);
  }
});

async function save(rawURL, title, tabId, fromPage) {
  const url = normalize(rawURL);
  if (!url) {
    tell(tabId, "failed", "Only web pages can be saved.", null);
    return;
  }
  // Reading the page takes a few seconds; queuing an address takes a moment, and
  // "Saving…" is only shown if it doesn't — otherwise the card would flicker.
  let slow;
  let capture = null;
  if (fromPage && tabId != null) {
    await tell(tabId, "working", "Reading the page…", title);
    capture = await read(tabId);
    await tell(tabId, "working", "Saving…", capture?.title || title);
  } else {
    slow = setTimeout(() => tell(tabId, "working", "Saving…", title), 250);
  }

  let reply;
  try {
    reply = await api.runtime.sendNativeMessage(HOST, { action: "save", url, title: title || null, capture });
  } catch (error) {
    reply = missingHelper(error)
      ? { ok: false, error: "Evening Reader Helper isn't set up on this Mac yet.", help: true }
      : { ok: false, error: String(error?.message ?? error) };
  }
  clearTimeout(slow);
  if (reply?.ok) {
    const headline = reply.status === "resaved" ? "Already saved — back in Unread" : "Saved";
    const note = reply.captured
      ? "Ready to read, offline too."
      : "Evening Reader will fetch it the next time it opens.";
    tell(tabId, "saved", headline, reply.title ?? url, note);
  } else {
    const help = reply?.help
      ? { note: "Get it, open it once, then save again.", link: { label: "Get Evening Reader Helper", url: HELPER_PAGE } }
      : {};
    tell(tabId, "failed", "Couldn't save this page", reply?.error ?? "Evening Reader didn't answer.", help.note, help.link);
  }
}

// MARK: - Reading the page

// The article, read out of the open page the way `ArticleExtractor` reads one in the
// app: the page woken all the way down first, then the app's own pass, then Defuddle for
// the Markdown and as the second chance. Null when neither could make sense of it.
//
// The scripts were written for a page loaded only to be read, and they leave their marks
// on it. This page is the reader's, so whatever they take out of it is put back after.
async function read(tabId) {
  const run = async (injection) => {
    const [frame] = await api.scripting.executeScript({ target: { tabId }, ...injection });
    return frame?.result;
  };
  const decode = (json) => {
    try { return typeof json === "string" ? JSON.parse(json) : null; } catch { return null; }
  };
  try {
    await run({ func: wakeLazyContent });
    await run({ func: watchRemovals });
    let primary, second;
    try {
      primary = decode(await run({ files: ["extract.js"] }));
      await run({ files: ["defuddle.js"] });
      second = decode(await run({ files: ["defuddle-run.js"] }));
    } finally {
      await run({ func: putBack });
    }
    const result = merged(primary, second);
    if (!result) return null;
    const { title, byline, site, published, excerpt, wordCount, html, markdown } = result;
    return { title, byline, site, published, excerpt, wordCount, html, markdown };
  } catch {
    return null;
  }
}

// `ArticleExtractor.merged`: the app's own reading, with Defuddle's Markdown and any
// detail the first pass missed; Defuddle's reading when the first pass came back empty.
function merged(primary, other) {
  if (primary?.ok) {
    if (!other) return primary;
    const out = { ...primary, markdown: other.markdown };
    for (const key of ["title", "byline", "site", "published", "excerpt", "leadImage"]) {
      if (!out[key]) out[key] = other[key];
    }
    return out;
  }
  return other?.ok ? other : null;
}

// Runs in the page. Most publishers only put a picture in as it scrolls into view, so
// the page is read down once, as `ArticleExtractor` does — and then put back where the
// reader had it. Bounded, so a page that grows as it is scrolled can't hold the save up.
async function wakeLazyContent() {
  const images = () => document.querySelectorAll('img[loading="lazy"]');
  images().forEach((i) => { i.loading = "eager"; });
  const x = window.scrollX, y = window.scrollY;
  const step = Math.max(window.innerHeight * 0.8, 400);
  const started = Date.now();
  for (let top = 0; top < document.documentElement.scrollHeight; top += step) {
    if (Date.now() - started > 3500) break;
    window.scrollTo({ left: x, top, behavior: "instant" });
    await new Promise((r) => setTimeout(r, 70));
  }
  images().forEach((i) => { i.loading = "eager"; });
  window.scrollTo({ left: x, top: y, behavior: "instant" });
  await new Promise((r) => setTimeout(r, 250));
  return true;
}

// Runs in the page, in the extension's own world — whose DOM prototypes are its own, so
// what is wrapped here is what the extraction scripts call and never what the page's own
// scripts do. Every node they take out of the live page is noted, with where it was, for
// `putBack`. Nodes taken out of a copy of the page are the scripts' business.
function watchRemovals() {
  if (globalThis.eveningReaderPutBack) return;
  const removed = [];
  const live = (node) => node?.isConnected && node.ownerDocument === document;
  const removeChild = Node.prototype.removeChild;
  const remove = Element.prototype.remove;
  Node.prototype.removeChild = function (child) {
    if (live(child)) removed.push([this, child, child.nextSibling]);
    return removeChild.call(this, child);
  };
  Element.prototype.remove = function () {
    if (live(this) && this.parentNode) removed.push([this.parentNode, this, this.nextSibling]);
    return remove.call(this);
  };
  globalThis.eveningReaderPutBack = () => {
    Node.prototype.removeChild = removeChild;
    Element.prototype.remove = remove;
    // Last out, first back: each node's neighbour is back in place by the time it is.
    for (let i = removed.length - 1; i >= 0; i--) {
      const [parent, child, next] = removed[i];
      if (child.isConnected) continue;
      try { parent.insertBefore(child, next?.parentNode === parent ? next : null); } catch {}
    }
  };
}

// Runs in the page: everything `watchRemovals` saw go, back where it was, and the marks
// `extract.js` leaves on what it found hidden taken off again.
function putBack() {
  globalThis.eveningReaderPutBack?.();
  delete globalThis.eveningReaderPutBack;
  document.querySelectorAll("[data-ag-unseen]").forEach((el) => el.removeAttribute("data-ag-unseen"));
  return true;
}

// The address the app itself would keep: tracking parameters and the fragment taken off,
// so a page saved from here matches one saved on the phone. Mirrors `Library.normalize`.
function normalize(raw) {
  let url;
  try {
    url = new URL(raw);
  } catch {
    return null;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return null;
  const junk = new Set(["utm_source", "utm_medium", "utm_campaign", "utm_term",
                        "utm_content", "utm_name", "fbclid", "gclid", "mc_cid",
                        "mc_eid", "igshid", "ref", "ref_src", "s", "cmpid"]);
  for (const name of [...url.searchParams.keys()]) {
    if (junk.has(name.toLowerCase())) url.searchParams.delete(name);
  }
  url.hash = "";
  return url.href;
}

// Chrome's word for a host it has no manifest for, or whose manifest names a helper that
// has gone: the app was never opened, or was moved or deleted after it was.
function missingHelper(error) {
  return /native messaging host not found|not found/i.test(String(error?.message ?? error));
}

// MARK: - Saying so

// What happened, said twice: on the toolbar button, which works on any tab, and as a
// card on the page itself, where there is one we are allowed to draw on — not on the
// browser's own pages or the extension store, which is what the badge is for.
async function tell(tabId, phase, headline, detail, note, link) {
  badge(tabId, phase, detail ? `${headline}: ${detail}` : headline);
  if (tabId == null) return;
  try {
    // The site's typeface goes in with the first card on a page, and only then.
    const [had] = await api.scripting.executeScript({
      target: { tabId },
      func: () => Boolean(globalThis.eveningReaderFont),
    });
    const fonts = had?.result ? null : await typeface();
    await api.scripting.executeScript({
      target: { tabId },
      func: showCard,
      args: [phase, headline, detail, note ?? null, link ?? null, fonts],
    });
  } catch {
    // A page we can't reach. The badge has said it.
  }
}

// Bricolage Grotesque, the website's typeface, from the extension's own files: the
// Latin subsets Google Fonts serves, variable in weight and optical size. Handed to the
// page as bytes rather than as an address, because many pages' security policies refuse
// fonts from anywhere but their own site, and bytes aren't fetched from anywhere.
const FONT_FILES = [
  { file: "fonts/bricolage-latin.woff2",
    range: "U+0000-00FF, U+0131, U+0152-0153, U+02BB-02BC, U+02C6, U+02DA, U+02DC, U+0304, U+0308, U+0329, U+2000-206F, U+20AC, U+2122, U+2191, U+2193, U+2212, U+2215, U+FEFF, U+FFFD" },
  { file: "fonts/bricolage-latin-ext.woff2",
    range: "U+0100-02BA, U+02BD-02C5, U+02C7-02CC, U+02CE-02D7, U+02DD-02FF, U+0304, U+0308, U+0329, U+1D00-1DBF, U+1E00-1E9F, U+1EF2-1EFF, U+2020, U+20A0-20AB, U+20AD-20C4, U+2113, U+2C60-2C7F, U+A720-A7FF" },
];
let typefaceLoad;
function typeface() {
  typefaceLoad ??= Promise.all(FONT_FILES.map(async ({ file, range }) => {
    const bytes = new Uint8Array(await (await fetch(api.runtime.getURL(file))).arrayBuffer());
    let binary = "";
    for (let i = 0; i < bytes.length; i += 0x8000) {
      binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    }
    return { data: btoa(binary), range };
  })).catch(() => {
    typefaceLoad = null;  // Tried again next time; the card falls back to the system's.
    return null;
  });
  return typefaceLoad;
}

function badge(tabId, phase, title) {
  const target = tabId == null ? {} : { tabId };
  const look = {
    working: { text: "…", color: "#8f6233" },
    saved: { text: "✓", color: "#b5651d" },
    failed: { text: "!", color: "#a23b2a" },
  }[phase];
  api.action.setBadgeBackgroundColor({ ...target, color: look.color });
  api.action.setBadgeText({ ...target, text: look.text });
  api.action.setTitle({ ...target, title });
  if (phase === "working") return;
  setTimeout(() => {
    api.action.setBadgeText({ ...target, text: "" });
    api.action.setTitle({ ...target, title: "Save to Evening Reader" });
  }, phase === "failed" ? 8000 : 2500);
}

// The card, drawn into the page in the website's look: paper and ink, the app's icon,
// and the amber left to the icon. It follows the reader's light or dark setting, as the
// site does with the lights on or off. Runs in the page, so it has to stand entirely on
// its own — nothing from this file is in scope there. In a shadow root, so the page's
// styles can't reach it and its styles can't reach the page.
//
// The colors are the site's (docs/assets/site.css): --card, --rule, --fg, --body,
// --muted, lights on and off. The icon is drawn rather than loaded, so a page whose
// security policy refuses outside pictures still shows it.
function showCard(phase, headline, detail, note, link, fonts) {
  // The typeface, once per page, under a name of its own so the page's text never picks
  // it up. Faces added to the document reach into the shadow root; a face declared in it
  // wouldn't.
  if (fonts && !globalThis.eveningReaderFont) {
    globalThis.eveningReaderFont = true;
    for (const { data, range } of fonts) {
      const bytes = Uint8Array.from(atob(data), (c) => c.charCodeAt(0));
      const face = new FontFace("Evening Reader Bricolage", bytes,
                                { weight: "200 800", unicodeRange: range });
      document.fonts.add(face);
      face.load().catch(() => {});
    }
  }
  const id = "evening-reader-save-card";
  let host = document.getElementById(id);
  if (!host) {
    host = document.createElement("div");
    host.id = id;
    host.style.cssText = "all: initial; position: fixed; top: 16px; right: 16px; z-index: 2147483647;";
    const root = host.attachShadow({ mode: "open" });
    root.innerHTML = `
      <style>
        .card {
          --card: #ffffff; --rim: #dedcd7; --ink: #16171b; --body: #4a4b51; --muted: #62636a;
          --shadow: rgba(22, 23, 27, 0.45);
          box-sizing: border-box; width: 320px; padding: 16px 18px;
          display: flex; gap: 14px; align-items: flex-start;
          background: var(--card); color: var(--ink); border-radius: 22px;
          box-shadow: 0 0 0 1px var(--rim), 0 22px 44px -24px var(--shadow);
          font-family: "Evening Reader Bricolage", -apple-system, system-ui, sans-serif;
          font-optical-sizing: auto;
          -webkit-font-smoothing: antialiased; text-align: left; cursor: default;
          opacity: 0; transform: translateY(-8px) scale(0.98);
          transition: opacity 180ms ease-out, transform 220ms ease-out;
        }
        @media (prefers-color-scheme: dark) {
          .card {
            --card: #19191c; --rim: rgba(255, 255, 255, 0.12); --ink: #edebe7; --body: #bdbbb6;
            --muted: #a9a7a2; --shadow: rgba(0, 0, 0, 0.6);
          }
        }
        .card.shown { opacity: 1; transform: none; }
        @media (prefers-reduced-motion: reduce) { .card { transition: opacity 120ms linear; transform: none; } }
        .icon { width: 36px; height: 36px; flex: none; display: block; }
        .text { display: flex; flex-direction: column; gap: 4px; min-width: 0; flex: 1; }
        .headline {
          display: flex; align-items: center; gap: 6px;
          font-size: 16px; line-height: 1.25; font-weight: 700; letter-spacing: -0.01em;
        }
        .headline svg { width: 16px; height: 16px; flex: none; }
        .detail {
          font-size: 14px; line-height: 1.35; color: var(--body); overflow-wrap: anywhere;
          display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden;
        }
        .card.working .detail { display: block; white-space: nowrap; text-overflow: ellipsis; }
        .card.failed .detail { -webkit-line-clamp: 6; line-height: 1.4; }
        .note { font-size: 13px; line-height: 1.35; color: var(--muted); }
        .detail:empty, .note:empty { display: none; }
        .progress { display: none; margin-top: 8px; height: 3px; border-radius: 2px; background: var(--rim); overflow: hidden; }
        .card.working .progress { display: block; }
        .progress span {
          display: block; width: 38%; height: 3px; border-radius: 2px; background: var(--ink);
          animation: slide 1.3s ease-in-out infinite;
        }
        @keyframes slide { from { transform: translateX(-100%); } to { transform: translateX(265%); } }
        @media (prefers-reduced-motion: reduce) { .progress span { animation: none; } }
        .link {
          margin-top: 10px; align-self: flex-start; display: inline-flex; align-items: center;
          min-height: 36px; padding: 0 16px; border-radius: 18px;
          background: var(--ink); color: var(--card);
          font: inherit; font-size: 14px; font-weight: 700; text-decoration: none; cursor: pointer;
        }
        .link:hover { opacity: 0.8; }
        .link:focus-visible { outline: 3px solid var(--ink); outline-offset: 3px; }
        .link[hidden] { display: none; }
      </style>
      <div class="card" role="status" aria-live="polite">
        <svg class="icon" viewBox="0 0 36 36" aria-hidden="true">
          <defs>
            <radialGradient id="er-page" cx="50%" cy="45%" r="70%">
              <stop offset="0" stop-color="#ffb866"/>
              <stop offset="1" stop-color="#e98f2c"/>
            </radialGradient>
          </defs>
          <rect width="36" height="36" rx="9" fill="#120d08"/>
          <rect x="8.5" y="8.5" width="19" height="19" rx="2.5" fill="url(#er-page)"/>
          <path d="M11.5 14h11M11.5 17.5h11M11.5 21h7" stroke="#2b1a0b" stroke-width="1.5" stroke-linecap="round"/>
        </svg>
        <div class="text">
          <div class="headline"></div>
          <div class="detail"></div>
          <div class="note"></div>
          <div class="progress"><span></span></div>
          <a class="link" target="_blank" rel="noopener" hidden></a>
        </div>
      </div>`;
    (document.body ?? document.documentElement).appendChild(host);
    host.addEventListener("click", (event) => {
      // The button opens its page; anywhere else on the card puts it away.
      if (!event.composedPath().some((node) => node.classList?.contains("link"))) host.remove();
    });
  }

  const root = host.shadowRoot;
  const card = root.querySelector(".card");
  card.classList.toggle("working", phase === "working");
  card.classList.toggle("failed", phase === "failed");
  const title = root.querySelector(".headline");
  title.textContent = headline;
  if (phase === "saved") {
    title.insertAdjacentHTML("afterbegin",
      `<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"
            stroke-linejoin="round" aria-hidden="true"><path d="M3 8.5l3.2 3L13 4.5"/></svg>`);
  }
  root.querySelector(".detail").textContent = detail ?? "";
  root.querySelector(".note").textContent = note ?? "";
  const action = root.querySelector(".link");
  action.hidden = !link;
  action.textContent = link?.label ?? "";
  if (link) action.href = link.url; else action.removeAttribute("href");
  requestAnimationFrame(() => card.classList.add("shown"));

  clearTimeout(host.dismissal);
  if (phase !== "working") {
    host.dismissal = setTimeout(() => {
      card.classList.remove("shown");
      setTimeout(() => host.remove(), 250);
    }, link ? 15000 : phase === "failed" ? 8000 : 3200);
  }
}
