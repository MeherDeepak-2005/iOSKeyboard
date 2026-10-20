#include "MarisaLexicon.hpp"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <numeric>
#include <stdexcept>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/resource.h>
#include <fcntl.h>
#include <unistd.h>
using Clock = std::chrono::steady_clock;
using kb::experimental::MarisaLexicon;
namespace {
struct MappedFile {
    int fd; std::size_t size; void* address;
    explicit MappedFile(const char* path) {
        fd = open(path, O_RDONLY);
        if (fd < 0) throw std::runtime_error("open corpus failed");
        struct stat status{};
        if (fstat(fd, &status)) { close(fd); throw std::runtime_error("stat corpus failed"); }
        size = std::size_t(status.st_size);
        address = mmap(nullptr, size, PROT_READ, MAP_PRIVATE, fd, 0);
        if (address == MAP_FAILED) { close(fd); throw std::runtime_error("map corpus failed"); }
    }
    ~MappedFile() { munmap(address, size); close(fd); }
    auto bytes() const { return std::span(static_cast<const std::byte*>(address), size); }
};
// Benchmark-only native reproduction of the packed byte-trie exact lookup.
// Reads only a corpus already validated by PackedLexicon.
struct PackedLookup {
    std::span<const std::byte> bytes;
    std::size_t offset, width;
    std::uint32_t version;
    std::uint32_t u32(std::size_t p) const {
        std::uint32_t v = 0;
        for (int i = 0; i < 4; ++i) v |= std::uint32_t(std::to_integer<unsigned char>(bytes[p + i])) << (8 * i);
        return v;
    }
    explicit PackedLookup(std::span<const std::byte> data) : bytes(data) {
        version = u32(4); width = version == 5 ? 12 : 14;
        const auto entries = version == 5 ? 6 : 8;
        offset = (version >= 4 ? 36 : version >= 3 ? 32 : 28) + std::size_t(4) * u32(8) +
            std::size_t(4) * (std::size_t(u32(8)) + 1) +
            std::size_t(version == 5 ? 12 : 16) * u32(12) + std::size_t(entries) * u32(16) +
            std::size_t(version == 5 ? 12 : 20) * u32(20) + std::size_t(entries) * u32(24);
    }
    std::optional<std::uint32_t> wordID(std::string_view word) const {
        std::size_t node = 0;
        for (unsigned char letter : word) {
            const auto p = offset + width * node;
            std::size_t low = u32(p + 2), high = low + std::to_integer<unsigned char>(bytes[p + 1]);
            const auto end = high;
            while (low < high) {
                const auto mid = low + (high - low) / 2;
                if (std::to_integer<unsigned char>(bytes[offset + width * mid]) < letter) low = mid + 1;
                else high = mid;
            }
            if (low == end || std::to_integer<unsigned char>(bytes[offset + width * low]) != letter) return {};
            node = low;
        }
        const auto p = offset + width * node + 6;
        const auto id = version == 5 ? u32(p) & 0xffff : u32(p);
        return id == (version == 5 ? 0xffff : 0xffffffff) ? std::nullopt : std::optional(id);
    }
};
void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
void parity(const std::vector<kb::ChannelCandidate>& a, const std::vector<kb::ChannelCandidate>& b) {
    require(a.size() == b.size(), "candidate count differs");
    for (std::size_t i = 0; i < a.size(); ++i)
        require(a[i].word == b[i].word && a[i].cost == b[i].cost && a[i].logFrequency == b[i].logFrequency,
            "candidate order/word/cost/frequency differs");
}
std::vector<std::string> queries() {
    std::vector<std::string> result{"a", "i", "teh", "th", "hel", "hello", "dont", "can't", "cant", "wont", "recieve",
        "correcgion", "coeevitjkn", "x", "zzzzzz", "qwerty", "definately", "possibly", "it's", "whens", "", "!", "hello!"};
    for (std::string word : {"correction", "receive", "keyboard", "tomorrow"})
        for (std::size_t n = 1; n <= word.size(); ++n) result.push_back(word.substr(0, n));
    return result;
}
template<class F> double timed(F&& f) {
    const auto start = Clock::now(); f();
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
double percentile(std::vector<double> values, double p) {
    std::sort(values.begin(), values.end());
    return values.at(std::size_t(std::ceil(p * values.size())) - 1);
}
void check(const kb::PackedLexicon& corpus, const MarisaLexicon& marisa, const std::string& path) {
    for (std::uint32_t id = 0; id < corpus.wordCount(); ++id)
        require(marisa.wordID(corpus.word(id)) == id, "vocabulary ID mismatch");
    require(!marisa.contains("__not_a_corpus_word__"), "false lookup hit");
    const std::vector<kb::WordFunding> funding{{"correction", 1.6}, {"the", 1.2}, {"can't", 1.5}, {"receive", .8}, {"hello", 1.6}};
    std::size_t cases = 0;
    for (const auto& query : queries()) for (double radius : {0., 1.6, 3.6, 7.2}) {
        for (int mode = 0; mode < 4; ++mode) {
            std::vector<std::optional<kb::TouchOffset>> taps;
            if (mode & 1) taps.assign(query.size(), kb::TouchOffset{.23, -.17});
            const auto prior = mode & 2 ? std::optional(std::span<const kb::WordFunding>(funding)) : std::nullopt;
            parity(corpus.search(query, radius, taps, prior), marisa.search(query, radius, taps, prior));
            ++cases;
        }
    }
    // Wider independent coverage, including lexical punctuation/case variants.
    for (std::uint32_t id = 0; id < corpus.wordCount(); id += 997) {
        std::string query(corpus.word(id));
        if (query.size() > 2) std::swap(query[query.size() - 1], query[query.size() - 2]);
        parity(corpus.search(query, 3.6), marisa.search(query, 3.6)); ++cases;
    }
    std::vector<std::string> words;
    for (std::uint32_t id = 0; id < corpus.wordCount(); ++id) words.emplace_back(corpus.word(id));
    std::sort(words.begin(), words.end());
    for (std::string prefix : {"", "a", "th", "cor", "can'", "zzzzzz", "__missing__"}) {
        std::vector<kb::ChannelCandidate> expected;
        bool any = false;
        for (const auto& word : words) if (word.starts_with(prefix)) {
            any = true;
            {
                const auto id = *marisa.wordID(word);
                expected.push_back({word, 0, std::log(double(std::max(corpus.frequency(id), 1u)) + 1)});
            }
        }
        std::stable_sort(expected.begin(), expected.end(), [](const auto& a, const auto& b) { return a.logFrequency > b.logFrequency; });
        if (expected.size() > 8) expected.resize(8);
        parity(expected, marisa.completions(prefix, 8));
        require(marisa.hasPrefix(prefix) == any, "prefix mismatch");
        require(marisa.completions(prefix, 0).empty(), "zero completion limit");
    }
    require(marisa.search("correction", 7.2, {}, {}, [] { return true; }).empty(), "cancellation returned partial hits");
    for (double radius : {-1., std::numeric_limits<double>::infinity()}) {
        bool rejected = false;
        try { marisa.search("hello", radius); } catch (const std::invalid_argument&) { rejected = true; }
        require(rejected, "invalid radius accepted");
    }
    std::vector<kb::WordFunding> invalid{{"hello", 1.7}};
    bool rejected = false;
    try { marisa.search("hello", 3.6, {}, std::span<const kb::WordFunding>(invalid)); }
    catch (const std::invalid_argument&) { rejected = true; }
    require(rejected, "invalid funding accepted");
    // Restore the artifact after each malformed sidecar fixture.
    const auto sidecar = path + ".ids";
    std::ifstream input(sidecar, std::ios::binary);
    const std::string original((std::istreambuf_iterator<char>(input)), {});
    for (int fixture = 0; fixture < 4; ++fixture) {
        auto broken = original;
        if (fixture == 0) broken.resize(7);
        if (fixture == 1) std::fill(broken.begin() + 8, broken.begin() + 12, char(255));
        if (fixture == 2) for (int i = 0; i < 4; ++i) std::swap(broken[8 + i], broken[12 + i]);
        if (fixture == 3) broken.push_back('x');
        { std::ofstream out(sidecar, std::ios::binary | std::ios::trunc); out.write(broken.data(), broken.size()); }
        rejected = false;
        try { MarisaLexicon bad(corpus, path); } catch (const std::invalid_argument&) { rejected = true; }
        { std::ofstream out(sidecar, std::ios::binary | std::ios::trunc); out.write(original.data(), original.size()); }
        require(rejected, "malformed sidecar accepted");
    }
    std::vector<std::optional<kb::TouchOffset>> mismatched(1, kb::TouchOffset{.4, -.2});
    parity(corpus.search("hello", 3.6, mismatched), marisa.search("hello", 3.6, mismatched));
    const std::vector<kb::WordFunding> emptyFunding;
    parity(corpus.search("hello", 3.6, {}, std::span<const kb::WordFunding>(emptyFunding)),
        marisa.search("hello", 3.6, {}, std::span<const kb::WordFunding>(emptyFunding)));
    cases += 2;
    std::cout << "{\"status\":\"passed\",\"vocabulary_ids_checked\":" << corpus.wordCount()
              << ",\"search_parity_cases\":" << cases << ",\"malformed_sidecars\":4}\n";
}
}
int main(int argc, char** argv) try {
    if (argc != 4) throw std::invalid_argument("usage: marisa-experiment corpus index build|test|bench|memory-packed|memory-marisa");
    MappedFile file(argv[1]);
    std::unique_ptr<kb::PackedLexicon> corpus;
    const double packedOpen = timed([&] { corpus = std::make_unique<kb::PackedLexicon>(file.bytes()); });
    const std::string path(argv[2]), mode(argv[3]);
    if (mode == "build") {
        const double elapsed = timed([&] { MarisaLexicon::build(*corpus, path); });
        auto u32 = [&](std::size_t offset) { std::uint32_t value = 0; for (int i = 0; i < 4; ++i) value |= std::uint32_t(std::to_integer<unsigned char>(file.bytes()[offset + i])) << (8 * i); return value; };
        const auto packedBytes = std::uint64_t(u32(28)) * (corpus->version() == 5 ? 12 : 14);
        std::cout << "{\"build_ms\":" << elapsed << ",\"words\":" << corpus->wordCount()
            << ",\"packed_trie_bytes\":" << packedBytes << ",\"marisa_bytes\":" << std::filesystem::file_size(path)
            << ",\"id_map_bytes\":" << std::filesystem::file_size(path + ".ids") << "}\n";
        return 0;
    }
    std::unique_ptr<MarisaLexicon> marisa;
    double marisaOpen = 0;
    if (mode != "memory-packed") marisaOpen = timed([&] { marisa = std::make_unique<MarisaLexicon>(*corpus, path); });
    if (mode == "test") { check(*corpus, *marisa, path); return 0; }
    std::size_t checksum = 0;
    if (mode.starts_with("memory-")) {
        for (const auto& query : queries()) checksum += mode == "memory-packed" ? corpus->search(query, 3.6).size() : marisa->search(query, 3.6).size();
        struct rusage usage{};
        if (getrusage(RUSAGE_SELF, &usage)) throw std::runtime_error("getrusage failed");
        auto rss = std::uint64_t(usage.ru_maxrss);
#ifndef __APPLE__
        rss *= 1024;
#endif
        std::cout << "{\"checksum\":" << checksum << ",\"peak_rss_bytes\":" << rss << "}\n"; return 0;
    }
    require(mode == "bench", "unknown mode");
    PackedLookup packedLookup(file.bytes());
    std::vector<double> packedTimes, marisaTimes, lookupTimes, packedLookupTimes;
    // Alternating order across repetitions reduces systematic order bias.
    for (int repeat = -1; repeat < 5; ++repeat) for (const auto& query : queries()) {
        if (query.empty()) continue;
        double p = 0, m = 0;
        auto packedRun = [&] { p = timed([&] { checksum += corpus->search(query, 3.6).size(); }); };
        auto marisaRun = [&] { m = timed([&] { checksum += marisa->search(query, 3.6).size(); }); };
        if (repeat % 2) { packedRun(); marisaRun(); } else { marisaRun(); packedRun(); }
        if (repeat >= 0) { packedTimes.push_back(p); marisaTimes.push_back(m); }
    }
    for (std::uint32_t id = 0; id < corpus->wordCount(); ++id)
        require(packedLookup.wordID(corpus->word(id)) == id, "packed lookup reference mismatch");
    for (int repeat = 0; repeat < 5; ++repeat) {
        packedLookupTimes.push_back(timed([&] {
            for (std::uint32_t id = 0; id < corpus->wordCount(); ++id) checksum += packedLookup.wordID(corpus->word(id)).value_or(0);
        }));
        lookupTimes.push_back(timed([&] {
            for (std::uint32_t id = 0; id < corpus->wordCount(); ++id) checksum += marisa->wordID(corpus->word(id)).value_or(0);
        }));
    }
    std::cout << "{\"samples_per_backend\":" << packedTimes.size()
        << ",\"packed_search_p50_ms\":" << percentile(packedTimes, .5) << ",\"packed_search_p95_ms\":" << percentile(packedTimes, .95)
        << ",\"marisa_search_p50_ms\":" << percentile(marisaTimes, .5) << ",\"marisa_search_p95_ms\":" << percentile(marisaTimes, .95)
        << ",\"packed_validated_open_ms\":" << packedOpen << ",\"additional_marisa_validated_open_ms\":" << marisaOpen
        << ",\"packed_full_vocab_lookup_p50_ms\":" << percentile(packedLookupTimes, .5)
        << ",\"marisa_full_vocab_lookup_p50_ms\":" << percentile(lookupTimes, .5) << ",\"checksum\":" << checksum << "}\n";
    return 0;
} catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
