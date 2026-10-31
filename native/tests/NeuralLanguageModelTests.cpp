// NSS word-model runtime vs the Python reference (tools/nss/nss/export.py goldens):
//   neural-language-model-tests model.nsslm model.goldens.json langdata.bin
// Also checks the ring buffer's step accounting and that malformed files are rejected.
#include "../DecoderCore/include/NeuralLanguageModel.hpp"
#include "../DecoderCore/include/PackedLexicon.hpp"
#include "MiniJson.hpp"
#include <cassert>
#include <cmath>
#include <fstream>
#include <iostream>
#include <sstream>
using namespace kb;

static std::vector<std::byte> bytes(const char* path) {
    std::ifstream in(path, std::ios::binary); std::stringstream s; s << in.rdbuf(); auto text = s.str();
    std::vector<std::byte> out(text.size()); std::memcpy(out.data(), text.data(), text.size()); return out;
}
static bool rejects(std::vector<std::byte> data) {
    try { NeuralWordModel::load(data); } catch (const std::exception&) { return true; }
    return false;
}
static double mass(const PackedLexicon& lexicon, std::string_view word) {
    bool emittable = !word.empty();
    for (char c : word) emittable = emittable && ((c >= 'a' && c <= 'z') || c == '\'');
    if (emittable) if (auto id = lexicon.wordID(word)) return double(lexicon.frequency(std::uint32_t(*id))) + 1;
    return 0.5;
}
int main(int argc, char** argv) {
    if (argc != 4) { std::cerr << "model.nsslm goldens.json langdata.bin\n"; return 2; }
    auto modelBytes = bytes(argv[1]), lexiconBytes = bytes(argv[3]);
    auto goldens = json::Parser(std::string(reinterpret_cast<const char*>(bytes(argv[2]).data()), bytes(argv[2]).size())).value();
    auto model = NeuralWordModel::load(modelBytes);
    PackedLexicon lexicon(lexiconBytes);
    const double tolerance = goldens["tolerance"].number();
    auto unknown = UnknownWordTable::build(*model, lexicon);
    assert(unknown.oovWords == std::size_t(goldens["oov_words"].number()));
    assert(std::abs(unknown.logOOVMass - std::log(goldens["oov_mass"].number())) < 1e-9);
    assert(std::abs(model->unknownLexiconShare() - goldens["unk_lexicon_share"].number()) < 1e-6);
    assert(std::abs(model->unknownLogCenter() - goldens["unk_log_center"].number()) < 1e-5);

    NeuralSearchSpace space(model, unknown);
    std::size_t checked = 0;
    double worst = 0;
    auto near = [&](double actual, double expected) { worst = std::max(worst, std::abs(actual - expected)); return std::abs(actual - expected) <= tolerance; };
    for (const auto& item : goldens["cases"].array()) {
        std::vector<std::string> context;
        for (const auto& word : item["context"].array()) context.push_back(word.text());
        std::vector<std::int32_t> ids;
        for (const auto& word : context) if (auto id = model->contextID(word); id >= 0) ids.push_back(id);
        const auto& expectedIDs = item["ids"].array();
        assert(ids.size() == expectedIDs.size());
        for (std::size_t i = 0; i < ids.size(); ++i) assert(ids[i] == std::int32_t(expectedIDs[i].number()));
        space.update(context);
        assert(near(space.unknownLogProbability(), item["unk"].number()));
        const auto& scores = std::get<std::shared_ptr<json::Object>>(item["scores"].data);
        for (const auto& [word, value] : *scores) { assert(near(space.logProbability(word, mass(lexicon, word)), value.number())); ++checked; }
        const auto& arcs = space.arcs(-15.0f, 100000);
        // Words near the threshold may cross it under float rounding.
        assert(std::abs(double(arcs.size()) - item["arc_count"].number()) <= 2);
        const auto& top = item["top"].array();
        for (std::size_t i = 0; i < top.size() && i < 5; ++i) {
            const auto& pair = top[i].array();
            assert(near(arcs[i].second, pair[1].number()));
            assert(model->word(arcs[i].first) == pair[0].text() || std::abs(arcs[i].second - arcs[i + 1].second) < 1e-4);
        }
        const auto& extend = std::get<std::shared_ptr<json::Object>>(item["extend"].data);
        for (const auto& [phrase, value] : *extend) {
            std::vector<std::string> words; std::istringstream split(phrase); for (std::string w; split >> w;) words.push_back(w);
            assert(near(space.sequence(words, [&](std::string_view w) { return mass(lexicon, w); }), value.number()));
            ++checked;
        }
    }

    // Ring accounting: one model step per committed word, none per keystroke or backspace.
    ContextRing ring(model, 6, 4);
    auto id = [&](const char* word) { return model->contextID(word); };
    std::vector<std::int32_t> a{id("i"), id("am")};
    assert(ring.sync(a).stepped == 2 && ring.sync(a).stepped == 0);
    std::vector<std::int32_t> b{id("i"), id("am"), id("going")};
    assert(ring.sync(b).stepped == 1 && ring.sync(a).stepped == 0 && ring.sync(b).stepped == 1);
    std::vector<std::int32_t> sentence{id("can"), id("you"), id("send"), id("me"), id("the"), id("photos")};
    for (std::size_t end = 1; end <= sentence.size(); ++end) {   // the host sends a sliding 4-word window
        auto from = end > 4 ? end - 4 : 0;
        assert(ring.sync(std::span(sentence).subspan(from, end - from)).stepped == 1);
    }
    { // The slid window's state equals reading the whole sentence from <bos>.
        std::vector<float> state(model->stateSize()), scratch(model->featureSize());
        model->step(model->sentenceStart(), state, state, scratch);
        for (auto word : sentence) model->step(word, state, state, scratch);
        for (std::size_t k = 0; k < scratch.size(); ++k) assert(std::abs(scratch[k] - ring.features()[k]) < 1e-6);
    }

    // Malformed models are rejected, never read out of bounds.
    assert(rejects({}));
    auto truncated = modelBytes; truncated.resize(truncated.size() / 2); assert(rejects(truncated));
    auto magic = modelBytes; magic[0] = std::byte{'X'}; assert(rejects(magic));
    auto version = modelBytes; version[4] = std::byte{9}; assert(rejects(version));
    for (std::size_t cut : {std::size_t(255), std::size_t(300), modelBytes.size() - 1}) {
        auto prefix = modelBytes; prefix.resize(cut); assert(rejects(prefix));
    }
    std::cout << "NSS word model matches " << checked << " reference scores (max |error| " << worst << ")\n";
}
