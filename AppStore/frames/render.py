#!/usr/bin/env python3
"""Render the App Store screenshots in frame.html to out/.

    python3 AppStore/frames/render.py              # every frame, iPhone and iPad
    python3 AppStore/frames/render.py phone        # just the iPhone set
    python3 AppStore/frames/render.py pad 2 3      # just these iPad frames

The iPhone set is 1320 x 2868 (6.9"), the iPad set 2064 x 2752 (13"), the two sizes
App Store Connect asks for and scales down from. Captures live in captures/: the
iPhone ones by name (front.png, reader.png, ...), the iPad ones as pad-<name>.png.

Needs Google Chrome, and the network once for the Bricolage Grotesque web font.
"""
import pathlib, re, subprocess, sys

HERE = pathlib.Path(__file__).resolve().parent
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
SIZES = {"phone": (1320, 2868), "pad": (2064, 2752)}

args = sys.argv[1:]
sizes = [a for a in args if a in SIZES] or list(SIZES)
picked = [int(a) for a in args if a.isdigit()]

page = HERE / "frame.html"
count = len(re.findall(r"^\s{4}\{$", page.read_text(), re.M))
frames = picked or range(1, count + 1)

out = HERE / "out"
out.mkdir(exist_ok=True)
for size in sizes:
    w, h = SIZES[size]
    for n in frames:
        if size == "pad" and not (HERE / "captures").glob("pad-*.png"):
            break
        target = out / f"evening-reader-{size}-{n:02d}.png"
        subprocess.run([
            CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
            "--force-device-scale-factor=1", f"--window-size={w},{h}",
            "--allow-file-access-from-files", "--virtual-time-budget=5000",
            f"--screenshot={target}", f"{page.as_uri()}?frame={n}&size={size}",
        ], check=True, stderr=subprocess.DEVNULL)
        print(target.relative_to(HERE))
