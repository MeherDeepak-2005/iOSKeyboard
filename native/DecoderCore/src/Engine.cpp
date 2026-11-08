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
// The middle of the strip is what Space commits: the correction, or the typed word when the user
// undid a correction of it this session (kept), which otherwise sat beside the very contraction
// Space no longer applies. Without either, the typed word stays among the three; typedFirst puts
// it in the middle (raw decoding commits the typed word whenever no completion outscores it).
void placeDecision(DecodeOutput& out, const std::string& typed, const DecodeInput& input, bool typedFirst = false) {
    if (out.correction.word) {
        std::erase(out.suggestions, *out.correction.word); out.suggestions.insert(out.suggestions.begin(), *out.correction.word);
    } else if ((input.kept || typedFirst) && !typed.empty()) {
        std::erase(out.suggestions, typed); std::erase(out.suggestions, input.word);
        out.suggestions.insert(out.suggestions.begin(), input.word);
    } else if (std::find(out.suggestions.begin(), out.suggestions.end(), typed) == out.suggestions.end()) {
        if (out.suggestions.size() >= 3) out.suggestions.back() = input.word; else out.suggestions.push_back(input.word);
    }
    if (out.suggestions.size() > 3) out.suggestions.resize(3);
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
    if (neural_ || options_.raw) {
        if (!packed_) throw std::invalid_argument("the neural search space needs a packed lexicon");
        neuralLexicon_ = std::make_shared<NeuralLexicon>(*packed_);
    }
}
std::unique_ptr<EngineSession> Engine::createSession() { return std::make_unique<EngineSession>(shared_from_this()); }
std::shared_ptr<const NeuralFst::Tables> Engine::neuralTables() const {
    // Sessions run on different queues (typing, each Glide gesture); call_once builds it once.
    std::call_once(neuralTablesOnce_, [&] {
        neuralTables_ = std::make_shared<NeuralFst::Tables>(neural_, neuralLexicon_,
            NeuralFst::Options{options_.nssExact, options_.nssUnigramFloor, options_.nssUnknownExponent});
    });
    return neuralTables_;
}
NeuralFst& EngineSession::neuralGraph() {
    if (!neuralGraph_) neuralGraph_ = std::make_unique<NeuralFst>(engine_->neuralTables());
    return *neuralGraph_;
}
std::vector<std::string> EngineSession::nextWords(std::span<const std::string> context, const EngineView& view, std::size_t limit) const {
    auto tri = engine_->language_->successors(context, counts(view), true, limit);
    auto bi = engine_->language_->successors(context, counts(view), false, limit);
    return LanguageModel::nextWords(std::move(tri), std::move(bi), limit);
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
    auto probabilities = engine_->language_->scores(single, input.context, counts(view), view.lexicon);
    for (std::size_t i = 0; i < list.size(); ++i) {
        auto& row = list[i]; row.language = probabilities[i];
        if (row.channel.word.find(' ') != std::string::npos) {
            std::vector<std::string> phrase; std::string_view text = row.channel.word;
            while (!text.empty()) { auto pos = text.find(' '); if (pos) phrase.emplace_back(text.substr(0, pos)); if (pos == text.npos) break; text.remove_prefix(pos + 1); }
            row.language = engine_->language_->sequence(phrase, input.context, counts(view), view.lexicon);
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
    if (engine_->options_.raw) return decodeRaw(input, view, token, neural);
    if (neural) return decodeNeural(input, view, token);
    if (typed.empty()) {
        auto next = nextWords(input.context, view, 8); std::vector<std::string> selected;
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
    auto next = input.context.empty() ? std::vector<std::string>{} : nextWords(input.context, view, 24);
    std::vector<ContextSuccessor> successors;
    if (length >= 4) for (const auto& word : next) successors.push_back({word, view.lexicon.characterCount(word), {}, {}});
    auto funding = input.funding;
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
    placeDecision(out, typed, input);
    if (engine_->options_.profile) out.timings.policy = elapsed(t);
    if (cancelled()) { out = {}; out.identity = input.identity; out.status = EngineStatus::cancelled; }
    return out;
}
void EngineSession::beginGlide(std::vector<std::string> context) { neuralSearch_.reset(); neuralGraph_.reset(); neuralIdentityReady_ = false; glideContext_ = std::move(context); glide_ = std::make_unique<StreamingGlide>(); }
std::vector<RankedRow> EngineSession::updateGlide(std::span<const Point> path, const GlideLayout& layout, const EngineView& view,
        std::span<const std::string> dynamic, const CancellationToken* token) {
    if (token && token->cancelled()) return {};
    if (!glide_) beginGlide({});
    if (engine_->neural_) {
        neuralGraph();
        neuralGraph_->update(glideContext_);
        std::vector<Point> points;
        for (auto point : path) points.push_back(toGrid(point, layout));
        auto stop = [&] { return token && token->cancelled(); };
        auto rows = decodeGlide(points, *engine_->packed_, 512, 4, 0, 0, 1.3, 8, stop,
            [&](std::size_t node) { return neuralGraph_->lookahead(0, std::uint32_t(node)); });
        for (const auto& word : dynamic) if (!view.lexicon.isBlocked(word))
            if (auto cost = shapeCost(word, points, 4, 0)) rows.push_back({word, *cost, 0});
        std::vector<RankedRow> result;
        for (const auto& row : rows) {
            if (view.lexicon.isBlocked(row.word)) continue;
            double prior;
            if (auto id = engine_->packed_->wordID(row.word)) prior = neuralGraph_->wordScore(0, std::uint32_t(*id));
            else { std::vector<std::string> labels{row.word}; prior = engine_->language_->scores(labels, {}, counts(view), view.lexicon)[0]; }
            prior += LanguageModel::personalBoost(row.word, glideContext_, counts(view), view.lexicon);
            auto safety = view.penalty(row.word);
            result.push_back({row, row.word, safety, prior, -row.cost / 0.1 + 0.6 * prior - safety, {}});
        }
        std::sort(result.begin(), result.end(), [](const auto& a, const auto& b) { return a.score == b.score ? a.key < b.key : a.score > b.score; });
        return stop() ? std::vector<RankedRow>{} : result;
    }
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

namespace kb {
DecodeOutput EngineSession::decodeNeural(const DecodeInput& input, const EngineView& view, const CancellationToken* token) {
    // A leading apostrophe on text that is not itself a word ('em, 'cause are) opens a quote:
    // decode the rest and keep the quote ('accidentaly -> 'accidentally, 'happy stays).
    if (input.normalized.size() >= 2 && input.normalized.front() == apostrophe && !view.lexicon.contains(input.normalized)) {
        auto rest = input;
        const auto quote = input.word.starts_with("’") ? 3 : input.word.starts_with("'") ? 1 : 0;
        rest.word = input.word.substr(quote); rest.normalized = input.normalized.substr(1);
        if (!rest.characterOffsets.empty()) {
            rest.characterOffsets.erase(rest.characterOffsets.begin());
            for (auto& at : rest.characterOffsets) --at;
        }
        if (!rest.letterFlags.empty()) rest.letterFlags.erase(rest.letterFlags.begin());
        if (!rest.taps.empty() && rest.taps.size() == input.characterOffsets.size() - 1) rest.taps.erase(rest.taps.begin());
        auto out = decodeNeural(rest, view, token);
        auto quoted = [](std::string& word) { word.insert(word.begin(), char(apostrophe)); };
        if (out.correction.word) quoted(*out.correction.word);
        for (auto& word : out.suggestions) quoted(word);
        for (auto& c : out.candidates) { quoted(c.ranked.key); quoted(c.ranked.channel.word); }
        return out;
    }
    DecodeOutput out; out.identity = input.identity;
    const auto started = Clock::now();
    auto cancelled = [&] { return token && token->cancelled(); };
    const bool newField = !neuralIdentityReady_ || neuralIdentity_.fieldRevision != input.identity.fieldRevision ||
        neuralIdentity_.vocabularyEpoch != input.identity.vocabularyEpoch || neuralIdentity_.personalizationEpoch != input.identity.personalizationEpoch;
    const bool newWord = newField || neuralIdentity_.wordSessionID != input.identity.wordSessionID;
    neuralGraph();
    if (newField) neuralGraph_->resetContext();
    const bool edited = !input.normalized.starts_with(neuralTyped_);
    neuralGraph_->update(input.context, newWord || edited);
    if (!neuralSearch_) neuralSearch_ = std::make_unique<NeuralFstSearch>(*neuralGraph_, NeuralFstSearch::Options{nssBeam, std::size_t(nssWidth), false, nssTouchSigma, nssChannelWeight});
    if (newWord || neuralIdentity_.layoutRevision != input.identity.layoutRevision) neuralSearch_->reset();
    neuralIdentity_ = input.identity; neuralIdentityReady_ = true; neuralTyped_ = input.normalized;
    if (cancelled()) { out.status = EngineStatus::cancelled; return out; }
    const auto& typed = input.normalized;
    std::vector<RankedRow> ranked, correctionRows;
    if (typed.empty()) {
        // Next-word prediction over BOTH neural and unigram paths: the best arcs and the most
        // frequent words reached through <unk> (NeuralFst::best), not a scan of the lexicon.
        for (const auto& [id, language] : neuralGraph_->best(0, 64)) {
            const auto word = std::string(engine_->packed_->word(id));
            if (view.lexicon.isBlocked(word)) continue;
            ranked.push_back({{word, 0, 0}, word, view.penalty(word), language, language, {}});
        }
    } else { ranked = neuralSearch_->decode(typed, input.taps, cancelled); correctionRows = neuralSearch_->completed(); }
    if (cancelled()) { neuralGraph_->update(input.context, true); neuralSearch_->reset(); out.status = EngineStatus::cancelled; return out; }
    std::erase_if(ranked, [&](const auto& row) { return view.lexicon.isBlocked(row.key); });
    std::erase_if(correctionRows, [&](const auto& row) { return view.lexicon.isBlocked(row.key); });
    std::unordered_map<std::string, double> costs;
    // The frequency prior ranks corrections; next-word predictions keep the model's order.
    auto frequency = [&](const std::string& word) { return typed.empty() ? 0 : nssFrequencyWeight * view.lexicon.logFrequency(word).value_or(0); };
    auto personalize = [&](auto& row) {
        row.safety = view.penalty(row.key);
        row.language += LanguageModel::personalBoost(row.key, input.context, counts(view), view.lexicon) + frequency(row.key);
        row.score = row.language - nssChannelWeight * row.channel.cost - row.safety;
    };
    for (auto& row : ranked) personalize(row);
    for (auto& row : correctionRows) { personalize(row); costs[row.key] = row.channel.cost; }
    const auto length = input.characterOffsets.empty() ? typed.size() : input.characterOffsets.size() - 1;
    std::unordered_set<std::string> close, broad, injected;
    bool aimedAtBlocked = false;
    double nameMargin = 0;   // added to the typed text's score after any rescoring
    if (!typed.empty() && nssRecovery > 0) {
        // The n-gram tier's recovery (decode() above), scored by G: the joint search's complete
        // words within the normal radius are the close set, and generateCandidates adds the narrow
        // first-letter passes, broad recovery for severe typos, context injection of the model's
        // likely next words and the blocked-word check. The gate judges recovered words as close
        // words, or with nssRecovery 2 as the n-gram tier does (loose, severe).
        std::vector<ChannelCandidate> retained;
        const auto radius = normalSearchCost(length);
        for (const auto& row : correctionRows)
            if (row.channel.cost <= radius && row.key.find(' ') == std::string::npos)
                retained.push_back({row.key, row.channel.cost, view.lexicon.logFrequency(row.key).value_or(0)});
        std::vector<ContextSuccessor> successors;
        std::vector<std::string> next;
        if (length >= 4) for (const auto& [id, language] : neuralGraph_->best(0, 24)) {
            (void)language;
            std::string word(engine_->packed_->word(id));
            if (view.lexicon.isBlocked(word)) continue;
            successors.push_back({word, view.lexicon.characterCount(word), {}, {}});
            next.push_back(std::move(word));
        }
        auto funding = input.funding;
        if (!funding && !next.empty()) funding = rankFunding(next);
        auto pools = generateCandidates(view.lexicon, typed, input.taps, successors,
            funding ? std::optional<std::span<const WordFunding>>(*funding) : std::nullopt,
            std::optional<std::span<const ChannelCandidate>>(retained), false, cancelled, input.characterOffsets);
        if (pools.cancelled || cancelled()) { neuralGraph_->update(input.context, true); neuralSearch_->reset(); out.status = EngineStatus::cancelled; return out; }
        aimedAtBlocked = pools.aimedAtBlocked;
        close = words(pools.close); broad = words(pools.broad); injected = words(pools.injected);
        auto add = [&](const ChannelCandidate& c, bool display) {
            if (c.word == typed || view.lexicon.isBlocked(c.word)) return;
            if (auto found = costs.find(c.word); found != costs.end()) { found->second = std::min(found->second, c.cost); return; }
            const auto id = engine_->packed_->wordID(c.word);
            if (!id || !std::isfinite(engine_->neuralLexicon_->unigram[std::size_t(*id)])) return;
            RankedRow row{c, c.word, view.penalty(c.word), neuralGraph_->wordScore(0, std::uint32_t(*id)), 0, {}};
            row.channel.logFrequency = 0;   // as the joint search's rows: frequency enters through personalize
            personalize(row);
            costs[c.word] = c.cost; correctionRows.push_back(row);
            if (display) ranked.push_back(std::move(row));
        };
        for (const auto& c : pools.close) add(c, false);
        for (const auto* rows : {&pools.broad, &pools.injected}) for (const auto& c : *rows) add(c, pools.completions.empty());
    }
    if (!typed.empty()) {
        // Literal/dynamic words are outside G, as in paper §4.2: typed text outside the lexicon
        // scores P(<unk>) in context (nssUnknownLiteral) or else the n-gram's context-free mass.
        std::vector<std::string> literal{typed};
        static const PersonalCounts none;
        double language = engine_->language_->scores(literal, {}, none, view.lexicon)[0];
        if (auto id = engine_->packed_->wordID(typed)) language = neuralGraph_->wordScore(0, std::uint32_t(*id));
        else {
            if (engine_->options_.nssExact && (nssUnknownLiteral > 0 || engine_->options_.nssTypedUnknown))
                if (const auto unknown = neuralGraph_->typedUnknown(); std::isfinite(unknown)) language = unknown;
            const auto& shown = input.word;
            const bool capitalized = shown.size() >= 2 && std::isupper(static_cast<unsigned char>(shown[0])) &&
                std::any_of(shown.begin() + 1, shown.end(), [](unsigned char c) { return std::islower(c); });
            if (capitalized && !input.context.empty()) nameMargin = nssCapitalMargin;
        }
        language += LanguageModel::personalBoost(typed, input.context, counts(view), view.lexicon) + frequency(typed);
        std::erase_if(ranked, [&](const auto& row) { return row.key == typed; });
        ranked.push_back({{typed, 0, 0}, typed, 0, language, language, {}}); costs[typed] = 0;
        std::erase_if(correctionRows, [&](const auto& row) { return row.key == typed; });
        correctionRows.push_back(ranked.back());
        for (const auto* dynamic : {view.lexicon.personal, view.lexicon.supplementary}) if (dynamic) {
            for (const auto& c : dynamic->search(typed, normalSearchCost(typed.size()), input.taps)) {
                if (view.lexicon.isBlocked(c.word) || c.word == typed) continue;
                std::vector<std::string> word{c.word};
                const auto prior = engine_->language_->scores(word, {}, counts(view), view.lexicon)[0];
                ranked.push_back({{c.word, c.cost, 0}, c.word, view.penalty(c.word), prior, prior - nssChannelWeight * c.cost - view.penalty(c.word), {}});
                correctionRows.push_back(ranked.back()); costs[c.word] = c.cost;
            }
        }
    }
    if (nssNgramWeight > 0 && !typed.empty()) {
        // Rescore the candidates with the n-gram mixed in: its unigram statistics separate a
        // common word from a rare one a cheaper edit away (abot: about, not abbot).
        std::unordered_map<std::string, double> mixed;
        for (const auto* rows : {&ranked, &correctionRows}) for (const auto& row : *rows) mixed.emplace(row.key, 0);
        std::vector<std::string> single;
        for (auto& [key, score] : mixed) {
            if (key.find(' ') == std::string::npos) { single.push_back(key); continue; }
            std::vector<std::string> phrase; std::string_view text = key;
            while (!text.empty()) { auto pos = text.find(' '); if (pos) phrase.emplace_back(text.substr(0, pos)); if (pos == text.npos) break; text.remove_prefix(pos + 1); }
            score = engine_->language_->sequence(phrase, input.context, counts(view), view.lexicon);
        }
        const auto probabilities = engine_->language_->scores(single, input.context, counts(view), view.lexicon);
        for (std::size_t i = 0; i < single.size(); ++i) mixed[single[i]] = probabilities[i];
        for (auto* rows : {&ranked, &correctionRows}) for (auto& row : *rows) {
            row.language = (1 - nssNgramWeight) * row.language + nssNgramWeight * mixed[row.key];
            row.score = row.language - nssChannelWeight * row.channel.cost - (row.key == typed ? 0 : row.safety);
        }
    }
    if (nameMargin != 0) for (auto* rows : {&ranked, &correctionRows}) for (auto& row : *rows)
        if (row.key == typed) { row.language += nameMargin; row.score += nameMargin; }
    std::sort(ranked.begin(), ranked.end(), [](const auto& a, const auto& b) { return a.score == b.score ? a.key < b.key : a.score > b.score; });
    if (typed.empty()) {
        for (const auto& row : ranked) if (out.suggestions.size() < 3) out.suggestions.push_back(row.key);
        return out;
    }
    const auto literal = std::find_if(ranked.begin(), ranked.end(), [&](const auto& row) { return row.key == typed; });
    const auto typedScore = literal->score;
    for (const auto& row : ranked) {
        if (out.suggestions.size() < 3) out.suggestions.push_back(row.key);
        if (out.candidates.size() < 24) out.candidates.push_back({row, row.key == typed ? CandidateSource::typed : row.key.find(' ') != std::string::npos ? CandidateSource::splitCorrection : costs.contains(row.key) ? CandidateSource::fuzzyLexicon : CandidateSource::completion, row.score - typedScore});
    }
    // A typed "id" is I'd, is, rid or the noun; the model's favourite "i" (I think id -> I)
    // drops the d the user typed.
    if (typed == "id") std::erase_if(correctionRows, [](const auto& row) { return row.key == "i"; });
    if (nssRecovery == 1 || nssRecovery == 3) broad.clear();
    if (nssRecovery == 1) injected.clear();
    auto loose = broad; loose.insert(injected.begin(), injected.end());
    for (const auto& word : close) { loose.erase(word); broad.erase(word); }
    auto policy = engine_->options_.correction;
    policy.oovMargin += nssOovMarginShift; policy.realWordMargin += nssRealWordMarginShift;
    // A typo aimed at a blocked word is left alone (biitch must not become "british").
    out.correction = correction(view.lexicon, correctionRows, costs, typed, length, input.letterFlags, input.context, input.kept || aimedAtBlocked, loose, broad, policy, nssChannelWeight);
    static const std::unordered_set<std::string> iForms{"i", "i'm", "i'll", "i've", "i'd"};
    if (input.word == typed && iForms.contains(typed)) out.correction = {typed, 100, 0, {}};
    placeDecision(out, typed, input);
    if (engine_->options_.profile) out.timings.generation = elapsed(started);
    return out;
}
} // namespace kb

namespace kb {
// Raw decoding (EngineOptions::raw): what the language model and the channel do alone.
// Both tiers run the same joint search (C o L o G) and differ only in G, the neural
// search space or the production n-gram as its backoff graph. The channel has no spelling
// rules; there is no correction gate, i-forms rule, minimum length, candidate funding,
// injection, recovery or completion cap. The best complete word is committed when its
// score (log P - channelWeight * cost) beats the typed text's: a lexicon word scores by
// G, any other string by the n-gram's context-free unknown-word mass (literal decoding,
// the same for both). Blocked words stay excluded; residual safety demotions and personal
// history are not applied.
DecodeOutput EngineSession::decodeRaw(const DecodeInput& input, const EngineView& view, const CancellationToken* token, bool neural) {
    DecodeOutput out; out.identity = input.identity;
    const auto started = Clock::now();
    auto cancelled = [&] { return token && token->cancelled(); };
    SearchGraph* graph;
    if (neural) {
        neuralGraph();
        graph = neuralGraph_.get();
    } else {
        if (!ngramGraph_) ngramGraph_ = std::make_unique<NgramFst>(*engine_->packed_, engine_->neuralLexicon_);
        graph = ngramGraph_.get();
    }
    const bool newField = !neuralIdentityReady_ || neuralIdentity_.fieldRevision != input.identity.fieldRevision ||
        neuralIdentity_.vocabularyEpoch != input.identity.vocabularyEpoch || neuralIdentity_.personalizationEpoch != input.identity.personalizationEpoch;
    const bool newWord = newField || neuralIdentity_.wordSessionID != input.identity.wordSessionID;
    if (newField) graph->resetContext();
    graph->update(input.context, newWord || !input.normalized.starts_with(neuralTyped_));
    if (!rawSearch_ || rawGraph_ != graph) {
        rawSearch_ = std::make_unique<NeuralFstSearch>(*graph, NeuralFstSearch::Options{16, 512, true}); rawGraph_ = graph;
    }
    if (newWord || neuralIdentity_.layoutRevision != input.identity.layoutRevision) rawSearch_->reset();
    neuralIdentity_ = input.identity; neuralIdentityReady_ = true; neuralTyped_ = input.normalized;
    if (cancelled()) { out.status = EngineStatus::cancelled; return out; }
    const auto& typed = input.normalized;
    auto blocked = [&](const RankedRow& row) { return view.lexicon.isBlocked(row.key); };
    if (typed.empty()) {
        for (const auto& [id, language] : graph->best(0, 16)) {
            std::string word(engine_->packed_->word(id));
            if (view.lexicon.isBlocked(word)) continue;
            out.suggestions.push_back(std::move(word));
            if (out.suggestions.size() == 3) break;
        }
        return out;
    }
    auto ranked = rawSearch_->decode(typed, input.taps, cancelled);
    auto complete = rawSearch_->completed();
    if (cancelled()) { graph->update(input.context, true); rawSearch_->reset(); out.status = EngineStatus::cancelled; return out; }
    std::erase_if(ranked, blocked); std::erase_if(complete, blocked);
    double literal;
    bool typedIsWord = false;
    if (auto id = engine_->packed_->wordID(typed); id && std::isfinite(engine_->neuralLexicon_->unigram[std::size_t(*id)])) {
        literal = graph->wordScore(0, std::uint32_t(*id));
        typedIsWord = true;
    } else if (neural && engine_->options_.nssExact && engine_->options_.nssTypedUnknown)
        literal = neuralGraph_->typedUnknown();
    else {
        static const PersonalCounts none;
        std::vector<std::string> text{typed};
        literal = engine_->language_->scores(text, {}, none, view.lexicon)[0];
    }
    const RankedRow typedRow{{typed, 0, 0}, typed, 0, literal, literal, {}};
    std::erase_if(ranked, [&](const auto& row) { return row.key == typed; });
    std::erase_if(complete, [&](const auto& row) { return row.key == typed; });
    auto best = std::max_element(complete.begin(), complete.end(), [](const auto& a, const auto& b) { return a.score == b.score ? a.key > b.key : a.score < b.score; });
    // A kept word (the user undid a correction of it) stays as typed, as in production.
    // A typed non-word (the bad typos the strip shows a fix for) may be replaced below its own
    // score by nssRawCommitMargin; a typed dictionary word only by a better-scoring word.
    if (best != complete.end() && best->score > typedRow.score - (typedIsWord ? 0 : nssRawCommitMargin) && !input.kept)
        out.correction = {best->key, best->score - typedRow.score, 0, {}};
    ranked.push_back(typedRow);
    std::sort(ranked.begin(), ranked.end(), [](const auto& a, const auto& b) { return a.score == b.score ? a.key < b.key : a.score > b.score; });
    for (const auto& row : ranked) {
        if (out.suggestions.size() < 3 && row.key != typed) out.suggestions.push_back(row.key);
        if (out.candidates.size() < 24) out.candidates.push_back({row, row.key == typed ? CandidateSource::typed
            : row.key.find(' ') != std::string::npos ? CandidateSource::splitCorrection : CandidateSource::fuzzyLexicon, row.score - typedRow.score});
    }
    placeDecision(out, typed, input, true);
    if (engine_->options_.profile) out.timings.generation = elapsed(started);
    return out;
}
} // namespace kb
