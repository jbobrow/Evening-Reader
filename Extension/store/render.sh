#!/bin/zsh
# Renders the Chrome Web Store images from the HTML beside this script, with headless
# Chrome, into Extension/dist/store/: two 1280×800 screenshots and the 440×280 small
# promo tile. They need the network for the website's font.

set -euo pipefail

here=${0:A:h}
out=${here:h}/dist/store
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
mkdir -p "$out"

render() {  # page width height
    "$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
        --virtual-time-budget=6000 --window-size="$2,$3" \
        --screenshot="$out/${1%.html}.png" "file://$here/$1" 2>/dev/null
    print "$out/${1%.html}.png"
}

render screenshot-1.html 1280 800
render screenshot-2.html 1280 800
render promo-small.html 440 280
