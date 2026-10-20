package com.xploree.decoder

import android.content.Context
import java.io.File
import java.io.IOException
import java.security.MessageDigest

/** Resource discovery is Android work; DecoderCore only receives immutable bytes.
 * Run on the IME worker. Extract once per content hash, never once per keystroke.
 */
object SharedEnglishDictionary {
    @Synchronized
    fun open(context: Context): NativeChannelDecoder = NativeChannelDecoder(install(context).absolutePath)

    @Synchronized
    fun openEngine(context: Context): NativeKeyboardEngine = NativeKeyboardEngine(install(context).absolutePath, context.assets.open("safety.kbguard").use { it.readBytes() })

    private fun install(context: Context): File {
        val expected = context.assets.open("langdata.sha256").bufferedReader().use { it.readText().trim() }
        require(expected.matches(Regex("[0-9a-f]{64}"))) { "Invalid dictionary resource hash" }
        val directory = File(context.noBackupFilesDir, "xploree-decoder")
        if (!directory.isDirectory && !directory.mkdirs()) throw IOException("Cannot create decoder directory")
        val target = File(directory, "$expected.bin")
        if (!target.isFile || digest(target) != expected) {
            val temporary = File.createTempFile("dictionary-", ".tmp", directory)
            try {
                context.assets.open("langdata.bin").use { input ->
                    temporary.outputStream().use { output -> input.copyTo(output, 64 * 1024) }
                }
                if (digest(temporary) != expected) throw IOException("Dictionary resource checksum mismatch")
                // Atomic same-filesystem replacement; existing native mappings keep
                // their own inode and never observe an in-place overwrite.
                if (!temporary.renameTo(target)) throw IOException("Cannot install dictionary resource")
            } finally { temporary.delete() }
        }
        if (!target.setReadOnly()) throw IOException("Cannot protect dictionary resource")
        return target
    }

    private fun digest(file: File): String {
        val sha = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                sha.update(buffer, 0, count)
            }
        }
        return sha.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }
}
