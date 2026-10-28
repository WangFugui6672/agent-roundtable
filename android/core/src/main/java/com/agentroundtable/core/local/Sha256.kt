package com.agentroundtable.core.local

import java.io.File
import java.io.InputStream
import java.security.MessageDigest

/** SHA256 校验。模型文件必须与清单中的摘要一致才允许加载。 */
object Sha256 {
    fun hex(input: InputStream): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(64 * 1024)
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            digest.update(buffer, 0, read)
        }
        return digest.digest().toHex()
    }

    fun hex(file: File): String = file.inputStream().use(::hex)

    fun matches(file: File, expected: String): Boolean =
        file.isFile && hex(file).equals(expected.trim(), ignoreCase = true)

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
}
