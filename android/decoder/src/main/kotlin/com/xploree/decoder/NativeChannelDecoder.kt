package com.xploree.decoder

import java.io.Closeable
import java.util.Locale

/** JNI façade for the shared English channel. Own on an IME worker, never the UI thread.
 * The caller supplies a private, extracted dictionary file that is not modified while open.
 * Final ranking, correction decisions, Glide and neural inference are NOT yet Android features.
 */
class NativeChannelDecoder(dictionaryPath: String) : Closeable {
    private var handle: Long = nativeOpen(dictionaryPath.toByteArray(Charsets.UTF_8))

    @Synchronized
    fun beginWord(first: Char, firstTap: TouchOffset? = null,
                  boosts: Map<String, Int> = emptyMap()): Boolean {
        check(handle != 0L) { "Decoder closed" }
        require(first in 'a'..'z')
        require(boosts.size <= 3000 && boosts.values.all { it >= 0 })
        require(boosts.keys.all { word -> word.isNotEmpty() && word.all { it in 'a'..'z' || it == '\'' } })
        val ordered = boosts.toSortedMap()
        return nativeBegin(handle, first.code, firstTap != null,
            firstTap?.dx ?: 0.0, firstTap?.dy ?: 0.0,
            ordered.keys.toTypedArray(), ordered.values.toIntArray())
        // false means the unchanged 24,000-state cap cannot cover this root.
        // A future full decoder must run its full-trie fallback, not truncate recall.
    }

    @Synchronized
    fun advance(word: String, taps: List<TouchOffset?>? = null): Boolean {
        check(handle != 0L) { "Decoder closed" }
        val normalized = word.lowercase(Locale.ROOT).toByteArray(Charsets.UTF_8)
        val matching = taps?.takeIf { it.size == normalized.size }
        val offsets = matching?.let { row -> DoubleArray(row.size * 2) { index ->
            if (index % 2 == 0) row[index / 2]?.dx ?: 0.0 else row[index / 2]?.dy ?: 0.0
        } }
        val validity = matching?.let { row -> ByteArray(row.size) { if (row[it] == null) 0 else 1 } }
        return nativeAdvance(handle, normalized, offsets, validity)
    }

    @Synchronized
    fun candidates(maxCost: Double = 3.6): ChannelCandidates {
        check(handle != 0L) { "Decoder closed" }
        return nativeCandidates(handle, maxCost)
    }

    @Synchronized
    fun search(word: String, maxCost: Double = 3.6,
               taps: List<TouchOffset?>? = null, funding: Map<String, Double>? = null): ChannelCandidates {
        check(handle != 0L) { "Decoder closed" }
        require(maxCost.isFinite() && maxCost >= 0)
        require(funding == null || funding.values.all { it.isFinite() && it > 0 && it <= 1.6 })
        require(funding == null || funding.keys.all { word -> word.all { it in 'a'..'z' || it == '\'' } })
        val ordered = funding?.toSortedMap()
        val normalized = word.lowercase(Locale.ROOT).toByteArray(Charsets.UTF_8)
        val matching = taps?.takeIf { it.size == normalized.size }
        val offsets = matching?.let { row -> DoubleArray(row.size * 2) { index ->
            if (index % 2 == 0) row[index / 2]?.dx ?: 0.0 else row[index / 2]?.dy ?: 0.0
        } }
        val validity = matching?.let { row -> ByteArray(row.size) { if (row[it] == null) 0 else 1 } }
        return nativeSearch(handle, normalized, maxCost, offsets, validity,
            ordered?.keys?.toTypedArray(), ordered?.values?.toDoubleArray())
    }

    @Synchronized
    fun languageScores(rows: List<LanguageEvidence>, corpusTotal: Double,
                       bigram: ContextEvidence = ContextEvidence(),
                       trigram: ContextEvidence = ContextEvidence()): DoubleArray {
        check(handle != 0L) { "Decoder closed" }
        val packed = rows.flatMap { listOf(it.unigramMass, it.bigramCount, it.trigramCount,
            it.unigramPersonal, it.bigramPersonal, it.trigramPersonal) }.toDoubleArray()
        return nativeLanguageScores(packed, corpusTotal,
            bigram.total, bigram.discountMass, trigram.total, trigram.discountMass)
    }

    @Synchronized
    override fun close() {
        if (handle != 0L) { nativeClose(handle); handle = 0L }
    }

    private external fun nativeOpen(path: ByteArray): Long
    private external fun nativeBegin(handle: Long, first: Int, hasTap: Boolean,
        dx: Double, dy: Double, words: Array<String>, counts: IntArray): Boolean
    private external fun nativeAdvance(handle: Long, word: ByteArray,
        offsets: DoubleArray?, validity: ByteArray?): Boolean
    private external fun nativeCandidates(handle: Long, maxCost: Double): ChannelCandidates
    private external fun nativeSearch(handle: Long, word: ByteArray, maxCost: Double,
        offsets: DoubleArray?, validity: ByteArray?, words: Array<String>?, bonuses: DoubleArray?): ChannelCandidates
    private external fun nativeLanguageScores(rows: DoubleArray, corpusTotal: Double,
        biTotal: Double, biDiscountMass: Double, triTotal: Double, triDiscountMass: Double): DoubleArray
    private external fun nativeClose(handle: Long)

    companion object { init { System.loadLibrary("xploree_decoder") } }
}

data class TouchOffset(val dx: Double, val dy: Double)
data class ChannelCandidates(val words: Array<String>, val costs: DoubleArray,
                             val logFrequencies: DoubleArray)

/** Match iOS revision fields. Capture identity before scheduling; compare all fields
 * before publication. A newer generation alone never validates a different field/layout.
 */
data class RequestIdentity(val fieldRevision: Long, val documentRevision: Long,
    val wordSessionID: Long, val generation: Long, val layoutRevision: Long,
    val vocabularyEpoch: Long, val personalizationEpoch: Long)

// Immutable evidence supplied by a future complete Android vocabulary/personal view.
data class LanguageEvidence(val unigramMass: Double, val bigramCount: Double,
    val trigramCount: Double, val unigramPersonal: Double, val bigramPersonal: Double,
    val trigramPersonal: Double)
// MKN transport: rows contain discounted effective counts, not raw token counts.
// Each context carries the sum of discounts across its complete retained table.
data class ContextEvidence(val total: Double = 0.0, val discountMass: Double = 0.0)
