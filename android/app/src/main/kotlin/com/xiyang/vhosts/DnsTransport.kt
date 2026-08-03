package com.xiyang.vhosts

import android.net.Network
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URI
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.SecureRandom
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import org.json.JSONObject

data class DnsProfileConfig(
    val type: String,
    val server: String,
    val secondaryServer: String,
    val dotHostname: String,
    val timeoutMs: Int,
    val retryCount: Int,
) {
    companion object {
        fun fromJson(json: JSONObject): DnsProfileConfig = DnsProfileConfig(
            type = json.getString("type"),
            server = json.getString("server"),
            secondaryServer = json.getString("secondaryServer"),
            dotHostname = json.getString("dotHostname"),
            timeoutMs = json.getInt("timeoutMs"),
            retryCount = json.getInt("retryCount"),
        )
    }
}

data class HostRuleConfig(
    val domain: String,
    val suffix: Boolean,
    val targetIp: String,
    val enabled: Boolean,
) {
    companion object {
        fun fromJson(json: JSONObject): HostRuleConfig = HostRuleConfig(
            domain = json.getString("domain"),
            suffix = json.getString("matchType") == "suffix",
            targetIp = json.getString("targetIp"),
            enabled = json.getBoolean("enabled"),
        )
    }
}

data class DnsQuery(
    val name: String,
    val type: Int,
    val questionEnd: Int,
)

data class DnsTestResult(
    val success: Boolean,
    val latencyMs: Int?,
    val detail: String,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "success" to success,
        "latencyMs" to latencyMs,
        "detail" to detail,
    )
}

class DnsTransport(
    private val profile: DnsProfileConfig,
    private val hostRules: List<HostRuleConfig> = emptyList(),
    private val network: Network? = null,
    private val protect: ((DatagramSocket) -> Boolean)? = null,
    private val protectTcp: ((Socket) -> Boolean)? = null,
) {
    private val random = SecureRandom()

    fun resolve(query: ByteArray): ByteArray {
        val parsed = DnsPacket.parseQuery(query)
            ?: return DnsPacket.servfail(query)

        val host = hostRules.firstOrNull { rule ->
            if (!rule.enabled || !DnsPacket.isIpAddress(rule.targetIp)) return@firstOrNull false
            val domain = rule.domain.removePrefix("*.").trimEnd('.').lowercase()
            if (rule.suffix) {
                parsed.name != domain && parsed.name.endsWith(".$domain")
            } else {
                parsed.name == domain
            }
        }
        if (host != null) {
            val answer = DnsPacket.hostResponse(query, parsed, host.targetIp)
            if (answer != null) return answer
        }

        var lastError: Exception? = null
        val servers = buildList {
            add(profile.server)
            if (profile.type == "plain" && profile.secondaryServer.isNotBlank()) {
                add(profile.secondaryServer)
            }
        }
        repeat(profile.retryCount.coerceIn(1, 5)) {
            for (server in servers) {
                try {
                    return request(server, query)
                } catch (error: Exception) {
                    lastError = error
                }
            }
        }
        throw IOException(lastError?.message ?: "DNS 请求失败")
    }

    fun test(): DnsTestResult {
        val query = DnsPacket.query("example.com", 1, random.nextInt(65536))
        val startedAt = System.nanoTime()
        return try {
            val response = resolve(query)
            val parsed = DnsPacket.parseQuery(response)
            if (parsed == null || !DnsPacket.isSuccessfulResponse(response, query)) {
                DnsTestResult(false, null, "服务器返回了无效的 DNS 响应")
            } else {
                val elapsed = ((System.nanoTime() - startedAt) / 1_000_000L).toInt()
                DnsTestResult(true, elapsed, "查询 example.com 成功")
            }
        } catch (error: Exception) {
            DnsTestResult(false, null, readableError(error))
        }
    }

    private fun request(server: String, query: ByteArray): ByteArray {
        return when (profile.type) {
            "plain" -> requestPlain(server, query)
            "doh" -> requestDoh(server, query)
            "dot" -> requestDot(server, query)
            else -> throw IOException("不支持的 DNS 类型")
        }
    }

    private fun requestPlain(server: String, query: ByteArray): ByteArray {
        val endpoint = parseEndpoint(server, 53)
        val addresses = resolveAddresses(endpoint.host)
        var lastError: Exception? = null
        for (address in addresses) {
            try {
                DatagramSocket().use { socket ->
                    if (protect != null && !protect.invoke(socket)) {
                        throw IOException("无法保护上游 UDP 套接字")
                    }
                    socket.soTimeout = profile.timeoutMs.coerceIn(300, 10000)
                    socket.connect(address, endpoint.port)
                    socket.send(DatagramPacket(query, query.size))
                    val buffer = ByteArray(4096)
                    val response = DatagramPacket(buffer, buffer.size)
                    socket.receive(response)
                    return response.data.copyOf(response.length)
                }
            } catch (error: Exception) {
                lastError = error
            }
        }
        throw IOException(lastError?.message ?: "无法连接 Plain DNS 服务器")
    }

    private fun requestDot(server: String, query: ByteArray): ByteArray {
        val endpoint = parseEndpoint(server, 853)
        val hostname = profile.dotHostname.ifBlank { endpoint.host }
        return withTlsSocket(endpoint.host, endpoint.port, hostname) { socket ->
            val payload = ByteArrayOutputStream().apply {
                write(query.size ushr 8)
                write(query.size and 0xff)
                write(query)
            }.toByteArray()
            socket.outputStream.write(payload)
            socket.outputStream.flush()
            val length = readU16(socket.inputStream)
            if (length <= 0 || length > 65535) throw IOException("DoT 响应长度无效")
            readExact(socket.inputStream, length)
        }
    }

    private fun requestDoh(server: String, query: ByteArray): ByteArray {
        val uri = URI(server)
        val dohHost = uri.host
        if (uri.scheme.lowercase() != "https" || dohHost.isNullOrBlank()) {
            throw IOException("DoH URL 必须是有效的 https 地址")
        }
        val port = if (uri.port > 0) uri.port else 443
        val endpoint = resolveAddresses(dohHost)
        var lastError: Exception? = null
        for (address in endpoint) {
            try {
                return withTlsSocket(address.hostAddress ?: throw IOException("DoH 地址无效"), port, dohHost) { socket ->
                    val path = (uri.rawPath?.takeIf { it.isNotBlank() } ?: "/dns-query") +
                        (uri.rawQuery?.let { "?$it" } ?: "")
                    val hostHeader = if (uri.port > 0) "$dohHost:$port" else dohHost
                    val request = buildString {
                        append("POST $path HTTP/1.1\r\n")
                        append("Host: $hostHeader\r\n")
                        append("Content-Type: application/dns-message\r\n")
                        append("Accept: application/dns-message\r\n")
                        append("Content-Length: ${query.size}\r\n")
                        append("Connection: close\r\n\r\n")
                    }.toByteArray(Charsets.US_ASCII)
                    socket.outputStream.write(request)
                    socket.outputStream.write(query)
                    socket.outputStream.flush()
                    readHttpDnsResponse(socket)
                }
            } catch (error: Exception) {
                lastError = error
            }
        }
        throw IOException(lastError?.message ?: "无法连接 DoH 服务器")
    }

    private fun <T> withTlsSocket(
        host: String,
        port: Int,
        serverName: String,
        block: (SSLSocket) -> T,
    ): T {
        val tcp = Socket()
        try {
            if (protectTcp != null && !protectTcp.invoke(tcp)) {
                throw IOException("无法保护上游 TCP 套接字")
            }
            tcp.connect(InetSocketAddress(resolveAddresses(host).first(), port), profile.timeoutMs)
            tcp.soTimeout = profile.timeoutMs.coerceIn(300, 10000)
            val ssl = SSLContext.getDefault().socketFactory.createSocket(
                tcp,
                serverName,
                port,
                true,
            ) as SSLSocket
            ssl.soTimeout = profile.timeoutMs.coerceIn(300, 10000)
            ssl.sslParameters = ssl.sslParameters.apply {
                endpointIdentificationAlgorithm = "HTTPS"
            }
            ssl.useClientMode = true
            ssl.startHandshake()
            return ssl.use(block)
        } finally {
            try {
                tcp.close()
            } catch (_: Exception) {
            }
        }
    }

    private fun readHttpDnsResponse(socket: SSLSocket): ByteArray {
        val input = BufferedInputStream(socket.inputStream)
        val headerBytes = ByteArrayOutputStream()
        var previous = -1
        var current: Int
        while (true) {
            current = input.read()
            if (current < 0) throw IOException("DoH 响应头不完整")
            headerBytes.write(current)
            if (previous == '\r'.code && current == '\n'.code && headerBytes.toString(Charsets.US_ASCII.name()).endsWith("\r\n\r\n")) {
                break
            }
            previous = current
            if (headerBytes.size() > 16384) throw IOException("DoH 响应头过大")
        }
        val headers = headerBytes.toString(Charsets.US_ASCII.name()).split("\r\n")
        val status = headers.firstOrNull()?.split(" ")?.getOrNull(1)?.toIntOrNull() ?: 0
        if (status !in 200..299) throw IOException("DoH HTTP 状态码 $status")
        val contentLength = headers.firstNotNullOfOrNull {
            if (it.lowercase().startsWith("content-length:")) it.substringAfter(':').trim().toIntOrNull() else null
        }
        val isChunked = headers.any { it.lowercase().startsWith("transfer-encoding:") && it.lowercase().contains("chunked") }
        val body = if (isChunked) {
            readChunkedBody(input)
        } else if (contentLength != null) {
            readExact(input, contentLength)
        } else {
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(4096)
            var count: Int
            while (input.read(buffer).also { count = it } >= 0) output.write(buffer, 0, count)
            output.toByteArray()
        }
        if (body.isEmpty()) throw IOException("DoH 返回空响应")
        return body
    }

    private fun readChunkedBody(input: BufferedInputStream): ByteArray {
        val output = ByteArrayOutputStream()
        while (true) {
            val line = readHttpLine(input)
            val size = line.substringBefore(';').trim().toIntOrNull(16)
                ?: throw IOException("DoH chunk 长度无效")
            if (size == 0) {
                readHttpLine(input)
                return output.toByteArray()
            }
            output.write(readExact(input, size))
            if (input.read() != '\r'.code || input.read() != '\n'.code) {
                throw IOException("DoH chunk 分隔符无效")
            }
        }
    }

    private fun readHttpLine(input: BufferedInputStream): String {
        val output = ByteArrayOutputStream()
        var previous = -1
        while (true) {
            val current = input.read()
            if (current < 0) throw IOException("DoH 响应行不完整")
            if (previous == '\r'.code && current == '\n'.code) {
                val bytes = output.toByteArray()
                return String(bytes, 0, bytes.size - 1, Charsets.US_ASCII)
            }
            output.write(current)
            previous = current
        }
    }

    private fun resolveAddresses(host: String): Array<InetAddress> {
        val literal = try { InetAddress.getByName(host) } catch (_: Exception) { null }
        if (literal != null && literal.hostAddress == host.trim('[', ']')) return arrayOf(literal)
        return network?.getAllByName(host) ?: InetAddress.getAllByName(host)
    }

    private fun parseEndpoint(value: String, defaultPort: Int): Endpoint {
        var input = value.trim()
        if (input.startsWith("dns://")) input = input.substring(6)
        if (input.startsWith("[")) {
            val end = input.indexOf(']')
            if (end > 0) {
                val portText = input.substring(end + 1).removePrefix(":")
                val port = if (portText.isEmpty()) {
                    defaultPort
                } else {
                    portText.toIntOrNull()?.also(::checkPort)
                        ?: throw IOException("端口必须是 1 到 65535 的数字")
                }
                return Endpoint(
                    input.substring(1, end),
                    port,
                )
            }
        }
        val separator = input.lastIndexOf(':')
        return if (separator > 0 && input.indexOf(':') == separator) {
            Endpoint(
                input.substring(0, separator),
                input.substring(separator + 1).toIntOrNull()?.also(::checkPort)
                    ?: throw IOException("端口必须是 1 到 65535 的数字"),
            )
        } else {
            Endpoint(input, defaultPort)
        }
    }

    private fun checkPort(port: Int) {
        if (port !in 1..65535) throw IOException("端口必须是 1 到 65535")
    }

    private fun readableError(error: Exception): String {
        val message = error.message?.takeIf { it.isNotBlank() } ?: error.javaClass.simpleName
        return when {
            message.contains("timed out", true) -> "请求超时，请检查网络或服务器端口"
            message.contains("CERT", true) || message.contains("SSL", true) -> "TLS 校验失败：$message"
            else -> message
        }
    }

    private data class Endpoint(val host: String, val port: Int)
}

object DnsPacket {
    fun query(name: String, type: Int, id: Int): ByteArray {
        val output = ByteArrayOutputStream()
        val header = ByteBuffer.allocate(12).order(ByteOrder.BIG_ENDIAN)
        header.putShort(id.toShort())
        header.putShort(0x0100.toShort())
        header.putShort(1)
        header.putShort(0)
        header.putShort(0)
        header.putShort(0)
        output.write(header.array())
        name.trim('.').split('.').forEach { label ->
            val bytes = label.toByteArray(Charsets.US_ASCII)
            output.write(bytes.size)
            output.write(bytes)
        }
        output.write(0)
        output.write(ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putShort(type.toShort()).putShort(1).array())
        return output.toByteArray()
    }

    fun parseQuery(data: ByteArray): DnsQuery? {
        if (data.size < 17 || u16(data, 4) != 1) return null
        val nameResult = readName(data, 12) ?: return null
        val typeOffset = nameResult.second
        if (typeOffset + 4 > data.size) return null
        return DnsQuery(nameResult.first, u16(data, typeOffset), typeOffset + 4)
    }

    fun isResponse(data: ByteArray): Boolean = data.size >= 12 && (u16(data, 2) and 0x8000) != 0

    fun isSuccessfulResponse(data: ByteArray, query: ByteArray): Boolean {
        return isResponse(data) &&
            data.size >= 12 &&
            query.size >= 2 &&
            data[0] == query[0] &&
            data[1] == query[1] &&
            (u16(data, 2) and 0x000f) == 0
    }

    fun hostResponse(query: ByteArray, parsed: DnsQuery, targetIp: String): ByteArray? {
        val address = parseIpAddress(targetIp) ?: return null
        when (parsed.type) {
            1 -> if (address !is Inet4Address) return null
            28 -> if (address !is Inet6Address) return null
            else -> return null
        }
        return answerResponse(query, parsed, listOf(address))
    }

    private fun answerResponse(query: ByteArray, parsed: DnsQuery, addresses: List<InetAddress>): ByteArray {
        val question = query.copyOfRange(12, parsed.questionEnd)
        val output = ByteArrayOutputStream()
        val flags = ((u16(query, 2) and 0x0100) or 0x8080).toShort()
        output.write(ByteBuffer.allocate(12).order(ByteOrder.BIG_ENDIAN)
            .putShort(ByteBuffer.wrap(query).order(ByteOrder.BIG_ENDIAN).short)
            .putShort(flags)
            .putShort(1)
            .putShort(addresses.size.toShort())
            .putShort(0)
            .putShort(0).array())
        output.write(question)
        addresses.forEach { address ->
            output.write(byteArrayOf(0xc0.toByte(), 0x0c))
            output.write(ByteBuffer.allocate(10).order(ByteOrder.BIG_ENDIAN)
                .putShort(if (address.address.size == 4) 1 else 28)
                .putShort(1)
                .putInt(60)
                .putShort(address.address.size.toShort()).array())
            output.write(address.address)
        }
        return output.toByteArray()
    }

    fun servfail(query: ByteArray): ByteArray {
        val parsed = parseQuery(query) ?: return query
        val question = query.copyOfRange(12, parsed.questionEnd)
        return ByteArrayOutputStream().apply {
            write(ByteBuffer.allocate(12).order(ByteOrder.BIG_ENDIAN)
                .putShort(ByteBuffer.wrap(query).order(ByteOrder.BIG_ENDIAN).short)
                .putShort(((u16(query, 2) and 0x0100) or 0x8082).toShort())
                .putShort(1).putShort(0).putShort(0).putShort(0).array())
            write(question)
        }.toByteArray()
    }

    fun isIpAddress(value: String): Boolean = parseIpAddress(value) != null

    private fun parseIpAddress(value: String): InetAddress? {
        val normalized = value.trim().removePrefix("[").removeSuffix("]")
        if (normalized.isEmpty() || !android.net.InetAddresses.isNumericAddress(normalized)) {
            return null
        }
        return try {
            InetAddress.getByName(normalized)
        } catch (_: Exception) {
            null
        }
    }

    private fun readName(data: ByteArray, start: Int): Pair<String, Int>? {
        val labels = mutableListOf<String>()
        var offset = start
        var consumed = false
        var jumps = 0
        while (offset < data.size && jumps++ < 32) {
            val length = data[offset].toInt() and 0xff
            if (length == 0) {
                offset++
                if (labels.isEmpty()) labels.add("")
                return labels.joinToString(".").lowercase() to (if (consumed) start + 2 else offset)
            }
            if ((length and 0xc0) == 0xc0) {
                if (offset + 1 >= data.size) return null
                val pointer = ((length and 0x3f) shl 8) or (data[offset + 1].toInt() and 0xff)
                val pointed = readName(data, pointer) ?: return null
                labels.add(pointed.first)
                offset += 2
                consumed = true
                return labels.joinToString(".").lowercase() to (if (consumed) offset else pointed.second)
            }
            if (length > 63 || offset + 1 + length > data.size) return null
            labels.add(String(data, offset + 1, length, Charsets.US_ASCII))
            offset += length + 1
        }
        return null
    }

    private fun u16(data: ByteArray, offset: Int): Int =
        ((data[offset].toInt() and 0xff) shl 8) or (data[offset + 1].toInt() and 0xff)
}

fun readExact(input: java.io.InputStream, length: Int): ByteArray {
    val result = ByteArray(length)
    var offset = 0
    while (offset < length) {
        val count = input.read(result, offset, length - offset)
        if (count < 0) throw IOException("DNS 响应提前结束")
        offset += count
    }
    return result
}

fun readU16(input: java.io.InputStream): Int {
    val first = input.read()
    val second = input.read()
    if (first < 0 || second < 0) throw IOException("DNS 长度字段不完整")
    return (first shl 8) or second
}
