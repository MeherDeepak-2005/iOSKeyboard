#pragma once
#include "PlatformContract.hpp"
#include "LanguageModel.hpp"
#include "NeuralLanguageModel.hpp"
#include "NeuralFst.hpp"
#include "Ranking.hpp"
#include "Glide.hpp"
#include "Personalization.hpp"
#include <atomic>
#include <mutex>
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
// The NSS tier's product rules (EngineSession::decodeNeural), tuned on the autocorrect
// benchmark's tune half (tools/evaluation/autocorrect; docs/nss-paper/COMPARISON.md).
// nssRecovery: 0 none; 1 the n-gram tier's recovered candidates (narrow first-letter passes,
// broad recovery, context injection) join the gate as close words, and a typo aimed at a
// blocked word is left alone; 2 the n-gram tier's rule, recovered words judged as loose or
// severe (changes rare words the user meant: 13% -> 37%); 3 only context injections loose.
KB_TUNABLE(nssRecovery, 1);
// Weight of the pack's log frequency added to a word's model score.
KB_TUNABLE(nssFrequencyWeight, 0.1);
// Typed text outside the lexicon scores P(<unk>) in context (NeuralFst::typedUnknown), so it
// is likelier to stand where names and new words go; 0 uses the n-gram's context-free mass.
KB_TUNABLE(nssUnknownLiteral, 1);
// A non-word typed capitalized after the first word of a sentence (Jurevis, not JUREVIS) is
// probably a name: correcting it needs this much more margin.
KB_TUNABLE(nssCapitalMargin, 3.0);
// Weight of the production n-gram in the final word scores (the joint search's candidates are
// rescored as (1 - w) x G + w x n-gram); 0 scores with G alone.
KB_TUNABLE(nssNgramWeight, 0.25);
// Added to the supplied policy's non-word margin (oovMargin, -0.5) for the NSS tier, whose
// unknown-text score sits higher than the n-gram's, and to its real-word margin (5). A real-word
// shift of -1 fixed 4.5 points more real-word errors on the held split but changed four times
// as many correct words (0.08% -> 0.34%), so it stays 0.
KB_TUNABLE(nssOovMarginShift, -1.5);
KB_TUNABLE(nssRealWordMarginShift, 0.0);
// The channel cost's weight in the NSS tier's search, scores and non-word gate. 4.5 kept more
// names and rare words but fixed fewer misspellings (held: -0.4 points, Birkbeck -2.5).
KB_TUNABLE(nssChannelWeight, 4.0);
// The NSS tier's joint search (NeuralFstSearch::Options): relative beam and token width, and
// the touch spread for taps in key widths (touchSubstitutionCost; 0 keeps substitutionCost).
KB_TUNABLE(nssBeam, 16);
KB_TUNABLE(nssWidth, 512);
KB_TUNABLE(nssTouchSigma, 0.7);
// Raw decoding commits the best completed word for a typed non-word when it scores above the
// typed text minus this margin (0: only when it outscores it); a typed dictionary word needs a
// better score. Larger commits more of the corrections the strip already shows, and changes
// more unknown words (names, rare words).
KB_TUNABLE(nssRawCommitMargin, 0.0);
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
    // The NSS graph tables every session's graph shares, built once on first use.
    mutable std::once_flag neuralTablesOnce_;
    mutable std::shared_ptr<const NeuralFst::Tables> neuralTables_;
    std::shared_ptr<const NeuralFst::Tables> neuralTables() const;
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
    NeuralFst& neuralGraph();
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
    // Builds the NSS graph ahead of the first decode, which otherwise pays for it.
    void prepareNeural() { if (engine_->neural_) neuralGraph(); }
    void memoryPressure() { search_.reset(); seedTaps_.clear(); neuralSearch_.reset(); rawSearch_.reset(); rawGraph_ = nullptr; neuralGraph_.reset(); ngramGraph_.reset(); neuralIdentityReady_ = false; endGlide(); }
    // Model steps the session's NSS context ring has run (0 without the NSS tier).
    std::uint64_t neuralSteps() const noexcept { return neuralGraph_ ? neuralGraph_->modelSteps() : 0; }
};
} // namespace kb
