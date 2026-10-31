#include "../include/NeuralFst.hpp"
#include <algorithm>
#include <cmath>
#include <limits>
#include <unordered_set>
namespace kb {
namespace {
constexpr float negInf = -std::numeric_limits<float>::infinity();
bool letters(std::string_view word) {
    return !word.empty() && std::all_of(word.begin(), word.end(), [](char c) { return (c >= 'a' && c <= 'z') || c == '\''; });
}
}
NeuralLexicon::NeuralLexicon(const PackedLexicon& lex) : packed(lex) {
    nodes.push_back(lex.trieRecord(0)); parent.push_back(0);
    terminal.assign(lex.wordCount(), UINT32_MAX);
    // Packed trie children are contiguous and strictly follow their parent.
    for (std::size_t i = 0; i < nodes.size(); ++i) {
        const auto n = nodes[i];
        if (n.wordID) terminal[std::size_t(*n.wordID)] = std::uint32_t(i);
        const auto end = n.firstChild + n.childCount;
        while (nodes.size() < end) { parent.push_back(0); nodes.push_back(lex.trieRecord(nodes.size())); }
        for (auto j = n.firstChild; j < end; ++j) parent[j] = std::uint32_t(i);
    }
    double mass = 0;
    for (std::uint32_t w = 0; w < lex.wordCount(); ++w) if (letters(lex.word(w))) mass += double(lex.frequency(w)) + 1;
    unigram.assign(lex.wordCount(), negInf); lookahead.assign(nodes.size(), negInf);
    for (std::uint32_t w = 0; w < lex.wordCount(); ++w) if (letters(lex.word(w))) {
        unigram[w] = float(std::log((double(lex.frequency(w)) + 1) / mass));
        if (terminal[w] != UINT32_MAX) lookahead[terminal[w]] = unigram[w];
    }
    for (std::size_t i = nodes.size(); i-- > 1;) lookahead[parent[i]] = std::max(lookahead[parent[i]], lookahead[i]);
}
NeuralFst::NeuralFst(std::shared_ptr<const NeuralWordModel> model, std::shared_ptr<const NeuralLexicon> lex)
    : model_(std::move(model)), lexicon_(std::move(lex)), ring_(std::make_unique<ContextRing>(model_)) {
    modelToWord_.assign(model_->vocabularySize(), -1);
    for (std::size_t id = 4; id < modelToWord_.size(); ++id)
        if (auto word = lexicon_->packed.wordID(model_->word(std::int32_t(id)))) modelToWord_[id] = *word;
}
void NeuralFst::resetContext() { ring_ = std::make_unique<ContextRing>(model_); context_.clear(); states_.clear(); }
void NeuralFst::update(std::span<const std::string> context, bool newWord) {
    std::vector<std::int32_t> ids;
    for (const auto& word : context) if (auto id = model_->contextID(word); id >= 0) ids.push_back(id);
    if (!states_.empty() && ids == context_) {
        if (!newWord) return;
        // Same committed context: restore the initial graph by truncating its
        // arenas. Reuse the already computed UpdateLM distribution, without an
        // additional dense inference or reconstruction of thousands of arcs.
        const auto count = expansions_[0].count;
        arcs_.resize(count); states_.resize(count + 2); expansions_.resize(1);
        for (std::size_t i = 2; i < states_.size(); ++i) states_[i].expansion = SIZE_MAX;
        extensions_ = 0; ++revision_; ++updates_; return;
    }
    ring_->sync(ids); context_ = std::move(ids);
    arcs_.clear(); states_.clear(); expansions_.clear(); extensions_ = 0;
    states_.push_back({0, 0, SIZE_MAX}); states_.push_back({1, 0, SIZE_MAX});
    modify(0, ring_->state(), ring_->features(), nssUpdateThreshold);
    ++revision_; ++updates_;
}
void NeuralFst::modify(std::uint32_t state, std::span<const float> recurrent, std::span<const float> features, float threshold) {
    std::vector<float> probabilities(model_->vocabularySize());
    model_->wordLogProbabilities(features, probabilities);
    Expansion e;
    e.begin = arcs_.size(); e.epsilon = probabilities[std::size_t(model_->unknown())];
    e.recurrent.assign(recurrent.begin(), recurrent.end());
    e.lookahead.assign(lexicon_->nodes.size(), negInf);
    for (std::size_t id = 4; id < probabilities.size(); ++id) {
        if (probabilities[id] < threshold || modelToWord_[id] < 0) continue;
        const auto word = std::uint32_t(modelToWord_[id]);
        if (lexicon_->terminal[word] == UINT32_MAX || !std::isfinite(lexicon_->unigram[word])) continue;
        const auto next = std::uint32_t(states_.size());
        states_.push_back({state, word, SIZE_MAX});
        arcs_.push_back({word, next, probabilities[id]});
        auto node = lexicon_->terminal[word];
        for (;;) {
            e.lookahead[node] = std::max(e.lookahead[node], probabilities[id]);
            if (!node) break;
            node = lexicon_->parent[node];
        }
    }
    e.count = arcs_.size() - e.begin;
    std::sort(arcs_.begin() + std::ptrdiff_t(e.begin), arcs_.end(), [](const auto& a, const auto& b) { return a.word < b.word; });
    states_[state].expansion = expansions_.size(); expansions_.push_back(std::move(e));
}
bool NeuralFst::expanded(std::uint32_t state) const { return state == 1 || states_.at(state).expansion != SIZE_MAX; }
void NeuralFst::extend(std::uint32_t state) {
    if (expanded(state)) return;
    const auto s = states_.at(state);
    auto recurrent = expansions_.at(states_.at(s.parent).expansion).recurrent;
    std::vector<float> features(model_->featureSize());
    model_->step(model_->contextID(lexicon_->packed.word(s.word)), recurrent, recurrent, features);
    modify(state, recurrent, features, nssExtendThreshold); ++extensions_;
}
std::vector<NeuralFst::Transition> NeuralFst::transitions(std::uint32_t state, std::uint32_t word) const {
    if (state == 1) return {{1, lexicon_->unigram[word]}};
    const auto index = states_.at(state).expansion;
    if (index == SIZE_MAX) return {{1, lexicon_->unigram[word]}};
    const auto& e = expansions_[index];
    std::vector<Transition> out{{1, double(e.epsilon) + lexicon_->unigram[word]}};
    auto first = arcs_.begin() + std::ptrdiff_t(e.begin), last = first + std::ptrdiff_t(e.count);
    auto found = std::lower_bound(first, last, word, [](const Arc& a, auto w) { return a.word < w; });
    if (found != last && found->word == word) out.push_back({found->next, found->logProbability});
    return out;
}
double NeuralFst::wordScore(std::uint32_t state, std::uint32_t word) const {
    double best = negInf;
    for (const auto& t : transitions(state, word)) best = std::max(best, t.logProbability);
    return best;
}
double NeuralFst::lookahead(std::uint32_t state, std::uint32_t node) const {
    const auto index = states_.at(state).expansion;
    if (index == SIZE_MAX) return lexicon_->lookahead[node];
    const auto& e = expansions_[index];
    double best = double(e.epsilon) + lexicon_->lookahead[node];
    best = std::max(best, double(e.lookahead[node]));
    return best;
}
NeuralFst::Stats NeuralFst::stats() const { return {updates_, extensions_, arcs_.size(), states_.size()}; }

double NeuralFstSearch::bound(const Token& t) const {
    return t.language + graph_.lookahead(t.state, t.node) - channelWeight * t.cost;
}
void NeuralFstSearch::reset() { beam_.clear(); complete_.clear(); completeRows_.clear(); typed_.clear(); taps_.clear(); revision_ = graph_.revision(); }
std::vector<NeuralFstSearch::Token> NeuralFstSearch::prune(std::vector<Token> input, bool deletions, std::uint8_t typedLetter) {
    auto order = [&](const Token& a, const Token& b) {
        auto x = a.upper, y = b.upper;
        if (x != y) return x < y;
        return std::tie(a.prefix, a.state, a.node, a.pending, a.boundary) > std::tie(b.prefix, b.state, b.node, b.pending, b.boundary);
    };
    // Recombine before selecting the beam. Queue comparisons then use cached
    // lookahead, avoiding repeated hash lookups for every heap comparison.
    struct Key {
        std::uint32_t node, state; std::string prefix; std::uint8_t pending; bool boundary;
        bool operator==(const Key&) const = default;
    };
    struct Hash { std::size_t operator()(const Key& k) const {
        return std::hash<std::string>{}(k.prefix) ^ (std::size_t(k.node) * 0x9e3779b1u) ^
            (std::size_t(k.state) * 0x85ebca6bu) ^ (std::size_t(k.pending) << 2) ^ std::size_t(k.boundary);
    }};
    auto keyOf = [](const Token& t) { return Key{t.node, t.state, t.prefix, t.pending, t.boundary}; };
    std::unordered_map<Key, std::size_t, Hash> positions; positions.reserve(input.size());
    std::vector<Token> unique; unique.reserve(input.size());
    for (auto& t : input) {
        t.upper = bound(t);
        auto [it, fresh] = positions.emplace(keyOf(t), unique.size());
        if (fresh) unique.push_back(std::move(t));
        else if (t.upper > unique[it->second].upper) unique[it->second] = std::move(t);
    }
    if (unique.size() > options_.width) {
        std::nth_element(unique.begin(), unique.begin() + std::ptrdiff_t(options_.width), unique.end(),
            [&](const auto& a, const auto& b) { return order(b, a); });
        unique.resize(options_.width);
    }
    std::priority_queue<Token, std::vector<Token>, decltype(order)> queue(order, std::move(unique));
    if (queue.empty()) return {};
    const auto floor = queue.top().upper - options_.beam;
    std::unordered_set<Key, Hash> seen; seen.reserve(options_.width);
    std::vector<Token> out;
    const auto& lex = graph_.lexicon();
    while (!queue.empty() && out.size() < options_.width) {
        auto t = queue.top(); queue.pop();
        if (t.upper < floor || !std::isfinite(t.upper)) break;
        if (!seen.insert(keyOf(t)).second) continue;
        out.push_back(t);
        if (!deletions || t.pending) continue;
        const auto node = lex.nodes[t.node];
        for (auto child = node.firstChild; child < node.firstChild + node.childCount; ++child) {
            auto next = t; next.node = child; next.boundary = false;
            next.cost += deletionCostAt(lex.nodes[child].label, node.label, typedLetter);
            next.upper = bound(next);
            if (next.upper >= floor) queue.push(std::move(next));
        }
    }
    return out;
}
std::vector<NeuralFstSearch::End> NeuralFstSearch::endings(std::span<const Token> tokens) const {
    std::vector<End> out;
    const auto& lex = graph_.lexicon();
    for (const auto& t : tokens) {
        const auto word = lex.nodes[t.node].wordID;
        if (t.pending || !word || lex.packed.blocked(std::uint32_t(*word))) continue;
        for (const auto& edge : graph_.transitions(t.state, std::uint32_t(*word)))
            out.push_back({t, std::uint32_t(*word), edge.next, t.language + edge.logProbability});
    }
    return out;
}
void NeuralFstSearch::advance(std::uint8_t letter, std::optional<TouchOffset> tap) {
    const auto& lex = graph_.lexicon();
    std::vector<Token> next;
    for (const auto& t : beam_) {
        if (t.pending) {
            auto done = t; done.pending = 0;
            done.cost += substitutionCost(t.pending, letter, tap); next.push_back(std::move(done)); continue;
        }
        auto extra = t;
        extra.cost += insertionCostAt(letter, typed_.empty() ? 0 : std::uint8_t(typed_.back()), lex.nodes[t.node].label);
        next.push_back(std::move(extra));
        // A space key replaced by c/v/b/n/m consumes a touch without a lexicon letter.
        if (t.boundary && std::string_view("cvbnm").find(char(letter)) != std::string_view::npos) {
            auto space = t; space.boundary = false; space.cost += 0.72 - 1.1; next.push_back(std::move(space));
        }
        const auto n = lex.nodes[t.node];
        for (auto child = n.firstChild; child < n.firstChild + n.childCount; ++child) {
            const auto c = lex.nodes[child];
            auto sub = t; sub.node = child; sub.boundary = false;
            sub.cost += substitutionCost(c.label, letter, tap, typed_.empty()); next.push_back(std::move(sub));
            // Two-label channel arc for adjacent transposition. The pending input is
            // consumed on the next frame, so no unfinished transposition can emit a word.
            for (auto grand = c.firstChild; grand < c.firstChild + c.childCount; ++grand) if (lex.nodes[grand].label == letter && c.label != letter) {
                auto swap = t; swap.node = grand; swap.pending = c.label; swap.boundary = false;
                swap.cost += transpositionCost; next.push_back(std::move(swap));
            }
        }
    }
    beam_ = prune(std::move(next), true, letter);
    auto ends = endings(beam_);
    std::stable_sort(ends.begin(), ends.end(), [](const End& a, const End& b) {
        auto x = a.language - channelWeight * a.token.cost, y = b.language - channelWeight * b.token.cost;
        return x == y ? std::tie(a.next, a.word, a.token.prefix) < std::tie(b.next, b.word, b.token.prefix) : x > y;
    });
    expandedLastFrame_ = 0;
    for (const auto& e : ends) {
        if (e.language - channelWeight * e.token.cost <= nssExpansionThreshold) break;
        if (!graph_.expanded(e.next)) {
            graph_.extend(e.next);
            if (++expandedLastFrame_ == nssExpansionsPerFrame) break;
        }
    }
    for (const auto& e : ends) {
        // No zero-input word loops: boundaries are created only after consuming a frame.
        auto root = e.token; root.node = 0; root.state = e.next; root.language = e.language;
        root.prefix += std::string(lex.packed.word(e.word)) + ' '; root.cost += 1.1; root.boundary = true;
        beam_.push_back(std::move(root));
    }
    beam_ = prune(std::move(beam_), false, letter);
}
std::vector<RankedRow> NeuralFstSearch::decode(std::string_view typed, std::span<const std::optional<TouchOffset>> taps,
                                            const std::function<bool()>& cancelled) {
    if (!letters(typed)) { reset(); return {}; }
    bool reuse = revision_ == graph_.revision() && typed.starts_with(typed_);
    if (reuse) for (std::size_t k = 0; k < typed_.size(); ++k) {
        auto a = taps.size() == typed.size() ? taps[k] : std::nullopt, b = taps_[k];
        if (a.has_value() != b.has_value() || (a && (a->dx != b->dx || a->dy != b->dy))) { reuse = false; break; }
    }
    if (!reuse || beam_.empty()) { reset(); beam_ = prune({Token{}}, true, 0); }
    for (std::size_t k = typed_.size(); k < typed.size(); ++k) {
        if (cancelled && cancelled()) { reset(); return {}; }
        const auto tap = taps.size() == typed.size() ? taps[k] : std::nullopt;
        advance(std::uint8_t(typed[k]), tap); typed_ += typed[k]; taps_.push_back(tap);
    }
    auto ends = endings(beam_);
    complete_.clear();
    for (const auto& e : ends) complete_.insert(e.token.prefix + std::string(graph_.lexicon().packed.word(e.word)));
    std::unordered_map<std::string, RankedRow> full;
    for (const auto& e : ends) {
        auto phrase = e.token.prefix + std::string(graph_.lexicon().packed.word(e.word));
        RankedRow row{{phrase, e.token.cost, 0}, phrase, 0, e.language, e.language - channelWeight * e.token.cost, {}};
        auto [it, fresh] = full.emplace(phrase, row);
        if (!fresh && row.score > it->second.score) it->second = row;
    }
    completeRows_.clear();
    for (auto& [word, row] : full) { (void)word; completeRows_.push_back(std::move(row)); }
    // Completion is a final, non-mutating epsilon traversal. It uses neural/spatial
    // bounds, never a frequency-only completion cap, and cannot feed boundary expansion.
    auto completion = beam_;
    for (auto& t : completion) { t.boundary = false; t.upper = bound(t); }
    auto order = [&](const Token& a, const Token& b) {
        return a.upper == b.upper ? std::tie(a.prefix, a.state, a.node) > std::tie(b.prefix, b.state, b.node) : a.upper < b.upper;
    };
    std::priority_queue<Token, std::vector<Token>, decltype(order)> queue(order, std::move(completion));
    std::unordered_map<std::string, double> resultScores;
    auto remember = [&](const End& e) {
        auto key = e.token.prefix + std::string(graph_.lexicon().packed.word(e.word));
        auto score = e.language - channelWeight * e.token.cost;
        auto [it, fresh] = resultScores.emplace(std::move(key), score);
        if (!fresh) it->second = std::max(it->second, score);
    };
    for (const auto& e : ends) remember(e);
    double floor = queue.empty() ? negInf : queue.top().upper - options_.beam;
    auto tighten = [&] {
        if (resultScores.size() < 24) return;
        std::vector<double> scores; scores.reserve(resultScores.size());
        for (const auto& [word, score] : resultScores) { (void)word; scores.push_back(score); }
        std::nth_element(scores.begin(), scores.begin() + 23, scores.end(), std::greater<>());
        floor = std::max(floor, scores[23]);
    };
    tighten();
    std::unordered_set<std::string> visited;
    while (!queue.empty()) {
        if (cancelled && cancelled()) { reset(); return {}; }
        auto t = queue.top(); queue.pop(); if (t.upper < floor) break;
        if (t.pending || t.node == 0) continue;
        auto key = t.prefix + '\t' + std::to_string(t.state) + ':' + std::to_string(t.node);
        if (!visited.insert(std::move(key)).second) continue;
        for (const auto& e : endings(std::span<const Token>(&t, 1))) {
            remember(e); ends.push_back(e);
        }
        if (visited.size() % 16 == 0) tighten();
        const auto node = graph_.lexicon().nodes[t.node];
        for (auto c = node.firstChild; c < node.firstChild + node.childCount; ++c) {
            auto child = t; child.node = c; child.upper = bound(child);
            if (child.upper >= floor) queue.push(std::move(child));
        }
    }
    std::unordered_map<std::string, RankedRow> best;
    for (std::size_t i = 0; i < ends.size(); ++i) {
        const auto& e = ends[i];
        auto phrase = e.token.prefix + std::string(graph_.lexicon().packed.word(e.word));
        RankedRow row{{phrase, e.token.cost, 0}, phrase, 0, e.language, e.language - channelWeight * e.token.cost, {}};
        auto [it, fresh] = best.emplace(phrase, row); if (!fresh && row.score > it->second.score) it->second = std::move(row);
    }
    std::vector<RankedRow> out;
    for (auto& [word, row] : best) { (void)word; out.push_back(std::move(row)); }
    std::sort(out.begin(), out.end(), [](const auto& a, const auto& b) { return a.score == b.score ? a.key < b.key : a.score > b.score; });
    return out;
}
} // namespace kb
