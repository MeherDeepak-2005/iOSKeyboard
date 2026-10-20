#pragma once
#include "SpatialModel.hpp"
#include <span>
#include <memory>
#include <string>
#include <string_view>
#include <vector>
namespace kb {
struct LexiconSeed { std::string word, spelling; double logFrequency; };
struct ChannelCandidate { std::string word; double cost, logFrequency; };
struct LexiconSeedView { std::string_view word, spelling; double logFrequency; };
struct BorrowedSeedViews { std::vector<LexiconSeedView> entries; };

// Immutable, shared preparation. Mapped views borrow the caller's backing; owning
// snapshots retain strings internally. Sessions never copy words or offsets.
class IncrementalSeedSet final {
public:
    explicit IncrementalSeedSet(std::vector<LexiconSeed> seeds);
    explicit IncrementalSeedSet(BorrowedSeedViews seeds);
    // Views into owned strings make object copying unsafe. Move the shared_ptr,
    // rather than the object. All five ownership operations are explicit.
    ~IncrementalSeedSet() = default;
    IncrementalSeedSet(const IncrementalSeedSet&) = delete;
    IncrementalSeedSet& operator=(const IncrementalSeedSet&) = delete;
    IncrementalSeedSet(IncrementalSeedSet&&) = delete;
    IncrementalSeedSet& operator=(IncrementalSeedSet&&) = delete;
    std::span<const LexiconSeedView> seeds() const noexcept { return seeds_; }
    std::span<const std::size_t> offsets() const noexcept { return offsets_; }
    std::size_t cellCount() const noexcept { return cells_; }
private:
    std::vector<LexiconSeed> ownedSeeds_;
    std::vector<LexiconSeedView> seeds_;
    std::vector<std::size_t> offsets_;
    std::size_t cells_ = 0;
    void prepareOffsets();
};

// One owner/execution lane per session, matching the Swift engine's retained DP.
// Sessions share immutable seed metadata and own their DP buffers; mapped seed
// bytes remain borrowed from the bridge-retained corpus.
class IncrementalSearch final {
public:
    explicit IncrementalSearch(std::vector<LexiconSeed> seeds);
    explicit IncrementalSearch(std::shared_ptr<const IncrementalSeedSet> seeds);
    // A session has one execution lane. Prevent accidental large buffer copies;
    // transfer ownership through unique_ptr, not by moving the session object.
    ~IncrementalSearch() = default;
    IncrementalSearch(const IncrementalSearch&) = delete;
    IncrementalSearch& operator=(const IncrementalSearch&) = delete;
    IncrementalSearch(IncrementalSearch&&) = delete;
    IncrementalSearch& operator=(IncrementalSearch&&) = delete;
    void reset(std::shared_ptr<const IncrementalSeedSet> seeds);
    bool advanceNormalized(std::string_view word, std::span<const std::optional<TouchOffset>> taps = {});
    std::vector<ChannelCandidate> candidates(double maxCost) const;
    const std::string& typed() const noexcept { return typed_; }
    std::size_t seedCount() const noexcept { return seedSet_->seeds().size(); }
private:
    std::shared_ptr<const IncrementalSeedSet> seedSet_;
    std::vector<double> previous_, previousPrevious_, scratch_;
    std::string typed_;
    std::vector<std::optional<TouchOffset>> appliedTaps_;
    bool canRollback_ = false;
    void resetRows();
    void append(std::uint8_t byte, std::optional<TouchOffset> tap);
};
} // namespace kb
