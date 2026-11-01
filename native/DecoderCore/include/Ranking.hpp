#pragma once
#include "CandidateGeneration.hpp"
namespace kb {
struct RankedRow {
    ChannelCandidate channel;
    std::string key;
    double safety = 0, language = 0, score = 0;
    std::optional<double> neural;
};
// Weights of rank() and the correction gate's rawScore: channel cost, language model, frequency.
// The channel weighs 4 (28 Oct): at 1, a frequent word one edit further away won
// (recident -> president, not resident), above all without context.
KB_TUNABLE(channelWeight, 4.0);
// The gate for a typed dictionary word (real-word errors) keeps its own channel weight: it
// weighs context evidence against a word the user may have meant, not a spelling.
KB_TUNABLE(realWordChannelWeight, 1.0);
// ... and so does a non-word whose best candidate came only from recovery (broad, injected).
KB_TUNABLE(recoveryChannelWeight, 1.0);
// A correction to two words (a missing space) must still beat the typed text by the
// non-word margin used before 28 Oct: the split is a different, rarer error.
KB_TUNABLE(splitCorrectionMargin, 3);
KB_TUNABLE(realWordCloseOnly, 1);
KB_TUNABLE(languageWeight, 1.0);
KB_TUNABLE(frequencyWeight, 0.1);
// The pre-LM shortlist and the completion cap keep their own ordering weight: changing it
// changes which rows the language model sees, not how they are scored.
inline constexpr double shortlistFrequencyWeight = 0.3;
// Shortest typed non-word (in characters) the gate may replace: two-letter slips (ro -> to,
// yu -> you) are common, and an undo teaches the word (Swift dontCorrect -> confirmSpelling).
KB_TUNABLE(minimumCorrectionLength, 2);
// A typed non-word whose winner spells the same sounds (spellingSkeleton: doubled letters,
// vowel confusions, ph/f, ck/k, soft c/s) may fire this much below the non-word margin when it
// leads the next candidate by spellingPatternGap (accomadated -> accommodated). 0 is off.
// 1.5 (1 Nov 2026, taps, tune half): held ECPS fixed 89.94 -> 90.22%, Birkbeck 41.40 -> 42.63%,
// Wikipedia 79.45 -> 80.64%, no case lost; guardrails unchanged (names 73.6 -> 74.3%, p 0.5;
// rare words 39.0 -> 39.2%, p 0.25). 3 failed the rare-words guardrail on the tune half.
KB_TUNABLE(spellingPatternMargin, 1.5);
KB_TUNABLE(spellingPatternGap, 1.0);
// A typed dictionary word whose own contraction (apostrophe restoration: its -> it's, ill -> i'll,
// hows -> how's) the ranking scores this much above it commits the contraction, unless the
// real-word gate accepts a slip the strip ranks first (this id -> this is). 0 (1 Nov 2026): Space
// commits the contraction exactly when the strip ranks it above the typed word; before, the strip
// showed it first and Space kept the other form. Held half, make_contractions.py sentences:
// contractions restored 52.0 -> 76.2% (its 10.9 -> 87.5, ill 14.0 -> 97.5, shed 7.3 -> 91.1,
// hows/whys 0 -> 100), plain words changed 10.3 -> 13.8% (its 2.2 -> 10.3, ill 3.1 -> 15.8);
// ECPS fixed +45, no case lost; ECPS correct words changed 0.39 -> 0.42% (p 0.25). Margin 1 scored
// within a few rows of 0; 2 and above left its/ill as typed. 99 is off.
KB_TUNABLE(contractionMargin, 0.0);
struct CorrectionPolicy {
    // oovMargin -0.5 (28 Oct), with the channel weighted 4: the most misspellings fixed while
    // changing no more of the unknown names a user meant (make_keep.py, tune half) than the
    // 27 Oct engine did; lower margins fix more (-6: +2 points) but change up to 12 points
    // more names.
    double oovMargin = -0.5, realWordMargin = 5, closeRescueMargin = 3,
        closeRescueGap = 0, minimumCloseGap = 0, closeRescueMaxCost = 1.6;
};
enum class CorrectionKind { realWord, close, loose, severe };
struct CorrectionGate {
    CorrectionKind kind;
    std::string candidate;
    double margin, cost;
    std::optional<double> gap;
    bool allowsCloseRescue;
};
struct CorrectionResult {
    std::optional<std::string> word;
    double margin = 0, threshold = 0;
    std::optional<CorrectionGate> gate;
};
std::vector<RankedRow> prepareRanking(std::span<const RankedRow> rows, const std::optional<RankedRow>& typed);
std::vector<RankedRow> shortlist(std::vector<RankedRow> ordered, const std::optional<RankedRow>& typed,
    std::optional<std::size_t> limit, bool compressed);
std::vector<RankedRow> rank(std::vector<RankedRow> rows, std::string_view typedKey,
    bool compressed, std::optional<std::size_t> limit = {});
double frequencyTerm(double frequency, bool compressed);
double rawScore(const RankedRow& row, double channel = channelWeight);
bool accepts(const CorrectionPolicy& policy, const CorrectionGate& gate);
bool nearForm(std::string_view a, std::string_view b);
// Lowercase ASCII consonant frame: ph->f, ck->k, soft c->s, other c->k, z->s, doubled letters
// collapsed, every vowel run after the first letter one '*', a final silent e dropped.
// Empty for anything but letters.
std::string spellingSkeleton(std::string_view word);
CorrectionResult correction(const GenerationLexicon& lexicon, std::span<const RankedRow> rows,
    const std::unordered_map<std::string, double>& costs, std::string_view typed, std::size_t characterCount,
    std::span<const std::uint8_t> letterFlags, std::span<const std::string> context, bool kept, const std::unordered_set<std::string>& loose,
    const std::unordered_set<std::string>& broad, const CorrectionPolicy& policy, double nonWordChannel = channelWeight);
} // namespace kb
