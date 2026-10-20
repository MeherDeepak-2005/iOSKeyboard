#include "../include/Safety.hpp"
#include <algorithm>
#include <cstdint>
#include <limits>
#include <stdexcept>
namespace kb {
std::unordered_map<std::string, double> parseSafetyPenalties(std::string_view blob) {
    auto u16 = [&](std::size_t at) {
        if (at > blob.size() || blob.size() - at < 2) throw std::invalid_argument("truncated safety");
        return std::uint32_t(static_cast<unsigned char>(blob[at])) | (std::uint32_t(static_cast<unsigned char>(blob[at + 1])) << 8);
    };
    auto u32 = [&](std::size_t at) { return u16(at) | (u16(at + 2) << 16); };
    if (blob.size() < 24 || blob.substr(0, 8) != "KBGUARD1" || u16(8) != 1 || u16(10) != 24) throw std::invalid_argument("invalid safety pack");
    auto n = u32(12), size = u32(16);
    if (n > (blob.size() - 24) / 24) throw std::invalid_argument("safety index overflow");
    auto base = 24 + std::size_t(n) * 24;
    if (size != blob.size() - base) throw std::invalid_argument("safety blob mismatch");
    std::unordered_map<std::string, double> out;
    for (std::size_t i = 0; i < n; ++i) {
        auto at = 24 + i * 24;
        auto offset = u32(at + 8), length = u16(at + 12);
        if (offset > size || length > size - offset) throw std::invalid_argument("safety range overflow");
        auto action = static_cast<unsigned char>(blob[at + 15]);
        if (action == 0 || action > 3) continue;
        double penalty = action == 1 ? 4 : std::numeric_limits<double>::infinity();
        auto [it, fresh] = out.emplace(std::string(blob.substr(base + offset, length)), penalty);
        if (!fresh) it->second = std::max(it->second, penalty);
    }
    return out;
}
}
