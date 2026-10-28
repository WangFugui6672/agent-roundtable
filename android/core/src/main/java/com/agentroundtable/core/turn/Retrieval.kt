package com.agentroundtable.core.turn

import com.agentroundtable.core.knowledge.RetrievalHit

/**
 * 一次资料库检索的接缝。
 *
 * [TurnRunner] 只依赖这个接口，不直接依赖嵌入实现；未注入时完全不检索。
 * 返回空列表表示没有可用参考资料，属于正常结果。
 */
fun interface Retrieval {
    suspend fun retrieve(query: String): List<RetrievalHit>
}
