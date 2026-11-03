#!/bin/zsh
# Gets the Chrome extension ready to load: copies in the app's own extraction scripts,
# builds the helper that writes into the Evening Reader library, and tells Chrome (and
# any other Chromium browser installed) where to find it.
#
# Run once, and again after changing anything in Extension/native, Shared, or the
# app's extraction scripts.

set -euo pipefail

here=${0:A:h}
repo=${here:h:h}
name=com.jonbobrow.eveningreader
# Fixed by the "key" in Extension/web/manifest.json, so it is the same wherever the
# unpacked extension is loaded from.
extension_id=jchcaaglfjbkhenophbgnkopmdlibacd

# The extension reads a page with the scripts the app reads one with. Copied rather than
# linked: Chrome won't load an extension file that resolves outside the extension's
# folder. Safari's project takes them straight from the app instead.
for script in extract.js defuddle.js defuddle-run.js defuddle-LICENSE.txt; do
    cp "$repo/AmberGlow/Reader/Resources/$script" "$repo/Extension/web/$script"
done

install_dir="$HOME/Library/Application Support/Evening Reader"
binary="$install_dir/evening-reader-host"
mkdir -p "$install_dir"

# The app's own store, so what the helper writes is what the app would.
swiftc -O -o "$binary" \
    "$repo"/Shared/{SavedArticle,ArticleStore,NoteFile,Highlight,OfflineAssets,MarkdownSidecar,CloudLibrary,PublishedDate}.swift \
    "$here/LibraryDrop.swift" \
    "$here/chrome-host/main.swift"

manifest=$(cat <<EOF
{
  "name": "$name",
  "description": "Saves pages to the Evening Reader library in iCloud",
  "path": "$binary",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$extension_id/"]
}
EOF
)

installed=()
for browser in "Google/Chrome" "Google/Chrome Beta" "Google/Chrome Canary" "Chromium" \
               "BraveSoftware/Brave-Browser" "Microsoft Edge" "Vivaldi"; do
    support="$HOME/Library/Application Support/$browser"
    [[ -d $support ]] || continue
    mkdir -p "$support/NativeMessagingHosts"
    print -r -- "$manifest" > "$support/NativeMessagingHosts/$name.json"
    installed+=("$browser")
done

print "Built $binary"
if (( ${#installed} )); then
    print "Registered with: ${(j:, :)installed}"
else
    print "No Chromium browser found to register with."
fi
