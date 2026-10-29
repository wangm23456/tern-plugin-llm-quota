# Tern LLM Quota Plugin

Tern terminal panel for tracking LLM token consumption and provider plan rate limits (Claude, Codex, OpenAI, DeepSeek, etc.).

## Features

- **Token Consumption**: Reads local `stats.db` to show session/daily token usage and costs.
- **Provider Quota & Rate Limits**: Displays 5h / 7d / monthly sliding-window limits for connected providers.
- **Live Refresh**: One-click refresh or auto-polling.

## Prerequisites

- [Tern Terminal](https://stencil.so/tern)
- Local `omp` CLI with usage / stats DB configured.

## Installation

```bash
mkdir -p ~/.config/tern/plugins
git clone https://github.com/wangm23456/tern-plugin-llm-quota.git ~/.config/tern/plugins/llm-quota
```

Open via Tern command palette: `LLM 用量与额度监控`.
