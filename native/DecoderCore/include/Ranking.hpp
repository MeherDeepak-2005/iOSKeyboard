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
CorrectionResult correction(const GenerationLexicon& lexicon, std::span<const RankedRow> rows,
    const std::unordered_map<std::string, double>& costs, std::string_view typed, std::size_t characterCount,
    std::span<const std::uint8_t> letterFlags, std::span<const std::string> context, bool kept, const std::unordered_set<std::string>& loose,
    const std::unordered_set<std::string>& broad, const CorrectionPolicy& policy, double nonWordChannel = channelWeight);
} // namespace kb
