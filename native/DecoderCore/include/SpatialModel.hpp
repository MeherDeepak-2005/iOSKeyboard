#pragma once
#include <cstddef>
#include <cstdint>
#include <optional>
namespace kb {
struct TouchOffset { double dx, dy; };
struct GridPoint { double x, y; };
inline constexpr std::uint8_t apostrophe = '\'';
inline constexpr double insertionCost = 1.6;
inline constexpr double deletionCost = 1.6;
inline constexpr double transpositionCost = 0.8;
inline constexpr double apostropheSkipCost = 0.4;
std::optional<GridPoint> grid(std::uint8_t letter) noexcept;
double substitutionCost(std::uint8_t intended, std::uint8_t typed,
                        std::optional<TouchOffset> tap = {}) noexcept;
double firstLetterPenalty(std::size_t typedLength, std::uint8_t candidateFirst,
                          std::uint8_t typedFirst) noexcept;
} // namespace kb
