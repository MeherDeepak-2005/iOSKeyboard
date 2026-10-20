#include "../include/CandidateGeneration.hpp"
#include <algorithm>
#include <cmath>
#include <limits>
#include <numeric>
#include <stdexcept>

namespace kb {
namespace {
template<class T> void append(std::vector<T>& into, const std::vector<T>& values) {
    into.insert(into.end(), values.begin(), values.end());
}
struct FundingNode {
    std::vector<std::pair<std::uint8_t, std::size_t>> children;
    double bonus = 0, terminal = 0;
};
std::size_t child(const std::vector<FundingNode>& nodes, std::size_t parent, std::uint8_t byte) {
    if (parent != SIZE_MAX) for (const auto& [label, next] : nodes[parent].children)
        if (label == byte) return next;
    return SIZE_MAX;
}
std::vector<FundingNode> makeFunding(std::optional<std::span<const WordFunding>> funding) {
    std::vector<FundingNode> out(1);
    if (funding) for (const auto& entry : *funding) {
        if (!std::isfinite(entry.bonus) || entry.bonus <= 0 || entry.bonus > 1.6)
            throw std::invalid_argument("invalid search funding");
        std::size_t at = 0;
        for (std::uint8_t byte : entry.word) {
            auto next = child(out, at, byte);
            if (next == SIZE_MAX) {
                next = out.size(); out[at].children.emplace_back(byte, next); out.emplace_back();
            }
            out[next].bonus = std::max(out[next].bonus, entry.bonus); at = next;
        }
        out[at].terminal = std::max(out[at].terminal, entry.bonus);
    }
    return out;
}
}

std::optional<std::size_t> MutableTrie::node(std::string_view word) const {
    std::size_t at = 0;
    for (std::uint8_t byte : word) {
        auto next = SIZE_MAX;
        for (const auto& [label, index] : nodes_[at].children)
            if (label == byte) { next = index; break; }
        if (next == SIZE_MAX) return {};
        at = next;
    }
    return at;
}
void MutableTrie::insert(std::string_view word, std::int64_t frequency, std::int32_t id, std::size_t characters) {
    std::size_t at = 0;
    for (std::uint8_t byte : word) {
        auto next = SIZE_MAX;
        for (const auto& [label, index] : nodes_[at].children)
            if (label == byte) { next = index; break; }
        if (next == SIZE_MAX) {
            next = nodes_.size(); nodes_[at].children.emplace_back(byte, next); nodes_.emplace_back();
        }
        at = next;
    }
    nodes_[at].word = std::string(word); nodes_[at].wordID = id;
    nodes_[at].characters = characters == SIZE_MAX ? word.size() : characters;
    nodes_[at].logFrequency = std::log(double(std::max<std::int64_t>(frequency, 1)) + 1);
}
bool MutableTrie::contains(std::string_view word) const {
    auto at = node(word); return at && nodes_[*at].word.has_value();
}
std::optional<std::size_t> MutableTrie::characterCount(std::string_view word) const {
    auto at = node(word); if (!at || !nodes_[*at].word) return {}; return nodes_[*at].characters;
}
bool MutableTrie::hasPrefix(std::string_view word) const { return node(word).has_value(); }
std::optional<std::int32_t> MutableTrie::wordID(std::string_view word) const {
    auto at = node(word);
    if (!at || !nodes_[*at].word || nodes_[*at].wordID < 0) return {};
    return nodes_[*at].wordID;
}
std::optional<double> MutableTrie::logFrequency(std::string_view word) const {
    auto at = node(word); if (!at || !nodes_[*at].word) return {};
    return nodes_[*at].logFrequency;
}
void MutableTrie::bump(std::string_view word) {
    auto at = node(word); if (at && nodes_[*at].word)
        nodes_[*at].logFrequency = std::log(std::exp(nodes_[*at].logFrequency) + 1);
}
std::vector<ChannelCandidate> MutableTrie::search(std::string_view typed, double maxCost,
        std::span<const std::optional<TouchOffset>> taps,
        std::optional<std::span<const WordFunding>> funding) const {
    if (typed.empty()) return {};
    if (!std::isfinite(maxCost) || maxCost < 0) throw std::invalid_argument("invalid search radius");
    const double extra = (maxCost + (funding ? 1.6 : 0)) / deletionCost;
    if (extra > 1'000'000 || typed.size() > 1'000'000) throw std::length_error("search input too large");
    const auto n = typed.size(), maxDepth = n + std::size_t(extra) + 2;
    if (maxDepth + 1 > SIZE_MAX / (n + 1)) throw std::length_error("search DP overflow");
    std::vector<double> dp((maxDepth + 1) * (n + 1));
    for (std::size_t i = 0; i <= n; ++i) dp[i] = double(i) * insertionCost;
    auto priors = makeFunding(funding);
    std::vector<ChannelCandidate> out;
    auto visit = [&](auto&& self, std::size_t index, std::uint8_t letter, std::uint8_t previousLetter,
                     std::size_t depth, double penalty, std::size_t prior) -> void {
        if (depth > maxDepth) return;
        auto base = depth * (n + 1), previous = base - (n + 1);
        auto skip = letter == apostrophe ? apostropheSkipCost : deletionCost;
        double rowMin = dp[previous] + skip; dp[base] = rowMin;
        for (std::size_t column = 1; column <= n; ++column) {
            const auto insertion = dp[base + column - 1] + insertionCost;
            const auto deletion = dp[previous + column] + skip;
            auto value = std::min(insertion, std::min(deletion,
                dp[previous + column - 1] + substitutionCost(letter, std::uint8_t(typed[column - 1]),
                    taps.size() == n ? taps[column - 1] : std::nullopt)));
            if (depth >= 2 && column >= 2 && letter == std::uint8_t(typed[column - 2]) &&
                previousLetter == std::uint8_t(typed[column - 1]))
                value = std::min(value, dp[previous - (n + 1) + column - 2] + transpositionCost);
            dp[base + column] = value; if (value < rowMin) rowMin = value;
        }
        const auto& item = nodes_[index];
        const auto terminal = prior == SIZE_MAX ? 0 : priors[prior].terminal;
        const auto bonus = prior == SIZE_MAX ? 0 : priors[prior].bonus;
        auto cost = dp[base + n] + penalty;
        if (item.word && cost - terminal <= maxCost) out.push_back({*item.word, cost, item.logFrequency});
        if (rowMin + penalty - bonus <= maxCost) for (const auto& [label, next] : item.children)
            self(self, next, label, letter, depth + 1, penalty, child(priors, prior, label));
    };
    for (const auto& [label, next] : nodes_[0].children)
        visit(visit, next, label, 0, 1, firstLetterPenalty(n, label, std::uint8_t(typed.front())),
            child(priors, 0, label));
    return out;
}
std::vector<ChannelCandidate> MutableTrie::completions(std::string_view prefix, std::size_t limit) const {
    auto start = node(prefix); if (!start || !limit) return {};
    std::vector<ChannelCandidate> out;
    // Preserve insertion-order DFS and the reference's approximate 256-word cap.
    auto collect = [&](auto&& self, std::size_t at) -> void {
        if (out.size() >= 256) return;
        const auto& item = nodes_[at];
        if (item.word) out.push_back({*item.word, 0, item.logFrequency});
        for (const auto& [label, next] : item.children) { (void)label; self(self, next); }
    };
    collect(collect, *start);
    std::stable_sort(out.begin(), out.end(), [](const auto& a, const auto& b) {
        return a.logFrequency > b.logFrequency;
    });
    if (out.size() > limit) out.resize(limit);
    return out;
}

double rankFundingBonus(std::size_t rank) {
    return std::min(1.6, 1.5 * std::pow(0.82, double(rank)));
}
double probabilityFundingBonus(double probability, double floor) {
    floor = std::min(floor, -1e-3);
    return std::isfinite(probability) && probability <= 0
        ? 1.6 * std::max(0.0, 1 - probability / floor) : 0;
}
std::vector<WordFunding> rankFunding(std::span<const std::string> words) {
    std::vector<WordFunding> out;
    for (std::size_t i = 0; i < words.size(); ++i) {
        auto bonus = rankFundingBonus(i);
        if (bonus > 0) out.push_back({words[i], bonus});
    }
    return out;
}
std::vector<WordFunding> probabilityFunding(std::span<const std::pair<std::string, double>> words, double floor) {
    floor = std::min(floor, -1e-3);
    std::vector<WordFunding> out;
    for (const auto& [word, probability] : words) {
        auto bonus = probabilityFundingBonus(probability, floor);
        if (bonus > 0) out.push_back({word, bonus});
    }
    return out;
}
double normalSearchCost(std::size_t length) noexcept { return length <= 4 ? 1.8 : length <= 7 ? 2.8 : 3.6; }
double injectedSpatialCost(std::string_view typed, std::string_view target,
        std::span<const std::optional<TouchOffset>> taps) {
    std::vector<double> previous(target.size() + 1), current(target.size() + 1);
    for (std::size_t j = 0; j <= target.size(); ++j) previous[j] = double(j) * 1.6;
    for (std::size_t i = 1; i <= typed.size(); ++i) {
        current[0] = double(i) * 1.6;
        for (std::size_t j = 1; j <= target.size(); ++j) {
            auto sub = previous[j - 1] + substitutionCost(std::uint8_t(target[j - 1]), std::uint8_t(typed[i - 1]),
                i <= taps.size() ? taps[i - 1] : std::nullopt);
            auto skip = std::uint8_t(target[j - 1]) == apostrophe ? apostropheSkipCost : 1.6;
            current[j] = std::min(sub, std::min(previous[j] + 1.6, current[j - 1] + skip));
        }
        previous.swap(current);
    }
    return previous.back();
}

bool GenerationLexicon::isBlocked(std::string_view word) const {
    return snapshot && snapshot->blocked.contains(std::string(word));
}
std::optional<std::int64_t> GenerationLexicon::boost(std::string_view word) const {
    if (snapshot) if (auto found = snapshot->boosts.find(std::string(word)); found != snapshot->boosts.end()) return found->second;
    return {};
}
bool GenerationLexicon::contains(std::string_view word) const {
    return (packed && packed->wordID(word)) || (base && base->contains(word)) ||
        (supplementary && supplementary->contains(word)) || (personal && personal->contains(word));
}
std::size_t GenerationLexicon::characterCount(std::string_view word) const {
    if (packed && packed->wordID(word)) return packed->characterCount(word);
    for (const auto* trie : {base, supplementary, personal}) if (trie) if (auto count = trie->characterCount(word)) return *count;
    return word.size();
}
std::optional<double> GenerationLexicon::logFrequency(std::string_view word) const {
    std::optional<double> value;
    if (packed) if (auto id = packed->wordID(word))
        value = std::log(double(std::max(packed->frequency(*id), 1u)) + 1);
    if (!value && base) value = base->logFrequency(word);
    if (value) {
        auto count = boost(word);
        return count ? std::log(std::exp(*value) + double(*count)) : value;
    }
    if (supplementary) value = supplementary->logFrequency(word);
    return value || !personal ? value : personal->logFrequency(word);
}
std::vector<ChannelCandidate> GenerationLexicon::corrections(std::string_view typed, double cost,
        std::span<const std::optional<TouchOffset>> taps, std::optional<std::span<const WordFunding>> funding,
        bool broad, const std::function<bool()>& cancel) const {
    auto boosted = [&](std::vector<ChannelCandidate> words) {
        for (auto& word : words) if (auto count = boost(word.word))
            word.logFrequency = std::log(std::exp(word.logFrequency) + double(*count));
        return words;
    };
    std::vector<ChannelCandidate> mutableWords;
    if (supplementary) append(mutableWords, supplementary->search(typed, cost, taps, broad ? funding : std::nullopt));
    if (personal) append(mutableWords, personal->search(typed, cost, taps, broad ? funding : std::nullopt));
    std::vector<ChannelCandidate> fixed;
    if (packed) fixed = boosted(packed->search(typed, cost, taps, funding, cancel));
    else if (base) {
        fixed = base->search(typed, cost, taps, funding);
        if (!broad) fixed = boosted(std::move(fixed)); // legacy broad fallback has no boosts
    }
    if (broad) { append(fixed, mutableWords); return fixed; }
    if (!packed) { append(fixed, mutableWords); return fixed; }
    append(mutableWords, fixed); return mutableWords;
}
std::vector<ChannelCandidate> GenerationLexicon::completions(std::string_view prefix, std::size_t limit) const {
    std::vector<ChannelCandidate> out;
    auto fixed = packed ? packed->completions(prefix, limit) : base ? base->completions(prefix, limit) : out;
    for (auto& word : fixed) if (auto count = boost(word.word))
        word.logFrequency = std::log(std::exp(word.logFrequency) + double(*count));
    // Preserve the façade's source order: base fallback, supplementary, personal, packed.
    if (!packed) append(out, fixed);
    if (supplementary) append(out, supplementary->completions(prefix, limit));
    if (personal) append(out, personal->completions(prefix, limit));
    if (packed) append(out, fixed);
    std::stable_sort(out.begin(), out.end(), [](const auto& a, const auto& b) { return a.logFrequency > b.logFrequency; });
    if (out.size() > limit) out.resize(limit);
    return out;
}
std::optional<std::string> GenerationLexicon::apostropheRestoration(std::string_view word) const {
    if (word.find('\'') != std::string_view::npos) return {};
    std::optional<std::string> best;
    std::uint32_t bestFrequency = 0;
    // Restoration historically checks only the packed corpus, then the closed synthesis list.
    if (packed) for (std::size_t i = 1; i < word.size(); ++i) {
        auto spelling = std::string(word.substr(0, i)) + "'" + std::string(word.substr(i));
        if (auto id = packed->wordID(spelling)) {
            auto frequency = packed->frequency(*id);
            if (!best || frequency > bestFrequency) { best = spelling; bestFrequency = frequency; }
        }
    }
    if (best) return best;
    static const std::unordered_set<std::string> sBases{"when", "where", "why", "how", "who", "what", "that",
        "there", "here", "it", "he", "she", "one", "everyone", "everybody", "everything", "someone", "somebody",
        "something", "anyone", "anybody", "anything", "nobody", "nothing"};
    static const std::unordered_set<std::string> ntBases{"must", "might", "need", "ought", "dare", "shall"};
    if (word.size() >= 3 && word.ends_with("s") && sBases.contains(std::string(word.substr(0, word.size() - 1))))
        return std::string(word.substr(0, word.size() - 1)) + "'s";
    if (word.size() >= 4 && word.ends_with("nt") && ntBases.contains(std::string(word.substr(0, word.size() - 2))))
        return std::string(word.substr(0, word.size() - 2)) + "n't";
    return {};
}

GeneratedCandidates generateCandidates(const GenerationLexicon& lexicon, std::string_view typed,
        std::span<const std::optional<TouchOffset>> taps, std::span<const ContextSuccessor> successors,
        std::optional<std::span<const WordFunding>> funding,
        std::optional<std::span<const ChannelCandidate>> retainedStatic, bool gruTier,
        const std::function<bool()>& cancel, std::span<const std::size_t> offsets) {
    GeneratedCandidates out;
    std::vector<std::size_t> asciiOffsets;
    if (offsets.empty()) { asciiOffsets.resize(typed.size() + 1); std::iota(asciiOffsets.begin(), asciiOffsets.end(), 0); offsets = asciiOffsets; }
    if (offsets.front() != 0 || offsets.back() != typed.size() || !std::is_sorted(offsets.begin(), offsets.end())) throw std::invalid_argument("invalid character boundaries");
    auto length = offsets.size() - 1;
    auto cancelled = [&] { if (cancel && cancel()) { out = {}; out.cancelled = true; return true; } return false; };
    if (typed.empty() || cancelled()) return out;
    auto normal = normalSearchCost(length);
    if (retainedStatic) {
        out.close.assign(retainedStatic->begin(), retainedStatic->end());
        if (lexicon.supplementary) append(out.close, lexicon.supplementary->search(typed, normal, taps));
        if (lexicon.personal) append(out.close, lexicon.personal->search(typed, normal, taps));
    } else out.close = lexicon.corrections(typed, normal, taps, {}, false, cancel);
    if (cancelled()) return out;
    const auto budget = normal * 2;
    std::vector<ChannelCandidate> injected;
    if (length >= 4) for (const auto& successor : successors) {
        const auto& word = successor.word;
        if (lexicon.isBlocked(word) || word.empty()) continue;
        auto difference = length > successor.characterCount ? length - successor.characterCount : successor.characterCount - length;
        if (difference > 3) continue;
        auto cost = injectedSpatialCost(typed, word, taps);
        if (cost <= budget) injected.push_back({word, cost, lexicon.logFrequency(word).value_or(0)});
        else if (length >= 8 && (typed.substr(0, offsets[1]) == (successor.first.empty() ? word.substr(0, 1) : successor.first) || typed.substr(offsets[length - 1]) == (successor.last.empty() ? word.substr(word.size() - 1) : successor.last)))
            injected.push_back({word, budget, lexicon.logFrequency(word).value_or(0)});
    }
    out.completions = lexicon.completions(typed, 24);
    auto closest = std::numeric_limits<double>::infinity();
    for (const auto& word : out.close) closest = std::min(closest, word.cost);
    const bool recover = length >= 6 && !lexicon.contains(typed) && out.completions.empty() &&
        (length >= 8 || out.close.empty() || closest > 0.65);
    if (recover) {
        out.broad = lexicon.corrections(typed, budget, taps, funding, true, cancel);
        std::stable_sort(out.broad.begin(), out.broad.end(), [](const auto& a, const auto& b) {
            auto lhs = a.cost - 0.12 * a.logFrequency, rhs = b.cost - 0.12 * b.logFrequency;
            return lhs == rhs ? a.word < b.word : lhs < rhs;
        });
        if (!gruTier && out.broad.size() > 24) out.broad.resize(24);
    }
    if (cancelled()) return out;
    const auto ceiling = closest <= normal ? closest + 1.6 : std::numeric_limits<double>::infinity();
    std::erase_if(out.broad, [&](const auto& word) { return word.cost > ceiling; });
    std::unordered_set<std::string> seen;
    for (const auto& word : out.close) seen.insert(word.word);
    for (const auto& word : out.broad) seen.insert(word.word);
    for (const auto& word : injected) if (!seen.contains(word.word) && word.cost <= ceiling) out.injected.push_back(word);
    for (const auto& word : out.close) if (out.completions.empty() ? word.cost <= 1.25 : word.word.starts_with(typed))
        out.displayCorrections.push_back(word);
    if (out.completions.empty()) { append(out.displayCorrections, out.broad); append(out.displayCorrections, out.injected); }
    if (length >= 2) if (auto restored = lexicon.apostropheRestoration(typed))
        if (std::none_of(out.displayCorrections.begin(), out.displayCorrections.end(), [&](const auto& c) { return c.word == *restored; }))
            out.displayCorrections.push_back({*restored, 0.5, lexicon.logFrequency(*restored).value_or(0)});
    if (length >= 4) {
        auto strength = -std::numeric_limits<double>::infinity();
        auto consider = [&](std::string_view a, std::string_view b, std::size_t aLength, std::size_t bLength, double cost) {
            if (!(aLength >= 2 || a == "a" || a == "i") || !(bLength >= 2 || b == "a" || b == "i") ||
                !lexicon.contains(a) || !lexicon.contains(b) || lexicon.isBlocked(std::string(a)) ||
                lexicon.isBlocked(std::string(b))) return;
            auto fa = lexicon.logFrequency(a), fb = lexicon.logFrequency(b);
            if (!fa || !fb) return;
            auto frequency = std::min(*fa, *fb), score = frequency - cost;
            if (score > strength) { strength = score; out.split = {std::string(a) + " " + std::string(b), cost, frequency}; }
        };
        for (std::size_t i = 1; i < length; ++i) {
            consider(typed.substr(0, offsets[i]), typed.substr(offsets[i]), i, length - i, 1.1);
            if (offsets[i + 1] - offsets[i] == 1 && std::string_view("cvbnm").find(typed[offsets[i]]) != std::string_view::npos && i + 1 < length)
                consider(typed.substr(0, offsets[i]), typed.substr(offsets[i + 1]), i, length - i - 1, 0.72);
        }
    }
    return out;
}
} // namespace kb
