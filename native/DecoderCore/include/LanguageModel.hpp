#pragma once
#include "CandidateGeneration.hpp"
#include "LanguageScoring.hpp"
#include <array>
namespace kb {
using CountRows = std::vector<std::pair<std::string, std::int64_t>>;
struct PersonalCounts {
    std::unordered_map<std::string, std::int64_t> unigram;
    std::unordered_map<std::string, CountRows> bigram, trigram;
    std::int64_t uni(std::string_view word) const;
    const CountRows& bi(std::string_view context) const;
    const CountRows& tri(std::string_view context) const;
};
enum class Smoothing { wittenBell, modifiedKneserNey, frequencyBackoff };
class LanguageModel final {
    struct Context {
        ContextEvidence evidence;
        std::unordered_map<std::int32_t, double> counts;
    };
    const PackedLexicon* data_;
    Smoothing smoothing_;
    double total_ = 1;
    std::unordered_map<std::int32_t, std::int64_t> unigrams_;
    std::unordered_map<std::int32_t, Context> bigrams_;
    std::array<double, 3> triDiscounts_{};
    // `wanted` (sorted IDs) limits stored counts to the words being scored; evidence
    // still covers the whole row. Modified Kneser–Ney needs every row and ignores it.
    std::optional<Context> prepare(const std::optional<Continuations>& row, std::span<const std::int32_t> wanted) const;
    static Context discounted(const CountRows& rows, const std::array<double, 3>& discounts);
    static Context discounted(const std::vector<Continuation>& rows, const std::array<double, 3>& discounts);
    void prepareMKN();
public:
    LanguageModel(const PackedLexicon* data, Smoothing smoothing);
    std::vector<double> scores(std::span<const std::string> words, std::span<const std::string> context,
        const PersonalCounts& personal, const GenerationLexicon& lexicon) const;
    double sequence(std::span<const std::string> words, std::vector<std::string> context,
        const PersonalCounts& personal, const GenerationLexicon& lexicon) const;
    // Unsorted counts preserve corpus/personal insertion order. The iOS adapter
    // supplies the former Swift dictionary's iteration permutation for tied rows.
    CountRows successors(std::span<const std::string> context, const PersonalCounts& personal,
        bool trigram, std::size_t limit) const;
    static std::vector<std::string> nextWords(CountRows tri, CountRows bi, std::size_t limit);
};
} // namespace kb
