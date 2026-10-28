package com.agentroundtable.core

import com.agentroundtable.core.api.ApiClient
import com.agentroundtable.core.api.ApiResult
import com.agentroundtable.core.model.RoundtableCard
import com.agentroundtable.core.model.RoundtableStatus
import com.agentroundtable.core.session.GuestSessionStore

/**
 * 首页数据来源：保证匿名会话存在，并读取本机圆桌列表。
 */
class HomeRepository(
    private val api: ApiClient,
    private val sessions: GuestSessionStore,
) {
    /** 读取已有匿名会话；没有就创建一个并持久化。 */
    suspend fun ensureSession(): ApiResult<String> {
        sessions.read()?.let { return ApiResult.Success(it) }

        return when (val result = api.createGuestSession()) {
            is ApiResult.Failure -> result
            is ApiResult.Success -> {
                sessions.write(result.value.id)
                ApiResult.Success(result.value.id)
            }
        }
    }

    /** 拉取首页状态。任何失败都折叠为可展示的 [HomeState.Failed]。 */
    suspend fun load(): HomeState {
        val sessionId = when (val session = ensureSession()) {
            is ApiResult.Failure -> return HomeState.Failed(session.message)
            is ApiResult.Success -> session.value
        }

        return when (val rooms = api.listRoundtables(sessionId)) {
            is ApiResult.Failure -> HomeState.Failed(rooms.message)
            is ApiResult.Success -> {
                if (rooms.value.isEmpty()) {
                    HomeState.Empty
                } else {
                    HomeState.Rooms(rooms.value.map { it.toCard() })
                }
            }
        }
    }
}

internal fun com.agentroundtable.core.model.Roundtable.toCard(): RoundtableCard =
    RoundtableCard(
        id = id,
        topic = topic,
        status = RoundtableStatus.fromWire(status),
    )
