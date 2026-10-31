#pragma once
#include "PackedLexicon.hpp"
#include "IncrementalSearch.hpp"
#include <unordered_map>
#include <unordered_set>

namespace kb {
// Mutable words have one authority. Swift owns learning/persistence and sends
// ordered insert/bump/reset events; all trie storage and traversal live here.
class MutableTrie final {
    struct Node {
        std::vector<std::pair<std::uint8_t, std::size_t>> children;
        std::optional<std::string> word;
        std::int32_t wordID = -1;
        double logFrequency = 0;
        std::size_t characters = 0;
    };
    std::vector<Node> nodes_{1};
    std::optional<std::size_t> node(std::string_view) const;
public:
    void insert(std::string_view word, std::int64_t frequency, std::int32_t id = -1, std::size_t characters = SIZE_MAX);
    bool contains(std::string_view word) const;
    bool hasPrefix(std::string_view prefix) const;
    std::optional<std::int32_t> wordID(std::string_view word) const;
    std::optional<double> logFrequency(std::string_view word) const;
    void bump(std::string_view word);
    std::optional<std::size_t> characterCount(std::string_view word) const;
    std::vector<ChannelCandidate> search(std::string_view typed, double maxCost,
        std::span<const std::optional<TouchOffset>> taps = {},
        std::optional<std::span<const WordFunding>> funding = {}) const;
    std::vector<ChannelCandidate> completions(std::string_view prefix, std::size_t limit) const;
};

double rankFundingBonus(std::size_t rank);
double probabilityFundingBonus(double logProbability, double logProbabilityFloor = -12);
std::vector<WordFunding> rankFunding(std::span<const std::string> words);
std::vector<WordFunding> probabilityFunding(std::span<const std::pair<std::string, double>> words,
    double logProbabilityFloor = -12);
// The search radius by typed length (about 1, 2 and 3 edits), times searchRadiusScale.
KB_TUNABLE(searchRadiusScale, 1.0);
KB_TUNABLE(shortSearchRadius, 1.6);   // up to 4 letters: one omission (1.1) and a little slack
// Broad recovery (severe typos) and context injection search this many times the normal radius
// (was 2 for every length). With cheaper omissions 1.6 still reaches about four edits; 8+ letter
// words keep 1.9 so a severe typo with no context (coeevitjkn, 6.775) is still recovered.
// Latency on the keystroke benchmark: 2 everywhere was 43% over the old p95, this is 20%.
KB_TUNABLE(broadRecoveryFactor, 1.6);
KB_TUNABLE(longBroadRecoveryFactor, 1.9);
double normalSearchCost(std::size_t length) noexcept;
// A missing space (ofthe -> "of the") and a space-bar slip onto c/v/b/n/m (ofvthe).
KB_TUNABLE(splitCost, 2.0);
KB_TUNABLE(spaceKeySplitCost, 0.72);
// Context injection intentionally uses its original Levenshtein alignment (no
// transposition or first-letter penalty), distinct from trie OSA search.
double injectedSpatialCost(std::string_view typed, std::string_view target,
    std::span<const std::optional<TouchOffset>> taps = {});

// Borrowed only for a synchronous generation call. Platform locks keep mutable
// tries/boosts stable; mapped bytes are retained by the bridge's lexicon owner.
struct GenerationSnapshot {
    std::unordered_map<std::string, std::int64_t> boosts;
    std::unordered_set<std::string> blocked;
};
struct GenerationLexicon {
    const PackedLexicon* packed = nullptr;
    const MutableTrie* base = nullptr;
    const MutableTrie* supplementary = nullptr;
    const MutableTrie* personal = nullptr;
    const GenerationSnapshot* snapshot = nullptr;
    bool isBlocked(std::string_view word) const;
    std::optional<std::int64_t> boost(std::string_view word) const;
    bool contains(std::string_view word) const;
    std::size_t characterCount(std::string_view word) const;
    std::optional<double> logFrequency(std::string_view word) const;
    std::vector<ChannelCandidate> corrections(std::string_view typed, double cost,
        std::span<const std::optional<TouchOffset>> taps,
        std::optional<std::span<const WordFunding>> funding, bool broad,
        const std::function<bool()>& cancel) const;
    std::vector<ChannelCandidate> completions(std::string_view prefix, std::size_t limit) const;
    std::optional<std::string> apostropheRestoration(std::string_view word) const;
};
struct ContextSuccessor { std::string word; std::size_t characterCount; std::string first, last; };
struct GeneratedCandidates {
    std::vector<ChannelCandidate> close, broad, injected, completions, displayCorrections;
    std::optional<ChannelCandidate> split;
    bool cancelled = false;
    // The closest dictionary match is a blocked word: leave the typo alone (no autocorrect).
    bool aimedAtBlocked = false;
};
GeneratedCandidates generateCandidates(const GenerationLexicon& lexicon,
    std::string_view typed, std::span<const std::optional<TouchOffset>> taps,
    std::span<const ContextSuccessor> contextSuccessors,
    std::optional<std::span<const WordFunding>> funding,
    std::optional<std::span<const ChannelCandidate>> retainedStatic,
    bool gruTier, const std::function<bool()>& cancel = {}, std::span<const std::size_t> characterOffsets = {});

} // namespace kb
