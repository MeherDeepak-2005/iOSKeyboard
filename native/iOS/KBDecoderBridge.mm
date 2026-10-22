#import "KBDecoderBridge.h"
#include "../DecoderCore/include/PackedLexicon.hpp"
#include "../DecoderCore/include/IncrementalSearch.hpp"
#include "../DecoderCore/include/CandidateGeneration.hpp"
#include "../DecoderCore/include/Engine.hpp"
#include "../DecoderCore/include/Personalization.hpp"
#include <memory>
#include <cmath>
#include <stdexcept>

static std::vector<std::optional<kb::TouchOffset>> KBTaps(NSData *, NSData *, std::size_t);
@interface KBPackedLexicon ()
- (const kb::PackedLexicon *)nativeLexicon;
@end
@interface KBChannelCandidate ()
- (instancetype)initWithCandidate:(const kb::ChannelCandidate&)candidate;
@end

@interface KBIncrementalSeedSet ()
- (instancetype)initWithNativeSeeds:(std::shared_ptr<const kb::IncrementalSeedSet>)seeds
                            lexicon:(KBPackedLexicon *)lexicon;
- (const std::shared_ptr<const kb::IncrementalSeedSet>&)nativeSeeds;
@end

static void KBSetError(NSError **error, const std::exception& failure) {
    if (error) *error = [NSError errorWithDomain:@"KBDecoderCore" code:1
        userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:failure.what()] ?: @"Native read failed"}];
}
#if DEBUG || KB_REFERENCE_DECODER_YES
@interface KBNgramRead ()
- (instancetype)initWithRead:(const kb::Continuations&)read;
@end
@implementation KBNgramRead
- (instancetype)initWithRead:(const kb::Continuations&)read {
    if ((self = [super init])) {
        _total = read.total;
        NSMutableArray *ids = [NSMutableArray arrayWithCapacity:read.entries.size()];
        NSMutableArray *counts = [NSMutableArray arrayWithCapacity:read.entries.size()];
        for (const auto& entry : read.entries) { [ids addObject:@(entry.word)]; [counts addObject:@(entry.count)]; }
        _wordIDs = [ids copy]; _counts = [counts copy];
    }
    return self;
}
@end
#endif
@implementation KBPackedLexicon {
    NSData *_backingData;
    std::unique_ptr<kb::PackedLexicon> _reader;
}
- (instancetype)initWithBacking:(NSObject *)backing error:(NSError **)error {
    if ((self = [super init])) {
        // A mutable object would permit pointer invalidation after validation.
        if (![backing isKindOfClass:[NSData class]] || [backing isKindOfClass:[NSMutableData class]]) {
            if (error) *error = [NSError errorWithDomain:@"KBDecoderCore" code:2
                userInfo:@{NSLocalizedDescriptionKey: @"Packed vocabulary backing must be immutable"}];
            return nil;
        }
        NSData *data = (NSData *)backing;
        _backingData = data;
        try { _reader = std::make_unique<kb::PackedLexicon>(std::span{
            static_cast<const std::byte *>(data.bytes), data.length}); }
        catch (const std::exception& failure) { KBSetError(error, failure); return nil; }
    }
    return self;
}
- (NSArray<NSNumber *> *)textMetadataIDs {
    NSMutableArray *out = [NSMutableArray array]; for (auto id : _reader->textMetadataIDs()) [out addObject:@(id)]; return out;
}
- (void)installTextMetadataIDs:(NSArray<NSNumber *> *)ids characterCounts:(NSArray<NSNumber *> *)counts firstLetters:(NSArray<NSNumber *> *)first lastLetters:(NSArray<NSNumber *> *)last {
    if (ids.count != counts.count || ids.count != first.count || ids.count != last.count) throw std::invalid_argument("invalid text metadata shape");
    std::vector<kb::PackedLexicon::TextMetadata> values;
    for (NSUInteger i = 0; i < ids.count; ++i) values.push_back({ids[i].intValue, counts[i].unsignedIntegerValue,
        first[i].intValue >= 0 ? std::optional<std::uint8_t>(first[i].unsignedCharValue) : std::nullopt,
        last[i].intValue >= 0 ? std::optional<std::uint8_t>(last[i].unsignedCharValue) : std::nullopt});
    _reader->installTextMetadata(values);
}
- (void)warmGlideAnchors { _reader->warmAnchors(); }
- (NSArray<NSString *> *)anchorWordsWithFirst:(NSData *)first last:(NSData *)last perBucket:(NSUInteger)cap {
    auto words = _reader->anchorWords({static_cast<const std::uint8_t *>(first.bytes), first.length}, {static_cast<const std::uint8_t *>(last.bytes), last.length}, cap);
    NSMutableArray *out = [NSMutableArray array]; for (const auto& word : words) [out addObject:[[NSString alloc] initWithBytes:word.data() length:word.size() encoding:NSUTF8StringEncoding]]; return out;
}
- (NSArray<KBChannelCandidate *> *)completionsForPrefix:(NSString *)prefix limit:(NSUInteger)limit {
    NSData *data = [prefix dataUsingEncoding:NSUTF8StringEncoding]; auto rows = _reader->completions({static_cast<const char *>(data.bytes), data.length}, limit);
    NSMutableArray *out = [NSMutableArray array]; for (const auto& row : rows) [out addObject:[[KBChannelCandidate alloc] initWithCandidate:row]]; return out;
}
- (const void *)backingAddress { return _reader->backingAddress(); }
- (const kb::PackedLexicon *)nativeLexicon { return _reader.get(); }
- (NSUInteger)formatVersion { return _reader->version(); }
- (NSUInteger)wordCount { return _reader->wordCount(); }
#if DEBUG || KB_REFERENCE_DECODER_YES
- (NSArray<NSString *> *)allWordsAndReturnError:(NSError **)error {
    try {
        NSMutableArray *result = [NSMutableArray arrayWithCapacity:_reader->wordCount()];
        for (std::uint32_t id = 0; id < _reader->wordCount(); ++id) {
            auto bytes = _reader->word(id);
            NSString *word = [[NSString alloc] initWithBytes:bytes.data() length:bytes.size() encoding:NSUTF8StringEncoding];
            if (!word) throw std::invalid_argument("invalid UTF-8 word in vocabulary");
            [result addObject:word];
        }
        return [result copy];
    } catch (const std::exception& failure) { KBSetError(error, failure); return nil; }
}
- (NSArray<NSNumber *> *)allFrequenciesAndReturnError:(NSError **)error {
    try {
        NSMutableArray *result = [NSMutableArray arrayWithCapacity:_reader->wordCount()];
        for (std::uint32_t id = 0; id < _reader->wordCount(); ++id) [result addObject:@(_reader->frequency(id))];
        return [result copy];
    } catch (const std::exception& failure) { KBSetError(error, failure); return nil; }
}
- (NSArray<NSNumber *> *)starterIDsWithLimit:(NSUInteger)limit error:(NSError **)error {
    try {
        NSMutableArray *result = [NSMutableArray array];
        for (auto id : _reader->starterIDs(limit)) [result addObject:@(id)];
        return [result copy];
    } catch (const std::exception& failure) { KBSetError(error, failure); return nil; }
}
- (KBNgramRead *)bigramsAfter:(int32_t)context limit:(NSUInteger)limit error:(NSError **)error {
    try {
        auto read = _reader->bigrams(context, limit);
        return read ? [[KBNgramRead alloc] initWithRead:*read] : nil;
    } catch (const std::exception& failure) { KBSetError(error, failure); return nil; }
}
- (KBNgramRead *)trigramsAfter:(int32_t)first second:(int32_t)second limit:(NSUInteger)limit error:(NSError **)error {
    try {
        auto read = _reader->trigrams(first, second, limit);
        return read ? [[KBNgramRead alloc] initWithRead:*read] : nil;
    } catch (const std::exception& failure) { KBSetError(error, failure); return nil; }
}
#endif
- (NSArray<KBChannelCandidate *> *)searchWord:(NSString *)word maxCost:(double)cost
    tapOffsets:(NSData *)offsets tapValidity:(NSData *)validity
    fundedWords:(NSArray<NSString *> *)words fundedBonuses:(NSArray<NSNumber *> *)bonuses
    shouldCancel:(BOOL (^)(void))cancel error:(NSError **)error {
    try {
        NSData *utf8 = [word dataUsingEncoding:NSUTF8StringEncoding];
        if (!utf8) throw std::invalid_argument("invalid search UTF-8");
        auto taps = KBTaps(offsets, validity, utf8.length);
        if ((words == nil) != (bonuses == nil) || words.count != bonuses.count)
            throw std::invalid_argument("invalid search funding shape");
        std::vector<kb::WordFunding> funding;
        for (NSUInteger index = 0; index < words.count; ++index) {
            NSData *label = [words[index] dataUsingEncoding:NSUTF8StringEncoding];
            if (!label) throw std::invalid_argument("invalid funding UTF-8");
            funding.push_back({std::string(static_cast<const char *>(label.bytes) ?: "", label.length),
                               bonuses[index].doubleValue});
        }
        std::optional<std::span<const kb::WordFunding>> view;
        if (words != nil) view = funding;
        std::function<bool()> cancellation;
        if (cancel) cancellation = [cancel] { return bool(cancel()); };
        auto candidates = _reader->search(std::string_view(static_cast<const char *>(utf8.bytes) ?: "", utf8.length),
                                         cost, taps, view, cancellation);
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:candidates.size()];
        for (const auto& candidate : candidates) [out addObject:[[KBChannelCandidate alloc] initWithCandidate:candidate]];
        return [out copy];
    } catch (const std::exception& failure) { KBSetError(error, failure); return nil; }
}
#if DEBUG || KB_REFERENCE_DECODER_YES
- (NSArray<NSArray<NSNumber *> *> *)trigramContextsAndReturnError:(NSError **)error {
    try {
        NSMutableArray *result = [NSMutableArray array];
        for (auto context : _reader->trigramContexts()) [result addObject:@[@(context.first), @(context.second)]];
        return [result copy];
    } catch (const std::exception& failure) { KBSetError(error, failure); return nil; }
}
#endif
- (KBIncrementalSeedSet *)incrementalSeedsForTypedFirst:(uint8_t)first firstTapDX:(double)dx
        firstTapDY:(double)dy hasFirstTap:(BOOL)hasTap stateCap:(NSUInteger)cap error:(NSError **)error {
    return [self incrementalSeedsForTypedFirst:first firstTapDX:dx firstTapDY:dy hasFirstTap:hasTap
        stateCap:cap boostWords:@[] boostCounts:@[] error:error];
}
- (KBIncrementalSeedSet *)incrementalSeedsForTypedFirst:(uint8_t)first firstTapDX:(double)dx
        firstTapDY:(double)dy hasFirstTap:(BOOL)hasTap stateCap:(NSUInteger)cap
        boostWords:(NSArray<NSString *> *)words boostCounts:(NSArray<NSNumber *> *)counts error:(NSError **)error {
    try {
        if (words.count != counts.count || words.count > 3000)
            throw std::invalid_argument("invalid personalization boost snapshot");
        std::vector<kb::WordFrequencyBoost> boosts;
        boosts.reserve(words.count);
        for (NSUInteger index = 0; index < words.count; ++index) {
            double count = counts[index].doubleValue;
            if (!std::isfinite(count) || count < 0 || count > UINT32_MAX || std::floor(count) != count)
                throw std::invalid_argument("invalid personalization boost count");
            NSData *utf8 = [words[index] dataUsingEncoding:NSUTF8StringEncoding];
            if (!utf8) throw std::invalid_argument("invalid boost UTF-8");
            boosts.push_back({std::string(static_cast<const char *>(utf8.bytes) ?: "", utf8.length),
                             static_cast<std::uint32_t>(count)});
        }
        auto seeds = _reader->incrementalSeeds(first,
            hasTap ? std::optional{kb::TouchOffset{dx, dy}} : std::nullopt, cap, boosts);
        return seeds ? [[KBIncrementalSeedSet alloc] initWithNativeSeeds:std::move(seeds) lexicon:self] : nil;
    } catch (const std::exception& failure) { KBSetError(error, failure); return nil; }
}
@end

#include <cstring>
#include <limits>

@implementation KBIncrementalSeedSet {
    KBPackedLexicon *_lexicon; // Retains the exact immutable vocabulary backing.
    std::shared_ptr<const kb::IncrementalSeedSet> _seeds;
}
- (instancetype)initWithNativeSeeds:(std::shared_ptr<const kb::IncrementalSeedSet>)seeds
                            lexicon:(KBPackedLexicon *)lexicon {
    if ((self = [super init])) { _lexicon = lexicon; _seeds = std::move(seeds); }
    return self;
}
- (const std::shared_ptr<const kb::IncrementalSeedSet>&)nativeSeeds { return _seeds; }
- (NSUInteger)seedCount { return _seeds->seeds().size(); }
- (NSUInteger)cellCount { return _seeds->cellCount(); }
- (const void *)backingAddress { return _lexicon.backingAddress; }
@end

@implementation KBChannelCandidate
+ (instancetype)candidateWithWord:(NSString *)word cost:(double)cost logFrequency:(double)frequency {
    NSData *bytes = [word dataUsingEncoding:NSUTF8StringEncoding];
    return [[self alloc] initWithCandidate:{std::string(static_cast<const char *>(bytes.bytes), bytes.length), cost, frequency}];
}
- (instancetype)initWithCandidate:(const kb::ChannelCandidate&)candidate {
    if ((self = [super init])) {
        _word = [[NSString alloc] initWithBytes:candidate.word.data() length:candidate.word.size() encoding:NSUTF8StringEncoding];
        if (!_word) throw std::invalid_argument("invalid UTF-8 candidate label");
        _cost = candidate.cost; _logFrequency = candidate.logFrequency;
    }
    return self;
}
@end

// Read numeric buffers with memcpy: caller alignment is deliberately unspecified.
static std::vector<std::optional<kb::TouchOffset>> KBTaps(NSData *offsets, NSData *validity, std::size_t count) {
    if (!offsets && !validity) return {};
    if (!offsets || !validity || count > SIZE_MAX / (2 * sizeof(double)) ||
        offsets.length != count * 2 * sizeof(double) || validity.length != count)
        throw std::invalid_argument("invalid tap buffer shape");
    auto bytes = static_cast<const std::byte *>(offsets.bytes);
    auto flags = static_cast<const std::uint8_t *>(validity.bytes);
    std::vector<std::optional<kb::TouchOffset>> taps(count);
    for (std::size_t i = 0; i < count; ++i) {
        if (flags[i] > 1) throw std::invalid_argument("invalid tap validity flag");
        if (flags[i]) {
            kb::TouchOffset tap;
            std::memcpy(&tap.dx, bytes + 2 * sizeof(double) * i, sizeof(double));
            std::memcpy(&tap.dy, bytes + (2 * i + 1) * sizeof(double), sizeof(double));
            taps[i] = tap;
        }
    }
    return taps;
}

@implementation KBIncrementalSearch {
    // Keep the backing owner before its dependent C++ state so synthesized
    // reverse-order ivar destruction destroys the search before the mapping.
    KBIncrementalSeedSet *_seedSet;
    std::unique_ptr<kb::IncrementalSearch> _search;
}
- (instancetype)initWithSeedSet:(KBIncrementalSeedSet *)seeds error:(NSError **)error {
    if ((self = [super init])) {
        try {
            if (!seeds) throw std::invalid_argument("missing incremental seed set");
            _seedSet = seeds;
            _search = std::make_unique<kb::IncrementalSearch>([seeds nativeSeeds]);
        } catch (const std::exception& failure) { KBSetError(error, failure); return nil; }
    }
    return self;
}
- (instancetype)initWithWords:(NSArray<NSString *> *)words spellings:(NSArray<NSData *> *)spellings
              logFrequencies:(NSArray<NSNumber *> *)frequencies error:(NSError **)error {
    if ((self = [super init])) {
        try {
            if (words.count != spellings.count || words.count != frequencies.count)
                throw std::invalid_argument("seed buffer shape mismatch");
            std::vector<kb::LexiconSeed> seeds;
            seeds.reserve(words.count);
            for (NSUInteger i = 0; i < words.count; ++i) {
                NSData *label = [words[i] dataUsingEncoding:NSUTF8StringEncoding];
                if (!label) throw std::invalid_argument("invalid UTF-8 seed label");
                const char *labelBytes = static_cast<const char *>(label.bytes);
                const char *spellingBytes = static_cast<const char *>(spellings[i].bytes);
                seeds.push_back({std::string(labelBytes ?: "", label.length),
                    std::string(spellingBytes ?: "", spellings[i].length), frequencies[i].doubleValue});
            }
            _search = std::make_unique<kb::IncrementalSearch>(std::move(seeds));
        } catch (const std::exception& failure) { KBSetError(error, failure); return nil; }
    }
    return self;
}
- (NSUInteger)seedCount { return _search->seedCount(); }
- (NSString *)typed { return [NSString stringWithUTF8String:_search->typed().c_str()]; }
- (BOOL)advanceNormalizedWord:(NSString *)word tapOffsets:(NSData *)offsets tapValidity:(NSData *)validity error:(NSError **)error {
    try {
        NSData *utf8 = [word dataUsingEncoding:NSUTF8StringEncoding];
        if (!utf8) throw std::invalid_argument("invalid UTF-8 input");
        auto taps = KBTaps(offsets, validity, utf8.length);
        return _search->advanceNormalized(std::string_view(static_cast<const char *>(utf8.bytes) ?: "", utf8.length), taps);
    } catch (const std::exception& failure) { KBSetError(error, failure); return NO; }
}
- (NSArray<KBChannelCandidate *> *)candidatesWithMaxCost:(double)maxCost error:(NSError **)error {
    try {
        NSMutableArray *out = [NSMutableArray array];
        for (const auto& candidate : _search->candidates(maxCost))
            [out addObject:[[KBChannelCandidate alloc] initWithCandidate:candidate]];
        return [out copy];
    } catch (const std::exception& failure) { KBSetError(error, failure); return nil; }
}
@end

#if DEBUG || KB_REFERENCE_DECODER_YES
@implementation KBSpatialAudit
+ (NSData *)substitutionCostsForIntended:(NSData *)intended typed:(NSData *)typed tapOffsets:(NSData *)offsets
                            tapValidity:(NSData *)validity error:(NSError **)error {
    try {
        if (intended.length != typed.length || intended.length > SIZE_MAX / sizeof(double))
            throw std::invalid_argument("invalid spatial key buffer shape");
        auto taps = KBTaps(offsets, validity, intended.length);
        auto a = static_cast<const std::uint8_t *>(intended.bytes), b = static_cast<const std::uint8_t *>(typed.bytes);
        NSMutableData *result = [NSMutableData dataWithLength:intended.length * sizeof(double)];
        auto out = static_cast<std::byte *>(result.mutableBytes);
        for (NSUInteger i = 0; i < intended.length; ++i) {
            auto cost = kb::substitutionCost(a[i], b[i], taps.empty() ? std::nullopt : taps[i]);
            std::memcpy(out + i * sizeof(double), &cost, sizeof(double));
        }
        return [result copy];
    } catch (const std::exception& failure) { KBSetError(error, failure); return nil; }
}
+ (double)firstLetterPenaltyForLength:(NSUInteger)length candidate:(uint8_t)candidate typed:(uint8_t)typed {
    return kb::firstLetterPenalty(length, candidate, typed);
}
@end

#endif
#include "../DecoderCore/include/LanguageScoring.hpp"
@implementation KBLanguageScorer
+ (NSData *)scoresForRows:(NSData *)rows corpusTotal:(double)total
    bigramTotal:(double)biTotal bigramDiscountMass:(double)biDiscountMass
    trigramTotal:(double)triTotal trigramDiscountMass:(double)triDiscountMass error:(NSError **)error {
    try {
        constexpr std::size_t width = 6 * sizeof(double);
        if (rows.length % width != 0) throw std::invalid_argument("invalid language evidence buffer shape");
        std::vector<kb::LanguageEvidence> evidence;
        evidence.reserve(rows.length / width);
        const auto input = static_cast<const std::byte *>(rows.bytes);
        for (std::size_t index = 0; index < rows.length / width; ++index) {
            double row[6]; std::memcpy(row, input + index * width, width);
            evidence.push_back({row[0], row[1], row[2], row[3], row[4], row[5]});
        }
        auto values = kb::languageScores(evidence, total, {biTotal, biDiscountMass}, {triTotal, triDiscountMass});
        return [NSData dataWithBytes:values.data() length:values.size() * sizeof(double)];
    } catch (const std::exception& failure) { KBSetError(error, failure); return nil; }
}
@end

static std::string KBText(NSString *word) {
    NSData *bytes = [word dataUsingEncoding:NSUTF8StringEncoding];
    if (!bytes) throw std::invalid_argument("invalid UTF-8 input");
    return std::string(static_cast<const char *>(bytes.bytes), bytes.length);
}
static NSArray<KBChannelCandidate *> *KBCandidates(const std::vector<kb::ChannelCandidate>& values) {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:values.size()];
    for (const auto& value : values) [out addObject:[[KBChannelCandidate alloc] initWithCandidate:value]];
    return out;
}
static std::optional<std::vector<kb::WordFunding>> KBFunding(NSArray<NSString *> *words, NSArray<NSNumber *> *bonuses) {
    if (!words && !bonuses) return {};
    if (!words || !bonuses || words.count != bonuses.count) throw std::invalid_argument("invalid funding shape");
    std::vector<kb::WordFunding> out;
    for (NSUInteger i = 0; i < words.count; ++i) out.push_back({KBText(words[i]), bonuses[i].doubleValue});
    return out;
}
@interface KBMutableTrie ()
- (std::shared_ptr<const kb::MutableTrie>)nativeSnapshot;
- (kb::MutableTrie&)nativeMutable;
@end
@implementation KBMutableTrie {
    std::shared_ptr<kb::MutableTrie> _trie;
}
- (instancetype)init {
    if ((self = [super init])) _trie = std::make_shared<kb::MutableTrie>();
    return self;
}
- (std::shared_ptr<const kb::MutableTrie>)nativeSnapshot { return _trie; }
- (kb::MutableTrie&)nativeMutable { [self prepareMutation]; return *_trie; }
- (void)prepareMutation {
    if (_trie.use_count() != 1) _trie = std::make_shared<kb::MutableTrie>(*_trie);
}
- (void)insertWord:(NSString *)word frequency:(int64_t)frequency wordID:(int32_t)wordID {
    [self prepareMutation]; _trie->insert(KBText(word), frequency, wordID);
}
- (void)insertWord:(NSString *)word frequency:(int64_t)frequency wordID:(int32_t)wordID characterCount:(NSUInteger)count {
    [self prepareMutation]; _trie->insert(KBText(word), frequency, wordID, count);
}
- (BOOL)containsWord:(NSString *)word { return _trie->contains(KBText(word)); }
- (BOOL)hasPrefix:(NSString *)word { return _trie->hasPrefix(KBText(word)); }
- (NSNumber *)wordIDForWord:(NSString *)word {
    auto id = _trie->wordID(KBText(word)); return id ? @(*id) : nil;
}
- (NSNumber *)logFrequencyForWord:(NSString *)word {
    auto frequency = _trie->logFrequency(KBText(word)); return frequency ? @(*frequency) : nil;
}
- (void)bumpWord:(NSString *)word { [self prepareMutation]; _trie->bump(KBText(word)); }
- (NSArray<KBChannelCandidate *> *)completionsForPrefix:(NSString *)prefix limit:(NSUInteger)limit {
    return KBCandidates(_trie->completions(KBText(prefix), limit));
}
- (NSArray<KBChannelCandidate *> *)searchWord:(NSString *)word maxCost:(double)cost
    tapOffsets:(NSData *)offsets tapValidity:(NSData *)validity
    fundedWords:(NSArray<NSString *> *)words fundedBonuses:(NSArray<NSNumber *> *)bonuses error:(NSError **)error {
    try {
        auto text = KBText(word); auto taps = KBTaps(offsets, validity, text.size());
        auto funding = KBFunding(words, bonuses);
        return KBCandidates(_trie->search(text, cost, taps,
            funding ? std::optional<std::span<const kb::WordFunding>>(*funding) : std::nullopt));
    } catch (const std::exception& failure) { KBSetError(error, failure); return nil; }
}
@end
@interface KBGeneratedCandidates ()
- (instancetype)initWithGeneration:(const kb::GeneratedCandidates&)generation;
@end
@implementation KBGeneratedCandidates
- (instancetype)initWithGeneration:(const kb::GeneratedCandidates&)generation {
    if ((self = [super init])) {
        _close = KBCandidates(generation.close); _broad = KBCandidates(generation.broad);
        _injected = KBCandidates(generation.injected); _completions = KBCandidates(generation.completions);
        _displayCorrections = KBCandidates(generation.displayCorrections);
        _split = generation.split ? [[KBChannelCandidate alloc] initWithCandidate:*generation.split] : nil;
        _cancelled = generation.cancelled;
    }
    return self;
}
@end
@interface KBGenerationSnapshot ()
- (const kb::GenerationSnapshot *)nativeSnapshot;
- (instancetype)initWithSharedGeneration:(std::shared_ptr<const kb::GenerationSnapshot>)generation;
@end
@implementation KBGenerationSnapshot {
    kb::GenerationSnapshot _snapshot;
    std::shared_ptr<const kb::GenerationSnapshot> _sharedGeneration;
}
- (instancetype)initWithBoosts:(NSDictionary<NSString *, NSNumber *> *)boosts blockedWords:(NSArray<NSString *> *)blocked {
    if ((self = [super init])) {
        for (NSString *key in boosts) _snapshot.boosts.emplace(KBText(key), boosts[key].longLongValue);
        for (NSString *key in blocked) _snapshot.blocked.insert(KBText(key));
    }
    return self;
}
- (const kb::GenerationSnapshot *)nativeSnapshot { return _sharedGeneration ? _sharedGeneration.get() : &_snapshot; }
- (instancetype)initWithSharedGeneration:(std::shared_ptr<const kb::GenerationSnapshot>)generation { if ((self = [super init])) _sharedGeneration = std::move(generation); return self; }
@end
@interface KBGenerationLexicon ()
- (kb::GenerationLexicon)nativeLexicon;
- (KBPackedLexicon *)packedOwner;
@end
@implementation KBGenerationLexicon {
    KBPackedLexicon *_packed;
    KBGenerationSnapshot *_snapshot;
    std::shared_ptr<const kb::MutableTrie> _base, _supplementary, _personal;
}
- (instancetype)initWithPacked:(KBPackedLexicon *)packed base:(KBMutableTrie *)base
    supplementary:(KBMutableTrie *)supplementary personal:(KBMutableTrie *)personal
    snapshot:(KBGenerationSnapshot *)snapshot {
    if ((self = [super init])) {
        _packed = packed; _snapshot = snapshot;
        _base = [base nativeSnapshot]; _supplementary = [supplementary nativeSnapshot]; _personal = [personal nativeSnapshot];
    }
    return self;
}
- (KBPackedLexicon *)packedOwner { return _packed; }
- (kb::GenerationLexicon)nativeLexicon {
    return {[_packed nativeLexicon], _base.get(), _supplementary.get(), _personal.get(), [_snapshot nativeSnapshot]};
}
- (BOOL)containsWord:(NSString *)word { auto view=[self nativeLexicon];return view.contains(word.UTF8String ?: ""); }
@end
@implementation KBCandidateGenerator
+ (NSArray<NSNumber *> *)rankFundingBonusesWithCount:(NSUInteger)count {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; ++i) [out addObject:@(kb::rankFundingBonus(i))];
    return out;
}
+ (NSArray<NSNumber *> *)probabilityFundingBonuses:(NSArray<NSNumber *> *)probabilities floor:(double)floor {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:probabilities.count];
    for (NSNumber *probability in probabilities) [out addObject:@(kb::probabilityFundingBonus(probability.doubleValue, floor))];
    return out;
}
+ (KBGeneratedCandidates *)generateWord:(NSString *)word lexicon:(KBGenerationLexicon *)lexiconSnapshot
    tapOffsets:(NSData *)offsets tapValidity:(NSData *)validity contextSuccessors:(NSArray<NSString *> *)successors successorLengths:(NSArray<NSNumber *> *)lengths
    successorFirst:(NSArray<NSString *> *)first successorLast:(NSArray<NSString *> *)last characterOffsets:(NSArray<NSNumber *> *)characterOffsets
    fundedWords:(NSArray<NSString *> *)words fundedBonuses:(NSArray<NSNumber *> *)bonuses
    retainedStatic:(NSArray<KBChannelCandidate *> *)retained gruTier:(BOOL)gru shouldCancel:(BOOL (^)(void))cancel
    error:(NSError **)error {
    try {
        auto lexicon = [lexiconSnapshot nativeLexicon];
        auto text = KBText(word); auto funding = KBFunding(words, bonuses);
        auto taps = KBTaps(offsets, validity, text.size());
        if (lengths.count != successors.count || first.count != successors.count || last.count != successors.count) throw std::invalid_argument("invalid successor lengths shape");
        std::vector<kb::ContextSuccessor> next;
        for (NSUInteger i = 0; i < successors.count; ++i) next.push_back({KBText(successors[i]), lengths[i].unsignedIntegerValue, KBText(first[i]), KBText(last[i])});
        std::optional<std::vector<kb::ChannelCandidate>> retainedWords;
        if (retained) {
            retainedWords.emplace();
            for (KBChannelCandidate *candidate in retained)
                retainedWords->push_back({KBText(candidate.word), candidate.cost, candidate.logFrequency});
        }
        std::vector<std::size_t> boundaries; for (NSNumber *value in characterOffsets) boundaries.push_back(value.unsignedIntegerValue);
        auto result = kb::generateCandidates(lexicon, text, taps, next,
            funding ? std::optional<std::span<const kb::WordFunding>>(*funding) : std::nullopt,
            retainedWords ? std::optional<std::span<const kb::ChannelCandidate>>(*retainedWords) : std::nullopt,
            gru, cancel ? std::function<bool()>([cancel] { return bool(cancel()); }) : std::function<bool()>(), boundaries);
        return [[KBGeneratedCandidates alloc] initWithGeneration:result];
    } catch (const std::exception& failure) { KBSetError(error, failure); return nil; }
}
@end

#include "../DecoderCore/include/LanguageModel.hpp"
static std::vector<std::string> KBTexts(NSArray<NSString *> *values) {
    std::vector<std::string> out; for (NSString *value in values) out.push_back(KBText(value)); return out;
}
static kb::CountRows KBCountRows(NSArray<NSString *> *words, NSArray<NSNumber *> *counts) {
    if (words.count != counts.count) throw std::invalid_argument("count rows shape mismatch");
    kb::CountRows out;
    for (NSUInteger i = 0; i < words.count; ++i) out.emplace_back(KBText(words[i]), counts[i].longLongValue);
    return out;
}
@interface KBPersonalCounts ()
- (const kb::PersonalCounts&)nativeCounts;
- (instancetype)initWithSharedCounts:(std::shared_ptr<const kb::PersonalCounts>)counts revision:(std::uint64_t)revision;
@end
@implementation KBPersonalCounts {
    kb::PersonalCounts _counts;
    std::shared_ptr<const kb::PersonalCounts> _shared;
    std::uint64_t _revision;
}
- (instancetype)initWithUnigrams:(NSDictionary<NSString *, NSNumber *> *)unigrams
    bigramWords:(NSDictionary<NSString *, NSArray<NSString *> *> *)biWords
    bigramCounts:(NSDictionary<NSString *, NSArray<NSNumber *> *> *)biCounts
    trigramWords:(NSDictionary<NSString *, NSArray<NSString *> *> *)triWords
    trigramCounts:(NSDictionary<NSString *, NSArray<NSNumber *> *> *)triCounts {
    if ((self = [super init])) {
        for (NSString *key in unigrams) _counts.unigram.emplace(KBText(key), unigrams[key].longLongValue);
        for (NSString *key in biWords) _counts.bigram.emplace(KBText(key), KBCountRows(biWords[key], biCounts[key]));
        for (NSString *key in triWords) _counts.trigram.emplace(KBText(key), KBCountRows(triWords[key], triCounts[key]));
    }
    return self;
}
- (const kb::PersonalCounts&)nativeCounts { return _shared ? *_shared : _counts; }
- (instancetype)initWithSharedCounts:(std::shared_ptr<const kb::PersonalCounts>)counts revision:(std::uint64_t)revision { if ((self = [super init])) { _shared = std::move(counts); _revision = revision; } return self; }
- (uint64_t)revision { return _revision; }
@end
@interface KBSuccessorCounts ()
- (instancetype)initWithRows:(const kb::CountRows&)rows;
@end
@implementation KBSuccessorCounts
- (instancetype)initWithRows:(const kb::CountRows&)rows {
    if ((self = [super init])) {
        NSMutableArray *words = [NSMutableArray array], *counts = [NSMutableArray array];
        for (const auto& [word, count] : rows) { [words addObject:[[NSString alloc] initWithBytes:word.data() length:word.size() encoding:NSUTF8StringEncoding]]; [counts addObject:@(count)]; }
        _words = words; _counts = counts;
    }
    return self;
}
@end
@interface KBNativeLanguageModel ()
- (std::shared_ptr<const kb::LanguageModel>)nativeModel;
@end
@implementation KBNativeLanguageModel {
    KBPackedLexicon *_packed;
    std::shared_ptr<kb::LanguageModel> _model;
}
- (instancetype)initWithPacked:(KBPackedLexicon *)packed smoothing:(NSString *)smoothing {
    if ((self = [super init])) {
        _packed = packed;
        auto estimator = [smoothing isEqualToString:@"modifiedKneserNey"] ? kb::Smoothing::modifiedKneserNey
            : [smoothing isEqualToString:@"frequencyBackoff"] ? kb::Smoothing::frequencyBackoff : kb::Smoothing::wittenBell;
        _model = std::make_shared<kb::LanguageModel>([packed nativeLexicon], estimator);
    }
    return self;
}
- (std::shared_ptr<const kb::LanguageModel>)nativeModel { return _model; }
- (NSData *)scoresForWords:(NSArray<NSString *> *)words context:(NSArray<NSString *> *)context
    personal:(KBPersonalCounts *)personal lexicon:(KBGenerationLexicon *)lexicon {
    auto result = _model->scores(KBTexts(words), KBTexts(context), [personal nativeCounts], [lexicon nativeLexicon]);
    return [NSData dataWithBytes:result.data() length:result.size() * sizeof(double)];
}
- (NSData *)scoresForPhrases:(NSArray<NSString *> *)phrases context:(NSArray<NSString *> *)context personal:(KBPersonalCounts *)personal lexicon:(KBGenerationLexicon *)lexicon {
    auto words = KBTexts(phrases), ctx = KBTexts(context); auto view = [lexicon nativeLexicon];
    auto result = _model->scores(words, ctx, [personal nativeCounts], view);
    for (std::size_t i = 0; i < words.size(); ++i) if (words[i].find(' ') != std::string::npos) {
        std::vector<std::string> tokens; std::size_t start = 0;
        while (start < words[i].size()) { auto end = words[i].find(' ', start); if (end == std::string::npos) end = words[i].size(); if (end > start) tokens.push_back(words[i].substr(start, end - start)); start = end + 1; }
        result[i] = _model->sequence(tokens, ctx, [personal nativeCounts], view);
    }
    return [NSData dataWithBytes:result.data() length:result.size() * sizeof(double)];
}
- (double)sequenceForWords:(NSArray<NSString *> *)words context:(NSArray<NSString *> *)context
    personal:(KBPersonalCounts *)personal lexicon:(KBGenerationLexicon *)lexicon {
    return _model->sequence(KBTexts(words), KBTexts(context), [personal nativeCounts], [lexicon nativeLexicon]);
}
- (KBSuccessorCounts *)successorsForContext:(NSArray<NSString *> *)context personal:(KBPersonalCounts *)personal
    trigram:(BOOL)trigram limit:(NSUInteger)limit {
    return [[KBSuccessorCounts alloc] initWithRows:_model->successors(KBTexts(context), [personal nativeCounts], trigram, limit)];
}
+ (NSArray<NSString *> *)nextWordsWithTrigramWords:(NSArray<NSString *> *)triWords counts:(NSArray<NSNumber *> *)triCounts
    bigramWords:(NSArray<NSString *> *)biWords counts:(NSArray<NSNumber *> *)biCounts limit:(NSUInteger)limit {
    auto values = kb::LanguageModel::nextWords(KBCountRows(triWords, triCounts), KBCountRows(biWords, biCounts), limit);
    NSMutableArray *out = [NSMutableArray array];
    for (const auto& word : values) [out addObject:[[NSString alloc] initWithBytes:word.data() length:word.size() encoding:NSUTF8StringEncoding]];
    return out;
}
@end

#include "../DecoderCore/include/Ranking.hpp"
static kb::RankedRow KBRankedRow(KBScoredRow *row) {
    return {{KBText(row.word), row.cost, row.logFrequency}, KBText(row.word.precomposedStringWithCanonicalMapping),
        0, row.language, row.score, row.neural ? std::optional<double>(row.neural.doubleValue) : std::nullopt};
}
@interface KBScoredRow ()
- (instancetype)initWithRanked:(const kb::RankedRow&)row;
@end
@implementation KBScoredRow
- (instancetype)initWithRanked:(const kb::RankedRow&)row {
    if ((self = [super init])) {
        _word = [[NSString alloc] initWithBytes:row.channel.word.data() length:row.channel.word.size() encoding:NSUTF8StringEncoding];
        _cost = row.channel.cost; _logFrequency = row.channel.logFrequency;
        _language = row.language; _neural = row.neural ? @(*row.neural) : nil; _score = row.score;
    } return self;
}
+ (instancetype)rowWithWord:(NSString *)word cost:(double)cost frequency:(double)frequency
    language:(double)language neural:(NSNumber *)neural score:(double)score {
    return [[self alloc] initWithRanked:{{KBText(word), cost, frequency}, KBText(word.precomposedStringWithCanonicalMapping),
        0, language, score, neural ? std::optional<double>(neural.doubleValue) : std::nullopt}];
}
@end
static NSArray<KBScoredRow *> *KBRankedRows(const std::vector<kb::RankedRow>& rows) {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:rows.size()];
    for (const auto& row : rows) [out addObject:[[KBScoredRow alloc] initWithRanked:row]];
    return out;
}
static kb::CorrectionPolicy KBPolicy(NSArray<NSNumber *> *p) {
    if (p.count != 6) throw std::invalid_argument("invalid correction policy shape");
    return {p[0].doubleValue, p[1].doubleValue, p[2].doubleValue, p[3].doubleValue, p[4].doubleValue, p[5].doubleValue};
}
static kb::CorrectionKind KBKind(NSString *kind) {
    return [kind isEqualToString:@"realWord"] ? kb::CorrectionKind::realWord : [kind isEqualToString:@"loose"] ? kb::CorrectionKind::loose
        : [kind isEqualToString:@"severe"] ? kb::CorrectionKind::severe : kb::CorrectionKind::close;
}
@interface KBCorrectionResult ()
- (instancetype)initWithCorrection:(const kb::CorrectionResult&)result;
@end
@implementation KBCorrectionResult
- (instancetype)initWithCorrection:(const kb::CorrectionResult&)result {
    if ((self = [super init])) {
        if (result.word) _word = [[NSString alloc] initWithBytes:result.word->data() length:result.word->size() encoding:NSUTF8StringEncoding];
        _margin = result.margin; _threshold = result.threshold;
        if (result.gate) {
            const auto& gate = *result.gate;
            _kind = @[@"realWord", @"close", @"loose", @"severe"][static_cast<NSUInteger>(gate.kind)];
            _candidate = [[NSString alloc] initWithBytes:gate.candidate.data() length:gate.candidate.size() encoding:NSUTF8StringEncoding];
            _cost = gate.cost; _gap = gate.gap ? @(*gate.gap) : nil; _allowsCloseRescue = gate.allowsCloseRescue;
        }
    } return self;
}
@end
@implementation KBRanking
+ (NSArray<KBScoredRow *> *)prepareCandidates:(NSArray<KBChannelCandidate *> *)candidates safety:(NSArray<NSNumber *> *)safety extra:(KBChannelCandidate *)extra {
    if (safety.count != candidates.count) throw std::invalid_argument("invalid safety batch");
    std::vector<kb::RankedRow> rows;
    for (NSUInteger i = 0; i < candidates.count; ++i) {
        auto c = candidates[i];
        rows.push_back({{KBText(c.word), c.cost, c.logFrequency}, KBText(c.word.precomposedStringWithCanonicalMapping), safety[i].doubleValue, 0, 0, {}});
    }
    std::optional<kb::RankedRow> typed;
    if (extra) typed = {{KBText(extra.word), extra.cost, extra.logFrequency}, KBText(extra.word.precomposedStringWithCanonicalMapping), 0, 0, 0, {}};
    return KBRankedRows(kb::prepareRanking(rows, typed));
}
+ (NSArray<KBScoredRow *> *)shortlistRows:(NSArray<KBScoredRow *> *)rows extra:(KBChannelCandidate *)extra limit:(NSNumber *)limit compressed:(BOOL)compressed {
    std::vector<kb::RankedRow> native;
    for (KBScoredRow *row in rows) native.push_back(KBRankedRow(row));
    std::optional<kb::RankedRow> typed;
    if (extra) typed = {{KBText(extra.word), extra.cost, extra.logFrequency}, KBText(extra.word.precomposedStringWithCanonicalMapping), 0, 0, 0, {}};
    return KBRankedRows(kb::shortlist(std::move(native), typed, limit ? std::optional<std::size_t>(limit.unsignedIntegerValue) : std::nullopt, compressed));
}
+ (NSArray<KBScoredRow *> *)rankRows:(NSArray<KBScoredRow *> *)rows language:(NSData *)language neural:(NSData *)neural
    safety:(NSArray<NSNumber *> *)safety typed:(NSString *)typed compressed:(BOOL)compressed limit:(NSNumber *)limit {
    if (language.length != rows.count * sizeof(double) || (neural && neural.length != language.length) || safety.count != rows.count)
        throw std::invalid_argument("invalid ranking score shape");
    std::vector<kb::RankedRow> native;
    for (NSUInteger i = 0; i < rows.count; ++i) {
        auto row = KBRankedRow(rows[i]);
        std::memcpy(&row.language, static_cast<const std::byte *>(language.bytes) + i * sizeof(double), sizeof(double));
        if (neural) { double value; std::memcpy(&value, static_cast<const std::byte *>(neural.bytes) + i * sizeof(double), sizeof(double)); row.neural = value; }
        row.safety = safety[i].doubleValue; native.push_back(std::move(row));
    }
    return KBRankedRows(kb::rank(std::move(native), KBText(typed.precomposedStringWithCanonicalMapping), compressed, limit ? std::optional<std::size_t>(limit.unsignedIntegerValue) : std::nullopt));
}
+ (KBCorrectionResult *)correctRows:(NSArray<KBScoredRow *> *)rows lexicon:(KBGenerationLexicon *)lexicon costs:(NSDictionary<NSString *, NSNumber *> *)costs
    typed:(NSString *)typed characterCount:(NSUInteger)length letterFlags:(NSData *)letterFlags context:(NSArray<NSString *> *)context kept:(BOOL)kept
    loose:(NSArray<NSString *> *)loose broad:(NSArray<NSString *> *)broad policy:(NSArray<NSNumber *> *)policy {
    std::vector<kb::RankedRow> native;
    for (KBScoredRow *row in rows) native.push_back(KBRankedRow(row));
    std::unordered_map<std::string, double> nativeCosts;
    for (NSString *key in costs) nativeCosts.emplace(KBText(key), costs[key].doubleValue);
    auto looseWords = KBTexts(loose), broadWords = KBTexts(broad);
    auto flags = std::span<const std::uint8_t>(static_cast<const std::uint8_t *>(letterFlags.bytes), letterFlags.length);
    auto result = kb::correction([lexicon nativeLexicon], native, nativeCosts, KBText(typed), length, flags, KBTexts(context), kept,
        {looseWords.begin(), looseWords.end()}, {broadWords.begin(), broadWords.end()}, KBPolicy(policy));
    return [[KBCorrectionResult alloc] initWithCorrection:result];
}
+ (BOOL)acceptsKind:(NSString *)kind margin:(double)margin gap:(NSNumber *)gap cost:(double)cost allowsCloseRescue:(BOOL)allows policy:(NSArray<NSNumber *> *)policy {
    return kb::accepts(KBPolicy(policy), {KBKind(kind), "", margin, cost, gap ? std::optional<double>(gap.doubleValue) : std::nullopt, bool(allows)});
}
@end

#include "../DecoderCore/include/Glide.hpp"
static std::vector<kb::Point> KBPoints(NSData *data) {
    static_assert(sizeof(kb::Point) == 2 * sizeof(double));
    if (data.length % sizeof(kb::Point)) throw std::invalid_argument("invalid point buffer shape");
    std::vector<kb::Point> out(data.length / sizeof(kb::Point));
    if (data.length) std::memcpy(out.data(), data.bytes, data.length); return out;
}
static NSData *KBPointData(const std::vector<kb::Point>& points) { return [NSData dataWithBytes:points.data() length:points.size() * sizeof(kb::Point)]; }
static kb::GlideLayout KBGlideLayout(NSData *keys, NSData *centers, double x, double y) {
    auto points = KBPoints(centers);
    if (keys.length != points.size()) throw std::invalid_argument("invalid key layout shape");
    kb::GlideLayout out{{}, x, y}; auto labels = static_cast<const std::uint8_t *>(keys.bytes);
    for (std::size_t i = 0; i < points.size(); ++i) out.centers.emplace_back(labels[i], points[i]); return out;
}
@interface KBProcessedGlide ()
- (instancetype)initWithGlide:(const kb::ProcessedGlide&)glide;
@end
@implementation KBProcessedGlide
- (instancetype)initWithGlide:(const kb::ProcessedGlide&)glide {
    if ((self = [super init])) {
        _points = KBPointData(glide.points); _dwell = [NSData dataWithBytes:glide.dwell.data() length:glide.dwell.size()];
        NSMutableArray *values = [NSMutableArray array]; for (auto index : glide.pivots) [values addObject:@(index)]; _pivots = values;
    } return self;
}
@end
@implementation KBNativeGlide
+ (KBProcessedGlide *)preprocess:(NSData *)points keys:(NSData *)keys centers:(NSData *)centers xPitch:(double)x yPitch:(double)y spacing:(double)spacing times:(NSData *)times {
    std::vector<double> stamps;
    if (times) { if (times.length % sizeof(double)) throw std::invalid_argument("invalid timestamps"); stamps.resize(times.length / sizeof(double)); if (times.length) std::memcpy(stamps.data(), times.bytes, times.length); }
    auto result = kb::preprocess(KBPoints(points), KBGlideLayout(keys, centers, x, y), spacing, stamps);
    return result ? [[KBProcessedGlide alloc] initWithGlide:*result] : nil;
}
+ (NSData *)toGrid:(NSData *)points keys:(NSData *)keys centers:(NSData *)centers xPitch:(double)x yPitch:(double)y {
    auto values = KBPoints(points); auto layout = KBGlideLayout(keys, centers, x, y);
    for (auto& value : values) value = kb::toGrid(value, layout); return KBPointData(values);
}
+ (NSData *)resample:(NSData *)points spacing:(double)spacing { return KBPointData(kb::resample(KBPoints(points), spacing)); }
+ (NSArray<NSNumber *> *)pivots:(NSData *)points threshold:(double)threshold {
    auto result = kb::pivots(KBPoints(points), threshold); NSMutableArray *out = [NSMutableArray array];
    for (auto value : result) [out addObject:@(value)]; return out;
}
+ (NSData *)lettersNearX:(double)x y:(double)y radius:(double)radius count:(NSUInteger)count {
    auto result = kb::lettersNear({x, y}, radius, count); return [NSData dataWithBytes:result.data() length:result.size()];
}
+ (NSNumber *)nearestLetterX:(double)x y:(double)y { auto result = kb::nearestLetter({x, y}); return result ? @(*result) : nil; }
+ (NSData *)idealPath:(NSString *)word count:(NSUInteger)count { auto path = kb::idealPath(KBText(word), count); return path ? KBPointData(*path) : nil; }
+ (NSNumber *)shapeCost:(NSString *)word points:(NSData *)points band:(int)band direction:(double)direction {
    auto cost = kb::shapeCost(KBText(word), KBPoints(points), band, direction); return cost ? @(*cost) : nil;
}
+ (NSArray<KBChannelCandidate *> *)decode:(NSData *)points packed:(KBPackedLexicon *)packed width:(NSUInteger)width band:(int)band
    frequency:(double)frequency direction:(double)direction seedRadius:(double)radius window:(NSUInteger)window shouldCancel:(BOOL (^)(void))cancel {
    return KBCandidates(kb::decodeGlide(KBPoints(points), *[packed nativeLexicon], width, band, frequency, direction, radius, window,
        cancel ? std::function<bool()>([cancel] { return bool(cancel()); }) : std::function<bool()>()));
}
+ (NSArray<KBChannelCandidate *> *)sortCandidates:(NSArray<KBChannelCandidate *> *)candidates limit:(NSUInteger)limit {
    std::vector<kb::ChannelCandidate> values;
    for (KBChannelCandidate *value in candidates) values.push_back({KBText(value.word), value.cost, value.logFrequency});
    std::stable_sort(values.begin(), values.end(), [](const auto& a, const auto& b) { return a.cost < b.cost; });
    if (values.size() > limit) values.resize(limit); return KBCandidates(values);
}
@end
@implementation KBNativeGlideResampler { std::unique_ptr<kb::GlideResampler> _state; }
- (instancetype)initWithSpacing:(double)spacing { if ((self = [super init])) _state = std::make_unique<kb::GlideResampler>(spacing); return self; }
- (id)copyWithZone:(NSZone *)zone {
    KBNativeGlideResampler *copy = [[[self class] allocWithZone:zone] initWithSpacing:1]; *copy->_state = *_state; return copy;
}
- (NSData *)appendPoints:(NSData *)points { return KBPointData(_state->append(KBPoints(points))); }
- (NSData *)samples { return KBPointData(_state->samples); }
@end
@implementation KBNativeOnlineGlide { std::unique_ptr<kb::OnlineGlide> _state; }
- (instancetype)initWithWord:(NSString *)word count:(NSUInteger)count {
    if ((self = [super init])) { auto path = kb::idealPath(KBText(word), count); if (!path) return nil; _state = std::make_unique<kb::OnlineGlide>(std::move(*path)); } return self;
}
- (id)copyWithZone:(NSZone *)zone { KBNativeOnlineGlide *copy = [[self class] allocWithZone:zone]; copy->_state = std::make_unique<kb::OnlineGlide>(*_state); return copy; }
- (void)consumePoints:(NSData *)points { _state->consume(KBPoints(points)); }
- (NSData *)ideal { return KBPointData(_state->ideal); }
- (NSUInteger)sampleCount { return _state->sampleCount; }
- (double)prefixCost { return _state->prefixCost(); }
@end

#include "../DecoderCore/include/Multiword.hpp"
static kb::MultiwordHypothesis KBHypothesis(KBMultiwordHypothesis *row) { return {row.offset, KBTexts(row.words), row.cost, row.logFrequency}; }
@interface KBMultiwordHypothesis ()
- (instancetype)initWithHypothesis:(const kb::MultiwordHypothesis&)row;
@end
@implementation KBMultiwordHypothesis
- (instancetype)initWithHypothesis:(const kb::MultiwordHypothesis&)row {
    if ((self = [super init])) {
        _offset = row.offset; _cost = row.cost; _logFrequency = row.logFrequency;
        NSMutableArray *words = [NSMutableArray array]; for (const auto& word : row.words) [words addObject:[[NSString alloc] initWithBytes:word.data() length:word.size() encoding:NSUTF8StringEncoding]]; _words = words;
    } return self;
}
+ (instancetype)makeOffset:(NSUInteger)offset words:(NSArray<NSString *> *)words cost:(double)cost frequency:(double)frequency {
    return [[self alloc] initWithHypothesis:{offset, KBTexts(words), cost, frequency}];
}
@end
static NSArray<KBMultiwordHypothesis *> *KBHypotheses(const std::vector<kb::MultiwordHypothesis>& rows) {
    NSMutableArray *out = [NSMutableArray array]; for (const auto& row : rows) [out addObject:[[KBMultiwordHypothesis alloc] initWithHypothesis:row]]; return out;
}
@interface KBMultiwordPruned ()
- (instancetype)initWithPruned:(const kb::MultiwordPruned&)result;
@end
@implementation KBMultiwordPruned
- (instancetype)initWithPruned:(const kb::MultiwordPruned&)result { if ((self = [super init])) { _frontier = KBHypotheses(result.frontier); _finished = KBCandidates(result.finished); } return self; }
@end
@implementation KBNativeMultiword { KBGenerationLexicon *_owner; std::unique_ptr<kb::MultiwordSearch> _search; }
- (instancetype)initWithLexicon:(KBGenerationLexicon *)lexicon word:(NSString *)word tapOffsets:(NSData *)offsets tapValidity:(NSData *)validity {
    if ((self = [super init])) { _owner = lexicon; auto text = KBText(word); _search = std::make_unique<kb::MultiwordSearch>([lexicon nativeLexicon], text, KBTaps(offsets, validity, text.size())); } return self;
}
- (NSArray<KBMultiwordHypothesis *> *)expand:(NSArray<KBMultiwordHypothesis *> *)frontier shouldCancel:(BOOL (^)(void))cancel {
    std::vector<kb::MultiwordHypothesis> rows; for (KBMultiwordHypothesis *row in frontier) rows.push_back(KBHypothesis(row));
    return KBHypotheses(_search->expand(rows, cancel ? std::function<bool()>([cancel] { return bool(cancel()); }) : std::function<bool()>()));
}
- (KBMultiwordPruned *)prune:(NSArray<KBMultiwordHypothesis *> *)rows neural:(NSData *)neural language:(NSData *)language {
    if (neural.length != rows.count * sizeof(double) || language.length != neural.length) throw std::invalid_argument("invalid multiword score buffers");
    std::vector<kb::MultiwordHypothesis> values; for (KBMultiwordHypothesis *row in rows) values.push_back(KBHypothesis(row));
    std::vector<double> n(rows.count), l(rows.count); if (neural.length) { std::memcpy(n.data(), neural.bytes, neural.length); std::memcpy(l.data(), language.bytes, language.length); }
    return [[KBMultiwordPruned alloc] initWithPruned:_search->prune(values, n, l)];
}
@end

@implementation KBNativeGlideSession { kb::StreamingGlide _state; }
- (BOOL)consume:(NSData *)points keys:(NSData *)keys centers:(NSData *)centers xPitch:(double)x yPitch:(double)y {
    return _state.consume(KBPoints(points), KBGlideLayout(keys, centers, x, y));
}
- (void)augmentWithLexicon:(KBGenerationLexicon *)lexicon contextWords:(NSArray<NSString *> *)context dynamicWords:(NSArray<NSString *> *)dynamic {
    _state.augment([lexicon nativeLexicon], KBTexts(context), KBTexts(dynamic));
}
- (BOOL)empty { return _state.empty(); }
- (BOOL)needsAugmentation { return _state.needsAugmentation; }
- (BOOL)invalid { return _state.invalid; }
- (NSArray<KBChannelCandidate *> *)rows { return KBCandidates(_state.rows()); }
@end
@implementation KBGlidePipeline
+ (NSArray<KBChannelCandidate *> *)augmentCandidates:(NSArray<KBChannelCandidate *> *)beam lexicon:(KBGenerationLexicon *)lexicon points:(NSData *)points
    contextWords:(NSArray<NSString *> *)context dynamicWords:(NSArray<NSString *> *)dynamic gate:(double)gate shouldCancel:(BOOL (^)(void))cancel {
    std::vector<kb::ChannelCandidate> rows; for (KBChannelCandidate *c in beam) rows.push_back({KBText(c.word), c.cost, c.logFrequency});
    return KBCandidates(kb::augmentGlide([lexicon nativeLexicon], std::move(rows), KBPoints(points), KBTexts(context), KBTexts(dynamic), gate,
        cancel ? std::function<bool()>([cancel] { return bool(cancel()); }) : std::function<bool()>()));
}
+ (NSArray<KBScoredRow *> *)rankCandidates:(NSArray<KBChannelCandidate *> *)rows lexicon:(KBGenerationLexicon *)lexicon language:(NSData *)language
    safety:(NSArray<NSNumber *> *)safety sigma:(double)sigma dwell:(NSData *)dwell {
    if (language.length != rows.count * sizeof(double) || safety.count != rows.count) throw std::invalid_argument("invalid glide rank shape");
    std::vector<kb::ChannelCandidate> values; std::vector<double> l(rows.count), s;
    for (KBChannelCandidate *c in rows) values.push_back({KBText(c.word), c.cost, c.logFrequency});
    if (language.length) std::memcpy(l.data(), language.bytes, language.length);
    for (NSNumber *value in safety) s.push_back(value.doubleValue);
    return KBRankedRows(kb::rankGlide([lexicon nativeLexicon], values, l, s, sigma, {static_cast<const std::uint8_t *>(dwell.bytes), dwell.length}));
}
@end

#include "../DecoderCore/include/NeuralSearch.hpp"
@interface KBNeuralTokenizer (NativeAccess)
- (const kb::Tokenizer *)nativeTokenizer;
@end
@implementation KBNeuralTokenizer { std::unique_ptr<kb::Tokenizer> _tokenizer; }
- (instancetype)initWithData:(NSData *)data {
    if((self=[super init])) { _tokenizer=std::make_unique<kb::Tokenizer>(std::span<const uint8_t>((const uint8_t*)data.bytes,data.length)); if(!_tokenizer->valid) return nil; } return self;
}
- (NSArray<NSString *> *)pieces { NSMutableArray *out=[NSMutableArray array]; for(const auto& p:_tokenizer->pieces) [out addObject:[[NSString alloc] initWithBytes:p.data() length:p.size() encoding:NSUTF8StringEncoding] ?: @"�"]; return out; }
- (NSArray<NSNumber *> *)starts { NSMutableArray *out=[NSMutableArray array];for(auto n:_tokenizer->starts)[out addObject:@(n)];return out; }
- (NSArray<NSNumber *> *)continuations { NSMutableArray *out=[NSMutableArray array];for(auto n:_tokenizer->continuations)[out addObject:@(n)];return out; }
- (const kb::Tokenizer *)nativeTokenizer { return _tokenizer.get(); }
- (int32_t)pad { return _tokenizer->pad; }
- (int32_t)english { return _tokenizer->english; }
- (void)setCharacterLengths:(NSArray<NSNumber *> *)lengths {std::vector<uint32_t> v;for(NSNumber *n in lengths)v.push_back(n.unsignedIntValue);_tokenizer->setLengths(v);}
- (NSArray<NSNumber *> *)encodeCharacters:(NSArray<NSString *> *)characters { auto c=KBTexts(characters);NSMutableArray *out=[NSMutableArray array];for(auto n:_tokenizer->encode(c))[out addObject:@(n)];return out; }
- (NSString *)wordFromIDs:(NSArray<NSNumber *> *)ids {std::vector<int32_t> v;for(NSNumber *n in ids)v.push_back(n.intValue);return @(_tokenizer->word(v).c_str());}
@end
@implementation KBNeuralMath
+ (NSArray<NSNumber *> *)top:(NSArray<NSNumber *> *)values count:(NSUInteger)count allowed:(NSArray<NSNumber *> *)allowed {std::vector<float> v;std::vector<uint8_t> a;for(NSNumber *n in values)v.push_back(n.floatValue);for(NSNumber *n in allowed)a.push_back(n.boolValue);NSMutableArray *out=[NSMutableArray array];for(auto n:kb::topIndices(v,count,a))[out addObject:@(n)];return out;}
@end
#import <CoreML/CoreML.h>
namespace {
std::vector<int32_t> KBTokenIDs(NSArray<NSNumber *> *numbers) {std::vector<int32_t> out;for(NSNumber *n in numbers)out.push_back(n.intValue);return out;}
std::vector<float> KBLogits(MLMultiArray *logits) {
    std::vector<float> values(logits.count);
    // Most model outputs are dense. Read their storage directly to avoid boxing
    // every vocabulary logit on each recurrent beam step.
    size_t expected=1;
    bool contiguous=true;
    for(NSInteger axis=logits.shape.count-1;axis>=0;--axis) {
        if(logits.shape[axis].unsignedIntegerValue>1 && logits.strides[axis].unsignedIntegerValue!=expected)contiguous=false;
        expected*=logits.shape[axis].unsignedIntegerValue;
    }
    if(contiguous) {
        if(logits.dataType==MLMultiArrayDataTypeFloat32) {
            const auto *data=static_cast<const float *>(logits.dataPointer);
            std::copy_n(data,values.size(),values.begin());return values;
        }
        if(logits.dataType==MLMultiArrayDataTypeFloat16) {
            const auto *data=static_cast<const __fp16 *>(logits.dataPointer);
            for(size_t i=0;i<values.size();++i)values[i]=data[i];return values;
        }
        if(logits.dataType==MLMultiArrayDataTypeDouble) {
            const auto *data=static_cast<const double *>(logits.dataPointer);
            for(size_t i=0;i<values.size();++i)values[i]=static_cast<float>(data[i]);return values;
        }
    }
    // Core ML also permits non-contiguous views and other numeric formats.
    for(NSUInteger i=0;i<logits.count;++i)values[i]=[[logits objectAtIndexedSubscript:i] floatValue];
    return values;
}
class KBModelInference {
    MLModel *__strong model;
    NSMutableArray<MLMultiArray *> *__strong states;
    size_t vocabulary,layers,hidden;
public:
    KBModelInference(MLModel *m, MLMultiArray *state,size_t v,size_t l,size_t h):model(m),states([NSMutableArray arrayWithObject:state]),vocabulary(v),layers(l),hidden(h){}
    MLMultiArray *stateAt(size_t id) { return id<states.count?states[id]:nil; }
    std::optional<kb::NeuralStep> operator()(int32_t token,size_t state) {
        @autoreleasepool {
            if(state>=states.count)return std::nullopt;
            NSError *error=nil;
            auto input=[[MLMultiArray alloc] initWithShape:@[@1,@1] dataType:MLMultiArrayDataTypeInt32 error:&error];
            if(!input)return std::nullopt;input[0]=@(token);
            auto provider=[[MLDictionaryFeatureProvider alloc] initWithDictionary:@{@"token":input,@"state_in":states[state]} error:&error];
            auto output=provider?[model predictionFromFeatures:provider error:&error]:nil;
            MLMultiArray *logits=[output featureValueForName:@"logits"].multiArrayValue;
            MLMultiArray *next=[output featureValueForName:@"state_out"].multiArrayValue;
            if(!logits||logits.count!=vocabulary||!next||![next.shape isEqualToArray:@[@(layers),@1,@(hidden)]]||next.dataType!=MLMultiArrayDataTypeFloat32)return std::nullopt;
            auto values=KBLogits(logits);
            const size_t id=states.count;[states addObject:next];return kb::NeuralStep{std::move(values),id};
        }
    }
};
NSDictionary *KBWordScores(const std::vector<kb::NeuralWord>& rows) {NSMutableDictionary *out=[NSMutableDictionary dictionary];for(const auto& [word,score]:rows)out[@(word.c_str())]=@(score);return out;}
}
@implementation KBNeuralRuntime
+ (NSDictionary<NSString *,NSNumber *> *)generate:(KBNeuralTokenizer *)tokenizer model:(MLModel *)model state:(MLMultiArray *)state previous:(int32_t)previous starts:(NSArray<NSNumber *> *)starts width:(NSUInteger)width branch:(NSUInteger)branch depth:(NSUInteger)depth layers:(NSUInteger)layers hidden:(NSUInteger)hidden lexicon:(KBGenerationLexicon *)lexicon cancel:(BOOL (^)(void))cancel {
    const auto& t=*tokenizer.nativeTokenizer;KBModelInference inference(model,state,t.pieces.size(),layers,hidden);auto view=[lexicon nativeLexicon];std::vector<uint8_t> allowed;for(NSNumber *n in starts)allowed.push_back(n.boolValue);
    auto rows=kb::generateWords(t,previous,0,allowed,width,branch,depth,[&](auto token,auto id){return inference(token,id);},[&](const auto& word){return view.contains(word)&&!view.isBlocked(word);},[&]{return bool(cancel());});
    return cancel()?nil:KBWordScores(rows);
}
+ (NSDictionary<NSString *,NSNumber *> *)score:(KBNeuralTokenizer *)tokenizer model:(MLModel *)model state:(MLMultiArray *)state previous:(int32_t)previous words:(NSArray<NSString *> *)words tokens:(NSArray<NSArray<NSNumber *> *> *)tokens layers:(NSUInteger)layers hidden:(NSUInteger)hidden cancel:(BOOL (^)(void))cancel {
    const auto& t=*tokenizer.nativeTokenizer;KBModelInference inference(model,state,t.pieces.size(),layers,hidden);std::vector<std::vector<int32_t>> ids;for(NSArray *row in tokens)ids.push_back(KBTokenIDs(row));
    auto out=kb::scoreWords(t,KBTexts(words),ids,previous,0,[&](auto token,auto stateID){return inference(token,stateID);},[&]{return bool(cancel());});return out?KBWordScores(*out):nil;
}
+ (NSArray<NSString *> *)sortWords:(NSArray<NSString *> *)words scores:(NSArray<NSNumber *> *)scores limit:(NSUInteger)limit {
    std::vector<kb::NeuralWord> rows;for(NSUInteger i=0;i<std::min(words.count,scores.count);++i)rows.emplace_back(words[i].UTF8String,scores[i].doubleValue);
    std::stable_sort(rows.begin(),rows.end(),[](const auto& a,const auto& b){return a.second>b.second;});NSMutableArray *out=[NSMutableArray array];for(size_t i=0;i<std::min<size_t>(limit,rows.size());++i)[out addObject:@(rows[i].first.c_str())];return out;
}
+ (NSArray<NSNumber *> *)contextPlan:(NSArray<NSNumber *> *)tokens cached:(NSArray<NSNumber *> *)cached pad:(int32_t)pad {
    auto plan=kb::contextPlan(KBTokenIDs(tokens),KBTokenIDs(cached),pad);return @[@(plan.reuse),@(plan.start),@(plan.previous)];
}
@end
#include "../DecoderCore/include/Adaptation.hpp"
@implementation KBNumericPolicy
+ (NSArray<NSNumber *> *)touch:(NSArray<NSNumber *> *)state x:(double)x y:(double)y observe:(BOOL)observe {
    if(state.count!=5)return @[];kb::TouchStatistics s;for(size_t i=0;i<5;++i)s[i]=state[i].doubleValue;
    if(observe){s=kb::observeTouch(s,{x,y});return @[@(s[0]),@(s[1]),@(s[2]),@(s[3]),@(s[4])];}
    const auto adjusted=kb::adjustTouch(s,{x,y});return @[@(adjusted.dx),@(adjusted.dy)];
}
+ (NSArray<NSNumber *> *)glide:(NSArray<NSNumber *> *)state cost:(NSNumber *)cost {
    if(state.count!=3)return @[];std::array<double,3> s;for(size_t i=0;i<3;++i)s[i]=state[i].doubleValue;
    if(cost){s=kb::observeGlide(s,cost.doubleValue);return @[@(s[0]),@(s[1]),@(s[2])];}
    const auto p=kb::glideParameters(s);return @[@(p[0]),@(p[1])];
}
+ (NSArray<NSNumber *> *)characterPriors:(NSArray<NSNumber *> *)frequencies {std::vector<double> f;for(NSNumber *n in frequencies)f.push_back(n.doubleValue);NSMutableArray *out=[NSMutableArray array];for(auto v:kb::characterPriors(f))[out addObject:@(v)];return out;}
+ (NSArray<NSNumber *> *)contextualPriors:(NSArray<NSString *> *)letters baseLetters:(NSArray<NSString *> *)baseLetters values:(NSArray<NSNumber *> *)values {std::vector<double> f;for(NSNumber *n in values)f.push_back(n.doubleValue);NSMutableArray *out=[NSMutableArray array];for(auto v:kb::contextualPriors(KBTexts(letters),KBTexts(baseLetters),f))[out addObject:@(v)];return out;}
@end
@implementation KBNeuralRuntime (BatchScoring)
+ (NSArray<NSNumber *> *)scoreBatch:(MLModel *)model state:(MLMultiArray *)state previous:(int32_t)previous padID:(int32_t)padID rows:(NSArray<NSArray<NSNumber *> *> *)rows layers:(NSUInteger)layers hidden:(NSUInteger)hidden batchSize:(NSUInteger)batchSize time:(NSUInteger)time cancel:(BOOL (^)(void))cancel {
    if(!time||!batchSize||state.count!=layers*hidden)return nil;
    auto tokens=[[MLMultiArray alloc] initWithShape:@[@(batchSize),@(time)] dataType:MLMultiArrayDataTypeInt32 error:nil];
    auto targets=[[MLMultiArray alloc] initWithShape:@[@(batchSize),@(time)] dataType:MLMultiArrayDataTypeInt32 error:nil];
    auto mask=[[MLMultiArray alloc] initWithShape:@[@(batchSize),@(time)] dataType:MLMultiArrayDataTypeFloat32 error:nil];
    auto boundaries=[[MLMultiArray alloc] initWithShape:@[@(batchSize)] dataType:MLMultiArrayDataTypeInt32 error:nil];
    auto stateIn=[[MLMultiArray alloc] initWithShape:@[@(layers),@(batchSize),@(hidden)] dataType:MLMultiArrayDataTypeFloat32 error:nil];
    if(!tokens||!targets||!mask||!boundaries||!stateIn)return nil;
    const auto *statePtr=(const float*)state.dataPointer;auto *stateOut=(float*)stateIn.dataPointer;
    for(size_t l=0;l<layers;++l)for(size_t b=0;b<batchSize;++b)for(size_t h=0;h<hidden;++h)stateOut[(l*batchSize+b)*hidden+h]=statePtr[l*hidden+h];
    NSMutableArray *result=[NSMutableArray arrayWithCapacity:rows.count];for(size_t i=0;i<rows.count;++i)[result addObject:@0.];
    for(size_t start=0;start<rows.count;start+=batchSize){
        if(cancel())return nil;const size_t n=std::min<size_t>(batchSize,rows.count-start);auto *in=(int32_t*)tokens.dataPointer;auto *target=(int32_t*)targets.dataPointer;auto *m=(float*)mask.dataPointer;auto *boundary=(int32_t*)boundaries.dataPointer;
        for(size_t b=0;b<batchSize;++b){NSArray<NSNumber *> *row=b<n?rows[start+b]:@[];for(size_t t=0;t<time;++t){const size_t off=b*time+t;in[off]=padID;target[off]=0;m[off]=0;}
            if(row.count>=time)return nil;for(size_t t=0;t<row.count;++t){in[b*time+t]=t==0?previous:rows[start+b][t-1].intValue;target[b*time+t]=row[t].intValue;m[b*time+t]=1;}
            if(row.count)in[b*time+row.count]=row.lastObject.intValue;boundary[b]=int32_t(row.count);
        }
        NSError *error=nil;auto provider=[[MLDictionaryFeatureProvider alloc] initWithDictionary:@{@"tokens":tokens,@"state_in":stateIn,@"targets":targets,@"mask":mask,@"boundary_positions":boundaries} error:&error];
        auto output=provider?[model predictionFromFeatures:provider error:&error]:nil;auto array=[output featureValueForName:@"log_probs"].multiArrayValue;
        if(!array||array.count<n)return nil;for(size_t b=0;b<n;++b){const double value=[[array objectAtIndexedSubscript:b] doubleValue];if(!std::isfinite(value))return nil;result[start+b]=@(value);}
    }
    return result;
}
@end
#include "../DecoderCore/include/NeuralSearch.hpp"
@implementation KBNeuralMath (ContextWindow)
+ (NSArray<NSNumber *> *)trimmedContext:(NSArray<NSNumber *> *)tokens mode:(NSNumber *)mode sequenceLength:(NSUInteger)sequenceLength maximumCandidateTokens:(NSUInteger)maximumCandidateTokens {
    auto ids=KBTokenIDs(tokens);std::optional<int32_t> m;if(mode)m=mode.intValue;auto out=kb::trimmedContext(ids,m,sequenceLength,maximumCandidateTokens);NSMutableArray *values=[NSMutableArray array];for(auto id:out)[values addObject:@(id)];return values;
}
@end
@implementation KBNeuralRuntime (TransformerScoring)
+ (NSArray<NSNumber *> *)scoreTransformer:(MLModel *)model rows:(NSArray<NSArray<NSNumber *> *> *)rows context:(NSArray<NSNumber *> *)context padID:(int32_t)padID sequenceLength:(NSUInteger)sequenceLength batchSize:(NSUInteger)batchSize scoreSlots:(NSUInteger)scoreSlots cancel:(BOOL (^)(void))cancel {
    if(!sequenceLength||!batchSize||!scoreSlots||context.count==0)return nil;std::vector<int32_t> contextIDs=KBTokenIDs(context);NSMutableArray *scores=[NSMutableArray arrayWithCapacity:rows.count];for(size_t i=0;i<rows.count;++i)[scores addObject:@0.];
    auto tokens=[[MLMultiArray alloc] initWithShape:@[@(batchSize),@(sequenceLength)] dataType:MLMultiArrayDataTypeInt32 error:nil];
    auto positions=[[MLMultiArray alloc] initWithShape:@[@(batchSize),@(scoreSlots)] dataType:MLMultiArrayDataTypeInt32 error:nil];
    auto targets=[[MLMultiArray alloc] initWithShape:@[@(batchSize),@(scoreSlots)] dataType:MLMultiArrayDataTypeInt32 error:nil];
    auto mask=[[MLMultiArray alloc] initWithShape:@[@(batchSize),@(scoreSlots)] dataType:MLMultiArrayDataTypeFloat32 error:nil];
    auto next=[[MLMultiArray alloc] initWithShape:@[@(batchSize),@1] dataType:MLMultiArrayDataTypeInt32 error:nil];if(!tokens||!positions||!targets||!mask||!next)return nil;
    for(size_t start=0;start<rows.count;start+=batchSize){if(cancel())return nil;const size_t n=std::min<size_t>(batchSize,rows.count-start);size_t maxTokens=0;for(size_t b=0;b<n;++b)maxTokens=std::max<size_t>(maxTokens,rows[start+b].count);
        auto *input=(int32_t*)tokens.dataPointer;for(size_t b=0;b<batchSize;++b){std::vector<int32_t> full=contextIDs;if(b<n)for(NSNumber *v in rows[start+b])full.push_back(v.intValue);for(size_t t=0;t<sequenceLength;++t)input[b*sequenceLength+t]=t<full.size()?full[t]:padID;}
        for(size_t slotStart=0;slotStart<maxTokens;slotStart+=scoreSlots){if(cancel())return nil;auto *p=(int32_t*)positions.dataPointer;auto *t=(int32_t*)targets.dataPointer;auto *m=(float*)mask.dataPointer;auto *nx=(int32_t*)next.dataPointer;
            for(size_t b=0;b<batchSize;++b){NSArray<NSNumber *> *row=b<n?rows[start+b]:@[];nx[b]=int32_t(std::max<size_t>(0,contextIDs.size()+row.count-1));for(size_t slot=0;slot<scoreSlots;++slot){const size_t ti=slotStart+slot,offset=b*scoreSlots+slot;p[offset]=ti<row.count?int32_t(contextIDs.size()-1+ti):0;t[offset]=ti<row.count?row[ti].intValue:0;m[offset]=ti<row.count?1.f:0.f;}}
            NSError *error=nil;auto provider=[[MLDictionaryFeatureProvider alloc] initWithDictionary:@{@"tokens":tokens,@"score_positions":positions,@"target_ids":targets,@"score_mask":mask,@"next_positions":next} error:&error];auto output=provider?[model predictionFromFeatures:provider error:&error]:nil;auto array=[output featureValueForName:@"candidate_log_probs"].multiArrayValue;
            if(!array||(![array.shape isEqualToArray:@[@(batchSize)]]&&![array.shape isEqualToArray:@[@(batchSize),@1]]))return nil;const size_t stride=array.strides[0].unsignedIntegerValue;for(size_t b=0;b<n;++b){const double v=[[array objectAtIndexedSubscript:b*stride] doubleValue];if(!std::isfinite(v))return nil;scores[start+b]=@([[scores objectAtIndexedSubscript:start+b] doubleValue]+v);}
        }
    }return scores;
}
@end
@implementation KBNeuralRuntime (ContextThreading)
+ (MLMultiArray *)zeroStateWithLayers:(NSUInteger)layers hidden:(NSUInteger)hidden {
    auto state=[[MLMultiArray alloc] initWithShape:@[@(layers),@1,@(hidden)] dataType:MLMultiArrayDataTypeFloat32 error:nil];if(!state)return nil;std::memset(state.dataPointer,0,state.count*sizeof(float));return state;
}
+ (MLMultiArray *)threadContext:(NSArray<NSNumber *> *)tokens tokenizer:(KBNeuralTokenizer *)tokenizer model:(MLModel *)model state:(MLMultiArray *)state previous:(int32_t)previous layers:(NSUInteger)layers hidden:(NSUInteger)hidden cancel:(BOOL (^)(void))cancel {
    const auto& t=*tokenizer.nativeTokenizer;KBModelInference inference(model,state,t.pieces.size(),layers,hidden);auto ids=KBTokenIDs(tokens);
    auto result=kb::threadContext(ids,previous,0,[&](auto token,auto stateID){return inference(token,stateID);},[&]{return bool(cancel());});if(!result||cancel())return nil;return inference.stateAt(*result);
}
@end
@implementation KBNeuralMath (ContextWords)
+ (NSArray<NSString *> *)lastWords:(NSArray<NSString *> *)words limit:(NSUInteger)limit {auto rows=kb::lastContextWords(KBTexts(words),limit);NSMutableArray *out=[NSMutableArray array];for(auto& w:rows)[out addObject:@(w.c_str())];return out;}
+ (NSArray<NSString *> *)knownWords:(NSArray<NSString *> *)words lexicon:(KBGenerationLexicon *)lexicon firstLetters:(NSArray<NSString *> *)firstLetters {auto view=[lexicon nativeLexicon];auto rows=kb::filterKnownWords(KBTexts(words),view,KBTexts(firstLetters));NSMutableArray *out=[NSMutableArray array];for(auto& w:rows)[out addObject:@(w.c_str())];return out;}
@end
@interface KBCancellationToken ()
- (const kb::CancellationToken *)nativeToken;
@end
@implementation KBCancellationToken { kb::CancellationToken _token; }
- (void)cancel { _token.cancel(); }
- (const kb::CancellationToken *)nativeToken { return &_token; }
@end
@interface KBEngineResult ()
- (instancetype)initWithOutput:(const kb::DecodeOutput&)output;
@end
@implementation KBEngineResult
- (instancetype)initWithOutput:(const kb::DecodeOutput&)output {
    if ((self = [super init])) {
        NSMutableArray *suggestions = [NSMutableArray array], *rows = [NSMutableArray array], *sources = [NSMutableArray array];
        for (const auto& word : output.suggestions) [suggestions addObject:[[NSString alloc] initWithBytes:word.data() length:word.size() encoding:NSUTF8StringEncoding]];
        for (const auto& row : output.candidates) {
            [rows addObject:[[KBScoredRow alloc] initWithRanked:row.ranked]];
            [sources addObject:@[@"typed", @"fuzzyLexicon", @"completion", @"contextInjection", @"broadRecovery", @"splitCorrection"][static_cast<NSUInteger>(row.source)]];
        }
        _suggestions = suggestions; _rows = rows; _sources = sources;
        _correction = [[KBCorrectionResult alloc] initWithCorrection:output.correction];
        _cancelled = output.status == kb::EngineStatus::cancelled;
        _phaseMilliseconds = @[@(output.timings.session), @(output.timings.generation), @(output.timings.scoring), @(output.timings.policy)];
    } return self;
}
@end
@implementation KBSharedEngine {
    KBPackedLexicon *_resourceOwner;
    std::shared_ptr<kb::Engine> _engine;
    std::unique_ptr<kb::EngineSession> _session;
    // Immutable after init; Glide sessions share it rather than copying per gesture.
    std::shared_ptr<const std::unordered_map<std::string, double>> _penalties;
}
- (instancetype)initWithLexicon:(KBGenerationLexicon *)lexicon model:(KBNativeLanguageModel *)model policy:(NSArray<NSNumber *> *)policy
    penalties:(NSDictionary<NSString *,NSNumber *> *)penalties profile:(BOOL)profile {
    if ((self = [super init])) {
        _resourceOwner = [lexicon packedOwner];
        auto view = [lexicon nativeLexicon];
        // _resourceOwner retains the mapping, EngineSession retains Engine.
        auto packed = std::shared_ptr<const kb::PackedLexicon>(view.packed, [owner = _resourceOwner](const kb::PackedLexicon *) { (void)owner; });
        kb::EngineOptions options; options.correction = KBPolicy(policy); options.profile = profile;
        _engine = std::make_shared<kb::Engine>(packed, options, [model nativeModel]); _session = _engine->createSession();
        auto table = std::make_shared<std::unordered_map<std::string, double>>();
        for (NSString *word in penalties) table->emplace(KBText(word), penalties[word].doubleValue);
        _penalties = std::move(table);
    } return self;
}
- (KBEngineResult *)decodeWord:(NSString *)word normalized:(NSString *)normalized context:(NSArray<NSString *> *)context
    identity:(NSData *)identity offsets:(NSArray<NSNumber *> *)characterOffsets letterFlags:(NSData *)flags
    tapOffsets:(NSData *)offsets tapValidity:(NSData *)validity lexicon:(KBGenerationLexicon *)lexicon
    personal:(KBPersonalCounts *)personal topWords:(NSArray<NSString *> *)topWords kept:(BOOL)kept token:(KBCancellationToken *)token error:(NSError **)error {
    try {
        if (identity.length != 7 * sizeof(std::uint64_t)) throw std::invalid_argument("invalid identity shape");
        kb::DecodeInput input; std::uint64_t fields[7]; std::memcpy(fields, identity.bytes, sizeof(fields));
        input.identity = {fields[0], fields[1], fields[2], fields[3], fields[4], fields[5], fields[6]};
        input.word = KBText(word); input.normalized = KBText(normalized); input.context = KBTexts(context); input.kept = kept;
        for (NSNumber *offset in characterOffsets) input.characterOffsets.push_back(offset.unsignedIntegerValue);
        const auto *bytes = static_cast<const std::uint8_t *>(flags.bytes); input.letterFlags.assign(bytes, bytes + flags.length);
        input.taps = KBTaps(offsets, validity, input.normalized.size());
        auto top = KBTexts(topWords);
        kb::EngineView view{[lexicon nativeLexicon], &[personal nativeCounts], top, _penalties.get(), personal.revision};
        return [[KBEngineResult alloc] initWithOutput:_session->decode(input, view, [token nativeToken])];
    } catch (const std::exception& failure) { KBSetError(error, failure); return nil; }
}
- (void)memoryPressure { _session->memoryPressure(); }
@end
static NSDictionary *KBExportCounts(const std::unordered_map<std::string, std::int64_t>& counts) {
    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:counts.size()];
    for (const auto& [key,count] : counts) out[[[NSString alloc] initWithBytes:key.data() length:key.size() encoding:NSUTF8StringEncoding]] = @(count);
    return out;
}
static NSDictionary *KBExportContexts(const std::unordered_map<std::string, kb::CountRows>& rows) {
    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:rows.size()];
    for (const auto& [key,row] : rows) {
        NSMutableDictionary *counts = [NSMutableDictionary dictionaryWithCapacity:row.size()];
        for (const auto& [word,count] : row) counts[[[NSString alloc] initWithBytes:word.data() length:word.size() encoding:NSUTF8StringEncoding]] = @(count);
        out[[[NSString alloc] initWithBytes:key.data() length:key.size() encoding:NSUTF8StringEncoding]] = counts;
    } return out;
}
@implementation KBPersonalState { kb::Personalization _state; }
- (uint64_t)epoch { return _state.epoch(); }
- (NSDictionary *)unigrams { return KBExportCounts(_state.counts()->unigram); }
- (NSDictionary *)bigrams { return KBExportContexts(_state.counts()->bigram); }
- (NSDictionary *)trigrams { return KBExportContexts(_state.counts()->trigram); }
- (NSDictionary *)confirmed { return KBExportCounts(_state.confirmed()); }
- (KBPersonalCounts *)snapshot { return [[KBPersonalCounts alloc] initWithSharedCounts:_state.counts() revision:_state.revision()]; }
- (void)install:(KBPersonalCounts *)counts confirmed:(NSDictionary<NSString *,NSNumber *> *)confirmed epoch:(uint64_t)epoch {
    kb::PersonalizationSnapshot snapshot; snapshot.counts = [counts nativeCounts]; snapshot.epoch = epoch;
    for (NSString *word in confirmed) snapshot.confirmed.emplace(KBText(word), confirmed[word].longLongValue);
    _state.install(std::move(snapshot));
}
- (void)reset:(uint64_t)epoch { _state.reset(epoch); }
- (void)learn:(NSString *)word context:(NSArray<NSString *> *)context { _state.learn(KBTexts(context), KBText(word)); }
- (void)demote:(NSString *)word { _state.demote(KBText(word)); }
- (void)confirm:(NSString *)word { _state.confirm(KBText(word)); }
- (void)releaseKeep:(NSString *)word { _state.releaseKeep(KBText(word)); }
- (BOOL)kept:(NSString *)word { return _state.kept(KBText(word)); }
- (NSInteger)count:(NSString *)word { return _state.counts()->uni(KBText(word)); }
- (BOOL)prune { return _state.prune(); }
- (BOOL)allowsAdoption:(NSString *)word count:(NSInteger)count lexicon:(KBGenerationLexicon *)lexicon { return _state.allowsAdoption(KBText(word), count, [lexicon nativeLexicon]); }
@end
@interface KBSharedGlide ()
- (instancetype)initWithEngine:(std::shared_ptr<kb::Engine>)engine penalties:(std::shared_ptr<const std::unordered_map<std::string,double>>)penalties context:(NSArray<NSString *> *)context;
@end
@implementation KBSharedEngine (Glide)
- (KBSharedGlide *)glideSessionWithContext:(NSArray<NSString *> *)context {
    return [[KBSharedGlide alloc] initWithEngine:_engine penalties:_penalties context:context];
}
@end
@implementation KBSharedGlide {
    std::unique_ptr<kb::EngineSession> _session;
    std::shared_ptr<const std::unordered_map<std::string,double>> _penalties;
    kb::CancellationToken _token;
}
- (instancetype)initWithEngine:(std::shared_ptr<kb::Engine>)engine penalties:(std::shared_ptr<const std::unordered_map<std::string,double>>)penalties context:(NSArray<NSString *> *)context {
    if ((self = [super init])) { _session = engine->createSession(); _session->beginGlide(KBTexts(context)); _penalties = std::move(penalties); } return self;
}
- (NSArray<KBScoredRow *> *)update:(NSData *)points keys:(NSData *)keys centers:(NSData *)centers xPitch:(double)x yPitch:(double)y
    lexicon:(KBGenerationLexicon *)lexicon personal:(KBPersonalCounts *)personal dynamicWords:(NSArray<NSString *> *)dynamic error:(NSError **)error {
    try {
        auto layout = KBGlideLayout(keys,centers,x,y); auto path = KBPoints(points); auto words = KBTexts(dynamic);
        kb::EngineView view{[lexicon nativeLexicon], &[personal nativeCounts], {}, _penalties.get(), personal.revision};
        return KBRankedRows(_session->updateGlide(path,layout,view,words,&_token));
    } catch (const std::exception& e) { KBSetError(error,e); return nil; }
}
- (void)cancel { _token.cancel(); }
@end
@implementation KBVocabularyState { kb::VocabularyState _state; }
- (instancetype)initWithBlocked:(NSArray<NSString *> *)blocked {if((self=[super init])){std::unordered_set<std::string> words;for(NSString*word in blocked)words.insert(KBText(word));_state.setBlocked(std::move(words));}return self;}
- (KBGenerationSnapshot *)snapshot {return [[KBGenerationSnapshot alloc] initWithSharedGeneration:_state.snapshot()];}
- (NSDictionary *)boosts {return KBExportCounts(_state.snapshot()->boosts);}
- (void)supplementary:(NSString *)word frequency:(NSInteger)frequency glide:(BOOL)glide {_state.supplementary(KBText(word),frequency,glide);}
- (BOOL)note:(NSString *)word count:(NSInteger)count allowAdoption:(BOOL)allow threshold:(NSInteger)threshold glide:(BOOL)glide
    packed:(KBPackedLexicon *)packed base:(KBMutableTrie *)base supplementary:(KBMutableTrie *)supplementary personal:(KBMutableTrie *)personal {
    auto baseline=[base nativeSnapshot],supp=[supplementary nativeSnapshot];
    auto& mutablePersonal=[personal nativeMutable];kb::GenerationLexicon lexicon{[packed nativeLexicon],baseline.get(),supp.get(),&mutablePersonal,nullptr};
    return _state.noteUse(lexicon,mutablePersonal,KBText(word),count,allow,threshold,glide);
}
- (NSArray<NSString *> *)dynamicWords:(NSUInteger)limit {NSMutableArray*out=[NSMutableArray array];for(const auto&word:_state.dynamicWords(limit))[out addObject:[[NSString alloc]initWithBytes:word.data() length:word.size() encoding:NSUTF8StringEncoding]];return out;}
- (void)resetPersonalization {_state.resetPersonalization();}
@end
