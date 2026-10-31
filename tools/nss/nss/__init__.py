"""Word-level neural search space (NSS) language model: data, models, training and export.

The model predicts the next word over the fixed 30k-word NSS vocabulary
(`tools/data/nss/english-nss-vocab-30k.tsv`) plus `<unk>`. Lexicon words outside the
vocabulary are scored as P(<unk>|context) x P(word|<unk>), the Gboard NSS fallback.
"""

from pathlib import Path

PACKAGE = Path(__file__).resolve().parent
WORKSPACE = PACKAGE.parent
TOOLS = WORKSPACE.parent
REPO = TOOLS.parent
DATA = WORKSPACE / "data"
RUNS = WORKSPACE / "runs"

DEFAULT_VOCAB = TOOLS / "data" / "nss" / "english-nss-vocab-30k.tsv"
DEFAULT_LANGDATA = REPO / "keyboard" / "langdata.bin"
