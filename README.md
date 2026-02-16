# Kimi Hooks

Zero-polling task dispatch for [Kimi CLI](https://www.moonshot.cn/), inspired by [Claude Code Hooks](https://github.com/win4r/claude-code-hooks).

English | [中文](#中文说明)

## Overview

Kimi Hooks enables **zero-polling automation** for Kimi CLI tasks:

- Dispatch once → Kimi runs in background → Auto-notify on completion
- Dual-channel notification: Wake Event + File persistence
- Graceful signal handling (SIGTERM/SIGINT)
- Deduplication mechanism (30-second lock)

Built for [OpenClaw](https://openclaw.ai/) integration.

## Quick Start

```bash
# Install dependencies
pip install pexpect
# macOS: brew install jq
# Ubuntu: apt-get install jq

# Configure environment
export OPENCLAW_GATEWAY_URL="http://127.0.0.1:18789"
export OPENCLAW_GATEWAY_TOKEN="your-token"

# Run task
./dispatch-kimi.sh \
  -p "Write a Python web scraper" \
  -n "scraper-task" \
  -w "/path/to/project"
```

## Features

| Feature | Description |
|---------|-------------|
| Zero-polling | No busy-waiting, token-efficient |
| Dual-channel | Wake Event + pending-wake.json fallback |
| Deduplication | 30-second lock prevents duplicate notifications |
| Signal handling | Graceful shutdown on interrupt |
| Telegram notify | Optional group notifications |

## Architecture

```
dispatch-kimi.sh
    │
    ├─ Write task-meta.json
    ├─ Start Kimi CLI (via kimi-run.py)
    │
    └─ Kimi completes → notify-agi.sh
        │
        ├─ Write latest.json
        ├─ Send Wake Event → OpenClaw Gateway
        ├─ Write pending-wake.json (fallback)
        └─ Send Telegram notification (optional)
```

## Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-p, --prompt` | ✅ | Task prompt |
| `-n, --name` | ✅ | Task name for tracking |
| `-g, --group` | ❌ | Telegram group ID |
| `-w, --workdir` | ❌ | Working directory |
| `-t, --timeout` | ❌ | Timeout in seconds (default: 3600) |
| `--background` | ❌ | Run in background (nohup) |
| `--allowed-tools` | ❌ | Allowed tool list |

## Integration with OpenClaw

### Keyword Trigger

Configure your OpenClaw agent to detect `@Kimi ` prefix:

```
User: @Kimi Write a Python function
       ↓
OpenClaw detects @Kimi prefix
       ↓
Call dispatch-kimi.sh
       ↓
Kimi CLI runs in background
       ↓
Wake Event notifies OpenClaw
       ↓
OpenClaw replies with result
```

## Acknowledgements

This project is made possible by:

- **[Claude Code Hooks](https://github.com/win4r/claude-code-hooks)** — The original zero-polling architecture that inspired this project
- **[OpenClaw](https://openclaw.ai/)** — The AGI framework that enables seamless agent integration
- **[Kimi](https://www.moonshot.cn/)** — The AI assistant that powers the task execution

Special thanks to the open-source community for making AI automation accessible.

## License

MIT

---

## 中文说明

Kimi Hooks 是一个对标 [Claude Code Hooks](https://github.com/win4r/claude-code-hooks) 的 **Kimi CLI 零轮询任务调度方案**。

### 核心特性

- **零轮询设计** — OpenClaw 只需 dispatch 一次，Kimi 后台运行
- **双通道通知** — Wake Event 实时通知 + pending-wake.json 备选
- **防重复机制** — 30秒锁防止重复触发
- **信号处理** — SIGTERM/SIGINT 优雅退出

### 致谢

本项目感谢以下项目的支持：

- **[Claude Code Hooks](https://github.com/win4r/claude-code-hooks)** — 零轮询架构的灵感来源
- **[OpenClaw](https://openclaw.ai/)** — 提供 AGI 框架支持
- **[Kimi](https://www.moonshot.cn/)** — 提供 AI 任务执行能力
