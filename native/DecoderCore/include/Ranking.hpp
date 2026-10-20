#pragma once
#include "CandidateGeneration.hpp"
namespace kb {
struct RankedRow {
    ChannelCandidate channel;
    std::string key;
    double safety = 0, language = 0, score = 0;
    std::optional<double> neural;
};
struct CorrectionPolicy {
    double oovMargin = 3, realWordMargin = 5, closeRescueMargin = 3,
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
double rawScore(const RankedRow& row);
bool accepts(const CorrectionPolicy& policy, const CorrectionGate& gate);
bool nearForm(std::string_view a, std::string_view b);
CorrectionResult correction(const GenerationLexicon& lexicon, std::span<const RankedRow> rows,
    const std::unordered_map<std::string, double>& costs, std::string_view typed, std::size_t characterCount,
    std::span<const std::uint8_t> letterFlags, std::span<const std::string> context, bool kept, const std::unordered_set<std::string>& loose,
    const std::unordered_set<std::string>& broad, const CorrectionPolicy& policy);
} // namespace kb
