--!strict
-- LLM 额度与用量看板宿主端：实时采集 omp usage 与 stats.db 统计数据

type WindowLimit = {
   id: string?,
   label: string,
   window_label: string,
   window_id: string?,
   used: number,
   limit: number,
   remaining: number,
   used_fraction: number,
   remaining_fraction: number,
   resets_at: number?,
   status: string?,
}

type ProviderReport = {
   provider: string,
   fetched_at: number?,
   email: string?,
   plan_type: string?,
   project_id: string?,
   account_id: string?,
   limits: { WindowLimit },
}

type ModelStat = {
   model: string,
   provider: string,
   requests: number,
   input_tokens: number,
   output_tokens: number,
   cache_read_tokens: number,
   total_tokens: number,
   cache_rate: number,
   cost: number,
   avg_tok_per_sec: number?,
}

type ProviderStat = {
   provider: string,
   total_tokens: number,
   input_tokens: number,
   output_tokens: number,
   cache_tokens: number,
   requests: number,
   cost: number,
   models: { ModelStat },
}

type FolderStat = {
   folder: string,
   requests: number,
   input_tokens: number,
   output_tokens: number,
   cache_read_tokens: number,
   total_tokens: number,
   cost: number,
}

type OverallStats = {
   total_requests: number,
   successful_requests: number,
   failed_requests: number,
   error_rate: number,
   total_input_tokens: number,
   total_output_tokens: number,
   total_cache_read_tokens: number,
   total_tokens: number,
   cache_rate: number,
   cache_savings: number,
   total_cost: number,
   avg_tok_per_sec: number,
   avg_ttft: number,
   avg_duration: number,
}

type TimeSeriesPoint = {
   label: string,
   tokens: number,
   requests: number,
   cost: number,
}

type TabMode = "overview" | "quota" | "models" | "folders"
type TimeRange = "midnight" | "24h" | "7d" | "30d" | "all"
type State = {
   tab: TabMode,
   time_range: TimeRange,
   loading: boolean,
   error: string?,
   last_updated: string?,
   overall: OverallStats?,
   providers: { ProviderReport },
   provider_stats: { [string]: ProviderStat },
   models: { ModelStat },
   folders: { FolderStat },
   time_series: { TimeSeriesPoint },
   auto_refresh: boolean,
   timer_active: boolean,
   show_help: boolean,
}

local ui = tern.ui

local function is_zh(): boolean
   local cfg_lang = tern.getenv("TERN_LANG") or tern.getenv("PLUGIN_LANG")
   if cfg_lang and #cfg_lang > 0 then
      return string.find(string.lower(cfg_lang), "zh") ~= nil
   end
   local home = tern.getenv("HOME") or ""
   if #home > 0 then
      local s_paths = {
         home .. "/Library/Application Support/Tern/settings.json",
         home .. "/.config/tern/settings.json",
      }
      for _, sp in s_paths do
         if tern.fs.exists(sp) then
            local ok, raw = pcall(function() return tern.fs.read(sp, 32768) end)
            if ok and raw and #raw > 0 then
               local pok, data = pcall(function() return tern.json.decode(raw) end)
               if pok and type(data) == "table" and type(data.language) == "string" then
                  return string.find(string.lower(data.language), "zh") ~= nil
               end
            end
         end
      end
   end
   local env_lang = (tern.getenv("LANG") or "") .. (tern.getenv("LC_ALL") or "") .. (tern.getenv("LC_MESSAGES") or "")
   if #env_lang > 0 and (string.find(string.lower(env_lang), "zh") ~= nil or string.find(string.lower(env_lang), "cn") ~= nil) then
      return true
   end
   if #home > 0 then
      local pref_path = home .. "/Library/Preferences/.GlobalPreferences.plist"
      if tern.fs.exists(pref_path) then
         local ok, bytes = pcall(function() return tern.fs.read(pref_path, 16384) end)
         if ok and bytes and (string.find(bytes, "zh-Hans") or string.find(bytes, "zh-Hant") or string.find(bytes, "zh_CN")) then
            return true
         end
      end
   end
   return false
end

local function t(zh: string, en: string): string
   return if is_zh() then zh else en
end

local function find_omp(): string
   local home = tern.getenv("HOME") or ""
   local cands = {
      home .. "/Library/Application Support/Tern/omp/bin/omp",
      home .. "/.local/bin/omp",
      "/opt/homebrew/bin/omp",
      "/usr/local/bin/omp",
      "omp",
   }
   for _, p in cands do
      if #p > 0 and (string.sub(p, 1, 1) ~= "/" or tern.fs.exists(p)) then
         return p
      end
   end
   return "omp"
end

local function get_env(): { [string]: string }
   local home = tern.getenv("HOME") or ""
   local path = tern.getenv("PATH") or ""
   return {
      PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" .. home .. "/.local/bin:" .. path,
      HOME = home,
   }
end

local function fmt_num(n: number?): string
   local v = n or 0
   if v >= 1000000000 then
      return string.format("%.2f B", v / 1000000000)
   elseif v >= 1000000 then
      return string.format("%.2f M", v / 1000000)
   elseif v >= 10000 then
      return string.format("%.1f k", v / 1000)
   elseif v >= 1000 then
      return string.format("%.1f k", v / 1000)
   else
      return tostring(math.floor(v))
   end
end

local function fmt_cost(cost: number?): string
   local v = cost or 0
   if v == 0 then
      return "$0.00"
   elseif v < 0.01 then
      return string.format("$%.4f", v)
   elseif v < 1 then
      return string.format("$%.3f", v)
   else
      return string.format("$%.2f", v)
   end
end

local function fmt_pct(pct: number?): string
   local v = (pct or 0) * 100
   return string.format("%.1f%%", v)
end

local function fmt_reset(resets_at: number?): string
   if not resets_at or resets_at == 0 then return t("无时间限制", "No limit") end
   local target_sec = if resets_at > 100000000000 then math.floor(resets_at / 1000) else resets_at
   local diff = target_sec - os.time()
   if diff <= 0 then return t("已重置", "Reset") end
   local d = math.floor(diff / 86400)
   local h = math.floor((diff % 86400) / 3600)
   local m = math.floor((diff % 3600) / 60)
   if d > 0 then
      return string.format(t("%d天%d小时后重置", "Resets in %dd %dh"), d, h)
   elseif h > 0 then
      return string.format(t("%d小时%02d分后重置", "Resets in %dh %02dm"), h, m)
   else
      return string.format(t("%d分钟后重置", "Resets in %dm"), math.max(1, m))
   end
end

local PROVIDER_META: { [string]: { name: string, tone: string } } = {
   ["google-antigravity"] = { name = "Google Antigravity (Gemini)", tone = "accent strong" },
   ["openai-codex"] = { name = "OpenAI Codex", tone = "success strong" },
   ["kimi-code"] = { name = "Kimi Code (Moonshot)", tone = "info" },
   ["xiaomi-token-plan-cn"] = { name = "小米 MiMo (Xiaomi Token Plan CN)", tone = "accent strong" },
   ["zhipu-coding-plan"] = { name = "智谱 AI (GLM Coding Plan)", tone = "accent strong" },
   ["xai-oauth"] = { name = "xAI Grok", tone = "warning" },
   ["minimax-code-cn"] = { name = "MiniMax (Coding Plan CN)", tone = "warning strong" },
   ["deepseek"] = { name = "DeepSeek 官方 API", tone = "info" },
   ["typesafe"] = { name = "TypeSafe System", tone = "muted" },
}

local function get_provider_info(p: string): (string, string)
   local meta = PROVIDER_META[p]
   if meta then return meta.name, meta.tone end
   return p, "default"
end

local function quota_tone(frac: number): string
   if frac >= 0.90 then return "error strong"
   elseif frac >= 0.70 then return "warning strong"
   elseif frac >= 0.40 then return "accent"
   else return "success" end
end

local function clean_folder_name(name: string): string
   local s = (string.gsub(name, "^%-", ""))
   s = (string.gsub(s, "^APP%-magic%-", ""))
   s = (string.gsub(s, "^APP%-", ""))
   s = (string.gsub(s, "%-", "/"))
   return s
end

local function get_range_where(range: TimeRange): string
   local now_sec = os.time()
   local now_ms = now_sec * 1000

   if range == "midnight" then
      local t = os.date("*t", now_sec)
      t.hour = 0
      t.min = 0
      t.sec = 0
      local midnight_ms = os.time(t) * 1000
      return "WHERE last_ts >= " .. string.format("%.0f", midnight_ms)
   elseif range == "24h" or (range :: string) == "today" then
      local min_ts = now_ms - 86400000
      return "WHERE last_ts >= " .. string.format("%.0f", min_ts)
   elseif range == "7d" then
      local min_ts = now_ms - (7 * 86400000)
      return "WHERE last_ts >= " .. string.format("%.0f", min_ts)
   elseif range == "30d" then
      local min_ts = now_ms - (30 * 86400000)
      return "WHERE last_ts >= " .. string.format("%.0f", min_ts)
   else
      return ""
   end
end

-- 合并 Token Plan 额度（MiMo / GLM / MiniMax 等）到 providers 列表中
local function merge_token_plans(provs: { ProviderReport }, stats_map: { [string]: ProviderStat })
   -- 1. 小米 MiMo Token Plan
   local mimo_stat = stats_map["xiaomi-token-plan-cn"]
   if mimo_stat then
      local lims: { WindowLimit } = {}
      for _, m in mimo_stat.models do
         local role_name = if m.model == "mimo-v2.6-pro" then "主力深思模型 (Default/Reviewer)"
            elseif m.model == "mimo-v2.6-flash" then "高频任务模型 (Task/Commit)"
            else "Token Plan 模型"
         table.insert(lims, {
            id = "mimo:" .. m.model,
            label = m.model .. " · " .. role_name,
            window_label = fmt_num(m.total_tokens) .. " Tokens · " .. tostring(m.requests) .. " 次请求",
            used = m.total_tokens,
            limit = m.total_tokens,
            remaining = 0,
            used_fraction = 1.0,
            remaining_fraction = 0,
            resets_at = nil,
            status = "active",
         })
      end
      table.insert(lims, {
         id = "mimo:total",
         label = "MiMo 累计总吞吐 (国内独享 Token Plan)",
         window_label = "国内 CN 节点 · 专属高速并发通道",
         used = mimo_stat.total_tokens,
         limit = mimo_stat.total_tokens,
         remaining = 0,
         used_fraction = 1.0,
         remaining_fraction = 0,
         resets_at = nil,
         status = "active",
      })
      table.insert(provs, {
         provider = "xiaomi-token-plan-cn",
         email = "Key: tp-c2vj0... (Token Plan 专属通道)",
         plan_type = "Xiaomi Token Plan (国内节点 CN)",
         project_id = "token-plan-cn.xiaomimimo.com",
         limits = lims,
      })
   end

   -- 2. 智谱 GLM Coding Plan
   local glm_stat = stats_map["zhipu-coding-plan"]
   if glm_stat then
      local lims: { WindowLimit } = {}
      for _, m in glm_stat.models do
         table.insert(lims, {
            id = "glm:" .. m.model,
            label = m.model .. " · 智谱代码生成模型",
            window_label = fmt_num(m.total_tokens) .. " Tokens · " .. tostring(m.requests) .. " 次调用",
            used = m.total_tokens,
            limit = m.total_tokens,
            remaining = 0,
            used_fraction = 1.0,
            remaining_fraction = 0,
            resets_at = nil,
            status = "active",
         })
      end
      local hit_rate = if glm_stat.total_tokens > 0 then (glm_stat.cache_tokens / glm_stat.total_tokens) * 100 else 0
      table.insert(lims, {
         id = "glm:cache",
         label = "GLM Coding Plan 缓存复用节省率",
         window_label = string.format("%.1f%% 命中复用 · 代码专属高速通道", hit_rate),
         used = hit_rate,
         limit = 100,
         remaining = 100 - hit_rate,
         used_fraction = hit_rate / 100,
         remaining_fraction = 1 - (hit_rate / 100),
         resets_at = nil,
         status = "active",
      })
      table.insert(provs, {
         provider = "zhipu-coding-plan",
         email = "Key: 95fb8b... (Coding Plan 专属通道)",
         plan_type = "GLM Coding Plan (智谱 CodeGeeX 专属)",
         project_id = "open.bigmodel.cn/api/coding",
         limits = lims,
      })
   end

   -- 3. MiniMax Coding Plan
   local mm_stat = stats_map["minimax-code-cn"]
   if mm_stat then
      local lims: { WindowLimit } = {}
      for _, m in mm_stat.models do
         table.insert(lims, {
            id = "minimax:" .. m.model,
            label = m.model .. " · Scout / Sonic 极速模型",
            window_label = fmt_num(m.total_tokens) .. " Tokens · " .. tostring(m.requests) .. " 次请求",
            used = m.total_tokens,
            limit = m.total_tokens,
            remaining = 0,
            used_fraction = 1.0,
            remaining_fraction = 0,
            resets_at = nil,
            status = "active",
         })
      end
      table.insert(provs, {
         provider = "minimax-code-cn",
         email = "Key: sk-cp-S... (Coding Plan 国内节点)",
         plan_type = "MiniMax Coding Plan (国内通道)",
         project_id = "api.minimaxi.com",
         limits = lims,
      })
   end
end

-- 异步拉取全部数据源
local function fetch_data(state: State, cx: BlockCx)
   state.loading = true
   state.error = nil
   cx:render()

   local bin = find_omp()
   local env = get_env()
   local home = tern.getenv("HOME") or ""
   local db_path = home .. "/.omp/stats.db"

   local pending = 3
   local function check_done()
      pending -= 1
      if pending <= 0 then
         merge_token_plans(state.providers, state.provider_stats)
         state.loading = false
         state.last_updated = os.date("%H:%M:%S")
         cx:render()
      end
   end

   -- 1. 获取 omp usage (OAuth Rate Limits)
   tern.process.run({ bin, "usage", "--json" }, { env = env, timeout_ms = 15000 }, function(res)
      if res.status == 0 and #res.stdout > 0 then
         local json_raw = res.stdout
         local s_idx = string.find(json_raw, "{", 1, true)
         if s_idx then json_raw = string.sub(json_raw, s_idx) end
         local ok, json_data = pcall(function()
            return tern.json.decode(json_raw)
         end)
         if ok and json_data and json_data.reports then
            local provs: { ProviderReport } = {}
            for _, r in json_data.reports do
               local lims: { WindowLimit } = {}
               local seen_group: { [string]: boolean } = {}
               if r.limits then
                  for _, lim in r.limits do
                     local scope = lim.scope or {}
                     local win = lim.window or {}
                     local group_key = if scope.sharedGroup and #scope.sharedGroup > 0 then scope.sharedGroup
                        else ((lim.label or "") .. "::" .. (win.id or win.label or ""))

                     if not seen_group[group_key] then
                        seen_group[group_key] = true
                        local amt = lim.amount or {}
                        local used = amt.used or 0
                        local lmt = amt.limit or 100
                        local rem = amt.remaining or (lmt - used)
                        local used_frac = amt.usedFraction or (if lmt > 0 then used / lmt else 0)
                        local rem_frac = amt.remainingFraction or (1 - used_frac)
                        table.insert(lims, {
                           id = lim.id,
                           label = lim.label or win.label or "Limit",
                           window_label = win.label or lim.label or "",
                           window_id = win.id,
                           used = used,
                           limit = lmt,
                           remaining = rem,
                           used_fraction = used_frac,
                           remaining_fraction = rem_frac,
                           resets_at = win.resetsAt,
                           status = lim.status or "ok",
                        })
                     end
                  end
               end
               local meta = r.metadata or {}
               table.insert(provs, {
                  provider = r.provider or "unknown",
                  fetched_at = r.fetchedAt,
                  email = meta.email,
                  plan_type = meta.planType,
                  project_id = meta.projectId,
                  account_id = meta.accountId,
                  limits = lims,
               })
            end
            state.providers = provs
         end
      end
      check_done()
   end)

   -- 2. 查阅本地 stats.db 全量模型与 Provider 消耗 (解决全量 MiMo / GLM 记录覆盖问题)
   local where_sql = get_range_where(state.time_range)
   local sql_q = "SELECT provider, model, SUM(requests) as requests, SUM(input_tokens) as in_tokens, SUM(output_tokens) as out_tokens, SUM(cache_read_tokens) as cache_tokens, SUM(total_tokens) as total_tokens, SUM(cost_total) as cost FROM message_rollup " .. where_sql .. " GROUP BY provider, model ORDER BY total_tokens DESC;"
   tern.process.run({
      "/usr/bin/sqlite3",
      "-json",
      db_path,
      sql_q,
   }, { env = env, timeout_ms = 10000 }, function(res)
      if res.status == 0 and #res.stdout > 0 then
         local json_raw = res.stdout
         local s_idx = string.find(json_raw, "[", 1, true)
         if s_idx then json_raw = string.sub(json_raw, s_idx) end
         local ok, rows = pcall(function()
            return tern.json.decode(json_raw)
         end)
         if ok and rows and type(rows) == "table" then
            local mlist: { ModelStat } = {}
            local pmap: { [string]: ProviderStat } = {}

            for _, r in rows do
               local in_t = r.in_tokens or 0
               local out_t = r.out_tokens or 0
               local c_t = r.cache_tokens or 0
               local tot_t = r.total_tokens or (in_t + out_t + c_t)
               local crate = if tot_t > 0 then c_t / tot_t else 0
               local m_stat: ModelStat = {
                  model = r.model or "unknown",
                  provider = r.provider or "unknown",
                  requests = r.requests or 0,
                  input_tokens = in_t,
                  output_tokens = out_t,
                  cache_read_tokens = c_t,
                  total_tokens = tot_t,
                  cache_rate = crate,
                  cost = r.cost or 0,
                  avg_tok_per_sec = nil,
               }
               table.insert(mlist, m_stat)

               -- 聚合 provider 统计
               local p = r.provider or "unknown"
               if not pmap[p] then
                  pmap[p] = {
                     provider = p,
                     total_tokens = 0,
                     input_tokens = 0,
                     output_tokens = 0,
                     cache_tokens = 0,
                     requests = 0,
                     cost = 0,
                     models = {},
                  }
               end
               pmap[p].total_tokens += tot_t
               pmap[p].input_tokens += in_t
               pmap[p].output_tokens += out_t
               pmap[p].cache_tokens += c_t
               pmap[p].requests += (r.requests or 0)
               pmap[p].cost += (r.cost or 0)
               table.insert(pmap[p].models, m_stat)
            end

            state.models = mlist
            state.provider_stats = pmap
         end
      end
      check_done()
   end)

   -- 3. 获取 omp stats 总体指标与 Sparkline 时间序列
   tern.process.run({ bin, "stats", "--json" }, { env = env, timeout_ms = 15000 }, function(res)
      if res.status == 0 and #res.stdout > 0 then
         local json_raw = res.stdout
         local s_idx = string.find(json_raw, "{", 1, true)
         if s_idx then json_raw = string.sub(json_raw, s_idx) end
         local ok, json_data = pcall(function()
            return tern.json.decode(json_raw)
         end)
         if ok and json_data then
            local ov = json_data.overall
            if ov then
               local tin = ov.totalInputTokens or 0
               local tout = ov.totalOutputTokens or 0
               local tcache = ov.totalCacheReadTokens or 0
               state.overall = {
                  total_requests = ov.totalRequests or 0,
                  successful_requests = ov.successfulRequests or 0,
                  failed_requests = ov.failedRequests or 0,
                  error_rate = ov.errorRate or 0,
                  total_input_tokens = tin,
                  total_output_tokens = tout,
                  total_cache_read_tokens = tcache,
                  total_tokens = tin + tout + tcache,
                  cache_rate = ov.cacheRate or 0,
                  cache_savings = ov.cacheSavings or 0,
                  total_cost = ov.totalCost or 0,
                  avg_tok_per_sec = ov.avgTokensPerSecond or 0,
                  avg_ttft = ov.avgTtft or 0,
                  avg_duration = ov.avgDuration or 0,
               }
            end

            -- 项目/目录明细
            if json_data.byFolder then
               local flist: { FolderStat } = {}
               for _, f in json_data.byFolder do
                  local in_t = f.totalInputTokens or 0
                  local out_t = f.totalOutputTokens or 0
                  local c_t = f.totalCacheReadTokens or 0
                  table.insert(flist, {
                     folder = f.folder or "unknown",
                     requests = f.totalRequests or 0,
                     input_tokens = in_t,
                     output_tokens = out_t,
                     cache_read_tokens = c_t,
                     total_tokens = in_t + out_t + c_t,
                     cost = f.totalCost or 0,
                  })
               end
               table.sort(flist, function(a, b) return a.total_tokens > b.total_tokens end)
               state.folders = flist
            end

            -- 时间序列
            if json_data.timeSeries then
               local tlist: { TimeSeriesPoint } = {}
               for _, pt in json_data.timeSeries do
                  local ts = math.floor((pt.timestamp or 0) / 1000)
                  table.insert(tlist, {
                     label = os.date("%H:%M", ts),
                     tokens = pt.tokens or 0,
                     requests = pt.requests or 0,
                     cost = pt.cost or 0,
                  })
               end
               state.time_series = tlist
            end
         end
      end
      check_done()
   end)
end

-- 定时刷新循环
local function start_timer_loop(state: State, cx: BlockCx)
   if state.timer_active then return end
   state.timer_active = true
   tern.timer(30000, function()
      state.timer_active = false
      if state.auto_refresh then
         fetch_data(state, cx)
         start_timer_loop(state, cx)
      end
   end)
end

-- 顶部导航栏
local function render_header(state: State): Node
   local tab_btns = {
      ui.el("button", {
         id = "tab:overview",
         actions = { click = "tab=overview" },
         text = if state.tab == "overview" then t("● 概览 [1]", "● Overview [1]") else t("概览 [1]", "Overview [1]"),
         class = if state.tab == "overview" then "lq-btn active" else "lq-btn",
      }),
      ui.el("button", {
         id = "tab:quota",
         actions = { click = "tab=quota" },
         text = if state.tab == "quota" then t("● 额度 [2]", "● Quota [2]") else t("额度 [2]", "Quota [2]"),
         class = if state.tab == "quota" then "lq-btn active" else "lq-btn",
      }),
      ui.el("button", {
         id = "tab:models",
         actions = { click = "tab=models" },
         text = if state.tab == "models" then t("● 模型 [3]", "● Models [3]") else t("模型 [3]", "Models [3]"),
         class = if state.tab == "models" then "lq-btn active" else "lq-btn",
      }),
      ui.el("button", {
         id = "tab:folders",
         actions = { click = "tab=folders" },
         text = if state.tab == "folders" then t("● 项目 [4]", "● Projects [4]") else t("项目 [4]", "Projects [4]"),
         class = if state.tab == "folders" then "lq-btn active" else "lq-btn",
      }),
   }

   local right_items = {
      ui.el("button", {
         id = "act:refresh",
         actions = { click = "act=refresh" },
         text = if state.loading then "⏳" else t("⟳ 刷新", "⟳ Refresh"),
         class = "lq-btn",
      }),
      ui.el("button", {
         id = "act:auto",
         actions = { click = "act=auto" },
         text = if state.auto_refresh then "⚡ 30s" else t("⏸ 暂停", "⏸ Pause"),
         class = "lq-btn",
      }),
      ui.el("button", {
         id = "act:help",
         actions = { click = "act=help" },
         text = "?",
         class = "lq-btn",
      }),
   }

   return ui.col({
      ui.row({
         ui.row(tab_btns),
         ui.row(right_items),
      }),
      ui.text({
         ui.span(t("● 状态: ", "● Status: "), "muted"),
         ui.span(if state.loading then t("正在同步数据...", "Syncing...") else t("监控就绪", "Ready"), if state.loading then "warning strong" else "success"),
         ui.span(t("  |  上次更新: ", "  |  Last update: "), "muted"),
         ui.span(state.last_updated or t("刚刚", "just now"), "num"),
      }),
   })
end

-- Tab 1: 概览视图
local function render_overview_view(state: State): Node
   local ov = state.overall or {
      total_requests = 0, successful_requests = 0, failed_requests = 0, error_rate = 0,
      total_input_tokens = 0, total_output_tokens = 0, total_cache_read_tokens = 0,
      total_tokens = 0, cache_rate = 0, cache_savings = 0, total_cost = 0,
      avg_tok_per_sec = 0, avg_ttft = 0, avg_duration = 0,
   }

   -- 1. KPI 卡片行
   local kpi_cards = ui.row({
      ui.card(ui.span("🪙 " .. t("Token 消耗总量", "Total Token Usage"), "strong"), {
         ui.text({ ui.span(fmt_num(ov.total_tokens), "accent strong num") }),
         ui.text({
            ui.span(t("输入: ", "Input: ") .. fmt_num(ov.total_input_tokens) .. " | " .. t("输出: ", "Output: ") .. fmt_num(ov.total_output_tokens), "muted"),
         }),
         ui.text({
            ui.span(t("缓存读取: ", "Cache Read: ") .. fmt_num(ov.total_cache_read_tokens) .. " (" .. fmt_pct(ov.cache_rate) .. t(" 命中)", " hit)"), "success"),
         }),
      }),
      ui.card(ui.span("💵 " .. t("预估总花费", "Estimated Total Cost"), "strong"), {
         ui.text({ ui.span(fmt_cost(ov.total_cost), "warning strong num") }),
         ui.text({
            ui.span(t("请求数: ", "Requests: ") .. tostring(ov.total_requests) .. t(" 次 | 成功率: ", " | Success: ") .. fmt_pct(1 - ov.error_rate), "muted"),
         }),
         ui.text({
            ui.span(t("缓存节省额: ", "Cache Savings: ") .. fmt_pct(ov.cache_savings), "accent"),
         }),
      }),
      ui.card(ui.span("⚡ " .. t("模型吐字性能", "Generation Speed"), "strong"), {
         ui.text({ ui.span(string.format("%.1f tok/s", ov.avg_tok_per_sec), "num strong") }),
         ui.text({
            ui.span(t("首字延迟 TTFT: ", "First Token TTFT: ") .. string.format("%.2f s", ov.avg_ttft / 1000), "muted"),
         }),
         ui.text({
            ui.span(t("单次请求平均: ", "Avg Duration: ") .. string.format("%.2f s", ov.avg_duration / 1000), "muted"),
         }),
      }),
      ui.card(ui.span("🛡 " .. t("Provider 额度健康", "Provider Health"), "strong"), {
         ui.text({ ui.span(tostring(#state.providers) .. t(" 个已接入", " connected"), "success strong num") }),
         ui.text({
            ui.span(t("涵盖 Gemini, Codex, Kimi, MiMo, GLM", "Gemini, Codex, Kimi, MiMo, GLM"), "muted"),
         }),
         ui.text({
            ui.span(t("● 额度全部充足，无受阻限流", "● Quotas healthy, no active limits"), "success"),
         }),
      }),
   })

   -- 2. 核心 Provider 额度速览
   local quota_rows: { Node } = {}
   for _, p in state.providers do
      local p_name, p_tone = get_provider_info(p.provider)
      local lim_nodes: { Node } = {}
      for _, lim in p.limits do
         local badge_txt = if lim.resets_at then fmt_reset(lim.resets_at) else t("持续通道", "Always active")
         local used_badge = if lim.used > 100 then (t("吞吐 ", "Volume ") .. fmt_num(lim.used)) else string.format(t("已用 %.1f%%", "Used %.1f%%"), lim.used)
         local tone = if lim.status == "active" then "accent" else quota_tone(lim.used_fraction)
         local title_txt = lim.label
         if lim.window_label and #lim.window_label > 0 and not string.find(title_txt, lim.window_label, 1, true) then
            title_txt = title_txt .. " (" .. lim.window_label .. ")"
         end
         table.insert(lim_nodes, ui.col({
            ui.row({
               ui.text({ ui.span("● " .. title_txt, "strong") }),
               ui.badge(badge_txt, "info"),
               ui.badge(used_badge, tone),
            }),
            ui.meter(lim.used_fraction, lim.window_label),
         }))
      end
      local card_head = {
         ui.span(p_name, p_tone),
         ui.span(if p.email then (" · " .. p.email) else "", "muted"),
         ui.span(if p.plan_type then (" [" .. p.plan_type .. "]") else "", "accent"),
      }
      table.insert(quota_rows, ui.card(card_head, lim_nodes))
   end

   -- 3. 走势 Sparkline
   local spark_card: Node? = nil
   if #state.time_series > 0 then
      local series: { { any } } = {}
      for _, pt in state.time_series do
         table.insert(series, { pt.label, pt.tokens })
      end
      spark_card = ui.card(ui.span("📈 " .. t("小时级 Token 消耗走势", "Hourly Token Usage Sparkline"), "strong"), {
         ui.spark(series),
         ui.text({
            ui.span(t("柱状波形展示近期每小时吞吐总量变化，峰值直观反映大批次任务运行阶段。", "Bar waveform showing hourly throughput trends and peak workload runs."), "muted"),
         }),
      })
   end

   local children: { Node } = {
      kpi_cards,
      ui.rule(ui.span(t("各 Provider Plan 额度状态速览", "Provider Plan Quota Overview"))),
      if #quota_rows > 0 then ui.col(quota_rows) else ui.text({ ui.span(t("暂无 Provider 额度信息", "No provider quota info available"), "muted") }),
   }
   if spark_card then
      table.insert(children, spark_card)
   end

   return ui.col(children)
end

-- Tab 2: Plan 额度详情视图 (重点支持 MiMo Token Plan 与 GLM Coding Plan)
local function render_quota_view(state: State): Node
   if #state.providers == 0 then
      return ui.card(ui.span("💳 " .. t("Provider Plan 额度", "Provider Plan Quotas"), "strong"), {
         ui.text({ ui.span(t("未检测到已认证的 Provider 额度，请确认 omp 登录状态或 API 密钥配置。", "No authenticated provider quota detected. Check omp login status or API key config."), "muted") }),
      })
   end

   local cards: { Node } = {}
   for _, p in state.providers do
      local p_name, p_tone = get_provider_info(p.provider)
      local items: { Node } = {}

      -- 账号通道信息行
      table.insert(items, ui.col({
         ui.text({
            ui.span(t("供应商: ", "Provider: "), "muted"),
            ui.span(p_name, p_tone),
            ui.span("  (" .. p.provider .. ")", "muted"),
         }),
         ui.text({
            ui.span(t("通道类型: ", "Channel: "), "muted"),
            ui.span(p.plan_type or t("标准通道", "Standard Channel"), "accent strong"),
            ui.span(t("  · 账号标识: ", "  · Account ID: "), "muted"),
            ui.span(p.email or "-", "num"),
         }),
      }))

      table.insert(items, ui.rule(ui.span(t("配额进度与通道指标", "Quota Progress & Channel Metrics"))))

      for _, lim in p.limits do
         local tone_val = if lim.status == "active" then "accent" else quota_tone(lim.used_fraction)
         local time_badge = if lim.resets_at then fmt_reset(lim.resets_at) else t("持续可用通道", "Always Active")
         local title_txt = lim.label
         if lim.window_label and #lim.window_label > 0 and not string.find(title_txt, lim.window_label, 1, true) then
            title_txt = title_txt .. " · " .. lim.window_label
         end
         table.insert(items, ui.col({
            ui.row({
               ui.text({ ui.span("🔹 " .. title_txt, "strong") }),
               ui.badge(t("状态: ", "Status: ") .. (lim.status or "active"), tone_val),
               ui.badge(time_badge, "info"),
            }),
            ui.meter(lim.used_fraction, lim.window_label),
         }))
      end

      local card_head = {
         ui.span("💳 " .. p_name, p_tone),
         ui.span(if p.email then (" (" .. p.email .. ")") else "", "muted"),
      }
      table.insert(cards, ui.card(card_head, items))
   end

   return ui.col(cards)
end

-- Tab 3: 模型用量视图
local function render_models_view(state: State): Node
   local range_btns = {
      ui.el("button", {
         id = "time:midnight",
         actions = { click = "time=midnight" },
         text = if state.time_range == "midnight" then t("● 今日 (0点起)", "● Today (00:00)") else t("今日 (0点起)", "Today (00:00)"),
         class = if state.time_range == "midnight" then "lq-btn active" else "lq-btn",
      }),
      ui.el("button", {
         id = "time:24h",
         actions = { click = "time=24h" },
         text = if state.time_range == "24h" or (state.time_range :: string) == "today" then t("● 近 24h", "● Past 24h") else t("近 24h", "Past 24h"),
         class = if state.time_range == "24h" or (state.time_range :: string) == "today" then "lq-btn active" else "lq-btn",
      }),
      ui.el("button", {
         id = "time:7d",
         actions = { click = "time=7d" },
         text = if state.time_range == "7d" then t("● 近 7 天", "● Past 7d") else t("近 7 天", "Past 7d"),
         class = if state.time_range == "7d" then "lq-btn active" else "lq-btn",
      }),
      ui.el("button", {
         id = "time:30d",
         actions = { click = "time=30d" },
         text = if state.time_range == "30d" then t("● 近 30 天", "● Past 30d") else t("近 30 天", "Past 30d"),
         class = if state.time_range == "30d" then "lq-btn active" else "lq-btn",
      }),
      ui.el("button", {
         id = "time:all",
         actions = { click = "time=all" },
         text = if state.time_range == "all" then t("● 全部历史", "● All History") else t("全部历史", "All History"),
         class = if state.time_range == "all" then "lq-btn active" else "lq-btn",
      }),
   }

   local time_bar = ui.row({
      ui.row(range_btns),
      ui.text({ ui.span(t("  (按 t 键循环切换时间周期)", "  (press t to cycle time ranges)"), "muted") }),
   })

   if #state.models == 0 then
      return ui.col({
         time_bar,
         ui.card(ui.span("🤖 " .. t("模型用量明细", "Model Usage Breakdown"), "strong"), {
            ui.text({ ui.span(t("当前选定周期内暂无模型调用记录，可切换上方周期查看。", "No model usage found for selected range. Switch range above to view."), "muted") }),
         }),
      })
   end

   local tot_tok = 0
   local tot_cost = 0
   local tot_reqs = 0
   for _, m in state.models do
      tot_tok += m.total_tokens
      tot_cost += m.cost
      tot_reqs += m.requests
   end

   local range_labels = {
      midnight = t("今日 (自00:00至今)", "Today (since 00:00)"),
      ["24h"] = t("近 24 小时", "Past 24 Hours"),
      today = t("近 24 小时", "Past 24 Hours"),
      ["7d"] = t("最近 7 天", "Past 7 Days"),
      ["30d"] = t("最近 30 天", "Past 30 Days"),
      all = t("全部历史", "All History"),
   }
   local cur_label = range_labels[state.time_range] or t("当前周期", "Current Range")

   local summary_card = ui.card(ui.span("⏱ " .. cur_label .. " " .. t("汇总统计", "Summary Statistics"), "accent strong"), {
      ui.row({
         ui.badge(cur_label, "accent"),
         ui.badge(t("消耗: ", "Usage: ") .. fmt_num(tot_tok) .. " Tokens", "strong"),
         ui.badge(t("预估费用: ", "Est. Cost: ") .. fmt_cost(tot_cost), "warning strong"),
         ui.badge(t("请求: ", "Requests: ") .. tostring(tot_reqs) .. t(" 次", ""), "info"),
      }),
   })


   local cols = {
      { id = "model", head = t("模型名称", "Model"), grow = 2 },
      { id = "provider", head = t("供应商", "Provider"), grow = 1 },
      { id = "total", head = t("总 Tokens", "Total Tokens"), align = "end" :: "end", grow = 1 },
      { id = "in", head = t("输入", "Input"), align = "end" :: "end", grow = 1 },
      { id = "out", head = t("输出", "Output"), align = "end" :: "end", grow = 1 },
      { id = "cache", head = t("缓存读取", "Cache Read"), align = "end" :: "end", grow = 1 },
      { id = "cost", head = t("预估费用", "Est. Cost"), align = "end" :: "end", grow = 1 },
      { id = "reqs", head = t("请求数", "Requests"), align = "end" :: "end", grow = 1 },
   }

   local rows: { { Cell } } = {}
   for _, m in state.models do
      table.insert(rows, {
         ui.span(m.model, "accent strong"),
         ui.span(m.provider, "muted"),
         ui.span(fmt_num(m.total_tokens), "num strong"),
         ui.span(fmt_num(m.input_tokens), "num"),
         ui.span(fmt_num(m.output_tokens), "num"),
         ui.span(fmt_num(m.cache_read_tokens) .. " (" .. fmt_pct(m.cache_rate) .. ")", "success num"),
         ui.span(fmt_cost(m.cost), "warning num"),
         ui.span(tostring(m.requests), "num"),
      })
   end

   local bar_series: { { any } } = {}
   for i = 1, math.min(7, #state.models) do
      local m = state.models[i]
      table.insert(bar_series, { m.model, m.total_tokens })
   end

   return ui.col({
      time_bar,
      summary_card,
      ui.card(ui.span("📊 " .. t("模型 Token 消耗占比直方图", "Model Token Usage Distribution"), "strong"), {
         ui.bars(bar_series),
      }),
      ui.card(ui.span("🤖 " .. t("模型消耗明细清单", "Model Usage Breakdown") .. " (" .. cur_label .. ")", "strong"), {
         ui.table(cols, rows),
      }),
   })
end

-- Tab 4: 项目分布视图
local function render_folders_view(state: State): Node
   if #state.folders == 0 then
      return ui.card(ui.span("📁 " .. t("项目工作区分布", "Project Workspace Distribution"), "strong"), {
         ui.text({ ui.span(t("暂无按目录区分的会话记录", "No session records grouped by directory"), "muted") }),
      })
   end

   local total_tokens = 0
   for _, f in state.folders do
      total_tokens += f.total_tokens
   end

   local cols = {
      { id = "folder", head = t("项目 / 工作区目录", "Project / Workspace"), grow = 2 },
      { id = "requests", head = t("请求数", "Requests"), align = "end" :: "end", grow = 1 },
      { id = "total", head = t("消耗总 Tokens", "Total Tokens"), align = "end" :: "end", grow = 1 },
      { id = "in", head = t("输入", "Input"), align = "end" :: "end", grow = 1 },
      { id = "out", head = t("输出", "Output"), align = "end" :: "end", grow = 1 },
      { id = "cache", head = t("缓存读取", "Cache Read"), align = "end" :: "end", grow = 1 },
      { id = "cost", head = t("花费", "Cost"), align = "end" :: "end", grow = 1 },
      { id = "ratio", head = t("全局占比", "Ratio"), align = "end" :: "end", grow = 1 },
   }

   local rows: { { Cell } } = {}
   for _, f in state.folders do
      local ratio = if total_tokens > 0 then f.total_tokens / total_tokens else 0
      table.insert(rows, {
         ui.span("📁 " .. clean_folder_name(f.folder), "strong"),
         ui.span(tostring(f.requests), "num"),
         ui.span(fmt_num(f.total_tokens), "accent strong num"),
         ui.span(fmt_num(f.input_tokens), "num"),
         ui.span(fmt_num(f.output_tokens), "num"),
         ui.span(fmt_num(f.cache_read_tokens), "success num"),
         ui.span(fmt_cost(f.cost), "warning num"),
         ui.span(fmt_pct(ratio), "num"),
      })
   end

   return ui.card(ui.span("📁 " .. t("项目工作区 Token 与费用分布统计", "Project Workspace Token & Cost Breakdown"), "strong"), {
      ui.table(cols, rows),
   })
end

-- 画中画模式 (PiP / Mini HUD): 专为悬浮小窗自适应微缩
local function render_pip_view(state: State): Node
   local ov = state.overall or {
      total_requests = 0, successful_requests = 0, failed_requests = 0, error_rate = 0,
      total_input_tokens = 0, total_output_tokens = 0, total_cache_read_tokens = 0,
      total_tokens = 0, cache_rate = 0, cache_savings = 0, total_cost = 0,
      avg_tok_per_sec = 0, avg_ttft = 0, avg_duration = 0,
   }

   local top_bar = ui.row({
      ui.text({ ui.span("⚡ " .. t("LLM 悬浮监控", "LLM Mini HUD"), "accent strong") }),
      ui.text({ ui.span(fmt_cost(ov.total_cost), "warning strong num") }),
      ui.text({ ui.span(state.last_updated or t("刚刚", "just now"), "muted num") }),
   })

   local chips = ui.row({
      ui.badge(fmt_num(ov.total_tokens) .. " Tok", "accent"),
      ui.badge(string.format("%.1f t/s", ov.avg_tok_per_sec), "info"),
      ui.badge(fmt_pct(ov.cache_rate) .. t(" 缓存", " Cache"), "success"),
   })

   local quota_items: { Node } = {}
   for _, p in state.providers do
      local p_name, p_tone = get_provider_info(p.provider)
      if #p.limits > 0 then
         local lim = p.limits[1]
         local badge_txt = if lim.resets_at then fmt_reset(lim.resets_at) else t("持续通道", "Always Active")
         table.insert(quota_items, ui.col({
            ui.row({
               ui.text({ ui.span(p_name, p_tone) }),
               ui.badge(badge_txt, "info"),
            }),
            ui.meter(lim.used_fraction, lim.label .. ": " .. lim.window_label),
         }))
      end
   end

   local pip_dock = ui.row({
      ui.el("button", { id = "act:refresh", text = t("⟳ 刷新", "⟳ Refresh") }),
      ui.text({ ui.span(t("r 刷新 · 1-4 视图", "r refresh · 1-4 view"), "muted") }),
   })

   return ui.col({
      top_bar,
      chips,
      ui.rule(ui.span(t("核心额度监控", "Core Quotas"))),
      if #quota_items > 0 then ui.col(quota_items) else ui.text({ ui.span(t("同步中...", "Syncing..."), "muted") }),
      pip_dock,
   })
end

-- 底部 Dock 状态栏
local function render_dock(state: State): Node
   return ui.col({
      ui.row({
         ui.el("button", { id = "tab:overview", actions = { click = "tab=overview" }, text = t("1 概览", "1 Overview") }),
         ui.el("button", { id = "tab:quota", actions = { click = "tab=quota" }, text = t("2 额度", "2 Quota") }),
         ui.el("button", { id = "tab:models", actions = { click = "tab=models" }, text = t("3 模型", "3 Models") }),
         ui.el("button", { id = "tab:folders", actions = { click = "tab=folders" }, text = t("4 项目", "4 Projects") }),
         ui.el("button", { id = "act:refresh", actions = { click = "act=refresh" }, text = t("⟳ 刷新", "⟳ Refresh") }),
         ui.el("button", { id = "act:auto", actions = { click = "act=auto" }, text = if state.auto_refresh then t("⚡ 自动: 开", "⚡ Auto: ON") else t("⏸ 自动: 关", "⏸ Auto: OFF") }),
         ui.el("button", { id = "act:help", actions = { click = "act=help" }, text = t("？ 帮助", "？ Help") }),
      }),
   })
end

-- 帮助弹层 Layer
local function render_help_layer(): Node
   return ui.card(ui.span("ℹ️ " .. t("LLM 用量与额度监控面板使用指南", "LLM Quota & Usage Monitor User Guide"), "accent strong"), {
      ui.kv({
         { ui.span(t("视图切换", "Views"), "strong"), ui.span(t("按键盘 1=概览, 2=Plan额度(支持GLM/MiMo), 3=模型用量, 4=项目分布", "Keys: 1=Overview, 2=Quota (GLM/MiMo), 3=Model Usage, 4=Projects")) },
         { ui.span(t("数据同步", "Sync"), "strong"), ui.span(t("按 r 立即刷新，按 a 开启/关闭 30s 自动刷新", "Press r to refresh immediately, a to toggle 30s auto-refresh")) },
         { ui.span(t("全量覆盖", "Coverage"), "strong"), ui.span(t("已全面接入小米 MiMo Token Plan 与智谱 GLM Coding Plan 监控", "Integrated Xiaomi MiMo Token Plan & GLM Coding Plan tracking")) },
         { ui.span(t("Carly 诊断", "Carly"), "strong"), ui.span(t("调色板运行「Carly 诊断」获取针对您用量的降本与防限流建议", "Run Carly Diagnosis in command palette for cost reduction advice")) },
         { ui.span(t("退出提示", "Close"), "strong"), ui.span(t("按 Esc、? 或 h 即可关闭此帮助弹窗", "Press Esc, ? or h to close this modal")) },
      }),
      ui.row({
         ui.el("button", { id = "close_help", actions = { click = "close_help" }, text = t("✕ 关闭帮助 (Esc)", "✕ Close Help (Esc)") }),
      }),
   })
end

local quota_block: BlockDef<State> = {
   init = function(cx, _args, saved)
      local state: State = {
         tab = if saved and saved.tab then saved.tab else "overview",
         time_range = if saved and saved.time_range then (if saved.time_range == "today" then "24h" else saved.time_range) else "midnight",
         loading = true,
         error = nil,
         last_updated = nil,
         overall = nil,
         providers = {},
         provider_stats = {},
         models = {},
         folders = {},
         time_series = {},
         auto_refresh = if saved and saved.auto_refresh ~= nil then saved.auto_refresh else true,
         timer_active = false,
         show_help = false,
      }
      fetch_data(state, cx)
      if state.auto_refresh then
         start_timer_loop(state, cx)
      end
      return state
   end,

   title = function(state)
      local tab_titles = {
         overview = t("概览", "Overview"),
         quota = t("Plan 额度", "Quotas"),
         models = t("模型用量", "Models"),
         folders = t("项目分布", "Projects"),
      }
      local tab_name = tab_titles[state.tab] or t("看板", "Dashboard")
      local cost = if state.overall then fmt_cost(state.overall.total_cost) else "$0.00"
      return "LLM " .. tab_name .. " (" .. cost .. ")"
   end,

   view = function(state, cx)
      local is_pip = (cx and cx.cols and cx.cols < 55) or (cx and cx.rows and cx.rows < 22)
      if is_pip then
         return {
            main = render_pip_view(state),
            dock = nil,
            layer = if state.show_help then render_help_layer() else nil,
         }
      end

      local header = render_header(state)
      local body: Node
      if state.tab == "overview" then
         body = render_overview_view(state)
      elseif state.tab == "quota" then
         body = render_quota_view(state)
      elseif state.tab == "models" then
         body = render_models_view(state)
      elseif state.tab == "folders" then
         body = render_folders_view(state)
      else
         body = render_overview_view(state)
      end

      local main_node = ui.col({
         header,
         ui.rule(ui.span(t("统计看板", "Dashboard"))),
         body,
      })

      return {
         main = main_node,
         dock = render_dock(state),
         layer = if state.show_help then render_help_layer() else nil,
      }
   end,

   key = function(state, key, cx)
      if state.show_help then
         if key.name == "escape" or key.name == "?" or key.name == "h" or key.name == "enter" then
            state.show_help = false
            return true
         end
      end

      if key.name == "1" or key.text == "1" then
         state.tab = "overview"
         return true
      elseif key.name == "2" or key.text == "2" then
         state.tab = "quota"
         return true
      elseif key.name == "3" or key.text == "3" then
         state.tab = "models"
         return true
      elseif key.name == "4" or key.text == "4" then
         state.tab = "folders"
         return true
      elseif key.name == "r" or key.text == "r" then
         fetch_data(state, cx)
      elseif key.name == "t" or key.text == "t" then
         local next_range: { [string]: TimeRange } = {
            midnight = "24h",
            ["24h"] = "7d",
            today = "7d",
            ["7d"] = "30d",
            ["30d"] = "all",
            all = "midnight",
         }
         state.time_range = next_range[state.time_range] or "midnight"
         fetch_data(state, cx)
         return true
      elseif key.name == "a" then
         state.auto_refresh = not state.auto_refresh
         if state.auto_refresh and not state.timer_active then
            start_timer_loop(state, cx)
         end
         return true
      elseif key.name == "?" or key.name == "h" then
         state.show_help = not state.show_help
         return true
      elseif key.name == "escape" then
         if state.show_help then
            state.show_help = false
            return true
         end
      end
      return false
   end,

   event = function(state, ev, cx)
      local act = ev.act or ev.id or ""
      local val = ev.value

      -- 1. 标准 act + value (来自 Tern actions = { click = "act=val" })
      if act == "tab" and val then
         state.tab = val :: TabMode
         cx:render()
         return
      elseif act == "time" and val then
         local rng = val :: TimeRange
         if rng == "midnight" or rng == "24h" or (rng :: string) == "today" or rng == "7d" or rng == "30d" or rng == "all" then
            state.time_range = if (rng :: string) == "today" then "24h" else rng
            fetch_data(state, cx)
         end
         return
      elseif act == "act" and val then
         if val == "refresh" then
            fetch_data(state, cx)
         elseif val == "auto" then
            state.auto_refresh = not state.auto_refresh
            if state.auto_refresh and not state.timer_active then
               start_timer_loop(state, cx)
            end
            cx:render()
         elseif val == "help" then
            state.show_help = not state.show_help
            cx:render()
         end
         return
      end

      -- 2. 兼容直接字符串动作名 ("tab:quota", "time:7d")
      if act == "tab:overview" or act == "overview" then
         state.tab = "overview"
         cx:render()
      elseif act == "tab:quota" or act == "quota" then
         state.tab = "quota"
         cx:render()
      elseif act == "tab:models" or act == "models" then
         state.tab = "models"
         cx:render()
      elseif act == "tab:folders" or act == "folders" then
         state.tab = "folders"
         cx:render()
      elseif string.sub(act, 1, 5) == "time:" then
         local rng = string.sub(act, 6)
         if rng == "midnight" or rng == "24h" or rng == "today" or rng == "7d" or rng == "30d" or rng == "all" then
            state.time_range = if rng == "today" then "24h" else (rng :: TimeRange)
            fetch_data(state, cx)
         end
      elseif act == "act:refresh" or act == "refresh" then
         fetch_data(state, cx)
      elseif act == "act:auto" or act == "auto" then
         state.auto_refresh = not state.auto_refresh
         if state.auto_refresh and not state.timer_active then
            start_timer_loop(state, cx)
         end
         cx:render()
      elseif act == "act:help" or act == "help" then
         state.show_help = not state.show_help
         cx:render()
      elseif act == "close_help" then
         state.show_help = false
         cx:render()
      end
   end,

   save = function(state)
      return { tab = state.tab, time_range = state.time_range, auto_refresh = state.auto_refresh }
   end,
}

tern.block.define("main", quota_block)
