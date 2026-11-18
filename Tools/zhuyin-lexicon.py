#!/usr/bin/env python3
"""Builds the Zhuyin keyboard's lexicon from McBopomofo's word list.

    python3 Tools/zhuyin-lexicon.py <McBopomofo>/Source/Data AmberGlow/Theme/Zhuyin/ZhuyinLexicon.txt

McBopomofo (https://github.com/openvanilla/McBopomofo, MIT) keeps its data as
plain lists: every character with its readings, every phrase with its readings,
and how often each turned up in its corpus. This does what its own compiler does
with them — turns counts into log10 scores, splits a character's score among its
readings by how common each reading is, applies its hand-tuned promotions — and
writes one line per reading:

    ㄓㄨㄥ-ㄨㄣˊ<TAB>中文 -4.123<TAB>…

with candidates in descending score. Scores are what the keyboard's sentence
builder adds up, so a phrase wins over the characters that spell it only when
it is likelier than all of them taken together.

Only the lists themselves are read; nothing in the McBopomofo checkout is run.
"""
import math
import sys
from pathlib import Path

UNK = -99.0          # a character in the reading list that never turned up in the corpus
HETERO_DEFAULT = -6.8
FSCALE = 2.7         # how much a phrase of n characters is boosted over n singles
LN_HALF = 0.69314718055994


def lines(path):
    with open(path, encoding="utf-8") as f:
        for line in f:
            if not line.strip() or line.startswith("#"):
                continue
            yield line.split()


def build(data: Path):
    # Phrase frequencies, with phrases that are part of a longer one discounted by it.
    occ = {e[0]: int(e[1]) for e in lines(data / "phrase.occ")}
    for e in lines(data / "exclusion.txt"):
        if len(e) < 2:
            continue
        key, longer = e[0], e[1]
        if key in longer and key in occ and longer in occ:
            occ[key] -= occ[longer]
    norm = sum(FSCALE ** (len(k) - 1) * v for k, v in occ.items())
    freq = {k: math.log10(FSCALE ** (len(k) - 1) * (v if v >= 1 else 0.5) / norm)
            for k, v in occ.items()}

    # Readings, in source order.
    readings = {}
    chars = []
    for e in lines(data / "BPMFBase.txt"):
        ch, r = e[0], e[1]
        if ch not in readings:
            readings[ch] = []
            chars.append(ch)
        readings[ch].append(r)
    for e in lines(data / "BPMFMappings.txt"):
        readings.setdefault(e[0], []).append("-".join(e[1:]))

    # Which reading of a many-voiced character is its usual one, second, third.
    phon = []
    for name in ("heterophony1.list", "heterophony2.list", "heterophony3.list"):
        phon.append({e[0]: e[1] for e in lines(data / name)})

    scores = {k: UNK for k in chars}
    for k, v in freq.items():
        if k in readings:
            scores[k] = v

    lm = {}
    def add(reading, value, score):
        lm.setdefault(reading, []).append((value, score))

    for value, score in scores.items():
        for r in readings.get(value, []):
            if len(value) > 3 or value not in phon[0] or phon[0][value] == r:
                add(r, value, score)
            elif value in phon[1] and phon[1][value] == r:
                add(r, value, max(score - LN_HALF, HETERO_DEFAULT))
            elif value in phon[2] and phon[2][value] == r:
                add(r, value, max(score - 2 * LN_HALF, HETERO_DEFAULT))
            else:
                add(r, value, HETERO_DEFAULT)

    # A reading can list a value twice (a phrase read the same way twice); keep the best.
    for r, us in lm.items():
        best = {}
        for v, s in us:
            if v not in best or s > best[v]:
                best[v] = s
        # Stable: equal scores keep the reading list's own order.
        order = list(dict.fromkeys(v for v, _ in us))
        lm[r] = sorted(((v, best[v]) for v in order), key=lambda u: -u[1])

    postprocess(lm, data / "Postprocess.txt")
    return lm


def postprocess(lm, path):
    epsilon = 0.0001
    def score_of(reading, value):
        return next((s for v, s in lm.get(reading, []) if v == value), None)
    def replace(reading, value, new):
        lm[reading] = sorted(((v, new if v == value else s) for v, s in lm[reading]),
                             key=lambda u: -u[1])
    for e in lines(path):
        op = e[0]
        if op == "epsilon":
            epsilon = float(e[1])
        elif op == "promote-over-single-syllables":
            value, reading = e[1], e[2]
            ours = score_of(reading, value)
            singles = [lm.get(r, [None])[0] for r in reading.split("-")]
            if ours is None or not all(singles):
                continue
            theirs = sum(s for _, s in singles)
            if theirs > ours:
                replace(reading, value, theirs + epsilon)
        elif op == "promote-over-peers":
            value, reading = e[1], e[2]
            if score_of(reading, value) is None:
                continue
            top_value, top_score = lm[reading][0]
            if top_value != value:
                replace(reading, value, top_score + epsilon)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    lm = build(Path(sys.argv[1]))
    with open(sys.argv[2], "w", encoding="utf-8") as out:
        for reading in sorted(lm, key=lambda k: k.encode("utf-8")):
            out.write(reading)
            for v, s in lm[reading]:
                out.write("\t%s %.3f" % (v, s))
            out.write("\n")
    print(f"{len(lm)} readings, {sum(len(u) for u in lm.values())} entries")


if __name__ == "__main__":
    main()
