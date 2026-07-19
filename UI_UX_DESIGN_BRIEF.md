# Custom iOS Keyboard Companion App

## UI/UX Design Brief

### 1. Product Summary

This product is a third-party iOS keyboard and a companion iPhone app. The keyboard is the primary product: users type, receive autocorrections and predictions, glide across letters, and access emoji, clipboard history, GIFs, and stickers from any compatible iOS text field. The companion app exists to onboard the user, configure the keyboard, personalize its visual appearance, manage learned data, and show typing progress.

The design should be created from first principles. Do not treat an existing screenshot or implementation as a visual reference. Preserve the workflows and platform constraints in this document, but propose a fresh visual system and interaction model.

### 2. Product Goals

- Make installation and first use understandable to someone who has never enabled a third-party iOS keyboard.
- Make the app feel like a polished iOS utility, not a developer settings panel.
- Keep the recurring configuration surface short and easy to scan after onboarding is complete.
- Make appearance customization expressive without becoming a long, technical color-control form.
- Communicate privacy and Full Access requirements accurately without creating unnecessary fear.
- Make typing feedback immediate and legible, especially during glide input and autocorrection.
- Preserve familiar iOS keyboard geometry so existing typing muscle memory transfers.
- Let gamification reward continued use without competing with the keyboard controls.

### 3. Non-Goals and Platform Constraints

- The keyboard cannot change the font used by another app's text field. The host app owns inserted-text typography. Do not design a setting that promises otherwise.
- iOS does not provide a reliable API that tells the companion app whether this exact keyboard is currently enabled. The app can reliably know only that the extension has been opened and used at least once.
- Haptic feedback from a third-party keyboard requires Full Access. The setting must communicate this dependency when relevant.
- Debug logs, neural-model diagnostics, memory information, and glide-capture tools are development-only and must not appear in the production information architecture.
- The companion app must follow the system Light or Dark appearance. A selected keyboard color must not recolor the entire companion app.
- English is available now. Tenglish and Telugu are future languages and should be shown only if a clear disabled or coming-soon state is useful.

### 4. Primary Users

The primary user types frequently on an iPhone and wants better correction, prediction, glide input, and visual personalization. They understand ordinary iOS settings but should not need technical knowledge about keyboard extensions, language models, dictionaries, or Full Access.

Important user qualities:

- They judge the keyboard within seconds based on accuracy, responsiveness, spacing, and visual familiarity.
- They may abandon onboarding if enabling the extension feels complicated or unsafe.
- They want customization, but most users will choose a preset rather than build a theme manually.
- Advanced users may want detailed color and background controls.
- Users may switch frequently between Light and Dark system appearance.

### 5. Information Architecture

The production app should have a shallow hierarchy:

1. Home
2. Appearance
3. Achievements
4. Enable Keyboard onboarding, visible only until first confirmed use
5. Reset Learned Data confirmation

The Home screen should not behave like a permanent onboarding screen. Once the keyboard has been used, installation instructions disappear and the remaining screen becomes a compact control center.

### 6. First-Run Flow

The first launch should prioritize one task: enabling and opening the keyboard.

The flow should explain the following in short, progressive steps:

1. Add the keyboard in iOS Settings.
2. Open a text field in any app.
3. Use the globe control to switch to this keyboard.
4. Optionally allow Full Access for haptics and features that require network or shared data.

The primary action opens the app's iOS Settings page. Instructions should use plain language and a small number of steps. Avoid a large block of prose.

After the extension has been opened once, the app should stop showing the onboarding section. A subtle success state may appear once, but it should not permanently occupy the Home screen.

Required states:

- Not yet used
- Settings opened but use not confirmed
- First use confirmed
- Full Access unavailable while a dependent feature is enabled

### 7. Home Screen

The Home screen is a system-styled overview and control surface. All content scrolls as one page. Nothing except the navigation bar should remain sticky.

Recommended content order:

1. League and streak summary
2. Onboarding card, only before first use
3. Keyboard preferences
4. Learned-data management

Keyboard preferences include:

- Language
- Appearance
- Haptic Feedback

The Language row opens a compact menu or selection sheet. English is active. Future language choices must be clearly unavailable and must not look selectable.

The Appearance row opens the unified appearance experience. It displays the selected preset name or Custom state and may show a small swatch. It must not apply the selected swatch color to unrelated app navigation, toggles, or destructive actions.

Haptic Feedback is a standard system toggle. If Full Access is unavailable, the interface should explain the requirement contextually, close to the toggle, rather than in a permanent paragraph elsewhere.

Learned-data management contains one destructive command: Reset Learned Words. It opens a confirmation sheet that clearly states that learned vocabulary, correction history, and glide adaptation will be removed while the shipped dictionary and visual settings remain.

### 8. Appearance Experience

Presets and custom editing belong in one Appearance destination. Do not create separate Themes and Theme Studio pages.

The default state should prioritize preset selection:

- Show color presets as easily scannable swatches.
- Preview the correct preset variant for the current system Light or Dark appearance.
- Make selection obvious without relying only on color.
- Allow horizontal browsing, a compact grid, or another efficient pattern.
- Keep preset names short and secondary to the visual swatch.

Custom editing should be an optional mode in the same destination. Activating it reveals a live keyboard preview and role-based controls.

Editable roles:

- Letter-key fill
- Special-key fill
- Action-key color or gradient
- Key-label color
- Keyboard background

Background options:

- Solid color
- Two-stop gradient
- User photo

The editor should focus on one selected role at a time. The user may select the role from a compact control or tap the corresponding region in the live preview. Avoid repeating instructions under every control. Use progressive disclosure so background-only controls, such as photo selection and gradient stops, appear only while Background is selected.

The custom theme needs a contrast mode for light or dark backgrounds so labels, popups, and pressed states remain legible. The design should prevent obviously unreadable combinations or warn before saving them.

The live preview is an editing tool, not a second keyboard on the Home screen. It appears only inside Appearance while custom editing is active.

### 9. Achievements and Gamification

Gamification should feel supportive and optional. It must not make the utility feel like a game or block access to settings.

The Home screen contains a compact, tappable league summary. It scrolls with the page and includes:

- Current league, beginning with Bronze
- Total words typed
- Progress toward the next league
- Current streak
- One navigation affordance only

The summary should use the league color as a controlled accent, not as a full-screen theme. Bronze should feel refined and metallic rather than muddy or heavily brown.

The full Achievements screen contains:

- Current league and progress
- A 14-day typing activity chart
- Tapped versus glided word totals
- Best day
- Current and best streaks
- Trophy collection with earned and locked states

Empty and early-user states are important. A user with zero words should see achievable next steps, not an empty analytics dashboard.

### 10. Keyboard Surface

The keyboard must feel immediately familiar to an iPhone user. Letter positions, row offsets, key centers, and the relationship between rows should closely preserve standard QWERTY muscle memory. Visual originality should come from materials, color roles, feedback, and details rather than moving letters away from expected positions.

Keyboard pages:

- Letters
- Numbers
- Symbols
- Emoji
- Clipboard
- GIFs and stickers

The bottom row contains page switching, the system globe when required, emoji access, a flexible Space key, and a contextual action key. The action key changes its label and meaning based on the host field, such as Return, Go, Search, Send, Done, or Next.

Functional keys such as page switchers, globe, Space, and the action key may use stronger rounding. Letter keys should use restrained, consistent rounding and stable dimensions. Touch gaps must not become dead zones.

### 11. Suggestion Bar

The suggestion bar has a clipboard entry point and three word positions.

Ranking order is visualized as:

- Second-ranked suggestion on the left
- Top-ranked suggestion in the center
- Third-ranked suggestion on the right

The center suggestion is the authoritative candidate and receives a subtle translucent highlight while the user is completing a word. The highlight remains when the typed word exactly matches the center word. It should be visible in both Light and Dark modes without becoming a solid button.

Completion styling may distinguish the already typed prefix from the predicted remainder. Dividers and labels should be quiet, aligned, and readable at keyboard height.

### 12. Glide Input Experience

Glide input starts when a finger moves continuously across multiple letter keys. During the gesture:

- Draw a smooth path behind the finger.
- Use a rounded cap and join.
- Make the active point around the finger slightly thicker and rounder than the tail.
- Keep the trail translucent enough that letters remain readable.
- Show exactly one current top-ranked word in the center suggestion position.
- Update the displayed winner as the ranking changes.

When the finger lifts, the displayed winner should insert immediately. If no valid live winner exists, the keyboard may perform a fallback decode. The user should never see a list of raw crossed letters presented as if it were the predicted word.

The final alternatives remain available as one-tap replacements after insertion. Backspace immediately after a glide should be able to remove or revert the glided word predictably.

### 13. Emoji, Clipboard, GIF, and Sticker Panels

These are keyboard-height work surfaces, not companion-app pages.

Emoji:

- Category browsing
- Search
- Recent emoji
- Clear return path to ABC

Clipboard:

- Clipboard history list
- Tap to paste
- Pin and unpin
- Delete
- Empty state
- Full Access explanation when required

GIFs and stickers:

- Browse and search states
- Loading, empty, offline, and missing-API states
- Clear content-type switching
- Clear return path to ABC

Panels must preserve keyboard height intentionally and avoid large dead areas when users return to letters.

### 14. Visual Direction for the Companion App

The app should feel native to the current iOS design language: calm, structured, and content-first. It should not inherit the selected keyboard accent as its global theme.

Color guidance:

- Use semantic iOS background and grouped-surface colors.
- Use a stable system accent for navigation and standard controls.
- Reserve keyboard preset colors for swatches and previews.
- Reserve league colors for league-specific progress and symbols.
- Use semantic red only for destructive actions.
- Define independent Light and Dark values rather than mechanically inverting colors.
- Meet WCAG contrast requirements for text and essential controls.

Typography guidance:

- Use San Francisco and Dynamic Type throughout the companion app.
- Use system text styles rather than fixed decorative typography.
- Use headline weight sparingly for page titles and primary card labels.
- Keep settings labels at body size and metadata at subheadline or caption size.
- Do not use negative letter spacing.
- Do not expose a font-selection feature for inserted text.

### 15. Spacing, Shape, and Borders

Use a 4-point spacing foundation with common increments of 8, 12, 16, 20, and 24 points.

Recommended principles:

- Primary page horizontal margins: approximately 16 to 20 points.
- Minimum interactive target: 44 by 44 points.
- Settings rows: consistent vertical rhythm and aligned leading icons.
- Card corner radius: restrained, approximately 8 points.
- Avoid cards nested inside cards.
- Use separators or subtle strokes to establish grouping before adding shadows.
- Keep shadows soft and rare; do not use them as the only boundary.
- Keep icon containers consistent in size and corner treatment.
- Align text baselines, trailing values, switches, and chevrons across rows.
- Respect safe areas and Dynamic Type expansion.

### 16. Motion and Feedback

- Use short, system-like transitions for selection and disclosure.
- Do not animate layout in a way that moves keyboard keys during typing.
- Provide immediate pressed states and optional haptic feedback on key contact.
- Theme changes should update previews smoothly but should not animate every key independently.
- Achievement progress may animate on entry, but motion must be subtle and respect Reduce Motion.
- All custom transparency must remain understandable when Reduce Transparency is enabled.

### 17. Accessibility

- Support Dynamic Type in the companion app.
- Provide VoiceOver labels and traits for swatches, selected themes, keys, progress, and locked trophies.
- Never communicate selected, locked, or error states by color alone.
- Maintain at least 44-point touch targets even where visible controls are smaller.
- Test Light Mode, Dark Mode, Increased Contrast, Reduce Transparency, Reduce Motion, and Bold Text.
- Ensure long localization strings can wrap without overlapping trailing controls.
- Keep keyboard legends centered and readable without changing key dimensions.

### 18. Content Tone

Use concise, direct language. Avoid technical terms such as n-gram, decoder, jetsam, model headroom, mmap, or trie in production UI.

Preferred wording examples:

- Enable Keyboard
- Open Settings
- Appearance
- Haptic Feedback
- Reset Learned Words
- Custom Theme
- Choose Photo
- Full Access is needed for haptic feedback

Avoid long instructional footers when an inline state, icon, or contextual message can explain the same thing.

### 19. Required Designer Deliverables

- Information architecture and primary user flows
- Low-fidelity wireframes for first run, returning Home, Appearance, and Achievements
- High-fidelity Light and Dark designs
- Keyboard designs for letters, numbers, symbols, suggestions, active glide, emoji, clipboard, GIF, and sticker states
- Component inventory with measurements, spacing, typography, colors, borders, and interaction states
- Theme preset and custom-editor behavior specification
- Empty, loading, disabled, error, destructive-confirmation, and Full Access states
- Accessibility annotations
- Prototype covering onboarding, preset selection, custom editing, glide feedback, and learned-data reset

### 20. Areas Open for Fresh Design

The designer is encouraged to propose a new composition, navigation treatment, preset browser, league visualization, icon style, motion language, and custom-theme workflow. The design does not need to resemble the existing implementation. The fixed requirements are platform behavior, feature hierarchy, typing familiarity, accessibility, and the interaction contracts described above.
