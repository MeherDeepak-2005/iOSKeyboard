#!/usr/bin/env python3
"""Extract messaging-register text from the cached downloads into plain-text
files for prepare_data.py, holding out a test slice for before/after evals.

Inputs (in ../.cache, downloaded once):
  smsCorpus_en_2015.03.09_all.xml   NUS SMS corpus (~55k real SMS, CC BY)
  dd_{train,validation,test}.parquet  DailyDialog (roskoN/dailydialog mirror)

Outputs (in data/):
  sms_train.txt           SMS minus the held-out slice
  dailydialog.txt         DailyDialog train+validation utterances
  messaging_heldout.txt   DailyDialog TEST split + every 10th SMS — never
                          enters the training corpus; the register eval set.

DailyDialog ships pre-tokenized ("don ' t", "Let ' s") — apostrophes are
rejoined here or contractions would shatter before the tokenizer ever sees them.
"""

import re
import xml.etree.ElementTree as ET
from pathlib import Path

import pyarrow.parquet as pq

HERE = Path(__file__).resolve().parent
CACHE = HERE.parent / ".cache"
DATA = HERE / "data"

APOS = re.compile(r"\s*'\s*")


def dailydialog_lines(split):
    table = pq.read_table(CACHE / f"dd_{split}.parquet")
    for utts in table.column("utterances").to_pylist():
        for u in utts:
            yield APOS.sub("'", u)


def sms_lines():
    root = ET.parse(CACHE / "smsCorpus_en_2015.03.09_all.xml").getroot()
    for msg in root.iter("message"):
        t = msg.find("text")
        if t is not None and t.text:
            yield t.text


def main():
    DATA.mkdir(exist_ok=True)
    heldout = (DATA / "messaging_heldout.txt").open("w")

    with (DATA / "dailydialog.txt").open("w") as f:
        n = 0
        for split in ("train", "validation"):
            for line in dailydialog_lines(split):
                f.write(line.replace("\n", " ") + "\n")
                n += 1
        print(f"dailydialog.txt: {n} utterances")
    n_test = 0
    for line in dailydialog_lines("test"):
        heldout.write(line.replace("\n", " ") + "\n")
        n_test += 1

    with (DATA / "sms_train.txt").open("w") as f:
        n_train = n_held = 0
        for i, line in enumerate(sms_lines()):
            line = line.replace("\n", " ")
            if i % 10 == 0:
                heldout.write(line + "\n")
                n_held += 1
            else:
                f.write(line + "\n")
                n_train += 1
        print(f"sms_train.txt: {n_train} messages ({n_held} held out)")

    heldout.close()
    print(f"messaging_heldout.txt: {n_test} dailydialog + {n_held} sms lines")


if __name__ == "__main__":
    main()
