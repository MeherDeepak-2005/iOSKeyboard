#include "../include/Ranking.hpp"
#include <algorithm>
#include "../include/TextOrder.hpp"
#include <cmath>
#include <limits>
#include <numeric>
namespace kb {
double frequencyTerm(double frequency, bool compressed) { return compressed ? std::log1p(std::max(frequency, 0.0)) : frequency; }
double rawScore(const RankedRow& row, double channel) {
    auto prior = row.neural ? 0.7 * *row.neural + (1 - 0.7) * row.language : row.language;
    return -channel * row.channel.cost + languageWeight * prior + frequencyWeight * row.channel.logFrequency;
}
std::vector<RankedRow> prepareRanking(std::span<const RankedRow> rows, const std::optional<RankedRow>& typed) {
    std::vector<RankedRow> out;
    std::unordered_map<std::string, std::size_t> indices;
    for (const auto& row : rows) {
        if ((!typed || row.key != typed->key) && !std::isfinite(row.safety)) continue;
        auto [it, inserted] = indices.emplace(row.key, out.size());
        if (inserted) out.push_back(row);
        else if (out[it->second].channel.cost > row.channel.cost) out[it->second] = row;
    }
    if (typed) {
        auto [it, inserted] = indices.emplace(typed->key, out.size());
        if (inserted) out.push_back(*typed); else out[it->second] = *typed;
    }
    return out;
}
std::vector<RankedRow> shortlist(std::vector<RankedRow> rows, const std::optional<RankedRow>& typed,
        std::optional<std::size_t> limit, bool compressed) {
    auto cap = limit ? std::optional<std::size_t>(*limit - (typed && *limit > 0 ? 1 : 0)) : std::nullopt;
    if (cap && rows.size() > *cap) {
        std::stable_sort(rows.begin(), rows.end(), [&](const auto& a, const auto& b) {
            auto lhs = -a.channel.cost + shortlistFrequencyWeight * frequencyTerm(a.channel.logFrequency, compressed);
            auto rhs = -b.channel.cost + shortlistFrequencyWeight * frequencyTerm(b.channel.logFrequency, compressed);
            return lhs == rhs ? utf8Less(a.key, b.key) : lhs > rhs;
        }); rows.resize(*cap);
    }
    if (typed) { std::erase_if(rows, [&](const auto& row) { return row.key == typed->key; }); rows.push_back(*typed); }
    return rows;
}
std::vector<RankedRow> rank(std::vector<RankedRow> rows, std::string_view typed, bool compressed, std::optional<std::size_t> limit) {
    for (auto& row : rows) {
        auto prior = row.neural ? 0.7 * *row.neural + (1 - 0.7) * row.language : row.language;
        row.score = -channelWeight * row.channel.cost - (row.key == typed ? 0 : row.safety) + languageWeight * prior
            + frequencyWeight * frequencyTerm(row.channel.logFrequency, compressed);
    }
    std::stable_sort(rows.begin(), rows.end(), [](const auto& a, const auto& b) { return a.score == b.score ? utf8Less(a.key, b.key) : a.score > b.score; });
    if (limit && rows.size() > *limit) {
        auto found = std::find_if(rows.begin(), rows.end(), [&](const auto& row) { return row.key == typed; });
        std::optional<RankedRow> extra = found != rows.end() ? std::optional(*found) : std::nullopt;
        rows.resize(*limit);
        if (extra && std::none_of(rows.begin(), rows.end(), [&](const auto& row) { return row.key == typed; })) {
            if (!rows.empty()) rows.pop_back(); rows.push_back(*extra);
        }
    }
    return rows;
}
bool accepts(const CorrectionPolicy& p, const CorrectionGate& e) {
    switch (e.kind) {
    case CorrectionKind::realWord: return e.margin > p.realWordMargin;
    case CorrectionKind::severe: return e.margin > std::log(10.0) && (!e.gap || *e.gap >= std::log(2.0));
    case CorrectionKind::loose: return e.margin > p.oovMargin && (!e.gap || *e.gap >= 1);
    case CorrectionKind::close:
        if (e.gap && *e.gap < p.minimumCloseGap) return false;
        if (e.margin > p.oovMargin) return true;
        return e.allowsCloseRescue && e.cost <= p.closeRescueMaxCost && e.margin > p.closeRescueMargin && (!e.gap || *e.gap >= p.closeRescueGap);
    }
    return false;
}
// longer is shorter plus a regular inflectional ending (test/tests, box/boxes, bake/baked).
// mis/miss is not one (a word ending in s does not pluralize with a bare s), nor are
// two-letter bases (we/wed, be/bed, ha/has), which are usually unrelated words.
bool inflection(std::string_view shorter, std::string_view longer) {
    if (!longer.starts_with(shorter) || shorter.size() < 3) return false;
    auto ending = longer.substr(shorter.size());
    if (ending == "s") return !shorter.ends_with("s");
    if (ending == "es") return shorter.ends_with("s") || shorter.ends_with("x") || shorter.ends_with("z") ||
        shorter.ends_with("ch") || shorter.ends_with("sh") || shorter.ends_with("o");
    if (ending == "d") return shorter.ends_with("e");
    return ending == "ed" || ending == "'s";
}
// Optimal string alignment distance (unit costs, adjacent transpositions).
std::size_t osaDistance(std::string_view a, std::string_view b) {
    std::vector<std::vector<std::size_t>> d(a.size() + 1, std::vector<std::size_t>(b.size() + 1));
    for (std::size_t i = 0; i <= a.size(); ++i) d[i][0] = i;
    for (std::size_t j = 0; j <= b.size(); ++j) d[0][j] = j;
    for (std::size_t i = 1; i <= a.size(); ++i) for (std::size_t j = 1; j <= b.size(); ++j) {
        d[i][j] = std::min({d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0u : 1u)});
        if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]) d[i][j] = std::min(d[i][j], d[i - 2][j - 2] + 1);
    }
    return d[a.size()][b.size()];
}
bool nearForm(std::string_view a, std::string_view b) {
    if ((a.size() > b.size() ? a.size() - b.size() : b.size() - a.size()) > 2) return false;
    std::vector<std::size_t> previous(b.size() + 1), current(b.size() + 1);
    std::iota(previous.begin(), previous.end(), 0);
    for (std::size_t i = 1; i <= a.size(); ++i) {
        current[0] = i; auto minimum = i;
        for (std::size_t j = 1; j <= b.size(); ++j) {
            current[j] = std::min(previous[j - 1] + (a[i - 1] == b[j - 1] ? 0u : 1u), std::min(previous[j] + 1, current[j - 1] + 1));
            minimum = std::min(minimum, current[j]);
        }
        if (minimum > 2) return false;
        previous.swap(current);
    }
    return previous.back() <= 2;
}
CorrectionResult correction(const GenerationLexicon& lexicon, std::span<const RankedRow> rows,
        const std::unordered_map<std::string, double>& costs, std::string_view typed, std::size_t length,
        std::span<const std::uint8_t> letterFlags, std::span<const std::string> context, bool kept, const std::unordered_set<std::string>& loose,
        const std::unordered_set<std::string>& broad, const CorrectionPolicy& suppliedPolicy) {
    if (kept) return {};
    auto literal = std::find_if(rows.begin(), rows.end(), [&](const auto& r) { return r.channel.word == typed; });
    if (literal == rows.end()) return {};
    auto policy = std::any_of(rows.begin(), rows.end(), [](const auto& r) { return r.neural.has_value(); }) ? CorrectionPolicy{} : suppliedPolicy;
    std::vector<const RankedRow*> eligible;
    for (const auto& r : rows) if (r.channel.word != typed && costs.contains(r.channel.word)) eligible.push_back(&r);
    const RankedRow* best = nullptr;
    double channel = lexicon.contains(typed) ? realWordChannelWeight : channelWeight;
    // A non-word is judged against each candidate's correction cost: the same word as a
    // completion (cost 0, the typed text is its prefix) must not turn the gate into autocomplete
    // (successfull -> successfully). The real-word gate keeps the completion cost it was
    // calibrated with (wit -> with).
    const bool realWord = lexicon.contains(typed);
    auto rawScore = [&](const RankedRow& row) {
        auto found = costs.find(row.channel.word);
        return kb::rawScore(row, channel) - channel * (realWord || found == costs.end() || &row == &*literal ? 0 : found->second - row.channel.cost);
    };
    double bestScore = -std::numeric_limits<double>::infinity(), typedScore = rawScore(*literal);
    auto pickBest = [&] {
        best = nullptr; bestScore = -std::numeric_limits<double>::infinity(); typedScore = rawScore(*literal);
        for (const auto* r : eligible) if (!best || rawScore(*r) > bestScore) { best = r; bestScore = rawScore(*r); }
    };
    // The real-word gate only weighs slips (cost <= 1.6): a frequent far word must not hide one.
    if (realWord && realWordCloseOnly) std::erase_if(eligible, [&](const RankedRow* r) { return costs.at(r->channel.word) > 1.6; });
    pickBest();
    // A split that cannot clear its own margin gives way to the best single word (sacreligious
    // is not "sa religious", nor left alone because of it).
    if (best && best->channel.word.find(' ') != std::string::npos && bestScore - typedScore <= splitCorrectionMargin) {
        std::erase_if(eligible, [](const RankedRow* r) { return r->channel.word.find(' ') != std::string::npos; });
        pickBest();
    }
    // Recovery beyond the close search (broad, context injection) is far from what was typed
    // whatever the candidate: there the gate weighs the channel less, as before 28 Oct.
    if (best && !lexicon.contains(typed) && loose.contains(best->channel.word) && recoveryChannelWeight != channel) {
        channel = recoveryChannelWeight; pickBest();
    }
    auto gap = [&](std::string_view winner, bool unrelated) -> std::optional<double> {
        std::optional<double> other;
        for (const auto* r : eligible) if (r->channel.word != winner && (!unrelated || !nearForm(r->channel.word, winner))) {
            auto score = rawScore(*r); if (!other || score > *other) other = score;
        }
        return other ? std::optional(bestScore - *other) : std::nullopt;
    };
    auto finish = [&](CorrectionGate gate) {
        bool fire = accepts(policy, gate);
        // A missing-space split keeps the earlier non-word margin (iamhere is not "ia here").
        if (fire && gate.candidate.find(' ') != std::string::npos && gate.margin <= splitCorrectionMargin) fire = false;
        double threshold = gate.kind == CorrectionKind::realWord ? policy.realWordMargin
            : gate.kind == CorrectionKind::severe ? std::log(10.0) : policy.oovMargin;
        if (fire && gate.kind == CorrectionKind::close && gate.margin <= policy.oovMargin) threshold = policy.closeRescueMargin;
        return CorrectionResult{fire ? std::optional(gate.candidate) : std::nullopt, gate.margin, threshold, gate};
    };
    if (lexicon.contains(typed)) {
        if (typed == "id") {
            if (context.empty()) return {"i'd", 100, 0, {}};
            static const std::unordered_set<std::string> determiners{"my","your","his","her","our","their","a","an","the","valid","fake","user","login","student","employee","email","caller"};
            if (determiners.contains(context.back())) return {};
        }
        // At most one added letter: two cheap doubled-letter or completion steps (dog -> doggy) are
        // not a real-word slip, and the 1.6 cost cap no longer excludes them.
        if (length < 2 || !best || !lexicon.contains(best->channel.word) || costs.at(best->channel.word) > 1.6 ||
            best->channel.word.size() > typed.size() + 1) return {};
        // A valid word is never replaced by its own inflection (tests -> test, base -> bases):
        // the language model prefers one form, but the user chose the other deliberately.
        if (inflection(typed, best->channel.word) || inflection(best->channel.word, typed)) return {};
        return finish({CorrectionKind::realWord, best->channel.word, bestScore - typedScore, costs.at(best->channel.word), gap(best->channel.word, false), false});
    }
    if (typed.find('\'') != std::string_view::npos) {
        static const std::vector<std::string> suffixes{"'s", "'re", "'ve", "'ll", "'d", "'m", "n't"};
        for (const auto& suffix : suffixes) if (typed.ends_with(suffix)) {
            auto base = typed.substr(0, typed.size() - suffix.size());
            if (!base.empty() && letterFlags.size() == typed.size() && std::all_of(letterFlags.begin(), letterFlags.begin() + base.size(), [](auto v) { return v != 0; }) && lexicon.contains(base)) return {};
        }
    }
    if (length >= 2) if (auto restored = lexicon.apostropheRestoration(typed); restored && !lexicon.isBlocked(*restored)) return {*restored, 100, 0, {}};
    if (double(length) < minimumCorrectionLength || !best) return {};
    auto winner = best->channel.word;
    // Promote only when the typed s is not already part of the winner's spelling (minuts ->
    // minutes, but muts -> must, goos -> good), and then as a plural before a possessive.
    if (typed.ends_with("s") && !winner.ends_with("s") && winner.find('\'') == std::string::npos &&
            osaDistance(typed, winner + "s") < osaDistance(typed, winner)) {
        auto plural = winner + "s", promoted = winner + "'s";
        if (lexicon.contains(plural) && !lexicon.isBlocked(plural)) winner = plural;
        else if (lexicon.contains(promoted) && !lexicon.isBlocked(promoted)) winner = promoted;
    }
    bool isLoose = loose.contains(winner), severe = length >= 8 && broad.contains(winner);
    auto cost = costs.contains(winner) ? costs.at(winner) : std::numeric_limits<double>::max();
    bool isStatic = (lexicon.packed && lexicon.packed->wordID(winner)) || (!lexicon.packed && lexicon.base && lexicon.base->contains(winner));
    return finish({isLoose ? (severe ? CorrectionKind::severe : CorrectionKind::loose) : CorrectionKind::close,
        winner, bestScore - typedScore, cost, gap(winner, isLoose), !isLoose && cost <= 1.6 && isStatic && winner.find(' ') == std::string::npos && winner.find('\'') == std::string::npos && length >= 4});
}
} // namespace kb
