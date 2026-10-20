#pragma once
#include <string>
#include <string_view>
#include <unordered_map>
namespace kb {
// KBGUARD1 v1 reader shared by adapters and host tests. demote → 4, either suppress
// action → +inf, allow/unknown skipped. A duplicated term keeps its strongest action.
std::unordered_map<std::string, double> parseSafetyPenalties(std::string_view blob);
}
