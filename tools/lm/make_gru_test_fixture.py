#!/usr/bin/env python3
"""Create a tiny deterministic random model for runtime plumbing tests, not quality evaluation."""
import argparse
from dataclasses import asdict
import json
from pathlib import Path
import subprocess
import sys
import torch
import sentencepiece as spm
from model import GRUModelConfig, KeyboardGRULM
from export_tokenizer import export_tokenizer
from export_gru_score_coreml import boundary_mask, streamed_score


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, default=Path("/tmp/ioskeyboard-gru-test-fixture"))
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    words = "the work school onboarding uncomfortable encyclopedia doing birthday tomorrow restaurant hello world thanks happy great this is it a lot can not correction keyboard neural search beam language state token cache memory pressure reset field context touch score model complete ending probability decoder something definitely possible welcome morning evening today yesterday after before another friend please".split()
    corpus = args.out / "corpus.txt"
    corpus.write_text(("i am going to " + " ".join(words) + "\n") * 20)
    spm.SentencePieceTrainer.train(input=str(corpus), model_prefix=str(args.out / "spm"),
        vocab_size=96, hard_vocab_limit=False, pad_id=0, unk_id=1,
        bos_id=-1, eos_id=-1, user_defined_symbols=["<en>"])
    tokenizer = args.out / "spm.model"
    sp = spm.SentencePieceProcessor(model_file=str(tokenizer))
    torch.manual_seed(17)
    config = GRUModelConfig(vocab_size=sp.vocab_size(), d_model=8, hidden=8, layers=2)
    model = KeyboardGRULM(config).eval()
    checkpoint = args.out / "gru.pt"
    torch.save({"model": model.state_dict(), "model_type": "gru",
                "model_config": asdict(config), "vocab": config.vocab_size}, checkpoint)
    for script, name in [("export_gru_coreml.py", "gru"), ("export_gru_score_coreml.py", "gru_score")]:
        subprocess.run([sys.executable, str(Path(__file__).with_name(script)),
            "--checkpoint", str(checkpoint), "--tokenizer", str(tokenizer),
            "--precision", "fp32", "--out", str(args.out / f"{name}.mlpackage")], check=True)
    export_tokenizer(tokenizer, args.out / "gru_tokenizer.bin")
    ends = boundary_mask([sp.id_to_piece(i) for i in range(sp.vocab_size())])
    context = ["i", "am", "going", "to"]
    tokens = [sp.piece_to_id("<en>")] + sp.encode(" ".join(context), out_type=int)
    words.append("pneumonoultramicroscopicsilicovolcanoconiosis")
    with torch.no_grad():
        scores = {word: streamed_score(model, tokens, sp.encode(word, out_type=int), 0, ends) for word in words}
    (args.out / "fixture.json").write_text(json.dumps({"context": context, "scores": scores}, indent=2))


if __name__ == "__main__":
    main()
