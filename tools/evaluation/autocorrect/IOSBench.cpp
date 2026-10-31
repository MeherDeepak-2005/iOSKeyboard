// iOSKeyboard side of the autocorrect/suggestion comparison (27 Oct 2026).
// Engine setup is copied from iOSKeyboard native/tests/EngineTests.cpp replayGoldens
// (the host half of the iOS/Android parity test): langdata.bin, installed text metadata,
// safety.kbguard penalties via EngineState, default EngineOptions. Context words follow
// KeyboardViewController.contextWords(_:max: 8): word characters are letters and
// apostrophes, stop at . ! ? or newline, lowercased like DecodeContract.
// No touch offsets are sent (CoreV4 receives characters only). No personalization.
//
// KB_NSS=model.nsslm decodes with the neural search space tier (tools/nss) instead of the
// n-gram; the model file is mapped read-only like langdata.bin.
//
// Same TSV/JSONL contract as CoreBench.cpp.
#include "Engine.hpp"
#include "Safety.hpp"
#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cctype>
#include <fstream>
#include <iostream>
#include <sstream>
#include <fcntl.h>
#include <mach/mach.h>
#include <malloc/malloc.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <sys/resource.h>
using namespace kb;
using Clock = std::chrono::steady_clock;
static double ms(Clock::time_point a, Clock::time_point b) { return std::chrono::duration<double, std::milli>(b - a).count(); }
static std::string quote(const std::string& s) {
    std::string r = "\"";
    for (unsigned char c : s) {
        if (c == '"' || c == '\\') r += '\\';
        if (c < 0x20) continue;
        r += char(c);
    }
    return r + '"';
}
static std::string slurp(const std::string& path) { std::ifstream in(path, std::ios::binary); std::stringstream out; out << in.rdbuf(); return out.str(); }
static std::string lower(std::string text) { for (auto& c : text) if (static_cast<unsigned char>(c) < 0x80) c = char(std::tolower(static_cast<unsigned char>(c))); return text; }
static std::vector<std::size_t> boundaries(std::string_view text) {
    std::vector<std::size_t> out{0};
    for (std::size_t i = 0; i < text.size();) {
        auto c = static_cast<unsigned char>(text[i]); std::size_t n = c < 0x80 ? 1 : c < 0xe0 ? 2 : c < 0xf0 ? 3 : 4;
        bool combining = n == 2 && (c == 0xcc || (c == 0xcd && static_cast<unsigned char>(text[i + 1]) < 0xb0));
        i += n; if (combining && out.size() > 1) out.back() = i; else out.push_back(i);
    }
    return out;
}
static bool wordChar(unsigned char c) { return std::isalpha(c) || c == '\'' || c >= 0x80; }
static std::vector<std::string> contextWords(const std::string& s, std::size_t max = 8) {
    std::vector<std::string> words; std::size_t end = s.size();
    while (end && wordChar(s[end - 1])) --end;   // drop trailing partial (none: context ends before the word)
    while (words.size() < max) {
        while (end && !wordChar(s[end - 1])) { char c = s[end - 1]; if (c == '.' || c == '!' || c == '?' || c == '\n') return words; --end; }
        if (!end) break;
        std::size_t start = end; while (start && wordChar(s[start - 1])) --start;
        words.insert(words.begin(), lower(s.substr(start, end - start))); end = start;
    }
    return words;
}
static std::string modelTier = "ngram";
static DecodeInput makeInput(const std::string& typed, const std::vector<std::string>& context, std::uint64_t word, std::uint64_t gen) {
    DecodeInput in; in.word = typed; in.normalized = lower(typed); in.context = context; in.modelTier = modelTier;
    in.identity = {1, word, word, gen, 1, 0, 0};
    in.characterOffsets = boundaries(in.normalized); in.letterFlags.assign(in.normalized.size(), 0);
    for (std::size_t k = 1; k < in.characterOffsets.size(); ++k) {
        auto at = in.characterOffsets[k - 1]; auto c = static_cast<unsigned char>(in.normalized[at]);
        if (c >= 0x80 || std::isalpha(c)) std::fill(in.letterFlags.begin() + long(at), in.letterFlags.begin() + long(in.characterOffsets[k]), 1);
    }
    if (in.normalized.empty()) in.characterOffsets.clear();
    return in;
}
// Same rule as CoreBench.cpp: rank among the first three non-literal entries.
static int rankOf(const std::vector<std::string>& list, const std::string& prefix, const std::string& target) {
    int slot = 0;
    for (const auto& w : list) {
        auto l = lower(w);
        if (l == prefix) continue;
        if (slot == 3) break;
        if (l == target) return slot;
        ++slot;
    }
    return -1;
}
// KB_DIAG=1: where a target is lost. Rebuilds the pool exactly as EngineSession::decode
// (public functions only; the packed search stands in for the equivalent retained search),
// then applies the same 32-row pre-LM shortlist. Pools: p=completion d=display c=close
// b=broad i=injected s=split.
struct Funnel { std::string pools; bool shortlisted = false; };
static Funnel funnel(const EngineSession& session, const DecodeInput& in, const EngineView& view, const std::string& target) {
    Funnel f; const auto& typed = in.normalized;
    auto length = in.characterOffsets.empty() ? typed.size() : in.characterOffsets.size() - 1;
    auto next = in.context.empty() ? std::vector<std::string>{} : session.nextWords(in.context, view, 24);
    std::vector<ContextSuccessor> successors;
    if (length >= 4) for (const auto& word : next) successors.push_back({word, view.lexicon.characterCount(word), {}, {}});
    std::optional<std::vector<WordFunding>> funding; if (!next.empty()) funding = rankFunding(next);
    auto pools = generateCandidates(view.lexicon, typed, in.taps, successors,
        funding ? std::optional<std::span<const WordFunding>>(*funding) : std::nullopt, std::nullopt, false, {}, in.characterOffsets);
    std::vector<ChannelCandidate> scoring;
    auto take = [&](const std::vector<ChannelCandidate>& rows, char tag) {
        scoring.insert(scoring.end(), rows.begin(), rows.end());
        if (std::any_of(rows.begin(), rows.end(), [&](const auto& c) { return c.word == target; })) f.pools += tag;
    };
    take(pools.completions, 'p'); take(pools.displayCorrections, 'd'); take(pools.close, 'c'); take(pools.broad, 'b'); take(pools.injected, 'i');
    if (pools.split) { scoring.push_back(*pools.split); if (pools.split->word == target) f.pools += 's'; }
    std::vector<RankedRow> prepared;
    for (auto& row : scoring) { auto key = row.word; auto safety = view.penalty(key); prepared.push_back({std::move(row), std::move(key), safety, 0, 0, {}}); }
    std::optional<RankedRow> extra = RankedRow{{typed, 0, view.lexicon.logFrequency(typed).value_or(0)}, typed, 0, 0, 0, {}};
    auto ordered = prepareRanking(prepared, extra);
    // KB_DIAG_CAP (default 16, 0 = none) mirrors EngineSession::score's completion-only cap.
    const char* capText = std::getenv("KB_DIAG_CAP"); const std::size_t cap = capText ? std::size_t(std::atoi(capText)) : 16;
    if (cap) {
        std::unordered_set<std::string> only; for (const auto& c : pools.completions) only.insert(c.word);
        for (const auto* rows : {&pools.displayCorrections, &pools.close, &pools.broad, &pools.injected}) for (const auto& c : *rows) only.erase(c.word);
        if (pools.split) only.erase(pools.split->word);
        std::vector<RankedRow> completions, others;
        for (auto& row : ordered) (row.key == typed || !only.contains(row.key) ? others : completions).push_back(std::move(row));
        if (completions.size() > cap) {
            std::stable_sort(completions.begin(), completions.end(), [](const auto& a, const auto& b) {
                auto lhs = -a.channel.cost + 0.3 * frequencyTerm(a.channel.logFrequency, true), rhs = -b.channel.cost + 0.3 * frequencyTerm(b.channel.logFrequency, true);
                return lhs == rhs ? utf8Less(a.key, b.key) : lhs > rhs; });
            completions.resize(cap);
        }
        ordered = std::move(others); for (auto& row : completions) ordered.push_back(std::move(row));
    }
    for (const auto& row : shortlist(std::move(ordered), extra, 32, true)) if (row.key == target) f.shortlisted = true;
    return f;
}
static void words(std::ostream& o, const std::vector<std::string>& w) {
    o << '['; for (std::size_t i = 0; i < w.size(); ++i) { if (i) o << ','; o << quote(w[i]); } o << ']';
}
static void processRecord(std::ostream& out, const char* label) {
    rusage usage{}; getrusage(RUSAGE_SELF, &usage);
    task_vm_info_data_t info{}; mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count);
    // heap_in_use = live malloc bytes; footprint minus it is allocator-retained and other dirty memory.
    malloc_statistics_t heap{}; malloc_zone_statistics(nullptr, &heap);
    out << "{\"kind\":\"process\",\"at\":" << quote(label) << ",\"peak_rss_bytes\":" << usage.ru_maxrss
        << ",\"footprint_bytes\":" << info.phys_footprint << ",\"heap_in_use_bytes\":" << heap.size_in_use
        << ",\"heap_allocated_bytes\":" << heap.size_allocated << "}\n";
}
int main(int argc, char** argv) {
    if (argc < 5) { std::cerr << "langdata.bin safety.kbguard cases.tsv output.jsonl\n"; return 2; }
    std::ofstream out(argv[4]);
    auto initStart = Clock::now();
    // Mapped read-only like native/android/SharedEngineJni.cpp's Mapping.
    int fd = open(argv[1], O_RDONLY); struct stat st{}; fstat(fd, &st);
    void* data = mmap(nullptr, std::size_t(st.st_size), PROT_READ, MAP_PRIVATE, fd, 0); close(fd);
    if (data == MAP_FAILED) { std::cerr << "cannot map " << argv[1] << "\n"; return 3; }
    auto reader = std::shared_ptr<const PackedLexicon>(new PackedLexicon({static_cast<const std::byte*>(data), std::size_t(st.st_size)}));
    std::vector<PackedLexicon::TextMetadata> metadata;
    for (auto id : reader->textMetadataIDs()) {
        auto text = reader->word(id); auto marks = boundaries(text);
        auto ascii = [&](std::size_t from, std::size_t to) { return to - from == 1 && static_cast<unsigned char>(text[from]) < 0x80 ? std::optional(std::uint8_t(text[from])) : std::nullopt; };
        metadata.push_back({id, marks.size() - 1, ascii(marks[0], marks[1]), ascii(marks[marks.size() - 2], marks.back())});
    }
    reader->installTextMetadata(metadata); reader->warmAnchors();
    // KB_POLICY="oov,realWord,closeRescueMargin,closeRescueGap,minimumCloseGap,closeRescueMaxCost"
    // overrides the correction gate (Swift CorrectionPolicy.nativeValues order), for gate sweeps.
    EngineOptions options;
    if (const char* text = std::getenv("KB_POLICY")) {
        double v[6]; if (std::sscanf(text, "%lf,%lf,%lf,%lf,%lf,%lf", v, v + 1, v + 2, v + 3, v + 4, v + 5) != 6) return 2;
        options.correction = {v[0], v[1], v[2], v[3], v[4], v[5]};
    }
    // KB_PROFILE=1: engine phase timings, summed over keystrokes after the first letter of
    // next-word rows, written as one "profile" record at the end (letters 1-4 and 5+).
    const bool profile = std::getenv("KB_PROFILE") && std::string(std::getenv("KB_PROFILE")) == "1";
    options.profile = profile;
    double phase[2][4] = {};
    if (const char* text = std::getenv("KB_STATECAP")) options.stateCap = std::size_t(std::atol(text));   // retained-search seed cap
    std::shared_ptr<const NeuralWordModel> neural;
    if (const char* path = std::getenv("KB_NSS")) {
        int nfd = open(path, O_RDONLY); struct stat nst{}; fstat(nfd, &nst);
        void* bytes = mmap(nullptr, std::size_t(nst.st_size), PROT_READ, MAP_PRIVATE, nfd, 0); close(nfd);
        if (bytes == MAP_FAILED) { std::cerr << "cannot map " << path << "\n"; return 3; }
        neural = NeuralWordModel::load({static_cast<const std::byte*>(bytes), std::size_t(nst.st_size)});
        modelTier = "nss";
    }
    auto engine = std::make_shared<Engine>(reader, options, nullptr, neural); auto state = engine->createState();
    state->setSafety(parseSafetyPenalties(slurp(argv[2])));
    auto session = engine->createSession();
    out << "{\"kind\":\"startup\",\"engine\":\"ioskeyboard\",\"tier\":" << quote(modelTier) << ",\"words\":" << reader->wordCount() << ",\"startup_ms\":" << ms(initStart, Clock::now()) << "}\n";
    processRecord(out, "after_startup");
    std::ifstream f(argv[3]); std::string line; std::size_t events = 0; std::uint64_t wordID = 0, gen = 0;
    const bool diagnose = std::getenv("KB_DIAG") && std::string(std::getenv("KB_DIAG")) == "1";
    const bool dump = std::getenv("KB_DUMP") && std::string(std::getenv("KB_DUMP")) == "1";
    while (std::getline(f, line)) {
        std::vector<std::string> p; std::size_t s = 0;
        for (std::size_t i = 0; i <= line.size(); ++i) if (i == line.size() || line[i] == '\t') { p.push_back(line.substr(s, i - s)); s = i + 1; }
        // Optional sixth column: one simulated tap per typed character, "dx,dy" in key widths
        // from that key's centre, ';'-separated ("-" = none); see make_taps.py.
        if (p.size() != 5 && p.size() != 6) continue;
        std::vector<std::optional<TouchOffset>> taps;
        if (p.size() == 6) for (std::size_t at = 0; at <= p[5].size();) {
            auto end = std::min(p[5].find(';', at), p[5].size()); auto cell = p[5].substr(at, end - at);
            double dx = 0, dy = 0;
            if (cell != "-" && std::sscanf(cell.c_str(), "%lf,%lf", &dx, &dy) == 2) taps.push_back(TouchOffset{dx, dy}); else taps.push_back(std::nullopt);
            at = end + 1;
        }
        const std::string &id = p[0], &kind = p[1], &raw = p[2], &typed = p[3], target = lower(p[4]);
        if (events && events % 10000 == 0) processRecord(out, ("after_" + std::to_string(events)).c_str());
        ++events; ++wordID; auto context = contextWords(raw + " ");   // the word starts after a space
        if (kind == "ac") {
            auto view = state->view(); auto t = Clock::now();
            auto in = makeInput(typed, context, wordID, ++gen);
            if (taps.size() + 1 == in.characterOffsets.size()) in.taps = taps;
            auto r = session->decode(in, view);
            double elapsed = ms(t, Clock::now());
            out << "{\"id\":" << quote(id) << ",\"s\":"; words(out, r.suggestions);
            out << ",\"c\":" << (r.correction.word ? quote(*r.correction.word) : "null") << ",\"ms\":" << elapsed
                << ",\"ok\":" << (r.status == EngineStatus::ok ? 1 : 0);
            if (diagnose) {
                auto fn = funnel(*session, in, view, target);
                int rank = -1; for (std::size_t i = 0; i < r.candidates.size(); ++i) if (r.candidates[i].ranked.channel.word == target) { rank = int(i); break; }
                out << ",\"pools\":" << quote(fn.pools) << ",\"sl\":" << (fn.shortlisted ? 1 : 0) << ",\"rk\":" << rank;
            }
            // KB_DUMP=1: the ranked rows (word, channel cost, language, log frequency, score) for offline reranking.
            if (dump) {
                out << ",\"rows\":[";
                for (std::size_t i = 0; i < r.candidates.size(); ++i) {
                    const auto& row = r.candidates[i].ranked;
                    out << (i ? "," : "") << '[' << quote(row.channel.word) << ',' << row.channel.cost << ',' << row.language << ','
                        << row.channel.logFrequency << ',' << row.score << ',' << int(r.candidates[i].source) << ']';
                }
                out << ']';
                if (r.correction.gate) {
                    const auto& g = *r.correction.gate;
                    out << ",\"g\":[" << int(g.kind) << ',' << quote(g.candidate) << ',' << g.margin << ',' << r.correction.threshold << ',' << g.cost << ']';
                }
            }
            out << "}\n";
            continue;
        }
        int r0 = -1, kfound = -1; bool ok = true; double ms0 = 0; std::vector<double> lat; std::vector<std::string> first;
        for (std::size_t k = 0; k < target.size() || k < 2; ++k) {
            if (k > target.size()) break;
            auto view = state->view(); auto t = Clock::now();
            auto r = session->decode(makeInput(target.substr(0, k), context, wordID, ++gen), view);
            double elapsed = ms(t, Clock::now());
            ok = ok && r.status == EngineStatus::ok;
            int rank = k < target.size() ? rankOf(r.suggestions, target.substr(0, k), target) : -1;
            if (k == 0) { r0 = rank; ms0 = elapsed; first = r.suggestions; } else lat.push_back(elapsed);
            if (profile && k) { auto& sum = phase[k > 4]; sum[0] += r.timings.session; sum[1] += r.timings.generation; sum[2] += r.timings.scoring; sum[3] += r.timings.policy; }
            if (rank >= 0 && kfound < 0) kfound = int(k);
            if (kfound >= 0 && k >= 1) break;
        }
        if (kfound < 0) kfound = int(target.size());
        out << "{\"id\":" << quote(id) << ",\"r0\":" << r0 << ",\"kf\":" << kfound << ",\"len\":" << target.size() << ",\"s0\":"; words(out, first);
        out << ",\"ms0\":" << ms0 << ",\"msk\":["; for (std::size_t i = 0; i < lat.size(); ++i) out << (i ? "," : "") << lat[i];
        out << "],\"ok\":" << (ok ? 1 : 0) << "}\n";
    }
    if (profile) for (int b = 0; b < 2; ++b)
        out << "{\"kind\":\"profile\",\"letters\":\"" << (b ? "5+" : "1-4") << "\",\"session\":" << phase[b][0] << ",\"generation\":" << phase[b][1]
            << ",\"scoring\":" << phase[b][2] << ",\"policy\":" << phase[b][3] << "}\n";
    processRecord(out, "end");
    if (neural) out << "{\"kind\":\"nss\",\"model_steps\":" << session->neuralSteps() << "}\n";
    out << "{\"kind\":\"done\",\"events\":" << events << "}\n";
    return 0;
}
