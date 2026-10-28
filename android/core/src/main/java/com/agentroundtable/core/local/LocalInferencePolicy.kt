package com.agentroundtable.core.local

/** 设备侧可用于端侧推理的内存信息，由 `:app` 采集。 */
data class LocalDeviceCapability(
    val is64Bit: Boolean,
    val availableMemoryBytes: Long,
    val lowMemory: Boolean,
)

sealed interface LocalAvailability {
    data object Available : LocalAvailability

    data class Disabled(val reason: String) : LocalAvailability
}

/**
 * 端侧推理可用性策略。
 *
 * 原生推理不占用 Java 堆，但仍需要模型文件之外的 KV cache 与计算缓冲。这里用
 * [WORKING_SET_OVERHEAD_BYTES] 留出保守余量；内存不足时入口必须明确禁用。
 */
object LocalInferencePolicy {
    const val WORKING_SET_OVERHEAD_BYTES: Long = 384L * 1024 * 1024

    fun requiredMemoryBytes(model: LocalModel): Long =
        model.sizeBytes + WORKING_SET_OVERHEAD_BYTES

    fun availability(model: LocalModel, device: LocalDeviceCapability): LocalAvailability {
        if (!device.is64Bit) {
            return LocalAvailability.Disabled("端侧推理仅支持 64 位设备。")
        }
        if (device.lowMemory) {
            return LocalAvailability.Disabled("设备当前处于低内存状态，端侧推理暂不可用。")
        }
        val required = requiredMemoryBytes(model)
        if (device.availableMemoryBytes < required) {
            return LocalAvailability.Disabled(
                "可用内存不足：需要约 ${formatMiB(required)}，当前可用 " +
                    "${formatMiB(device.availableMemoryBytes)}。",
            )
        }
        return LocalAvailability.Available
    }

    fun formatMiB(bytes: Long): String {
        val mib = bytes / (1024.0 * 1024.0)
        return if (mib >= 1024) {
            String.format("%.2f GB", mib / 1024.0)
        } else {
            String.format("%.0f MB", mib)
        }
    }
}
