#include "MarisaLexicon.hpp"
#include <algorithm>
#include <cmath>
#include <fstream>
#include <limits>
#include <stdexcept>
#include <unordered_map>

namespace kb::experimental {
namespace {
void write32(std::ostream& out, std::uint32_t v) {
    for (unsigned shift = 0; shift < 32; shift += 8) out.put(char(v >> shift));
}
std::uint32_t read32(std::istream& in) {
    std::uint32_t v = 0;
    for (unsigned shift = 0; shift < 32; shift += 8) {
        int c = in.get();
        if (c == EOF) throw std::invalid_argument("truncated MARISA ID map");
        v |= std::uint32_t(c) << shift;
    }
    return v;
}
double logFrequency(const PackedLexicon& corpus, std::uint32_t id) {
    return std::log(double(std::max(corpus.frequency(id), 1u)) + 1);
}
}
void MarisaLexicon::build(const PackedLexicon& corpus, const std::string& path) {
    marisa::Keyset keys;
    for (std::uint32_t id = 0; id < corpus.wordCount(); ++id) {
        const auto word = corpus.word(id);
        if (word.empty()) throw std::invalid_argument("empty MARISA vocabulary word");
        keys.push_back(word.data(), word.size());
    }
    marisa::Trie trie;
    // Lexical enumeration matches the packed trie's label-sorted DFS order.
    trie.build(keys, MARISA_LABEL_ORDER);
    if (trie.num_keys() != corpus.wordCount()) throw std::invalid_argument("duplicate vocabulary");
    std::vector<std::uint32_t> ids(keys.size());
    for (std::uint32_t id = 0; id < keys.size(); ++id) ids.at(keys[id].id()) = id;
    trie.save(path.c_str());
    std::ofstream out(path + ".ids", std::ios::binary | std::ios::trunc);
    write32(out, 0x31494d4b); // KMI1, little endian
    write32(out, corpus.wordCount());
    for (auto id : ids) write32(out, id);
    if (!out) throw std::runtime_error("cannot write MARISA ID map");
}
MarisaLexicon::MarisaLexicon(const PackedLexicon& corpus, const std::string& path) : corpus_(corpus) {
    trie_.mmap(path.c_str());
    if (trie_.node_order() != MARISA_LABEL_ORDER) throw std::invalid_argument("MARISA requires lexical order");
    std::ifstream in(path + ".ids", std::ios::binary);
    if (read32(in) != 0x31494d4b || read32(in) != corpus.wordCount() ||
        trie_.num_keys() != corpus.wordCount()) throw std::invalid_argument("MARISA vocabulary mismatch");
    vocabularyIDs_.resize(corpus.wordCount());
    std::vector<bool> seen(corpus.wordCount());
    marisa::Agent agent;
    for (std::size_t key = 0; key < vocabularyIDs_.size(); ++key) {
        auto id = read32(in);
        if (id >= corpus.wordCount() || seen[id]) throw std::invalid_argument("invalid MARISA vocabulary ID");
        seen[id] = true;
        agent.set_query(key); trie_.reverse_lookup(agent);
        if (std::string_view(agent.key().ptr(), agent.key().length()) != corpus.word(id))
            throw std::invalid_argument("stale MARISA vocabulary ID map");
        vocabularyIDs_[key] = id;
    }
    if (in.peek() != EOF) throw std::invalid_argument("trailing MARISA ID data");
}
std::optional<std::uint32_t> MarisaLexicon::wordID(std::string_view word) const {
    marisa::Agent agent; agent.set_query(word.data(), word.size());
    if (!trie_.lookup(agent)) return {};
    return vocabularyIDs_.at(agent.key().id());
}
bool MarisaLexicon::hasPrefix(std::string_view prefix) const {
    marisa::Agent agent; agent.set_query(prefix.data(), prefix.size());
    return trie_.predictive_search(agent);
}
std::vector<ChannelCandidate> MarisaLexicon::completions(std::string_view prefix, std::size_t limit) const {
    marisa::Agent agent; agent.set_query(prefix.data(), prefix.size());
    std::vector<ChannelCandidate> out;
    // Exact frequency top-k; lexical ties are deterministic in this prototype.
    // Shipping packed completion uses heap traversal ties, so this method is not
    // enabled in production. Whole-prefix enumeration is measured separately.
    if (!limit) return out;
    while (trie_.predictive_search(agent)) {
        auto id = vocabularyIDs_.at(agent.key().id());
        out.push_back({std::string(corpus_.word(id)), 0, logFrequency(corpus_, id)});
    }
    std::stable_sort(out.begin(), out.end(), [](const auto& a, const auto& b) {
        return a.logFrequency > b.logFrequency;
    });
    if (out.size() > limit) out.resize(limit);
    return out;
}
std::vector<ChannelCandidate> MarisaLexicon::search(std::string_view typed, double maxCost,
    std::span<const std::optional<TouchOffset>> taps,
    std::optional<std::span<const WordFunding>> funding,
    const std::function<bool()>& shouldCancel) const {
    if (typed.empty()) return {};
    if (!std::isfinite(maxCost) || maxCost < 0) throw std::invalid_argument("invalid search radius");
    struct Prior { double prefix = 0, terminal = 0; };
    std::unordered_map<std::string, Prior> priors;
    if (funding) for (const auto& entry : *funding) {
        if (!std::isfinite(entry.bonus) || entry.bonus <= 0 || entry.bonus > 1.6)
            throw std::invalid_argument("invalid search funding");
        for (std::size_t length = 1; length <= entry.word.size(); ++length) {
            auto& prior = priors[entry.word.substr(0, length)];
            prior.prefix = std::max(prior.prefix, entry.bonus);
            if (length == entry.word.size()) prior.terminal = std::max(prior.terminal, entry.bonus);
        }
    }
    const double extra = (maxCost + (funding ? 1.6 : 0)) / deletionCost;
    if (extra >= double(std::numeric_limits<std::size_t>::max() / 2))
        throw std::length_error("search depth overflow");
    const auto allowance = std::size_t(extra) + 2;
    if (typed.size() > SIZE_MAX - allowance - 1) throw std::length_error("search depth overflow");
    const auto n = typed.size(), maxDepth = n + allowance;
    if (maxDepth + 1 > SIZE_MAX / (n + 1)) throw std::length_error("search DP overflow");
    std::vector<double> dp((maxDepth + 1) * (n + 1));
    for (std::size_t i = 0; i <= n; ++i) dp[i] = double(i) * insertionCost;
    std::vector<ChannelCandidate> out;
    std::string path, blocked;
    double finalCost = 0;
    std::size_t visited = 0;
    marisa::Agent agent; agent.set_query("", 0);
    // Public MARISA exposes whole-key enumeration, not child cursors. Reuse DP
    // rows for common prefixes and skip DP below pruned prefixes; enumeration
    // still decodes all keys. This is an intentional, measured prototype limit.
    while (trie_.predictive_search(agent)) {
        if ((++visited & 127) == 0 && shouldCancel && shouldCancel()) return {};
        const std::string_view word(agent.key().ptr(), agent.key().length());
        if (!blocked.empty() && word.starts_with(blocked)) continue;
        blocked.clear();
        std::size_t common = 0;
        while (common < std::min(path.size(), word.size()) && path[common] == word[common]) ++common;
        path.resize(common);
        const auto penalty = firstLetterPenalty(n, std::uint8_t(word.front()), std::uint8_t(typed.front()));
        bool terminalReached = true;
        for (std::size_t index = common; index < word.size(); ++index) {
            const auto depth = index + 1;
            if (depth > maxDepth) { blocked = std::string(word.substr(0, depth)); terminalReached = false; break; }
            const auto letter = std::uint8_t(word[index]);
            const auto base = depth * (n + 1), previous = base - (n + 1);
            const auto skip = letter == apostrophe ? apostropheSkipCost : deletionCost;
            double rowMin = dp[previous] + skip; dp[base] = rowMin;
            for (std::size_t col = 1; col <= n; ++col) {
                double value = std::min(dp[base + col - 1] + insertionCost,
                    std::min(dp[previous + col] + skip, dp[previous + col - 1] +
                        substitutionCost(letter, std::uint8_t(typed[col - 1]), taps.size() == n ? taps[col - 1] : std::nullopt)));
                if (depth >= 2 && col >= 2 && letter == std::uint8_t(typed[col - 2]) && word[index - 1] == typed[col - 1])
                    value = std::min(value, dp[previous - (n + 1) + col - 2] + transpositionCost);
                dp[base + col] = value; rowMin = std::min(rowMin, value);
            }
            path.push_back(char(letter));
            const auto prior = priors.find(path);
            const auto bonus = prior == priors.end() ? 0 : prior->second.prefix;
            finalCost = dp[base + n] + penalty;
            if (rowMin + penalty - bonus > maxCost) {
                blocked = path;
                // Packed traversal tests this terminal before pruning children.
                terminalReached = depth == word.size();
                break;
            }
        }
        if (terminalReached) {
            const auto prior = priors.find(std::string(word));
            const double terminal = prior == priors.end() ? 0 : prior->second.terminal;
            if (finalCost - terminal <= maxCost) {
                auto id = vocabularyIDs_.at(agent.key().id());
                out.push_back({std::string(corpus_.word(id)), finalCost, logFrequency(corpus_, id)});
            }
        }
    }
    return out;
}
}
