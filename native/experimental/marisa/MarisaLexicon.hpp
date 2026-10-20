#pragma once
#include "PackedLexicon.hpp"
#include "IncrementalSearch.hpp"
#include <marisa.h>

namespace kb::experimental {
// Opt-in immutable vocabulary index. Caller retains corpus for metadata/ngrams.
// Mutable/personal lexicons stay outside this class, as with PackedLexicon.
class MarisaLexicon final {
public:
    static void build(const PackedLexicon& corpus, const std::string& path);
    MarisaLexicon(const PackedLexicon& corpus, const std::string& path);
    std::optional<std::uint32_t> wordID(std::string_view word) const;
    bool contains(std::string_view word) const { return wordID(word).has_value(); }
    bool hasPrefix(std::string_view prefix) const;
    std::vector<ChannelCandidate> completions(std::string_view prefix, std::size_t limit) const;
    std::vector<ChannelCandidate> search(std::string_view typed, double maxCost,
        std::span<const std::optional<TouchOffset>> taps = {},
        std::optional<std::span<const WordFunding>> funding = {},
        const std::function<bool()>& shouldCancel = {}) const;
private:
    const PackedLexicon& corpus_;
    marisa::Trie trie_;
    std::vector<std::uint32_t> vocabularyIDs_;
};
}
