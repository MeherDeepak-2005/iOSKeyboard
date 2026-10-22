#pragma once
#include "LanguageModel.hpp"
#include <unordered_set>
namespace kb {
// Shared with EngineWire: anything learned must survive export -> import, so writes
// enforce the same limits the snapshot decoder checks.
inline constexpr std::size_t maxPersonalWordBytes = 1024, maxPersonalContextBytes = 1040;
struct PersonalizationSnapshot {
    PersonalCounts counts;
    std::unordered_map<std::string, std::int64_t> confirmed;
    std::uint64_t epoch = 0;
};
// Hosts serialize access and persist exported snapshots. Searchers retain immutable
// COW count snapshots so learning/reset cannot invalidate an active decode.
class Personalization final {
    std::shared_ptr<PersonalCounts> counts_ = std::make_shared<PersonalCounts>();
    std::unordered_map<std::string, std::int64_t> confirmed_;
    std::unordered_set<std::string> kept_;
    struct Event { std::vector<std::string> context; std::string word; };
    std::vector<Event> recent_;
    std::uint64_t epoch_ = 0, revision_ = 0;
    void mutate();
public:
    std::shared_ptr<const PersonalCounts> counts() const { return counts_; }
    const auto& confirmed() const { return confirmed_; }
    std::uint64_t revision() const { return revision_; }
    std::uint64_t epoch() const { return epoch_; }
    void install(PersonalizationSnapshot snapshot);
    PersonalizationSnapshot exportSnapshot() const { return {*counts_, confirmed_, epoch_}; }
    void reset(std::uint64_t epoch);
    void learn(std::span<const std::string> context, std::string word);
    void demote(std::string_view word);
    void confirm(std::string word);
    void releaseKeep(std::string_view word) { kept_.erase(std::string(word)); }
    bool kept(std::string_view word) const { return kept_.contains(std::string(word)); }
    std::int64_t confirmations(std::string_view word) const;
    std::size_t diversity(std::string_view word, std::size_t limit = 2) const;
    bool prune();
    bool allowsAdoption(std::string_view word, std::int64_t count, const GenerationLexicon&, std::int64_t threshold = 8) const;
};
}
namespace kb {
class VocabularyState final {
    std::shared_ptr<GenerationSnapshot> generation_ = std::make_shared<GenerationSnapshot>();
    std::unordered_map<std::string,std::int64_t> supplementaryGlide_, personalGlide_;
    void mutate();
public:
    std::shared_ptr<const GenerationSnapshot> snapshot() const { return generation_; }
    void setBlocked(std::unordered_set<std::string> words);
    void supplementary(std::string word, std::int64_t frequency, bool glideSpelling);
    bool noteUse(const GenerationLexicon&, MutableTrie& personal, std::string word, std::int64_t count,
        bool allowAdoption, std::int64_t adoptAfter, bool glideSpelling);
    std::vector<std::string> dynamicWords(std::size_t limit) const;
    void resetPersonalization();
};
}
