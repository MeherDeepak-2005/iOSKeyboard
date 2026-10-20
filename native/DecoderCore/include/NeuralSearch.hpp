#pragma once
#include <cstdint>
#include <span>
#include <string>
#include <unordered_map>
#include <vector>
#include "CandidateGeneration.hpp"
namespace kb {
class Tokenizer {
public:
    explicit Tokenizer(std::span<const uint8_t> data);
    bool valid = false;
    int32_t unknown = 0, pad = 0, english = -1;
    std::vector<std::string> pieces;
    std::vector<uint8_t> starts, continuations;
    // Platform supplies Unicode grapheme segmentation and normalization once at the boundary.
    void setLengths(std::span<const uint32_t> lengths);
    std::vector<int32_t> encode(std::span<const std::string> characters) const;
    std::string word(std::span<const int32_t> ids) const;
private:
    struct Piece { int32_t id; float score; };
    std::unordered_map<std::string, Piece> lookup;
    size_t maximum = 24;
};
bool logProbabilities(std::vector<float>& values);
double boundaryProbability(std::span<const float> values, std::span<const uint8_t> continuations);
std::vector<int32_t> topIndices(std::span<const float> values, size_t count, std::span<const uint8_t> allowed);
}
#include <functional>
#include <optional>
namespace kb {
struct NeuralStep { std::vector<float> logits; size_t state; };
using NeuralInference = std::function<std::optional<NeuralStep>(int32_t,size_t)>;
using NeuralWord = std::pair<std::string,double>;
std::vector<NeuralWord> generateWords(const Tokenizer&, int32_t previous, size_t state,
    std::span<const uint8_t> allowedStarts, size_t width, size_t branch, size_t depth,
    const NeuralInference&, const std::function<bool(const std::string&)>& known,
    const std::function<bool()>& cancelled);
std::optional<std::vector<NeuralWord>> scoreWords(const Tokenizer&, std::span<const std::string> words,
    std::span<const std::vector<int32_t>> tokens, int32_t previous, size_t state,
    const NeuralInference&, const std::function<bool()>& cancelled);
struct ContextPlan { bool reuse; size_t start; int32_t previous; };
ContextPlan contextPlan(std::span<const int32_t> tokens,std::span<const int32_t> cached,int32_t pad);
}
namespace kb {
std::vector<int32_t> trimmedContext(std::span<const int32_t> tokens,std::optional<int32_t> languageMode,size_t sequenceLength,size_t maximumCandidateTokens);
}
namespace kb {
std::optional<size_t> threadContext(std::span<const int32_t> tokens,int32_t previous,size_t state,
    const NeuralInference&,const std::function<bool()>& cancelled);
}
namespace kb {
std::vector<std::string> filterKnownWords(std::span<const std::string> words,const GenerationLexicon&,std::span<const std::string> firstLetters);
std::vector<std::string> lastContextWords(std::span<const std::string> words,size_t limit);
}
