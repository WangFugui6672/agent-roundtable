package com.agentroundtable.core

/**
 * 首页需要渲染的纯数据状态。
 *
 * 状态在 `:core` 中计算，`:app` 只负责渲染，因此首页的空态与有内容态
 * 都可以在 JVM 单元测试中验证，不需要模拟器。
 */
sealed interface HomeState {
    /** 本机还没有任何圆桌。 */
    data object Empty : HomeState
}
