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
    if (penalties) if (auto it = penalties->find(std::string(word)); it != penalties->end()) return it->second;
    return lexicon.isBlocked(word) ? std::numeric_limits<double>::infinity() : 0;
}
Engine::Engine(std::shared_ptr<const PackedLexicon> packed, EngineOptions options, std::shared_ptr<const LanguageModel> language)
    : packed_(std::move(packed)), options_(options), language_(language ? std::move(language) : std::make_shared<const LanguageModel>(packed_.get(), options.smoothing)) {}
std::unique_ptr<EngineSession> Engine::createSession() { return std::make_unique<EngineSession>(shared_from_this()); }
std::vector<std::string> EngineSession::nextWords(std::span<const std::string> context, const EngineView& view, std::size_t limit) const {
    auto tri = engine_->language_->successors(context, counts(view), true, limit);
    auto bi = engine_->language_->successors(context, counts(view), false, limit);
    return LanguageModel::nextWords(std::move(tri), std::move(bi), limit);
}
std::vector<RankedRow> EngineSession::score(std::vector<ChannelCandidate> rows, const std::optional<ChannelCandidate>& typed,
        const DecodeInput& input, const EngineView& view) const {
    std::vector<RankedRow> prepared;
    prepared.reserve(rows.size());
    for (auto& row : rows) { auto key = row.word; auto safety = view.penalty(key); prepared.push_back({std::move(row), std::move(key), safety, 0, 0, {}}); }
    std::optional<RankedRow> extra;
    if (typed) extra = RankedRow{*typed, typed->word, 0, 0, 0, {}};
    auto list = shortlist(prepareRanking(prepared, extra), extra, 32, true);
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
    if (input.modelTier != "ngram") { out.status = EngineStatus::unsupportedModel; return out; }
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
    if (typed.empty()) {
        auto next = nextWords(input.context, view, 8); std::vector<std::string> selected;
        for (const auto& word : next) if ((input.context.empty() || word != input.context.back()) && !view.lexicon.isBlocked(word) && std::find(selected.begin(), selected.end(), word) == selected.end()) selected.push_back(word);
        for (const auto& word : view.topWords) if (selected.size() < 3 && (input.context.empty() || word != input.context.back()) && std::find(selected.begin(), selected.end(), word) == selected.end()) selected.push_back(word);
        if (selected.size() > 3) selected.resize(3);
        std::vector<ChannelCandidate> rows; for (const auto& word : selected) rows.push_back({word, 0, view.lexicon.logFrequency(word).value_or(0)});
        for (const auto& row : score(std::move(rows), {}, input, view)) out.suggestions.push_back(row.channel.word);
        return out;
    }
    auto length = input.characterOffsets.empty() ? typed.size() : input.characterOffsets.size() - 1;
    auto t = Clock::now();
    std::optional<std::vector<ChannelCandidate>> retained;
    if (typed.size() >= 5 && engine_->packed_ && engine_->packed_->hasTrie()) {
        auto first = std::uint8_t(typed.front());
        const auto tap = input.taps.empty() ? std::nullopt : input.taps.front();
        const bool sameSeedTap = tap.has_value() == seedTap_.has_value() && (!tap || (tap->dx == seedTap_->dx && tap->dy == seedTap_->dy));
        bool reuse = sameSeedTap && searchVocabularyRevision_ == view.vocabularyRevision && searchPersonalizationRevision_ == view.personalizationRevision && search_ && first_ == first && searchIdentity_.wordSessionID == input.identity.wordSessionID &&
            searchIdentity_.layoutRevision == input.identity.layoutRevision && searchIdentity_.fieldRevision == input.identity.fieldRevision &&
            searchIdentity_.vocabularyEpoch == input.identity.vocabularyEpoch && searchIdentity_.personalizationEpoch == input.identity.personalizationEpoch;
        if (!reuse) {
            std::vector<WordFrequencyBoost> boosts;
            if (view.lexicon.snapshot) for (const auto& [word, count] : view.lexicon.snapshot->boosts) boosts.push_back({word, std::uint32_t(std::max<std::int64_t>(count, 0))});
            auto seeds = engine_->packed_->incrementalSeeds(first, input.taps.empty() ? std::nullopt : input.taps.front(), engine_->options_.stateCap, boosts);
            if (seeds) {
                if (search_) search_->reset(std::move(seeds));
                else search_ = std::make_unique<IncrementalSearch>(std::move(seeds));
            } else search_.reset();
            first_ = first; searchIdentity_ = input.identity; seedTap_ = tap; searchPersonalizationRevision_ = view.personalizationRevision; searchVocabularyRevision_ = view.vocabularyRevision;
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
    t = Clock::now(); auto ranked = score(std::move(scoring), literal, input, view);
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
        out.correction = correction(view.lexicon, ranked, costs, typed, length, input.letterFlags, input.context, input.kept, loose, broad, engine_->options_.correction);
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
    if (!glide_->consume(path, layout)) return {};
    if (glide_->needsAugmentation) {
        auto next = glide_->empty() ? nextWords(glideContext_, view, 48) : std::vector<std::string>{};
        glide_->augment(view.lexicon, next, dynamic);
    }
    auto rows = glide_->rows(); std::vector<std::string> labels; std::vector<double> safety;
    for (const auto& row : rows) { labels.push_back(row.word); safety.push_back(view.penalty(row.word)); }
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
    return {{packed_.get(),nullptr,&supplementary_,&adopted_,vocabulary_.snapshot().get()},personal_.counts().get(),top_,&penalties_,personal_.revision(),vocabularyRevision_};
}
void EngineState::prepareTop(){
    top_.clear();if(!packed_)return;auto ids=packed_->starterIDs(24);
    if(ids.empty()){for(std::uint32_t i=0;i<packed_->wordCount();++i)ids.push_back(std::int32_t(i));std::stable_sort(ids.begin(),ids.end(),[&](auto a,auto b){return packed_->frequency(a)>packed_->frequency(b);});if(ids.size()>32)ids.resize(32);}
    for(auto id:ids){std::string word(packed_->word(id));if(!vocabulary_.snapshot()->blocked.contains(word))top_.push_back(std::move(word));if(top_.size()>=8)break;}
}
void EngineState::setSafety(std::unordered_map<std::string,double> penalties){penalties_=std::move(penalties);std::unordered_set<std::string> blocked;for(const auto&[word,cost]:penalties_)if(!std::isfinite(cost))blocked.insert(word);vocabulary_.setBlocked(std::move(blocked));prepareTop();++vocabularyRevision_;}
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
