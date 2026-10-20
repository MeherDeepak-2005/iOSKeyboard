#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@class KBIncrementalSeedSet;
@class KBChannelCandidate;

// iOS ownership and transport. Portable algorithms live exclusively in DecoderCore.
#if DEBUG || KB_REFERENCE_DECODER_YES
@interface KBNgramRead : NSObject
@property(nonatomic, readonly) NSUInteger total;
@property(nonatomic, readonly) NSArray<NSNumber *> *wordIDs;
@property(nonatomic, readonly) NSArray<NSNumber *> *counts;
- (instancetype)init NS_UNAVAILABLE;
@end

#endif

@interface KBPackedLexicon : NSObject
// Retains this exact immutable NSData object; C++ borrows its bytes without a copy.
- (nullable instancetype)initWithBacking:(NSObject *)backing error:(NSError **)error;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) NSUInteger formatVersion;
@property(nonatomic, readonly) NSUInteger wordCount;
@property(nonatomic, readonly) const void *backingAddress;
#if DEBUG || KB_REFERENCE_DECODER_YES
- (nullable NSArray<NSString *> *)allWordsAndReturnError:(NSError **)error;
- (nullable NSArray<NSNumber *> *)allFrequenciesAndReturnError:(NSError **)error;
- (nullable NSArray<NSNumber *> *)starterIDsWithLimit:(NSUInteger)limit error:(NSError **)error;
- (nullable KBNgramRead *)bigramsAfter:(int32_t)context limit:(NSUInteger)limit error:(NSError **)error __attribute__((swift_error(nonnull_error)));
- (nullable KBNgramRead *)trigramsAfter:(int32_t)first second:(int32_t)second limit:(NSUInteger)limit error:(NSError **)error __attribute__((swift_error(nonnull_error)));
- (nullable NSArray<NSArray<NSNumber *> *> *)trigramContextsAndReturnError:(NSError **)error;
#endif
- (nullable NSArray<KBChannelCandidate *> *)searchWord:(NSString *)word maxCost:(double)cost
    tapOffsets:(nullable NSData *)offsets tapValidity:(nullable NSData *)validity
    fundedWords:(nullable NSArray<NSString *> *)words fundedBonuses:(nullable NSArray<NSNumber *> *)bonuses
    shouldCancel:(nullable BOOL (^)(void))cancel error:(NSError **)error
    NS_SWIFT_NAME(search(word:maxCost:tapOffsets:tapValidity:fundedWords:fundedBonuses:shouldCancel:));
- (NSArray<NSNumber *> *)textMetadataIDs;
- (void)installTextMetadataIDs:(NSArray<NSNumber *> *)ids characterCounts:(NSArray<NSNumber *> *)counts
    firstLetters:(NSArray<NSNumber *> *)first lastLetters:(NSArray<NSNumber *> *)last;
- (void)warmGlideAnchors;
- (NSArray<NSString *> *)anchorWordsWithFirst:(NSData *)first last:(NSData *)last perBucket:(NSUInteger)cap;
- (NSArray<KBChannelCandidate *> *)completionsForPrefix:(NSString *)prefix limit:(NSUInteger)limit;
// Prepares immutable native seed metadata directly from the retained mapping.
// Nil is the same unsupported/cap fallback as LangData.incrementalSeeds.
- (nullable KBIncrementalSeedSet *)incrementalSeedsForTypedFirst:(uint8_t)first
        firstTapDX:(double)dx firstTapDY:(double)dy hasFirstTap:(BOOL)hasTap
        stateCap:(NSUInteger)cap error:(NSError **)error __attribute__((swift_error(nonnull_error)));
- (nullable KBIncrementalSeedSet *)incrementalSeedsForTypedFirst:(uint8_t)first
        firstTapDX:(double)dx firstTapDY:(double)dy hasFirstTap:(BOOL)hasTap
        stateCap:(NSUInteger)cap boostWords:(NSArray<NSString *> *)words
        boostCounts:(NSArray<NSNumber *> *)counts error:(NSError **)error __attribute__((swift_error(nonnull_error)));
@end
NS_ASSUME_NONNULL_END

NS_ASSUME_NONNULL_BEGIN
@interface KBIncrementalSeedSet : NSObject
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) NSUInteger seedCount;
@property(nonatomic, readonly) NSUInteger cellCount;
@property(nonatomic, readonly) const void *backingAddress;
@end

@interface KBChannelCandidate : NSObject
@property(nonatomic, readonly) NSString *word;
@property(nonatomic, readonly) double cost;
@property(nonatomic, readonly) double logFrequency;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)candidateWithWord:(NSString *)word cost:(double)cost logFrequency:(double)frequency NS_SWIFT_NAME(make(word:cost:logFrequency:));
@end

@interface KBIncrementalSearch : NSObject
// Shared immutable seeds; no per-word Swift/Foundation boxing or string copies.
// Retains the seed set and mapping for the entire session lifetime.
- (nullable instancetype)initWithSeedSet:(KBIncrementalSeedSet *)seeds error:(NSError **)error;
- (nullable instancetype)initWithWords:(NSArray<NSString *> *)words
                            spellings:(NSArray<NSData *> *)spellings
                       logFrequencies:(NSArray<NSNumber *> *)frequencies error:(NSError **)error;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) NSUInteger seedCount;
@property(nonatomic, readonly) NSString *typed;
// Two native-endian Doubles per tap, one byte validity flag per typed byte.
// Both buffers are nil for an absent/mismatched tap row; consumed synchronously.
- (BOOL)advanceNormalizedWord:(NSString *)word tapOffsets:(nullable NSData *)offsets
                 tapValidity:(nullable NSData *)validity error:(NSError **)error __attribute__((swift_error(nonnull_error)));
- (nullable NSArray<KBChannelCandidate *> *)candidatesWithMaxCost:(double)maxCost error:(NSError **)error;
@end

#if DEBUG || KB_REFERENCE_DECODER_YES
@interface KBSpatialAudit : NSObject
// Batched audit seam; no per-key Swift callback. Byte keys, Double dx/dy, byte flags.
+ (nullable NSData *)substitutionCostsForIntended:(NSData *)intended typed:(NSData *)typed
                                     tapOffsets:(NSData *)offsets tapValidity:(NSData *)validity error:(NSError **)error;
+ (double)firstLetterPenaltyForLength:(NSUInteger)length candidate:(uint8_t)candidate typed:(uint8_t)typed;
@end
#endif
NS_ASSUME_NONNULL_END

NS_ASSUME_NONNULL_BEGIN
@interface KBLanguageScorer : NSObject
// Six native-endian Doubles per row: continuation unigram mass, discounted bi/tri counts, personal uni/bi/tri.
// Synchronous whole-batch transport; result owns one Double per candidate.
+ (nullable NSData *)scoresForRows:(NSData *)rows corpusTotal:(double)total
    bigramTotal:(double)biTotal bigramDiscountMass:(double)biDiscountMass
    trigramTotal:(double)triTotal trigramDiscountMass:(double)triDiscountMass error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END

NS_ASSUME_NONNULL_BEGIN
// Mutable native trie. Caller serializes mutation and search (Lexicon's lock).
@interface KBMutableTrie : NSObject
- (void)insertWord:(NSString *)word frequency:(int64_t)frequency wordID:(int32_t)wordID;
- (void)insertWord:(NSString *)word frequency:(int64_t)frequency wordID:(int32_t)wordID characterCount:(NSUInteger)count;
- (BOOL)containsWord:(NSString *)word;
- (BOOL)hasPrefix:(NSString *)prefix;
- (nullable NSNumber *)wordIDForWord:(NSString *)word;
- (nullable NSNumber *)logFrequencyForWord:(NSString *)word;
- (void)bumpWord:(NSString *)word;
- (NSArray<KBChannelCandidate *> *)completionsForPrefix:(NSString *)prefix limit:(NSUInteger)limit;
- (nullable NSArray<KBChannelCandidate *> *)searchWord:(NSString *)word maxCost:(double)cost
    tapOffsets:(nullable NSData *)offsets tapValidity:(nullable NSData *)validity
    fundedWords:(nullable NSArray<NSString *> *)words fundedBonuses:(nullable NSArray<NSNumber *> *)bonuses
    error:(NSError **)error NS_SWIFT_NAME(search(word:maxCost:tapOffsets:tapValidity:fundedWords:fundedBonuses:));
@end

@interface KBGeneratedCandidates : NSObject
@property(nonatomic, readonly) NSArray<KBChannelCandidate *> *close;
@property(nonatomic, readonly) NSArray<KBChannelCandidate *> *broad;
@property(nonatomic, readonly) NSArray<KBChannelCandidate *> *injected;
@property(nonatomic, readonly) NSArray<KBChannelCandidate *> *completions;
@property(nonatomic, readonly) NSArray<KBChannelCandidate *> *displayCorrections;
@property(nonatomic, readonly, nullable) KBChannelCandidate *split;
@property(nonatomic, readonly) BOOL cancelled;
- (instancetype)init NS_UNAVAILABLE;
@end

// Immutable, cached until a vocabulary-learning event changes the boosts.
@interface KBGenerationSnapshot : NSObject
- (instancetype)initWithBoosts:(NSDictionary<NSString *, NSNumber *> *)boosts
    blockedWords:(NSArray<NSString *> *)blocked;
- (instancetype)init NS_UNAVAILABLE;
@end

// Retains the mapping and copy-on-write mutable snapshots. Construct under the
// Lexicon lock, then release that lock before any static trie walk.
@interface KBGenerationLexicon : NSObject
- (instancetype)initWithPacked:(nullable KBPackedLexicon *)packed base:(KBMutableTrie *)base
    supplementary:(KBMutableTrie *)supplementary personal:(KBMutableTrie *)personal
    snapshot:(KBGenerationSnapshot *)snapshot;
- (instancetype)init NS_UNAVAILABLE;
- (BOOL)containsWord:(NSString *)word;
- (BOOL)isBlockedWord:(NSString *)word;
@end

@interface KBCandidateGenerator : NSObject
+ (NSArray<NSNumber *> *)rankFundingBonusesWithCount:(NSUInteger)count;
+ (NSArray<NSNumber *> *)probabilityFundingBonuses:(NSArray<NSNumber *> *)probabilities floor:(double)floor;
// One synchronous, whole-generation call. Native code owns traversal and policy;
// no per-node, per-word, safety or frequency callback crosses into Swift.
+ (nullable KBGeneratedCandidates *)generateWord:(NSString *)word
    lexicon:(KBGenerationLexicon *)lexicon
    tapOffsets:(nullable NSData *)offsets tapValidity:(nullable NSData *)validity
    contextSuccessors:(NSArray<NSString *> *)successors successorLengths:(NSArray<NSNumber *> *)lengths
    successorFirst:(NSArray<NSString *> *)first successorLast:(NSArray<NSString *> *)last characterOffsets:(NSArray<NSNumber *> *)characterOffsets
    fundedWords:(nullable NSArray<NSString *> *)words fundedBonuses:(nullable NSArray<NSNumber *> *)bonuses
    retainedStatic:(nullable NSArray<KBChannelCandidate *> *)retained gruTier:(BOOL)gru
    shouldCancel:(nullable BOOL (^)(void))cancel error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END

NS_ASSUME_NONNULL_BEGIN
@interface KBPersonalCounts : NSObject
@property(nonatomic, readonly) uint64_t revision;
- (instancetype)initWithUnigrams:(NSDictionary<NSString *, NSNumber *> *)unigrams
    bigramWords:(NSDictionary<NSString *, NSArray<NSString *> *> *)biWords
    bigramCounts:(NSDictionary<NSString *, NSArray<NSNumber *> *> *)biCounts
    trigramWords:(NSDictionary<NSString *, NSArray<NSString *> *> *)triWords
    trigramCounts:(NSDictionary<NSString *, NSArray<NSNumber *> *> *)triCounts;
@end
@interface KBSuccessorCounts : NSObject
@property(nonatomic, readonly) NSArray<NSString *> *words;
@property(nonatomic, readonly) NSArray<NSNumber *> *counts;
@end
@interface KBNativeLanguageModel : NSObject
- (instancetype)initWithPacked:(nullable KBPackedLexicon *)packed smoothing:(NSString *)smoothing;
- (NSData *)scoresForWords:(NSArray<NSString *> *)words context:(NSArray<NSString *> *)context
    personal:(KBPersonalCounts *)personal lexicon:(KBGenerationLexicon *)lexicon;
- (NSData *)scoresForPhrases:(NSArray<NSString *> *)phrases context:(NSArray<NSString *> *)context personal:(KBPersonalCounts *)personal lexicon:(KBGenerationLexicon *)lexicon;
- (double)sequenceForWords:(NSArray<NSString *> *)words context:(NSArray<NSString *> *)context
    personal:(KBPersonalCounts *)personal lexicon:(KBGenerationLexicon *)lexicon;
- (KBSuccessorCounts *)successorsForContext:(NSArray<NSString *> *)context personal:(KBPersonalCounts *)personal
    trigram:(BOOL)trigram limit:(NSUInteger)limit;
+ (NSArray<NSString *> *)nextWordsWithTrigramWords:(NSArray<NSString *> *)triWords counts:(NSArray<NSNumber *> *)triCounts
    bigramWords:(NSArray<NSString *> *)biWords counts:(NSArray<NSNumber *> *)biCounts limit:(NSUInteger)limit;
@end
NS_ASSUME_NONNULL_END

NS_ASSUME_NONNULL_BEGIN
@interface KBScoredRow : NSObject
@property(nonatomic, readonly) NSString *word;
@property(nonatomic, readonly) double cost, logFrequency, language, score;
@property(nonatomic, readonly, nullable) NSNumber *neural;
+ (instancetype)rowWithWord:(NSString *)word cost:(double)cost frequency:(double)frequency
    language:(double)language neural:(nullable NSNumber *)neural score:(double)score NS_SWIFT_NAME(make(word:cost:frequency:language:neural:score:));
@end
@interface KBCorrectionResult : NSObject
@property(nonatomic, readonly, nullable) NSString *word;
@property(nonatomic, readonly) double margin, threshold, cost;
@property(nonatomic, readonly, nullable) NSNumber *gap;
@property(nonatomic, readonly, nullable) NSString *kind, *candidate;
@property(nonatomic, readonly) BOOL allowsCloseRescue;
@end
@interface KBRanking : NSObject
+ (NSArray<KBScoredRow *> *)prepareCandidates:(NSArray<KBChannelCandidate *> *)candidates
    safety:(NSArray<NSNumber *> *)safety extra:(nullable KBChannelCandidate *)extra;
+ (NSArray<KBScoredRow *> *)shortlistRows:(NSArray<KBScoredRow *> *)rows extra:(nullable KBChannelCandidate *)extra
    limit:(nullable NSNumber *)limit compressed:(BOOL)compressed;
+ (NSArray<KBScoredRow *> *)rankRows:(NSArray<KBScoredRow *> *)rows language:(NSData *)language
    neural:(nullable NSData *)neural safety:(NSArray<NSNumber *> *)safety typed:(NSString *)typed
    compressed:(BOOL)compressed limit:(nullable NSNumber *)limit;
+ (KBCorrectionResult *)correctRows:(NSArray<KBScoredRow *> *)rows lexicon:(KBGenerationLexicon *)lexicon
    costs:(NSDictionary<NSString *, NSNumber *> *)costs typed:(NSString *)typed characterCount:(NSUInteger)length
    letterFlags:(NSData *)letterFlags context:(NSArray<NSString *> *)context kept:(BOOL)kept
    loose:(NSArray<NSString *> *)loose broad:(NSArray<NSString *> *)broad policy:(NSArray<NSNumber *> *)policy;
+ (BOOL)acceptsKind:(NSString *)kind margin:(double)margin gap:(nullable NSNumber *)gap cost:(double)cost
    allowsCloseRescue:(BOOL)allows policy:(NSArray<NSNumber *> *)policy;
@end
NS_ASSUME_NONNULL_END

NS_ASSUME_NONNULL_BEGIN
@interface KBProcessedGlide : NSObject
@property(nonatomic, readonly) NSData *points, *dwell;
@property(nonatomic, readonly) NSArray<NSNumber *> *pivots;
@end
@interface KBNativeGlide : NSObject
+ (nullable KBProcessedGlide *)preprocess:(NSData *)points keys:(NSData *)keys centers:(NSData *)centers
    xPitch:(double)xPitch yPitch:(double)yPitch spacing:(double)spacing times:(nullable NSData *)times;
+ (NSData *)toGrid:(NSData *)points keys:(NSData *)keys centers:(NSData *)centers xPitch:(double)xPitch yPitch:(double)yPitch;
+ (NSData *)resample:(NSData *)points spacing:(double)spacing;
+ (NSArray<NSNumber *> *)pivots:(NSData *)points threshold:(double)threshold;
+ (NSData *)lettersNearX:(double)x y:(double)y radius:(double)radius count:(NSUInteger)count;
+ (nullable NSNumber *)nearestLetterX:(double)x y:(double)y;
+ (nullable NSData *)idealPath:(NSString *)word count:(NSUInteger)count;
+ (nullable NSNumber *)shapeCost:(NSString *)word points:(NSData *)points band:(int)band direction:(double)direction;
+ (NSArray<KBChannelCandidate *> *)decode:(NSData *)points packed:(KBPackedLexicon *)packed width:(NSUInteger)width
    band:(int)band frequency:(double)frequency direction:(double)direction seedRadius:(double)seedRadius
    window:(NSUInteger)window shouldCancel:(nullable BOOL (^)(void))cancel;
+ (NSArray<KBChannelCandidate *> *)sortCandidates:(NSArray<KBChannelCandidate *> *)candidates limit:(NSUInteger)limit;
@end
@interface KBNativeGlideResampler : NSObject <NSCopying>
- (instancetype)initWithSpacing:(double)spacing;
- (NSData *)appendPoints:(NSData *)points;
@property(nonatomic, readonly) NSData *samples;
@end
@interface KBNativeOnlineGlide : NSObject <NSCopying>
- (nullable instancetype)initWithWord:(NSString *)word count:(NSUInteger)count;
- (void)consumePoints:(NSData *)points;
@property(nonatomic, readonly) NSData *ideal;
@property(nonatomic, readonly) NSUInteger sampleCount;
@property(nonatomic, readonly) double prefixCost;
@end
NS_ASSUME_NONNULL_END

NS_ASSUME_NONNULL_BEGIN
@interface KBMultiwordHypothesis : NSObject
@property(nonatomic, readonly) NSUInteger offset;
@property(nonatomic, readonly) NSArray<NSString *> *words;
@property(nonatomic, readonly) double cost, logFrequency;
+ (instancetype)makeOffset:(NSUInteger)offset words:(NSArray<NSString *> *)words cost:(double)cost frequency:(double)frequency NS_SWIFT_NAME(make(offset:words:cost:frequency:));
@end
@interface KBMultiwordPruned : NSObject
@property(nonatomic, readonly) NSArray<KBMultiwordHypothesis *> *frontier;
@property(nonatomic, readonly) NSArray<KBChannelCandidate *> *finished;
@end
@interface KBNativeMultiword : NSObject
- (instancetype)initWithLexicon:(KBGenerationLexicon *)lexicon word:(NSString *)word
    tapOffsets:(nullable NSData *)offsets tapValidity:(nullable NSData *)validity;
- (NSArray<KBMultiwordHypothesis *> *)expand:(NSArray<KBMultiwordHypothesis *> *)frontier shouldCancel:(nullable BOOL (^)(void))cancel;
- (KBMultiwordPruned *)prune:(NSArray<KBMultiwordHypothesis *> *)rows neural:(NSData *)neural language:(NSData *)language;
@end
NS_ASSUME_NONNULL_END
NS_ASSUME_NONNULL_BEGIN
@interface KBNativeGlideSession : NSObject
- (BOOL)consume:(NSData *)points keys:(NSData *)keys centers:(NSData *)centers xPitch:(double)xPitch yPitch:(double)yPitch;
- (void)augmentWithLexicon:(KBGenerationLexicon *)lexicon contextWords:(NSArray<NSString *> *)contextWords dynamicWords:(NSArray<NSString *> *)dynamicWords;
@property(nonatomic, readonly) BOOL empty, needsAugmentation, invalid;
@property(nonatomic, readonly) NSArray<KBChannelCandidate *> *rows;
@end
@interface KBGlidePipeline : NSObject
+ (NSArray<KBChannelCandidate *> *)augmentCandidates:(NSArray<KBChannelCandidate *> *)beam lexicon:(KBGenerationLexicon *)lexicon
    points:(NSData *)points contextWords:(NSArray<NSString *> *)contextWords dynamicWords:(NSArray<NSString *> *)dynamicWords
    gate:(double)gate shouldCancel:(nullable BOOL (^)(void))cancel NS_SWIFT_NAME(augment(beam:lexicon:points:contextWords:dynamicWords:gate:shouldCancel:));
+ (NSArray<KBScoredRow *> *)rankCandidates:(NSArray<KBChannelCandidate *> *)rows lexicon:(KBGenerationLexicon *)lexicon
    language:(NSData *)language safety:(NSArray<NSNumber *> *)safety sigma:(double)sigma dwell:(NSData *)dwell NS_SWIFT_NAME(rank(rows:lexicon:language:safety:sigma:dwell:));
+ (NSArray<NSString *> *)dynamicWords:(NSArray<NSString *> *)supplementary counts:(NSArray<NSNumber *> *)supplementaryCounts
    personal:(NSArray<NSString *> *)personal counts:(NSArray<NSNumber *> *)personalCounts limit:(NSUInteger)limit;
@end
NS_ASSUME_NONNULL_END
NS_ASSUME_NONNULL_BEGIN
@interface KBNeuralTokenizer : NSObject
- (nullable instancetype)initWithData:(NSData *)data;
@property(nonatomic, readonly) NSArray<NSString *> *pieces;
@property(nonatomic, readonly) NSArray<NSNumber *> *starts, *continuations;
@property(nonatomic, readonly) int32_t pad, english;
- (void)setCharacterLengths:(NSArray<NSNumber *> *)lengths;
- (NSArray<NSNumber *> *)encodeCharacters:(NSArray<NSString *> *)characters;
- (NSString *)wordFromIDs:(NSArray<NSNumber *> *)ids;
@end
@interface KBNeuralMath : NSObject
+ (nullable NSArray<NSNumber *> *)logProbabilities:(NSArray<NSNumber *> *)values;
+ (double)boundary:(NSArray<NSNumber *> *)values continuation:(NSArray<NSNumber *> *)continuation;
+ (NSArray<NSNumber *> *)top:(NSArray<NSNumber *> *)values count:(NSUInteger)count allowed:(NSArray<NSNumber *> *)allowed;
@end
NS_ASSUME_NONNULL_END
NS_ASSUME_NONNULL_BEGIN
@class MLModel, MLMultiArray;
@interface KBNeuralRuntime : NSObject
+ (nullable NSDictionary<NSString *, NSNumber *> *)generate:(KBNeuralTokenizer *)tokenizer model:(MLModel *)model
    state:(MLMultiArray *)state previous:(int32_t)previous starts:(NSArray<NSNumber *> *)starts
    width:(NSUInteger)width branch:(NSUInteger)branch depth:(NSUInteger)depth layers:(NSUInteger)layers hidden:(NSUInteger)hidden
    lexicon:(KBGenerationLexicon *)lexicon cancel:(BOOL (^)(void))cancel;
+ (nullable NSDictionary<NSString *, NSNumber *> *)score:(KBNeuralTokenizer *)tokenizer model:(MLModel *)model
    state:(MLMultiArray *)state previous:(int32_t)previous words:(NSArray<NSString *> *)words
    tokens:(NSArray<NSArray<NSNumber *> *> *)tokens layers:(NSUInteger)layers hidden:(NSUInteger)hidden cancel:(BOOL (^)(void))cancel;
+ (NSArray<NSString *> *)sortWords:(NSArray<NSString *> *)words scores:(NSArray<NSNumber *> *)scores limit:(NSUInteger)limit;
+ (NSArray<NSNumber *> *)contextPlan:(NSArray<NSNumber *> *)tokens cached:(NSArray<NSNumber *> *)cached pad:(int32_t)pad;
@end
NS_ASSUME_NONNULL_END
NS_ASSUME_NONNULL_BEGIN
@interface KBNumericPolicy : NSObject
+ (NSArray<NSNumber *> *)touch:(NSArray<NSNumber *> *)state x:(double)x y:(double)y observe:(BOOL)observe;
+ (NSArray<NSNumber *> *)glide:(NSArray<NSNumber *> *)state cost:(nullable NSNumber *)cost;
+ (NSArray<NSNumber *> *)characterPriors:(NSArray<NSNumber *> *)frequencies;
+ (NSArray<NSNumber *> *)contextualPriors:(NSArray<NSString *> *)letters baseLetters:(NSArray<NSString *> *)baseLetters values:(NSArray<NSNumber *> *)values;
@end
NS_ASSUME_NONNULL_END
NS_ASSUME_NONNULL_BEGIN
@interface KBNeuralRuntime (BatchScoring)
+ (nullable NSArray<NSNumber *> *)scoreBatch:(MLModel *)model state:(MLMultiArray *)state previous:(int32_t)previous padID:(int32_t)padID
    rows:(NSArray<NSArray<NSNumber *> *> *)rows layers:(NSUInteger)layers hidden:(NSUInteger)hidden
    batchSize:(NSUInteger)batchSize time:(NSUInteger)time cancel:(BOOL (^)(void))cancel;
@end
NS_ASSUME_NONNULL_END
NS_ASSUME_NONNULL_BEGIN
@interface KBNeuralMath (ContextWindow)
+ (NSArray<NSNumber *> *)trimmedContext:(NSArray<NSNumber *> *)tokens mode:(nullable NSNumber *)mode sequenceLength:(NSUInteger)sequenceLength maximumCandidateTokens:(NSUInteger)maximumCandidateTokens;
@end
@interface KBNeuralRuntime (TransformerScoring)
+ (nullable NSArray<NSNumber *> *)scoreTransformer:(MLModel *)model rows:(NSArray<NSArray<NSNumber *> *> *)rows
    context:(NSArray<NSNumber *> *)context padID:(int32_t)padID sequenceLength:(NSUInteger)sequenceLength
    batchSize:(NSUInteger)batchSize scoreSlots:(NSUInteger)scoreSlots cancel:(BOOL (^)(void))cancel;
@end
NS_ASSUME_NONNULL_END
NS_ASSUME_NONNULL_BEGIN
@interface KBNeuralRuntime (ContextThreading)
+ (MLMultiArray *)zeroStateWithLayers:(NSUInteger)layers hidden:(NSUInteger)hidden;
+ (nullable MLMultiArray *)threadContext:(NSArray<NSNumber *> *)tokens tokenizer:(KBNeuralTokenizer *)tokenizer
    model:(MLModel *)model state:(MLMultiArray *)state previous:(int32_t)previous layers:(NSUInteger)layers
    hidden:(NSUInteger)hidden cancel:(BOOL (^)(void))cancel;
@end
NS_ASSUME_NONNULL_END
NS_ASSUME_NONNULL_BEGIN
@interface KBNeuralMath (ContextWords)
+ (NSArray<NSString *> *)lastWords:(NSArray<NSString *> *)words limit:(NSUInteger)limit;
+ (NSArray<NSString *> *)knownWords:(NSArray<NSString *> *)words lexicon:(KBGenerationLexicon *)lexicon firstLetters:(NSArray<NSString *> *)firstLetters;
@end
NS_ASSUME_NONNULL_END
NS_ASSUME_NONNULL_BEGIN
@interface KBCancellationToken : NSObject
- (void)cancel;
@end
@interface KBEngineResult : NSObject
@property(nonatomic, readonly) NSArray<NSString *> *suggestions;
@property(nonatomic, readonly) NSArray<KBScoredRow *> *rows;
@property(nonatomic, readonly) NSArray<NSString *> *sources;
@property(nonatomic, readonly) KBCorrectionResult *correction;
@property(nonatomic, readonly) BOOL cancelled;
@property(nonatomic, readonly) NSArray<NSNumber *> *phaseMilliseconds;
@end
@interface KBSharedEngine : NSObject
- (instancetype)initWithLexicon:(KBGenerationLexicon *)lexicon model:(KBNativeLanguageModel *)model
    policy:(NSArray<NSNumber *> *)policy penalties:(NSDictionary<NSString *, NSNumber *> *)penalties profile:(BOOL)profile;
- (nullable KBEngineResult *)decodeWord:(NSString *)word normalized:(NSString *)normalized context:(NSArray<NSString *> *)context
    identity:(NSData *)identity offsets:(NSArray<NSNumber *> *)characterOffsets letterFlags:(NSData *)flags
    tapOffsets:(nullable NSData *)offsets tapValidity:(nullable NSData *)validity
    lexicon:(KBGenerationLexicon *)lexicon personal:(KBPersonalCounts *)personal topWords:(NSArray<NSString *> *)topWords
    kept:(BOOL)kept token:(KBCancellationToken *)token error:(NSError **)error
    NS_SWIFT_NAME(decode(word:normalized:context:identity:characterOffsets:letterFlags:tapOffsets:tapValidity:lexicon:personal:topWords:kept:token:));
- (void)memoryPressure;
@end
NS_ASSUME_NONNULL_END
NS_ASSUME_NONNULL_BEGIN
@interface KBPersonalState : NSObject
@property(nonatomic, readonly) uint64_t epoch;
@property(nonatomic, readonly) NSDictionary<NSString *, NSNumber *> *unigrams;
@property(nonatomic, readonly) NSDictionary<NSString *, NSNumber *> *confirmed;
@property(nonatomic, readonly) NSDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *bigrams;
@property(nonatomic, readonly) NSDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *trigrams;
- (KBPersonalCounts *)snapshot;
- (void)install:(KBPersonalCounts *)counts confirmed:(NSDictionary<NSString *, NSNumber *> *)confirmed epoch:(uint64_t)epoch;
- (void)reset:(uint64_t)epoch;
- (void)learn:(NSString *)word context:(NSArray<NSString *> *)context;
- (void)demote:(NSString *)word;
- (void)confirm:(NSString *)word;
- (void)releaseKeep:(NSString *)word;
- (BOOL)kept:(NSString *)word;
- (NSInteger)count:(NSString *)word;
- (NSInteger)confirmationCount:(NSString *)word;
- (NSUInteger)diversity:(NSString *)word limit:(NSUInteger)limit;
- (BOOL)prune;
- (BOOL)allowsAdoption:(NSString *)word count:(NSInteger)count lexicon:(KBGenerationLexicon *)lexicon;
@end
NS_ASSUME_NONNULL_END
NS_ASSUME_NONNULL_BEGIN
@class KBSharedGlide;
@interface KBSharedEngine (Glide)
- (KBSharedGlide *)glideSessionWithContext:(NSArray<NSString *> *)context;
@end
@interface KBSharedGlide : NSObject
- (nullable NSArray<KBScoredRow *> *)update:(NSData *)points keys:(NSData *)keys centers:(NSData *)centers xPitch:(double)x yPitch:(double)y
    lexicon:(KBGenerationLexicon *)lexicon personal:(KBPersonalCounts *)personal dynamicWords:(NSArray<NSString *> *)dynamic error:(NSError **)error;
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
NS_ASSUME_NONNULL_BEGIN
@interface KBVocabularyState : NSObject
- (instancetype)initWithBlocked:(NSArray<NSString *> *)blocked;
@property(nonatomic, readonly) KBGenerationSnapshot *snapshot;
@property(nonatomic, readonly) NSDictionary<NSString *, NSNumber *> *boosts;
- (void)supplementary:(NSString *)word frequency:(NSInteger)frequency glide:(BOOL)glide;
- (BOOL)note:(NSString *)word count:(NSInteger)count allowAdoption:(BOOL)allow threshold:(NSInteger)threshold glide:(BOOL)glide
    packed:(nullable KBPackedLexicon *)packed base:(KBMutableTrie *)base supplementary:(KBMutableTrie *)supplementary personal:(KBMutableTrie *)personal;
- (NSArray<NSString *> *)dynamicWords:(NSUInteger)limit;
- (void)resetPersonalization;
@end
NS_ASSUME_NONNULL_END
