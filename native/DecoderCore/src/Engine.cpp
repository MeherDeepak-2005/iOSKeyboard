#include "../include/Engine.hpp"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <limits>
#include <numeric>
#include <stdexcept>
namespace kb {
namespace {
const PersonalCounts emptyCounts;
using Clock = std::chrono::steady_clock;
double elapsed(Clock::time_point t) { return std::chrono::duration<double, std::milli>(Clock::now() - t).count(); }
const PersonalCounts& counts(const EngineView& view) { return view.personal ? *view.personal : emptyCounts; }
std::unordered_set<std::string> words(std::span<const ChannelCandidate> rows) {
    std::unordered_set<std::string> out; for (const auto& row : rows) out.insert(row.word); return out;
}
}
double EngineView::penalty(std::string_view word) const {
    // Blocked words are excluded during generation (PackedLexicon blocked bitset, learn-time
    // refusal, phrase checks), so only the residual non-blocking penalties remain to apply.
    if (penalties && !penalties->empty()) if (auto it = penalties->find(std::string(word)); it != penalties->end()) return it->second;
    return 0;
}
Engine::Engine(std::shared_ptr<const PackedLexicon> packed, EngineOptions options, std::shared_ptr<const LanguageModel> language,
        std::shared_ptr<const NeuralWordModel> neural)
    : packed_(std::move(packed)), options_(options), language_(language ? std::move(language) : std::make_shared<const LanguageModel>(packed_.get(), options.smoothing)),
      neural_(std::move(neural)) {
    if (neural_) {
        if (!packed_) throw std::invalid_argument("the neural search space needs a packed lexicon");
        unknown_ = UnknownWordTable::build(*neural_, *packed_);
    }
}
std::unique_ptr<EngineSession> Engine::createSession() { return std::make_unique<EngineSession>(shared_from_this()); }
std::vector<std::string> EngineSession::nextWords(std::span<const std::string> context, const EngineView& view, std::size_t limit) const {
    auto tri = engine_->language_->successors(context, counts(view), true, limit);
    auto bi = engine_->language_->successors(context, counts(view), false, limit);
    return LanguageModel::nextWords(std::move(tri), std::move(bi), limit);
}
namespace {
// u(w) of the NSS <unk> fallback: the n-gram unigram mass (frequency + 1) of an emittable
// pack word, else 0.5, LanguageModel's mass for a word without a pack entry.
std::optional<double> lexiconMass(const EngineView& view, std::string_view word) {
    const auto* packed = view.lexicon.packed;
    const bool emittable = !word.empty() && std::all_of(word.begin(), word.end(), [](char c) { return (c >= 'a' && c <= 'z') || c == '\''; });
    if (packed && emittable) if (auto id = packed->wordID(word)) return double(packed->frequency(std::uint32_t(*id))) + 1;
    return std::nullopt;
}
double unigramMass(const EngineView& view, std::string_view word) { return lexiconMass(view, word).value_or(0.5); }
}
// The NSS scores lexicon words: its vocabulary directly, the rest of the pack through
// P(<unk>|context). A string the lexicon cannot emit (the typed non-word, a personal word)
// is Gboard's "literal decoding" case, outside the language FST. It keeps the n-gram's
// context-free unknown-word mass, the literal baseline the correction gate was calibrated
// on, shifted by how much more (or less) likely than usual an unknown word is here.
std::vector<double> EngineSession::neuralScores(std::span<const std::string> words, std::span<const std::string> context, const EngineView& view) const {
    std::vector<double> out(words.size());
    std::vector<std::string> literal;
    std::vector<std::size_t> where;
    for (std::size_t i = 0; i < words.size(); ++i) {
        if (auto mass = lexiconMass(view, words[i]))
            out[i] = nssLanguageWeight * nss_->logProbability(words[i], *mass) + LanguageModel::personalBoost(words[i], context, counts(view), view.lexicon);
        else { literal.push_back(words[i]); where.push_back(i); }
    }
    if (!literal.empty()) {
        static const PersonalCounts none;
        auto base = engine_->language_->scores(literal, {}, none, view.lexicon);
        const double shift = engine_->neural_->unknownLogCenter() < 0
            ? nssLiteralUnknownWeight * (nss_->unknownLogProbability() - engine_->neural_->unknownLogCenter()) : 0;
        for (std::size_t k = 0; k < where.size(); ++k)
            out[where[k]] = base[k] + shift + LanguageModel::personalBoost(literal[k], context, counts(view), view.lexicon);
    }
    return out;
}
// The context's most likely lexicon words, then words the user's own history adds after
// the last context word (a learned bigram seen at least 3 times), as the n-gram tier does.
std::vector<std::string> EngineSession::neuralNextWords(std::span<const std::string> context, const EngineView& view, std::size_t limit) const {
    std::vector<std::string> out;
    for (const auto& [id, logProbability] : nss_->arcs(nssArcThreshold, nssArcLimit)) {
        (void)logProbability;
        if (out.size() >= limit) break;
        std::string word(nss_->model().word(id));
        if (view.lexicon.contains(word) && !view.lexicon.isBlocked(word)) out.push_back(std::move(word));
    }
    if (!context.empty()) for (const auto& [word, count] : counts(view).bi(context.back()))
        if (count >= 3 && view.lexicon.contains(word) && !view.lexicon.isBlocked(word) && std::find(out.begin(), out.end(), word) == out.end()) out.push_back(word);
    return out;
}
std::vector<WordFunding> EngineSession::neuralFunding(const EngineView& view) const {
    if (funding_ && funding_->revision == nss_->revision() && funding_->vocabulary == view.vocabularyRevision) return funding_->words;
    std::vector<std::pair<std::string, double>> words;
    for (const auto& [id, logProbability] : nss_->arcs(nssArcThreshold, nssArcLimit)) {
        if (logProbability <= nssFundingFloor || words.size() >= nssFundingLimit) break;
        std::string word(nss_->model().word(id));
        if (view.lexicon.contains(word) && !view.lexicon.isBlocked(word)) words.emplace_back(std::move(word), logProbability);
    }
    funding_ = NeuralFunding{nss_->revision(), view.vocabularyRevision, probabilityFunding(words, nssFundingFloor)};
    return funding_->words;
}
std::vector<RankedRow> EngineSession::score(std::vector<ChannelCandidate> rows, const std::optional<ChannelCandidate>& typed,
        const DecodeInput& input, const EngineView& view, const std::unordered_set<std::string>* completionOnly) const {
    std::vector<RankedRow> prepared;
    prepared.reserve(rows.size());
    const bool residual = view.penalties && !view.penalties->empty();
    for (auto& row : rows) { auto key = row.word; auto safety = residual ? view.penalty(key) : 0.0; prepared.push_back({std::move(row), std::move(key), safety, 0, 0, {}}); }
    std::optional<RankedRow> extra;
    if (typed) extra = RankedRow{*typed, typed->word, 0, 0, 0, {}};
    auto ordered = prepareRanking(prepared, extra);
    // Completions cost 0, so up to 24 of them could fill the 32-row pre-LM shortlist and drop
    // a strong correction before the language model sees it (tat lost "that"). Keep only the
    // best completion-only rows, by the shortlist's own order, so corrections keep >= 15 slots.
    constexpr std::size_t completionSlots = 16;
    if (completionOnly && !completionOnly->empty()) {
        std::vector<RankedRow> completions, others;
        for (auto& row : ordered) ((extra && row.key == extra->key) || !completionOnly->contains(row.key) ? others : completions).push_back(std::move(row));
        if (completions.size() > completionSlots) {
            std::stable_sort(completions.begin(), completions.end(), [](const auto& a, const auto& b) {
                auto lhs = -a.channel.cost + shortlistFrequencyWeight * frequencyTerm(a.channel.logFrequency, true);
                auto rhs = -b.channel.cost + shortlistFrequencyWeight * frequencyTerm(b.channel.logFrequency, true);
                return lhs == rhs ? utf8Less(a.key, b.key) : lhs > rhs;
            });
            completions.resize(completionSlots);
        }
        ordered = std::move(others);
        for (auto& row : completions) ordered.push_back(std::move(row));
    }
    auto list = shortlist(std::move(ordered), extra, 32, true);
    std::vector<std::string> single;
    single.reserve(list.size()); for (const auto& row : list) single.push_back(row.channel.word);
    const bool neural = input.modelTier == "nss";
    auto probabilities = neural ? neuralScores(single, input.context, view) : engine_->language_->scores(single, input.context, counts(view), view.lexicon);
    for (std::size_t i = 0; i < list.size(); ++i) {
        auto& row = list[i]; row.language = probabilities[i];
        if (row.channel.word.find(' ') != std::string::npos) {
            std::vector<std::string> phrase; std::string_view text = row.channel.word;
            while (!text.empty()) { auto pos = text.find(' '); if (pos) phrase.emplace_back(text.substr(0, pos)); if (pos == text.npos) break; text.remove_prefix(pos + 1); }
            if (neural) {
                // ExtendLM: each later word is scored after the model reads the earlier ones.
                row.language = nssLanguageWeight * nss_->sequence(phrase, [&](std::string_view word) { return unigramMass(view, word); });
                std::vector<std::string> context(input.context.begin(), input.context.end());
                for (const auto& word : phrase) { row.language += LanguageModel::personalBoost(word, context, counts(view), view.lexicon); context.push_back(word); }
            } else row.language = engine_->language_->sequence(phrase, input.context, counts(view), view.lexicon);
        }
    }
    return rank(std::move(list), typed ? typed->word : "", true);
}
DecodeOutput EngineSession::decode(const DecodeInput& input, const EngineView& view, const CancellationToken* token) {
    DecodeOutput out; out.identity = input.identity;
    auto cancelled = [&] { return token && token->cancelled(); };
    if (input.language != "en") { out.status = EngineStatus::unsupportedLanguage; return out; }
    const bool neural = input.modelTier == "nss";
    if (input.modelTier != "ngram" && !(neural && engine_->neural_)) { out.status = EngineStatus::unsupportedModel; return out; }
    if (cancelled()) { out.status = EngineStatus::cancelled; return out; }
    if (view.lexicon.packed != engine_->packed_.get()) throw std::invalid_argument("engine/view dictionary mismatch");
    const auto& typed = input.normalized;
    if (!validUTF8(input.word) || !validUTF8(typed) || std::any_of(input.context.begin(),input.context.end(),[](const auto& word){return !validUTF8(word);})) throw std::invalid_argument("invalid UTF-8 request");
    if (!input.letterFlags.empty() && input.letterFlags.size()!=typed.size()) throw std::invalid_argument("invalid letter metadata");
    if (!input.characterOffsets.empty()) {
        if(input.characterOffsets.front()!=0||input.characterOffsets.back()!=typed.size())throw std::invalid_argument("invalid character boundaries");
        for(std::size_t i=1;i<input.characterOffsets.size();++i) {
            auto at=input.characterOffsets[i];
            if(at<=input.characterOffsets[i-1]||at>typed.size()||(at<typed.size()&&(static_cast<unsigned char>(typed[at])&0xc0)==0x80))throw std::invalid_argument("invalid character boundaries");
        }
    }
    if (neural) {
        if (!nss_) nss_ = std::make_unique<NeuralSearchSpace>(engine_->neural_, engine_->unknown_);
        nss_->update(input.context);   // UpdateLM: one model step per newly committed word
    }
    if (typed.empty()) {
        auto next = neural ? neuralNextWords(input.context, view, 8) : nextWords(input.context, view, 8); std::vector<std::string> selected;
        for (const auto& word : next) if ((input.context.empty() || word != input.context.back()) && std::find(selected.begin(), selected.end(), word) == selected.end()) selected.push_back(word);
        for (const auto& word : view.topWords) if (selected.size() < 3 && (input.context.empty() || word != input.context.back()) && std::find(selected.begin(), selected.end(), word) == selected.end()) selected.push_back(word);
        if (selected.size() > 3) selected.resize(3);
        std::vector<ChannelCandidate> rows; for (const auto& word : selected) rows.push_back({word, 0, view.lexicon.logFrequency(word).value_or(0)});
        for (const auto& row : score(std::move(rows), {}, input, view)) out.suggestions.push_back(row.channel.word);
        return out;
    }
    auto length = input.characterOffsets.empty() ? typed.size() : input.characterOffsets.size() - 1;
    auto t = Clock::now();
    std::optional<std::vector<ChannelCandidate>> retained;
    // Retained search accepts only a-z and apostrophes. Reject other input before
    // building a ~24k-seed set that advanceNormalized would discard every keystroke.
    const bool retainable = std::all_of(typed.begin(), typed.end(), [](unsigned char c) { return (c >= 'a' && c <= 'z') || c == apostrophe; });
    if (!retainable) search_.reset();
    if (retainable && typed.size() >= 5 && engine_->packed_ && engine_->packed_->hasTrie()) {
        auto first = std::uint8_t(typed.front()), second = std::uint8_t(typed[1]);
        const auto tap = input.taps.empty() ? std::nullopt : input.taps.front();
        const bool sameSeedTap = tap.has_value() == seedTap_.has_value() && (!tap || (tap->dx == seedTap_->dx && tap->dy == seedTap_->dy));
        // Seeds cover the radius this length needs (2.8 up to 7 letters, 3.6 from 8), so most
        // first letters stay under the state cap; a word growing past 7 letters reseeds once.
        const double radius = normalSearchCost(length);
        bool reuse = sameSeedTap && seedRadius_ >= radius && searchVocabularyRevision_ == view.vocabularyRevision && searchPersonalizationRevision_ == view.personalizationRevision && search_ && first_ == first && second_ == second && searchIdentity_.wordSessionID == input.identity.wordSessionID &&
            searchIdentity_.layoutRevision == input.identity.layoutRevision && searchIdentity_.fieldRevision == input.identity.fieldRevision &&
            searchIdentity_.vocabularyEpoch == input.identity.vocabularyEpoch && searchIdentity_.personalizationEpoch == input.identity.personalizationEpoch;
        if (!reuse) {
            std::vector<WordFrequencyBoost> boosts;
            if (view.lexicon.snapshot) for (const auto& [word, count] : view.lexicon.snapshot->boosts) boosts.push_back({word, std::uint32_t(std::max<std::int64_t>(count, 0))});
            auto seeds = engine_->packed_->incrementalSeeds(first, input.taps.empty() ? std::nullopt : input.taps.front(), engine_->options_.stateCap, boosts, second, radius);
            if (seeds) {
                if (search_) search_->reset(std::move(seeds));
                else search_ = std::make_unique<IncrementalSearch>(std::move(seeds));
            } else search_.reset();
            first_ = first; second_ = second; seedRadius_ = radius; searchIdentity_ = input.identity; seedTap_ = tap; searchPersonalizationRevision_ = view.personalizationRevision; searchVocabularyRevision_ = view.vocabularyRevision;
        }
        if (search_) {
            if (search_->advanceNormalized(typed, input.taps)) retained = search_->candidates(normalSearchCost(length));
            else search_.reset();
        }
    }
    if (engine_->options_.profile) out.timings.session = elapsed(t);
    // NSS: the neural distribution conditions every word, the first one included (<bos>).
    auto next = neural ? neuralNextWords(input.context, view, 24) : input.context.empty() ? std::vector<std::string>{} : nextWords(input.context, view, 24);
    std::vector<ContextSuccessor> successors;
    if (length >= 4) for (const auto& word : next) successors.push_back({word, view.lexicon.characterCount(word), {}, {}});
    auto funding = input.funding;
    if (!funding && neural) funding = neuralFunding(view);
    if (!funding && !next.empty()) funding = rankFunding(next);
    t = Clock::now();
    auto pools = generateCandidates(view.lexicon, typed, input.taps, successors,
        funding ? std::optional<std::span<const WordFunding>>(*funding) : std::nullopt,
        retained ? std::optional<std::span<const ChannelCandidate>>(*retained) : std::nullopt, false, cancelled, input.characterOffsets);
    if (pools.cancelled || cancelled()) { out.status = EngineStatus::cancelled; return out; }
    if (engine_->options_.profile) out.timings.generation = elapsed(t);
    auto close = words(pools.close), broad = words(pools.broad), injected = words(pools.injected), completed = words(pools.completions);
    auto display = words(pools.completions); for (const auto& c : pools.displayCorrections) display.insert(c.word);
    std::unordered_map<std::string, double> costs;
    auto addCosts = [&](const auto& rows) { for (const auto& c : rows) { auto [it, fresh] = costs.emplace(c.word, c.cost); if (!fresh) it->second = std::min(it->second, c.cost); } };
    addCosts(pools.close); addCosts(pools.broad); addCosts(pools.injected);
    std::vector<ChannelCandidate> scoring;
    auto append = [&](const auto& rows) { scoring.insert(scoring.end(), rows.begin(), rows.end()); };
    append(pools.completions); append(pools.displayCorrections); append(pools.close); append(pools.broad); append(pools.injected);
    if (pools.split) { scoring.push_back(*pools.split); display.insert(pools.split->word); costs[pools.split->word] = pools.split->cost; }
    ChannelCandidate literal{typed, 0, view.lexicon.logFrequency(typed).value_or(std::log(double(counts(view).uni(typed)) + 1))};
    std::unordered_set<std::string> completionOnly = completed;
    for (const auto* rows : {&pools.displayCorrections, &pools.close, &pools.broad, &pools.injected})
        for (const auto& c : *rows) completionOnly.erase(c.word);
    if (pools.split) completionOnly.erase(pools.split->word);
    t = Clock::now(); auto ranked = score(std::move(scoring), literal, input, view, &completionOnly);
    if (engine_->options_.profile) out.timings.scoring = elapsed(t);
    t = Clock::now();
    auto typedRow = std::find_if(ranked.begin(), ranked.end(), [&](const auto& row) { return row.channel.word == typed; });
    auto typedScore = typedRow == ranked.end() ? 0 : typedRow->score;
    for (const auto& row : ranked) {
        const auto& word = row.channel.word;
        if (out.suggestions.size() < 3 && display.contains(word)) out.suggestions.push_back(word);
        auto source = word == typed ? CandidateSource::typed : pools.split && word == pools.split->word ? CandidateSource::splitCorrection : close.contains(word) ? CandidateSource::fuzzyLexicon : injected.contains(word) ? CandidateSource::contextInjection : broad.contains(word) ? CandidateSource::broadRecovery : completed.contains(word) ? CandidateSource::completion : CandidateSource::fuzzyLexicon;
        if (out.candidates.size() < 24) out.candidates.push_back({row, source, row.score - typedScore});
    }
    static const std::unordered_set<std::string> iForms{"i", "i'm", "i'll", "i've", "i'd"};
    if (input.word == typed && iForms.contains(typed)) out.correction = {typed, 100, 0, {}};
    else {
        auto loose = broad; loose.insert(injected.begin(), injected.end());
        for (const auto& word : close) { loose.erase(word); broad.erase(word); }
        // A typo aimed at a blocked word is left alone (biitch must not become "british").
        out.correction = correction(view.lexicon, ranked, costs, typed, length, input.letterFlags, input.context, input.kept || pools.aimedAtBlocked, loose, broad, engine_->options_.correction);
    }
    if (out.correction.word) {
        std::erase(out.suggestions, *out.correction.word); out.suggestions.insert(out.suggestions.begin(), *out.correction.word);
    } else if (std::find(out.suggestions.begin(), out.suggestions.end(), typed) == out.suggestions.end()) {
        if (out.suggestions.size() >= 3) out.suggestions.back() = input.word; else out.suggestions.push_back(input.word);
    }
    if (out.suggestions.size() > 3) out.suggestions.resize(3);
    if (engine_->options_.profile) out.timings.policy = elapsed(t);
    if (cancelled()) { out = {}; out.identity = input.identity; out.status = EngineStatus::cancelled; }
    return out;
}
void EngineSession::beginGlide(std::vector<std::string> context) { glideContext_ = std::move(context); glide_ = std::make_unique<StreamingGlide>(); }
std::vector<RankedRow> EngineSession::updateGlide(std::span<const Point> path, const GlideLayout& layout, const EngineView& view,
        std::span<const std::string> dynamic, const CancellationToken* token) {
    if (token && token->cancelled()) return {};
    if (!glide_) beginGlide({});
    if (!glide_->consume(path, layout)) throw GlideInvalidated();
    if (glide_->needsAugmentation) {
        auto next = glide_->empty() ? nextWords(glideContext_, view, 48) : std::vector<std::string>{};
        glide_->augment(view.lexicon, next, dynamic);
    }
    auto rows = glide_->rows(); std::vector<std::string> labels; std::vector<double> safety;
    const bool residual = view.penalties && !view.penalties->empty();
    for (const auto& row : rows) { labels.push_back(row.word); safety.push_back(residual ? view.penalty(row.word) : 0.0); }
    auto language = engine_->language_->scores(labels, glideContext_, counts(view), view.lexicon);
    auto result = rankGlide(view.lexicon, rows, language, safety, 0.10, {});
    return token && token->cancelled() ? std::vector<RankedRow>{} : result;
}
} // namespace kb

namespace kb {
namespace {
bool glideWord(std::string_view word) { return word.size()>=2 && std::all_of(word.begin(),word.end(),[](unsigned char c){return(c>='a'&&c<='z')||c=='\'';}); }
}
EngineView EngineState::view() const {
    return {{packed_.get(),nullptr,&supplementary_,&adopted_,vocabulary_.snapshot().get()},personal_.counts().get(),top_,&residual_,personal_.revision(),vocabularyRevision_};
}
void EngineState::prepareTop(){
    top_.clear();if(!packed_)return;auto ids=packed_->starterIDs(24);
    if(ids.empty()){for(std::uint32_t i=0;i<packed_->wordCount();++i)ids.push_back(std::int32_t(i));std::stable_sort(ids.begin(),ids.end(),[&](auto a,auto b){return packed_->frequency(a)>packed_->frequency(b);});if(ids.size()>32)ids.resize(32);}
    for(auto id:ids){std::string word(packed_->word(id));if(!vocabulary_.snapshot()->blocked.contains(word))top_.push_back(std::move(word));if(top_.size()>=8)break;}
}
void EngineState::setSafety(std::unordered_map<std::string,double> penalties){
    penalties_=std::move(penalties);residual_.clear();std::unordered_set<std::string> blocked;
    for(const auto&[word,cost]:penalties_){if(!std::isfinite(cost))blocked.insert(word);else if(packed_&&packed_->wordID(word))residual_.emplace(word,cost);}
    // Blocked dictionary words are excluded during generation from now on (installed once).
    if(packed_){std::vector<std::string> terms(blocked.begin(),blocked.end());packed_->installBlocked(terms);}
    vocabulary_.setBlocked(std::move(blocked));prepareTop();++vocabularyRevision_;}
void EngineState::note(const std::string&word,std::int64_t count){auto lexicon=view().lexicon;bool allow=personal_.allowsAdoption(word,count,lexicon);if(vocabulary_.noteUse(lexicon,adopted_,word,count,allow,8,glideWord(word)))++vocabularyRevision_;}
void EngineState::apply(const UserEvent& event){
    switch(event.kind){
    case UserEventKind::learn:if(event.learnable&&!event.word.empty()&&!penalties_.contains(event.word)){personal_.learn(event.context,event.word);personal_.prune();note(event.word,personal_.counts()->uni(event.word));}break;
    case UserEventKind::confirmSpelling:personal_.confirm(event.word);break;
    case UserEventKind::correctionStood:personal_.releaseKeep(event.word);break;
    case UserEventKind::wordReplaced:personal_.releaseKeep(event.word);personal_.demote(event.word);break;
    case UserEventKind::reset:personal_.reset(event.epoch);adopted_=MutableTrie();vocabulary_.resetPersonalization();++vocabularyRevision_;break;
    case UserEventKind::supplementary:if(event.learnable&&!event.word.empty()&&!penalties_.contains(event.word)&&!view().lexicon.contains(event.word)){supplementary_.insert(event.word,50);vocabulary_.supplementary(event.word,50,glideWord(event.word));++vocabularyRevision_;}break;
    }
}
void EngineState::importPersonalization(PersonalizationSnapshot snapshot){
    personal_.install(std::move(snapshot));personal_.prune();adopted_=MutableTrie();vocabulary_.resetPersonalization();++vocabularyRevision_;
    std::vector<std::string> words;for(const auto&[word,count]:personal_.counts()->unigram){(void)count;words.push_back(word);}std::sort(words.begin(),words.end(),utf8Less);for(const auto&word:words)note(word,std::min<std::int64_t>(personal_.counts()->uni(word),50));
}
}
