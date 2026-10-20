#import "KBDecoderBridge.h"
#include "../DecoderCore/include/PackedLexicon.hpp"
#include "../DecoderCore/include/IncrementalSearch.hpp"
#include "../DecoderCore/include/CandidateGeneration.hpp"
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
@end
@implementation KBMutableTrie {
    std::shared_ptr<kb::MutableTrie> _trie;
}
- (instancetype)init {
    if ((self = [super init])) _trie = std::make_shared<kb::MutableTrie>();
    return self;
}
- (std::shared_ptr<const kb::MutableTrie>)nativeSnapshot { return _trie; }
- (void)prepareMutation {
    if (_trie.use_count() != 1) _trie = std::make_shared<kb::MutableTrie>(*_trie);
}
- (void)insertWord:(NSString *)word frequency:(int64_t)frequency wordID:(int32_t)wordID {
    [self prepareMutation]; _trie->insert(KBText(word), frequency, wordID);
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
@end
@implementation KBGenerationSnapshot {
    kb::GenerationSnapshot _snapshot;
}
- (instancetype)initWithBoosts:(NSDictionary<NSString *, NSNumber *> *)boosts blockedWords:(NSArray<NSString *> *)blocked {
    if ((self = [super init])) {
        for (NSString *key in boosts) _snapshot.boosts.emplace(KBText(key), boosts[key].longLongValue);
        for (NSString *key in blocked) _snapshot.blocked.insert(KBText(key));
    }
    return self;
}
- (const kb::GenerationSnapshot *)nativeSnapshot { return &_snapshot; }
@end
@interface KBGenerationLexicon ()
- (kb::GenerationLexicon)nativeLexicon;
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
- (kb::GenerationLexicon)nativeLexicon {
    return {[_packed nativeLexicon], _base.get(), _supplementary.get(), _personal.get(), [_snapshot nativeSnapshot]};
}
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
    fundedWords:(NSArray<NSString *> *)words fundedBonuses:(NSArray<NSNumber *> *)bonuses
    retainedStatic:(NSArray<KBChannelCandidate *> *)retained gruTier:(BOOL)gru shouldCancel:(BOOL (^)(void))cancel
    error:(NSError **)error {
    try {
        auto lexicon = [lexiconSnapshot nativeLexicon];
        auto text = KBText(word); auto funding = KBFunding(words, bonuses);
        auto taps = KBTaps(offsets, validity, text.size());
        if (lengths.count != successors.count) throw std::invalid_argument("invalid successor lengths shape");
        std::vector<kb::ContextSuccessor> next;
        for (NSUInteger i = 0; i < successors.count; ++i) next.push_back({KBText(successors[i]), lengths[i].unsignedIntegerValue});
        std::optional<std::vector<kb::ChannelCandidate>> retainedWords;
        if (retained) {
            retainedWords.emplace();
            for (KBChannelCandidate *candidate in retained)
                retainedWords->push_back({KBText(candidate.word), candidate.cost, candidate.logFrequency});
        }
        auto result = kb::generateCandidates(lexicon, text, taps, next,
            funding ? std::optional<std::span<const kb::WordFunding>>(*funding) : std::nullopt,
            retainedWords ? std::optional<std::span<const kb::ChannelCandidate>>(*retainedWords) : std::nullopt,
            gru, cancel ? std::function<bool()>([cancel] { return bool(cancel()); }) : std::function<bool()>());
        return [[KBGeneratedCandidates alloc] initWithGeneration:result];
    } catch (const std::exception& failure) { KBSetError(error, failure); return nil; }
}
@end
