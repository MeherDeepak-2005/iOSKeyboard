#pragma once
#include "PlatformContract.hpp"
#include "LanguageModel.hpp"
#include "NeuralLanguageModel.hpp"
#include "NeuralFst.hpp"
#include "Ranking.hpp"
#include "Glide.hpp"
#include "Personalization.hpp"
#include <atomic>
#include <stdexcept>
#include "TextOrder.hpp"

namespace kb {
// Cancellation is independently thread safe. Session operations use one host lane.
class CancellationToken final {
    std::atomic<bool> cancelled_{false};
public:
    void cancel() noexcept { cancelled_.store(true, std::memory_order_relaxed); }
    bool cancelled() const noexcept { return cancelled_.load(std::memory_order_relaxed); }
};
enum class EngineStatus { ok, cancelled, unsupportedLanguage, unsupportedModel, glideInvalidated };
// Thrown by updateGlide when the retained stream can no longer be extended (path
// shrank, layout pitch changed). Hosts must fall back to a full-path decode.
struct GlideInvalidated final : std::runtime_error { GlideInvalidated() : std::runtime_error("glide stream invalidated") {} };
enum class CandidateSource { typed, fuzzyLexicon, completion, contextInjection, broadRecovery, splitCorrection };
struct DecodeInput {
    RequestIdentity identity;
    std::string word, normalized;
    std::vector<std::string> context;
    std::vector<std::optional<TouchOffset>> taps;
    std::vector<std::size_t> characterOffsets;
    std::vector<std::uint8_t> letterFlags;
    // "ngram", or "nss" (the neural search space; needs an Engine built with a NeuralWordModel).
    std::string language = "en", modelTier = "ngram";
    bool kept = false;
    std::optional<std::vector<WordFunding>> funding;
};
struct CandidateEvidence {
    RankedRow ranked;
    CandidateSource source;
    double typedMargin;
};
struct PhaseTimings {
    double session = 0, generation = 0, scoring = 0, policy = 0;
};
struct DecodeOutput {
    RequestIdentity identity;
    EngineStatus status = EngineStatus::ok;
    std::vector<std::string> suggestions;
    std::vector<CandidateEvidence> candidates;
    CorrectionResult correction;
    PhaseTimings timings;
};
// Views are borrowed synchronously; adapter snapshot owners must outlive the call.
// They point directly into native COW lexicons/counts, never platform callbacks.
// `penalties` holds only residual, non-blocking safety penalties (in-dictionary demote
// terms). Blocked words are excluded during candidate generation and never reach ranking.
struct EngineView {
    GenerationLexicon lexicon;
    const PersonalCounts* personal = nullptr;
    std::span<const std::string> topWords;
    const std::unordered_map<std::string, double>* penalties = nullptr;
    std::uint64_t personalizationRevision = 0, vocabularyRevision = 0;
    double penalty(std::string_view word) const;
};
struct EngineOptions {
    // Raw decoding, to measure the language models themselves: both tiers run the same
    // joint search (NeuralFstSearch) over their own graph (NeuralFst or NgramFst), with
    // the channel's spelling rules, the correction gate and the candidate heuristics
    // switched off. See EngineSession::decodeRaw.
    bool raw = false;
    // NeuralFst::Options::exact: exact vocabulary scores and <unk> shared outside the
    // vocabulary. false reproduces the published graph (Codex's paper replica).
    bool nssExact = true;
    // NeuralFst::Options::unigramFloor (with nssExact): vocabulary words keep the
    // published fallback path as a floor.
    bool nssUnigramFloor = false;
    // NeuralFst::Options::unknownExponent (with nssExact).
    double nssUnknownExponent = 1;
    // Raw mode, nss tier, nssExact: typed text outside the lexicon is scored by
    // NeuralFst::typedUnknown (the model's P(<unk>) in context), not the n-gram constant.
    bool nssTypedUnknown = false;
    CorrectionPolicy correction;
    Smoothing smoothing = Smoothing::wittenBell;
    bool profile = false;
    std::size_t stateCap = defaultIncrementalStateCap;
};
enum class UserEventKind { learn, confirmSpelling, correctionStood, wordReplaced, reset, supplementary };
struct UserEvent {
    UserEventKind kind;
    std::string word;
    std::vector<std::string> context;
    std::uint64_t epoch = 0;
    bool learnable = true;
};
class EngineState final {
    std::shared_ptr<const PackedLexicon> packed_;
    Personalization personal_;
    VocabularyState vocabulary_;
    MutableTrie supplementary_, adopted_;
    std::vector<std::string> top_;
    std::unordered_map<std::string,double> penalties_, residual_;
    std::uint64_t vocabularyRevision_ = 0;
    void note(const std::string& word, std::int64_t count);
    void prepareTop();
public:
    explicit EngineState(std::shared_ptr<const PackedLexicon> packed) : packed_(std::move(packed)) { prepareTop(); }
    EngineView view() const;
    void setSafety(std::unordered_map<std::string,double> penalties);
    void apply(const UserEvent&);
    void importPersonalization(PersonalizationSnapshot);
    PersonalizationSnapshot exportPersonalization() const { return personal_.exportSnapshot(); }
    std::vector<std::string> dynamicGlideWords(std::size_t limit = 128) const { return vocabulary_.dynamicWords(limit); }
    bool kept(std::string_view word) const { return personal_.kept(word); }
};
class EngineSession;
class Engine final : public std::enable_shared_from_this<Engine> {
    friend class EngineSession;
    std::shared_ptr<const PackedLexicon> packed_;
    EngineOptions options_;
    std::shared_ptr<const LanguageModel> language_;
    std::shared_ptr<const NeuralWordModel> neural_;
    std::shared_ptr<const NeuralLexicon> neuralLexicon_;
public:
    explicit Engine(std::shared_ptr<const PackedLexicon> packed, EngineOptions options = {}, std::shared_ptr<const LanguageModel> language = {},
        std::shared_ptr<const NeuralWordModel> neural = {});
    std::unique_ptr<EngineSession> createSession();
    std::unique_ptr<EngineState> createState() const { return std::make_unique<EngineState>(packed_); }
    const PackedLexicon* dictionary() const { return packed_.get(); }
    bool supportsNeuralSearchSpace() const noexcept { return neural_ != nullptr; }
};
class EngineSession final {
    std::shared_ptr<Engine> engine_;
    std::unique_ptr<IncrementalSearch> search_;
    RequestIdentity searchIdentity_;
    std::uint8_t first_ = 0, second_ = 0;
    double seedRadius_ = 0;
    std::uint64_t searchPersonalizationRevision_ = 0, searchVocabularyRevision_ = 0;
    std::optional<TouchOffset> seedTap_;
    std::unique_ptr<StreamingGlide> glide_;
    std::vector<std::string> glideContext_;
    std::vector<std::optional<TouchOffset>> seedTaps_;
    std::unique_ptr<NeuralFst> neuralGraph_;
    std::unique_ptr<NeuralFstSearch> neuralSearch_;
    std::unique_ptr<NgramFst> ngramGraph_;
    std::unique_ptr<NeuralFstSearch> rawSearch_;
    const SearchGraph* rawGraph_ = nullptr;
    RequestIdentity neuralIdentity_;
    std::string neuralTyped_;
    bool neuralIdentityReady_ = false;
    DecodeOutput decodeNeural(const DecodeInput&, const EngineView&, const CancellationToken*);
    DecodeOutput decodeRaw(const DecodeInput&, const EngineView&, const CancellationToken*, bool neural);
    std::vector<RankedRow> score(std::vector<ChannelCandidate> rows, const std::optional<ChannelCandidate>& typed,
        const DecodeInput& input, const EngineView& view, const std::unordered_set<std::string>* completionOnly = nullptr) const;
public:
    explicit EngineSession(std::shared_ptr<Engine> engine) : engine_(std::move(engine)) {}
    DecodeOutput decode(const DecodeInput&, const EngineView&, const CancellationToken* = nullptr);
    std::vector<std::string> nextWords(std::span<const std::string> context, const EngineView&, std::size_t limit = 24) const;
    void beginGlide(std::vector<std::string> context);
    std::vector<RankedRow> updateGlide(std::span<const Point> path, const GlideLayout&, const EngineView&,
        std::span<const std::string> dynamicWords, const CancellationToken* = nullptr);
    void endGlide() { glide_.reset(); glideContext_.clear(); }
    void memoryPressure() { search_.reset(); seedTaps_.clear(); neuralSearch_.reset(); rawSearch_.reset(); rawGraph_ = nullptr; neuralGraph_.reset(); ngramGraph_.reset(); neuralIdentityReady_ = false; endGlide(); }
    // Model steps the session's NSS context ring has run (0 without the NSS tier).
    std::uint64_t neuralSteps() const noexcept { return neuralGraph_ ? neuralGraph_->modelSteps() : 0; }
};
} // namespace kb
