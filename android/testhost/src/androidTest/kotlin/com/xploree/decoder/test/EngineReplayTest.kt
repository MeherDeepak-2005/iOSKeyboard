package com.xploree.decoder.test

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.xploree.decoder.*
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class EngineReplayTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private fun asset(name: String) = instrumentation.context.assets.open(name).bufferedReader().use { it.readText() }
    private fun engine() = SharedEnglishDictionary.openEngine(instrumentation.targetContext)
    private fun identity(session: Long, generation: Long) = RequestIdentity(1, generation, session, generation, 1, 0, 0)
    @Test fun corpusMatchesIOSAndNativeEvidence() {
        val corpus = JSONArray(asset("corpus.json")); val golden = JSONArray(asset("golden-corpus.json"))
        assertEquals(132, corpus.length()); assertEquals(corpus.length(), golden.length())
        engine().use { engine ->
            for (i in 0 until corpus.length()) {
                val fixture = corpus.getJSONObject(i); val expected = golden.getJSONObject(i)
                val context = fixture.getJSONArray("context"); val words = List(context.length()) { context.getString(it) }
                val id = identity(i.toLong() + 1, i.toLong() + 1)
                val actual = engine.decode(KeyboardDecodeRequest(fixture.getString("typed"), words, id))
                assertEquals(fixture.getString("id"), expected.getString("id")); assertEquals(id, actual.identity); assertEquals(0, actual.status)
                val suggestions = expected.getJSONArray("suggestions")
                assertEquals(List(suggestions.length()) { suggestions.getString(it) }, actual.suggestions)
                assertEquals(expected.optString("correction").takeUnless { expected.isNull("correction") }, actual.correction)
                val rows = expected.getJSONArray("candidates"); assertEquals(rows.length(), actual.candidates.size)
                val sources = listOf("typed", "fuzzyLexicon", "completion", "contextInjection", "broadRecovery", "splitCorrection")
                for (j in 0 until rows.length()) {
                    val a = actual.candidates[j]; val b = rows.getJSONObject(j)
                    assertEquals(b.getString("word"), a.word); assertEquals(b.getString("source"), sources[a.source])
                    assertEquals(b.getDouble("cost"), a.cost, 1e-9); assertEquals(b.getDouble("score"), a.score, 1e-9)
                }
            }
        }
    }
    @Test fun editingLearningResetAndSnapshotLifetime() {
        engine().use { engine ->
            var generation = 0L
            for (word in listOf("hello", "correction", "coeevitjkn", "definitely", "recieve", "qzvaxon")) {
                val session = ++generation
                for (n in 1..word.length) {
                    val input = word.substring(0, n); val first = engine.decode(KeyboardDecodeRequest(input, emptyList(), identity(session, ++generation)))
                    val fresh = engine.decode(KeyboardDecodeRequest(input, emptyList(), identity(++generation, ++generation)))
                    assertEquals(first.suggestions, fresh.suggestions); assertEquals(first.correction, fresh.correction)
                }
                val backspace = word.dropLast(1)
                val first = engine.decode(KeyboardDecodeRequest(backspace, emptyList(), identity(session, ++generation)))
                val fresh = engine.decode(KeyboardDecodeRequest(backspace, emptyList(), identity(++generation, ++generation)))
                assertEquals(first.suggestions, fresh.suggestions)
            }
            repeat(9) { engine.learn("meherdeepak", listOf("hello")) }; engine.confirmSpelling("meherdeepak")
            val snapshot = engine.exportPersonalization()
            engine.resetPersonalization(7); assertFalse(snapshot.contentEquals(engine.exportPersonalization()))
            engine.importPersonalization(snapshot); assertArrayEquals(snapshot, engine.exportPersonalization())
            engine.wordReplaced("meherdeepak"); assertFalse(snapshot.contentEquals(engine.exportPersonalization()))
            engine.memoryPressure()
        }
    }
    @Test fun glideMatchesIOSGolden() {
        val fixtures = JSONArray(asset("glides.json")); val golden = JSONArray(asset("golden-glide.json"))
        assertEquals(60, fixtures.length())
        val rows = listOf("qwertyuiop", "asdfghjkl", "zxcvbnm"); val shifts = listOf(0.0, 0.5, 1.5)
        val keys = rows.joinToString("").toByteArray(Charsets.US_ASCII)
        val centers = rows.flatMapIndexed { y, row -> row.mapIndexed { x, _ -> listOf(x + shifts[y], y.toDouble()) }.flatten() }.toDoubleArray()
        engine().use { engine ->
            for (i in 0 until fixtures.length()) {
                val fixture = fixtures.getJSONObject(i); val context = fixture.getJSONArray("context")
                engine.beginGlide(List(context.length()) { context.getString(it) })
                val points = fixture.getJSONArray("points")
                val path = DoubleArray(points.length() * 2) { n -> points.getJSONArray(n / 2).getDouble(n % 2) }
                val actual = engine.updateGlide(path, keys, centers, 1.0, 1.0, identity(i.toLong() + 1, 1))
                val expected = golden.getJSONObject(i).getJSONArray("suggestions")
                assertEquals(List(expected.length()) { expected.getString(it) }, actual.suggestions)
                assertEquals(actual.suggestions, engine.endGlide().suggestions)
            }
        }
    }
    @Test fun unicodeBoundaryConformance() {
        val fixtures = JSONArray(asset("unicode-boundaries.json"))
        for (i in 0 until fixtures.length()) {
            val fixture = fixtures.getJSONObject(i); val actual = TextBoundary.describe(fixture.getString("word"))
            val offsets = fixture.getJSONArray("offsets"); assertArrayEquals(IntArray(offsets.length()) { offsets.getInt(it) }, actual.offsets)
            val flags = fixture.getJSONArray("letters"); assertArrayEquals(ByteArray(flags.length()) { flags.getInt(it).toByte() }, actual.letters)
        }
    }
    @Test fun closeAndCancellationAreSafeAcrossThreads() {
        val engine = engine(); val worker = Executors.newSingleThreadExecutor()
        val future = worker.submit { try { engine.decode(KeyboardDecodeRequest("coeevitjkn", listOf("possibly", "receive"), identity(1,1))) } catch (_: IllegalStateException) {} }
        engine.cancel(); engine.close(); future.get(10, TimeUnit.SECONDS)
        worker.shutdownNow(); engine.close()
    }
}
