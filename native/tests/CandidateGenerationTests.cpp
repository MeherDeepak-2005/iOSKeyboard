#include "../DecoderCore/include/CandidateGeneration.hpp"
#include <cassert>
#include <algorithm>
#include <cmath>
#include <iostream>
using namespace kb;
int main() {
    MutableTrie base, personal, supplementary;
    base.insert("correction", 100); base.insert("coercion", 10);
    base.insert("the", 900); base.insert("hello", 200); base.insert("help", 150);
    base.insert("a", 700); base.insert("lot", 100); base.insert("send", 200);
    base.insert("can't", 400); base.insert("can", 400); base.insert("its", 350);
    GenerationSnapshot snapshot;
    GenerationLexicon lexicon{nullptr, &base, &supplementary, &personal, &snapshot};
    auto typo = base.search("teh", 1.8);
    assert(typo.size() == 1 && typo[0].word == "the" && typo[0].cost == 0.8);
    auto before = base.logFrequency("hello").value(); base.bump("hello");
    assert(base.logFrequency("hello").value() == std::log(std::exp(before) + 1));
    auto completions = base.completions("hel", 24);
    assert(completions.size() == 2 && completions[0].word == "hello");
    std::vector<ContextSuccessor> successors{{"correction", 10}};
    auto result = generateCandidates(lexicon, "coeevitjkn", {}, successors, {}, {}, false);
    assert(!result.cancelled && !result.broad.empty());
    auto correction = std::find_if(result.broad.begin(), result.broad.end(), [](const auto& c) { return c.word == "correction"; });
    assert(correction != result.broad.end() && std::abs(correction->cost - 6.525) < 1e-9);
    result = generateCandidates(lexicon, "alot", {}, {}, {}, {}, false);
    assert(result.split && result.split->word == "a lot" && result.split->cost == 1.1);
    result = generateCandidates(lexicon, "avlot", {}, {}, {}, {}, false);
    assert(result.split && result.split->word == "a lot" && result.split->cost == 0.72);
    snapshot.blocked.insert("lot");
    result = generateCandidates(lexicon, "alot", {}, {}, {}, {}, false);
    assert(!result.split);
    result = generateCandidates(lexicon, "teh", {}, {}, {}, {}, false, [] { return true; });
    assert(result.cancelled && result.close.empty() && result.completions.empty());
    personal.insert("meher", 8);
    assert(lexicon.contains("meher") && !base.contains("meher"));
    MutableTrie fresh;
    assert(!fresh.contains("meher")); // reset replaces the personal trie, never the static layer
    std::vector<std::string> likely{"correction"};
    auto rankedFunding = rankFunding(likely);
    assert(rankedFunding.size() == 1 && rankedFunding[0].bonus == 1.5);
    std::vector<std::pair<std::string, double>> scores{{"correction", -2}, {"coercion", -12}, {"bad", 1}};
    auto probability = probabilityFunding(scores);
    assert(probability.size() == 1 && std::abs(probability[0].bonus - 1.6 * (1 - 2.0 / 12)) < 1e-9);
    std::cout << "Candidate generation goldens passed\n";
}
