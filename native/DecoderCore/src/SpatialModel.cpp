#include "../include/SpatialModel.hpp"
#include <algorithm>
#include <array>
#include <string_view>
namespace kb {
// Key centres in key widths: rows offset 0, 0.5 and 1.5. Built once; looked up per trie node.
static constexpr auto keyGrid = [] {
    std::array<std::optional<GridPoint>, 256> table{};
    constexpr std::array<std::string_view, 3> rows{"qwertyuiop", "asdfghjkl", "zxcvbnm"};
    constexpr std::array<double, 3> offsets{0.0, 0.5, 1.5};
    for (std::size_t row = 0; row < rows.size(); ++row)
        for (std::size_t column = 0; column < rows[row].size(); ++column)
            table[static_cast<unsigned char>(rows[row][column])] = GridPoint{double(column) + offsets[row], double(row)};
    return table;
}();
std::optional<GridPoint> grid(std::uint8_t letter) noexcept { return keyGrid[letter]; }

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
static double substitution(std::uint8_t intended, std::uint8_t typed, std::optional<TouchOffset> tap, double vowelCost) noexcept {
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
    if (intended == typed) return 0;
    auto a = grid(intended), t = grid(typed);
    if (!a || !t) return 3.0;
    const auto px = t->x + tap.dx, py = t->y + tap.dy;
    const auto toIntended = (a->x - px) * (a->x - px) + (a->y - py) * (a->y - py), toTyped = tap.dx * tap.dx + tap.dy * tap.dy;
    const auto spatial = std::max(0.0, toIntended - toTyped) / (2 * sigma * sigma) + substitutionBase;
    return std::min({3.0, spatial, spellingSubstitution(intended, typed, typedFirst ? firstVowelSubstitutionCost : vowelSubstitutionCost)});
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
