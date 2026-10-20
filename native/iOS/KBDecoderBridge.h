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
    fundedWords:(nullable NSArray<NSString *> *)words fundedBonuses:(nullable NSArray<NSNumber *> *)bonuses
    retainedStatic:(nullable NSArray<KBChannelCandidate *> *)retained gruTier:(BOOL)gru
    shouldCancel:(nullable BOOL (^)(void))cancel error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
