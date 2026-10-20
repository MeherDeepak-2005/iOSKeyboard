#include "../include/PackedLexicon.hpp"
#include "../include/IncrementalSearch.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <unordered_map>
#include <limits>
#include <utility>
#include <stdexcept>

namespace kb {
std::optional<std::size_t> PackedLexicon::trieNode(std::string_view prefix) const {
    if (!nodes_) return {};
    std::size_t at = 0;
    for (std::uint8_t letter : prefix) {
        auto offset = trie_ + nodeSize_ * at;
        auto first = u32(offset + 2);
        auto count = std::to_integer<std::uint8_t>(bytes_[offset + 1]);
        std::size_t next = SIZE_MAX;
        for (std::size_t i = first; i < std::size_t(first) + count; ++i)
            if (std::to_integer<std::uint8_t>(bytes_[trie_ + nodeSize_ * i]) == letter) { next = i; break; }
        if (next == SIZE_MAX) return {};
        at = next;
    }
    return at;
}
std::optional<std::int32_t> PackedLexicon::wordID(std::string_view spelling) const {
    auto at = trieNode(spelling); if (!at) return {};
    auto id = version_ == 5 ? std::uint32_t(u16(trie_ + nodeSize_ * *at + 6)) : u32(trie_ + nodeSize_ * *at + 6);
    if (id == (version_ == 5 ? 0xffffu : 0xffffffffu)) return {};
    return static_cast<std::int32_t>(id);
}
std::vector<ChannelCandidate> PackedLexicon::completions(std::string_view prefix, std::size_t limit) const {
    auto start = trieNode(prefix); if (!start || !limit) return {};
    struct Entry { std::uint32_t priority; std::size_t node; std::int32_t wordID; };
    std::vector<Entry> heap;
    auto maxFrequency = [&](std::size_t at) { return u32(trie_ + nodeSize_ * at + (version_ == 5 ? 8 : 10)); };
    // Deliberately use the reference's heap comparisons. std::priority_queue has
    // different equal-priority behavior and changes tied completion ordering.
    auto push = [&](Entry e) {
        heap.push_back(e); auto c = heap.size() - 1;
        while (c > 0) {
            auto p = (c - 1) >> 1;
            if (heap[p].priority >= heap[c].priority) break;
            std::swap(heap[p], heap[c]); c = p;
        }
    };
    auto pop = [&] {
        auto top = heap.front(), last = heap.back(); heap.pop_back();
        if (!heap.empty()) {
            heap[0] = last; std::size_t p = 0;
            while (true) {
                auto l = 2 * p + 1, r = l + 1, m = p;
                if (l < heap.size() && heap[l].priority > heap[m].priority) m = l;
                if (r < heap.size() && heap[r].priority > heap[m].priority) m = r;
                if (m == p) break;
                std::swap(heap[p], heap[m]); p = m;
            }
        }
        return top;
    };
    std::vector<ChannelCandidate> out;
    push({maxFrequency(*start), *start, -1});
    while (!heap.empty() && out.size() < limit) {
        auto e = pop();
        if (e.node == SIZE_MAX) {
            out.push_back({std::string(word(e.wordID)), 0, std::log(double(std::max(frequency(e.wordID), 1u)) + 1)});
            continue;
        }
        auto offset = trie_ + nodeSize_ * e.node;
        auto id = version_ == 5 ? std::uint32_t(u16(offset + 6)) : u32(offset + 6);
        if (id != (version_ == 5 ? 0xffffu : 0xffffffffu)) push({frequency(id), SIZE_MAX, std::int32_t(id)});
        auto first = u32(offset + 2); auto count = std::to_integer<std::uint8_t>(bytes_[offset + 1]);
        for (std::size_t i = first; i < std::size_t(first) + count; ++i) push({maxFrequency(i), i, -1});
    }
    return out;
}
namespace {
constexpr std::uint32_t empty32 = 0xffffffff;
constexpr std::uint32_t empty16 = 0xffff;
void require(bool condition, const char* reason) {
    if (!condition) throw std::invalid_argument(reason);
}
std::uint64_t mix64(std::uint64_t value) {
    value ^= value >> 30; value *= 0xBF58476D1CE4E5B9ULL;
    value ^= value >> 27; value *= 0x94D049BB133111EBULL;
    return value ^ (value >> 31);
}
}
std::uint16_t PackedLexicon::u16(std::size_t offset) const {
    require(offset <= bytes_.size() && bytes_.size() - offset >= 2, "truncated UInt16");
    return std::to_integer<std::uint16_t>(bytes_[offset]) |
           (std::to_integer<std::uint16_t>(bytes_[offset + 1]) << 8);
}
std::uint32_t PackedLexicon::u32(std::size_t offset) const {
    require(offset <= bytes_.size() && bytes_.size() - offset >= 4, "truncated UInt32");
    return std::to_integer<std::uint32_t>(bytes_[offset]) |
           (std::to_integer<std::uint32_t>(bytes_[offset + 1]) << 8) |
           (std::to_integer<std::uint32_t>(bytes_[offset + 2]) << 16) |
           (std::to_integer<std::uint32_t>(bytes_[offset + 3]) << 24);
}
std::uint32_t PackedLexicon::idAt(std::size_t offset) const {
    return version_ == 5 ? u16(offset) : u32(offset);
}
PackedLexicon::PackedLexicon(std::span<const std::byte> bytes) : bytes_(bytes) {
    require(bytes.size() >= 28, "truncated header");
    require(u32(0) == 0x4B424C4D, "invalid KBLM magic");
    version_ = u32(4);
    require(version_ >= 2 && version_ <= 6, "unsupported KBLM version");
    const std::size_t header = version_ >= 4 ? 36 : version_ >= 3 ? 32 : 28;
    require(bytes.size() >= header, "truncated versioned header");
    words_ = u32(8); biBuckets_ = u32(12); biEntries_ = u32(16);
    triBuckets_ = u32(20); triEntries_ = u32(24);
    nodes_ = version_ >= 3 ? u32(28) : 0;
    starters_ = version_ >= 4 ? u32(32) : 0;
    require(words_ <= static_cast<std::uint32_t>(INT32_MAX), "word IDs exceed Int32");
    require(version_ != 5 || words_ < empty16, "v5 word IDs exceed UInt16");
    nodeSize_ = version_ == 5 ? 12 : 14;
    entrySize_ = starterSize_ = version_ == 5 ? 6 : 8;
    // Add each section only after checked multiplication/subtraction. Corrupt counts
    // must not wrap offsets, even on a platform with a smaller size_t.
    std::size_t cursor = header;
    auto section = [&](std::size_t width, std::size_t count) {
        require(count <= (bytes.size() - cursor) / width, "section exceeds backing");
        auto start = cursor; cursor += width * count; return start;
    };
    frequencies_ = section(4, words_);
    offsets_ = section(4, std::size_t(words_) + 1);
    biHash_ = section(version_ == 5 ? 12 : 16, biBuckets_);
    biData_ = section(entrySize_, biEntries_);
    triHash_ = section(version_ == 5 ? 12 : 20, triBuckets_);
    triData_ = section(entrySize_, triEntries_);
    trie_ = section(nodeSize_, nodes_);
    starterData_ = section(starterSize_, starters_);
    blob_ = cursor;
    validate();
}
void PackedLexicon::validateRange(Range range, std::uint32_t count) const {
    require(range.start <= count && range.count <= count - range.start,
            "continuation range exceeds section");
}
void PackedLexicon::validate() {
    std::uint32_t previous = 0;
    for (std::size_t i = 0; i <= words_; ++i) {
        auto end = u32(offsets_ + 4 * i);
        require(end >= previous && end <= bytes_.size() - blob_, "invalid word offsets");
        previous = end;
    }
    for (auto [base, count] : {std::pair{biData_, biEntries_}, std::pair{triData_, triEntries_},
                               std::pair{starterData_, starters_}}) {
        for (std::size_t i = 0; i < count; ++i)
            require(idAt(base + entrySize_ * i) < words_, "invalid continuation/starter ID");
    }
    if (version_ < 5) {
        for (auto count : {biBuckets_, triBuckets_})
            require(count == 0 || (count & (count - 1)) == 0, "hash table size is not a power of two");
    }
    std::uint32_t lastKey = 0;
    for (std::size_t i = 0; i < biBuckets_; ++i) {
        auto base = biHash_ + (version_ == 5 ? 12 : 16) * i;
        auto key = idAt(base);
        if (version_ < 5 && key == empty32) continue;
        require(key < words_, "invalid bigram context ID");
        if (version_ >= 5) {
            require(i == 0 || key > lastKey, "unsorted/duplicate bigram contexts");
            lastKey = key;
        }
        validateRange({u32(base + 4), u32(base + 8), version_ == 5 ? u16(base + 2) : u32(base + 12)}, biEntries_);
    }
    lastKey = 0;
    std::uint64_t lastWideKey = 0;
    for (std::size_t i = 0; i < triBuckets_; ++i) {
        auto base = triHash_ + (version_ == 5 ? 12 : 20) * i;
        auto key = u32(base);
        if (version_ < 5 && key == empty32) continue;
        if (version_ == 5) {
            require((key >> 16) < words_ && (key & empty16) < words_, "invalid trigram context ID");
            require(i == 0 || key > lastKey, "unsorted/duplicate trigram contexts");
            lastKey = key;
            auto start = u32(base + 8);
            auto end = i + 1 < triBuckets_ ? u32(base + 20) : triEntries_;
            require(end >= start, "reversed trigram range");
            validateRange({u32(base + 4), start, end - start}, triEntries_);
        } else {
            require(key < words_ && u32(base + 4) < words_, "invalid trigram context ID");
            if (version_ == 6) {
                const auto wideKey = (std::uint64_t(key) << 32) | u32(base + 4);
                require(i == 0 || wideKey > lastWideKey, "unsorted/duplicate trigram contexts");
                lastWideKey = wideKey;
            }
            validateRange({u32(base + 8), u32(base + 12), u32(base + 16)}, triEntries_);
        }
    }
    for (std::size_t i = 0; i < nodes_; ++i) {
        auto base = trie_ + nodeSize_ * i;
        auto count = std::to_integer<unsigned>(bytes_[base + 1]);
        auto first = u32(base + 2), id = idAt(base + 6);
        require(first <= nodes_ && count <= nodes_ - first, "invalid trie child range");
        require(count == 0 || first > i, "trie children must follow parent");
        require(id == (version_ == 5 ? empty16 : empty32) || id < words_, "invalid trie terminal ID");
    }
}
std::uint32_t PackedLexicon::frequency(std::uint32_t id) const {
    if (id >= words_) throw std::out_of_range("word ID");
    return u32(frequencies_ + 4 * id);
}
std::string_view PackedLexicon::word(std::uint32_t id) const {
    if (id >= words_) throw std::out_of_range("word ID");
    auto start = u32(offsets_ + 4 * id), end = u32(offsets_ + 4 * (std::size_t(id) + 1));
    return {reinterpret_cast<const char*>(bytes_.data() + blob_ + start), end - start};
}
std::shared_ptr<const IncrementalSeedSet> PackedLexicon::incrementalSeeds(
    std::uint8_t typedFirst, std::optional<TouchOffset> firstTap, std::size_t stateCap, std::span<const WordFrequencyBoost> boosts) const {
    if (!nodes_ || typedFirst < 'a' || typedFirst > 'z') return {};
    std::array<bool, 256> allowed{};
    auto first = u32(trie_ + 2);
    auto count = std::to_integer<unsigned>(bytes_[trie_ + 1]);
    auto penalty = firstLetterPenalty(8, 'z', typedFirst);
    for (std::size_t i = first; i < std::size_t(first) + count; ++i) {
        auto label = std::to_integer<std::uint8_t>(bytes_[trie_ + nodeSize_ * i]);
        if (label == typedFirst || penalty + substitutionCost(label, typedFirst, firstTap) <= 3.6)
            allowed[label] = true;
    }
    std::unordered_map<std::string_view, std::uint32_t> boostView;
    for (const auto& boost : boosts) {
        if (!boostView.emplace(boost.word, boost.count).second)
            throw std::invalid_argument("duplicate personalization boost");
    }
    BorrowedSeedViews seeds;
    seeds.entries.reserve(std::min<std::size_t>(stateCap, words_ / 3));
    for (std::uint32_t id = 0; id < words_; ++id) {
        auto spelling = word(id);
        if (spelling.empty()) return {}; // Swift checks this even for excluded roots.
        if (!allowed[static_cast<unsigned char>(spelling.front())]) continue;
        if (seeds.entries.size() >= stateCap) return {};
        double logFrequency = std::log(double(std::max(frequency(id), 1u)) + 1);
        if (auto boost = boostView.find(spelling); boost != boostView.end())
            logFrequency = std::log(std::exp(logFrequency) + double(boost->second));
        seeds.entries.push_back({spelling, spelling, logFrequency});
    }
    return std::make_shared<const IncrementalSeedSet>(std::move(seeds));
}
std::vector<ChannelCandidate> PackedLexicon::search(std::string_view typed, double maxCost,
        std::span<const std::optional<TouchOffset>> taps,
        std::optional<std::span<const WordFunding>> funding,
        const std::function<bool()>& shouldCancel) const {
    if (!nodes_ || typed.empty()) return {};
    if (!std::isfinite(maxCost) || maxCost < 0) throw std::invalid_argument("invalid search radius");
    struct Prior { std::vector<std::pair<std::uint8_t, std::size_t>> children; double bonus = 0, terminal = 0; };
    std::vector<Prior> priors(1);
    if (funding) for (const auto& entry : *funding) {
        if (!std::isfinite(entry.bonus) || entry.bonus <= 0 || entry.bonus > 1.6)
            throw std::invalid_argument("invalid search funding");
        std::size_t node = 0;
        for (unsigned char byte : entry.word) {
            std::size_t next = SIZE_MAX;
            for (const auto& child : priors[node].children) if (child.first == byte) { next = child.second; break; }
            if (next == SIZE_MAX) {
                next = priors.size(); priors[node].children.emplace_back(byte, next); priors.emplace_back();
            }
            priors[next].bonus = std::max(priors[next].bonus, entry.bonus); node = next;
        }
        priors[node].terminal = std::max(priors[node].terminal, entry.bonus);
    }
    auto priorChild = [&](std::size_t node, std::uint8_t byte) {
        if (node != SIZE_MAX) for (const auto& child : priors[node].children)
            if (child.first == byte) return child.second;
        return SIZE_MAX;
    };
    const auto extra = (maxCost + (funding ? 1.6 : 0)) / deletionCost;
    if (extra >= double(std::numeric_limits<std::size_t>::max() / 2))
        throw std::length_error("search depth overflow");
    const auto allowance = static_cast<std::size_t>(extra) + 2;
    if (typed.size() > SIZE_MAX - allowance - 1) throw std::length_error("search depth overflow");
    const auto n = typed.size(), maxDepth = n + allowance;
    if (maxDepth + 1 > SIZE_MAX / (n + 1)) throw std::length_error("search DP overflow");
    std::vector<double> dp((maxDepth + 1) * (n + 1));
    for (std::size_t i = 0; i <= n; ++i) dp[i] = double(i) * insertionCost;
    // Each candidate label sees the same substitution cost at a typed column.
    // Compute geometry once per column/label rather than once per visited cell.
    if (n > SIZE_MAX / 256) throw std::length_error("search substitution table overflow");
    std::vector<std::array<double, 256>> substitutions(n);
    std::array<bool, 256> substitutionReady{};
    std::vector<std::pair<std::uint32_t, double>> hits;
    std::size_t visits = 0; bool cancelled = false;
    auto byteAt = [&](std::size_t node, std::size_t offset) {
        return std::to_integer<std::uint8_t>(bytes_[trie_ + nodeSize_ * node + offset]);
    };
    auto visit = [&](auto&& self, std::size_t node, std::uint8_t letter, std::uint8_t previousLetter,
                     std::size_t depth, double firstPenalty, std::size_t prior) -> void {
        if (cancelled || depth > maxDepth) return;
        ++visits;
        if ((visits & 127) == 0 && shouldCancel && shouldCancel()) { cancelled = true; return; }
        if (!substitutionReady[letter]) {
            for (std::size_t column = 0; column < n; ++column)
                substitutions[column][letter] = substitutionCost(letter, std::uint8_t(typed[column]),
                    taps.size() == n ? taps[column] : std::nullopt);
            substitutionReady[letter] = true;
        }
        const auto base = depth * (n + 1), previous = base - (n + 1);
        const auto skip = letter == apostrophe ? apostropheSkipCost : deletionCost;
        double rowMin = dp[previous] + skip; dp[base] = rowMin;
        for (std::size_t column = 1; column <= n; ++column) {
            const double insertion = dp[base + column - 1] + insertionCost;
            const double deletion = dp[previous + column] + skip;
            double value = std::min(insertion, std::min(deletion,
                dp[previous + column - 1] + substitutions[column - 1][letter]));
            if (depth >= 2 && column >= 2 && letter == std::uint8_t(typed[column - 2]) &&
                previousLetter == std::uint8_t(typed[column - 1]))
                value = std::min(value, dp[previous - (n + 1) + column - 2] + transpositionCost);
            dp[base + column] = value; if (value < rowMin) rowMin = value;
        }
        auto offset = trie_ + nodeSize_ * node;
        std::uint32_t id = version_ == 5 ? u16(offset + 6) : u32(offset + 6);
        if (version_ == 5 && id == empty16) id = empty32;
        const double bonus = prior != SIZE_MAX ? priors[prior].bonus : 0;
        const double terminal = prior != SIZE_MAX ? priors[prior].terminal : 0;
        const double finalCost = dp[base + n] + firstPenalty;
        if (id != empty32 && finalCost - terminal <= maxCost) hits.emplace_back(id, finalCost);
        if (rowMin + firstPenalty - bonus <= maxCost) {
            const auto first = u32(offset + 2); const auto count = byteAt(node, 1);
            for (std::size_t child = first; child < std::size_t(first) + count; ++child) {
                const auto childByte = byteAt(child, 0);
                self(self, child, childByte, letter, depth + 1, firstPenalty, priorChild(prior, childByte));
            }
        }
    };
    const auto first = u32(trie_ + 2); const auto count = byteAt(0, 1);
    for (std::size_t node = first; node < std::size_t(first) + count; ++node) {
        const auto letter = byteAt(node, 0);
        visit(visit, node, letter, 0, 1, firstLetterPenalty(n, letter, std::uint8_t(typed.front())),
              priorChild(0, letter));
    }
    if (cancelled) return {};
    std::vector<ChannelCandidate> result; result.reserve(hits.size());
    for (const auto& [id, cost] : hits)
        result.push_back({std::string(word(id)), cost, std::log(double(std::max(frequency(id), 1u)) + 1)});
    return result;
}

std::vector<std::int32_t> PackedLexicon::starterIDs(std::size_t limit) const {
    std::vector<std::int32_t> out;
    for (std::size_t i = 0; i < std::min<std::size_t>(limit, starters_); ++i)
        out.push_back(static_cast<std::int32_t>(idAt(starterData_ + starterSize_ * i)));
    return out;
}
std::optional<PackedLexicon::Range> PackedLexicon::bigramRange(std::int32_t context) const {
    if (context < 0 || static_cast<std::uint32_t>(context) >= words_ || biBuckets_ == 0) return {};
    auto key = static_cast<std::uint32_t>(context);
    if (version_ >= 5) {
        const std::size_t width = version_ == 5 ? 12 : 16;
        std::size_t lower = 0, upper = biBuckets_;
        while (lower < upper) {
            auto mid = lower + (upper - lower) / 2;
            if (idAt(biHash_ + width * mid) < key) lower = mid + 1; else upper = mid;
        }
        if (lower == biBuckets_) return {};
        auto base = biHash_ + width * lower;
        if (idAt(base) != key) return {};
        return Range{u32(base + 4), u32(base + 8), version_ == 5 ? u16(base + 2) : u32(base + 12)};
    }
    auto mask = biBuckets_ - 1;
    auto bucket = mix64(key) & mask;
    for (std::uint32_t probes = 0; probes < biBuckets_; ++probes) {
        auto base = biHash_ + 16 * bucket;
        auto slot = u32(base);
        if (slot == empty32) return {};
        if (slot == key) return Range{u32(base + 4), u32(base + 8), u32(base + 12)};
        bucket = (bucket + 1) & mask;
    }
    return {};
}
std::optional<PackedLexicon::Range> PackedLexicon::trigramRange(std::int32_t first, std::int32_t second) const {
    if (first < 0 || second < 0 || static_cast<std::uint32_t>(first) >= words_ ||
        static_cast<std::uint32_t>(second) >= words_ || triBuckets_ == 0) return {};
    if (version_ == 6) {
        const auto key = (std::uint64_t(first) << 32) | std::uint32_t(second);
        std::size_t lower = 0, upper = triBuckets_;
        while (lower < upper) {
            auto mid = lower + (upper - lower) / 2, base = triHash_ + 20 * mid;
            const auto slot = (std::uint64_t(u32(base)) << 32) | u32(base + 4);
            if (slot < key) lower = mid + 1; else upper = mid;
        }
        if (lower == triBuckets_) return {};
        auto base = triHash_ + 20 * lower;
        if (u32(base) != std::uint32_t(first) || u32(base + 4) != std::uint32_t(second)) return {};
        return Range{u32(base + 8), u32(base + 12), u32(base + 16)};
    }
    if (version_ == 5) {
        auto key = (static_cast<std::uint32_t>(first) << 16) | static_cast<std::uint32_t>(second);
        std::size_t lower = 0, upper = triBuckets_;
        while (lower < upper) {
            auto mid = lower + (upper - lower) / 2;
            if (u32(triHash_ + 12 * mid) < key) lower = mid + 1; else upper = mid;
        }
        if (lower == triBuckets_) return {};
        auto base = triHash_ + 12 * lower;
        if (u32(base) != key) return {};
        auto start = u32(base + 8);
        auto end = lower + 1 < triBuckets_ ? u32(base + 20) : triEntries_;
        return Range{u32(base + 4), start, end - start};
    }
    auto key = (std::uint64_t(static_cast<std::uint32_t>(first)) << 32) | static_cast<std::uint32_t>(second);
    auto mask = triBuckets_ - 1;
    auto bucket = mix64(key) & mask;
    for (std::uint32_t probes = 0; probes < triBuckets_; ++probes) {
        auto base = triHash_ + 20 * bucket;
        auto slot = u32(base);
        if (slot == empty32) return {};
        if (slot == static_cast<std::uint32_t>(first) && u32(base + 4) == static_cast<std::uint32_t>(second))
            return Range{u32(base + 8), u32(base + 12), u32(base + 16)};
        bucket = (bucket + 1) & mask;
    }
    return {};
}
Continuations PackedLexicon::readRange(std::size_t base, Range range, std::size_t limit) const {
    Continuations out{range.total, {}};
    auto count = std::min<std::size_t>(range.count, limit);
    out.entries.reserve(count);
    for (std::size_t i = range.start; i < std::size_t(range.start) + count; ++i) {
        auto offset = base + entrySize_ * i;
        out.entries.push_back({static_cast<std::int32_t>(idAt(offset)), u32(offset + (version_ == 5 ? 2 : 4))});
    }
    return out;
}
std::optional<Continuations> PackedLexicon::bigrams(std::int32_t context, std::size_t limit) const {
    auto range = bigramRange(context);
    if (!range) return {};
    return readRange(biData_, *range, limit);
}
std::optional<Continuations> PackedLexicon::trigrams(std::int32_t first, std::int32_t second, std::size_t limit) const {
    auto range = trigramRange(first, second);
    if (!range) return {};
    return readRange(triData_, *range, limit);
}
std::vector<TrigramContext> PackedLexicon::trigramContexts() const {
    std::vector<TrigramContext> out;
    for (std::size_t i = 0; i < triBuckets_; ++i) {
        auto base = triHash_ + (version_ == 5 ? 12 : 20) * i;
        auto key = u32(base);
        if (version_ < 5 && key == empty32) continue;
        out.push_back(version_ == 5 ? TrigramContext{static_cast<std::int32_t>(key >> 16), static_cast<std::int32_t>(key & empty16)}
                                  : TrigramContext{static_cast<std::int32_t>(key), static_cast<std::int32_t>(u32(base + 4))});
    }
    return out;
}
} // namespace kb
