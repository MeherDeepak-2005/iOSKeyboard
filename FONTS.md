# Adding custom fonts (Nerd Fonts) to the keyboard

The Fonts page already ships **4 fonts that work with zero setup**, because they're
system designs (no files needed):

| Font in app | What it is        | File needed |
|-------------|-------------------|-------------|
| System      | San Francisco     | none |
| Rounded     | SF Rounded        | none |
| Serif       | New York          | none |
| Monospaced  | SF Mono           | none |

The last two entries — **JetBrains Mono** and **Hack** — are *Nerd Font* slots that
fall back to System until you add the actual font file. Here's how to wire one up.

## 1. Get the font file

Nerd Fonts ship as `.ttf`. Download from https://github.com/ryanoasis/nerd-fonts
(or use the patched fonts you already have). You want the **Mono** variant for even
key spacing, e.g.:

- `JetBrainsMonoNerdFontMono-Regular.ttf`
- `HackNerdFontMono-Regular.ttf`

> ⚠️ Keyboards are killed at ~30–60 MB of memory. Add **one weight per font** (Regular),
> not the whole family. Each Nerd Font file is ~2–4 MB; that's fine, a dozen is not.

## 2. Add the file to BOTH targets

Drag the `.ttf` into the Xcode project navigator. In the dialog:

- ✅ **Copy items if needed**
- ✅ Check **both** targets: `keyboard` (app, for the preview) **and** `demo_keyboard`
  (the extension, for actual typing).

That's it — no Info.plist editing. `FontInstaller.registerBundledFonts()` (called on
launch in both the app and the extension) scans the bundle and registers every
`.ttf`/`.otf` it finds at runtime.

## 3. Tell the code the PostScript name

The code looks fonts up by **PostScript name**, which is *not* the filename. Find it:

```bash
# prints the PostScript name(s) inside the file
fc-scan --format "%{postscriptname}\n" JetBrainsMonoNerdFontMono-Regular.ttf
# or, on macOS without fontconfig:
python3 -c "from fontTools.ttLib import TTFont,sys; f=TTFont('FILE.ttf'); print([r.toUnicode() for r in f['name'].names if r.nameID==6])"
```

Then put that exact string into `KBFont.customFamily` in `keyboard/Keyboard.swift`:

```swift
var customFamily: String? {
    switch self {
    case .jetBrains: return "JetBrainsMonoNFM-Regular"   // ← replace with the real PostScript name
    case .hack:      return "HackNFM-Regular"             // ← replace with the real PostScript name
    default:         return nil
    }
}
```

If the name is wrong, `UIFont(name:)` returns nil and the code silently falls back to
System — so a typo here just means "no effect," never a crash.

## 4. Adding MORE fonts

Add a case to the `KBFont` enum (it's `CaseIterable`, so it shows up in the Fonts list
automatically), give it a `subtitle`, and a `customFamily`. Drop the file in, set the
PostScript name, done.

---

### Recommendation

Nerd Fonts are monospaced coding fonts — great for a distinctive look, but wide and not
ideal for fast prose typing. For a keyboard I'd ship at most one mono option (JetBrains
Mono reads well) and lean on the proportional system designs (Rounded / Serif) as the
"pretty" choices most users actually want. You can always add more later.
