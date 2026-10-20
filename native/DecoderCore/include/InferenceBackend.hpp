#pragma once
#include <cstdint>
#include <span>
#include <vector>

namespace kb {
// Planned interface only: current Core ML Swift paths are not replaced here.
// Implementations live in iOS Objective-C++ or an Android-specific backend.
// No Apple/Android tensor, framework or ownership type may cross this interface.
struct InferenceBatch {
    std::span<const std::int32_t> tokenIDs;
    std::span<const std::uint32_t> sequenceOffsets;
    std::span<const float> recurrentState;
};
struct InferenceOutput {
    std::vector<float> logProbabilities;
    std::vector<float> recurrentState;
};
class InferenceBackend {
public:
    virtual ~InferenceBackend() = default;
    InferenceBackend(const InferenceBackend&) = delete;
    InferenceBackend& operator=(const InferenceBackend&) = delete;
    InferenceBackend(InferenceBackend&&) = delete;
    InferenceBackend& operator=(InferenceBackend&&) = delete;
    virtual InferenceOutput predict(const InferenceBatch&) = 0;
protected:
    InferenceBackend() = default;
};
} // namespace kb
