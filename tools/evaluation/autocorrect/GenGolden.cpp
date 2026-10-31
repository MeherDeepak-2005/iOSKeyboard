#include "Engine.hpp"
#include "EngineWire.hpp"
#include "Safety.hpp"
#include "MiniJson.hpp"
#include <cstdio>
#include <cctype>
#include <cmath>
#include <sstream>
#include <cassert>
#include <fstream>
#include <iostream>
#include <iterator>
using namespace kb;
static DecodeInput input(std::string word, std::uint64_t generation = 1) {
    DecodeInput in; in.word = in.normalized = std::move(word);
    in.identity = {1,generation,1,generation,1,0,0};
    for (std::size_t i=0;i<=in.word.size();++i) in.characterOffsets.push_back(i);
    in.letterFlags.assign(in.word.size(),1); return in;
}
static std::string slurp(const std::string& path) { std::ifstream in(path, std::ios::binary); assert(in); std::stringstream out; out << in.rdbuf(); return out.str(); }
// Host stand-in for the adapters' OS segmentation. Exact for the fixture inputs and
// the pack's 106 non-ASCII forms, which are precomposed: one code point per character
// (U+0300..U+036F combining marks join the preceding character).
static std::vector<std::size_t> boundaries(std::string_view text) {
    std::vector<std::size_t> out{0};
    for (std::size_t i = 0; i < text.size();) {
        auto c = static_cast<unsigned char>(text[i]); std::size_t n = c < 0x80 ? 1 : c < 0xe0 ? 2 : c < 0xf0 ? 3 : 4;
        bool combining = n == 2 && (c == 0xcc || (c == 0xcd && static_cast<unsigned char>(text[i + 1]) < 0xb0));
        i += n; if (combining && out.size() > 1) out.back() = i; else out.push_back(i);
    }
    return out;
}
static std::string lower(std::string text) { for (auto& c : text) if (static_cast<unsigned char>(c) < 0x80) c = char(std::tolower(static_cast<unsigned char>(c))); return text; }
static DecodeInput fixtureInput(const std::string& typed, const json::Value& context, std::uint64_t n) {
    DecodeInput in; in.word = typed; in.normalized = lower(typed); in.identity = {1, n, n, n, 1, 0, 0};
    for (const auto& word : context.array()) in.context.push_back(lower(word.text()));
    in.characterOffsets = boundaries(in.normalized); in.letterFlags.assign(in.normalized.size(), 0);
    for (std::size_t k = 1; k < in.characterOffsets.size(); ++k) {
        auto at = in.characterOffsets[k - 1]; auto c = static_cast<unsigned char>(in.normalized[at]);
        if (c >= 0x80 || std::isalpha(c)) std::fill(in.letterFlags.begin() + long(at), in.letterFlags.begin() + long(in.characterOffsets[k]), 1);
    }
    return in;
}
static const char* sourceName(CandidateSource source) {
    static const char* names[] = {"typed", "fuzzyLexicon", "completion", "contextInjection", "broadRecovery", "splitCorrection"};
    return names[static_cast<int>(source)];
}

int main(int, char** argv) {
    std::string root = argv[2], fixtures = argv[3];
    std::ifstream stream(argv[1], std::ios::binary); std::vector<char> chars((std::istreambuf_iterator<char>(stream)), {});
    auto backing = std::make_shared<std::vector<char>>(std::move(chars));
    auto reader = std::shared_ptr<const PackedLexicon>(new PackedLexicon({reinterpret_cast<const std::byte*>(backing->data()), backing->size()}), [backing](const PackedLexicon* p) { delete p; });
    std::vector<PackedLexicon::TextMetadata> metadata;
    for (auto id : reader->textMetadataIDs()) {
        auto text = reader->word(id); auto marks = boundaries(text);
        auto ascii = [&](std::size_t from, std::size_t to) { return to - from == 1 && static_cast<unsigned char>(text[from]) < 0x80 ? std::optional(std::uint8_t(text[from])) : std::nullopt; };
        metadata.push_back({id, marks.size() - 1, ascii(marks[0], marks[1]), ascii(marks[marks.size() - 2], marks.back())});
    }
    reader->installTextMetadata(metadata); reader->warmAnchors();
    auto engine = std::make_shared<Engine>(reader); auto state = engine->createState();
    state->setSafety(parseSafetyPenalties(slurp(root + "/keyboard/safety.kbguard")));
    auto session = engine->createSession();
    auto corpus = json::parse(slurp(fixtures + "/corpus.json"));
    auto q = [](const std::string& s) { std::string r = "\""; for (char c : s) { if (c == '"' || c == '\\') r += '\\'; r += c; } return r + "\""; };
    for (std::size_t i = 0; i < corpus.array().size(); ++i) {
        const auto& fixture = corpus.array()[i]; auto view = state->view();
        auto r = session->decode(fixtureInput(fixture["typed"].text(), fixture["context"], i + 1), view);
        std::printf("{\"id\":%s,\"correction\":%s,\"suggestions\":[", q(fixture["id"].text()).c_str(), r.correction.word ? q(*r.correction.word).c_str() : "null");
        for (std::size_t k = 0; k < r.suggestions.size(); ++k) std::printf("%s%s", k ? "," : "", q(r.suggestions[k]).c_str());
        std::printf("],\"candidates\":[");
        for (std::size_t k = 0; k < r.candidates.size(); ++k) { const auto& c = r.candidates[k];
            std::printf("%s{\"word\":%s,\"source\":\"%s\",\"cost\":%.17g,\"score\":%.17g}", k ? "," : "", q(c.ranked.channel.word).c_str(), sourceName(c.source), c.ranked.channel.cost, c.ranked.score); }
        std::printf("]}\n");
    }
}
