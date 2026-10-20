#include "../include/Multiword.hpp"
#include <algorithm>
#include <cmath>
namespace kb {
std::string MultiwordHypothesis::phrase() const {
    std::string out; for (const auto& word : words) { if (!out.empty()) out += ' '; out += word; } return out;
}
MultiwordSearch::MultiwordSearch(GenerationLexicon lexicon, std::string typed, std::vector<std::optional<TouchOffset>> taps)
    : lexicon_(lexicon), typed_(std::move(typed)), taps_(std::move(taps)) {}
std::vector<MultiwordHypothesis> MultiwordSearch::expand(std::span<const MultiwordHypothesis> frontier, const std::function<bool()>& cancel) {
    if (typed_.size() < 4 || typed_.size() > 24 || !std::all_of(typed_.begin(), typed_.end(), [](unsigned char c) { return (c >= 'a' && c <= 'z') || c == apostrophe; })) return {};
    std::vector<MultiwordHypothesis> result;
    for (const auto& state : frontier) {
        if (state.words.size() >= 3 || state.offset >= typed_.size()) continue;
        for (auto end = state.offset + 1; end <= std::min(typed_.size(), state.offset + 16); ++end) {
            if (cancel && cancel()) return {};
            if (state.words.empty() && end == typed_.size()) continue;
            const auto key = state.offset * 25 + end;
            auto found = cache_.find(key);
            if (found == cache_.end()) {
                auto text = std::string_view(typed_).substr(state.offset, end - state.offset);
                auto taps = taps_.size() == typed_.size() ? std::span<const std::optional<TouchOffset>>(taps_).subspan(state.offset, end - state.offset) : std::span<const std::optional<TouchOffset>>();
                auto options = lexicon_.corrections(text, 1.8, taps, {}, false, cancel);
                std::erase_if(options, [&](const auto& word) { return lexicon_.isBlocked(word.word) || (lexicon_.characterCount(word.word) < 2 && word.word != "a" && word.word != "i") || word.cost > 1.8; });
                std::stable_sort(options.begin(), options.end(), [](const auto& a, const auto& b) {
                    auto lhs = -a.cost + 0.12 * a.logFrequency, rhs = -b.cost + 0.12 * b.logFrequency;
                    return lhs == rhs ? a.word < b.word : lhs > rhs;
                });
                if (options.size() > 8) options.resize(8); found = cache_.emplace(key, std::move(options)).first;
            }
            for (const auto& word : found->second) {
                auto add = [&](std::size_t offset, double boundaryCost) {
                    auto cost = state.cost + word.cost + boundaryCost;
                    if (cost > 4.8 || (offset != typed_.size() && state.words.size() + 1 >= 3)) return;
                    auto words = state.words; words.push_back(word.word);
                    result.push_back({offset, std::move(words), cost, std::min(state.logFrequency, word.logFrequency)});
                };
                add(end, end == typed_.size() ? 0 : 1.1);
                if (end + 1 < typed_.size() && std::string_view("cvbnm").find(typed_[end]) != std::string_view::npos) add(end + 1, 0.72);
            }
        }
    }
    std::vector<MultiwordHypothesis> unique; std::unordered_map<std::string, std::size_t> positions;
    for (auto& state : result) {
        auto key = std::to_string(state.offset) + ":" + state.phrase(); auto [found, inserted] = positions.emplace(key, unique.size());
        if (inserted) unique.push_back(std::move(state)); else if (state.cost < unique[found->second].cost) unique[found->second] = std::move(state);
    }
    std::stable_sort(unique.begin(), unique.end(), [](const auto& a, const auto& b) {
        auto lhs = a.phrase(), rhs = b.phrase(); return lhs == rhs ? a.offset < b.offset : lhs < rhs;
    }); return unique;
}
MultiwordPruned MultiwordSearch::prune(std::span<const MultiwordHypothesis> rows, std::span<const double> neural, std::span<const double> language) const {
    if (rows.size() != neural.size() || rows.size() != language.size()) throw std::invalid_argument("invalid phrase score shape");
    std::vector<std::pair<MultiwordHypothesis, double>> ranked;
    for (std::size_t i = 0; i < rows.size(); ++i) if (std::isfinite(neural[i])) {
        auto score = -rows[i].cost + 1.0 * (0.7 * neural[i] + (1 - 0.7) * language[i]) + 0.3 * frequencyTerm(rows[i].logFrequency, true);
        ranked.emplace_back(rows[i], score);
    }
    std::stable_sort(ranked.begin(), ranked.end(), [](const auto& a, const auto& b) { return a.second == b.second ? a.first.phrase() < b.first.phrase() : a.second > b.second; });
    MultiwordPruned out; std::unordered_map<std::size_t, std::size_t> counts;
    for (const auto& [state, score] : ranked) { (void)score;
        if (state.offset == typed_.size()) { if (state.words.size() >= 2) out.finished.push_back({state.phrase(), state.cost, state.logFrequency}); }
        else if (counts[state.offset] < 2) { ++counts[state.offset]; out.frontier.push_back(state); }
    } return out;
}
} // namespace kb
