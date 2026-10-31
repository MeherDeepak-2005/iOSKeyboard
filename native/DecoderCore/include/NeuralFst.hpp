#pragma once
#include "NeuralLanguageModel.hpp"
#include "Ranking.hpp"
#include <queue>

namespace kb {
// Published NSS constants, Zhang et al. EMNLP Industry 2024, §4.4.
inline constexpr float nssUpdateThreshold = -15, nssExtendThreshold = -12;
inline constexpr double nssExpansionThreshold = -12;
inline constexpr std::size_t nssExpansionsPerFrame = 1;

// Static C o L adapter. Word labels are packed-lexicon IDs. The existing edit/touch
// channel supplies C; this trie supplies L. Unigram arcs cover the entire lexicon.
class NeuralLexicon final {
public:
    const PackedLexicon& packed;
    std::vector<PackedLexicon::TrieNodeRecord> nodes;
    std::vector<std::uint32_t> parent, terminal;
    std::vector<float> unigram, lookahead;
    explicit NeuralLexicon(const PackedLexicon&);
};

// Figures 2–4: start=0, shared unigram state=1; each neural arc has its own
// destination with an epsilon edge to 1. Direct and fallback paths coexist.
// §4.4.3: all mutable arcs in ONE array, states index contiguous ranges. Reset
// clears sizes while retaining capacity. The static unigram graph is shared.
class NeuralFst final {
public:
    struct Arc { std::uint32_t word, next; float logProbability; };
    struct Transition { std::uint32_t next; double logProbability; };
    struct Stats { std::size_t updates = 0, extensions = 0, arcs = 0, states = 0; };
    NeuralFst(std::shared_ptr<const NeuralWordModel>, std::shared_ptr<const NeuralLexicon>);
    void update(std::span<const std::string> context, bool newWord = false);
    void resetContext();
    bool expanded(std::uint32_t state) const;
    void extend(std::uint32_t state);
    std::vector<Transition> transitions(std::uint32_t state, std::uint32_t word) const;
    double lookahead(std::uint32_t state, std::uint32_t node) const;
    double wordScore(std::uint32_t state, std::uint32_t word) const;
    const NeuralLexicon& lexicon() const { return *lexicon_; }
    Stats stats() const;
    std::uint64_t modelSteps() const { return ring_->steps() + extensions_; }
    std::uint64_t revision() const { return revision_; }
private:
    struct State { std::uint32_t parent, word; std::size_t expansion = SIZE_MAX; };
    struct Expansion {
        std::size_t begin = 0, count = 0;
        float epsilon = 0;
        std::vector<float> recurrent;
        std::vector<float> lookahead;
    };
    std::shared_ptr<const NeuralWordModel> model_;
    std::shared_ptr<const NeuralLexicon> lexicon_;
    std::unique_ptr<ContextRing> ring_;
    std::vector<std::int32_t> context_, modelToWord_;
    std::vector<State> states_;
    std::vector<Arc> arcs_;
    std::vector<Expansion> expansions_;
    std::uint64_t revision_ = 0;
    std::size_t updates_ = 0, extensions_ = 0;
    void modify(std::uint32_t state, std::span<const float> recurrent,
                std::span<const float> features, float threshold);
};

// Lazy C o L o G composition. Language lookahead is included BEFORE beam pruning;
// there is no frequency-only retrieval or pre-LM candidate shortlist.
class NeuralFstSearch final {
public:
    struct Options { double beam = 16; std::size_t width = 512; };
    explicit NeuralFstSearch(NeuralFst& graph) : graph_(graph) {}
    NeuralFstSearch(NeuralFst& graph, Options options) : graph_(graph), options_(options) {}
    std::vector<RankedRow> decode(std::string_view typed, std::span<const std::optional<TouchOffset>> taps,
                                 const std::function<bool()>& cancelled = {});
    void reset();
    const std::vector<RankedRow>& completed() const { return completeRows_; }
    bool complete(std::string_view word) const { return complete_.contains(std::string(word)); }
    std::size_t expandedLastFrame() const { return expandedLastFrame_; }
private:
    struct Token {
        std::uint32_t node = 0, state = 0;
        std::string prefix;
        double language = 0, cost = 0, upper = 0;
        std::uint8_t pending = 0; // second input of a transposition
        bool boundary = false;
    };
    struct End { Token token; std::uint32_t word, next; double language; };
    NeuralFst& graph_;
    Options options_;
    std::vector<Token> beam_;
    std::unordered_set<std::string> complete_;
    std::vector<RankedRow> completeRows_;
    std::string typed_;
    std::vector<std::optional<TouchOffset>> taps_;
    std::uint64_t revision_ = 0;
    std::size_t expandedLastFrame_ = 0;
    double bound(const Token&) const;
    std::vector<Token> prune(std::vector<Token>, bool deletions, std::uint8_t typedLetter);
    std::vector<End> endings(std::span<const Token>) const;
    void advance(std::uint8_t letter, std::optional<TouchOffset> tap);
};
} // namespace kb
