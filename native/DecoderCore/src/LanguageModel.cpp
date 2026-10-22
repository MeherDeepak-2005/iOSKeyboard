#include "../include/LanguageModel.hpp"
#include <algorithm>
#include "../include/TextOrder.hpp"
#include <numeric>
namespace kb {
namespace {
const CountRows emptyRows;
std::int64_t lookup(const CountRows& row, std::string_view word) {
    for (const auto& [key, count] : row) if (key == word) return count;
    return 0;
}
std::array<double, 3> discounts(const std::array<std::int64_t, 5>& counts) {
    std::array<double, 3> out;
    const auto y = counts[1] > 0 ? double(counts[1]) / (double(counts[1]) + 2 * double(counts[2])) : 0.75;
    for (std::size_t k = 1; k <= 3; ++k)
        out[k - 1] = counts[k] > 0 && counts[k + 1] > 0
            ? std::min(double(k), std::max(0.0, double(k) - double(k + 1) * y * double(counts[k + 1]) / double(counts[k]))) : 0.75;
    return out;
}
}
std::int64_t PersonalCounts::uni(std::string_view word) const {
    auto found = unigram.find(std::string(word)); return found == unigram.end() ? 0 : found->second;
}
const CountRows& PersonalCounts::bi(std::string_view context) const {
    auto found = bigram.find(std::string(context)); return found == bigram.end() ? emptyRows : found->second;
}
const CountRows& PersonalCounts::tri(std::string_view context) const {
    auto found = trigram.find(std::string(context)); return found == trigram.end() ? emptyRows : found->second;
}
LanguageModel::LanguageModel(const PackedLexicon* data, Smoothing smoothing) : data_(data), smoothing_(smoothing) {
    if (!data_) return;
    if (smoothing == Smoothing::modifiedKneserNey) { prepareMKN(); return; }
    total_ = double(data_->wordCount());
    for (std::uint32_t id = 0; id < data_->wordCount(); ++id) total_ += double(data_->frequency(id));
    if (smoothing == Smoothing::frequencyBackoff) total_ += 0.5;
}
LanguageModel::Context LanguageModel::discounted(const std::vector<Continuation>& entries, const std::array<double, 3>& d) {
    auto rows = entries;
    std::sort(rows.begin(), rows.end(), [](const auto& a, const auto& b) { return a.word < b.word; });
    Context out;
    for (const auto& entry : entries) out.evidence.total += double(entry.count);
    for (const auto& entry : rows) if (entry.count > 0) {
        auto discount = d[std::min<std::size_t>(entry.count, 3) - 1];
        out.evidence.discountMass += discount;
        out.counts[entry.word] = std::max(double(entry.count) - discount, 0.0);
    }
    return out;
}
LanguageModel::Context LanguageModel::discounted(const CountRows& rows, const std::array<double, 3>& d) {
    std::vector<Continuation> entries;
    for (const auto& [word, count] : rows) entries.push_back({std::stoi(word), std::uint32_t(count)});
    return discounted(entries, d);
}
void LanguageModel::prepareMKN() {
    std::unordered_map<std::int32_t, std::unordered_map<std::int32_t, std::uint32_t>> continuation, raw;
    std::array<std::int64_t, 5> triHistogram{}, biHistogram{};
    bool hasTrigrams = false;
    for (const auto& context : data_->trigramContexts()) if (auto row = data_->trigrams(context.first, context.second)) {
        for (const auto& entry : row->entries) if (entry.count > 0) {
            hasTrigrams = true; ++continuation[context.second][entry.word];
            if (entry.count <= 4) ++triHistogram[entry.count];
        }
    }
    for (std::uint32_t id = 0; id < data_->wordCount(); ++id) if (auto row = data_->bigrams(std::int32_t(id))) {
        for (const auto& entry : row->entries) if (entry.count > 0) {
            ++unigrams_[entry.word];
            if (!hasTrigrams) raw[std::int32_t(id)][entry.word] = entry.count;
        }
    }
    triDiscounts_ = discounts(triHistogram);
    auto& lower = hasTrigrams ? continuation : raw;
    for (const auto& [context, row] : lower) {
        (void)context;
        for (const auto& [word, count] : row) { (void)word; if (count > 0 && count <= 4) ++biHistogram[count]; }
    }
    auto d = discounts(biHistogram);
    for (const auto& [context, row] : lower) {
        std::vector<Continuation> entries;
        for (const auto& [word, count] : row) entries.push_back({word, count});
        bigrams_.emplace(context, discounted(entries, d));
    }
    std::int64_t sum = 0;
    for (const auto& [word, count] : unigrams_) { (void)word; sum += count; }
    total_ = double(sum) + 0.5;
}
std::optional<LanguageModel::Context> LanguageModel::prepare(const std::optional<Continuations>& row,
        std::span<const std::int32_t> wanted) const {
    if (!row || !row->total || row->entries.empty()) return {};
    if (smoothing_ == Smoothing::modifiedKneserNey) return discounted(row->entries, triDiscounts_);
    Context out;
    // One pass: whole-row evidence, counts kept only for scored words (no row-sized map).
    std::uint64_t retained = 0; double sum = 0;
    std::vector<std::pair<std::int32_t, std::uint32_t>> hits;
    for (const auto& e : row->entries) {
        retained += e.count; sum += double(e.count);
        if (std::binary_search(wanted.begin(), wanted.end(), e.word)) hits.emplace_back(e.word, e.count);
    }
    if (smoothing_ == Smoothing::wittenBell) {
        auto n = double(row->total), t = double(row->entries.size());
        auto weight = n / (n + t) * n / (n + 8);
        // A pruned context's total exceeds its retained counts; that unretained mass
        // belongs to the backoff, not to nothing. Identical to n * (1 - weight) when
        // nothing was pruned.
        out.evidence = {n, n - weight * double(std::min<std::uint64_t>(retained, row->total))};
        for (const auto& [word, count] : hits) out.counts.emplace(word, weight * double(count));
    } else {
        auto prior = double(row->entries.size()) + 8;
        out.evidence = {sum + prior, prior};
        for (const auto& [word, count] : hits) out.counts.emplace(word, double(count));
    }
    return out;
}
std::vector<double> LanguageModel::scores(std::span<const std::string> words, std::span<const std::string> context,
        const PersonalCounts& personal, const GenerationLexicon& lexicon) const {
    const auto n = context.size();
    auto previous = data_ && n ? data_->wordID(context[n - 1]) : std::nullopt;
    auto first = data_ && n >= 2 ? data_->wordID(context[n - 2]) : std::nullopt;
    std::vector<std::optional<std::int32_t>> ids;
    ids.reserve(words.size());
    std::vector<std::int32_t> wanted;
    for (const auto& word : words) {
        ids.push_back(data_ ? data_->wordID(word) : std::nullopt);
        if (ids.back()) wanted.push_back(*ids.back());
    }
    std::sort(wanted.begin(), wanted.end());
    std::optional<Context> bi, tri;
    if (previous) {
        if (smoothing_ == Smoothing::modifiedKneserNey) {
            if (auto found = bigrams_.find(*previous); found != bigrams_.end()) bi = found->second;
        } else bi = prepare(data_->bigrams(*previous), wanted);
    }
    if (first && previous) tri = prepare(data_->trigrams(*first, *previous), wanted);
    std::vector<LanguageEvidence> rows;
    for (std::size_t index = 0; index < words.size(); ++index) {
        const auto& word = words[index];
        const auto id = ids[index];
        double mass = 0.5;
        if (id) {
            if (smoothing_ == Smoothing::modifiedKneserNey) {
                if (auto found = unigrams_.find(*id); found != unigrams_.end()) mass = double(found->second);
            } else mass = double(data_->frequency(*id)) + 1;
        }
        auto count = [&](const auto& row) { if (row && id) if (auto f = row->counts.find(*id); f != row->counts.end()) return f->second; return 0.0; };
        rows.push_back({mass, count(bi), count(tri), double(lexicon.contains(word) ? personal.uni(word) : 0),
            double(n ? lookup(personal.bi(context[n - 1]), word) : 0),
            double(n >= 2 ? lookup(personal.tri(context[n - 2] + " " + context[n - 1]), word) : 0)});
    }
    return languageScores(rows, total_, bi ? bi->evidence : ContextEvidence{}, tri ? tri->evidence : ContextEvidence{});
}
double LanguageModel::sequence(std::span<const std::string> words, std::vector<std::string> context,
        const PersonalCounts& personal, const GenerationLexicon& lexicon) const {
    double total = 0;
    for (const auto& word : words) { total += scores(std::span(&word, 1), context, personal, lexicon)[0]; context.push_back(word); }
    return total;
}
CountRows LanguageModel::successors(std::span<const std::string> context, const PersonalCounts& personal,
        bool trigram, std::size_t limit) const {
    const auto n = context.size();
    if (n < (trigram ? 2u : 1u)) return {};
    std::optional<Continuations> corpus;
    if (data_) if (auto last = data_->wordID(context.back())) {
        if (trigram) { if (auto first = data_->wordID(context[n - 2])) corpus = data_->trigrams(*first, *last, std::max<std::size_t>(64, limit * 4)); }
        else corpus = data_->bigrams(*last, std::max<std::size_t>(64, limit * 4));
    }
    CountRows out;
    auto position = [&](const std::string& word) { return std::find_if(out.begin(), out.end(), [&](const auto& e) { return e.first == word; }); };
    if (corpus) for (const auto& e : corpus->entries) if (e.count >= 2) {
        std::string word(data_->word(e.word)); auto found = position(word);
        if (found == out.end()) out.emplace_back(word, e.count); else found->second += e.count;
    }
    const auto& learned = trigram ? personal.tri(context[n - 2] + " " + context[n - 1]) : personal.bi(context.back());
    for (const auto& [word, count] : learned) if (data_ && data_->wordID(word)) {
        auto found = position(word);
        if (found != out.end() && count >= 3) found->second += std::min<std::int64_t>(count - 3 + 1, 8);
        else if (count >= 5) {
            auto value = std::min<std::int64_t>(count - 5 + 1, 8);
            if (found == out.end()) out.emplace_back(word, value); else found->second = value;
        }
    }
    std::erase_if(out, [](const auto& e) { return e.first.empty(); });
    return out;
}
std::vector<std::string> LanguageModel::nextWords(CountRows tri, CountRows bi, std::size_t limit) {
    if (!limit) return {};
    auto sort = [](auto& row) { std::stable_sort(row.begin(), row.end(), [](const auto& a, const auto& b) { return a.second == b.second ? utf8Less(a.first, b.first) : a.second > b.second; }); };
    sort(tri); sort(bi);
    std::vector<std::string> out;
    auto fill = [&](const auto& row) { for (const auto& [word, count] : row) { (void)count; if (out.size() >= limit) break; if (std::find(out.begin(), out.end(), word) == out.end()) out.push_back(word); } };
    fill(tri); fill(bi); return out;
}
} // namespace kb
