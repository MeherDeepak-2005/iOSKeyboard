#include "../include/Safety.hpp"
#include <algorithm>
#include <limits>
#include <stdexcept>
namespace kb {
namespace {
constexpr std::size_t headerSize = 24, entrySize = 24;
std::uint32_t u16(std::string_view blob, std::size_t at) {
    if (at > blob.size() || blob.size() - at < 2) throw std::invalid_argument("truncated safety");
    return std::uint32_t(static_cast<unsigned char>(blob[at])) | (std::uint32_t(static_cast<unsigned char>(blob[at + 1])) << 8);
}
std::uint32_t u32(std::string_view blob, std::size_t at) { return u16(blob, at) | (u16(blob, at + 2) << 16); }
double penaltyFor(SafetyAction action) {
    return action == SafetyAction::demote ? 4 : action == SafetyAction::allow ? 0 : std::numeric_limits<double>::infinity();
}
SafetyAction actionFrom(std::uint8_t raw) { return raw <= 3 ? SafetyAction(raw) : SafetyAction::allow; }
}
std::uint64_t SafetyLexicon::fnv1a(std::string_view text) noexcept {
    std::uint64_t h = 0xcbf29ce484222325ull;
    for (unsigned char c : text) { h ^= c; h *= 0x100000001b3ull; }
    return h;
}
SafetyLexicon::SafetyLexicon(std::string_view blob) : blob_(blob) {
    if (blob.size() < headerSize || blob.substr(0, 8) != "KBGUARD1" || u16(blob, 8) != 1 || u16(blob, 10) != entrySize)
        throw std::invalid_argument("invalid safety pack");
    auto n = u32(blob, 12), size = u32(blob, 16);
    if (n > (blob.size() - headerSize) / entrySize) throw std::invalid_argument("safety index overflow");
    count_ = n; terms_ = headerSize + std::size_t(n) * entrySize;
    if (size != blob.size() - terms_) throw std::invalid_argument("safety blob mismatch");
    for (std::size_t i = 0; i < count_; ++i) {
        auto at = headerSize + i * entrySize;
        auto offset = u32(blob, at + 8), length = u16(blob, at + 12);
        if (offset > size || length > size - offset) throw std::invalid_argument("safety range overflow");
        // Binary search needs ascending hashes; each hash must be the builder's FNV-1a of its term.
        if (i && hash(i - 1) > hash(i)) throw std::invalid_argument("safety index unsorted");
        if (hash(i) != fnv1a(term(i))) throw std::invalid_argument("safety hash mismatch");
    }
}
std::uint64_t SafetyLexicon::hash(std::size_t entry) const {
    auto at = headerSize + entry * entrySize; return std::uint64_t(u32(blob_, at)) | (std::uint64_t(u32(blob_, at + 4)) << 32);
}
std::string_view SafetyLexicon::term(std::size_t entry) const {
    auto at = headerSize + entry * entrySize; return blob_.substr(terms_ + u32(blob_, at + 8), u16(blob_, at + 12));
}
std::uint8_t SafetyLexicon::byte(std::size_t entry, std::size_t offset) const {
    return static_cast<unsigned char>(blob_[headerSize + entry * entrySize + offset]);
}
std::optional<std::size_t> SafetyLexicon::find(std::string_view normalized) const {
    const auto h = fnv1a(normalized);
    std::size_t lo = 0, hi = count_;
    while (lo < hi) { auto mid = lo + (hi - lo) / 2; if (hash(mid) < h) lo = mid + 1; else hi = mid; }
    std::optional<std::size_t> best;
    for (auto i = lo; i < count_ && hash(i) == h; ++i)
        if (term(i) == normalized && (!best || actionFrom(byte(i, 15)) > actionFrom(byte(*best, 15)))) best = i;
    return best;
}
SafetyAction SafetyLexicon::action(std::string_view normalized) const {
    auto i = find(normalized); return i ? actionFrom(byte(*i, 15)) : SafetyAction::allow;
}
std::optional<SafetyLanguage> SafetyLexicon::language(std::string_view normalized) const {
    auto i = find(normalized); if (!i) return {};
    auto raw = byte(*i, 14); return raw >= 1 && raw <= 3 ? std::optional(SafetyLanguage(raw)) : std::nullopt;
}
double SafetyLexicon::penalty(std::string_view normalized) const { return penaltyFor(action(normalized)); }
bool SafetyLexicon::blocked(std::string_view normalized) const {
    auto a = action(normalized); return a == SafetyAction::suppressSuggest || a == SafetyAction::suppressAlways;
}
std::unordered_map<std::string, double> SafetyLexicon::penalties() const {
    std::unordered_map<std::string, double> out;
    for (std::size_t i = 0; i < count_; ++i) {
        auto action = actionFrom(byte(i, 15)); if (action == SafetyAction::allow) continue;
        auto [it, fresh] = out.emplace(std::string(term(i)), penaltyFor(action));
        if (!fresh) it->second = std::max(it->second, penaltyFor(action));
    }
    return out;
}
std::vector<std::string> SafetyLexicon::blockedTerms() const {
    std::vector<std::string> out;
    for (const auto& [word, penalty] : penalties()) if (penalty == std::numeric_limits<double>::infinity()) out.push_back(word);
    std::sort(out.begin(), out.end());
    return out;
}
std::unordered_map<std::string, double> parseSafetyPenalties(std::string_view blob) { return SafetyLexicon(blob).penalties(); }
}
