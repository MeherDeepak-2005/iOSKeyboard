#pragma once
#include <cstddef>
#include <cstdint>
#include <optional>
#include "Tuning.hpp"
namespace kb {
struct TouchOffset { double dx, dy; };
struct GridPoint { double x, y; };
inline constexpr std::uint8_t apostrophe = '\'';
// Fitted on the tune half of tools/evaluation/autocorrect (tune.py, 27 Oct 2026; doubled letters
// and vowels 28 Oct with the Wikipedia misspelling list's tune half); the Swift
// reference (Trie.swift, SpatialModel.swift) must use the same values.
KB_TUNABLE(insertionCost, 1.6);
KB_TUNABLE(deletionCost, 1.1);
KB_TUNABLE(transpositionCost, 0.65);
// A doubled letter typed once (posess -> possess) or a letter typed twice (excell -> excel):
// the most common spelling (not typing) error. Only the same letter on both sides is cheap:
// the candidate repeats its previous letter and the typed letter there is that letter, or the
// typed word repeats its previous letter and the candidate letter there is that letter
// (coeevitjkn is no cheaper a match for connection's nn).
KB_TUNABLE(doubledDeletionCost, 0.3);
KB_TUNABLE(doubledInsertionCost, 0.6);
inline constexpr double apostropheSkipCost = 0.4;
// firstLetterPenalty by typed length; the 5+ letter values depend on the candidate's shape.
KB_TUNABLE(firstLetterPenalty3, 0.35);
KB_TUNABLE(firstLetterPenalty4, 0.2);
KB_TUNABLE(swappedFirstLetterPenalty, 0.75);
KB_TUNABLE(missingFirstLetterPenalty4, 0.2);
KB_TUNABLE(missingFirstLetterPenalty, 1.5);
KB_TUNABLE(adjacentFirstLetterPenalty, 1.0);
KB_TUNABLE(otherFirstLetterPenalty, 2.0);
// Substitution: squared key distance / 2 + substitutionBase for a different key.
KB_TUNABLE(substitutionBase, 0.6);
// Spelling confusions (vowel for vowel: speach -> speech; c/k, c/s, s/z), whatever the key distance.
KB_TUNABLE(vowelSubstitutionCost, 1.5);
// Vowel for vowel at the typed first letter (emminent -> imminent). The retained search does not
// seed those first letters (seedFirstLetterCost); generateCandidates searches them separately.
// 1.5 (31 Oct): Wikipedia top 3 +0.1 point on the tune half, no unknown names changed.
KB_TUNABLE(firstVowelSubstitutionCost, 1.5);
// First-letter penalty (5+ letters) for a spelling confusion: vowel for vowel, c/k, c/s, s/z
// (krust -> crust), whatever the key distance; 2 = as any other first key. 1 gained 0.2 points
// of Wikipedia top 3 but changed 0.8 points more unknown names (tune half, 31 Oct): left at 2.
KB_TUNABLE(spellingFirstLetterPenalty, 2.0);
// A neighbouring key typed before a non-word (vfell -> fell, cdate -> date): the rest is searched
// and this added; 3 = off. 1.6 (31 Oct): synthetic typos fixed +1.6 points on the tune half,
// no more unknown names or rare words changed.
KB_TUNABLE(extraLeadingKeyCost, 1.6);
KB_TUNABLE(soundAlikeSubstitutionCost, 0.9);
// A candidate letter the user did not type, after the candidate letter previous (0 at the
// start), where the typed letter at that point is typedLetter (0 before the first).
inline double deletionCostAt(std::uint8_t letter, std::uint8_t previous, std::uint8_t typedLetter) noexcept {
    return letter == apostrophe ? apostropheSkipCost
        : letter == previous && letter == typedLetter ? doubledDeletionCost : deletionCost;
}
// An extra typed letter, after the typed letter previous (0 before the first), where the
// candidate letter at that point is candidateLetter (0 before the first).
inline double insertionCostAt(std::uint8_t typedLetter, std::uint8_t previous, std::uint8_t candidateLetter) noexcept {
    return typedLetter == previous && typedLetter == candidateLetter ? doubledInsertionCost : insertionCost;
}
std::optional<GridPoint> grid(std::uint8_t letter) noexcept;
// typedFirst: the typed letter is the word's first, where vowel for vowel costs
// firstVowelSubstitutionCost instead.
double substitutionCost(std::uint8_t intended, std::uint8_t typed,
                        std::optional<TouchOffset> tap = {}, bool typedFirst = false) noexcept;
// A tap scored against the key it landed on: (d(intended)^2 - d(typed)^2) / (2 sigma^2), plus
// substitutionBase for another key, capped like substitutionCost. The typed key costs nothing
// however far off-centre the tap, and a tap on the border between two keys makes both nearly
// equal; sigma is the touch spread in key widths. Spelling confusions keep their own costs.
double touchSubstitutionCost(std::uint8_t intended, std::uint8_t typed, TouchOffset tap, double sigma, bool typedFirst = false) noexcept;
// Key geometry alone: squared distance / 2 + substitutionBase, no spelling confusions
// (vowel for vowel, c/k/s/z). The raw decoder's channel (EngineOptions::raw).
double geometricSubstitutionCost(std::uint8_t intended, std::uint8_t typed, std::optional<TouchOffset> tap = {}) noexcept;
// The first-letter substitution that decides which first letters the retained search seeds:
// as substitutionCost at the first letter, but vowel for vowel only by key distance and no
// spelling first-letter discount. Seeding every confusable first letter overflows the state
// cap; firstLetterVariants searches those letters instead.
double seedFirstLetterCost(std::uint8_t label, std::uint8_t typedFirst, std::optional<TouchOffset> tap) noexcept;
// A spelling confusion of two letters, whatever their keys: vowel for vowel, c/k, c/s, s/z.
bool spellingConfusion(std::uint8_t a, std::uint8_t b) noexcept;
// Row or diagonal keyboard neighbours (squared grid distance <= 1.3).
bool neighbouringKeys(std::uint8_t a, std::uint8_t b) noexcept;
// Penalty for a candidate whose first letter differs from the typed one. From 5 letters it
// depends on the shape: first two letters swapped (ocokies -> cookies), a dropped first letter
// (the candidate's second letter is the typed first: bove -> above), a neighbouring first key,
// or any other first key. Pass 0 for a letter that is unknown or absent.
// spelling: a spelling confusion (spellingConfusion) pays at most spellingFirstLetterPenalty.
double firstLetterPenalty(std::size_t typedLength, std::uint8_t candidateFirst,
                          std::uint8_t typedFirst, std::uint8_t typedSecond = 0,
                          std::uint8_t candidateSecond = 0, bool spelling = true) noexcept;
} // namespace kb
