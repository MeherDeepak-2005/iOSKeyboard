#include "../DecoderCore/include/Engine.hpp"
#include <cassert>
#include <algorithm>
#include <cmath>
#include <fstream>
#include <iostream>
#include <sstream>
#include <cstring>
using namespace kb;
static std::vector<std::byte> read(const char* path) {
    std::ifstream in(path, std::ios::binary); assert(in);
    std::stringstream ss; ss << in.rdbuf(); auto s = ss.str();
    std::vector<std::byte> out(s.size()); std::memcpy(out.data(), s.data(), s.size()); return out;
}
int main(int argc, char** argv) {
    assert(argc == 3);
    auto bytes = read(argv[1]), pack = read(argv[2]);
    auto model = NeuralWordModel::load(bytes);
    auto lex = std::make_shared<PackedLexicon>(pack);
    auto indexed = std::make_shared<NeuralLexicon>(*lex);
    NeuralFst graph(model, indexed);
    std::vector<std::string> context{"can", "you"}; graph.update(context);
    std::vector<float> recurrent(model->stateSize()), features(model->featureSize()), probs(model->vocabularySize());
    model->step(model->sentenceStart(), recurrent, recurrent, features);
    for (const auto& w : context) model->step(model->contextID(w), recurrent, recurrent, features);
    model->wordLogProbabilities(features, probs);
    std::size_t expectedArcs = 0;
    for (std::size_t id = 4; id < model->vocabularySize(); ++id) {
        auto w = lex->wordID(model->word(std::int32_t(id)));
        if (!w || !std::isfinite(indexed->unigram[std::size_t(*w)])) continue;
        const auto edges = graph.transitions(0, std::uint32_t(*w));
        const auto fallback = probs[std::size_t(model->unknown())] + indexed->unigram[std::size_t(*w)];
        assert(std::abs(edges[0].logProbability - fallback) < 2e-6);
        const bool kept = probs[id] >= nssUpdateThreshold;
        assert(edges.size() == (kept ? 2u : 1u));
        if (kept) { ++expectedArcs; assert(std::abs(edges[1].logProbability - probs[id]) < 1e-6); }
        // Every prefix lookahead is an admissible bound on this word's graph score.
        auto node = indexed->terminal[std::size_t(*w)];
        for (;;) { assert(graph.lookahead(0, node) + 1e-6 >= graph.wordScore(0, std::uint32_t(*w))); if (!node) break; node = indexed->parent[node]; }
    }
    assert(graph.stats().arcs == expectedArcs); // no 1024-word cap
    auto word = lex->wordID("you"); assert(word);
    auto edges = graph.transitions(0, std::uint32_t(*word)); assert(edges.size() == 2);
    const auto destination = edges[1].next;
    assert(!graph.expanded(destination));
    // Before ExtendLM, the following word has contextless unigram scores (Fig.3).
    assert(std::abs(graph.wordScore(destination, std::uint32_t(*word)) - indexed->unigram[std::size_t(*word)]) < 1e-6);
    graph.extend(destination); assert(graph.stats().extensions == 1);
    graph.extend(destination); assert(graph.stats().extensions == 1);
    model->step(model->contextID("you"), recurrent, recurrent, features); model->wordLogProbabilities(features, probs);
    for (std::size_t id = 4; id < model->vocabularySize(); ++id) if (auto w = lex->wordID(model->word(std::int32_t(id)))) {
        if (!std::isfinite(indexed->unigram[std::size_t(*w)])) continue;
        auto extended = graph.transitions(destination, std::uint32_t(*w));
        assert(extended.size() == (probs[id] >= nssExtendThreshold ? 2u : 1u));
        if (extended.size() == 2) assert(std::abs(extended[1].logProbability - probs[id]) < 1e-6);
    }
    graph.update(context, true); assert(graph.stats().extensions == 0 && graph.stats().arcs == expectedArcs);
    NeuralFstSearch search(graph);
    std::vector<RankedRow> rows;
    for (auto prefix : {"h", "ho", "how", "howm", "howma", "howman", "howmany"}) {
        rows = search.decode(prefix, {}); assert(search.expandedLastFrame() <= 1);
    }
    assert(!rows.empty());
    const auto incremental = rows;
    graph.update(context, true);
    NeuralFstSearch freshSearch(graph);
    const auto oneShot = freshSearch.decode("howmany", {});
    assert(incremental.size() == oneShot.size());
    for (std::size_t i = 0; i < oneShot.size(); ++i) {
        assert(incremental[i].key == oneShot[i].key);
        assert(std::abs(incremental[i].score - oneShot[i].score) < 1e-6);
    }
    if (model->vocabularySize() > 1000) {
        graph.update(context, true);
        NeuralFstSearch misspelled(graph);
        auto alternatives = misspelled.decode("howmny", {});
        assert(std::any_of(alternatives.begin(), alternatives.end(), [](const auto& row) { return row.key == "how many"; }));
    }
    for (const auto& row : rows) assert(std::isfinite(row.score));
    assert(search.decode("hello", {}, [] { return true; }).empty());
    assert(search.decode("é", {}).empty());
    // Field identity is part of cache invalidation, even when visible windows match.
    auto engine = std::make_shared<Engine>(lex, EngineOptions{}, nullptr, model);
    auto state = engine->createState(); auto session = engine->createSession();
    DecodeInput in; in.modelTier = "nss"; in.word = in.normalized = "you";
    std::vector<std::string> sentence{"i", "think", "that", "you", "can", "send", "me", "the", "new", "book"};
    for (std::size_t end = 1; end <= sentence.size(); ++end) {
        const auto from = end > 8 ? end - 8 : 0;
        in.context.assign(sentence.begin() + std::ptrdiff_t(from), sentence.begin() + std::ptrdiff_t(end));
        in.identity.fieldRevision = 1; in.identity.wordSessionID = end;
        session->decode(in, state->view());
    }
    in.identity.fieldRevision = 2;
    auto reset = session->decode(in, state->view());
    auto fresh = engine->createSession()->decode(in, state->view());
    assert(reset.suggestions == fresh.suggestions && reset.candidates.size() == fresh.candidates.size());
    for (std::size_t i = 0; i < reset.candidates.size(); ++i) assert(std::abs(reset.candidates[i].ranked.score - fresh.candidates[i].ranked.score) < 1e-6);
    std::cout << "NSS graph: " << expectedArcs << " untruncated initial arcs; direct/fallback, ExtendLM, lookahead, pruning, cancellation and field reset passed\n";
}
