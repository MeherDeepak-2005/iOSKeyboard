#pragma once
#include "CandidateGeneration.hpp"
#include "Ranking.hpp"
namespace kb {
struct MultiwordHypothesis {
    std::size_t offset;
    std::vector<std::string> words;
    double cost, logFrequency;
    std::string phrase() const;
};
struct MultiwordPruned { std::vector<MultiwordHypothesis> frontier; std::vector<ChannelCandidate> finished; };
class MultiwordSearch final {
    GenerationLexicon lexicon_;
    std::string typed_;
    std::vector<std::optional<TouchOffset>> taps_;
    std::unordered_map<std::size_t, std::vector<ChannelCandidate>> cache_;
public:
    MultiwordSearch(GenerationLexicon lexicon, std::string typed, std::vector<std::optional<TouchOffset>> taps);
    std::vector<MultiwordHypothesis> expand(std::span<const MultiwordHypothesis> frontier, const std::function<bool()>& cancel);
    MultiwordPruned prune(std::span<const MultiwordHypothesis> rows, std::span<const double> neural, std::span<const double> language) const;
};
} // namespace kb
