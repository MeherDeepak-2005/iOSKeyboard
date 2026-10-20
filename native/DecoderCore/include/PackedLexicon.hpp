#pragma once
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string_view>
#include <string>
#include <vector>
#include <memory>
#include <functional>
#include "SpatialModel.hpp"

namespace kb {
class IncrementalSeedSet;
struct Continuation { std::int32_t word; std::uint32_t count; };
struct Continuations { std::uint32_t total; std::vector<Continuation> entries; };
struct TrigramContext { std::int32_t first, second; };
struct ChannelCandidate;
struct WordFunding { std::string word; double bonus; };
struct WordFrequencyBoost { std::string word; std::uint32_t count; };

// Immutable borrowed view. The caller must retain the backing bytes for this object's
// entire lifetime. No vocabulary bytes are copied; returned string_views share them.
class PackedLexicon final {
public:
    explicit PackedLexicon(std::span<const std::byte> bytes);
    std::uint32_t version() const noexcept { return version_; }
    std::uint32_t wordCount() const noexcept { return words_; }
    const void* backingAddress() const noexcept { return bytes_.data(); }
    std::string_view word(std::uint32_t id) const;
    std::uint32_t frequency(std::uint32_t id) const;
    std::optional<std::int32_t> wordID(std::string_view word) const;
    std::vector<ChannelCandidate> completions(std::string_view prefix, std::size_t limit) const;
    std::vector<std::int32_t> starterIDs(std::size_t limit) const;
    std::optional<Continuations> bigrams(std::int32_t context,
                                       std::size_t limit = SIZE_MAX) const;
    std::optional<Continuations> trigrams(std::int32_t first, std::int32_t second,
                                        std::size_t limit = SIZE_MAX) const;
    // Validation/parity enumeration only; not a callback into a Swift hot path.
    std::vector<TrigramContext> trigramContexts() const;
    // Same root gate, vocabulary-ID order, cap and log-frequency as Swift.
    // A null result means unsupported input/no trie/cap overflow/empty word;
    // an empty nonnull set is valid. Caller retains backing for all sessions.
    std::shared_ptr<const IncrementalSeedSet> incrementalSeeds(
        std::uint8_t typedFirst, std::optional<TouchOffset> firstTap = {},
        std::size_t stateCap = 24'000,
        std::span<const WordFrequencyBoost> boosts = {}) const;
    std::vector<ChannelCandidate> search(std::string_view typed, double maxCost,
        std::span<const std::optional<TouchOffset>> taps = {},
        std::optional<std::span<const WordFunding>> funding = {},
        const std::function<bool()>& shouldCancel = {}) const;
private:
    struct Range { std::uint32_t total, start, count; };
    std::span<const std::byte> bytes_;
    std::uint32_t version_, words_, biBuckets_, biEntries_, triBuckets_, triEntries_, nodes_, starters_;
    std::size_t frequencies_, offsets_, biHash_, biData_, triHash_, triData_, trie_, starterData_, blob_;
    std::size_t nodeSize_, entrySize_, starterSize_;
    std::uint16_t u16(std::size_t offset) const;
    std::uint32_t u32(std::size_t offset) const;
    std::uint32_t idAt(std::size_t offset) const;
    std::optional<Range> bigramRange(std::int32_t context) const;
    std::optional<Range> trigramRange(std::int32_t first, std::int32_t second) const;
    Continuations readRange(std::size_t base, Range range, std::size_t limit) const;
    void validateRange(Range range, std::uint32_t count) const;
    void validate();
    std::optional<std::size_t> trieNode(std::string_view prefix) const;
};
} // namespace kb
