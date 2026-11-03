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
    reply = { ok: false, error: explain(error) };
  }
  clearTimeout(slow);
  if (reply?.ok) {
    const headline = reply.status === "resaved" ? "Already saved — back in Unread" : "Saved to Evening Reader";
    const note = reply.captured
      ? "Ready to read, offline too."
      : "Evening Reader will fetch it the next time it opens.";
    tell(tabId, "saved", headline, reply.title ?? url, note);
  } else {
    tell(tabId, "failed", "Couldn't save this page", reply?.error ?? "Evening Reader didn't answer.");
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

function explain(error) {
  const message = String(error?.message ?? error);
  if (/native messaging host not found|not found/i.test(message)) {
    return "Evening Reader's helper isn't installed on this Mac, so the page can't be saved yet.";
  }
  return message;
}

// MARK: - Saying so

// What happened, said twice: on the toolbar button, which works on any tab, and as a
// card on the page itself, where there is one we are allowed to draw on — not on the
// browser's own pages or the extension store, which is what the badge is for.
async function tell(tabId, phase, headline, detail, note) {
  badge(tabId, phase, detail ? `${headline}: ${detail}` : headline);
  if (tabId == null) return;
  try {
    await api.scripting.executeScript({
      target: { tabId },
      func: showCard,
      args: [phase, headline, detail, note ?? null],
    });
  } catch {
    // A page we can't reach. The badge has said it.
  }
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

// The share sheet's card, drawn into the page: the same amber, the same serif headline,
// the title under it, and a word on what happens next. Runs in the page, so it has to stand entirely on its own — nothing
// from this file is in scope there. In a shadow root, so the page's styles can't reach
// it and its styles can't reach the page.
//
// The colors are `AmberPalette` at the share card's settings (warmth 0.62, glow 0.85,
// paper): the card at 0.88, its edge 0.62, the headline 0.02, the detail 0.34, the
// note 0.52.
function showCard(phase, headline, detail, note) {
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
          box-sizing: border-box;
          display: flex; flex-direction: column; align-items: center; gap: 10px;
          min-width: 260px; max-width: 320px; padding: 22px 26px 20px;
          background: #d1985b; color: #000;
          border: 1px solid #8f6233; border-radius: 22px;
          box-shadow: 0 0 30px rgba(228, 168, 106, 0.5), 0 8px 24px rgba(16, 11, 5, 0.28);
          text-align: center; cursor: default;
          opacity: 0; transform: translateY(-8px) scale(0.98);
          transition: opacity 180ms ease-out, transform 220ms ease-out;
        }
        .card.shown { opacity: 1; transform: none; }
        @media (prefers-reduced-motion: reduce) { .card { transition: opacity 120ms linear; transform: none; } }
        svg { width: 26px; height: 26px; color: #100b05; }
        .headline { font: 500 17px/1.25 ui-serif, "New York", Georgia, serif; }
        .detail {
          font: 12px/1.35 -apple-system, system-ui, sans-serif; color: #493017;
          display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden;
        }
        .note { font: 11px/1.35 -apple-system, system-ui, sans-serif; color: #754f28; margin-top: -4px; }
        .detail:empty, .note:empty { display: none; }
        .spin { animation: spin 1.1s linear infinite; transform-origin: 50% 50%; }
        @keyframes spin { to { transform: rotate(360deg); } }
      </style>
      <div class="card" role="status" aria-live="polite">
        <span class="icon"></span>
        <div class="headline"></div>
        <div class="detail"></div>
        <div class="note"></div>
      </div>`;
    (document.body ?? document.documentElement).appendChild(host);
    host.addEventListener("click", () => host.remove());
  }

  const root = host.shadowRoot;
  const card = root.querySelector(".card");
  const stroke = 'fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"';
  root.querySelector(".icon").innerHTML = {
    working: `<svg viewBox="0 0 26 26"><circle cx="13" cy="13" r="10" ${stroke} opacity="0.25"/>
              <path class="spin" d="M13 3a10 10 0 0 1 10 10" ${stroke}/></svg>`,
    saved: `<svg viewBox="0 0 26 26"><circle cx="13" cy="13" r="10" ${stroke}/>
            <path d="M8.5 13.5l3 3 6-7" ${stroke}/></svg>`,
    failed: `<svg viewBox="0 0 26 26"><circle cx="13" cy="13" r="10" ${stroke}/>
             <path d="M13 8v6.5M13 18v.01" ${stroke}/></svg>`,
  }[phase];
  root.querySelector(".headline").textContent = headline;
  root.querySelector(".detail").textContent = detail ?? "";
  root.querySelector(".note").textContent = note ?? "";
  requestAnimationFrame(() => card.classList.add("shown"));

  clearTimeout(host.dismissal);
  if (phase !== "working") {
    host.dismissal = setTimeout(() => {
      card.classList.remove("shown");
      setTimeout(() => host.remove(), 250);
    }, phase === "failed" ? 6000 : 3200);
  }
}
