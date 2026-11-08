#include "../include/SpatialModel.hpp"
#include <algorithm>
#include <array>
#include <atomic>
#include <mutex>
#include <span>
#include <cmath>
#include <string_view>
namespace kb {
// Key centres in key widths. Looked up per trie node, so a grid is an immutable table read
// through one atomic pointer; an installed grid is kept for the life of the process.
namespace {
struct KeyGrid {
    std::array<std::optional<GridPoint>, 256> table{};
    std::array<char, 27> letters{};   // row by row, NUL-terminated
};
constexpr KeyGrid makeGrid(std::span<const std::string_view> rows, std::span<const double> offsets) {
    KeyGrid out{};
    std::size_t n = 0;
    for (std::size_t row = 0; row < rows.size(); ++row)
        for (std::size_t column = 0; column < rows[row].size(); ++column) {
            const auto c = static_cast<unsigned char>(rows[row][column]);
            out.table[c] = GridPoint{double(column) + offsets[row], double(row)};
            out.letters[n++] = char(c);
        }
    return out;
}
constexpr std::array<std::string_view, 3> qwertyRows{"qwertyuiop", "asdfghjkl", "zxcvbnm"};
constexpr std::array<double, 3> qwertyOffsets{0.0, 0.5, 1.5};
constexpr KeyGrid builtInGrid = makeGrid(qwertyRows, qwertyOffsets);
std::atomic<const KeyGrid*> activeGrid{&builtInGrid};
}
std::optional<GridPoint> grid(std::uint8_t letter) noexcept { return activeGrid.load(std::memory_order_acquire)->table[letter]; }
std::string_view gridLetters() noexcept { return activeGrid.load(std::memory_order_acquire)->letters.data(); }
bool installGrid(std::span<const std::string_view> rows, std::span<const double> offsets) noexcept {
    if (rows.empty() || rows.size() != offsets.size()) return false;
    std::array<bool, 256> seen{};
    std::size_t count = 0;
    for (std::size_t row = 0; row < rows.size(); ++row) {
        if (!std::isfinite(offsets[row]) || offsets[row] < 0 || offsets[row] >= 4) return false;
        for (char c : rows[row]) {
            const auto u = static_cast<unsigned char>(c);
            if (u < 'a' || u > 'z' || seen[u]) return false;
            seen[u] = true; ++count;
        }
    }
    if (count != 26) return false;
    static std::mutex installing;
    std::lock_guard lock(installing);
    const auto* current = activeGrid.load(std::memory_order_acquire);
    const auto next = makeGrid(rows, offsets);
    if (next.letters == current->letters && next.table == current->table) return true;
    // Leaked on purpose: a decode on another thread may still hold the previous table.
    activeGrid.store(new KeyGrid(next), std::memory_order_release);
    return true;
}

bool spellingConfusion(std::uint8_t a, std::uint8_t b) noexcept {
    constexpr std::string_view vowels = "aeiou";
    if (a == b) return false;
    if (vowels.find(char(a)) != vowels.npos && vowels.find(char(b)) != vowels.npos) return true;
    auto pair = [&](char x, char y) { return (a == x && b == y) || (a == y && b == x); };
    return pair('c', 'k') || pair('c', 's') || pair('s', 'z');
}
bool neighbouringKeys(std::uint8_t a, std::uint8_t b) noexcept {
    const auto p = grid(a), q = grid(b);
    return a != b && p && q && (p->x - q->x) * (p->x - q->x) + (p->y - q->y) * (p->y - q->y) <= 1.3;
}
// Spelling (not keyboard) confusions: one vowel for another (definatly, absense) and the
// sound-alike consonants c/k/s/z (brasillian). Their cost does not depend on key distance.
static double spellingSubstitution(std::uint8_t intended, std::uint8_t typed, double vowelCost) noexcept {
    constexpr std::string_view vowels = "aeiou";
    if (vowels.find(char(intended)) != vowels.npos && vowels.find(char(typed)) != vowels.npos) return vowelCost;
    auto pair = [&](char x, char y) { return (intended == x && typed == y) || (intended == y && typed == x); };
    if (pair('c', 'k') || pair('c', 's') || pair('s', 'z')) return soundAlikeSubstitutionCost;
    return 3.0;
}
static double touch(std::uint8_t intended, std::uint8_t typed, TouchOffset tap, double sigma, double vowelCost) noexcept {
    if (intended == typed) return 0;
    auto a = grid(intended), t = grid(typed);
    if (!a || !t) return 3.0;
    const auto px = t->x + tap.dx, py = t->y + tap.dy;
    const auto toIntended = (a->x - px) * (a->x - px) + (a->y - py) * (a->y - py), toTyped = tap.dx * tap.dx + tap.dy * tap.dy;
    const auto spatial = std::max(0.0, toIntended - toTyped) / (2 * sigma * sigma) + substitutionBase;
    return std::min({3.0, spatial, spellingSubstitution(intended, typed, vowelCost)});
}
static double substitution(std::uint8_t intended, std::uint8_t typed, std::optional<TouchOffset> tap, double vowelCost) noexcept {
    if (tap && touchSigma > 0 && std::isfinite(tap->dx) && std::isfinite(tap->dy)) return touch(intended, typed, *tap, touchSigma, vowelCost);
    auto a = grid(intended), t = grid(typed);
    if (!tap || !a || !t) {
        if (intended == typed) return 0;
        if (!a || !t) return 3.0;
        auto dx = a->x - t->x, dy = a->y - t->y;
        auto d2 = dx * dx + dy * dy;
        return std::min({3.0, d2 / (2 * 1.0 * 1.0) + substitutionBase, spellingSubstitution(intended, typed, vowelCost)});
    }
    auto px = t->x + tap->dx, py = t->y + tap->dy;
    auto dx = a->x - px, dy = a->y - py;
    auto d2 = dx * dx + dy * dy;
    auto base = d2 / (2 * 1.0 * 1.0);
    return intended == typed ? std::min(3.0, base)
        : std::min({3.0, base + substitutionBase, spellingSubstitution(intended, typed, vowelCost)});
}
double substitutionCost(std::uint8_t intended, std::uint8_t typed, std::optional<TouchOffset> tap, bool typedFirst) noexcept {
    return substitution(intended, typed, tap, typedFirst ? firstVowelSubstitutionCost : vowelSubstitutionCost);
}
double touchSubstitutionCost(std::uint8_t intended, std::uint8_t typed, TouchOffset tap, double sigma, bool typedFirst) noexcept {
    return touch(intended, typed, tap, sigma, typedFirst ? firstVowelSubstitutionCost : vowelSubstitutionCost);
}
double geometricSubstitutionCost(std::uint8_t intended, std::uint8_t typed, std::optional<TouchOffset> tap) noexcept {
    auto a = grid(intended), t = grid(typed);
    if (!a || !t) return intended == typed ? 0 : 3.0;
    const auto px = t->x + (tap ? tap->dx : 0), py = t->y + (tap ? tap->dy : 0);
    const auto dx = a->x - px, dy = a->y - py;
    const auto base = (dx * dx + dy * dy) / 2;
    return intended == typed ? std::min(3.0, base) : std::min(3.0, base + substitutionBase);
}
double seedFirstLetterCost(std::uint8_t label, std::uint8_t typedFirst, std::optional<TouchOffset> tap) noexcept {
    return firstLetterPenalty(8, label, typedFirst, 0, 0, false) + substitution(label, typedFirst, tap, 3.0);
}
double firstLetterPenalty(std::size_t typedLength, std::uint8_t candidateFirst, std::uint8_t typedFirst, std::uint8_t typedSecond,
        std::uint8_t candidateSecond, bool spelling) noexcept {
    if (candidateFirst == typedFirst || typedLength <= 2) return 0;
    const bool swapped = typedSecond && candidateFirst == typedSecond && candidateSecond == typedFirst;
    // A dropped first letter (bove -> above, nstead -> instead): the candidate's second letter
    // is the typed first. The search already charges the deleted letter, so only a small
    // penalty is added; a swap (waay -> away) keeps its own.
    if (typedLength >= 4 && !swapped && candidateSecond == typedFirst)
        return typedLength == 4 ? missingFirstLetterPenalty4 : missingFirstLetterPenalty;
    if (typedLength == 3) return firstLetterPenalty3;
    if (typedLength == 4) return firstLetterPenalty4;
    // Only a swap of the first two letters is discounted. Discounting any candidate that starts
    // with the typed second letter read the first letter as junk (bcome -> come, adress -> dress),
    // and discounting neighbouring first keys turned qorrwctuon into affection
    // (CoreV4 analysis/autocorrect-comparison-2026-10-27).
    if (swapped) return swappedFirstLetterPenalty;
    const double other = spelling && spellingConfusion(candidateFirst, typedFirst)
        ? std::min(otherFirstLetterPenalty, spellingFirstLetterPenalty) : otherFirstLetterPenalty;
    return neighbouringKeys(candidateFirst, typedFirst) ? std::min(adjacentFirstLetterPenalty, other) : other;
}
} // namespace kb
