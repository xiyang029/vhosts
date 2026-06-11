package com.xiyang.vhosts

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.Log
import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.IDN
import java.net.Socket
import java.net.URI
import java.nio.ByteBuffer
import java.nio.ByteOrder
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
import kotlin.concurrent.thread
import kotlin.math.max
import kotlin.math.min

class VhostsVpnService : VpnService() {
    private var vpnInterface: ParcelFileDescriptor? = null
    private var workerThread: Thread? = null
    private val dnsResponseCache = DnsResponseCache()

    @Volatile
    private var running = false

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val configurationJson = intent.getStringExtra(EXTRA_CONFIGURATION_JSON)
                if (configurationJson.isNullOrBlank()) {
                    stopSelfSafely()
                    return START_NOT_STICKY
                }
                if (!startVpn(configurationJson)) {
                    return START_NOT_STICKY
                }
            }

            ACTION_STOP -> {
                stopVpn()
                stopSelfSafely()
            }
        }

        return START_STICKY
    }

    override fun onDestroy() {
        stopVpn()
        super.onDestroy()
    }

    override fun onRevoke() {
        stopVpn()
        notifyStateChanged(
            context = this,
            authorized = false,
            running = false,
        )
        stopSelf()
        super.onRevoke()
    }

    private fun startVpn(configurationJson: String): Boolean {
        if (running) {
            return true
        }

        if (VpnService.prepare(this) != null) {
            Log.w(TAG, "VPN permission is not available; another VPN may be active")
            notifyStateChanged(
                context = this,
                authorized = false,
                running = false,
            )
            stopSelf()
            return false
        }

        val config = try {
            parseSessionConfig(configurationJson)
        } catch (error: Exception) {
            Log.e(TAG, "Failed to parse session configuration", error)
            null
        } ?: run {
            stopSelfSafely()
            return false
        }

        dnsResponseCache.clear()

        val builder = Builder()
            .setSession("vhosts DNS")
            .setMtu(1500)
            .addAddress("10.0.0.2", 32)
            .addDnsServer(DNS_BRIDGE_IPV4)
            .addRoute(DNS_BRIDGE_IPV4, 32)

        if (config.allowIpv6) {
            builder
                .addAddress(VPN_TUN_IPV6, 128)
                .addDnsServer(DNS_BRIDGE_IPV6)
                .addRoute(DNS_BRIDGE_IPV6, 128)
        }

        vpnInterface = try {
            builder.establish()
        } catch (error: Exception) {
            Log.e(TAG, "Failed to establish VPN interface", error)
            null
        }
        if (vpnInterface == null) {
            Log.e(TAG, "Failed to establish VPN interface")
            stopSelfSafely()
            return false
        }

        val notification = buildNotification(config)
        try {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED,
            )
        } catch (error: Exception) {
            Log.e(TAG, "Failed to promote VPN service to foreground", error)
            stopSelfSafely()
            return false
        }

        setRunning(true)

        workerThread = thread(name = "vhosts-vpn-worker", isDaemon = true) {
            try {
                processPackets(config)
            } finally {
                if (running && !Thread.currentThread().isInterrupted) {
                    Handler(Looper.getMainLooper()).post {
                        if (running) {
                            stopSelfSafely()
                        }
                    }
                }
            }
        }
        return true
    }

    private fun stopVpn() {
        setRunning(false)
        workerThread?.interrupt()
        workerThread = null
        vpnInterface?.close()
        vpnInterface = null

        stopForeground(STOP_FOREGROUND_REMOVE)
    }

    private fun processPackets(config: SessionConfig) {
        val tun = vpnInterface ?: return
        val input = FileInputStream(tun.fileDescriptor)
        val output = FileOutputStream(tun.fileDescriptor)
        val packet = ByteArray(32767)

        while (running && !Thread.currentThread().isInterrupted) {
            val length = try {
                input.read(packet)
            } catch (_: Exception) {
                break
            }

            if (length < 0) {
                break
            }

            if (length == 0) {
                continue
            }

            val parsed = parseUdpPacket(packet, length, config.allowIpv6) ?: continue
            if (parsed.destinationPort != DNS_PORT || !isDnsBridgeAddress(parsed.destinationAddress)) {
                continue
            }

            val dnsQuery = parseDnsQuery(parsed.packet, parsed.payloadOffset, parsed.payloadLength) ?: continue
            val matchedRule = config.findMatchingRule(dnsQuery.questionName)
            val cacheKey = DnsCacheKey(
                questionName = dnsQuery.questionName,
                questionType = dnsQuery.questionType,
            )
            val cachedPayload = dnsResponseCache.get(cacheKey, dnsQuery.transactionId)

            val dnsPayload = cachedPayload ?: run {
                val ruleResponse = if (matchedRule != null && dnsQuery.questionType.isAddressRecord) {
                    buildDnsResponse(dnsQuery, matchedRule.rule.targetIp)
                } else {
                    null
                }

                val payload = ruleResponse ?: run {
                    val forwardResult = performDnsForward(
                        context = this,
                        config = config,
                        queryBytes = parsed.packet.copyOfRange(parsed.payloadOffset, parsed.payloadOffset + parsed.payloadLength),
                        datagramProtector = { socket -> protect(socket) },
                        rawSocketProtector = { socket -> protect(socket) },
                    )
                    forwardResult?.responseBytes?.also { responseBytes ->
                        val ttlSeconds = extractDnsResponseMinTtlSeconds(responseBytes)
                            ?: DEFAULT_CACHE_TTL_SECONDS
                        dnsResponseCache.put(cacheKey, responseBytes, ttlSeconds)
                    }
                }

                if (payload != null && ruleResponse != null) {
                    dnsResponseCache.put(cacheKey, payload, DEFAULT_CACHE_TTL_SECONDS)
                }

                payload
            } ?: continue

            val responsePacket = when (parsed.ipVersion) {
                4 -> buildIpv4UdpPacket(
                    sourceAddress = parsed.destinationAddress,
                    destinationAddress = parsed.sourceAddress,
                    sourcePort = parsed.destinationPort,
                    destinationPort = parsed.sourcePort,
                    payload = dnsPayload,
                )

                6 -> buildIpv6UdpPacket(
                    sourceAddress = parsed.destinationAddress,
                    destinationAddress = parsed.sourceAddress,
                    sourcePort = parsed.destinationPort,
                    destinationPort = parsed.sourcePort,
                    payload = dnsPayload,
                )

                else -> null
            } ?: continue

            try {
                output.write(responsePacket)
                output.flush()
            } catch (error: Exception) {
                Log.e(TAG, "Failed to write DNS response", error)
            }
        }
    }

    private fun buildDnsResponse(query: DnsQuery, answerIp: String): ByteArray? {
        val answerType = when (query.questionType) {
            DnsRecordType.A -> 1
            DnsRecordType.AAAA -> 28
            else -> return null
        }

        val ipBytes = try {
            InetAddress.getByName(answerIp).address
        } catch (_: Exception) {
            return buildDnsNoDataResponse(query)
        }

        if ((answerType == 1 && ipBytes.size != 4) || (answerType == 28 && ipBytes.size != 16)) {
            Log.w(
                TAG,
                "Hosts rule matched ${query.questionName}, but target IP family does not match query type ${query.questionType}",
            )
            return buildDnsNoDataResponse(query)
        }

        val response = ByteBuffer.allocate(512).order(ByteOrder.BIG_ENDIAN)
        response.putShort(query.transactionId)
        response.putShort(0x8180.toShort())
        response.putShort(1.toShort())
        response.putShort(1.toShort())
        response.putShort(0.toShort())
        response.putShort(0.toShort())
        response.put(query.packet, query.questionOffset, query.questionEndOffset - query.questionOffset)
        response.putShort(0xC00C.toShort())
        response.putShort(answerType.toShort())
        response.putShort(1.toShort())
        response.putInt(60)
        response.putShort(ipBytes.size.toShort())
        response.put(ipBytes)
        return response.array().copyOf(response.position())
    }

    private fun buildDnsNoDataResponse(query: DnsQuery): ByteArray {
        val response = ByteBuffer.allocate(512).order(ByteOrder.BIG_ENDIAN)
        response.putShort(query.transactionId)
        response.putShort(0x8180.toShort())
        response.putShort(1.toShort())
        response.putShort(0.toShort())
        response.putShort(0.toShort())
        response.putShort(0.toShort())
        response.put(query.packet, query.questionOffset, query.questionEndOffset - query.questionOffset)
        return response.array().copyOf(response.position())
    }

    private fun parseUdpPacket(packet: ByteArray, packetLength: Int, allowIpv6: Boolean): ParsedUdpPacket? {
        if (packetLength <= 0) {
            return null
        }

        return when ((packet[0].toInt() shr 4) and 0x0F) {
            4 -> parseIpv4UdpPacket(packet, packetLength)
            6 -> if (allowIpv6) parseIpv6UdpPacket(packet, packetLength) else null
            else -> null
        }
    }

    private fun parseIpv4UdpPacket(packet: ByteArray, packetLength: Int): ParsedUdpPacket? {
        val version = (packet[0].toInt() shr 4) and 0x0F
        if (version != 4) {
            return null
        }

        val headerLength = (packet[0].toInt() and 0x0F) * 4
        if (packetLength < headerLength + UDP_HEADER_LENGTH) {
            return null
        }

        val totalLength = readUnsignedShort(packet, 2)
        if (totalLength > packetLength || totalLength < headerLength + UDP_HEADER_LENGTH) {
            return null
        }

        val protocol = packet[9].toInt() and 0xFF
        if (protocol != UDP_PROTOCOL_NUMBER) {
            return null
        }

        val sourceAddress = InetAddress.getByAddress(packet.copyOfRange(12, 16))
        val destinationAddress = InetAddress.getByAddress(packet.copyOfRange(16, 20))

        val udpOffset = headerLength
        val sourcePort = readUnsignedShort(packet, udpOffset)
        val destinationPort = readUnsignedShort(packet, udpOffset + 2)
        val udpLength = readUnsignedShort(packet, udpOffset + 4)
        if (udpLength < UDP_HEADER_LENGTH || udpOffset + udpLength > packetLength) {
            return null
        }

        val payloadOffset = udpOffset + UDP_HEADER_LENGTH
        val payloadLength = min(udpLength - UDP_HEADER_LENGTH, totalLength - payloadOffset)

        return ParsedUdpPacket(
            ipVersion = 4,
            sourceAddress = sourceAddress,
            destinationAddress = destinationAddress,
            sourcePort = sourcePort,
            destinationPort = destinationPort,
            packet = packet,
            payloadOffset = payloadOffset,
            payloadLength = payloadLength,
        )
    }

    private fun parseIpv6UdpPacket(packet: ByteArray, packetLength: Int): ParsedUdpPacket? {
        if (packetLength < IPV6_HEADER_LENGTH + UDP_HEADER_LENGTH) {
            return null
        }

        val version = (packet[0].toInt() shr 4) and 0x0F
        if (version != 6) {
            return null
        }

        val advertisedPayloadLength = readUnsignedShort(packet, 4)
        val packetLimit = when {
            advertisedPayloadLength == 0 -> packetLength
            IPV6_HEADER_LENGTH + advertisedPayloadLength > packetLength -> return null
            else -> IPV6_HEADER_LENGTH + advertisedPayloadLength
        }

        val sourceAddress = InetAddress.getByAddress(packet.copyOfRange(8, 24))
        val destinationAddress = InetAddress.getByAddress(packet.copyOfRange(24, 40))

        var nextHeader = packet[6].toInt() and 0xFF
        var offset = IPV6_HEADER_LENGTH

        while (nextHeader != UDP_PROTOCOL_NUMBER) {
            when (nextHeader) {
                IPV6_NEXT_HEADER_HOP_BY_HOP,
                IPV6_NEXT_HEADER_ROUTING,
                IPV6_NEXT_HEADER_DESTINATION_OPTIONS,
                IPV6_NEXT_HEADER_MOBILITY,
                -> {
                    if (offset + 2 > packetLimit) {
                        return null
                    }
                    val headerLength = ((packet[offset + 1].toInt() and 0xFF) + 1) * 8
                    nextHeader = packet[offset].toInt() and 0xFF
                    offset += headerLength
                }

                IPV6_NEXT_HEADER_FRAGMENT -> {
                    if (offset + 8 > packetLimit) {
                        return null
                    }
                    val fragmentField = readUnsignedShort(packet, offset + 2)
                    val fragmentOffset = (fragmentField and 0xFFF8) shr 3
                    val hasMoreFragments = (fragmentField and 0x0001) != 0
                    if (fragmentOffset != 0 || hasMoreFragments) {
                        return null
                    }
                    nextHeader = packet[offset].toInt() and 0xFF
                    offset += 8
                }

                IPV6_NEXT_HEADER_AUTHENTICATION -> {
                    if (offset + 2 > packetLimit) {
                        return null
                    }
                    val headerLength = ((packet[offset + 1].toInt() and 0xFF) + 2) * 4
                    nextHeader = packet[offset].toInt() and 0xFF
                    offset += headerLength
                }

                else -> return null
            }

            if (offset + UDP_HEADER_LENGTH > packetLimit) {
                return null
            }
        }

        val sourcePort = readUnsignedShort(packet, offset)
        val destinationPort = readUnsignedShort(packet, offset + 2)
        val udpLength = readUnsignedShort(packet, offset + 4)
        val availableUdpLength = packetLimit - offset
        val effectiveUdpLength = when {
            udpLength == 0 -> availableUdpLength
            udpLength < UDP_HEADER_LENGTH || udpLength > availableUdpLength -> return null
            else -> udpLength
        }

        val payloadOffset = offset + UDP_HEADER_LENGTH
        val payloadLength = effectiveUdpLength - UDP_HEADER_LENGTH

        return ParsedUdpPacket(
            ipVersion = 6,
            sourceAddress = sourceAddress,
            destinationAddress = destinationAddress,
            sourcePort = sourcePort,
            destinationPort = destinationPort,
            packet = packet,
            payloadOffset = payloadOffset,
            payloadLength = payloadLength,
        )
    }

    private fun parseDnsQuery(packet: ByteArray, payloadOffset: Int, payloadLength: Int): DnsQuery? {
        if (payloadLength < 12) {
            return null
        }

        val payloadEnd = payloadOffset + payloadLength
        val questionOffset = payloadOffset + 12
        val transactionId = readShort(packet, payloadOffset)
        val questionNameBuilder = StringBuilder()
        var offset = questionOffset

        while (offset < payloadEnd) {
            val labelLength = packet[offset].toInt() and 0xFF
            offset += 1
            if (labelLength == 0) {
                break
            }
            if (offset + labelLength > payloadEnd) {
                return null
            }

            if (questionNameBuilder.isNotEmpty()) {
                questionNameBuilder.append('.')
            }
            questionNameBuilder.append(String(packet, offset, labelLength, Charsets.UTF_8))
            offset += labelLength
        }

        if (offset + 4 > payloadEnd) {
            return null
        }

        val questionType = DnsRecordType.fromCode(readUnsignedShort(packet, offset))
        offset += 2
        offset += 2

        return DnsQuery(
            transactionId = transactionId,
            questionName = normalizeDomain(questionNameBuilder.toString()),
            questionType = questionType,
            packet = packet,
            questionOffset = questionOffset,
            questionEndOffset = offset,
        )
    }

    private fun buildIpv4UdpPacket(
        sourceAddress: InetAddress,
        destinationAddress: InetAddress,
        sourcePort: Int,
        destinationPort: Int,
        payload: ByteArray,
    ): ByteArray {
        val udpLength = UDP_HEADER_LENGTH + payload.size
        val ipLength = 20 + udpLength
        val packet = ByteBuffer.allocate(ipLength).order(ByteOrder.BIG_ENDIAN)

        packet.put(((4 shl 4) or 5).toByte())
        packet.put(0)
        packet.putShort(ipLength.toShort())
        packet.putShort(0)
        packet.putShort(0)
        packet.put(64.toByte())
        packet.put(UDP_PROTOCOL_NUMBER.toByte())
        packet.putShort(0)
        packet.put(sourceAddress.address)
        packet.put(destinationAddress.address)

        val ipHeader = packet.array()
        writeIpv4Checksum(ipHeader)

        val udpStart = 20
        writeUnsignedShort(ipHeader, udpStart, sourcePort)
        writeUnsignedShort(ipHeader, udpStart + 2, destinationPort)
        writeUnsignedShort(ipHeader, udpStart + 4, udpLength)
        writeUnsignedShort(ipHeader, udpStart + 6, 0)
        System.arraycopy(payload, 0, ipHeader, udpStart + UDP_HEADER_LENGTH, payload.size)
        writeUdpChecksum(
            packet = ipHeader,
            udpStart = udpStart,
            udpLength = udpLength,
            sourceAddress = sourceAddress.address,
            destinationAddress = destinationAddress.address,
            protocol = UDP_PROTOCOL_NUMBER,
        )

        return ipHeader
    }

    private fun buildIpv6UdpPacket(
        sourceAddress: InetAddress,
        destinationAddress: InetAddress,
        sourcePort: Int,
        destinationPort: Int,
        payload: ByteArray,
    ): ByteArray? {
        val sourceBytes = sourceAddress.address
        val destinationBytes = destinationAddress.address
        if (sourceBytes.size != 16 || destinationBytes.size != 16) {
            return null
        }

        val udpLength = UDP_HEADER_LENGTH + payload.size
        val packet = ByteBuffer.allocate(IPV6_HEADER_LENGTH + udpLength).order(ByteOrder.BIG_ENDIAN)

        packet.putInt(6 shl 28)
        packet.putShort(udpLength.toShort())
        packet.put(UDP_PROTOCOL_NUMBER.toByte())
        packet.put(64.toByte())
        packet.put(sourceBytes)
        packet.put(destinationBytes)

        val bytes = packet.array()
        val udpStart = IPV6_HEADER_LENGTH
        writeUnsignedShort(bytes, udpStart, sourcePort)
        writeUnsignedShort(bytes, udpStart + 2, destinationPort)
        writeUnsignedShort(bytes, udpStart + 4, udpLength)
        writeUnsignedShort(bytes, udpStart + 6, 0)
        System.arraycopy(payload, 0, bytes, udpStart + UDP_HEADER_LENGTH, payload.size)
        writeUdpChecksum(
            packet = bytes,
            udpStart = udpStart,
            udpLength = udpLength,
            sourceAddress = sourceBytes,
            destinationAddress = destinationBytes,
            protocol = UDP_PROTOCOL_NUMBER,
        )

        return bytes
    }

    private fun writeIpv4Checksum(packet: ByteArray) {
        packet[10] = 0
        packet[11] = 0
        val checksum = checksum(packet, 0, 20)
        packet[10] = (checksum shr 8).toByte()
        packet[11] = checksum.toByte()
    }

    private fun writeUdpChecksum(
        packet: ByteArray,
        udpStart: Int,
        udpLength: Int,
        sourceAddress: ByteArray,
        destinationAddress: ByteArray,
        protocol: Int,
    ) {
        packet[udpStart + 6] = 0
        packet[udpStart + 7] = 0

        var sum = 0
        sum = accumulateChecksum(sum, sourceAddress, 0, sourceAddress.size)
        sum = accumulateChecksum(sum, destinationAddress, 0, destinationAddress.size)
        sum = if (sourceAddress.size == 4) {
            sum = accumulateChecksum(sum, byteArrayOf(0, protocol.toByte()), 0, 2)
            accumulateChecksum(
                sum,
                byteArrayOf(((udpLength shr 8) and 0xFF).toByte(), (udpLength and 0xFF).toByte()),
                0,
                2,
            )
        } else {
            val pseudoHeader = ByteBuffer.allocate(8).order(ByteOrder.BIG_ENDIAN)
                .putInt(udpLength)
                .putInt(protocol)
                .array()
            accumulateChecksum(sum, pseudoHeader, 0, pseudoHeader.size)
        }

        sum = accumulateChecksum(sum, packet, udpStart, udpLength)
        var checksum = finalizeChecksum(sum)
        if (checksum == 0) {
            checksum = 0xFFFF
        }
        writeUnsignedShort(packet, udpStart + 6, checksum)
    }

    private fun checksum(buffer: ByteArray, start: Int, length: Int): Int {
        return finalizeChecksum(accumulateChecksum(0, buffer, start, length))
    }

    private fun accumulateChecksum(initialSum: Int, buffer: ByteArray, start: Int, length: Int): Int {
        var sum = initialSum
        var index = start
        while (index < start + length) {
            val high = buffer[index].toInt() and 0xFF
            val low = if (index + 1 < start + length) buffer[index + 1].toInt() and 0xFF else 0
            sum += (high shl 8) or low
            while (sum > 0xFFFF) {
                sum = (sum and 0xFFFF) + (sum shr 16)
            }
            index += 2
        }
        return sum
    }

    private fun finalizeChecksum(sumValue: Int): Int {
        var sum = sumValue
        while (sum > 0xFFFF) {
            sum = (sum and 0xFFFF) + (sum shr 16)
        }
        return sum.inv() and 0xFFFF
    }

    private fun readUnsignedShort(buffer: ByteArray, offset: Int): Int {
        return ((buffer[offset].toInt() and 0xFF) shl 8) or (buffer[offset + 1].toInt() and 0xFF)
    }

    private fun readShort(buffer: ByteArray, offset: Int): Short {
        return readUnsignedShort(buffer, offset).toShort()
    }

    private fun writeUnsignedShort(buffer: ByteArray, offset: Int, value: Int) {
        buffer[offset] = ((value shr 8) and 0xFF).toByte()
        buffer[offset + 1] = (value and 0xFF).toByte()
    }

    private fun buildNotification(config: SessionConfig): Notification {
        createNotificationChannel()

        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }

        val message = buildString {
            append(config.activeProfile?.name ?: "DNS")
            append(" · ")
            append(config.hostRuleCount)
            append(" 条规则")
        }

        val builder = Notification.Builder(this, CHANNEL_ID)

        return builder
            .setContentTitle("vhosts 正在接管 DNS")
            .setContentText(message)
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .setOngoing(true)
            .apply {
                if (pendingIntent != null) {
                    setContentIntent(pendingIntent)
                }
            }
            .build()
    }

    private fun createNotificationChannel() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) {
            return
        }

        val channel = NotificationChannel(
            CHANNEL_ID,
            "vhosts VPN",
            NotificationManager.IMPORTANCE_LOW,
        )
        manager.createNotificationChannel(channel)
    }

    private fun stopSelfSafely() {
        stopVpn()
        stopSelf()
    }

    private fun setRunning(value: Boolean) {
        running = value
        serviceRunning = value
        notifyStateChanged(this)
    }

    companion object {
        const val ACTION_START = "com.xiyang.vhosts.action.START_VPN"
        const val ACTION_STOP = "com.xiyang.vhosts.action.STOP_VPN"
        const val ACTION_VPN_STATE_CHANGED = "com.xiyang.vhosts.action.VPN_STATE_CHANGED"
        const val EXTRA_CONFIGURATION_JSON = "com.xiyang.vhosts.extra.CONFIGURATION_JSON"
        const val EXTRA_AUTHORIZED = "com.xiyang.vhosts.extra.AUTHORIZED"
        const val EXTRA_RUNNING = "com.xiyang.vhosts.extra.RUNNING"
        @Volatile
        private var serviceRunning = false

        fun isRunning(context: Context): Boolean = VpnService.prepare(context) == null && serviceRunning

        fun notifyStateChanged(
            context: Context,
            authorized: Boolean = VpnService.prepare(context) == null,
            running: Boolean = authorized && serviceRunning,
        ) {
            context.sendBroadcast(
                Intent(ACTION_VPN_STATE_CHANGED).apply {
                    setPackage(context.packageName)
                    putExtra(EXTRA_AUTHORIZED, authorized)
                    putExtra(EXTRA_RUNNING, running)
                },
            )
        }

        fun statePayloadFromIntent(intent: Intent): Map<String, Boolean>? {
            if (!intent.hasExtra(EXTRA_AUTHORIZED) || !intent.hasExtra(EXTRA_RUNNING)) {
                return null
            }

            return mapOf(
                "authorized" to intent.getBooleanExtra(EXTRA_AUTHORIZED, false),
                "running" to intent.getBooleanExtra(EXTRA_RUNNING, false),
            )
        }

        fun saveConfiguration(context: Context, configurationJson: String) {
            context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_CONFIGURATION_JSON, configurationJson)
                .apply()
        }

        fun loadConfiguration(context: Context): String? {
            return context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
                .getString(KEY_CONFIGURATION_JSON, null)
                ?.takeIf { it.isNotBlank() }
        }

        private const val TAG = "VhostsVpnService"
        private const val PREFERENCES_NAME = "vhosts_native"
        private const val KEY_CONFIGURATION_JSON = "configuration_json"
        private const val CHANNEL_ID = "vhosts_vpn"
        private const val NOTIFICATION_ID = 0x1188
        private const val DNS_PORT = 53
        private const val UDP_PROTOCOL_NUMBER = 17
        private const val UDP_HEADER_LENGTH = 8
        private const val IPV6_HEADER_LENGTH = 40
        private const val IPV6_NEXT_HEADER_HOP_BY_HOP = 0
        private const val IPV6_NEXT_HEADER_ROUTING = 43
        private const val IPV6_NEXT_HEADER_FRAGMENT = 44
        private const val IPV6_NEXT_HEADER_AUTHENTICATION = 51
        private const val IPV6_NEXT_HEADER_DESTINATION_OPTIONS = 60
        private const val IPV6_NEXT_HEADER_MOBILITY = 135
        const val DNS_BRIDGE_IPV4 = "10.0.0.53"
        const val DNS_BRIDGE_IPV6 = "fd00:1:fd00:1::53"
        private const val VPN_TUN_IPV6 = "fd00:1:fd00:1::2"
    }
}

internal fun runDnsHealthCheck(
    context: Context,
    profileJson: String,
    allowIpv6: Boolean,
): Map<String, Any?> {
    val profile = try {
        parseDnsProfileConfig(JSONObject(profileJson))
    } catch (_: Exception) {
        return mapOf(
            "healthStatus" to DnsHealthStatusName.OFFLINE.value,
            "healthDetail" to "DNS 配置解析失败，请检查表单内容",
            "latencyMs" to null,
        )
    }

    val queryType = if (allowIpv6) DnsRecordType.AAAA else DnsRecordType.A
    val queryBytes = buildDnsQuery("example.com", queryType)
    val session = SessionConfig(
        activeProfile = profile,
        hostRules = emptyList(),
        allowIpv6 = allowIpv6,
    )

    val result = session.forwardPrimaryDnsQuery(context, queryBytes)

    if (result == null) {
        return mapOf(
            "healthStatus" to DnsHealthStatusName.OFFLINE.value,
            "healthDetail" to "${profile.name} 探测失败，请检查服务器地址、协议类型或网络连通性",
            "latencyMs" to null,
        )
    }

    val resultIps = extractDnsAnswerIps(result.responseBytes)
    val healthStatus = when {
        resultIps.isEmpty() -> DnsHealthStatusName.DEGRADED.value
        result.latencyMs > max(profile.timeoutMs, 1800) -> DnsHealthStatusName.DEGRADED.value
        else -> DnsHealthStatusName.HEALTHY.value
    }
    val detail = when (healthStatus) {
        DnsHealthStatusName.HEALTHY.value ->
            "${profile.name} 连接成功，${result.transport} ${result.upstreamLabel} 响应正常"

        DnsHealthStatusName.DEGRADED.value ->
            "${profile.name} 已连通，但响应偏慢或未返回 A/AAAA 结果"

        else ->
            "${profile.name} 当前不可用，请检查服务器或网络"
    }
    return mapOf(
        "healthStatus" to healthStatus,
        "healthDetail" to detail,
        "latencyMs" to result.latencyMs,
    )
}

private data class ParsedUdpPacket(
    val ipVersion: Int,
    val sourceAddress: InetAddress,
    val destinationAddress: InetAddress,
    val sourcePort: Int,
    val destinationPort: Int,
    val packet: ByteArray,
    val payloadOffset: Int,
    val payloadLength: Int,
)

private data class DnsQuery(
    val transactionId: Short,
    val questionName: String,
    val questionType: DnsRecordType,
    val packet: ByteArray,
    val questionOffset: Int,
    val questionEndOffset: Int,
)

private data class HostRuleConfig(
    val id: String,
    val domain: String,
    val matchType: String,
    val targetIp: String,
    val enabled: Boolean,
) {
    val normalizedMatchType: String
        get() = matchType.lowercase()
}

private data class DnsProfileConfig(
    val id: String,
    val name: String,
    val type: String,
    val server: String,
    val secondaryServer: String,
    val dohUrl: String,
    val dotHostname: String,
    val timeoutMs: Int,
    val retryCount: Int,
    val enabled: Boolean,
) {
    val normalizedType: String
        get() = type.lowercase()
}

private data class UpstreamDnsServer(
    val address: InetAddress,
    val port: Int,
) {
    val label: String
        get() = "${address.hostAddress}:$port"
}

private data class CompiledHostRule(
    val rule: HostRuleConfig,
    val normalizedDomain: String,
    val suffix: String?,
    val wildcardRegex: Regex?,
) {
    fun matchesSuffix(domain: String): Boolean {
        val suffixValue = suffix ?: return false
        return domain == suffixValue || domain.endsWith(".$suffixValue")
    }

    fun matchesWildcard(domain: String): Boolean {
        val regex = wildcardRegex ?: return normalizedDomain == domain
        return regex.matches(domain)
    }
}

private data class SessionConfig(
    val activeProfile: DnsProfileConfig?,
    val hostRules: List<HostRuleConfig>,
    val allowIpv6: Boolean,
) {
    private val enabledRules = hostRules.asSequence()
        .filter { it.enabled }
        .map(::compileHostRule)
        .toList()
    private val exactRules = enabledRules
        .filter { it.rule.normalizedMatchType == "exact" }
        .associateBy { it.normalizedDomain }
    private val suffixRules = enabledRules
        .filter { it.rule.normalizedMatchType == "suffix" }
    private val wildcardRules = enabledRules
        .filter { it.rule.normalizedMatchType != "exact" && it.rule.normalizedMatchType != "suffix" }

    val hostRuleCount: Int
        get() = enabledRules.size

    fun findMatchingRule(questionName: String): CompiledHostRule? {
        val normalized = normalizeDomain(questionName)
        exactRules[normalized]?.let { return it }
        suffixRules.firstOrNull { it.matchesSuffix(normalized) }?.let { return it }
        return wildcardRules.firstOrNull { it.matchesWildcard(normalized) }
    }

    fun resolveUpstreamServers(context: Context): List<UpstreamDnsServer> {
        val profile = activeProfile ?: return systemDnsServers(context)
        return when (profile.normalizedType) {
            "plain" -> parsePlainServers(profile)
            else -> systemDnsServers(context)
        }
    }

    fun systemDnsServers(context: Context): List<UpstreamDnsServer> {
        val connectivityManager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return fallbackServers()
        val preferredNetwork = connectivityManager.activeNetwork
        if (preferredNetwork != null) {
            dnsServersForNetwork(connectivityManager, preferredNetwork)?.let { servers ->
                if (servers.isNotEmpty()) {
                    return servers
                }
            }
        }

        return fallbackServers()
    }

    private fun dnsServersForNetwork(
        connectivityManager: ConnectivityManager,
        network: android.net.Network,
    ): List<UpstreamDnsServer>? {
        val capabilities = connectivityManager.getNetworkCapabilities(network) ?: return null
        if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) {
            return null
        }
        if (!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
            return null
        }

        val linkProperties = connectivityManager.getLinkProperties(network) ?: return null
        return linkProperties.dnsServers
            .mapNotNull { address ->
                if (!allowIpv6 && address.address.size == 16) {
                    null
                } else {
                    UpstreamDnsServer(address, 53)
                }
            }
            .filterNot { server -> isDnsBridgeAddress(server.address) }
    }

    private fun parsePlainServers(profile: DnsProfileConfig): List<UpstreamDnsServer> {
        val result = mutableListOf<UpstreamDnsServer>()
        addServer(result, profile.server)
        addServer(result, profile.secondaryServer)
        return result.ifEmpty { fallbackServers() }
    }

    private fun addServer(result: MutableList<UpstreamDnsServer>, value: String) {
        val parsed = parseHostAndPort(value) ?: return
        if (!allowIpv6 && parsed.address.address.size == 16) {
            return
        }
        result += parsed
    }

    private fun fallbackServers(): List<UpstreamDnsServer> {
        val servers = mutableListOf(
            UpstreamDnsServer(DNS_BRIDGE_FALLBACK_V4_PRIMARY, 53),
            UpstreamDnsServer(DNS_BRIDGE_FALLBACK_V4_SECONDARY, 53),
        )
        if (allowIpv6) {
            servers += UpstreamDnsServer(DNS_BRIDGE_FALLBACK_V6_PRIMARY, 53)
            servers += UpstreamDnsServer(DNS_BRIDGE_FALLBACK_V6_SECONDARY, 53)
        }
        return servers
    }
}

private data class DnsForwardResult(
    val responseBytes: ByteArray,
    val latencyMs: Int,
    val transport: String,
    val upstreamLabel: String,
)

private enum class DnsRecordType(val code: Int) {
    A(1),
    AAAA(28),
    OTHER(-1);

    val isAddressRecord: Boolean
        get() = this == A || this == AAAA

    companion object {
        fun fromCode(code: Int): DnsRecordType {
            return entries.firstOrNull { it.code == code } ?: OTHER
        }
    }
}

private enum class DnsHealthStatusName(val value: String) {
    HEALTHY("healthy"),
    DEGRADED("degraded"),
    OFFLINE("offline"),
}

private fun parseSessionConfig(configurationJson: String): SessionConfig {
    val root = JSONObject(configurationJson)
    val hostRules = parseObjectArray(root, "hostRules", ::parseHostRuleConfig)
    val profiles = parseObjectArray(root, "dnsProfiles", ::parseDnsProfileConfig)

    val activeProfileId = root.optString("activeDnsProfileId", "")
    val activeProfile = profiles.firstOrNull { it.id == activeProfileId }
        ?: profiles.firstOrNull { it.enabled }
        ?: profiles.firstOrNull()

    return SessionConfig(
        activeProfile = activeProfile,
        hostRules = hostRules,
        allowIpv6 = root.optBoolean("allowIpv6", true),
    )
}

private fun <T> parseObjectArray(
    root: JSONObject,
    key: String,
    parser: (JSONObject) -> T,
): List<T> {
    val array = root.optJSONArray(key) ?: return emptyList()
    val items = mutableListOf<T>()
    for (index in 0 until array.length()) {
        val item = array.optJSONObject(index) ?: continue
        items += parser(item)
    }
    return items
}

private fun parseHostRuleConfig(item: JSONObject): HostRuleConfig {
    return HostRuleConfig(
        id = item.optString("id"),
        domain = item.optString("domain"),
        matchType = item.optString("matchType", "exact"),
        targetIp = item.optString("targetIp"),
        enabled = item.optBoolean("enabled", true),
    )
}

private fun parseDnsProfileConfig(item: JSONObject): DnsProfileConfig {
    return DnsProfileConfig(
        id = item.optString("id"),
        name = item.optString("name"),
        type = item.optString("type"),
        server = item.optString("server"),
        secondaryServer = item.optString("secondaryServer"),
        dohUrl = item.optString("dohUrl"),
        dotHostname = item.optString("dotHostname"),
        timeoutMs = item.optInt("timeoutMs", DEFAULT_TIMEOUT_MS),
        retryCount = max(item.optInt("retryCount", 1), 1),
        enabled = item.optBoolean("enabled", false),
    )
}

private fun compileHostRule(rule: HostRuleConfig): CompiledHostRule {
    val normalizedDomain = normalizeDomain(rule.domain)
    return when (rule.normalizedMatchType) {
        "suffix" -> CompiledHostRule(
            rule = rule,
            normalizedDomain = normalizedDomain,
            suffix = normalizedDomain.removePrefix("*."),
            wildcardRegex = null,
        )

        "wildcard" -> CompiledHostRule(
            rule = rule,
            normalizedDomain = normalizedDomain,
            suffix = null,
            wildcardRegex = buildWildcardRegex(normalizedDomain),
        )

        "exact" -> CompiledHostRule(
            rule = rule,
            normalizedDomain = normalizedDomain,
            suffix = null,
            wildcardRegex = null,
        )

        else -> CompiledHostRule(
            rule = rule,
            normalizedDomain = normalizedDomain,
            suffix = null,
            wildcardRegex = buildWildcardRegex(normalizedDomain),
        )
    }
}

private fun buildWildcardRegex(pattern: String): Regex? {
    if (!pattern.contains('*')) {
        return null
    }

    val regex = pattern
        .split('*')
        .filter { it.isNotEmpty() }
        .joinToString(separator = ".*") { Regex.escape(it) }
    return Regex("^$regex$")
}

private fun performDnsForward(
    context: Context,
    config: SessionConfig,
    queryBytes: ByteArray,
    datagramProtector: ((DatagramSocket) -> Boolean)? = null,
    rawSocketProtector: ((Socket) -> Boolean)? = null,
): DnsForwardResult? {
    val primaryResult = config.forwardPrimaryDnsQuery(
        context = context,
        queryBytes = queryBytes,
        datagramProtector = datagramProtector,
        rawSocketProtector = rawSocketProtector,
    )

    if (primaryResult != null) {
        return primaryResult
    }

    val profile = config.activeProfile ?: return null
    if (profile.normalizedType == "plain" || profile.normalizedType == "system") {
        return null
    }

    return forwardViaUdp(
        queryBytes = queryBytes,
        upstreamServers = config.systemDnsServers(context),
        timeoutMs = profile.timeoutMs,
        retryCount = profile.retryCount,
        datagramProtector = datagramProtector,
        transport = "UDP",
    )
}

private fun SessionConfig.forwardPrimaryDnsQuery(
    context: Context,
    queryBytes: ByteArray,
    datagramProtector: ((DatagramSocket) -> Boolean)? = null,
    rawSocketProtector: ((Socket) -> Boolean)? = null,
): DnsForwardResult? {
    val profile = activeProfile
    val timeoutMs = profile?.timeoutMs ?: DEFAULT_TIMEOUT_MS
    val retryCount = profile?.retryCount ?: 1

    return when (profile?.normalizedType) {
        "doh" -> forwardViaDoH(queryBytes, profile)
        "dot" -> forwardViaDot(queryBytes, profile, rawSocketProtector)
        "plain" -> forwardViaUdp(
            queryBytes = queryBytes,
            upstreamServers = resolveUpstreamServers(context),
            timeoutMs = timeoutMs,
            retryCount = retryCount,
            datagramProtector = datagramProtector,
            transport = "UDP",
        )

        "system", null, "" -> forwardViaUdp(
            queryBytes = queryBytes,
            upstreamServers = systemDnsServers(context),
            timeoutMs = timeoutMs,
            retryCount = retryCount,
            datagramProtector = datagramProtector,
            transport = "System UDP",
        )

        else -> null
    }
}

private fun forwardViaUdp(
    queryBytes: ByteArray,
    upstreamServers: List<UpstreamDnsServer>,
    timeoutMs: Int,
    retryCount: Int,
    datagramProtector: ((DatagramSocket) -> Boolean)? = null,
    transport: String = "UDP",
): DnsForwardResult? {
    val filteredServers = upstreamServers.filterNot { server -> isDnsBridgeAddress(server.address) }
    if (filteredServers.isEmpty()) {
        return null
    }

    repeat(max(retryCount, 1)) {
        for (server in filteredServers) {
            DatagramSocket().use { socket ->
                try {
                    datagramProtector?.invoke(socket)
                    socket.soTimeout = max(timeoutMs, 250)
                    socket.connect(InetSocketAddress(server.address, server.port))
                    val startedAt = System.nanoTime()
                    socket.send(DatagramPacket(queryBytes, queryBytes.size))

                    val responseBuffer = ByteArray(4096)
                    val responsePacket = DatagramPacket(responseBuffer, responseBuffer.size)
                    socket.receive(responsePacket)
                    val elapsedMs = ((System.nanoTime() - startedAt) / 1_000_000L).toInt()
                    return DnsForwardResult(
                        responseBytes = responsePacket.data.copyOf(responsePacket.length),
                        latencyMs = elapsedMs,
                        transport = transport,
                        upstreamLabel = server.label,
                    )
                } catch (error: Exception) {
                    Log.w(TAG_FORWARD, "UDP DNS request failed for ${server.label}", error)
                }
            }
        }
    }

    return null
}

private fun forwardViaDoH(
    queryBytes: ByteArray,
    profile: DnsProfileConfig?,
): DnsForwardResult? {
    val resolvedProfile = profile ?: return null
    val url = resolvedProfile.dohUrl.takeIf { it.isNotBlank() } ?: resolvedProfile.server.takeIf { it.isNotBlank() }
    if (url.isNullOrBlank()) {
        return null
    }

    for (attemptIndex in 0 until max(resolvedProfile.retryCount, 1)) {
        var connection: HttpsURLConnection? = null
        try {
            val startedAt = System.nanoTime()
            connection = (java.net.URL(url).openConnection() as HttpsURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = max(resolvedProfile.timeoutMs, 250)
                readTimeout = max(resolvedProfile.timeoutMs, 250)
                doOutput = true
                setRequestProperty("Content-Type", "application/dns-message")
                setRequestProperty("Accept", "application/dns-message")
            }

            connection.outputStream.use { output ->
                output.write(queryBytes)
            }

            if (connection.responseCode !in 200..299) {
                connection.disconnect()
                continue
            }

            val responseBytes = connection.inputStream.use { input -> input.readBytes() }
            val elapsedMs = ((System.nanoTime() - startedAt) / 1_000_000L).toInt()
            return DnsForwardResult(
                responseBytes = responseBytes,
                latencyMs = elapsedMs,
                transport = "DoH",
                upstreamLabel = url,
            )
        } catch (error: Exception) {
            Log.w(TAG_FORWARD, "DoH query failed for $url on attempt ${attemptIndex + 1}", error)
        } finally {
            connection?.disconnect()
        }
    }

    return null
}

private fun forwardViaDot(
    queryBytes: ByteArray,
    profile: DnsProfileConfig?,
    rawSocketProtector: ((Socket) -> Boolean)? = null,
): DnsForwardResult? {
    val server = profile?.server?.takeIf { it.isNotBlank() } ?: return null
    val parsed = parseHostAndPort(server, 853) ?: return null
    val hostname = profile.dotHostname.takeIf { it.isNotBlank() } ?: parsed.address.hostAddress ?: return null

    repeat(max(profile.retryCount, 1)) {
        try {
            val startedAt = System.nanoTime()
            val factory = SSLSocketFactory.getDefault() as SSLSocketFactory
            Socket().use { rawSocket ->
                rawSocketProtector?.invoke(rawSocket)
                rawSocket.connect(InetSocketAddress(parsed.address, parsed.port), max(profile.timeoutMs, 250))
                val sslSocket = factory.createSocket(rawSocket, hostname, parsed.port, true) as SSLSocket
                sslSocket.use { socket ->
                    socket.soTimeout = max(profile.timeoutMs, 250)
                    socket.startHandshake()

                    DataOutputStream(socket.outputStream).use { output ->
                        output.writeShort(queryBytes.size)
                        output.write(queryBytes)
                        output.flush()
                    }

                    val responseBytes = DataInputStream(socket.inputStream).use { input ->
                        val responseLength = input.readUnsignedShort()
                        val bytes = ByteArray(responseLength)
                        input.readFully(bytes)
                        bytes
                    }
                    val elapsedMs = ((System.nanoTime() - startedAt) / 1_000_000L).toInt()
                    return DnsForwardResult(
                        responseBytes = responseBytes,
                        latencyMs = elapsedMs,
                        transport = "DoT",
                        upstreamLabel = "$hostname:${parsed.port}",
                    )
                }
            }
        } catch (error: Exception) {
            Log.w(TAG_FORWARD, "DoT query failed for $server", error)
        }
    }

    return null
}

private fun parseHostAndPort(value: String, defaultPort: Int = 53): UpstreamDnsServer? {
    val normalizedValue = value.trim()
    if (normalizedValue.isBlank()) {
        return null
    }

    return try {
        if (normalizedValue.contains("://")) {
            val uri = URI(normalizedValue)
            val host = uri.host ?: return null
            val port = if (uri.port > 0) uri.port else defaultPort
            UpstreamDnsServer(InetAddress.getByName(host), port)
        } else if (normalizedValue.startsWith("[")) {
            val closingBracketIndex = normalizedValue.indexOf(']')
            if (closingBracketIndex <= 1) {
                return null
            }
            val host = normalizedValue.substring(1, closingBracketIndex)
            val port = if (closingBracketIndex + 1 < normalizedValue.length && normalizedValue[closingBracketIndex + 1] == ':') {
                normalizedValue.substring(closingBracketIndex + 2).toIntOrNull() ?: defaultPort
            } else {
                defaultPort
            }
            UpstreamDnsServer(InetAddress.getByName(host), port)
        } else if (normalizedValue.count { it == ':' } == 1) {
            val parts = normalizedValue.split(':', limit = 2)
            UpstreamDnsServer(InetAddress.getByName(parts[0]), parts[1].toIntOrNull() ?: defaultPort)
        } else {
            UpstreamDnsServer(InetAddress.getByName(normalizedValue), defaultPort)
        }
    } catch (_: Exception) {
        null
    }
}

private fun isDnsBridgeAddress(address: InetAddress): Boolean {
    return when (address.address.size) {
        4 -> address.hostAddress == DNS_BRIDGE_IPV4_ADDRESS.hostAddress
        16 -> address.hostAddress == DNS_BRIDGE_IPV6_ADDRESS.hostAddress
        else -> false
    }
}

private fun normalizeDomain(domain: String): String {
    val normalized = domain.trim().trimEnd('.').lowercase()
    if (normalized.isEmpty()) {
        return normalized
    }

    return try {
        IDN.toASCII(normalized, IDN.USE_STD3_ASCII_RULES).lowercase()
    } catch (_: Exception) {
        normalized
    }
}

private fun extractDnsResponseMinTtlSeconds(payload: ByteArray): Int? {
    if (payload.size < 12) {
        return null
    }

    val questionCount = readUnsignedShort(payload, 4)
    val answerCount = readUnsignedShort(payload, 6)
    if (answerCount == 0) {
        return null
    }

    var offset = 12
    repeat(questionCount) {
        offset = skipDnsName(payload, offset) ?: return null
        if (offset + 4 > payload.size) {
            return null
        }
        offset += 4
    }

    var minTtl = Int.MAX_VALUE
    repeat(answerCount) {
        offset = skipDnsName(payload, offset) ?: return null
        if (offset + 10 > payload.size) {
            return null
        }

        offset += 4
        val ttl = ((payload[offset].toInt() and 0xFF) shl 24) or
            ((payload[offset + 1].toInt() and 0xFF) shl 16) or
            ((payload[offset + 2].toInt() and 0xFF) shl 8) or
            (payload[offset + 3].toInt() and 0xFF)
        minTtl = min(minTtl, ttl)
        offset += 4

        val dataLength = readUnsignedShort(payload, offset)
        offset += 2
        if (offset + dataLength > payload.size) {
            return null
        }
        offset += dataLength
    }

    return if (minTtl == Int.MAX_VALUE) null else minTtl.coerceAtLeast(1)
}

private const val DEFAULT_CACHE_TTL_SECONDS = 60

private data class DnsCacheKey(
    val questionName: String,
    val questionType: DnsRecordType,
)

private data class DnsCacheEntry(
    val responseBytes: ByteArray,
    val expiresAtMillis: Long,
)

private class DnsResponseCache {
    private val lock = Any()
    private val entries = mutableMapOf<DnsCacheKey, DnsCacheEntry>()

    fun get(key: DnsCacheKey, transactionId: Short): ByteArray? {
        val now = System.currentTimeMillis()
        synchronized(lock) {
            val entry = entries[key] ?: return null
            if (entry.expiresAtMillis <= now) {
                entries.remove(key)
                return null
            }

            return entry.responseBytes.copyWithTransactionId(transactionId)
        }
    }

    fun put(key: DnsCacheKey, responseBytes: ByteArray, ttlSeconds: Int) {
        if (ttlSeconds <= 0) {
            return
        }

        synchronized(lock) {
            entries[key] = DnsCacheEntry(
                responseBytes = responseBytes.copyOf(),
                expiresAtMillis = System.currentTimeMillis() + (ttlSeconds * 1000L),
            )
        }
    }

    fun clear() {
        synchronized(lock) {
            entries.clear()
        }
    }
}

private fun ByteArray.copyWithTransactionId(transactionId: Short): ByteArray {
    val copy = copyOf()
    copy[0] = ((transactionId.toInt() shr 8) and 0xFF).toByte()
    copy[1] = (transactionId.toInt() and 0xFF).toByte()
    return copy
}

private fun extractDnsAnswerIps(payload: ByteArray): List<String> {
    if (payload.size < 12) {
        return emptyList()
    }

    val questionCount = readUnsignedShort(payload, 4)
    val answerCount = readUnsignedShort(payload, 6)
    var offset = 12

    for (questionIndex in 0 until questionCount) {
        offset = skipDnsName(payload, offset) ?: return emptyList()
        if (offset + 4 > payload.size) {
            return emptyList()
        }
        offset += 4
    }

    val result = mutableListOf<String>()
    for (answerIndex in 0 until answerCount) {
        offset = skipDnsName(payload, offset) ?: return result
        if (offset + 10 > payload.size) {
            return result
        }

        val type = readUnsignedShort(payload, offset)
        offset += 2
        offset += 2
        offset += 4
        val dataLength = readUnsignedShort(payload, offset)
        offset += 2
        if (offset + dataLength > payload.size) {
            return result
        }

        if ((type == 1 && dataLength == 4) || (type == 28 && dataLength == 16)) {
            try {
                val resolvedAddress = InetAddress.getByAddress(payload.copyOfRange(offset, offset + dataLength))
                resolvedAddress.hostAddress?.let(result::add)
            } catch (_: Exception) {
            }
        }
        offset += dataLength
    }

    return result
}

private fun skipDnsName(buffer: ByteArray, startOffset: Int): Int? {
    var offset = startOffset
    var guard = 0
    while (offset < buffer.size && guard < buffer.size) {
        val length = buffer[offset].toInt() and 0xFF
        if (length == 0) {
            return offset + 1
        }
        if ((length and 0xC0) == 0xC0) {
            return if (offset + 1 < buffer.size) offset + 2 else null
        }
        offset += 1 + length
        if (offset > buffer.size) {
            return null
        }
        guard += 1
    }
    return null
}

private fun buildDnsQuery(domain: String, recordType: DnsRecordType): ByteArray {
    val packet = ByteBuffer.allocate(512).order(ByteOrder.BIG_ENDIAN)
    packet.putShort((System.nanoTime() and 0xFFFF).toShort())
    packet.putShort(0x0100.toShort())
    packet.putShort(1.toShort())
    packet.putShort(0.toShort())
    packet.putShort(0.toShort())
    packet.putShort(0.toShort())
    for (label in domain.split('.')) {
        val bytes = label.toByteArray(Charsets.UTF_8)
        packet.put(bytes.size.toByte())
        packet.put(bytes)
    }
    packet.put(0)
    packet.putShort(recordType.code.toShort())
    packet.putShort(1.toShort())
    return packet.array().copyOf(packet.position())
}

private fun readUnsignedShort(buffer: ByteArray, offset: Int): Int {
    return ((buffer[offset].toInt() and 0xFF) shl 8) or (buffer[offset + 1].toInt() and 0xFF)
}

private val DNS_BRIDGE_IPV4_ADDRESS: InetAddress by lazy(LazyThreadSafetyMode.NONE) {
    InetAddress.getByName(VhostsVpnService.DNS_BRIDGE_IPV4)
}

private val DNS_BRIDGE_IPV6_ADDRESS: InetAddress by lazy(LazyThreadSafetyMode.NONE) {
    InetAddress.getByName(VhostsVpnService.DNS_BRIDGE_IPV6)
}

private val DNS_BRIDGE_FALLBACK_V4_PRIMARY: InetAddress by lazy(LazyThreadSafetyMode.NONE) {
    InetAddress.getByName("1.1.1.1")
}

private val DNS_BRIDGE_FALLBACK_V4_SECONDARY: InetAddress by lazy(LazyThreadSafetyMode.NONE) {
    InetAddress.getByName("8.8.8.8")
}

private val DNS_BRIDGE_FALLBACK_V6_PRIMARY: InetAddress by lazy(LazyThreadSafetyMode.NONE) {
    InetAddress.getByName("2606:4700:4700::1111")
}

private val DNS_BRIDGE_FALLBACK_V6_SECONDARY: InetAddress by lazy(LazyThreadSafetyMode.NONE) {
    InetAddress.getByName("2001:4860:4860::8888")
}

private const val DEFAULT_TIMEOUT_MS = 2000
private const val TAG_FORWARD = "VhostsDnsForward"
