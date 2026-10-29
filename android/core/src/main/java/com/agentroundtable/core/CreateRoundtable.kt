package com.agentroundtable.core

/** 创建圆桌时的校验结果。 */
sealed interface CreateValidation {
    data object Valid : CreateValidation

    data class Invalid(val message: String) : CreateValidation
}

/**
 * 创建圆桌的本地校验，与服务端的规则保持一致。
 *
 * 放在 `:core` 是为了让「议题长度」「恰好三位参与者」这类规则可以在纯 JVM 上测试，
 * 而不是散落在界面的输入框回调里。
 */
object CreateRoundtableRules {
    const val TOPIC_MIN_CHARS = 1
    const val TOPIC_MAX_CHARS = 500
    const val REQUIRED_AGENTS = 3

    fun validateTopic(topic: String): CreateValidation {
        val trimmed = topic.trim()
        return when {
            trimmed.length < TOPIC_MIN_CHARS -> CreateValidation.Invalid("请先填写议题。")
            trimmed.length > TOPIC_MAX_CHARS ->
                CreateValidation.Invalid("议题不能超过 $TOPIC_MAX_CHARS 个字符。")
            else -> CreateValidation.Valid
        }
    }

    fun validateSelection(selectedIds: List<String>): CreateValidation = when {
        selectedIds.size < REQUIRED_AGENTS ->
            CreateValidation.Invalid("请选择 $REQUIRED_AGENTS 位 Agent。")
        selectedIds.size > REQUIRED_AGENTS ->
            CreateValidation.Invalid("最多只能选择 $REQUIRED_AGENTS 位 Agent。")
        selectedIds.distinct().size != selectedIds.size ->
            CreateValidation.Invalid("不能重复选择同一位 Agent。")
        else -> CreateValidation.Valid
    }
}
