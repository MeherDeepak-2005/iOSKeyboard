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
#include <unordered_map>
#include <mutex>
#include <array>
#include "SpatialModel.hpp"

namespace kb {
class IncrementalSeedSet;
struct Continuation { std::int32_t word; std::uint32_t count; };
struct Continuations { std::uint32_t total; std::vector<Continuation> entries; };
struct TrigramContext { std::int32_t first, second; };
struct ChannelCandidate;
class MutableTrie;
struct WordFunding { std::string word; double bonus; };
struct WordFrequencyBoost { std::string word; std::uint32_t count; };

// Immutable borrowed view. The caller must retain the backing bytes for this object's
// entire lifetime. No vocabulary bytes are copied; returned string_views share them.
class PackedLexicon final {
public:
    explicit PackedLexicon(std::span<const std::byte> bytes);
    std::uint32_t version() const noexcept { return version_; }
    std::uint32_t wordCount() const noexcept { return words_; }
    struct TextMetadata { std::int32_t id; std::size_t characters; std::optional<std::uint8_t> first, last; };
    std::vector<std::int32_t> textMetadataIDs() const;
    void installTextMetadata(std::span<const TextMetadata> metadata) const;
    // Safety-blocked words as a word-ID bitset, installed once at load and before any
    // search. search, completions, incrementalSeeds and anchorWords never emit them, so
    // they are excluded during candidate generation (traversal still passes through them:
    // a blocked word can prefix a clean one). Terms not in the dictionary are ignored.
    void installBlocked(std::span<const std::string> terms) const;
    bool blocked(std::uint32_t id) const noexcept { return id < words_ && !blocked_.empty() && (blocked_[id >> 6] >> (id & 63) & 1); }
    std::size_t blockedCount() const noexcept { return blockedCount_; }
    // The blocked dictionary words alone, searched once per keystroke for the closest blocked
    // match's cost (never a candidate). Null until installBlocked.
    const MutableTrie* blockedTrie() const noexcept { return blockedTrie_.get(); }
    std::size_t characterCount(std::string_view word) const;
    void warmAnchors() const;
    std::vector<std::string> anchorWords(std::span<const std::uint8_t> first, std::span<const std::uint8_t> last, std::size_t perBucket) const;
    struct TrieNodeRecord { std::uint8_t label; std::uint32_t firstChild, childCount, maxFrequency; std::optional<std::int32_t> wordID; };
    bool hasTrie() const noexcept { return nodes_ > 0; }
    TrieNodeRecord trieRecord(std::size_t node) const;
    // The trie as stored, for readers that walk it in place instead of copying it:
    // trieNodeSize() bytes per node - label, child count, first child (32-bit), word ID
    // (16-bit in v5, else 32-bit; all ones = none), subtree max frequency - little-endian.
    const std::byte* trieData() const noexcept { return bytes_.data() + trie_; }
    std::size_t trieNodeSize() const noexcept { return nodeSize_; }
    std::size_t trieNodeCount() const noexcept { return nodes_; }
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
    // Same root gate, vocabulary-ID order, cap and log-frequency as Swift. maxCost is the
    // search radius the seeds must cover (default: words of 8+ letters).
    // A null result means unsupported input/no trie/cap overflow/empty word;
    // an empty nonnull set is valid. Caller retains backing for all sessions.
    std::shared_ptr<const IncrementalSeedSet> incrementalSeeds(
        std::uint8_t typedFirst, std::optional<TouchOffset> firstTap = {},
        std::size_t stateCap = 24'000,
        std::span<const WordFrequencyBoost> boosts = {}, std::uint8_t typedSecond = 0,
        double maxCost = 3.6) const;
    // missingFirstOnly limits the search to candidates whose first letter the user dropped
    // (one extra leading letter, then the typed word: bove -> above): at most 26 descents.
    // The full search (missingFirstOnly false) never emits that shape, and the retained
    // incremental search seeds only by the typed first letters, so this pass is their only source.
    // roots, when not empty, limits the search to candidates starting with one of those letters.
    std::vector<ChannelCandidate> search(std::string_view typed, double maxCost,
        std::span<const std::optional<TouchOffset>> taps = {},
        std::optional<std::span<const WordFunding>> funding = {},
        const std::function<bool()>& shouldCancel = {}, bool missingFirstOnly = false,
        std::span<const std::uint8_t> roots = {}) const;
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
    mutable std::once_flag metadataOnce_, anchorsOnce_, seedIndexOnce_, blockedOnce_;
    mutable std::vector<std::uint64_t> blocked_;
    mutable std::size_t blockedCount_ = 0;
    mutable std::shared_ptr<const MutableTrie> blockedTrie_;
    mutable std::array<std::vector<std::uint32_t>, 256> seedIDs_;
    mutable bool emptySeedWord_ = false;
    mutable std::unordered_map<std::int32_t, TextMetadata> textMetadata_;
    mutable std::unordered_map<std::uint16_t, std::vector<std::int32_t>> anchors_;
    std::optional<std::size_t> trieNode(std::string_view prefix) const;
};
} // namespace kb
