import Foundation

nonisolated struct TeluguHostEdit: Equatable, Sendable {
	let deleteBackwardCount: Int
	let insertion: String
}

/// A host-independent plan for replacing text immediately before the cursor.
/// Some text hosts delete an Indic extended grapheme in one call while others expose
/// its combining marks one at a time. Callers therefore inspect the document after
/// every deletion and stop at `prefix` instead of assuming `String.count` matches the
/// host's deletion unit.
nonisolated struct HostSuffixReplacementPlan: Equatable, Sendable {
	enum State: Equatable, Sendable {
		case deleteBackward
		case readyToInsert
		case invalid
	}

	let prefix: String
	let replacement: String
	let maximumDeleteCount: Int

	init?(contextBeforeInput: String, suffix: String, replacement: String) {
		guard !suffix.isEmpty, contextBeforeInput.hasSuffix(suffix) else { return nil }
		prefix = String(contextBeforeInput.dropLast(suffix.count))
		self.replacement = replacement
		// UTF-16 is the most conservative bound used by UIKit hosts. The state check
		// below stops immediately when a host removes a complete grapheme at once.
		maximumDeleteCount = max(suffix.count, suffix.unicodeScalars.count,
			suffix.utf16.count)
	}

	func state(for contextBeforeInput: String) -> State {
		if contextBeforeInput == prefix { return .readyToInsert }
		guard contextBeforeInput.hasPrefix(prefix) else { return .invalid }
		return .deleteBackward
	}
}

/// Validates Telugu scalar transitions while keeping the host mutation append-only.
/// UITextDocumentProxy does not promise scalar-level deletion: deleting and rebuilding
/// an extended grapheme can remove more text than intended in some hosts. A sequence
/// such as independent-a + ma + virama + ma therefore emits four literal inserts and
/// lets CoreText shape the resulting NFC string.
nonisolated enum TeluguComposer {
	static func edit(for output: KeyOutput, contextBeforeInput context: String,
		 rules: TeluguCompositionRules? = TeluguLanguagePack.shared.composition) -> TeluguHostEdit {
		let value = normalized(output.literal)
		guard !value.isEmpty else { return TeluguHostEdit(deleteBackwardCount: 0, insertion: "") }
		guard let rules else {
			return output.isPlainText
				? TeluguHostEdit(deleteBackwardCount: 0, insertion: value)
				: TeluguHostEdit(deleteBackwardCount: 0, insertion: "")
		}
		let cluster = context.last.map(String.init) ?? ""
		let scalars = cluster.unicodeScalars
		let last = scalars.last

		switch output {
		case .text:
			return TeluguHostEdit(deleteBackwardCount: 0, insertion: value)
		case .teluguVowel(let independent, let dependent):
			if last.map(rules.isConsonant) == true {
				// A bare consonant already carries inherent అ. Other vowels append their
				// dependent sign, matching the contextual behavior of alphabetic layouts.
				return TeluguHostEdit(deleteBackwardCount: 0,
					insertion: dependent.map(normalized) ?? "")
			}
			return TeluguHostEdit(deleteBackwardCount: 0, insertion: normalized(independent))
		case .teluguConsonant:
			guard value.unicodeScalars.count == 1,
				  value.unicodeScalars.first.map(rules.isConsonant) == true else {
				return TeluguHostEdit(deleteBackwardCount: 0, insertion: "")
			}
			return TeluguHostEdit(deleteBackwardCount: 0, insertion: value)
		case .teluguDependentVowel:
			// Apple exposes dependent signs on the normal page. They are legal after a
			// bare consonant (including the final consonant of an existing conjunct).
			guard last.map(rules.isConsonant) == true else {
				return TeluguHostEdit(deleteBackwardCount: 0, insertion: "")
			}
			return TeluguHostEdit(deleteBackwardCount: 0, insertion: value)
		case .teluguMark:
			guard !cluster.isEmpty,
				  scalars.contains(where: rules.isScriptScalar),
				  last?.value != rules.virama else {
				return TeluguHostEdit(deleteBackwardCount: 0, insertion: "")
			}
			return TeluguHostEdit(deleteBackwardCount: 0, insertion: value)
		case .teluguVirama:
			guard last.map(rules.isConsonant) == true,
				  value.unicodeScalars.first?.value == rules.virama else {
				return TeluguHostEdit(deleteBackwardCount: 0, insertion: "")
			}
			return TeluguHostEdit(deleteBackwardCount: 0, insertion: value)
		}
	}

	static func normalized(_ value: String) -> String {
		value.precomposedStringWithCanonicalMapping
	}

	static func output(forLiteral value: String,
		 rules: TeluguCompositionRules? = TeluguLanguagePack.shared.composition) -> KeyOutput {
		guard let rules else { return .text(normalized(value)) }
		return rules.output(for: value)
	}

	static func isTeluguScalar(_ scalar: UnicodeScalar,
		 rules: TeluguCompositionRules? = TeluguLanguagePack.shared.composition) -> Bool {
		rules?.isScriptScalar(scalar) ?? false
	}
}

private extension KeyOutput {
	nonisolated var isPlainText: Bool {
		if case .text = self { return true }
		return false
	}
}
