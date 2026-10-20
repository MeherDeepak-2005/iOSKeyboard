#include "../include/IncrementalSearch.hpp"
#include <algorithm>
#include <array>
#include <limits>
#include <stdexcept>
#include <utility>
namespace kb {
IncrementalSeedSet::IncrementalSeedSet(std::vector<LexiconSeed> seeds) : ownedSeeds_(std::move(seeds)) {
    seeds_.reserve(ownedSeeds_.size());
    for (const auto& seed : ownedSeeds_)
        seeds_.push_back({seed.word, seed.spelling, seed.logFrequency});
    prepareOffsets();
}
IncrementalSeedSet::IncrementalSeedSet(BorrowedSeedViews seeds) : seeds_(std::move(seeds.entries)) {
    prepareOffsets();
}
void IncrementalSeedSet::prepareOffsets() {
    offsets_.reserve(seeds_.size());
    for (const auto& seed : seeds_) {
        if (seed.spelling.size() >= std::numeric_limits<std::size_t>::max() - cells_)
            throw std::length_error("incremental DP size overflow");
        offsets_.push_back(cells_); cells_ += seed.spelling.size() + 1;
    }
}
IncrementalSearch::IncrementalSearch(std::vector<LexiconSeed> seeds)
    : IncrementalSearch(std::make_shared<const IncrementalSeedSet>(std::move(seeds))) {}
IncrementalSearch::IncrementalSearch(std::shared_ptr<const IncrementalSeedSet> seeds) : seedSet_(std::move(seeds)) {
    if (!seedSet_) throw std::invalid_argument("missing incremental seed set");
    auto cells = seedSet_->cellCount();
    previous_.resize(cells); previousPrevious_.resize(cells); scratch_.resize(cells);
    resetRows();
}
void IncrementalSearch::resetRows() {
    const auto seeds_ = seedSet_->seeds();
    const auto offsets_ = seedSet_->offsets();
    for (std::size_t index = 0; index < seeds_.size(); ++index) {
        const auto& spelling = seeds_[index].spelling;
        auto offset = offsets_[index]; previous_[offset] = 0;
        for (std::size_t column = 1; column <= spelling.size(); ++column) {
            auto skip = std::uint8_t(spelling[column - 1]) == apostrophe ? apostropheSkipCost : deletionCost;
            previous_[offset + column] = previous_[offset + column - 1] + skip;
        }
    }
}
bool IncrementalSearch::advanceNormalized(std::string_view word, std::span<const std::optional<TouchOffset>> taps) {
    if (word.empty() || !std::all_of(word.begin(), word.end(), [](unsigned char c) {
        return (c >= 'a' && c <= 'z') || c == apostrophe;
    })) return false; // Invalid input must leave the retained state unchanged.
    const bool hasTaps = taps.size() == word.size();
    // The rotating buffers already retain columns n, n-1 and n-2. Reuse them
    // for one backspace instead of rebuilding every seeded word from column 0.
    // A second deletion needs n-3, so it takes the established rebuild path.
    // Rebuild also when the caller changes any surviving tap: deletion previously
    // recomputed that prefix using the newly supplied touch evidence.
    bool sameTaps = canRollback_ && word.size() + 1 == typed_.size() && typed_.starts_with(word);
    if (sameTaps) for (std::size_t i = 0; i < word.size(); ++i) {
        const auto tap = hasTaps ? taps[i] : std::nullopt;
        const auto old = appliedTaps_[i];
        if (tap.has_value() != old.has_value() || (tap && (tap->dx != old->dx || tap->dy != old->dy))) {
            sameTaps = false; break;
        }
    }
    if (sameTaps) {
        previous_.swap(previousPrevious_);
        previousPrevious_.swap(scratch_);
        typed_.pop_back(); appliedTaps_.pop_back(); canRollback_ = false;
        return true;
    }
    if (word.size() < typed_.size() || !word.starts_with(typed_)) {
        resetRows(); typed_.clear(); appliedTaps_.clear(); canRollback_ = false;
    }
    for (std::size_t index = typed_.size(); index < word.size(); ++index)
        append(std::uint8_t(word[index]), hasTaps ? taps[index] : std::nullopt);
    return typed_ == word;
}
void IncrementalSearch::append(std::uint8_t byte, std::optional<TouchOffset> tap) {
    const auto seeds_ = seedSet_->seeds();
    const auto offsets_ = seedSet_->offsets();
    auto typedIndex = typed_.size() + 1;
    // Geometry depends only on the candidate byte and this typed tap, not on
    // the seed or DP cell. Keep the original Double formula and operation order.
    std::array<double, 256> substitutions;
    for (std::size_t candidate = 0; candidate < substitutions.size(); ++candidate)
        substitutions[candidate] = substitutionCost(std::uint8_t(candidate), byte, tap);
    for (std::size_t index = 0; index < seeds_.size(); ++index) {
        const auto& spelling = seeds_[index].spelling;
        auto offset = offsets_[index]; scratch_[offset] = double(typedIndex) * insertionCost;
        for (std::size_t column = 1; column <= spelling.size(); ++column) {
            auto candidate = std::uint8_t(spelling[column - 1]);
            auto skip = candidate == apostrophe ? apostropheSkipCost : deletionCost;
            auto insertion = previous_[offset + column] + insertionCost;
            auto deletion = scratch_[offset + column - 1] + skip;
            auto substitution = previous_[offset + column - 1] + substitutions[candidate];
            auto value = std::min(insertion, std::min(deletion, substitution));
            if (typedIndex >= 2 && column >= 2 && candidate == std::uint8_t(typed_[typedIndex - 2]) &&
                std::uint8_t(spelling[column - 2]) == byte)
                value = std::min(value, previousPrevious_[offset + column - 2] + transpositionCost);
            scratch_[offset + column] = value;
        }
    }
    previousPrevious_.swap(previous_); previous_.swap(scratch_); typed_.push_back(static_cast<char>(byte));
    appliedTaps_.push_back(tap); canRollback_ = typed_.size() >= 2;
}
std::vector<ChannelCandidate> IncrementalSearch::candidates(double maxCost) const {
    const auto seeds_ = seedSet_->seeds();
    const auto offsets_ = seedSet_->offsets();
    std::vector<ChannelCandidate> result;
    if (typed_.empty()) return result;
    result.reserve(std::min<std::size_t>(128, seeds_.size()));
    for (std::size_t index = 0; index < seeds_.size(); ++index) {
        const auto& seed = seeds_[index];
        if (seed.spelling.empty()) continue;
        auto penalty = firstLetterPenalty(typed_.size(), std::uint8_t(seed.spelling.front()), std::uint8_t(typed_.front()));
        auto cost = previous_[offsets_[index] + seed.spelling.size()] + penalty;
        if (cost <= maxCost) result.push_back({std::string(seed.word), cost, seed.logFrequency});
    }
    return result;
}
} // namespace kb
