#!/bin/zsh
# Packages the Chrome extension for the Chrome Web Store, as
# Extension/dist/save-to-evening-reader-<version>.zip.
#
# The zip is Extension/web with the app's extraction scripts copied in, and without the
# manifest's "key": the store gives a published extension its own key and refuses an
# upload that brings one.

set -euo pipefail

here=${0:A:h}
repo=${here:h}
version=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$here/web/manifest.json")

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

cp "$here/web/background.js" "$stage/"
cp -R "$here/web/icons" "$stage/icons"
for script in extract.js defuddle.js defuddle-run.js defuddle-LICENSE.txt; do
    cp "$repo/AmberGlow/Reader/Resources/$script" "$stage/$script"
done
python3 -I - "$here/web/manifest.json" "$stage/manifest.json" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1]))
manifest.pop("key", None)
json.dump(manifest, open(sys.argv[2], "w"), indent=2, ensure_ascii=False)
PY

mkdir -p "$here/dist"
zip_path="$here/dist/save-to-evening-reader-$version.zip"
rm -f "$zip_path"
(cd "$stage" && zip -qrX "$zip_path" . -x '.*')
print "$zip_path"
unzip -l "$zip_path"
