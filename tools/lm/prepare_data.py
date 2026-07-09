#!/usr/bin/env python3
"""Build data/corpus.txt for LM training: one cleaned, register-tagged sentence
per line, e.g. `<en> see you tomorrow at the station`.

Default = English only (Leipzig news, cached by ../build_language_data.py, plus
optionally more Leipzig corpora) so the pipeline runs end-to-end without manual
downloads. Telugu and romanized Telugu are added via flags once the datasets
are on disk:

  --sangraha DIR    directory of Telugu-script text files (AI4Bharat Sangraha)
  --dakshina TSV    Dakshina te romanized lexicon/sentences file(s)

Cleaning: lowercase, strip URLs/emails, keep letters + Telugu block + ' only,
collapse whitespace, drop very short/long lines, dedupe.
"""

import argparse
import gzip
import hashlib
import re
import sys
import tarfile
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
CACHE = HERE.parent / ".cache"
DATA = HERE / "data"

# OpenSubtitles English mono (OPUS) — the conversational backbone. 3.6 GB gzip;
# streamed and truncated, never fully stored. This is the texting-register fix:
# short second-person dialog, questions, contractions.
OPENSUBS_EN = "https://object.pouta.csc.fi/OPUS-OpenSubtitles/v2018/mono/en.txt.gz"

URL_RE = re.compile(r"https?://\S+|www\.\S+|\S+@\S+")
EN_KEEP = re.compile(r"[^a-z' ]+")
TE_KEEP = re.compile(r"[^ఀ-౿ a-z']+")   # Telugu block (+ Latin for code-switch)
SPACES = re.compile(r"\s+")


def clean(line: str, telugu: bool = False) -> str | None:
    s = URL_RE.sub(" ", line.lower())
    s = (TE_KEEP if telugu else EN_KEEP).sub(" ", s)
    s = SPACES.sub(" ", s).strip()
    n = len(s.split())
    return s if 3 <= n <= 40 else None


def leipzig_english():
    tars = sorted(CACHE.glob("eng_*_1M.tar.gz")) or sorted(CACHE.glob("eng_*.tar.gz"))
    for tar_path in tars:
        with tarfile.open(tar_path, "r:gz") as tar:
            member = next(m for m in tar.getmembers() if m.name.endswith("-sentences.txt"))
            f = tar.extractfile(member)
            for raw in f:
                yield raw.decode("utf-8", errors="replace").split("\t", 1)[-1]


def opensubtitles_english(limit: int):
    """Stream-decompress OpenSubtitles, yield up to `limit` lines. The 3.6 GB
    gzip is read incrementally over HTTP and never stored whole."""
    req = urllib.request.Request(OPENSUBS_EN, headers={"User-Agent": "curl/8"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        with gzip.GzipFile(fileobj=resp) as gz:
            for i, raw in enumerate(gz):
                if i >= limit:
                    return
                yield raw.decode("utf-8", errors="replace")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sangraha", type=Path, help="dir of Telugu-script .txt files")
    ap.add_argument("--dakshina", type=Path, nargs="*", help="romanized Telugu file(s)")
    ap.add_argument("--max-per-register", type=int, default=1_000_000)
    ap.add_argument("--extra-en", type=Path, nargs="*",
                    help="extra English plain-text files (one utterance per line), e.g. "
                         "data/sms_train.txt data/dailydialog.txt from extract_messaging.py. "
                         "Emitted FIRST so the register cap never crowds them out.")
    ap.add_argument("--no-opensubs", action="store_true", help="skip the OpenSubtitles download")
    ap.add_argument("--finetune", action="store_true",
                    help="write data/finetune.txt from OpenSubtitles ONLY (conversational "
                         "register) for the low-LR fine-tune pass, instead of the pretrain corpus")
    args = ap.parse_args()

    DATA.mkdir(exist_ok=True)
    seen: set[bytes] = set()
    target = "finetune.txt" if args.finetune else "corpus.txt"
    out = (DATA / target).open("w")
    counts = {"<en>": 0, "<te>": 0, "<xlit>": 0}

    def emit(tag: str, line: str, telugu: bool = False):
        if counts[tag] >= args.max_per_register:
            return
        if (s := clean(line, telugu)) is None:
            return
        h = hashlib.blake2b(s.encode(), digest_size=8).digest()
        if h in seen:
            return
        seen.add(h)
        out.write(f"{tag} {s}\n")
        counts[tag] += 1

    # Fine-tune corpus = conversational only, so a short low-LR pass pulls the
    # pretrained model toward texting register.
    if args.finetune:
        for line in opensubtitles_english(args.max_per_register * 3):
            emit("<en>", line)
        out.close()
        print("finetune corpus:", counts, "->", DATA / target)
        return

    # Pretrain corpus: true messaging text first (SMS, dialogue), OpenSubtitles
    # as the conversational backbone, Leipzig news last for formal-word coverage.
    for f in args.extra_en or []:
        for line in f.open(errors="replace"):
            emit("<en>", line)
    if not args.no_opensubs:
        for line in opensubtitles_english(int(args.max_per_register * 0.75)):
            emit("<en>", line)
    for line in leipzig_english():
        emit("<en>", line)

    if args.sangraha:
        for f in sorted(args.sangraha.rglob("*.txt")):
            for line in f.open(errors="replace"):
                emit("<te>", line, telugu=True)

    for f in args.dakshina or []:
        for line in Path(f).open(errors="replace"):
            # Dakshina TSVs: native \t romanized (take the romanized column)
            emit("<xlit>", line.split("\t")[-1])

    out.close()
    print("corpus:", counts, "->", DATA / "corpus.txt")


if __name__ == "__main__":
    main()
