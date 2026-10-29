package com.agentroundtable.core

import com.agentroundtable.core.model.RoundtableCard

/**
 * 首页需要渲染的纯数据状态。
 *
 * 状态在 `:core` 中计算，`:app` 只负责渲染，因此首页的每种状态都可以在
 * JVM 单元测试中验证，不需要模拟器。
 */
sealed interface HomeState {
    /** 首次加载中。 */
    data object Loading : HomeState

    /** 本机还没有任何圆桌。 */
    data object Empty : HomeState

    /** 本机已有圆桌，按最近活动倒序。 */
    data class Rooms(val items: List<RoundtableCard>) : HomeState

    /** 加载失败，[message] 可直接展示。 */
    data class Failed(val message: String) : HomeState
}
