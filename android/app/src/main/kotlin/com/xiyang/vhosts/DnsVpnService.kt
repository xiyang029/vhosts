package com.xiyang.vhosts

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.util.Log
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.InetAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.json.JSONArray
import org.json.JSONObject

class DnsVpnService : VpnService() {
    private var vpnInterface: android.os.ParcelFileDescriptor? = null
    private var worker: Thread? = null
    private var stopping = false

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopVpn()
            return START_NOT_STICKY
        }
        if (intent?.action == ACTION_START) {
            stopTunnelOnly()
            startForeground(NOTIFICATION_ID, createNotification())
            broadcast(STATUS_STARTING)
            startTunnel(intent)
        }
        return START_STICKY
    }

    private fun startTunnel(intent: Intent) {
        val profile = try {
            DnsProfileConfig.fromJson(JSONObject(intent.getStringExtra(EXTRA_PROFILE).orEmpty()))
        } catch (error: Exception) {
            Log.e(TAG, "Invalid DNS profile", error)
            broadcast(STATUS_ERROR)
            stopSelf()
            return
        }
        val rules = try {
            val array = JSONArray(intent.getStringExtra(EXTRA_RULES).orEmpty())
            buildList {
                for (index in 0 until array.length()) {
                    add(HostRuleConfig.fromJson(array.getJSONObject(index)))
                }
            }
        } catch (error: Exception) {
            Log.e(TAG, "Invalid hosts rules", error)
            emptyList()
        }

        stopping = false
        worker = Thread {
            try {
                val network = getSystemService(android.net.ConnectivityManager::class.java).activeNetwork
                val transport = DnsTransport(
                    profile = profile,
                    hostRules = rules,
                    network = network,
                    protect = { protect(it) },
                    protectTcp = { protect(it) },
                )
                vpnInterface = Builder()
                    .setSession("vhosts DNS")
                    .setMtu(1500)
                    .addAddress(VPN_ADDRESS, 32)
                    .addAddress(VPN_IPV6_ADDRESS, 128)
                    .addDnsServer(DNS_ADDRESS)
                    .addDnsServer(DNS_IPV6_ADDRESS)
                    .addRoute(DNS_ADDRESS, 32)
                    .addRoute(DNS_IPV6_ADDRESS, 128)
                    .establish()
                if (vpnInterface == null) throw IllegalStateException("无法建立 VPN 接口")
                broadcast(STATUS_STARTED)
                tunnelLoop(transport)
            } catch (error: Exception) {
                if (!stopping) {
                    Log.e(TAG, "DNS VPN stopped unexpectedly", error)
                    broadcast(STATUS_ERROR)
                }
            } finally {
                closeInterface()
                if (!stopping) broadcast(STATUS_STOPPED)
            }
        }.also { it.start() }
    }

    private fun tunnelLoop(transport: DnsTransport) {
        val descriptor = vpnInterface ?: return
        FileInputStream(descriptor.fileDescriptor).use { input ->
            FileOutputStream(descriptor.fileDescriptor).use { output ->
                val packet = ByteArray(32767)
                while (!stopping) {
                    val length = input.read(packet)
                    if (length > 0) {
                        val response = handlePacket(packet, length, transport)
                        if (response != null) output.write(response)
                    }
                }
            }
        }
    }

    private fun handlePacket(packet: ByteArray, length: Int, transport: DnsTransport): ByteArray? {
        if (length < 1) return null
        return when (packet[0].toInt() ushr 4) {
            4 -> handleIpv4Packet(packet, length, transport)
            6 -> handleIpv6Packet(packet, length, transport)
            else -> null
        }
    }

    private fun handleIpv4Packet(packet: ByteArray, length: Int, transport: DnsTransport): ByteArray? {
        if (length < 28 || packet[9].toInt() and 0xff != 17) return null
        val ihl = (packet[0].toInt() and 0x0f) * 4
        if (length < ihl + 8) return null
        val destination = packet.copyOfRange(16, 20)
        if (!destination.contentEquals(InetAddress.getByName(DNS_ADDRESS).address)) return null
        val source = packet.copyOfRange(12, 16)
        val sourcePort = u16(packet, ihl)
        val destinationPort = u16(packet, ihl + 2)
        if (destinationPort != 53) return null
        val dnsStart = ihl + 8
        val dnsQuery = packet.copyOfRange(dnsStart, length)
        val dnsResponse = try {
            transport.resolve(dnsQuery)
        } catch (error: Exception) {
            Log.w(TAG, "DNS upstream request failed", error)
            DnsPacket.servfail(dnsQuery)
        }
        return buildUdpResponse(
            source = destination,
            destination = source,
            sourcePort = 53,
            destinationPort = sourcePort,
            payload = dnsResponse,
        )
    }

    private fun handleIpv6Packet(packet: ByteArray, length: Int, transport: DnsTransport): ByteArray? {
        if (length < 48 || packet[6].toInt() and 0xff != 17) return null
        val destination = packet.copyOfRange(24, 40)
        if (!destination.contentEquals(InetAddress.getByName(DNS_IPV6_ADDRESS).address)) return null
        val source = packet.copyOfRange(8, 24)
        val sourcePort = u16(packet, 40)
        val destinationPort = u16(packet, 42)
        if (destinationPort != 53) return null
        val dnsQuery = packet.copyOfRange(48, length)
        val dnsResponse = try {
            transport.resolve(dnsQuery)
        } catch (error: Exception) {
            Log.w(TAG, "IPv6 DNS upstream request failed", error)
            DnsPacket.servfail(dnsQuery)
        }
        return buildIpv6UdpResponse(
            source = destination,
            destination = source,
            sourcePort = 53,
            destinationPort = sourcePort,
            payload = dnsResponse,
        )
    }

    private fun buildUdpResponse(
        source: ByteArray,
        destination: ByteArray,
        sourcePort: Int,
        destinationPort: Int,
        payload: ByteArray,
    ): ByteArray {
        val totalLength = 20 + 8 + payload.size
        val packet = ByteBuffer.allocate(totalLength).order(ByteOrder.BIG_ENDIAN)
        packet.put(0x45)
        packet.put(0)
        packet.putShort(totalLength.toShort())
        packet.putShort(0)
        packet.putShort(0)
        packet.put(64)
        packet.put(17)
        packet.putShort(0)
        packet.put(source)
        packet.put(destination)
        packet.putShort(sourcePort.toShort())
        packet.putShort(destinationPort.toShort())
        packet.putShort((8 + payload.size).toShort())
        packet.putShort(0)
        packet.put(payload)
        val result = packet.array()
        putU16(result, 10, checksum(result, 0, 20))
        putU16(result, 26, udpChecksum(result, 20, payload.size + 8))
        return result
    }

    private fun udpChecksum(packet: ByteArray, udpOffset: Int, udpLength: Int): Int {
        var sum = 0L
        for (index in 12 until 20 step 2) sum += u16(packet, index).toLong()
        sum += 17
        sum += udpLength
        for (index in udpOffset until udpOffset + udpLength step 2) {
            sum += if (index + 1 < packet.size) u16(packet, index) else (packet[index].toInt() and 0xff) shl 8
        }
        return foldChecksum(sum)
    }

    private fun buildIpv6UdpResponse(
        source: ByteArray,
        destination: ByteArray,
        sourcePort: Int,
        destinationPort: Int,
        payload: ByteArray,
    ): ByteArray {
        val udpLength = 8 + payload.size
        val packet = ByteBuffer.allocate(40 + udpLength).order(ByteOrder.BIG_ENDIAN)
        packet.putInt(0x60000000)
        packet.putShort(udpLength.toShort())
        packet.put(17)
        packet.put(64)
        packet.put(source)
        packet.put(destination)
        packet.putShort(sourcePort.toShort())
        packet.putShort(destinationPort.toShort())
        packet.putShort(udpLength.toShort())
        packet.putShort(0)
        packet.put(payload)
        val result = packet.array()
        putU16(result, 46, ipv6UdpChecksum(result, udpLength))
        return result
    }

    private fun ipv6UdpChecksum(packet: ByteArray, udpLength: Int): Int {
        var sum = 0L
        for (index in 8 until 40 step 2) sum += u16(packet, index).toLong()
        sum += (udpLength ushr 16).toLong()
        sum += (udpLength and 0xffff).toLong()
        sum += 17
        for (index in 40 until 40 + udpLength step 2) {
            sum += if (index + 1 < packet.size) u16(packet, index) else {
                (packet[index].toInt() and 0xff) shl 8
            }
        }
        return foldChecksum(sum)
    }

    private fun checksum(packet: ByteArray, offset: Int, length: Int): Int {
        var sum = 0L
        for (index in offset until offset + length step 2) sum += u16(packet, index).toLong()
        return foldChecksum(sum)
    }

    private fun foldChecksum(value: Long): Int {
        var sum = value
        while (sum ushr 16 != 0L) sum = (sum and 0xffff) + (sum ushr 16)
        return sum.inv().toInt() and 0xffff
    }

    private fun u16(data: ByteArray, offset: Int): Int =
        ((data[offset].toInt() and 0xff) shl 8) or (data[offset + 1].toInt() and 0xff)

    private fun putU16(data: ByteArray, offset: Int, value: Int) {
        data[offset] = (value ushr 8).toByte()
        data[offset + 1] = value.toByte()
    }

    private fun stopVpn() {
        stopping = true
        broadcast(STATUS_STOPPING)
        stopTunnelOnly()
        stopForeground(STOP_FOREGROUND_REMOVE)
        broadcast(STATUS_STOPPED)
        stopSelf()
    }

    private fun stopTunnelOnly() {
        stopping = true
        try {
            vpnInterface?.close()
        } catch (_: Exception) {
        }
        vpnInterface = null
        worker?.interrupt()
        worker = null
    }

    private fun closeInterface() {
        try {
            vpnInterface?.close()
        } catch (_: Exception) {
        }
        vpnInterface = null
    }

    private fun createNotification(): Notification {
        val channelId = "vhosts_dns"
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(channelId, "vhosts DNS", NotificationManager.IMPORTANCE_LOW),
            )
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, channelId)
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .setContentTitle("vhosts DNS")
            .setContentText("自定义 DNS 正在运行")
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }

    private fun broadcast(status: String) {
        sendBroadcast(Intent(ACTION_STATUS).setPackage(packageName).putExtra(EXTRA_STATUS, status))
    }

    override fun onDestroy() {
        stopTunnelOnly()
        super.onDestroy()
    }

    companion object {
        const val ACTION_START = "com.xiyang.vhosts.action.START_DNS_VPN"
        const val ACTION_STOP = "com.xiyang.vhosts.action.STOP_DNS_VPN"
        const val ACTION_STATUS = "com.xiyang.vhosts.action.DNS_VPN_STATUS"
        const val EXTRA_PROFILE = "profileJson"
        const val EXTRA_RULES = "hostRulesJson"
        const val EXTRA_STATUS = "status"
        const val STATUS_STARTING = "starting"
        const val STATUS_STARTED = "started"
        const val STATUS_STOPPING = "stopping"
        const val STATUS_STOPPED = "stopped"
        const val STATUS_ERROR = "error"
        private const val TAG = "DnsVpnService"
        private const val NOTIFICATION_ID = 1001
        private const val VPN_ADDRESS = "10.0.0.2"
        private const val DNS_ADDRESS = "10.0.0.1"
        private const val VPN_IPV6_ADDRESS = "fd00:7654:6e73::2"
        private const val DNS_IPV6_ADDRESS = "fd00:7654:6e73::1"
    }
}
