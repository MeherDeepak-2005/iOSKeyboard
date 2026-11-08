#include "../DecoderCore/include/Engine.hpp"
#include "../DecoderCore/include/EngineWire.hpp"
#include "../DecoderCore/include/Safety.hpp"
#include "../DecoderCore/include/SpatialModel.hpp"
#include "MiniJson.hpp"
#include <algorithm>
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
// Same setup as native/android/SharedEngineJni.cpp: EngineState owns safety/vocabulary,
// default EngineOptions, metadata installed for non-ASCII forms. Goldens are written by
// the production iOS engine (KBSharedEngine), so this is the host half of iOS/Android parity.
static void replayGoldens(const std::shared_ptr<const PackedLexicon>& reader, const std::string& root, const std::string& fixtures) {
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
    auto corpus = json::parse(slurp(fixtures + "/corpus.json")), golden = json::parse(slurp(fixtures + "/golden-corpus.json"));
    assert(corpus.array().size() == 132 && golden.array().size() == 132);
    std::size_t mismatches = 0;
    for (std::size_t i = 0; i < corpus.array().size(); ++i) {
        const auto& fixture = corpus.array()[i]; const auto& expected = golden.array()[i];
        assert(fixture["id"].text() == expected["id"].text());
        auto view = state->view();
        auto actual = session->decode(fixtureInput(fixture["typed"].text(), fixture["context"], i + 1), view);
        std::vector<std::string> suggestions; for (const auto& s : expected["suggestions"].array()) suggestions.push_back(s.text());
        bool same = actual.status == EngineStatus::ok && actual.suggestions == suggestions
            && (expected["correction"].null() ? !actual.correction.word : actual.correction.word == expected["correction"].text())
            && actual.candidates.size() == expected["candidates"].array().size();
        for (std::size_t j = 0; same && j < actual.candidates.size(); ++j) {
            const auto& a = actual.candidates[j]; const auto& b = expected["candidates"].array()[j];
            same = a.ranked.channel.word == b["word"].text() && b["source"].text() == sourceName(a.source)
                && std::abs(a.ranked.channel.cost - b["cost"].number()) <= 1e-9 && std::abs(a.ranked.score - b["score"].number()) <= 1e-9;
        }
        if (!same) { ++mismatches; std::cerr << "golden decode mismatch: " << fixture["id"].text() << " '" << fixture["typed"].text() << "'\n"; }
    }
    auto glides = json::parse(slurp(fixtures + "/glides.json")), glideGolden = json::parse(slurp(fixtures + "/golden-glide.json"));
    assert(glides.array().size() == 60 && glideGolden.array().size() == 60);
    GlideLayout layout{{}, 1, 1}; const char* rows[] = {"qwertyuiop", "asdfghjkl", "zxcvbnm"}; const double shifts[] = {0, 0.5, 1.5};
    for (int y = 0; y < 3; ++y) for (int x = 0; rows[y][x]; ++x) layout.centers.emplace_back(std::uint8_t(rows[y][x]), Point{x + shifts[y], double(y)});
    for (std::size_t i = 0; i < glides.array().size(); ++i) {
        const auto& fixture = glides.array()[i]; std::vector<std::string> context;
        for (const auto& word : fixture["context"].array()) context.push_back(lower(word.text()));
        std::vector<Point> path; for (const auto& point : fixture["points"].array()) path.push_back({point.array()[0].number(), point.array()[1].number()});
        session->beginGlide(context);
        auto view = state->view(); auto dynamic = state->dynamicGlideWords();
        auto ranked = session->updateGlide(path, layout, view, dynamic); session->endGlide();
        std::vector<std::string> actual; for (std::size_t k = 0; k < ranked.size() && k < 4; ++k) actual.push_back(ranked[k].channel.word);
        std::vector<std::string> expected; for (const auto& s : glideGolden.array()[i]["suggestions"].array()) expected.push_back(s.text());
        if (actual != expected) { ++mismatches; std::cerr << "golden glide mismatch: " << fixture["id"].text() << "\n"; }
    }
    assert(mismatches == 0);
    std::cout << "Shared engine matches 132 iOS decode goldens and 60 iOS streaming Glide goldens\n";
}
// The bundled safety pack through kb::SafetyLexicon: the same cases as the Swift
// KBSafetyLexicon test, on input the platform has already normalized.
static void testSafety(const std::string& root) {
    const auto blob = slurp(root + "/keyboard/safety.kbguard");
    SafetyLexicon safety(blob);
    assert(safety.size() == 997);
    for (const char* word : {"fuck", "5h1t", "2 girls 1 cup", "xxx", "దెంగు"}) assert(safety.blocked(word));
    assert(safety.language("దెంగు") == SafetyLanguage::telugu);
    assert(safety.action("కుక్క") == SafetyAction::demote && safety.penalty("కుక్క") == 4 && !safety.blocked("కుక్క"));
    for (const char* word : {"class", "meher", "telangana", "prolly", "kukka", ""}) assert(safety.action(word) == SafetyAction::allow && safety.penalty(word) == 0);
    assert(!safety.blocked("FUCK"));   // case folding belongs to the platform boundary
    auto table = safety.penalties(); assert(table == parseSafetyPenalties(blob) && table.size() == 997);
    for (const auto& [word, value] : table) assert(safety.penalty(word) == value);
    auto blocked = safety.blockedTerms(); assert(blocked.size() == 991 && std::is_sorted(blocked.begin(), blocked.end()));
    for (std::size_t n = 0; n < blob.size(); ++n) { bool rejected = false; try { SafetyLexicon cut(std::string_view(blob).substr(0, n)); } catch (const std::invalid_argument&) { rejected = true; } assert(rejected); }
    auto expectRejected = [](std::string bytes) { bool rejected = false; try { SafetyLexicon bad(bytes); } catch (const std::invalid_argument&) { rejected = true; } assert(rejected); };
    { auto bad = blob; std::swap_ranges(bad.begin() + 24, bad.begin() + 32, bad.begin() + 48); expectRejected(bad); }   // hash order
    { auto bad = blob; bad[24] = char(bad[24] ^ 1); expectRejected(bad); }                                            // hash != FNV-1a(term)
    std::cout << "Safety lexicon: 997 entries, lookups, penalties, ordering/hash validation and truncation passed\n";
}
// Generation-time exclusion: after setSafety installs the blocked bitset, no generation
// source emits a blocked word; only the typed text itself stays available.
static void testBlockedGeneration(const std::shared_ptr<const PackedLexicon>& reader, const std::string& root) {
    const auto blob = slurp(root + "/keyboard/safety.kbguard");
    SafetyLexicon safety(blob);
    auto engine = std::make_shared<Engine>(reader); auto state = engine->createState();
    state->setSafety(parseSafetyPenalties(blob));   // installs the bitset (once per reader)
    std::size_t inDictionary = 0;
    for (const auto& term : safety.blockedTerms()) if (auto id = reader->wordID(term)) { ++inDictionary; assert(reader->blocked(std::uint32_t(*id))); }
    assert(inDictionary == 279 && reader->blockedCount() == 279);
    auto isBlockedWord = [&](const std::string& word) { auto id = reader->wordID(word); return id && reader->blocked(std::uint32_t(*id)); };
    for (const auto& term : safety.blockedTerms()) if (reader->wordID(term)) {
        for (const auto& hit : reader->search(term, 2.8)) assert(!isBlockedWord(hit.word));
        for (const auto& c : reader->completions(term, 24)) assert(c.word == term || !isBlockedWord(c.word));
    }
    for (char first = 'a'; first <= 'z'; ++first) {
        for (const auto& c : reader->completions(std::string(1, first), 200)) assert(!isBlockedWord(c.word));
        if (auto seeds = reader->incrementalSeeds(std::uint8_t(first), {}, 1000000)) for (const auto& seed : seeds->seeds()) assert(!isBlockedWord(std::string(seed.word)));
    }
    auto session = engine->createSession(); auto view = state->view();
    assert(view.penalties && view.penalties->empty());   // no in-dictionary demote terms: no per-row lookups
    for (std::uint32_t id = 0; id < 400; ++id) {
        std::vector<std::string> context{std::string(reader->word(id))};
        for (const auto& word : session->nextWords(context, view, 24)) assert(!isBlockedWord(word));
    }
    // The typed literal is never censored: "hoe" (blocked) keeps its exact match and completion.
    auto pools = generateCandidates(view.lexicon, "hoe", {}, {}, std::nullopt, std::nullopt, false);
    assert(std::count_if(pools.close.begin(), pools.close.end(), [](const auto& c) { return c.word == "hoe" && c.cost == 0; }) == 1);
    for (const auto& pool : {pools.close, pools.broad, pools.injected, pools.completions, pools.displayCorrections})
        for (const auto& c : pool) assert(c.word == "hoe" || !isBlockedWord(c.word));
    // A typo aimed at a blocked word is left alone, not recovered into an unrelated word.
    assert(reader->blockedTrie());
    for (const char* typo : {"biitch", "masterbation", "bicthes"}) {
        auto decoded = session->decode(input(typo), view);
        assert(!decoded.correction.word || !isBlockedWord(*decoded.correction.word));
        for (const auto& s : decoded.suggestions) assert(s == typo || !isBlockedWord(s));
    }
    assert(!session->decode(input("biitch"), view).correction.word && !session->decode(input("masterbation"), view).correction.word);
    std::cout << "Blocked generation: 279 dictionary words excluded from search, completions, seeds and successors; typed literal kept; blocked-aimed typos left alone\n";
}
// The app installs its layout pack's grid; a bad grid is refused and the current one kept.
static void testInstalledGrid() {
    using Rows = std::array<std::string_view, 3>; using Offsets = std::array<double, 3>;
    const Rows qwerty{"qwertyuiop", "asdfghjkl", "zxcvbnm"}; const Offsets offsets{0.0, 0.5, 1.5};
    assert(gridLetters() == "qwertyuiopasdfghjklzxcvbnm");
    assert(installGrid(qwerty, offsets) && grid('a')->x == 0.5 && grid('z')->x == 1.5);
    assert(!installGrid(Rows{"qwertyuiop", "asdfghjkl", "zxcvbn"}, offsets));          // 25 letters
    assert(!installGrid(Rows{"qwertyuiop", "asdfghjkl", "zxcvbnmq"}, offsets));        // repeated q
    assert(!installGrid(Rows{"qwertyuiop", "asdfghjkl", "zxcvbnM"}, offsets));         // not lowercase
    assert(!installGrid(qwerty, std::array<double, 2>{0.0, 0.5}));
    assert(gridLetters() == "qwertyuiopasdfghjklzxcvbnm" && grid('m')->x == 7.5);
    const Rows azerty{"azertyuiop", "qsdfghjklm", "wxcvbn"};
    assert(installGrid(azerty, offsets) && grid('q')->y == 1 && grid('m')->x == 9.5 && !neighbouringKeys('q', 'w'));
    assert(installGrid(qwerty, offsets) && grid('q')->x == 0 && grid('q')->y == 0 && neighbouringKeys('q', 'w'));
}
int main(int argc,char**argv) {
    assert(argc == 2 || argc == 4);
    testInstalledGrid();
    Personalization user; user.reset(4);
    user.learn(std::vector<std::string>{"the","old"}, "word"); auto old=user.counts();
    user.learn(std::vector<std::string>{"a","new"}, "word");
    assert(old->uni("word")==1 && user.counts()->uni("word")==2);
    user.demote("word"); assert(user.counts()->uni("word")==1 && user.counts()->bi("new").empty() && user.counts()->tri("a new").empty());
    assert(user.counts()->bi("old").size()==1);
    user.confirm("word");assert(user.kept("word") && user.confirmations("word")==1);user.releaseKeep("word");assert(!user.kept("word"));
    auto serialized=encodePersonalization(user.exportSnapshot());auto restored=decodePersonalization(serialized);
    assert(restored.epoch==4 && restored.counts.uni("word")==1 && restored.confirmed.at("word")==1);
    for(std::size_t n=0;n<serialized.size();++n){bool rejected=false;try{(void)decodePersonalization(std::span(serialized).first(n));}catch(const std::invalid_argument&){rejected=true;}assert(rejected);}
    {   // Whatever learning accepts must import again (oversized/empty inputs are not stored).
        Personalization edge; edge.reset(9);
        std::string longWord(1100,'x'), longContext(1100,'y'), half(600,'z');
        edge.learn(std::vector<std::string>{longContext},"hello"); edge.learn(std::vector<std::string>{half,half},"there");
        edge.learn({},longWord); edge.learn({},""); edge.confirm(""); edge.confirm(longWord);
        auto back=decodePersonalization(encodePersonalization(edge.exportSnapshot()));
        assert(back.counts.uni("hello")==1 && back.counts.uni("there")==1 && !back.counts.uni(longWord) && back.confirmed.empty());
        assert(back.counts.bigram.contains(half) && !back.counts.bigram.contains(longContext) && back.counts.trigram.empty());
    }
    user.reset(5);assert(user.counts()->unigram.empty() && old->uni("word")==1 && !user.kept("word"));
    for(int i=0;i<4100;++i)user.learn({},"word"+std::to_string(i));assert(user.prune());assert(user.counts()->unigram.empty());
    std::vector<RankedRow> ties{{{"z",0,1},"z",0,0,0,{}},{{"a",0,1},"a",0,0,0,{}}};
    auto ordered=rank(ties,"",true);assert(ordered.front().channel.word=="a");std::reverse(ties.begin(),ties.end());assert(rank(ties,"",true).front().channel.word=="a");
    std::ifstream stream(argv[1],std::ios::binary);std::vector<char> chars((std::istreambuf_iterator<char>(stream)),{});assert(!chars.empty());
    auto backing=std::make_shared<std::vector<char>>(std::move(chars));
    auto reader=std::shared_ptr<const PackedLexicon>(new PackedLexicon({reinterpret_cast<const std::byte*>(backing->data()),backing->size()}),[backing](const PackedLexicon*p){delete p;});
    auto engine=std::make_shared<Engine>(reader);auto session=engine->createSession();
    GenerationSnapshot generation;MutableTrie supplemental,personal;PersonalCounts counts;
    EngineView view{{reader.get(),nullptr,&supplemental,&personal,&generation},&counts,{},{}};
    for(const auto& word:{"t","teh","the","hello","hell","helo","coeevitjkn","alot","avlot","cant","id","qzvaxon"}) {
        auto in=input(word);auto actual=session->decode(in,view);auto fresh=engine->createSession()->decode(in,view);
        assert(actual.suggestions==fresh.suggestions && actual.correction.word==fresh.correction.word);
        assert(actual.candidates.size()==fresh.candidates.size());
        for(std::size_t i=0;i<actual.candidates.size();++i){assert(actual.candidates[i].ranked.channel.word==fresh.candidates[i].ranked.channel.word);assert(actual.candidates[i].ranked.score==fresh.candidates[i].ranked.score);}
    }
    auto severe=session->decode(input("coeevitjkn"),view);assert(severe.correction.word=="correction");
    CancellationToken token;token.cancel();auto cancelled=session->decode(input("hello"),view,&token);assert(cancelled.status==EngineStatus::cancelled && cancelled.suggestions.empty());
    auto unsupported=input("hello");unsupported.language="te";assert(session->decode(unsupported,view).status==EngineStatus::unsupportedLanguage);
    unsupported=input("hello");unsupported.modelTier="neuralGRU";assert(session->decode(unsupported,view).status==EngineStatus::unsupportedModel);
    auto seeds=reader->incrementalSeeds('c',{},1000000);assert(seeds);
    std::vector<WordFrequencyBoost> boosts{{"correction",8}};
    auto boosted=reader->incrementalSeeds('c',{},1000000,boosts);assert(boosted && seeds->seeds().size()==boosted->seeds().size());
    IncrementalSearch reusable(seeds);reusable.advanceNormalized("hello");reusable.reset(boosted);assert(reusable.typed().empty());reusable.advanceNormalized("coeevitjkn");
    IncrementalSearch independent(boosted);independent.advanceNormalized("coeevitjkn");auto a=reusable.candidates(7.2),b=independent.candidates(7.2);assert(a.size()==b.size());for(std::size_t i=0;i<a.size();++i)assert(a[i].word==b[i].word&&a[i].cost==b[i].cost&&a[i].logFrequency==b[i].logFrequency);
    {   // Retyping a retained word with different touches must not reuse stale DP costs.
        auto hSeeds=reader->incrementalSeeds('h',{},1000000);assert(hSeeds);
        std::vector<std::optional<TouchOffset>> centered(5,TouchOffset{0,0}),shifted(5,TouchOffset{0.45,0.3});
        IncrementalSearch retainedSearch(hSeeds);retainedSearch.advanceNormalized("house",centered);retainedSearch.advanceNormalized("house",shifted);
        IncrementalSearch freshSearch(hSeeds);freshSearch.advanceNormalized("house",shifted);
        auto x=retainedSearch.candidates(2.4),y=freshSearch.candidates(2.4);assert(x.size()==y.size());
        for(std::size_t i=0;i<x.size();++i)assert(x[i].word==y[i].word&&x[i].cost==y[i].cost);
        retainedSearch.advanceNormalized("houses",centered);freshSearch.reset(hSeeds);freshSearch.advanceNormalized("houses",centered);
        x=retainedSearch.candidates(2.4);y=freshSearch.candidates(2.4);assert(x.size()==y.size());
        for(std::size_t i=0;i<x.size();++i)assert(x[i].word==y[i].word&&x[i].cost==y[i].cost);
    }
    {   // A stream that can no longer be extended must say so, not look like "no candidates".
        GlideLayout layout{{},1,1};const char* rows[]={"qwertyuiop","asdfghjkl","zxcvbnm"};const double shifts[]={0,0.5,1.5};
        for(int y=0;y<3;++y)for(int x=0;rows[y][x];++x)layout.centers.emplace_back(std::uint8_t(rows[y][x]),Point{x+shifts[y],double(y)});
        std::vector<Point> path{{5.5,1},{2,0},{8,0},{8,0}};
        auto glide=engine->createSession();glide->beginGlide({});(void)glide->updateGlide(path,layout,view,{});
        bool invalidated=false;try{(void)glide->updateGlide(std::span(path).first(2),layout,view,{});}catch(const GlideInvalidated&){invalidated=true;}
        assert(invalidated);
    }
    session->memoryPressure();assert(session->decode(input("hello"),view).suggestions==engine->createSession()->decode(input("hello"),view).suggestions);
    if (argc == 4) { testSafety(argv[2]); testBlockedGeneration(reader, argv[2]); replayGoldens(reader, argv[2], argv[3]); }
    std::cout << "Shared engine, snapshot ownership, deterministic ties, serialization, reset/reuse and cancellation passed\n";
}
