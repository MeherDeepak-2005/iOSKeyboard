#pragma once
#include "LanguageModel.hpp"
#include "NeuralLanguageModel.hpp"
#include "Ranking.hpp"
#include <bit>
#include <queue>
#include <unordered_map>

namespace kb {
// Published NSS constants, Zhang et al. EMNLP Industry 2024, §4.4.
inline constexpr float nssUpdateThreshold = -15, nssExtendThreshold = -12;
inline constexpr double nssExpansionThreshold = -12;
inline constexpr std::size_t nssExpansionsPerFrame = 1;

// Static C o L adapter. Word labels are packed-lexicon IDs. The existing edit/touch
// channel supplies C; this trie supplies L. Unigram arcs cover the entire lexicon.
class NeuralLexicon final {
public:
    // A trie node, decoded on access from the mapped dictionary: the lexicon keeps no copy of
    // the 275k-node trie (6.6 MB decoded, twice that at a grown vector's capacity).
    struct Node { std::uint8_t label; std::uint32_t firstChild, childCount; std::optional<std::int32_t> wordID; };
    const PackedLexicon& packed;
    std::vector<std::uint32_t> parent, terminal;
    std::vector<float> unigram, lookahead;
    // Emittable words by unigram probability, best first (next-word prediction's fallback).
    std::vector<std::uint32_t> topUnigrams;
    double mass = 0;   // sum of frequency + 1 over the emittable words unigram[] normalizes by
    explicit NeuralLexicon(const PackedLexicon&);
    // The nodes reachable from the root. The constructor range-checks every one, so node(),
    // which the search only calls on the root and on child links, reads without a check.
    std::size_t nodeCount() const noexcept { return parent.size(); }
    Node node(std::size_t index) const noexcept {
        const auto* at = trie_ + nodeSize_ * index;
        const std::uint32_t id = wideIDs_ ? le32(at + 6) : (le16(at + 6) == 0xffffu ? 0xffffffffu : le16(at + 6));
        return {std::to_integer<std::uint8_t>(at[0]), le32(at + 2), std::to_integer<std::uint8_t>(at[1]),
            id == 0xffffffffu ? std::nullopt : std::optional<std::int32_t>(std::int32_t(id))};
    }
private:
    const std::byte* trie_;
    std::size_t nodeSize_;
    bool wideIDs_;
    static std::uint32_t le16(const std::byte* at) noexcept {
        return std::to_integer<std::uint32_t>(at[0]) | std::to_integer<std::uint32_t>(at[1]) << 8;
    }
    static std::uint32_t le32(const std::byte* at) noexcept {
        return le16(at) | std::to_integer<std::uint32_t>(at[2]) << 16 | std::to_integer<std::uint32_t>(at[3]) << 24;
    }
};

// The best arc score under each trie node, kept only for nodes on some arc's path: an
// expansion's lookahead costs its arcs, not the 275k-node trie (1 MiB per expansion).
class ArcLookahead final {
    std::vector<std::uint32_t> nodes_;
    std::vector<float> values_;
public:
    // scratch: one float per trie node, all -inf; returned to -inf.
    void build(const NeuralLexicon&, std::span<const std::pair<std::uint32_t, float>> wordScores, std::vector<float>& scratch);
    float at(std::uint32_t node) const;
    std::size_t size() const noexcept { return nodes_.size(); }
};

// The language graph the joint search composes with C o L. State 0 is the context's
// root, state 1 the shared unigram state; other states are reached by word arcs.
class SearchGraph {
public:
    struct Transition { std::uint32_t next; double logProbability; };
    virtual ~SearchGraph() = default;
    virtual void update(std::span<const std::string> context, bool newWord = false) = 0;
    virtual void resetContext() = 0;
    virtual bool expanded(std::uint32_t state) const = 0;
    virtual void extend(std::uint32_t state) = 0;
    virtual std::vector<Transition> transitions(std::uint32_t state, std::uint32_t word) const = 0;
    virtual double lookahead(std::uint32_t state, std::uint32_t node) const = 0;
    virtual double wordScore(std::uint32_t state, std::uint32_t word) const = 0;
    // The `count` best-scoring words at `state` (next-word prediction), without a lexicon scan.
    virtual std::vector<std::pair<std::uint32_t, double>> best(std::uint32_t state, std::size_t count) const = 0;
    virtual const NeuralLexicon& lexicon() const = 0;
    virtual std::uint64_t revision() const = 0;
};

// Figures 2–4: start=0, shared unigram state=1; each neural arc has its own
// destination with an epsilon edge to 1. Direct and fallback paths coexist.
// §4.4.3: all mutable arcs in ONE array, states index contiguous ranges. Reset
// clears sizes while retaining capacity. The static unigram graph is shared.
class NeuralFst final : public SearchGraph {
public:
    struct Arc { std::uint32_t word, next; float logProbability; };
    struct Stats { std::size_t updates = 0, extensions = 0, arcs = 0, states = 0; };
    // exact: every vocabulary word scores its own model probability, also below the arc
    // threshold (the threshold then only decides which words open a state), and <unk> is
    // shared among the lexicon words outside the vocabulary only,
    //   P(w | ctx) = P(<unk> | ctx) * share * u(w) / sum of u over those words,
    // u = pack frequency + 1, share = the model's unknownLexiconShare(). false: the
    // paper's graph as published, where low-probability vocabulary words and every
    // other word fall back to P(<unk>) times their share of the WHOLE lexicon (Fig. 3).
    // unigramFloor (with exact): vocabulary words keep that fallback path too, so a
    // frequent word scores at least P(<unk>|ctx) x u(w) / (sum of u over the lexicon) where
    // the model finds it unlikely (Fig. 4: both paths compete, the best one counts).
    // unknownExponent (with exact): u(w) inside the <unk> share becomes u^a, flattening the
    // frequencies so rare words keep a usable probability; 0 is TF-IDF's sublinear 1 + ln u.
    struct Options { bool exact = false, unigramFloor = false; double unknownExponent = 1; };
    // How the model's vocabulary maps onto the lexicon for one model, lexicon and options:
    // most of a graph's construction and immutable once built, so every graph over them
    // shares one (Engine builds it once for the typing session and each Glide gesture).
    struct Tables {
        Tables(std::shared_ptr<const NeuralWordModel>, std::shared_ptr<const NeuralLexicon>, Options);
        std::shared_ptr<const NeuralWordModel> model;
        std::shared_ptr<const NeuralLexicon> lexicon;
        Options options;
        std::vector<std::int32_t> modelToWord, wordToModel;   // model id <-> lexicon id, -1 outside
        std::vector<float> outsideUnigram, outsideLookahead;  // exact: log share * u / outside mass
        double outsideMass = 0;                               // exact: sum of scaled u outside
        std::vector<std::uint32_t> topOutside;
        // exact: the trie nodes on some vocabulary word's path, numbered in trie order (parents
        // first). A node's number is how many such nodes precede it: a rank over one bit per node
        // (51 KB) instead of a 4-byte number per node (1.1 MB). UINT32_MAX off every path.
        struct Numbering {
            std::vector<std::uint64_t> bits;     // the node is on a path
            std::vector<std::uint32_t> before;   // numbered nodes ahead of each 64-node block
            std::uint32_t operator[](std::size_t node) const noexcept {
                const auto word = bits[node >> 6], mask = std::uint64_t(1) << (node & 63);
                return word & mask ? before[node >> 6] + std::uint32_t(std::popcount(word & (mask - 1))) : UINT32_MAX;
            }
        } vocabularyNode;
        // number -> parent's number, model id -> its terminal's number.
        std::vector<std::uint32_t> vocabularyParent, vocabularyTerminal;
    };
    explicit NeuralFst(std::shared_ptr<const Tables>);
    NeuralFst(std::shared_ptr<const NeuralWordModel> model, std::shared_ptr<const NeuralLexicon> lex)
        : NeuralFst(std::move(model), std::move(lex), Options{}) {}
    NeuralFst(std::shared_ptr<const NeuralWordModel> model, std::shared_ptr<const NeuralLexicon> lex, Options options)
        : NeuralFst(std::make_shared<Tables>(std::move(model), std::move(lex), options)) {}
    void update(std::span<const std::string> context, bool newWord = false) override;
    void resetContext() override;
    bool expanded(std::uint32_t state) const override;
    void extend(std::uint32_t state) override;
    std::vector<Transition> transitions(std::uint32_t state, std::uint32_t word) const override;
    double lookahead(std::uint32_t state, std::uint32_t node) const override;
    double wordScore(std::uint32_t state, std::uint32_t word) const override;
    std::vector<std::pair<std::uint32_t, double>> best(std::uint32_t state, std::size_t count) const override;
    const NeuralLexicon& lexicon() const override { return *lexicon_; }
    std::uint64_t revision() const override { return revision_; }
    // exact: log P(text outside the lexicon | context) = P(<unk>) x (1 - share) x half a
    // count among the words outside the vocabulary (as the n-gram scores unseen text).
    double typedUnknown() const;
    Stats stats() const;
    std::uint64_t modelSteps() const { return ring_->steps() + extensions_; }
private:
    struct State { std::uint32_t parent, word; std::size_t expansion = SIZE_MAX; };
    struct Expansion {
        std::size_t begin = 0, count = 0;
        float epsilon = 0;
        std::vector<float> recurrent;
        std::vector<float> distribution;   // exact: every vocabulary log-probability
        std::vector<float> vocabularyLookahead;   // exact: best vocabulary score per vocabulary node
        ArcLookahead lookahead;            // published graph: best arc score under each node
    };
    std::shared_ptr<const Tables> tables_;
    std::shared_ptr<const NeuralWordModel> model_;
    std::shared_ptr<const NeuralLexicon> lexicon_;
    Options options_;
    std::unique_ptr<ContextRing> ring_;
    std::vector<std::int32_t> context_;
    std::vector<State> states_;
    std::vector<Arc> arcs_;
    std::vector<Expansion> expansions_;
    std::vector<float> scratch_;
    std::uint64_t revision_ = 0;
    std::size_t updates_ = 0, extensions_ = 0;
    void modify(std::uint32_t state, std::span<const float> recurrent,
                std::span<const float> features, float threshold);
};

// The paper's control arm (§5.2): the N-gram search space, here the production
// Witten–Bell n-gram (LanguageModel) as a backoff graph. A state is a two-word history;
// its arcs are the observed bigram/trigram successors with their exact interpolated
// probabilities, every other word reaches the unigram distribution through the
// history's backoff weight. Word states expand under the same rule as NeuralFst's
// ExtendLM (until then the next word is contextless, Fig. 3), so the two graphs share
// one search and differ only in their probabilities. Personal history is not included.
class NgramFst final : public SearchGraph {
public:
    NgramFst(const PackedLexicon&, std::shared_ptr<const NeuralLexicon>);
    void update(std::span<const std::string> context, bool newWord = false) override;
    void resetContext() override;
    bool expanded(std::uint32_t state) const override { return state <= 1 || states_.at(state).expanded; }
    void extend(std::uint32_t state) override { states_.at(state).expanded = true; }
    std::vector<Transition> transitions(std::uint32_t state, std::uint32_t word) const override;
    double lookahead(std::uint32_t state, std::uint32_t node) const override;
    double wordScore(std::uint32_t state, std::uint32_t word) const override;
    std::vector<std::pair<std::uint32_t, double>> best(std::uint32_t state, std::size_t count) const override;
    const NeuralLexicon& lexicon() const override { return *lexicon_; }
    std::uint64_t revision() const override { return revision_; }
    std::size_t states() const noexcept { return states_.size(); }
private:
    struct History {
        std::int32_t first = -1, second = -1;   // packed ids; -1: none
        bool ready = false, expanded = false;
        double backoff = 0;                     // log weight of the unigram path
        std::unordered_map<std::uint32_t, float> successors;   // log P(word | history)
        std::vector<std::pair<std::uint32_t, float>> ranked;    // successors, best first
        ArcLookahead lookahead;
    };
    const PackedLexicon& packed_;
    std::shared_ptr<const NeuralLexicon> lexicon_;
    double unigramShift_ = 0;   // log(emittable mass / n-gram corpus total)
    mutable std::vector<History> states_;
    mutable std::unordered_map<std::uint64_t, std::uint32_t> index_;
    mutable std::vector<float> scratch_;
    std::vector<std::int32_t> context_;
    std::uint64_t revision_ = 0;
    const History& prepared(std::uint32_t state) const;
    std::uint32_t stateFor(std::int32_t first, std::int32_t second) const;
};

// Lazy C o L o G composition. Language lookahead is included BEFORE beam pruning;
// there is no frequency-only retrieval or pre-LM candidate shortlist.
class NeuralFstSearch final {
public:
    // raw: the channel is key geometry plus uniform insertion/deletion/transposition
    // costs, without the spelling rules (doubled letters, vowel/sound-alike confusions,
    // apostrophe skips); see EngineOptions::raw.
    // touchSigma > 0: taps scored by touchSubstitutionCost with this spread (not raw).
    // channelWeight: the channel cost's weight against log P in every score and bound.
    struct Options { double beam = 16; std::size_t width = 512; bool raw = false; double touchSigma = 0; double channelWeight = kb::channelWeight; };
    explicit NeuralFstSearch(SearchGraph& graph) : graph_(graph) {}
    NeuralFstSearch(SearchGraph& graph, Options options) : graph_(graph), options_(options) {}
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
    SearchGraph& graph_;
    Options options_;
    std::vector<Token> beam_;
    std::unordered_set<std::string> complete_;
    std::vector<RankedRow> completeRows_;
    std::string typed_;
    std::vector<std::optional<TouchOffset>> taps_;
    std::uint64_t revision_ = 0;
    std::size_t expandedLastFrame_ = 0;
    double bound(const Token&) const;
    double deletion(std::uint8_t letter, std::uint8_t previous, std::uint8_t typedLetter) const;
    double insertion(std::uint8_t typedLetter, std::uint8_t previous, std::uint8_t candidateLetter) const;
    double substitution(std::uint8_t intended, std::uint8_t typed, std::optional<TouchOffset> tap, bool first) const;
    std::vector<Token> prune(std::vector<Token>, bool deletions, std::uint8_t typedLetter);
    std::vector<End> endings(std::span<const Token>) const;
    void advance(std::uint8_t letter, std::optional<TouchOffset> tap);
};
} // namespace kb
