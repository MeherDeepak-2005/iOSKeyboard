#include "../DecoderCore/include/LanguageScoring.hpp"
#include "../DecoderCore/include/PackedLexicon.hpp"
#include "../DecoderCore/include/IncrementalSearch.hpp"
#include <cmath>
#include <limits>
#include <cassert>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <vector>
#include <type_traits>

static_assert(!std::is_copy_constructible_v<kb::IncrementalSearch>);
static_assert(!std::is_move_constructible_v<kb::IncrementalSearch>);
static_assert(!std::is_copy_assignable_v<kb::IncrementalSeedSet>);
static_assert(!std::is_move_assignable_v<kb::IncrementalSeedSet>);

using Bytes = std::vector<std::byte>;
static void put(Bytes& bytes, std::uint32_t value, unsigned width = 4) {
    for (unsigned i = 0; i < width; ++i) bytes.push_back(std::byte((value >> (8 * i)) & 255));
}
static void replace(Bytes& bytes, std::size_t offset, std::uint32_t value, unsigned width = 4) {
    for (unsigned i = 0; i < width; ++i) bytes.at(offset + i) = std::byte((value >> (8 * i)) & 255);
}
static Bytes fixture(unsigned version) {
    Bytes b;
    for (auto v : {0x4B424C4Du, version, 3u, 1u, 2u, 1u, 2u}) put(b, v);
    if (version >= 3) put(b, 1); // root-only trie
    if (version >= 4) put(b, 1); // one starter
    for (auto v : {11u, 22u, 33u, 0u, 1u, 3u, 6u}) put(b, v);
    if (version == 5) { put(b, 1, 2); put(b, 2, 2); put(b, 20); put(b, 0); }
    else for (auto v : {1u, 20u, 0u, 2u}) put(b, v);
    auto entry = [&](std::uint32_t id, std::uint32_t count) { put(b, id, version == 5 ? 2 : 4); put(b, count); };
    entry(2, 7); entry(0, 3);
    if (version == 5) for (auto v : {1u, 17u, 0u}) put(b, v); // packed context (0,1)
    else for (auto v : {0u, 1u, 17u, 0u, 2u}) put(b, v);
    entry(2, 9); entry(0, 2);
    if (version >= 3) {
        put(b, 0, 1); put(b, 0, 1); put(b, 0);
        put(b, version == 5 ? 0xffff : 0xffffffff, version == 5 ? 2 : 4); put(b, 33);
    }
    if (version >= 4) entry(1, 22);
    for (char c : std::string("abbccc")) b.push_back(std::byte(c));
    return b;
}
static void rejects(const Bytes& bytes) {
    bool rejected = false;
    try { kb::PackedLexicon view{bytes}; }
    catch (const std::invalid_argument&) { rejected = true; }
    assert(rejected);
}
static void testVersion(unsigned version) {
    auto bytes = fixture(version);
    kb::PackedLexicon view{bytes};
    assert(view.backingAddress() == bytes.data());
    assert(view.version() == version && view.wordCount() == 3);
    assert(view.word(0) == "a" && view.word(1) == "bb" && view.word(2) == "ccc");
    assert(view.frequency(0) == 11 && view.frequency(2) == 33);
    auto bi = view.bigrams(1);
    assert(bi && bi->total == 20 && bi->entries.size() == 2);
    assert(bi->entries[0].word == 2 && bi->entries[0].count == 7);
    assert(bi->entries[1].word == 0 && bi->entries[1].count == 3);
    assert(view.bigrams(1, 0)->entries.empty() && view.bigrams(1, 0)->total == 20);
    assert(view.bigrams(1, 1)->entries.size() == 1);
    assert(!view.bigrams(-1) && !view.bigrams(3) && !view.bigrams(0));
    // The legacy hash fixture is completely full. Missing lookup must terminate.
    auto tri = view.trigrams(0, 1);
    assert(tri && tri->total == 17 && tri->entries.size() == 2);
    assert(tri->entries[0].word == 2 && tri->entries[0].count == 9);
    assert(view.trigrams(0, 1, 1)->entries.size() == 1);
    assert(!view.trigrams(1, 0) && !view.trigrams(-1, 0) && !view.trigrams(0, 3));
    auto contexts = view.trigramContexts();
    assert(contexts.size() == 1 && contexts[0].first == 0 && contexts[0].second == 1);
    assert(view.starterIDs(0).empty());
    assert(view.starterIDs(10) == (version >= 4 ? std::vector<std::int32_t>{1} : std::vector<std::int32_t>{}));
    bool bounds = false;
    try { (void)view.word(3); } catch (const std::out_of_range&) { bounds = true; }
    assert(bounds);
    for (std::size_t cut = 0; cut < bytes.size(); ++cut) rejects(Bytes(bytes.begin(), bytes.begin() + cut));
    auto bad = bytes; replace(bad, 0, 0); rejects(bad);
    bad = bytes; replace(bad, 4, 7); rejects(bad);
    bad = bytes; replace(bad, 8, 0xffffffff); rejects(bad);
    const auto header = version >= 4 ? 36u : version >= 3 ? 32u : 28u;
    bad = bytes; replace(bad, header + 12 + 4, 100); rejects(bad); // nonmonotonic/out-of-bounds offsets
    const auto biHash = header + 12 + 16;
    bad = bytes; replace(bad, biHash, 3, version == 5 ? 2 : 4); rejects(bad);
    bad = bytes; replace(bad, biHash + 8, 0xffffffff); rejects(bad);
    const auto biData = biHash + (version == 5 ? 12 : 16);
    bad = bytes; replace(bad, biData, 3, version == 5 ? 2 : 4); rejects(bad);
    if (version < 5) { bad = bytes; replace(bad, 12, 3); rejects(bad); }
    std::cout << "PASS v" << version << ": words, exact n-grams, limits, missing/full hash lookup, shared bytes, bounds and "
              << bytes.size() << " truncated prefixes + corrupt fields\n";
}
// These pairs collide with legacy (first << 16) | second packing.
static void testWideIDs() {
    constexpr unsigned words = 65538;
    Bytes b;
    for (auto v : {0x4B424C4Du, 6u, words, 2u, 2u, 2u, 2u, 2u, 1u}) put(b, v);
    for (unsigned i = 0; i < words; ++i) put(b, 1);
    for (unsigned i = 0; i <= words; ++i) put(b, i);
    const auto biBase = b.size();
    for (auto v : {1u, 7u, 0u, 1u, 65536u, 9u, 1u, 1u}) put(b, v);
    for (auto v : {65536u, 7u, 65537u, 9u}) put(b, v);
    const auto triBase = b.size();
    for (auto v : {0u, 65536u, 11u, 0u, 1u, 1u, 0u, 13u, 1u, 1u}) put(b, v);
    for (auto v : {65536u, 11u, 65537u, 13u}) put(b, v);
    const auto trieBase = b.size();
    put(b, 0, 1); put(b, 1, 1); put(b, 1); put(b, 0xffffffff); put(b, 1);
    put(b, 'w', 1); put(b, 0, 1); put(b, 0); put(b, 65536); put(b, 1);
    put(b, 65537); put(b, 17);
    for (unsigned i = 0; i < words; ++i) b.push_back(std::byte('w'));
    kb::PackedLexicon view{b};
    assert(view.bigrams(1)->entries[0].word == 65536);
    assert(view.bigrams(65536)->entries[0].word == 65537);
    assert(view.trigrams(0, 65536)->total == 11);
    assert(view.trigrams(1, 0)->total == 13);
    assert(!view.trigrams(0, 0) && !view.trigrams(1, 65536));
    assert(view.starterIDs(1) == std::vector<std::int32_t>{65537});
    auto found = view.search("w", 0);
    assert(found.size() == 1 && found[0].word == "w");
    auto bad = b; replace(bad, biBase + 16, 1); rejects(bad);
    bad = b; replace(bad, triBase + 20, 0); replace(bad, triBase + 24, 65536); rejects(bad);
    bad = b; replace(bad, triBase + 24, words); rejects(bad);
    bad = b; replace(bad, trieBase + 14 + 6, words); rejects(bad);
    std::cout << "PASS v6 IDs above 65535, distinct wide context pairs, starters, trie and corrupt fields\n";
}
static void testSpatialAndIncremental() {
    auto q = kb::grid('q'), a = kb::grid('a'), z = kb::grid('z');
    assert(q && q->x == 0 && q->y == 0);
    assert(a && a->x == 0.5 && a->y == 1);
    assert(z && z->x == 1.5 && z->y == 2 && !kb::grid('\''));
    assert(kb::substitutionCost('q', 'q') == 0);
    assert(kb::substitutionCost('q', 'w') == 0.8);
    assert(kb::substitutionCost('q', 'w', kb::TouchOffset{-1, 0}) == 0.3);
    assert(kb::substitutionCost('q', 'q', kb::TouchOffset{0, 0}) == 0);
    assert(kb::substitutionCost('q', 'q', kb::TouchOffset{INFINITY, 0}) == 3);
    assert(kb::substitutionCost('?', '?') == 0 && kb::substitutionCost('?', 'q') == 3);
    assert(kb::firstLetterPenalty(2, 'n', 'm') == 0);
    assert(kb::firstLetterPenalty(3, 'n', 'm') == 0.35);
    assert(kb::firstLetterPenalty(4, 'n', 'm') == 0.75);
    assert(kb::firstLetterPenalty(5, 'n', 'm') == 2.5);
    assert(kb::firstLetterPenalty(20, 'm', 'm') == 0);
    kb::IncrementalSearch search{{{"the", "the", 1.25}, {"can't", "can't", 2.25},
                                 {"correction", "correction", 3.25}, {"coercion", "coercion", 4.25}}};
    assert(search.seedCount() == 4 && search.candidates(7.2).empty());
    auto costOf = [&](std::string_view word, double radius) {
        for (const auto& c : search.candidates(radius)) if (c.word == word) return c.cost;
        return std::numeric_limits<double>::infinity();
    };
    assert(search.advanceNormalized("t") && search.advanceNormalized("te") && search.advanceNormalized("teh"));
    assert(std::abs(costOf("the", 1) - 0.8) < 1e-9);
    assert(search.advanceNormalized("cant") && std::abs(costOf("can't", 1) - 0.4) < 1e-9);
    assert(search.advanceNormalized("coeevitjkn"));
    assert(std::abs(costOf("correction", 7.2) - 6.525) < 1e-9);
    assert(std::isinf(costOf("correction", 6.52)));
    assert(!search.advanceNormalized("") && search.typed() == "coeevitjkn");
    assert(!search.advanceNormalized("123") && search.typed() == "coeevitjkn");
    assert(search.advanceNormalized("correction") && costOf("correction", 0) == 0);
    assert(search.advanceNormalized("co") && search.advanceNormalized("cant"));
    assert(std::abs(costOf("can't", 1) - 0.4) < 1e-9);
    std::vector<std::optional<kb::TouchOffset>> mismatched{kb::TouchOffset{1, 1}};
    assert(search.advanceNormalized("the", mismatched) && costOf("the", 0) == 0);
    // A rollback and subsequent append must retain the depth-2 OSA column.
    // Compare every candidate against a fresh independently rebuilt session.
    const std::vector<kb::LexiconSeed> rollbackSeeds{{"the", "the", 1.25}, {"can't", "can't", 2.25},
        {"correction", "correction", 3.25}, {"coercion", "coercion", 4.25}, {"receive", "receive", 5}};
    kb::IncrementalSearch rolling{rollbackSeeds};
    auto compareFresh = [&](std::string_view word, std::span<const std::optional<kb::TouchOffset>> taps = {}) {
        assert(rolling.advanceNormalized(word, taps));
        kb::IncrementalSearch fresh{rollbackSeeds}; assert(fresh.advanceNormalized(word, taps));
        const auto actual = rolling.candidates(100), expected = fresh.candidates(100);
        assert(actual.size() == expected.size());
        for (std::size_t i = 0; i < actual.size(); ++i)
            assert(actual[i].word == expected[i].word && actual[i].cost == expected[i].cost &&
                actual[i].logFrequency == expected[i].logFrequency);
    };
    for (auto word : {"teh", "te", "the", "th", "t", "th", "the", "correction", "correctio",
                     "correcti", "correctio", "correction", "cant", "can", "ca", "can't", "can'", "can't"})
        compareFresh(word);
    std::vector<std::optional<kb::TouchOffset>> touch(4, kb::TouchOffset{.2, -.1});
    // Force a changed prefix before the touch replay; unchanged typed bytes keep
    // their original column evidence under the existing append-only contract.
    compareFresh("zzzz"); compareFresh("cant", touch);
    touch.resize(3); compareFresh("can", touch);
    touch.resize(4, kb::TouchOffset{.3, -.2}); compareFresh("cant", touch);
    touch.resize(3); touch[0] = kb::TouchOffset{-.4, .1}; compareFresh("can", touch);
    compareFresh("ca"); // tap-to-no-tap deletion must rebuild
    assert(!rolling.advanceNormalized("") && rolling.typed() == "ca");
    compareFresh("c"); compareFresh("ca");
    kb::IncrementalSearch empty{std::vector<kb::LexiconSeed>{}};
    assert(empty.advanceNormalized("word") && empty.candidates(7.2).empty());
    std::cout << "PASS spatial/retained DP: geometry, Double costs, first-letter policy, transpose, apostrophe, severe typo, reset, invalid/mismatched input and empty seeds\n";
}
static void testMappedSeedSets(unsigned version) {
    Bytes b;
    const std::vector<std::string> words{"a", "b", "cat", "can't", "correction", "z"};
    for (auto value : {0x4B424C4Du, version, 6u, 0u, 0u, 0u, 0u}) put(b, value);
    if (version >= 3) put(b, 5); // root plus four initial-letter nodes
    if (version >= 4) put(b, 0);
    for (auto f : {0u, 1u, 11u, 22u, 33u, 44u}) put(b, f);
    unsigned offset = 0;
    for (const auto& word : words) { put(b, offset); offset += word.size(); }
    put(b, offset);
    if (version >= 3) {
        auto node = [&](char label, unsigned count, unsigned first) {
            put(b, label, 1); put(b, count, 1); put(b, first);
            put(b, version == 5 ? 0xffff : 0xffffffff, version == 5 ? 2 : 4); put(b, 0);
        };
        node(0, 4, 1);
        for (char label : std::string("abcz")) node(label, 0, 0);
    }
    for (const auto& word : words) for (char c : word) b.push_back(std::byte(c));
    kb::PackedLexicon view{b};
    if (version == 2) { assert(!view.incrementalSeeds('c')); return; }
    assert(!view.incrementalSeeds('C') && !view.incrementalSeeds(0));
    assert(!view.incrementalSeeds('c', {}, 0));
    auto set = view.incrementalSeeds('c');
    assert(set && set->seeds().size() == 3);
    assert(view.incrementalSeeds('c', {}, 3) && !view.incrementalSeeds('c', {}, 2));
    for (std::size_t i = 0; i < 3; ++i) {
        auto seed = set->seeds()[i];
        assert(seed.word == words[i + 2] && seed.spelling == seed.word);
        assert(seed.spelling.data() == view.word(i + 2).data());
        assert(seed.logFrequency == std::log(double(view.frequency(i + 2)) + 1));
    }
    // A valid empty root selection differs from unsupported/cap overflow.
    auto empty = view.incrementalSeeds('p', kb::TouchOffset{INFINITY, 0}, 0);
    assert(empty && empty->seeds().empty() && empty->cellCount() == 0);
    std::vector<kb::WordFrequencyBoost> boosts{{"correction", 37}, {"notincorpusxyz", 99}};
    auto boosted = view.incrementalSeeds('c', {}, 3, boosts);
    assert(boosted && boosted->seeds().size() == set->seeds().size());
    for (std::size_t i = 0; i < set->seeds().size(); ++i) {
        const auto& seed = set->seeds()[i];
        const double expected = seed.word == "correction" ? std::log(std::exp(seed.logFrequency) + 37) : seed.logFrequency;
        assert(boosted->seeds()[i].word == seed.word);
        assert(boosted->seeds()[i].spelling.data() == seed.spelling.data());
        assert(std::abs(boosted->seeds()[i].logFrequency - expected) <= 1e-9);
    }
    boosts.push_back({"correction", 1});
    bool rejectedDuplicate = false;
    try { (void)view.incrementalSeeds('c', {}, 3, boosts); }
    catch (const std::invalid_argument&) { rejectedDuplicate = true; }
    assert(rejectedDuplicate);
    auto zeroFrequency = view.incrementalSeeds('a');
    assert(zeroFrequency && zeroFrequency->seeds()[0].logFrequency == std::log(2.0));
    kb::IncrementalSearch one{set}, two{set};
    set.reset(); // Both sessions independently retain the immutable descriptor set.
    assert(one.advanceNormalized("coeevitjkn") && two.advanceNormalized("cat"));
    assert(two.candidates(0).size() == 1 && two.candidates(0)[0].word == "cat");
    bool found = false;
    for (const auto& c : one.candidates(7.2))
        if (c.word == "correction") { assert(std::abs(c.cost - 6.525) < 1e-9); found = true; }
    assert(found && one.typed() == "coeevitjkn");
    // Equal offsets are accepted by the reader, but Swift seed selection rejects
    // empty words before checking whether their root would be included.
    auto bad = b;
    auto header = version >= 4 ? 36u : 32u;
    replace(bad, header + 6 * 4 + 4, 0);
    kb::PackedLexicon emptyWord{bad};
    assert(!emptyWord.incrementalSeeds('c'));
    std::cout << "PASS mapped seed sets v" << version << ": borrowed bytes, caps, ordering, frequency, shared metadata and independent DP\n";
}
int main(int argc, char** argv) {
    const std::vector<kb::LanguageEvidence> evidence{{10, 2, 1, 0, 0, 0}, {0.5, 0, 0, 3, 5, 7}};
    const auto scores = kb::languageScores(evidence, 1000, {20, 5}, {8, 3});
    assert(scores.size() == 2 && std::isfinite(scores[0]) && std::isfinite(scores[1]));
    const double base = kb::interpolateLanguage({8,3}, 1, kb::interpolateLanguage({20,5}, 2, 0.01));
    assert(std::abs(scores[0] - std::log(base)) <= 1e-9);
    assert(kb::personalLanguageBoost(2, 0.28) == 0);
    assert(std::abs(kb::personalLanguageBoost(3, 0.28) - 0.28 * std::log1p(1)) <= 1e-9);

    // Independent MKN golden: retained counts (1,2,4), discounts (.5,1.25,2).
    assert(std::abs(kb::interpolateLanguage({7, 3.75}, 0.5, 0.2)
                    - (0.5 / 7 + 3.75 / 7 * 0.2)) < 1e-12);
    assert(kb::interpolateLanguage({}, 0, 0.2) == 0.2);
    assert(std::abs(kb::interpolateLanguage({7, 3.75}, 0, 0.2) - 3.75 / 7 * 0.2) < 1e-12);
    const double mass = kb::interpolateLanguage({7, 3.75}, 0.5, 0.2)
                      + kb::interpolateLanguage({7, 3.75}, 0.75, 0.3)
                      + kb::interpolateLanguage({7, 3.75}, 2.0, 0.5);
    assert(std::abs(mass - 1) < 1e-12);
    bool invalidDiscount = false;
    try { (void)kb::languageScores(evidence, 1000, {1, 2}); }
    catch (const std::invalid_argument&) { invalidDiscount = true; }
    assert(invalidDiscount);

    for (unsigned version = 2; version <= 6; ++version) testVersion(version);
    for (unsigned version = 2; version <= 6; ++version) testMappedSeedSets(version);
    testWideIDs();
    testSpatialAndIncremental();
    if (argc > 1) {
        std::ifstream file(argv[1], std::ios::binary);
        if (!file) throw std::runtime_error("cannot open corpus");
        std::vector<char> storage{std::istreambuf_iterator<char>{file}, {}};
        kb::PackedLexicon corpus{{reinterpret_cast<const std::byte*>(storage.data()), storage.size()}};
        std::size_t bigrams = 0;
        for (std::uint32_t id = 0; id < corpus.wordCount(); ++id) {
            (void)corpus.word(id); (void)corpus.frequency(id);
            if (corpus.bigrams(id)) ++bigrams;
        }
        auto recovery = corpus.search("coeevitjkn", 7.2);
        assert(std::any_of(recovery.begin(), recovery.end(), [](const auto& candidate) {
            return candidate.word == "correction" && std::abs(candidate.cost - 6.525) <= 1e-9;
        }));
        assert(corpus.search("coeevitjkn", 7.2, {}, {}, [] { return true; }).empty());
        auto contexts = corpus.trigramContexts();
        for (auto c : contexts) assert(corpus.trigrams(c.first, c.second));
        std::cout << "PASS production corpus v" << corpus.version() << ": " << corpus.wordCount()
                  << " words, " << bigrams << " bigram contexts, " << contexts.size() << " trigram contexts\n";
    }
}
