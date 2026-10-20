#pragma once
#include <algorithm>
#include <cmath>
#include <limits>
#include <span>
#include <stdexcept>
#include <vector>
namespace kb {
// Counts are max(effectiveCount - D(effectiveCount), 0), prepared per order.
struct LanguageEvidence {
    double unigramMass;
    double bigramCount, trigramCount;
    double unigramPersonal, bigramPersonal, trigramPersonal;
};
// discountMass is the sum of D(count) over every retained successor.
struct ContextEvidence { double total = 0, discountMass = 0; };
// Same Double operation order as the reference Swift prior. Platform code supplies
// one immutable batch of corpus/personal evidence; no callbacks inside this scorer.
inline double interpolateLanguage(ContextEvidence context, double count, double backoff) {
    if (context.total <= 0) return backoff;
    return count / context.total + context.discountMass / context.total * backoff;
}
inline double personalLanguageBoost(double count, double weight) {
    return count >= 3 ? weight * std::log1p(count - 3 + 1) : 0;
}
inline std::vector<double> languageScores(std::span<const LanguageEvidence> rows,
        double corpusTotal, ContextEvidence bigram = {}, ContextEvidence trigram = {}) {
    if (!std::isfinite(corpusTotal) || corpusTotal <= 0)
        throw std::invalid_argument("invalid corpus smoothing mass");
    for (const auto context : {bigram, trigram}) {
        if (!std::isfinite(context.total) || !std::isfinite(context.discountMass) ||
            context.total < 0 || context.discountMass < 0 || context.discountMass > context.total)
            throw std::invalid_argument("invalid context evidence");
    }
    std::vector<double> result;
    result.reserve(rows.size());
    for (const auto& row : rows) {
        for (double value : {row.unigramMass, row.bigramCount, row.trigramCount,
                            row.unigramPersonal, row.bigramPersonal, row.trigramPersonal})
            if (!std::isfinite(value) || value < 0) throw std::invalid_argument("invalid language row");
        double probability = row.unigramMass / corpusTotal;
        probability = interpolateLanguage(bigram, row.bigramCount, probability);
        probability = interpolateLanguage(trigram, row.trigramCount, probability);
        result.push_back(std::log(std::max(probability, std::numeric_limits<double>::denorm_min()))
            + personalLanguageBoost(row.unigramPersonal, 0.10)
            + personalLanguageBoost(row.bigramPersonal, 0.22)
            + personalLanguageBoost(row.trigramPersonal, 0.28));
    }
    return result;
}
} // namespace kb
