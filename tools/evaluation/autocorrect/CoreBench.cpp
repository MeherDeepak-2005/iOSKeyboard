// CoreV4 side of the autocorrect/suggestion comparison (27 Oct 2026).
// Engine construction and the suggestion request are copied from
// ../corev4-smoothing-v2-2026-10-26/CoreEval.cpp (itself from
// ../laptop-comparison/CoreMain.cpp) minus the smoothing hook, so the pristine
// CAdaptexTextInterface path runs. Learning is disabled and every request starts
// from ResetToString, so results do not depend on request order.
//
// Input TSV rows: id <TAB> kind <TAB> context <TAB> typed <TAB> target
//   kind "ac": one request with the full typed word after the raw context text.
//   kind "nw": type target one character at a time after context; record the
//              suggestions at k=0 (next-word) and the first k with target in the top 3.
#include "stdafx.h"
#include "adaptextextinterface.h"
#include "atxdictdetail.h"
#include "atxdictionarymanager.h"
#include "atxwordassociation.h"
#include "kptpal.h"
#include <algorithm>
#include <chrono>
#include <codecvt>
#include <fstream>
#include <iostream>
#include <locale>
#include <mach/mach.h>
#include <sys/resource.h>
using Clock = std::chrono::steady_clock;
static double ms(Clock::time_point a, Clock::time_point b) { return std::chrono::duration<double, std::milli>(b - a).count(); }
static std::string quote(const std::string& s) {
    std::string r = "\"";
    for (unsigned char c : s) {
        if (c == '"' || c == '\\') r += '\\';
        if (c == '\n') { r += "\\n"; continue; }
        if (c == '\t') { r += "\\t"; continue; }
        if (c < 0x20) continue;
        r += char(c);
    }
    return r + '"';
}
static std::vector<KPTUniCharT> utf16(const std::string& s) {
    std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t> conv;
    auto u = conv.from_bytes(s);
    std::vector<KPTUniCharT> v(u.begin(), u.end());
    v.push_back(0);
    return v;
}
static std::string utf8(const KPTUniCharT* p, size_t n) {
    std::u16string u;
    for (size_t i = 0; i < n; ++i) u += char16_t(p[i]);
    std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t> conv;
    return conv.to_bytes(u);
}
static std::string lower(std::string s) { for (auto& c : s) c = char(std::tolower((unsigned char)c)); return s; }
struct Result { std::vector<std::string> words; std::string correction; double elapsed = 0; int reset = 1, suggest = 1; };
static Result suggest(CAdaptexTextInterface& e, const std::string& context, const std::string& typed) {
    std::string text = context;
    if (!text.empty()) text += ' ';
    text += typed;
    auto input = utf16(text);
    TGenericSuggestionList list;
    AtiSuggestionRequestT req{};
    req.numWords = 3;
    req.options = ATX_SUGGREQ_ENABLECOMPLETIONS | ATX_SUGGREQ_MISSING_SPACE_CORRECTION;
    if (typed.empty()) req.options |= ATX_SUGGREQ_NEXT_WORD;
    req.returnedList = &list;
    auto start = Clock::now();
    Result r;
    r.reset = e.ResetToString(input.data(), input.size() - 1, false);
    r.suggest = e.GetSuggestionList(&req);
    r.elapsed = ms(start, Clock::now());
    for (auto s : list) {
        auto w = utf8(s->stringData.GetString(), s->stringData.GetLength());
        r.words.push_back(w);
        if (r.correction.empty() && (s->source & ATX_IS_AUTOCORRECTION_WORD)) r.correction = w;
        delete s;
    }
    return r;
}
// Rank among the first three entries that are not the verbatim typed prefix (CoreV4
// always lists the literal first; iOSKeyboard appends it only without a correction).
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
static void words(std::ostream& o, const Result& r) {
    o << '[';
    for (size_t i = 0; i < r.words.size(); ++i) { if (i) o << ','; o << quote(r.words[i]); }
    o << ']';
}
static void processRecord(std::ostream& out, const char* label) {
    rusage usage{};
    getrusage(RUSAGE_SELF, &usage);
    task_vm_info_data_t info{};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count);
    out << "{\"kind\":\"process\",\"at\":" << quote(label) << ",\"peak_rss_bytes\":" << usage.ru_maxrss
        << ",\"footprint_bytes\":" << info.phys_footprint << "}\n";
}

int main(int argc, char** argv) {
    if (argc < 5) { std::cerr << "profile cases.tsv output.jsonl dictionary [medium|aggressive]\n"; return 2; }
    std::string profile = argv[1], dictionary = argv[4], mode = argc > 5 ? argv[5] : "medium";
    std::ofstream out(argv[3]);
    auto initStart = Clock::now();
    KPTPalStartupSettingsT pal{};
    pal.startupOptions = eKPTPalInitOutput | eKPTPalInitErrorStack;
    pal.applicationDirPath = profile.c_str();
    pal.tempDirPath = "/tmp";
    pal.outputBufferSize = 1024;
    auto palStatus = KPTPalCreateEnvironment(&pal);
    ATXPlatformSettingsT settings{};
    settings.m_Options = ATX_SUPPORTED_PLATFORM_SETTINGS_VERSION;
    settings.m_Platform = ATXPLATFORM_IOS;
    settings.m_FormFactor = 3;
    strcpy(settings.m_KeyMapFileName, "engus");
    settings.m_KeyMapFileNameLength = 5;
    std::string locale = dictionary == "english_in" ? "engin" : dictionary == "enggb" ? "enggb" : "engus";
    for (int i = 0; i < 5; ++i) settings.m_DefaultLanguageDescriptor[i] = locale[i];
    std::string langDir = profile + "/Lang", base = profile + "/";
    settings.m_CoreUIFileDirectories.m_pLanguageKeyMapDirectory = const_cast<char*>(langDir.c_str());
    CAdaptexTextInterface::SetEnabled(true);
    CAdaptexTextInterface engine(profile.c_str(), base.c_str(), &settings);
    auto construction = engine.GetConstructionStatus();
    auto load = engine.LoadUserProfile();
    if (palStatus != 0 || construction != ATXSuccess || load != ATXSuccess) {
        out << "{\"kind\":\"startup_failure\"}\n";
        return 3;
    }
    int32_t ff = 2;
    engine.SetParam(ATXCOREPARAM_FORMFACTOR, 4, &ff);
    ff = 3;
    engine.SetParam(ATXCOREPARAM_FORMFACTOR, 4, &ff);
    engine.SetState(engine.GetState() & ~ATI_STATE_LEARN);
    ATXDictionaryDetailT* details = nullptr;
    int n = 0;
    engine.GetDictionaryPriorities(&details, &n);
    for (int i = 1; i < n; ++i) if (std::string(details[i].Name) == dictionary) std::swap(details[0], details[i]);
    auto priority = engine.SetDictionaryPriorities(details, n);
    ATXDictionaryDetailT_DeleteArray(details, n);
    int32_t on = 1;
    engine.SetParam(ATXCOREPARAM_WAEC_ENABLE, 4, &on);
    engine.SetParam(ATXCOREPARAM_WAAC_ENABLE, 4, &on);
    ATXAutoCorrectionModeT m = mode == "aggressive" ? ATXAggressive : ATXMedium;
    engine.SetParam(ATXCOREPARAM_WAAC_MODE, sizeof(m), &m);
    out << "{\"kind\":\"startup\",\"engine\":\"corev4\",\"dictionary\":" << quote(dictionary) << ",\"mode\":" << quote(mode)
        << ",\"startup_ms\":" << ms(initStart, Clock::now()) << ",\"english_first\":" << (priority == 1 ? "true" : "false") << "}\n";
    processRecord(out, "after_startup");

    std::ifstream f(argv[2]);
    std::string line;
    size_t events = 0;
    while (std::getline(f, line)) {
        std::vector<std::string> p;
        size_t s = 0;
        for (size_t i = 0; i <= line.size(); ++i)
            if (i == line.size() || line[i] == '\t') { p.push_back(line.substr(s, i - s)); s = i + 1; }
        if (p.size() != 5) continue;
        const std::string &id = p[0], &kind = p[1], &context = p[2], &typed = p[3], target = lower(p[4]);
        ++events;
        if (kind == "ac") {
            Result r = suggest(engine, context, typed);
            out << "{\"id\":" << quote(id) << ",\"s\":";
            words(out, r);
            out << ",\"c\":" << (r.correction.empty() ? "null" : quote(r.correction)) << ",\"ms\":" << r.elapsed
                << ",\"ok\":" << (r.reset == 1 && r.suggest == 1 ? 1 : 0) << "}\n";
            continue;
        }
        int r0 = -1, kfound = -1;
        bool ok = true;
        double ms0 = 0;
        std::vector<double> lat;
        Result first;
        // k = 0 (next word) and k = 1 always run; stop at the first k < len with the
        // target offered. Not offered before the last letter: kf = len (no savings).
        for (size_t k = 0; k < target.size() || k < 2; ++k) {
            if (k > target.size()) break;
            Result r = suggest(engine, context, target.substr(0, k));
            ok = ok && r.reset == 1 && r.suggest == 1;
            int rank = k < target.size() ? rankOf(r.words, target.substr(0, k), target) : -1;
            if (k == 0) { r0 = rank; ms0 = r.elapsed; first = r; } else lat.push_back(r.elapsed);
            if (rank >= 0 && kfound < 0) kfound = int(k);
            if (kfound >= 0 && k >= 1) break;
        }
        if (kfound < 0) kfound = int(target.size());
        out << "{\"id\":" << quote(id) << ",\"r0\":" << r0 << ",\"kf\":" << kfound << ",\"len\":" << target.size() << ",\"s0\":";
        words(out, first);
        out << ",\"ms0\":" << ms0 << ",\"msk\":[";
        for (size_t i = 0; i < lat.size(); ++i) out << (i ? "," : "") << lat[i];
        out << "],\"ok\":" << (ok ? 1 : 0) << "}\n";
    }
    processRecord(out, "end");
    out << "{\"kind\":\"done\",\"events\":" << events << "}\n";
    return 0;
}
