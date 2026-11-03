# Chrome Web Store listing — Save to Evening Reader

Everything the developer dashboard asks for, in the order it asks. The package comes from `Extension/package-chrome.sh`, and the images from `Extension/store/render.sh`. Both are written to `Extension/dist/`.

## Package

Upload `Extension/dist/save-to-evening-reader-1.0.zip`.

## Store listing

**Name** (from the manifest): Save to Evening Reader

**Summary** (from the manifest's description, 132 characters at most): Saves the page you're reading to your Evening Reader library in iCloud.

**Description:**

> Save the page you're reading to Evening Reader, and find it waiting on your iPhone and iPad, ready to read.
>
> Click the button, press Option-Shift-E, or right-click and choose Save Page to Evening Reader. The extension reads the article out of the page you have open, with the same extraction Evening Reader uses: its text, title, author, date and pictures. It then saves the article into your Evening Reader library in iCloud Drive. Because it reads the page in front of you, it saves what you can see, including sites you're signed in to.
>
> The article arrives already read out of the page, with its pictures, so it opens offline without the app having to fetch anything. A link you right-click is saved too, and Evening Reader fetches it the next time it opens.
>
> Saving a page that's already in your library brings it back to the top of Unread, instead of adding a copy.
>
> Your library is plain files in your own iCloud Drive: a Markdown note for each article and a folder of its pictures. Nothing you save is sent to us or to anyone else.
>
> Requires a Mac, Evening Reader on your iPhone or iPad with iCloud Drive turned on, and Evening Reader's helper for the Mac.

**Category:** Productivity › Tools

**Language:** English

## Graphic assets

| Field | File |
|---|---|
| Store icon (128×128) | `Extension/web/icons/icon-128.png` |
| Screenshot 1 (1280×800) | `Extension/dist/store/screenshot-1.png` |
| Screenshot 2 (1280×800) | `Extension/dist/store/screenshot-2.png` |
| Small promo tile (440×280) | `Extension/dist/store/promo-small.png` |

Screenshot 2 uses the reader screen from the website (`docs/assets/screens/phone-reader.webp`), which shows a Quanta Magazine article as the website does.

## Additional fields

- **Official URL / Homepage:** https://eveningreader.jonbobrow.com
- **Support URL:** https://eveningreader.jonbobrow.com/support.html

## Privacy

**Single purpose:**

> Saves the web page the user is reading into their Evening Reader reading list, which lives in their own iCloud Drive.

**Permission justifications:**

- **activeTab:** The extension reads only the tab the user is on, and only when the user saves it: by clicking the toolbar button, using the keyboard shortcut or choosing Save Page from the context menu. It has no host permissions and never reads a page on its own.
- **scripting:** When the user saves a page, the extension runs Evening Reader's article extraction in that tab to read out the article's text, title, author, date and pictures. It also shows a small card on the page saying the article was saved.
- **contextMenus:** Adds "Save Page to Evening Reader" and "Save Link to Evening Reader" to the right-click menu.
- **nativeMessaging:** Hands the saved article to Evening Reader's helper on the user's Mac. The helper writes it into the user's Evening Reader library in their own iCloud Drive; a browser extension can't write files there itself.

**Remote code:** No, I am not using remote code. Every script is in the package. `defuddle.js` is the MIT-licensed Defuddle library (its license is included), minified but not obfuscated.

**Data usage.** Tick **Website content**: when the user saves a page, its text, title, author, date and pictures are read. They go only to the helper on the user's own Mac, which writes them into the user's own iCloud Drive. Nothing is sent to the developer or to anyone else. Tick all three certifications:

- I do not sell or transfer user data to third parties, outside of the approved use cases.
- I do not use or transfer user data for purposes that are unrelated to my item's single purpose.
- I do not use or transfer user data to determine creditworthiness or for lending purposes.

**Privacy policy URL:** https://eveningreader.jonbobrow.com/privacy.html (its "The browser extension" section).

## Distribution

The extension does nothing without the Mac helper, and the store can't install that. Publish as **Unlisted** or **Private** until there is a way for people to get the helper. Today the only way is `Extension/native/install-chrome-host.sh`, from this repository.

**Test instructions** (for the reviewer):

> This extension saves pages into the Evening Reader iOS app's iCloud library. It needs a Mac and a native messaging helper (com.jonbobrow.eveningreader). Without the helper, saving shows a card saying "Evening Reader's helper isn't installed on this Mac". Every other part of the extension is still visible: the toolbar button, the right-click items, and the card it draws on the page.

## After the first upload

The store gives the item its own ID, which won't be `jchcaaglfjbkhenophbgnkopmdlibacd`, the ID the unpacked copy uses. The helper only answers the IDs listed in its `allowed_origins`. So:

1. In the dashboard, open the item's **Package** tab, choose **View public key**, and copy the key that appears.
2. Put that key in `Extension/web/manifest.json` as `"key"`, in place of the current one. The unpacked copy then has the store's ID too. The packaging script takes the key out of the zip again.
3. Set `extension_id` in `Extension/native/install-chrome-host.sh` to the store's ID, and run the script again.
