# Save to Evening Reader — Chrome and Safari on the Mac

A toolbar button (and a right-click "Save Page / Save Link to Evening Reader") that puts the page into the Evening Reader library in iCloud. Shortcut: ⌥⇧E.

Clicking the button (or the shortcut, or "Save Page") reads the article out of the page you have open, using the app's own extraction scripts (`extract.js`, then Defuddle for the Markdown). That means it captures what you can see, including pages behind a login or paywall. The native side then stores it the way the app stores a page it fetched itself, using the app's own `ArticleStore`, `OfflineAssets` and `MarkdownSidecar`: pictures downloaded and sorted into drawings and photographs, `body.html`, `state.json` marked `ready`, and the note with the article's Markdown. Everything goes into `~/Library/Mobile Documents/iCloud~com~jonbobrow~AmberGlow/Documents`, so the article reaches every device ready to read, offline, without Evening Reader being opened.

The extraction scripts were written for a page loaded only to be read, and they remove hidden text from it. Here the page is your open tab, so the extension notes everything they take out and puts it back afterwards, and it returns you to where you'd scrolled.

When there's nothing to capture (a link saved from the context menu, a browser page, or a page neither script can read), it queues the address instead, `pending`, the same as the share sheet. The app fetches it the next time it opens. Saving a page that's already in the library brings it back to the top of Unread instead of adding a copy, and fills it in if it hadn't been fetched yet.

```
web/                  the extension itself, shared by both browsers
native/LibraryDrop.swift   stores what the extension read (both browsers use it)
native/chrome-host/   Chrome's native messaging host
native/install-chrome-host.sh
Safari/               the Mac app that carries the Safari extension
```

A browser extension can't write files outside its own sandbox, so each browser hands the article to a small native piece that writes the files. In Chrome that piece is a native messaging host. In Safari it's the extension's own handler, sandboxed, with access to the Evening Reader iCloud folder and to the network (for pictures), and nothing else.

## Chrome (and Brave, Edge, Vivaldi, Chromium)

1. `Extension/native/install-chrome-host.sh`: copies the app's extraction scripts into `Extension/web`, builds the helper into `~/Library/Application Support/Evening Reader/`, and registers it with every Chromium browser it finds. Run it again after the app's extraction scripts, `Shared/` or `Extension/native` change, then reload the extension.
2. `chrome://extensions` → Developer mode → **Load unpacked** → choose `Extension/web`.

The manifest's `key` fixes the extension ID at `jchcaaglfjbkhenophbgnkopmdlibacd`, so it matches the host's `allowed_origins` wherever the folder is loaded from.

## Safari

1. Open `Safari/Evening Reader Saver.xcodeproj`, then build and run the **Evening Reader Saver** scheme. (You can also put the built app in `~/Applications` and open it once.) The project takes the extraction scripts and `Shared/` sources straight from the app, so rebuilding picks up any changes.
2. Safari → Settings → Extensions → turn on **Save to Evening Reader**, and allow it on all websites so the button works on any page.

If Safari doesn't list it, turn on Develop → Developer Settings → **Allow unsigned extensions**.

## Trying the host without touching the library

`EVENING_READER_LIBRARY=/some/folder` makes `LibraryDrop` write there instead of iCloud.

## The Chrome Web Store

`Extension/package-chrome.sh` builds the upload, `Extension/dist/save-to-evening-reader-<version>.zip`, without the manifest's `key`. `Extension/store/render.sh` renders the screenshots and promo tile into `Extension/dist/store/`. Everything the dashboard asks for, including permission justifications, privacy answers and what to do after the first upload, is in [store/LISTING.md](store/LISTING.md).
