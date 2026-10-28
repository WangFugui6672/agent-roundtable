package com.agentroundtable.app.local

import android.app.ActivityManager
import android.content.Context
import android.os.Debug
import android.os.Process
import com.agentroundtable.core.local.LocalDeviceCapability
import java.io.File

/** 采集设备可用内存与进程峰值内存。 */
interface DeviceMemoryProbe {
    fun capability(): LocalDeviceCapability

    /** 进程峰值 RSS；读取失败时回退到 Android 的 PSS 统计。 */
    fun peakMemoryBytes(): Long
}

class AndroidDeviceMemoryProbe(context: Context) : DeviceMemoryProbe {
    private val activityManager =
        context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager

    override fun capability(): LocalDeviceCapability {
        val info = ActivityManager.MemoryInfo()
        activityManager.getMemoryInfo(info)
        return LocalDeviceCapability(
            is64Bit = Process.is64Bit(),
            availableMemoryBytes = info.availMem,
            lowMemory = info.lowMemory,
        )
    }

    override fun peakMemoryBytes(): Long {
        val vmHwm = readVmHwmBytes()
        if (vmHwm > 0) return vmHwm
        val info = Debug.MemoryInfo()
        Debug.getMemoryInfo(info)
        return info.totalPss.toLong() * 1024
    }

    private fun readVmHwmBytes(): Long {
        val status = File("/proc/self/status")
        if (!status.isFile) return 0
        return runCatching {
            status.useLines { lines ->
                val line = lines.firstOrNull { it.startsWith("VmHWM:") } ?: return@useLines 0L
                val kb = line.substringAfter("VmHWM:").trim().substringBefore(" ").toLongOrNull() ?: 0L
                kb * 1024
            }
        }.getOrDefault(0L)
    }
}
