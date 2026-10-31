#pragma once
#include "PlatformContract.hpp"
#include "LanguageModel.hpp"
#include "NeuralLanguageModel.hpp"
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
    UnknownWordTable unknown_;
public:
    explicit Engine(std::shared_ptr<const PackedLexicon> packed, EngineOptions options = {}, std::shared_ptr<const LanguageModel> language = {},
        std::shared_ptr<const NeuralWordModel> neural = {});
    std::unique_ptr<EngineSession> createSession();
    std::unique_ptr<EngineState> createState() const { return std::make_unique<EngineState>(packed_); }
    const PackedLexicon* dictionary() const { return packed_.get(); }
    bool supportsNeuralSearchSpace() const noexcept { return neural_ != nullptr; }
};
// Neural search space settings (Gboard NSS, Zhang et al. 2024): arcs above e^-15 form the
// context's search space; words above the funding floor get extra search radius.
inline constexpr float nssArcThreshold = -15.0f;
inline constexpr std::size_t nssArcLimit = 1024, nssFundingLimit = 1024;
inline constexpr double nssFundingFloor = -12.0;
// Scale on the NSS log-probability in ranking and the correction gate (1: the model's own
// probabilities, as Gboard uses them; the gate margins were fitted on n-gram scores).
KB_TUNABLE(nssLanguageWeight, 1.0);
// A typed string the lexicon cannot emit shares the context's unknown-word odds:
// + weight * (log P(<unk>|context) - its mean on validation text). 0 is Gboard's fixed
// literal penalty, under which a name in a name slot ("talking to Kemal") loses to an
// out-of-vocabulary lexicon name ("kendall") the slot's P(<unk>) lifts.
KB_TUNABLE(nssLiteralUnknownWeight, 1.0);
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
    std::unique_ptr<NeuralSearchSpace> nss_;
    // The NSS funding list changes only with the context (and the blocked vocabulary).
    struct NeuralFunding { std::uint64_t revision = 0, vocabulary = 0; std::vector<WordFunding> words; };
    mutable std::optional<NeuralFunding> funding_;
    std::vector<RankedRow> score(std::vector<ChannelCandidate> rows, const std::optional<ChannelCandidate>& typed,
        const DecodeInput& input, const EngineView& view, const std::unordered_set<std::string>* completionOnly = nullptr) const;
    // The NSS tier's language scores, next words and search funding; nss_ must be updated
    // to the request's context first.
    std::vector<double> neuralScores(std::span<const std::string> words, std::span<const std::string> context, const EngineView& view) const;
    std::vector<std::string> neuralNextWords(std::span<const std::string> context, const EngineView& view, std::size_t limit) const;
    std::vector<WordFunding> neuralFunding(const EngineView& view) const;
public:
    explicit EngineSession(std::shared_ptr<Engine> engine) : engine_(std::move(engine)) {}
    DecodeOutput decode(const DecodeInput&, const EngineView&, const CancellationToken* = nullptr);
    std::vector<std::string> nextWords(std::span<const std::string> context, const EngineView&, std::size_t limit = 24) const;
    void beginGlide(std::vector<std::string> context);
    std::vector<RankedRow> updateGlide(std::span<const Point> path, const GlideLayout&, const EngineView&,
        std::span<const std::string> dynamicWords, const CancellationToken* = nullptr);
    void endGlide() { glide_.reset(); glideContext_.clear(); }
    void memoryPressure() { search_.reset(); seedTaps_.clear(); nss_.reset(); funding_.reset(); endGlide(); }
    // Model steps the session's NSS context ring has run (0 without the NSS tier).
    std::uint64_t neuralSteps() const noexcept { return nss_ ? nss_->modelSteps() : 0; }
};
} // namespace kb
