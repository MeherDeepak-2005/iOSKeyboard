// Android transport only. No scoring/DP policy is duplicated here.
#include <jni.h>
#include "PackedLexicon.hpp"
#include "IncrementalSearch.hpp"
#include "PlatformContract.hpp"
#include "LanguageScoring.hpp"
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <cmath>
#include <algorithm>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <string>
#include <unordered_map>

namespace {
class MappedFile final {
public:
    explicit MappedFile(const std::string& path) {
        if (path.find('\0') != std::string::npos) throw std::invalid_argument("embedded NUL in dictionary path");
        int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
        if (fd < 0) throw std::runtime_error("dictionary file cannot be opened");
        struct stat status {};
        if (fstat(fd, &status) != 0 || !S_ISREG(status.st_mode) || status.st_size <= 0 ||
            static_cast<std::uintmax_t>(status.st_size) > std::numeric_limits<std::size_t>::max()) {
            close(fd); throw std::invalid_argument("invalid dictionary file size/type");
        }
        size_ = static_cast<std::size_t>(status.st_size);
        bytes_ = mmap(nullptr, size_, PROT_READ, MAP_PRIVATE, fd, 0);
        close(fd);
        if (bytes_ == MAP_FAILED) throw std::runtime_error("dictionary mapping failed");
    }
    ~MappedFile() { munmap(bytes_, size_); }
    MappedFile(const MappedFile&) = delete;
    MappedFile& operator=(const MappedFile&) = delete;
    MappedFile(MappedFile&&) = delete;
    MappedFile& operator=(MappedFile&&) = delete;
    std::span<const std::byte> bytes() const { return {static_cast<const std::byte*>(bytes_), size_}; }
private:
    void* bytes_ = MAP_FAILED;
    std::size_t size_ = 0;
};
class Session final {
public:
    explicit Session(const std::string& path) : mapping(path), lexicon(mapping.bytes()) {}
    ~Session() = default;
    Session(const Session&) = delete;
    Session& operator=(const Session&) = delete;
    Session(Session&&) = delete;
    Session& operator=(Session&&) = delete;
    // Declaration order matters: search dies before lexicon, then mapping.
    MappedFile mapping;
    kb::PackedLexicon lexicon;
    std::unique_ptr<kb::IncrementalSearch> search;
    std::mutex lane;
};
std::mutex registryMutex;
std::unordered_map<jlong, std::shared_ptr<Session>> registry;
jlong nextHandle = 1;

std::shared_ptr<Session> lookup(jlong handle) {
    std::lock_guard guard(registryMutex);
    auto item = registry.find(handle);
    if (item == registry.end()) throw std::invalid_argument("closed/unknown decoder handle");
    return item->second; // close cannot invalidate an in-flight call.
}
void fail(JNIEnv* env, const std::exception& error) {
    if (env->ExceptionCheck()) return;
    jclass type = env->FindClass("java/lang/IllegalStateException");
    if (type) { env->ThrowNew(type, error.what()); env->DeleteLocalRef(type); }
}
std::string bytes(JNIEnv* env, jbyteArray value) {
    if (!value) throw std::invalid_argument("missing UTF-8 input buffer");
    std::string out(static_cast<std::size_t>(env->GetArrayLength(value)), '\0');
    if (!out.empty()) env->GetByteArrayRegion(value, 0, static_cast<jsize>(out.size()), reinterpret_cast<jbyte*>(out.data()));
    if (env->ExceptionCheck()) throw std::runtime_error("UTF-8 buffer read failed");
    return out;
}
jobject javaCandidates(JNIEnv* env, const std::vector<kb::ChannelCandidate>& candidates) {
        if (candidates.size() > static_cast<std::size_t>(std::numeric_limits<jsize>::max()))
            throw std::length_error("candidate array too large");
        const auto count = static_cast<jsize>(candidates.size());
        jclass strings = env->FindClass("java/lang/String");
        if (!strings) return nullptr;
        jobjectArray words = env->NewObjectArray(count, strings, nullptr); env->DeleteLocalRef(strings);
        jdoubleArray costs = env->NewDoubleArray(count), frequencies = env->NewDoubleArray(count);
        if (!words || !costs || !frequencies) return nullptr;
        std::vector<jdouble> costValues, frequencyValues;
        costValues.reserve(candidates.size()); frequencyValues.reserve(candidates.size());
        for (jsize index = 0; index < count; ++index) {
            const auto& label = candidates[static_cast<std::size_t>(index)].word;
            // NewStringUTF accepts modified UTF-8, so enforce this adapter's
            // English ASCII contract before crossing JNI (no truncating NULs).
            if (!std::all_of(label.begin(), label.end(), [](unsigned char byte) {
                    return (byte >= 'a' && byte <= 'z') || byte == '\'';
                })) throw std::invalid_argument("non-ASCII English candidate label");
            jstring word = env->NewStringUTF(label.c_str());
            if (!word) return nullptr;
            env->SetObjectArrayElement(words, index, word); env->DeleteLocalRef(word);
            if (env->ExceptionCheck()) return nullptr;
            costValues.push_back(candidates[static_cast<std::size_t>(index)].cost);
            frequencyValues.push_back(candidates[static_cast<std::size_t>(index)].logFrequency);
        }
        if (count > 0) {
            env->SetDoubleArrayRegion(costs, 0, count, costValues.data());
            env->SetDoubleArrayRegion(frequencies, 0, count, frequencyValues.data());
        }
        if (env->ExceptionCheck()) return nullptr;
        jclass result = env->FindClass("com/xploree/decoder/ChannelCandidates");
        if (!result) return nullptr;
        jmethodID ctor = env->GetMethodID(result, "<init>", "([Ljava/lang/String;[D[D)V");
        if (!ctor) { env->DeleteLocalRef(result); return nullptr; }
        jobject out = env->NewObject(result, ctor, words, costs, frequencies); env->DeleteLocalRef(result);
        return out;
}
std::vector<std::optional<kb::TouchOffset>> tapBuffers(JNIEnv* env, jdoubleArray offsets, jbyteArray validity, std::size_t count) {
        std::vector<std::optional<kb::TouchOffset>> taps;
        if (offsets || validity) {
            if (!offsets || !validity || env->GetArrayLength(validity) != static_cast<jsize>(count) ||
                count > static_cast<std::size_t>(std::numeric_limits<jsize>::max()) / 2 ||
                env->GetArrayLength(offsets) != static_cast<jsize>(count * 2))
                throw std::invalid_argument("invalid tap buffer shape");
            auto flags = bytes(env, validity);
            std::vector<jdouble> values(count * 2);
            if (!values.empty()) env->GetDoubleArrayRegion(offsets, 0, static_cast<jsize>(values.size()), values.data());
            if (env->ExceptionCheck()) throw std::runtime_error("tap offsets read failed");
            taps.resize(count);
            for (std::size_t index = 0; index < count; ++index) {
                if (flags[index] != 0 && flags[index] != 1) throw std::invalid_argument("invalid tap validity");
                if (flags[index]) taps[index] = kb::TouchOffset{values[index * 2], values[index * 2 + 1]};
            }
        }
        return taps;
}
void requireSearch(const Session& session) {
    if (!session.search) throw std::logic_error("beginWord must select a supported root first");
}
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_xploree_decoder_NativeChannelDecoder_nativeOpen(JNIEnv* env, jobject, jbyteArray path) {
    try {
        auto session = std::make_shared<Session>(bytes(env, path));
        std::lock_guard guard(registryMutex);
        if (nextHandle == std::numeric_limits<jlong>::max()) throw std::length_error("decoder handle space exhausted");
        const auto handle = nextHandle++;
        registry.emplace(handle, std::move(session));
        return handle;
    } catch (const std::exception& error) { fail(env, error); return 0; }
}
extern "C" JNIEXPORT jboolean JNICALL
Java_com_xploree_decoder_NativeChannelDecoder_nativeBegin(JNIEnv* env, jobject, jlong handle,
        jint first, jboolean hasTap, jdouble dx, jdouble dy, jobjectArray words, jintArray counts) {
    try {
        auto session = lookup(handle); std::lock_guard guard(session->lane);
        if (!words || !counts || env->GetArrayLength(words) != env->GetArrayLength(counts) ||
            env->GetArrayLength(words) > 3000 || first < 'a' || first > 'z')
            throw std::invalid_argument("invalid root or personalization snapshot");
        std::vector<jint> values(static_cast<std::size_t>(env->GetArrayLength(counts)));
        if (!values.empty()) env->GetIntArrayRegion(counts, 0, static_cast<jsize>(values.size()), values.data());
        if (env->ExceptionCheck()) throw std::runtime_error("boost counts read failed");
        std::vector<kb::WordFrequencyBoost> boosts;
        boosts.reserve(values.size());
        for (std::size_t index = 0; index < values.size(); ++index) {
            if (values[index] < 0) throw std::invalid_argument("negative personalization count");
            auto word = static_cast<jstring>(env->GetObjectArrayElement(words, static_cast<jsize>(index)));
            if (!word) throw std::invalid_argument("missing personalization word");
            const char* text = env->GetStringUTFChars(word, nullptr);
            if (!text) { env->DeleteLocalRef(word); throw std::runtime_error("boost string read failed"); }
            try { boosts.push_back({text, static_cast<std::uint32_t>(values[index])}); }
            catch (...) { env->ReleaseStringUTFChars(word, text); env->DeleteLocalRef(word); throw; }
            env->ReleaseStringUTFChars(word, text); env->DeleteLocalRef(word);
        }
        auto seeds = session->lexicon.incrementalSeeds(static_cast<std::uint8_t>(first),
            hasTap ? std::optional{kb::TouchOffset{dx, dy}} : std::nullopt,
            kb::defaultIncrementalStateCap, boosts);
        session->search = seeds ? std::make_unique<kb::IncrementalSearch>(std::move(seeds)) : nullptr;
        return session->search ? JNI_TRUE : JNI_FALSE;
    } catch (const std::exception& error) { fail(env, error); return JNI_FALSE; }
}
extern "C" JNIEXPORT jboolean JNICALL
Java_com_xploree_decoder_NativeChannelDecoder_nativeAdvance(JNIEnv* env, jobject, jlong handle,
        jbyteArray word, jdoubleArray offsets, jbyteArray validity) {
    try {
        auto session = lookup(handle); std::lock_guard guard(session->lane); requireSearch(*session);
        auto typed = bytes(env, word);
        auto taps = tapBuffers(env, offsets, validity, typed.size());
        return session->search->advanceNormalized(typed, taps) ? JNI_TRUE : JNI_FALSE;
    } catch (const std::exception& error) { fail(env, error); return JNI_FALSE; }
}
extern "C" JNIEXPORT jobject JNICALL
Java_com_xploree_decoder_NativeChannelDecoder_nativeCandidates(JNIEnv* env, jobject, jlong handle, jdouble maxCost) {
    try {
        auto session = lookup(handle); std::lock_guard guard(session->lane); requireSearch(*session);
        const auto candidates = session->search->candidates(maxCost);
        return javaCandidates(env, candidates);
    } catch (const std::exception& error) { fail(env, error); return nullptr; }
}
extern "C" JNIEXPORT void JNICALL
Java_com_xploree_decoder_NativeChannelDecoder_nativeClose(JNIEnv* env, jobject, jlong handle) {
    try { std::lock_guard guard(registryMutex); registry.erase(handle); }
    catch (const std::exception& error) { fail(env, error); }
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_xploree_decoder_NativeChannelDecoder_nativeSearch(JNIEnv* env, jobject, jlong handle,
        jbyteArray word, jdouble radius, jdoubleArray offsets, jbyteArray validity, jobjectArray words, jdoubleArray bonuses) {
    try {
        auto session = lookup(handle); std::lock_guard guard(session->lane);
        if ((words == nullptr) != (bonuses == nullptr) ||
            (words && env->GetArrayLength(words) != env->GetArrayLength(bonuses)))
            throw std::invalid_argument("invalid search funding shape");
        std::vector<kb::WordFunding> funding;
        std::optional<std::span<const kb::WordFunding>> view;
        if (words) {
            std::vector<jdouble> values(static_cast<std::size_t>(env->GetArrayLength(bonuses)));
            if (!values.empty()) env->GetDoubleArrayRegion(bonuses, 0, static_cast<jsize>(values.size()), values.data());
            if (env->ExceptionCheck()) throw std::runtime_error("funding values read failed");
            for (std::size_t index = 0; index < values.size(); ++index) {
                auto label = static_cast<jstring>(env->GetObjectArrayElement(words, static_cast<jsize>(index)));
                if (!label) throw std::invalid_argument("missing funding label");
                const char* text = env->GetStringUTFChars(label, nullptr);
                if (!text) { env->DeleteLocalRef(label); throw std::runtime_error("funding label read failed"); }
                try { funding.push_back({text, values[index]}); }
                catch (...) { env->ReleaseStringUTFChars(label, text); env->DeleteLocalRef(label); throw; }
                env->ReleaseStringUTFChars(label, text); env->DeleteLocalRef(label);
            }
            view = funding;
        }
        auto typed = bytes(env, word);
        auto taps = tapBuffers(env, offsets, validity, typed.size());
        auto candidates = session->lexicon.search(typed, radius, taps, view);
        return javaCandidates(env, candidates);
    } catch (const std::exception& error) { fail(env, error); return nullptr; }
}
extern "C" JNIEXPORT jdoubleArray JNICALL
Java_com_xploree_decoder_NativeChannelDecoder_nativeLanguageScores(JNIEnv* env, jobject, jdoubleArray rows,
        jdouble mass, jdouble biTotal, jdouble biDiscountMass, jdouble triTotal, jdouble triDiscountMass) {
    try {
        if (!rows || env->GetArrayLength(rows) % 6 != 0) throw std::invalid_argument("invalid language row shape");
        std::vector<jdouble> values(static_cast<std::size_t>(env->GetArrayLength(rows)));
        if (!values.empty()) env->GetDoubleArrayRegion(rows, 0, static_cast<jsize>(values.size()), values.data());
        if (env->ExceptionCheck()) throw std::runtime_error("language rows read failed");
        std::vector<kb::LanguageEvidence> evidence;
        evidence.reserve(values.size() / 6);
        for (std::size_t index = 0; index < values.size(); index += 6)
            evidence.push_back({values[index], values[index+1], values[index+2],
                               values[index+3], values[index+4], values[index+5]});
        auto scores = kb::languageScores(evidence, mass, {biTotal, biDiscountMass}, {triTotal, triDiscountMass});
        jdoubleArray out = env->NewDoubleArray(static_cast<jsize>(scores.size()));
        if (out && !scores.empty()) env->SetDoubleArrayRegion(out, 0, static_cast<jsize>(scores.size()), scores.data());
        return out;
    } catch (const std::exception& error) { fail(env, error); return nullptr; }
}
