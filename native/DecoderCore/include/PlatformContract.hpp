#pragma once
#include <cstdint>

namespace kb {
// Transport records for both platform adapters. These are identities, never clocks
// or pointers. The platform must reject a stale result before publishing to its IME.
struct RequestIdentity {
    std::uint64_t fieldRevision = 0;
    std::uint64_t documentRevision = 0;
    std::uint64_t wordSessionID = 0;
    std::uint64_t generation = 0;
    std::uint64_t layoutRevision = 0;
    std::uint64_t vocabularyEpoch = 0;
    std::uint64_t personalizationEpoch = 0;
    bool operator==(const RequestIdentity&) const = default;
};
// Shared English engine contract. UI/lifecycle/model runtimes stay in adapters.
inline constexpr std::uint32_t platformContractVersion = 2;
inline constexpr std::uint32_t currentLanguagePackVersion = 6;
inline constexpr std::uint32_t defaultIncrementalStateCap = 24'000;
} // namespace kb
