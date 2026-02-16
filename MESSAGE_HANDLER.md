# Kimi CLI 消息处理器
# 规则：只有以 @Kimi 开头的消息才触发 Kimi Code 执行

## 触发规则

| 前缀 | 行为 | 示例 |
|------|------|------|
| `@Kimi ` | 触发 Kimi CLI 执行任务 | `@Kimi 写一个Python爬虫` |
| 其他消息 | 正常对话处理 | `你好` → 我直接回复 |

## 处理流程

```
用户发送: @Kimi 写一个Python计算斐波那契数列的函数

1. 检测前缀: 以 "@Kimi " 开头 ✅
2. 提取任务: "写一个Python计算斐波那契数列的函数"
3. 调用 dispatch-kimi.sh 派发任务
4. Kimi CLI 后台执行
5. 完成后通过 Wake Event 通知我
6. 我收到通知，读取 latest.json
7. 回复用户结果
```

## 配置要求

环境变量:
```bash
export KIMI_HOOKS_DIR="/root/.openclaw/workspace/kimi-hooks"
export OPENCLAW_GATEWAY_URL="http://127.0.0.1:18789"
export OPENCLAW_GATEWAY_TOKEN="b0308a6fc3eac38432f60f762bf554f57e4af1caceb40047"
```

## 使用示例

### 触发 Kimi Code
```
@Kimi 分析这个目录的代码结构
@Kimi 生成一份周报模板
@Kimi 写一个Dockerfile部署Python应用
```

### 普通对话（不触发）
```
你好
今天天气怎么样
帮我查一下资料
```

## Wake Event 处理

当 Kimi 任务完成时，OpenClaw Gateway 会发送 wake event。

Wake Event 格式:
```json
{
    "type": "kimi-task-complete",
    "payload": {
        "session_id": "kimi-20260216_xxxxxx",
        "task_name": "fibonacci",
        "status": "done",
        "timestamp": "2026-02-16T16:00:00+00:00"
    }
}
```

收到 wake event 后:
1. 读取 `kimi-hooks/latest.json`
2. 提取任务结果
3. 回复给用户

## 注意事项

1. **必须加空格**: `@Kimi任务` ❌ `@Kimi 任务` ✅
2. **任务超时**: 默认 1 小时，超时自动终止
3. **结果保留**: 最新结果在 `latest.json`，历史在 `runs/` 目录
4. **容错设计**: Kimi 执行失败也会通知，不会无限等待
