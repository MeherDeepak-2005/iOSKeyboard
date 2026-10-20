package com.xploree.decoder

import java.io.Closeable
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.text.BreakIterator
import java.util.Locale
import java.util.concurrent.atomic.AtomicLong

/** Complete English backend. Schedule calls on a worker. cancel/close may be called
 * from another thread; publication must still compare every RequestIdentity field.
 * The constructor receives the same validated pack and safety asset used on iOS.
 */
class NativeKeyboardEngine(dictionaryPath: String, safetyPack: ByteArray) : Closeable {
    private val handle = AtomicLong(nativeOpen(dictionaryPath.toByteArray(Charsets.UTF_8), safetyPack))
    init {
        try {
            val reader = WireReader(nativeMetadata(id()))
            val metadata = ArrayList<Long>()
            repeat(reader.count(200000)) {
                val wordID = reader.int()
                val word = reader.text()
                val text = TextBoundary.describe(word)
                metadata += wordID.toLong()
                metadata += (text.offsets.size - 1).toLong()
                val clusters = TextBoundary.clusters(word)
                metadata += clusters.firstOrNull()?.singleOrNull()?.code?.takeIf { it < 128 }?.toLong() ?: -1L
                metadata += clusters.lastOrNull()?.singleOrNull()?.code?.takeIf { it < 128 }?.toLong() ?: -1L
            }
            reader.finish()
            nativeInstallMetadata(id(), metadata.toLongArray())
        } catch (failure: Throwable) { close(); throw failure }
    }
    private fun id(): Long = handle.get().also { check(it != 0L) { "Decoder closed" } }
    fun decode(request: KeyboardDecodeRequest): KeyboardDecodeResult {
        val text = TextBoundary.describe(request.word.lowercase(Locale.ROOT))
        val taps = request.taps?.takeIf { it.size == text.utf8.size }
        val offsets = taps?.let { row -> DoubleArray(row.size * 2) { i -> if (i % 2 == 0) row[i / 2]?.dx ?: 0.0 else row[i / 2]?.dy ?: 0.0 } }
        val validity = taps?.let { row -> ByteArray(row.size) { if (row[it] == null) 0 else 1 } }
        return decodeResult(nativeDecode(id(), request.word.toByteArray(Charsets.UTF_8), text.utf8,
            request.context.map { it.lowercase(Locale.ROOT).toByteArray(Charsets.UTF_8) }.toTypedArray(), request.identity.fields(),
            text.offsets, text.letters, offsets, validity))
    }
    fun cancel() { handle.get().takeIf { it != 0L }?.let { nativeCancel(it) } }
    fun learn(word: String, context: List<String>) {
        val normalized = word.lowercase(Locale.ROOT)
        require(TextBoundary.learnable(normalized))
        event(0, normalized, context)
    }
    fun confirmSpelling(word: String) = event(1, word.lowercase(Locale.ROOT))
    fun correctionStood(word: String) = event(2, word.lowercase(Locale.ROOT))
    fun wordReplaced(word: String) = event(3, word.lowercase(Locale.ROOT))
    fun resetPersonalization(epoch: Long) = event(4, "", epoch = epoch)
    fun importSupplementary(words: List<String>) {
        words.map { it.lowercase(Locale.ROOT) }.filter { TextBoundary.learnable(it) && TextBoundary.clusters(it).size >= 2 }
            .forEach { event(5, it) }
    }
    private fun event(kind: Int, word: String, context: List<String> = emptyList(), epoch: Long = 0) {
        nativeEvent(id(), kind, word.toByteArray(Charsets.UTF_8), context.map { it.lowercase(Locale.ROOT).toByteArray(Charsets.UTF_8) }.toTypedArray(), epoch)
    }
    fun exportPersonalization(): ByteArray = nativeExport(id())
    fun importPersonalization(snapshot: ByteArray) = nativeImport(id(), snapshot)
    fun memoryPressure() = nativeMemoryPressure(id())
    fun beginGlide(context: List<String>) = nativeBeginGlide(id(), context.map { it.lowercase(Locale.ROOT).toByteArray(Charsets.UTF_8) }.toTypedArray())
    fun updateGlide(path: DoubleArray, keys: ByteArray, centers: DoubleArray, xPitch: Double, yPitch: Double, identity: RequestIdentity): KeyboardDecodeResult {
        require(path.size % 2 == 0 && centers.size == keys.size * 2)
        require(path.all(Double::isFinite) && centers.all(Double::isFinite) && xPitch.isFinite() && yPitch.isFinite() && xPitch > 0 && yPitch > 0)
        return decodeResult(nativeGlide(id(), path, keys, centers, xPitch, yPitch, identity.fields()))
    }
    fun endGlide(): KeyboardDecodeResult = decodeResult(nativeEndGlide(id()))
    override fun close() { val previous = handle.getAndSet(0L); if (previous != 0L) nativeClose(previous) }
    private external fun nativeOpen(path: ByteArray, safety: ByteArray): Long
    private external fun nativeClose(handle: Long)
    private external fun nativeCancel(handle: Long)
    private external fun nativeDecode(handle: Long, original: ByteArray, normalized: ByteArray, context: Array<ByteArray>, identity: LongArray,
        offsets: IntArray, flags: ByteArray, taps: DoubleArray?, validity: ByteArray?): ByteArray
    private external fun nativeEvent(handle: Long, kind: Int, word: ByteArray, context: Array<ByteArray>, epoch: Long)
    private external fun nativeExport(handle: Long): ByteArray
    private external fun nativeImport(handle: Long, bytes: ByteArray)
    private external fun nativeMemoryPressure(handle: Long)
    private external fun nativeBeginGlide(handle: Long, context: Array<ByteArray>)
    private external fun nativeGlide(handle: Long, path: DoubleArray, keys: ByteArray, centers: DoubleArray, xPitch: Double, yPitch: Double, identity: LongArray): ByteArray
    private external fun nativeEndGlide(handle: Long): ByteArray
    private external fun nativeMetadata(handle: Long): ByteArray
    private external fun nativeInstallMetadata(handle: Long, values: LongArray)
    companion object { init { System.loadLibrary("xploree_decoder") } }
}

data class KeyboardDecodeRequest(val word: String, val context: List<String>, val identity: RequestIdentity, val taps: List<TouchOffset?>? = null)
data class KeyboardCandidate(val word: String, val cost: Double, val logFrequency: Double, val language: Double, val score: Double, val typedMargin: Double, val source: Int)
data class KeyboardDecodeResult(val identity: RequestIdentity, val status: Int, val suggestions: List<String>, val correction: String?, val confidence: Double,
    val candidates: List<KeyboardCandidate>, val phaseMilliseconds: DoubleArray)
internal fun RequestIdentity.fields() = longArrayOf(fieldRevision, documentRevision, wordSessionID, generation, layoutRevision, vocabularyEpoch, personalizationEpoch)
internal class WireReader(bytes: ByteArray) {
    private val data = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
    fun int(): Int { require(data.remaining() >= 4); return data.int }
    fun long(): Long { require(data.remaining() >= 8); return data.long }
    fun real(): Double { require(data.remaining() >= 8); return data.double }
    fun count(max: Int): Int = int().also { require(it in 0..max) }
    fun text(length: Int = int()): String { require(length >= 0 && length <= data.remaining()); val bytes = ByteArray(length); data.get(bytes); return bytes.toString(Charsets.UTF_8) }
    fun finish() { require(!data.hasRemaining()) }
}
internal fun decodeResult(bytes: ByteArray): KeyboardDecodeResult {
    val r = WireReader(bytes); require(r.int() == 0x3244424b); val status = r.count(3)
    val identity = RequestIdentity(r.long(), r.long(), r.long(), r.long(), r.long(), r.long(), r.long())
    val suggestions = List(r.count(4)) { r.text() }
    val length = r.int(); val correction = if (length == -1) null else r.text(length)
    val confidence = r.real()
    val candidates = List(r.count(24)) { KeyboardCandidate(r.text(), r.real(), r.real(), r.real(), r.real(), r.real(), r.count(5)) }
    val timings = DoubleArray(4) { r.real() }; r.finish()
    return KeyboardDecodeResult(identity, status, suggestions, correction, confidence, candidates, timings)
}

/** OS segmentation is a boundary service. The common Unicode fixture suite checks
 * this metadata against iOS; algorithms receive explicit UTF-8 grapheme offsets.
 */
object TextBoundary {
    data class Description(val utf8: ByteArray, val offsets: IntArray, val letters: ByteArray)
    fun clusters(word: String): List<String> {
        val iterator = BreakIterator.getCharacterInstance(Locale.ROOT); iterator.setText(word)
        val result = ArrayList<String>(); var begin = iterator.first(); var end = iterator.next()
        while (end != BreakIterator.DONE) { result += word.substring(begin, end); begin = end; end = iterator.next() }
        return result
    }
    fun describe(word: String): Description {
        val bytes = word.toByteArray(Charsets.UTF_8); val offsets = ArrayList<Int>(); offsets += 0; val flags = ByteArray(bytes.size)
        for (cluster in clusters(word)) {
            val start = offsets.last(); val size = cluster.toByteArray(Charsets.UTF_8).size
            val letter = cluster.codePoints().anyMatch { Character.isLetter(it) }
            if (letter) flags.fill(1, start, start + size)
            offsets += start + size
        }
        return Description(bytes, offsets.toIntArray(), flags)
    }
    fun learnable(word: String): Boolean = word.isNotEmpty() && (clusters(word).size >= 2 || word == "a" || word == "i") &&
        word.codePoints().allMatch { Character.isLetter(it) || it == 39 || Character.getType(it) == Character.NON_SPACING_MARK.toInt() }
}
