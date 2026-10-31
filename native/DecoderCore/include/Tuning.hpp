#pragma once
// Channel costs and score weights. Production builds keep them constexpr. A KB_TUNING build
// (tools/evaluation/autocorrect only) reads each one once from the environment variable
// KB_<name>, so the evaluation harness can search them without a rebuild per value.
#ifdef KB_TUNING
#include <cstdlib>
namespace kb {
inline double tunable(const char* name, double fallback) {
    const char* text = std::getenv(name);
    return text ? std::strtod(text, nullptr) : fallback;
}
} // namespace kb
#define KB_TUNABLE(name, value) inline const double name = ::kb::tunable("KB_" #name, value)
#else
#define KB_TUNABLE(name, value) inline constexpr double name = value
#endif
