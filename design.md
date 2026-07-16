# Keyboard UI Design Specification

This file captures the visual themes, font sizes, layout constants, and row maps used by the keyboard UI extension for replication.

## Source Files

| Area | File |
|---|---|
| Extension host/controller | `demo_keyboard/KeyboardViewController.swift` |
| Theme model and key specs | `keyboard/Views/KeyboardTheme.swift` |
| Main keyboard deck and row layout | `keyboard/Views/Keyboard.swift` |
| Key rendering | `keyboard/Views/KeyButton.swift` |
| Suggestion strip | `keyboard/Views/SuggestionBar.swift` |
| Emoji palette and emoji search | `keyboard/Views/Emoji.swift` |
| Font and accent settings | `keyboard/Shared/KBSettings.swift` |
| Font registration | `keyboard/Shared/FontInstaller.swift` |

## Extension Container

The keyboard extension controller builds a full-bleed `KeyboardView`.

| Property | Value |
|---|---|
| Controller background | `.clear` |
| Keyboard view background | `.clear` |
| Keyboard constraints | Leading, trailing, top, and bottom pinned to controller view |
| Height constraint | `view.heightAnchor == keyboard.keyboardHeight` with priority `.required - 1` |
| Theme selection | `KeyboardTheme.system(dark: traitCollection.userInterfaceStyle == .dark)` |
| Theme rebuild trigger | `UITraitUserInterfaceStyle` changes |

## Base Themes

The keyboard uses a transparent glass-style deck. Both light and dark themes keep the deck clear so the host/system blur can show through.

| Item | Light | Dark |
|---|---|---|
| Theme name | `Light` | `Dark` |
| Deck background top | `.clear` | `.clear` |
| Deck background bottom | `.clear` | `.clear` |
| Normal key fill | `UIColor(white: 1, alpha: 0.42)` | `UIColor(white: 1, alpha: 0.16)` |
| Normal key text | `#1B1B1D` | `#ECECF0` |
| Special key fill | `UIColor(white: 1, alpha: 0.22)` | `UIColor(white: 1, alpha: 0.09)` |
| Special key text | `#1B1B1D` | `#ECECF0` |
| Accent/action key text | `.white` | `.white` |
| Shift/delete fill (`accentSoft`) | `UIColor(white: 1, alpha: 0.22)` | `UIColor(white: 1, alpha: 0.09)` |
| Shift/delete text | `#1B1B1D` | `#ECECF0` |
| Shadow color | `UIColor(white: 0, alpha: 1)` | `.white` |
| Shadow opacity | `0` | `0` |
| Base corner radius | `8` | `8` |

### Key Roles

| Role | Fill | Text |
|---|---|---|
| `normal` | `theme.key` | `theme.keyText` |
| `special` | `theme.specialKey` | `theme.specialKeyText` |
| `accent` | Diagonal accent gradient | `theme.accentKeyText` |
| `accentSoft` | `theme.accentSoft` | `theme.accentSoftText` |

The `accent` role is used for the return/action key. Its gradient runs from `(0, 0)` to `(1, 1)`.

## Accent Palette

The selected accent comes from `KBSettings.accent`. Emerald is the default.

| Accent | Light Gradient | Dark Gradient |
|---|---|---|
| Emerald | `#37C26B` -> `#1E9E5A` | `#33B566` -> `#18854C` |
| Leaf | `#6FB544` -> `#4E8E2E` | `#78C84E` -> `#57A338` |
| Mint | `#44CFA0` -> `#21B287` | `#53DCAB` -> `#2FC795` |
| Teal | `#16A89B` -> `#0B7C76` | `#1CB4A6` -> `#108A82` |
| Forest | `#4C9E45` -> `#2C6E30` | `#4F9E45` -> `#357A38` |
| Sky | `#55B4FF` -> `#2F97EC` | `#63BCFF` -> `#39A4F5` |
| Ocean | `#3A7BF0` -> `#2056D6` | `#4585F0` -> `#2A60D9` |
| Indigo | `#5560E0` -> `#3A44C6` | `#5F69E8` -> `#434FD6` |
| Lavender | `#AE9BFF` -> `#8E78FA` | `#BBA6FF` -> `#9C84FF` |
| Plum | `#9A4FD0` -> `#7733AE` | `#A75FE0` -> `#8642C2` |
| Coral | `#FF8C76` -> `#F2654E` | `#FF9079` -> `#F56A52` |
| Rose | `#FF87B0` -> `#E5588C` | `#FF92B8` -> `#F56AA0` |
| Amber | `#FFC24B` -> `#F5A11F` | `#FFC85A` -> `#F7AE2E` |
| Rust | `#E2682E` -> `#BE4C1A` | `#E87238` -> `#CC5A22` |
| Graphite | `#70757E` -> `#474B52` | `#7A7F88` -> `#4E535A` |
| Slate | `#78828F` -> `#566070` | `#6E7889` -> `#4C5666` |

## Font Sizes

| Element | Font |
|---|---|
| Single-character letter/number/symbol keys | Selected `KBFont`, size `23`, regular |
| Multi-character functional key labels (`space`, `123`, `ABC`, `go`, `search`, etc.) | System, size `16`, medium |
| Main key SF Symbols | Point size `19`, regular |
| Press popup label | Selected `KBFont`, size `min(34, popupHeight * 0.78)` |
| Suggestion strip buttons | System, size `17` |
| Emoji grid cell | System, size `28` |
| Emoji result button | System, size `28` |
| Emoji section header | System, size `11`, semibold |
| Emoji empty/data-unavailable label | System, size `15`, medium |
| Emoji browse search pill text | System, size `15` |
| Emoji browse search icon | SF Symbol point size `14`, medium |
| Emoji bottom bar title (`ABC`) | System, size `15`, semibold |
| Emoji bottom bar default icon | SF Symbol point size `16`, regular |
| Emoji bottom category tab icon | SF Symbol point size `15`, regular |
| Emoji search back button icon | SF Symbol point size `17`, medium |
| Emoji search pill icon | SF Symbol point size `14`, medium |
| Emoji search query text | System, size `16` |
| Emoji search clear icon | SF Symbol point size `15`, regular |
| Emoji search status label | System, size `14`, medium |

Suggestion strip labels set `adjustsFontSizeToFitWidth = true` and `minimumScaleFactor = 0.8`.

## Main Keyboard Layout

| Constant | Value |
|---|---|
| Key spacing | `6` |
| Row spacing | `8` |
| Row height | `45` |
| Suggestion strip height | `34` |
| Side padding | `6` |
| Top padding | `5` |
| Bottom padding | `6` |
| Collapsed suggestion top pad | `0` |
| Default `unitPitch` before layout | `30` |

Keyboard height:

```swift
keyboardHeight = headerSpace + topPad + rowHeight * 4 + rowSpacing * 3 + botPad
```

| State | Header Space | Total Height |
|---|---:|---:|
| Suggestions visible | `34` | `249` |
| Suggestions hidden/collapsed | `0` | `215` |
| Emoji search active | `86` | `301` |

### Key Width Calculation

```swift
W = bounds.width - sidePad * 2
unit = max(1, (W - keySpacing * 9) / 10)
unitPitch = unit + keySpacing
wide = unit * 1.5 + keySpacing / 2
retW = unit * 2 + keySpacing
```

| Width Kind | Width |
|---|---|
| `unit` | `unit` |
| `wide` | `unit * 1.5 + keySpacing / 2` |
| `ret` | `unit * 2 + keySpacing` |
| `flex` | Remaining row width divided by number of flex keys |

Rows without flex keys are horizontally centered. Rows with flex keys start at `sidePad`.

## Key Shapes and Effects

| Property | Value |
|---|---|
| Standard key radius | `8` |
| Pill key radius | `bounds.height / 2` |
| Corner curve | `.continuous` |
| Key shadow radius | `2.5` |
| Key shadow offset | `(0, 1)` |
| Key shadow opacity | `0` from theme |
| Press overlay, dark | White alpha `0.18` |
| Press overlay, light | Black alpha `0.12` |
| Covered/recess fill, dark | Black alpha `0.34` |
| Covered/recess fill, light | Black alpha `0.16` |

Pill keys include the action/return key, `space`, `123`, `ABC`, `#+=`, and globe. The emoji key is not pill-shaped.

## Press Popup

Only keys with `popup = true` show a popup. Letter keys and typed number/symbol keys use popups.

| Constant | Value |
|---|---|
| Horizontal edge clamp | `3` |
| Gap above key | `4` |
| Popup width | `max(keyFrame.width * 1.32, 42)` |
| Preferred popup height | `keyFrame.height + 5` |
| Maximum popup height | `bounds.height - 6` |
| Corner radius | `11` |
| Label inset | `dx: 4`, `dy: 2` |
| Popup z position | `1000` |
| Popup clear delay after commit | `0.018` seconds |
| Dark popup fill | `#4A4A50` |
| Light popup fill | `.white` |
| Popup text, dark | `#ECECF0` |
| Popup text, light | `#1B1B1D` |
| Popup shadow color | Black |
| Popup shadow opacity, dark | `0.45` |
| Popup shadow opacity, light | `0.20` |
| Popup shadow radius | `4` |
| Popup shadow offset | `(0, 2)` |

When a popup is shown, the original key hides its glyph and switches to the recessed fill.

## Suggestion Strip

| Property | Value |
|---|---|
| Height | `34` |
| Background | `.clear` |
| Button count | `3` |
| Distribution | Equal thirds |
| Button text color | `theme.keyText` |
| Completion remainder color | `theme.keyText.withAlphaComponent(0.45)` |
| Separator color | `theme.keyText.withAlphaComponent(0.12)` |
| Separator width | `0.5` |
| Separator vertical inset | `10` |

The strip is hidden and its full height reclaimed in secure, URL, email, search, numeric, phone, decimal, name-phone, ASCII number, and autocorrection-disabled fields.

## Glide Trail

| Property | Value |
|---|---|
| Stroke width | `9` |
| Line cap | `.round` |
| Line join | `.round` |
| Stroke color | `theme.accentStart.withAlphaComponent(0.30)` |
| Glide threshold | `unitPitch * 0.85` and at least two visible letter keys crossed |

## Hit Testing

| Behavior | Value |
|---|---|
| Inner authoritative key core | `frame.insetBy(dx: width * 0.28, dy: height * 0.28)` |
| Gaps | Not dead zones; nearest key wins |
| Language-model target bias | Subtracts `prior * unitPitch * unitPitch * 0.12` from squared distance |
| Key tap offset scale | `dx / unitPitch`, `dy / (rowHeight + rowSpacing)`, clamped to `[-1, 1]` |

## Key Rows

### Letters Page

| Row | Keys |
|---|---|
| 1 | `q w e r t y u i o p` |
| 2 | `a s d f g h j k l` |
| 3 | `shift z x c v b n m delete` |
| 4 | `123 [globe if needed] emoji space return/action` |

### Numbers Page

| Row | Keys |
|---|---|
| 1 | `1 2 3 4 5 6 7 8 9 0` |
| 2 | `- / : ; ( ) $ & @ "` |
| 3 | `#+= . , ? ! ' delete` |
| 4 | `ABC [globe if needed] emoji space return/action` |

### Symbols Page

| Row | Keys |
|---|---|
| 1 | `[ ] { } # % ^ * + =` |
| 2 | `_ \ | ~ < > € £ ¥ •` |
| 3 | `123 . , ? ! ' delete` |
| 4 | `ABC [globe if needed] emoji space return/action` |

## Key Roles by Function

| Key | Role | Width | Shape |
|---|---|---|---|
| Letter keys | `normal` | `unit` | Standard |
| Number/symbol keys | `normal` | `unit` | Standard |
| Punctuation on third row of numbers/symbols | `normal` | `flex` | Standard |
| Shift | `accentSoft` | `wide` | Standard |
| Delete | `accentSoft` | `wide` | Standard |
| Return/action | `accent` | `ret` | Pill |
| Space | `normal` | `flex` | Pill |
| `123`, `ABC`, `#+=` | `special` | `wide` | Pill |
| Globe | `special` | `unit` | Pill |
| Emoji | `special` | `unit` | Standard |

Return/action labels are contextual: `go`, `search`, `send`, `join`, `next`, `route`, `done`, `continue`, `SOS`, or a return symbol for default.

## Emoji Browse Page

The emoji page replaces the key grid with an overlay collection view.

| Constant | Value |
|---|---|
| Search row height | `42` |
| Bottom bar height | `42` |
| Search pill frame | `x: 8`, `y: 5`, `width: bounds.width - 16`, `height: 32` |
| Search pill radius | `16` |
| Search pill background, dark | White alpha `0.10` |
| Search pill background, light | White alpha `0.55` |
| Search pill content insets | Top `0`, leading `12`, bottom `0`, trailing `12` |
| Search icon/text color | `theme.keyText.withAlphaComponent(0.45)` |
| Search image padding | `6` |
| Collection frame | `x: 0`, `y: 42`, `width: bounds.width`, `height: bounds.height - 84` |
| Bottom bar frame | `x: 0`, `y: bounds.height - 42`, `width: bounds.width`, `height: 42` |
| Bottom bar background, dark | White alpha `0.05` |
| Bottom bar background, light | Black alpha `0.04` |

### Emoji Grid

| Property | Value |
|---|---|
| Effective width | `container.effectiveContentSize.width - 12` |
| Columns | `max(6, Int(width / 46))` |
| Cell width | `1 / columns` fractional width |
| Row height | `width * (1 / columns)` |
| Section insets | Top `0`, leading `6`, bottom `10`, trailing `6` |
| Section header height | `24` |
| Cell corner radius | `8` |
| Cell highlight, dark | White alpha `0.10` |
| Cell highlight, light | Black alpha `0.08` |
| Empty label color | `theme.specialKeyText.withAlphaComponent(0.55)` |

### Emoji Bottom Bar

| Property | Value |
|---|---|
| Stack spacing | `2` |
| Stack horizontal inset | `4` each side |
| Fixed leading/delete button width | `40` |
| Inactive icon tint | `theme.specialKeyText.withAlphaComponent(0.5)` |
| Active icon tint | `theme.keyText` |
| Active tab background, dark | White alpha `0.12` |
| Active tab background, light | Black alpha `0.08` |
| Active tab corner radius | `8` |

Bottom bar layout: `ABC`, optional globe, category tabs, delete.

## Emoji Search Header

Emoji search swaps the suggestion strip for an `86` point header and reuses the real keyboard below it for query typing.

| Constant | Value |
|---|---|
| Header height | `86` |
| Search row | `38` |
| Results row | `48` |
| Back button size | `36 x 36` |
| Back leading | `6` |
| Back center Y | `19` from top |
| Pill leading | Back trailing `+ 2` |
| Pill trailing | `-8` |
| Pill center Y | `19` from top |
| Pill height | `32` |
| Pill radius | `16` |
| Pill background, dark | White alpha `0.10` |
| Pill background, light | White alpha `0.55` |
| Search icon leading | `11` |
| Query leading from icon | `7` |
| Query trailing before clear | `-8` maximum |
| Caret size | `2 x 18` |
| Caret corner radius | `1` |
| Caret leading from query | `1` |
| Clear button size | `28 x 28` |
| Clear button trailing | `-6` |
| Results scroll top | `38` |
| Results scroll horizontal inset | `6` |
| Results scroll height | `48` |
| Results stack spacing | `2` |
| Result button width | `44` |
| Result cap | `60` |

### Emoji Search Colors

| Element | Color |
|---|---|
| Back icon | `theme.specialKeyText` |
| Search icon | `theme.keyText.withAlphaComponent(0.45)` |
| Placeholder query text | `theme.keyText.withAlphaComponent(0.45)` |
| Active query text | `theme.keyText` |
| Caret, dark | `#ECECF0` |
| Caret, light | `theme.keyText` |
| Clear icon | `theme.keyText.withAlphaComponent(0.35)` |
| Status label | `theme.specialKeyText.withAlphaComponent(0.5)` |

The caret animates from alpha `1` to `0` with duration `0.55`, delay `0.3`, repeating and autoreversing.
