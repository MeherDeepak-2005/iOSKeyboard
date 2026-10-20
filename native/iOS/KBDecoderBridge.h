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
