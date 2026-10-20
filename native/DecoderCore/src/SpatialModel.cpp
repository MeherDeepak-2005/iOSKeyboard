#include "../include/SpatialModel.hpp"
#include <algorithm>
#include <array>
#include <string_view>
namespace kb {
std::optional<GridPoint> grid(std::uint8_t letter) noexcept {
    constexpr std::array<std::string_view, 3> rows{"qwertyuiop", "asdfghjkl", "zxcvbnm"};
    constexpr std::array<double, 3> offsets{0.0, 0.5, 1.5};
    for (std::size_t row = 0; row < rows.size(); ++row) {
        auto column = rows[row].find(static_cast<char>(letter));
        if (column != std::string_view::npos) return GridPoint{double(column) + offsets[row], double(row)};
    }
    return {};
}
double substitutionCost(std::uint8_t intended, std::uint8_t typed, std::optional<TouchOffset> tap) noexcept {
    auto a = grid(intended), t = grid(typed);
    if (!tap || !a || !t) {
        if (intended == typed) return 0;
        if (!a || !t) return 3.0;
        auto dx = a->x - t->x, dy = a->y - t->y;
        auto d2 = dx * dx + dy * dy;
        return std::min(3.0, d2 / (2 * 1.0 * 1.0) + 0.3);
    }
    auto px = t->x + tap->dx, py = t->y + tap->dy;
    auto dx = a->x - px, dy = a->y - py;
    auto d2 = dx * dx + dy * dy;
    auto base = d2 / (2 * 1.0 * 1.0);
    return intended == typed ? std::min(3.0, base) : std::min(3.0, base + 0.3);
}
double firstLetterPenalty(std::size_t typedLength, std::uint8_t candidateFirst, std::uint8_t typedFirst) noexcept {
    if (candidateFirst == typedFirst || typedLength <= 2) return 0;
    if (typedLength == 3) return 0.35;
    if (typedLength == 4) return 0.75;
    return 2.5;
}
} // namespace kb
