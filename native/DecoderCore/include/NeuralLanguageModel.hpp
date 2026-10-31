#pragma once
#include <array>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <span>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace kb {
class PackedLexicon;

// Word-level neural search space LM (tools/nss): a recurrent model (CIFG/LSTM or GRU)
// over the fixed 30k-word NSS vocabulary plus <unk>, read from an `.nsslm` file
// (tools/nss/nss/export.py). int8 rows with fp32 scales are dequantized on the fly, so
// the weights stay in the mapped file. Immutable once loaded and safe to share; it
// borrows `bytes`, which `owner` keeps alive.
class NeuralWordModel final {
public:
    static std::shared_ptr<const NeuralWordModel> load(std::span<const std::byte> bytes, std::shared_ptr<const void> owner = {});
    std::size_t vocabularySize() const noexcept { return vocabulary_; }
    std::size_t stateSize() const noexcept { return stateSize_; }
    std::size_t featureSize() const noexcept { return features_; }
    std::int32_t unknown() const noexcept { return unk_; }
    std::int32_t sentenceStart() const noexcept { return bos_; }
    float unknownLexiconShare() const noexcept { return unkShare_; }
    // Mean log P(<unk>|context) over validation text (0 when the export did not record it).
    float unknownLogCenter() const noexcept { return unkCenter_; }
    std::string_view word(std::int32_t id) const;
    // A candidate as the lexicon spells it -> id, or unknown() outside the vocabulary.
    std::int32_t exact(std::string_view word) const;
    // A context word as the keyboard sends it -> id: ASCII lowercase, surrounding quotes
    // stripped, unknown() outside the vocabulary; -1 for a bare run of apostrophes (skipped).
    std::int32_t contextID(std::string_view word) const;
    // Reads `token` from `state` (stateSize floats; `<bos>` clears it first) into `next`,
    // which may alias `state`, and writes the output features (featureSize floats).
    void step(std::int32_t token, std::span<const float> state, std::span<float> next, std::span<float> features) const;
    // log P(w | context, a word follows) for every id: <pad>/<bos>/<eos> are -inf.
    void wordLogProbabilities(std::span<const float> features, std::span<float> out) const;
    const std::array<std::uint8_t, 32>& vocabularySHA256() const noexcept { return vocabularySHA_; }
private:
    struct Matrix { const std::int8_t* q = nullptr; const float* scale = nullptr; std::size_t rows = 0, cols = 0; };
    struct Layer { Matrix gates, projection; const float* bias = nullptr; std::size_t input = 0; };
    NeuralWordModel() = default;
    std::shared_ptr<const void> owner_;
    std::uint32_t arch_ = 0;
    bool cifg_ = false;
    std::size_t vocabulary_ = 0, embed_ = 0, hidden_ = 0, projection_ = 0, features_ = 0, recurrent_ = 0, stateSize_ = 0;
    std::int32_t pad_ = 0, unk_ = 1, bos_ = 2, eos_ = 3;
    float unkShare_ = 0, unkCenter_ = 0;
    Matrix embedding_, output_, gruProjection_;
    const float* outputBias_ = nullptr;
    std::vector<Layer> layers_;
    // Words stay in the mapped file; lookups binary-search ids sorted by spelling
    // (120 KB instead of a 30k-entry hash map's ~2 MB of dirty heap).
    const std::uint32_t* wordOffsets_ = nullptr;
    const char* wordText_ = nullptr;
    std::vector<std::int32_t> sorted_;
    std::array<std::uint8_t, 32> vocabularySHA_{};
};

// Gboard's NSS fallback: a lexicon word outside the model vocabulary is reached through
// P(<unk>|context) into the unigram lexicon,
//   log P(w|context) = log P(<unk>|context) + log share + log u(w) - log oovMass,
// with u(w) the n-gram unigram mass (pack frequency + 1; 0.5 without a pack entry, as
// LanguageModel scores it) and oovMass the sum of u over emittable [a-z'] pack words
// outside the vocabulary. `share` is the fraction of <unk> training tokens that were
// lexicon words; the rest is text the lexicon cannot emit (names), left as typed.
struct UnknownWordTable {
    double logShare = 0, logOOVMass = 0;
    std::size_t oovWords = 0;
    static UnknownWordTable build(const NeuralWordModel&, const PackedLexicon&);
    double logWordGivenUnknown(double unigramMass) const;
};

// Rolling ring buffer of per-word model states for the current sentence: the left
// context is read once, not on every request. Slot = position % capacity; the oldest
// state is overwritten; the state after <bos> (the root) is kept apart. sync() restores
// the longest cached match and steps only the words after it (0 steps for another
// keystroke, 1 for a committed word or a slid 8-word window, 0 after a backspace into
// the previous word). A context shorter than `window` starts at the sentence start;
// a full window may be the tail of a longer cached sentence. Mirrors tools/nss/nss/ring.py.
class ContextRing final {
public:
    explicit ContextRing(std::shared_ptr<const NeuralWordModel> model, std::size_t capacity = 64, std::size_t window = 8);
    struct Sync { std::size_t reused = 0, stepped = 0; };
    Sync sync(std::span<const std::int32_t> context);
    std::span<const float> state() const { return stateAt(length_); }
    std::span<const float> features() const { return featuresAt(length_); }
    std::size_t length() const noexcept { return length_; }
    std::uint64_t steps() const noexcept { return steps_; }
private:
    std::shared_ptr<const NeuralWordModel> model_;
    std::size_t capacity_, window_, length_ = 0;
    std::uint64_t steps_ = 0;
    std::vector<float> rootState_, rootFeatures_, states_, features_;
    std::vector<std::int32_t> ids_;
    std::size_t oldest() const noexcept { return length_ > capacity_ ? length_ - capacity_ + 1 : 1; }
    std::int32_t idAt(std::size_t position) const { return ids_[(position - 1) % capacity_]; }
    std::span<const float> stateAt(std::size_t position) const;
    std::span<const float> featuresAt(std::size_t position) const;
};

// The per-session neural search space. update() (Gboard's UpdateLM) syncs the ring with
// the request's context and, only when the context changed, runs the output layer once;
// every keystroke of the word then reads the cached distribution.
class NeuralSearchSpace final {
public:
    NeuralSearchSpace(std::shared_ptr<const NeuralWordModel> model, UnknownWordTable unknown, std::size_t capacity = 64, std::size_t window = 8);
    ContextRing::Sync update(std::span<const std::string> context);
    // log P(word | context): a vocabulary word directly, any other through <unk>.
    double logProbability(std::string_view word, double unigramMass) const;
    double unknownLogProbability() const { return logProbabilities_[std::size_t(model_->unknown())]; }
    // Vocabulary words above `threshold` (natural log), best first: the words the search
    // space expands with their LM weight (Gboard keeps e^-15 and above).
    const std::vector<std::pair<std::int32_t, float>>& arcs(float threshold, std::size_t limit) const;
    // ExtendLM for a multi-word candidate ("of the"): later words are scored after
    // stepping the model through the earlier ones from the cached context state.
    double sequence(std::span<const std::string> words, const std::function<double(std::string_view)>& unigramMass) const;
    const NeuralWordModel& model() const noexcept { return *model_; }
    std::uint64_t modelSteps() const noexcept { return ring_.steps(); }
    // Changes whenever update() installs a new distribution (keys per-context caches).
    std::uint64_t revision() const noexcept { return revision_; }
private:
    std::shared_ptr<const NeuralWordModel> model_;
    UnknownWordTable unknown_;
    ContextRing ring_;
    std::vector<std::int32_t> ids_;
    std::vector<float> logProbabilities_;
    std::uint64_t revision_ = 0;
    bool ready_ = false;
    mutable std::vector<std::pair<std::int32_t, float>> arcs_;
    mutable float arcsThreshold_ = 0;
    mutable std::size_t arcsLimit_ = 0;
    mutable bool arcsReady_ = false;
    double score(std::string_view word, double unigramMass, std::span<const float> logProbabilities) const;
};
} // namespace kb
