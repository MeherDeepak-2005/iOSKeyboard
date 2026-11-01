// Raw decoding: the n-gram as a search graph (NgramFst) must reproduce the production
// LanguageModel exactly, NeuralFst's exact scores must equal the model's distribution
// (with <unk> shared outside the vocabulary), both graphs' lookaheads must bound their
// word scores, best() must equal a brute-force top k, and the raw decision must be the
// plain argmax.
//   raw-decoder-tests model.nsslm langdata.bin
#include "../DecoderCore/include/Engine.hpp"
#include <cassert>
#include <cmath>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>
using namespace kb;
static std::vector<std::byte> read(const char* path) {
    std::ifstream in(path, std::ios::binary); assert(in);
    std::stringstream ss; ss << in.rdbuf(); auto s = ss.str();
    std::vector<std::byte> out(s.size()); std::memcpy(out.data(), s.data(), s.size()); return out;
}
static std::vector<std::pair<std::uint32_t, double>> bruteForce(const SearchGraph& graph, const NeuralLexicon& lex, std::size_t count) {
    std::vector<std::pair<std::uint32_t, double>> all;
    for (std::uint32_t w = 0; w < lex.unigram.size(); ++w) if (std::isfinite(lex.unigram[w]) && lex.terminal[w] != UINT32_MAX) all.emplace_back(w, graph.wordScore(0, w));
    std::partial_sort(all.begin(), all.begin() + std::ptrdiff_t(count), all.end(),
        [](const auto& a, const auto& b) { return a.second == b.second ? a.first < b.first : a.second > b.second; });
    all.resize(count); return all;
}
static void admissible(const SearchGraph& graph, const NeuralLexicon& lex, std::uint32_t state) {
    for (std::uint32_t w = 0; w < lex.unigram.size(); w += 13) {
        if (!std::isfinite(lex.unigram[w]) || lex.terminal[w] == UINT32_MAX) continue;
        const auto score = graph.wordScore(state, w);
        for (auto node = lex.terminal[w];;) { assert(graph.lookahead(state, node) + 1e-5 >= score); if (!node) break; node = lex.parent[node]; }
    }
}
int main(int argc, char** argv) {
    assert(argc == 3);
    auto bytes = read(argv[1]), pack = read(argv[2]);
    auto model = NeuralWordModel::load(bytes);
    auto packed = std::make_shared<PackedLexicon>(pack);
    auto lex = std::make_shared<NeuralLexicon>(*packed);
    LanguageModel ngram(packed.get(), Smoothing::wittenBell);
    const PersonalCounts none;
    const GenerationLexicon view{packed.get()};
    std::vector<std::string> words; std::vector<std::uint32_t> ids;
    for (std::uint32_t w = 0; w < packed->wordCount(); ++w) if (std::isfinite(lex->unigram[w])) { words.emplace_back(packed->word(w)); ids.push_back(w); }

    // 1. NgramFst = LanguageModel, for every emittable word, in contexts of 0-2 known words.
    NgramFst graph(*packed, lex);
    std::size_t checked = 0;
    for (std::vector<std::string> context : std::vector<std::vector<std::string>>{{}, {"of"}, {"i", "am"}, {"the", "united"}, {"xqzzy"}, {"xqzzy", "going"}, {"you", "xqzzy"}}) {
        graph.update(context, true);
        auto expected = ngram.scores(words, context, none, view);
        // The lexicon's unigram table is float: agreement to float precision (~1e-6 at -20).
        for (std::size_t i = 0; i < words.size(); ++i) { assert(std::abs(graph.wordScore(0, ids[i]) - expected[i]) < 2e-6); ++checked; }
        admissible(graph, *lex, 0);
        auto best = graph.best(0, 5), brute = bruteForce(graph, *lex, 5);
        for (std::size_t i = 0; i < 5; ++i) assert(best[i].first == brute[i].first && std::abs(best[i].second - brute[i].second) < 1e-9);
    }
    // A multiword path keeps n-gram context: "of" then "the" scores P(the | ..., of).
    std::vector<std::string> context{"one"};
    graph.update(context, true);
    const auto of = std::uint32_t(*packed->wordID("of")), the = std::uint32_t(*packed->wordID("the"));
    const auto next = graph.transitions(0, of).front().next;
    std::vector<std::string> extended{"one", "of"}, target{"the"};
    assert(!graph.expanded(next));   // contextless until expanded, like NeuralFst (Fig. 3)
    assert(std::abs(graph.wordScore(next, the) - ngram.scores(target, {}, none, view)[0]) < 2e-6);
    graph.extend(next);
    assert(std::abs(graph.wordScore(next, the) - ngram.scores(target, extended, none, view)[0]) < 2e-6);
    admissible(graph, *lex, next);

    // 2. NeuralFst::best equals a brute-force top k over both paths.
    NeuralFst neural(model, lex);
    for (std::vector<std::string> c : std::vector<std::vector<std::string>>{{}, {"can", "you"}, {"thank"}}) {
        neural.update(c, true);
        auto best = neural.best(0, 5), brute = bruteForce(neural, *lex, 5);
        for (std::size_t i = 0; i < 5; ++i) assert(best[i].first == brute[i].first && std::abs(best[i].second - brute[i].second) < 1e-6);
    }

    // 3. Exact scores: each vocabulary word scores its model log-probability, also below the
    // arc threshold; a lexicon word outside the vocabulary scores
    // P(<unk>) * share * u(w) / (sum of u outside the vocabulary), u = frequency + 1.
    NeuralFst exact(model, lex, NeuralFst::Options{true});
    std::vector<std::int32_t> inside(lex->unigram.size(), -1);
    for (std::int32_t id = 4; id < std::int32_t(model->vocabularySize()); ++id)
        if (auto w = packed->wordID(model->word(id))) inside[std::size_t(*w)] = id;
    double outsideMass = 0;
    for (std::uint32_t w = 0; w < lex->unigram.size(); ++w) if (std::isfinite(lex->unigram[w]) && inside[w] < 0) outsideMass += double(packed->frequency(w)) + 1;
    const double share = model->unknownLexiconShare();
    std::size_t exactChecked = 0, belowThreshold = 0;
    for (std::vector<std::string> c : std::vector<std::vector<std::string>>{{}, {"can", "you"}, {"i", "live", "in"}}) {
        exact.update(c, true); neural.update(c, true);
        ContextRing ring(model);
        std::vector<std::int32_t> ids;
        for (const auto& word : c) if (auto id = model->contextID(word); id >= 0) ids.push_back(id);
        ring.sync(ids);
        std::vector<float> p(model->vocabularySize());
        model->wordLogProbabilities(ring.features(), p);
        const double unk = p[std::size_t(model->unknown())];
        double total = 0, expected = std::exp(unk) * share, published = 0;
        for (std::uint32_t w = 0; w < lex->unigram.size(); ++w) {
            if (!std::isfinite(lex->unigram[w]) || lex->terminal[w] == UINT32_MAX) continue;
            const double score = exact.wordScore(0, w);
            if (inside[w] >= 0) {
                const double direct = p[std::size_t(inside[w])];
                assert(std::abs(score - direct) < 1e-6);
                expected += std::exp(direct); belowThreshold += direct < nssUpdateThreshold;
            } else {
                assert(std::abs(score - (unk + std::log(share) + std::log((double(packed->frequency(w)) + 1) / outsideMass))) < 1e-5);
            }
            total += std::exp(score); published += std::exp(neural.wordScore(0, w)); ++exactChecked;
        }
        // The lexicon gets the vocabulary words' mass plus the lexicon's share of <unk>.
        assert(std::abs(total - expected) < 1e-4);
        std::cout << "  context \"";
        for (std::size_t i = 0; i < c.size(); ++i) std::cout << (i ? " " : "") << c[i];
        std::cout << "\": lexicon mass exact " << total << ", published graph " << published << ", P(<unk>) " << std::exp(unk) << "\n";
        admissible(exact, *lex, 0);
        auto best = exact.best(0, 5), brute = bruteForce(exact, *lex, 5);
        for (std::size_t i = 0; i < 5; ++i) assert(best[i].first == brute[i].first && std::abs(best[i].second - brute[i].second) < 1e-6);
    }
    assert(belowThreshold > 0);
    // ExtendLM states score exactly too: "one of" then "the".
    exact.update(context, true);
    const auto ofState = exact.transitions(0, of);
    assert(ofState.size() == 1 && ofState.front().next > 1);   // above the threshold: its own state, no fallback path
    exact.extend(ofState.front().next);
    {
        ContextRing ring(model);
        std::vector<std::int32_t> ids{model->contextID("one"), model->contextID("of")};
        ring.sync(ids);
        std::vector<float> p(model->vocabularySize());
        model->wordLogProbabilities(ring.features(), p);
        assert(std::abs(exact.wordScore(ofState.front().next, the) - p[std::size_t(inside[the])]) < 1e-5);
    }
    admissible(exact, *lex, ofState.front().next);

    // The floor variant: a vocabulary word scores the better of its model probability and the
    // published fallback P(<unk>) x unigram; words outside the vocabulary as without it.
    NeuralFst floored(model, lex, NeuralFst::Options{true, true});
    for (std::vector<std::string> c : std::vector<std::vector<std::string>>{{"will"}, {"i", "live", "in"}}) {
        floored.update(c, true); exact.update(c, true);
        ContextRing ring(model);
        std::vector<std::int32_t> ids;
        for (const auto& word : c) if (auto id = model->contextID(word); id >= 0) ids.push_back(id);
        ring.sync(ids);
        std::vector<float> p(model->vocabularySize());
        model->wordLogProbabilities(ring.features(), p);
        const double unk = p[std::size_t(model->unknown())];
        std::size_t lifted = 0;
        for (std::uint32_t w = 0; w < lex->unigram.size(); ++w) {
            if (!std::isfinite(lex->unigram[w]) || lex->terminal[w] == UINT32_MAX) continue;
            const double score = floored.wordScore(0, w);
            if (inside[w] >= 0) {
                assert(std::abs(score - std::max(double(p[std::size_t(inside[w])]), unk + lex->unigram[w])) < 1e-5);
                lifted += unk + lex->unigram[w] > p[std::size_t(inside[w])];
            } else assert(std::abs(score - exact.wordScore(0, w)) < 1e-9);
        }
        assert(lifted > 0);
        admissible(floored, *lex, 0);
        auto best = floored.best(0, 5), brute = bruteForce(floored, *lex, 5);
        for (std::size_t i = 0; i < 5; ++i) assert(best[i].first == brute[i].first && std::abs(best[i].second - brute[i].second) < 1e-6);
    }

    // Flattened unknown-word frequencies: inside the <unk> share a word outside the vocabulary
    // weighs u^a (a = 0: 1 + ln u), still a distribution over those words; typed text outside
    // the lexicon gets the rest of <unk>, half a count on the same scale.
    for (double a : {0.5, 0.0}) {
        NeuralFst flat(model, lex, NeuralFst::Options{true, true, a});
        auto scale = [&](double u) { return a > 0 ? std::pow(u, a) : 1 + std::log(u); };
        double flatMass = 0;
        for (std::uint32_t w = 0; w < lex->unigram.size(); ++w) if (std::isfinite(lex->unigram[w]) && inside[w] < 0) flatMass += scale(double(packed->frequency(w)) + 1);
        std::vector<std::string> c{"i", "was", "talking", "to"};
        flat.update(c, true);
        ContextRing ring(model);
        std::vector<std::int32_t> ids;
        for (const auto& word : c) if (auto id = model->contextID(word); id >= 0) ids.push_back(id);
        ring.sync(ids);
        std::vector<float> p(model->vocabularySize());
        model->wordLogProbabilities(ring.features(), p);
        const double unk = p[std::size_t(model->unknown())];
        double outside = 0;
        for (std::uint32_t w = 0; w < lex->unigram.size(); ++w) {
            if (!std::isfinite(lex->unigram[w]) || lex->terminal[w] == UINT32_MAX || inside[w] >= 0) continue;
            const double expected = unk + std::log(share) + std::log(scale(double(packed->frequency(w)) + 1) / flatMass);
            assert(std::abs(flat.wordScore(0, w) - expected) < 1e-5);
            outside += std::exp(flat.wordScore(0, w) - unk - std::log(share));
        }
        assert(std::abs(outside - 1) < 1e-3);   // every outside word has a trie entry here
        const double half = a > 0 ? std::pow(0.5, a) : 1.0;
        assert(std::abs(flat.typedUnknown() - (unk + std::log(1 - share) + std::log(half / flatMass))) < 1e-9);
        admissible(flat, *lex, 0);
        auto best = flat.best(0, 5), brute = bruteForce(flat, *lex, 5);
        for (std::size_t i = 0; i < 5; ++i) assert(best[i].first == brute[i].first && std::abs(best[i].second - brute[i].second) < 1e-6);
    }
    assert(!std::isfinite(neural.typedUnknown()));   // the published graph has no such score

    // 4. Raw decoding: deterministic, and the commit is the plain argmax against the typed text.
    for (int variant = 0; variant < 4; ++variant) {
    EngineOptions options; options.raw = true; options.nssExact = variant != 2; options.nssUnigramFloor = variant == 1 || variant == 3;
    if (variant == 3) { options.nssUnknownExponent = 0.5; options.nssTypedUnknown = true; }
    auto engine = std::make_shared<Engine>(packed, options, nullptr, model);
    auto state = engine->createState();
    for (const char* tier : {"ngram", "nss"}) {
        for (const char* typed : {"teh", "recieve", "howmny", "hello", "ahmet"}) {
            DecodeInput in; in.modelTier = tier; in.word = in.normalized = typed;
            in.context = {"i", "will", "send", "you"}; in.identity.fieldRevision = 1; in.identity.wordSessionID = 7;
            auto one = engine->createSession()->decode(in, state->view()), two = engine->createSession()->decode(in, state->view());
            assert(one.status == EngineStatus::ok && one.suggestions == two.suggestions && one.correction.word == two.correction.word);
            const auto typedRow = std::find_if(one.candidates.begin(), one.candidates.end(), [&](const auto& c) { return c.ranked.key == typed; });
            if (one.correction.word) {
                assert(one.correction.margin > 0 && one.suggestions.front() == *one.correction.word);
                for (const auto& c : one.candidates) if (c.ranked.key == *one.correction.word) assert(c.typedMargin > 0);
            } else if (typedRow != one.candidates.end()) {
                for (const auto& c : one.candidates) if (c.ranked.key.size() == std::strlen(typed) && c.ranked.channel.cost > 0) assert(c.typedMargin <= 0 || c.ranked.key.find(' ') != std::string::npos);
            }
        }
        // A word the user kept (undid its correction) is never corrected again.
        DecodeInput kept; kept.modelTier = tier; kept.word = kept.normalized = "teh"; kept.context = {"i", "will", "send", "you"};
        kept.identity.fieldRevision = 3; kept.identity.wordSessionID = 9;
        assert(engine->createSession()->decode(kept, state->view()).correction.word);
        kept.kept = true;
        assert(!engine->createSession()->decode(kept, state->view()).correction.word);
        DecodeInput next; next.modelTier = tier; next.context = {"thank"}; next.identity.fieldRevision = 2;
        auto predicted = engine->createSession()->decode(next, state->view());
        assert(predicted.suggestions.size() == 3);
    }
    }
    std::cout << "Raw decoding: n-gram graph matches LanguageModel on " << checked << " scores; NSS exact scores match the model on "
              << exactChecked << " (" << belowThreshold << " vocabulary scores below e^-15); lookahead bounds, best(), argmax commit passed\n";
}
