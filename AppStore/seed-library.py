"""
Seeds a simulator's Evening Reader library for App Store screenshots.

    python3 AppStore/seed-library.py <simulator udid>

Writes pending article folders, two Gutenberg books (iliad.epub and flatland.epub,
expected beside this script — https://www.gutenberg.org/ebooks/6130.epub3.images and
/97.epub3.images), and five sites with icon.png files beside the script. Run it with
the app terminated, delete Library/index-cache.json, then launch: the app extracts
everything pending on its own. Highlights and glow presets were written by hand for
the 2026-09 set; see the session notes in git history for the shapes.
"""
import json, uuid, hashlib, os, re, shutil, sys, subprocess, unicodedata
from datetime import datetime, timedelta, timezone

udid = sys.argv[1]
root = subprocess.check_output(["xcrun","simctl","get_app_container",udid,"com.jonbobrow.AmberGlow","group.com.amberglow.shared"]).decode().strip()
lib = os.path.join(root, "Library")
seed = os.path.dirname(os.path.abspath(__file__))
now = datetime.now(timezone.utc)

def slug(text):
    folded = unicodedata.normalize("NFKD", text).encode("ascii","ignore").decode().lower()
    out=""; dash=False
    for ch in folded:
        if ch.isalnum(): out+=ch; dash=False
        elif not dash and out: out+="-"; dash=True
    return out.rstrip("-")[:60]

def iso(d): return d.strftime("%Y-%m-%dT%H:%M:%SZ")

def folder(title, id_):
    base = slug(title); short = id_[:8].lower()
    return os.path.join(lib, f"{base}--{short}" if base else short)

def write_article(a):
    d = folder(a["title"], a["id"]); os.makedirs(d, exist_ok=True)
    json.dump(a, open(os.path.join(d,"article.json"),"w"), indent=2, sort_keys=True)
    return d

def article(url, title, site, days_ago, hours=0):
    return {"id": str(uuid.uuid4()).upper(), "url": url, "title": title, "siteName": site,
            "wordCount": 0, "addedAt": iso(now - timedelta(days=days_ago, hours=hours)),
            "lastScroll": 0, "isArchived": False, "state": "pending"}

articles = [
    article("https://www.quantamagazine.org/what-makes-the-hardest-equations-in-physics-so-difficult-20180116/",
            "What Makes the Hardest Equations in Physics So Difficult?", "quantamagazine.org", 0, 3),
    article("https://www.quantamagazine.org/theory-of-fluids-enters-the-21st-century-20260817/",
            "Theory of Fluids Enters the 21st Century", "quantamagazine.org", 1, 2),
    article("https://kk.org/thetechnium/1000-true-fans/", "1,000 True Fans", "kk.org", 2, 5),
    article("https://jods.mitpress.mit.edu/pub/issue3-brand", "Pace Layering: How Complex Systems Learn and Keep Learning", "jods.mitpress.mit.edu", 3, 1),
    article("https://worrydream.com/refs/Egan_2001_-_Why_education_is_so_difficult_and_contentious.html",
            "Why education is so difficult and contentious", "worrydream.com", 4, 6),
    article("https://worrydream.com/refs/Hofstadter_2001_-_Analogy_as_the_Core_of_Cognition.pdf",
            "Analogy as the Core of Cognition", "worrydream.com", 5, 2),
    article("https://worrydream.com/refs/Mead_2001_-_Interview_(American_Spectator).html",
            "An Interview with Carver Mead", "worrydream.com", 6, 4),
    article("https://www.theatlantic.com/magazine/archive/1945/07/as-we-may-think/303881/",
            "As We May Think", "theatlantic.com", 8, 1),
]
for a in articles: write_article(a)

def book(file, title, creator, identifier, days_ago):
    src = "id:" + identifier.strip().lower().replace("urn:uuid:","").replace("urn:isbn:","")
    digest = hashlib.sha256(src.encode()).hexdigest()[:32]
    a = {"id": str(uuid.uuid4()).upper(), "kind": "book", "url": f"amber-book://{digest}", "title": title,
         "byline": creator, "wordCount": 0, "addedAt": iso(now - timedelta(days=days_ago, hours=3)),
         "lastScroll": 0, "isArchived": False, "state": "pending"}
    d = write_article(a)
    shutil.copy(os.path.join(seed, file), os.path.join(d, "book.epub"))

book("iliad.epub", "The Iliad", "Homer", "http://www.gutenberg.org/6130", 7)
book("flatland.epub", "Flatland: A Romance of Many Dimensions", "Edwin Abbott Abbott", "http://www.gutenberg.org/97", 9)

sites = [("Libby","https://libbyapp.com","libby.png"), ("Kindle","https://read.amazon.com","kindle.png"),
         ("YouTube","https://www.youtube.com","youtube.png"), ("Instagram","https://www.instagram.com","instagram.png"),
         ("NYTimes","https://www.nytimes.com","nytimes.png")]
for i,(name,url,icon) in enumerate(sites):
    sid = str(uuid.uuid4()).upper()
    d = os.path.join(lib, "Sites", f"{slug(name)}--{sid[:8].lower()}"); os.makedirs(d, exist_ok=True)
    json.dump({"id": sid, "name": name, "url": url, "addedAt": iso(now - timedelta(days=20-i))},
              open(os.path.join(d,"site.json"),"w"), indent=2, sort_keys=True)
    shutil.copy(os.path.join(seed, icon), os.path.join(d, "icon.png"))
print("seeded", lib)
