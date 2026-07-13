#!/usr/bin/env python3
from __future__ import annotations

"""Build keyboard/emoji.bin — the emoji catalog as one mmap-able binary.

The catalog used to live in Keyboard.swift as big string literals that were
split into ~1,300 heap Strings (plus arrays) the first time the emoji page
opened — dirty memory in a keyboard extension that fights for every MB. As a
mapped file the data stays in clean, evictable pages and EmojiStore decodes
one emoji at a time, per collection-view cell.

Emoji are Unicode text: we ship code points, not images. The lists below are
the single source of truth used to generate the runtime binary resource.

FORMAT v2 (little-endian, all u32 unless noted):

  header   magic 'KBEM', version=2, categoryCount C, stringCount N, mapCount M
  cats     C x (nameIdx, iconIdx, emojiStart, emojiCount)
           emoji string indices are [emojiStart, emojiStart+emojiCount)
  offsets  u32 x (N+1)     byte offsets into blob, per string index
  map      M x (wordIdx, emojiIdx)   word->emoji, SORTED by word bytes (bsearch)
  blob     utf8 bytes of all strings back to back

v1 had no map section (header was 4 u32, no mapCount). The reader still accepts
it (mapCount treated as 0).
"""

import struct
import unicodedata
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "keyboard" / "emoji.bin"
MAGIC = 0x4B42454D  # "KBEM" (as a little-endian u32 constant, mirror of EmojiStore)

CATEGORIES = [
    ("Smileys & People", "face.smiling",
     "😀 😃 😄 😁 😆 😅 😂 🤣 🥲 😊 😇 🙂 🙃 😉 😌 😍 🥰 😘 😗 😙 😚 😋 😛 😝 😜 🤪 🤨 🧐 🤓 😎 🥳 🤩 😏 😒 😞 😔 😟 😕 🙁 ☹️ 😣 😖 😫 😩 🥺 😢 😭 😤 😠 😡 🤬 🤯 😳 🥵 🥶 😱 😨 😰 😥 😓 🤗 🤔 🤭 🤫 🤥 😶 😐 😑 😬 🙄 😯 😦 😧 😮 😲 🥱 😴 🤤 😪 😵 🤐 🥴 🤢 🤮 🤧 😷 🤒 🤕 👋 🤚 ✋ 🖖 👌 🤏 ✌️ 🤞 🤟 🤘 🤙 👈 👉 👆 👇 👍 👎 ✊ 👊 🤛 🤜 👏 🙌 👐 🤲 🙏 💪 🦶 🦵 👀 👁 👅 👄 🧠"),
    ("Animals & Nature", "pawprint",
     "🐶 🐱 🐭 🐹 🐰 🦊 🐻 🐼 🐨 🐯 🦁 🐮 🐷 🐸 🐵 🙈 🙉 🙊 🐒 🐔 🐧 🐦 🐤 🦆 🦅 🦉 🦇 🐺 🐗 🐴 🦄 🐝 🐛 🦋 🐌 🐞 🐜 🦗 🕷 🐢 🐍 🦎 🦖 🦕 🐙 🦑 🦐 🦀 🐡 🐠 🐟 🐬 🐳 🐋 🦈 🐊 🐅 🐆 🦓 🦍 🐘 🦏 🐫 🦒 🐃 🐂 🐄 🐎 🐖 🐏 🐑 🐐 🌵 🎄 🌲 🌳 🌴 🌱 🌿 ☘️ 🍀 🎍 🌾 🌺 🌻 🌹 🌷 🌸 🌼 🌞 🌝 🌚 ⭐️ 🌟 ✨ ⚡️ 🔥 🌈 ☀️ ⛅️ ☁️ 🌧 ⛈ ❄️ ☃️ 💧 🌊"),
    ("Food & Drink", "fork.knife",
     "🍏 🍎 🍐 🍊 🍋 🍌 🍉 🍇 🍓 🫐 🍈 🍒 🍑 🥭 🍍 🥥 🥝 🍅 🍆 🥑 🥦 🥬 🥒 🌶 🌽 🥕 🧄 🧅 🥔 🍠 🥐 🍞 🥖 🥨 🧀 🥚 🍳 🥞 🧇 🥓 🥩 🍗 🍖 🌭 🍔 🍟 🍕 🥪 🌮 🌯 🥗 🍝 🍜 🍲 🍣 🍱 🍛 🍤 🍙 🍚 🍥 🥟 🍦 🍰 🎂 🍮 🍭 🍬 🍫 🍿 🍩 🍪 ☕️ 🍵 🥤 🧃 🍺 🍻 🥂 🍷 🥃 🍸 🍹 🧉"),
    ("Activity", "figure.run",
     "⚽️ 🏀 🏈 ⚾️ 🥎 🎾 🏐 🏉 🥏 🎱 🏓 🏸 🏒 🏑 🥍 🏏 🥅 ⛳️ 🏹 🎣 🥊 🥋 🎽 ⛸ 🥌 🛷 🎿 ⛷ 🏂 🏋️ 🤼 🤸 ⛹️ 🤺 🤾 🏌️ 🏇 🧘 🏄 🏊 🤽 🚣 🚴 🚵 🎪 🎭 🎨 🎬 🎤 🎧 🎼 🎹 🥁 🎷 🎺 🎸 🎻 🎲 🎯 🎳 🎮 🎰 🧩 🏆 🥇 🥈 🥉 🏅"),
    ("Travel & Places", "car",
     "🚗 🚕 🚙 🚌 🚎 🏎 🚓 🚑 🚒 🚐 🚚 🚛 🚜 🛴 🚲 🛵 🏍 🚨 🚔 🚍 🚘 🚖 🚡 🚠 🚟 🚃 🚋 🚝 🚄 🚅 🚈 🚂 🚆 🚇 🚊 🚉 ✈️ 🛫 🛬 💺 🚁 🚀 🛸 🚤 ⛵️ 🛶 🚢 ⚓️ 🗺 🗽 🗼 🏰 🏯 🏟 🎡 🎢 🎠 ⛲️ 🏖 🏝 ⛰ 🏔 🗻 🌋 🏕 ⛺️ 🏠 🏡 🏘 🏢 🏬 🏦 🏨 🏪 🏫 🏩 💒 🏛 ⛪️ 🕌 🕍 🛕"),
    ("Objects", "lightbulb",
     "⌚️ 📱 💻 ⌨️ 🖥 🖨 🖱 💽 💾 💿 📷 📸 📹 🎥 📞 ☎️ 📟 📺 📻 ⏱ ⏰ 🕰 ⌛️ ⏳ 📡 🔋 🔌 💡 🔦 🕯 🧯 💸 💵 💴 💶 💷 💰 💳 🧾 💎 ⚖️ 🔧 🔨 🛠 🔩 ⚙️ 🧰 🧲 🔫 💣 🔪 🚬 ⚰️ 🏺 🔮 📿 💈 🔭 🔬 🕳 💊 💉 🩸 🌡 🧷 🧵 🧶 👓 🕶 🌂 ☂️ 🧳 🎒 👜 👛 👝 🛍 🎁 🎈 🎏 🎀 🎉 🎊"),
    ("Symbols", "heart",
     "❤️ 🧡 💛 💚 💙 💜 🖤 🤍 🤎 💔 ❣️ 💕 💞 💓 💗 💖 💘 💝 💯 ✅ ❌ ❎ ➕ ➖ ➗ ✖️ ♾ 💲 ™️ ©️ ®️ 〰️ ➰ ➿ 🔚 🔙 🔛 🔝 🔜 ✔️ ☑️ 🔘 🔴 🟠 🟡 🟢 🔵 🟣 ⚫️ ⚪️ 🟤 🔺 🔻 🔸 🔹 🔶 🔷 🔳 🔲 ▪️ ▫️ ◼️ ◻️ ⬛️ ⬜️ 🟥 🟧 🟨 🟩 🟦 🟪 ⭐️ 🌟 ❓ ❗️ ‼️ ⁉️ 💤 🎵 🎶"),
]

# Word -> emoji aliases, surfaced in the suggestion bar's last slot on an exact
# word match (SwiftKey / stock QuickType behavior) and scanned by emoji search.
# First emoji wins. Deliberately conservative: a wrong emoji suggestion is worse
# than none.
WORD_EMOJI = {
    "love": "❤️", "heart": "❤️", "like": "👍", "yes": "👍", "no": "👎", "ok": "👌",
    "okay": "👌", "thanks": "🙏", "thank": "🙏", "please": "🙏", "pray": "🙏",
    "happy": "😊", "smile": "😊", "grin": "😁", "blush": "😊", "cute": "🥰",
    "sad": "😢", "unhappy": "😢", "upset": "😢", "cry": "😭", "crying": "😭",
    "sob": "😭", "sobbing": "😭", "tears": "😭", "tear": "😭", "bawl": "😭",
    "bawling": "😭", "laugh": "😂", "haha": "😂", "hahaha": "😂", "joy": "😂",
    "lol": "😂", "lmao": "🤣", "rofl": "🤣", "funny": "😂", "wink": "😉",
    "cool": "😎", "angry": "😡", "mad": "😡", "rage": "😡", "annoyed": "😒",
    "love you": "❤️", "loveyou": "❤️", "kiss": "😘", "hug": "🤗", "wow": "😮",
    "shocked": "😱", "scared": "😨", "fear": "😨", "sleep": "😴",
    "sleepy": "😴", "tired": "😴", "sick": "🤒", "party": "🥳", "yay": "🥳",
    "celebrate": "🥳", "congrats": "🥳", "congratulations": "🥳",
    "fire": "🔥", "lit": "🔥", "hot": "🔥", "cold": "🥶", "star": "⭐️",
    "sun": "☀️", "sunny": "☀️", "rain": "🌧", "rainy": "🌧", "snow": "❄️",
    "moon": "🌙", "rainbow": "🌈", "cloud": "☁️", "storm": "⛈",
    "dog": "🐶", "puppy": "🐶", "cat": "🐱", "kitten": "🐱", "bird": "🐦",
    "fish": "🐟", "bear": "🐻", "lion": "🦁", "tiger": "🐯", "monkey": "🐵",
    "cow": "🐮", "pig": "🐷", "frog": "🐸", "snake": "🐍", "bee": "🐝",
    "butterfly": "🦋", "bug": "🐛", "spider": "🕷", "unicorn": "🦄",
    "flower": "🌸", "rose": "🌹", "tree": "🌳", "plant": "🌱", "leaf": "🍀",
    "pizza": "🍕", "burger": "🍔", "fries": "🍟", "taco": "🌮", "sushi": "🍣",
    "coffee": "☕️", "tea": "🍵", "beer": "🍺", "wine": "🍷", "cake": "🎂",
    "birthday": "🎂", "cookie": "🍪", "candy": "🍬", "chocolate": "🍫",
    "apple": "🍎", "banana": "🍌", "egg": "🥚", "bread": "🍞", "cheese": "🧀",
    "car": "🚗", "bus": "🚌", "train": "🚆", "plane": "✈️", "flight": "✈️",
    "rocket": "🚀", "bike": "🚲", "boat": "🚤", "ship": "🚢", "home": "🏠",
    "house": "🏠", "money": "💰", "cash": "💵", "gift": "🎁", "present": "🎁",
    "phone": "📱", "camera": "📷", "music": "🎵", "song": "🎶", "game": "🎮",
    "book": "📚", "gym": "🏋️", "run": "🏃", "running": "🏃", "soccer": "⚽️",
    "football": "🏈", "basketball": "🏀", "baseball": "⚾️", "tennis": "🎾",
    "trophy": "🏆", "win": "🏆", "winner": "🏆", "medal": "🏅", "crown": "👑",
    "gem": "💎", "diamond": "💎", "clock": "⏰", "time": "⏰", "bomb": "💣",
    "skull": "💀", "ghost": "👻", "alien": "👽", "robot": "🤖", "poop": "💩",
    "eyes": "👀", "brain": "🧠", "muscle": "💪", "strong": "💪", "wave": "👋",
    "hi": "👋", "hello": "👋", "bye": "👋", "clap": "👏", "hundred": "💯",
    "check": "✅", "done": "✅", "cross": "❌", "question": "❓", "idea": "💡",
    "baby": "👶", "king": "🤴", "queen": "👸", "angel": "😇", "devil": "😈",
    "umbrella": "☂️", "parasol": "☂️", "closedumbrella": "🌂",
}

KEYWORD_STOPWORDS = {
    "a", "an", "and", "button", "capital", "emoji", "keycap", "latin", "letter",
    "mark", "selector", "sign", "small", "symbol", "variation", "with",
}


def normalized_keyword(s: str) -> str:
    return "".join(ch for ch in s.lower() if ch.isalnum())


def catalog_emojis() -> list[str]:
    return [emoji for _, _, emojis in CATEGORIES for emoji in emojis.split(" ")]


def unicode_keywords(emoji: str) -> list[str]:
    keywords: list[str] = []
    for scalar in emoji:
        codepoint = ord(scalar)
        if codepoint in (0xFE0E, 0xFE0F, 0x200D):
            continue
        name = unicodedata.name(scalar, "").lower().replace("-", " ")
        tokens = [t for t in name.split() if t not in KEYWORD_STOPWORDS]
        keywords.extend(tokens)
        for token in tokens:
            if len(token) > 3 and token.endswith("s"):
                keywords.append(token[:-1])
        if len(tokens) >= 2:
            keywords.append("".join(tokens))
    return keywords


def keyword_pairs() -> list[tuple[str, str]]:
    pairs: list[tuple[str, str]] = []
    seen: set[tuple[str, str]] = set()

    def add(keyword: str, emoji: str) -> None:
        key = normalized_keyword(keyword)
        if not key:
            return
        pair = (key, emoji)
        if pair in seen:
            return
        seen.add(pair)
        pairs.append(pair)

    # Manual aliases come first. When a word maps to several emoji, exact word->emoji
    # suggestions use the first entry, while search can still show the rest.
    for word, emoji in WORD_EMOJI.items():
        add(word, emoji)

    for emoji in catalog_emojis() + list(WORD_EMOJI.values()):
        for keyword in unicode_keywords(emoji):
            add(keyword, emoji)

    return sorted(pairs, key=lambda pair: pair[0].encode())


def main() -> None:
    strings: list[str] = []
    cats: list[tuple[int, int, int, int]] = []
    for name, icon, emojis in CATEGORIES:
        name_idx = len(strings); strings.append(name)
        icon_idx = len(strings); strings.append(icon)
        items = emojis.split(" ")
        assert all(items), f"double space in {name!r}"
        start = len(strings); strings.extend(items)
        cats.append((name_idx, icon_idx, start, len(items)))

    # Word->emoji map entries as (wordIdx, emojiIdx) into the string table, sorted by
    # the word's utf8 bytes so the reader can binary-search. Emoji strings are
    # interned (reused if already present as a catalog item or an earlier map value).
    interned: dict[str, int] = {}

    def intern(s: str) -> int:
        i = interned.get(s)
        if i is None:
            i = len(strings); strings.append(s); interned[s] = i
        return i

    map_pairs = [(intern(word), intern(emoji)) for word, emoji in keyword_pairs()]

    blob = bytearray()
    offsets = [0]
    for s in strings:
        blob += s.encode()
        offsets.append(len(blob))

    with OUT.open("wb") as f:
        f.write(struct.pack("<5I", MAGIC, 2, len(cats), len(strings), len(map_pairs)))
        for rec in cats:
            f.write(struct.pack("<4I", *rec))
        f.write(struct.pack(f"<{len(offsets)}I", *offsets))
        for pair in map_pairs:
            f.write(struct.pack("<2I", *pair))
        f.write(blob)
    total = sum(c[3] for c in cats)
    print(f"wrote {OUT} ({OUT.stat().st_size} B): {len(cats)} categories, "
          f"{total} emoji, {len(map_pairs)} word->emoji")


if __name__ == "__main__":
    main()
