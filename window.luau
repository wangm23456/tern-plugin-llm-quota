--!strict
-- 窗口端：注册 LLM 用量面板的调色板命令与 Carly AI 对话入口
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

tern.command({
   id = "open",
   title = t("LLM 额度: 开启用量与额度监控", "LLM Quota: Open Usage & Quota Monitor"),
   icon = "sparkle",
   run = function(cx)
      cx:new_block("llm-quota.main", nil, "beside")
      cx:toast("info", t("LLM 额度与用量", "LLM Quota"), t("已开启 LLM 监控面板 (1-4 切换视图，r 刷新)", "Opened LLM quota monitor (1-4 switch tab, r refresh)"))
   end,
})

tern.command({
   id = "open_tab",
   title = t("LLM 额度: 在独立标签页打开面板", "LLM Quota: Open Monitor in New Tab"),
   icon = "sparkle",
   run = function(cx)
      cx:new_block("llm-quota.main", nil, "tab")
   end,
})

tern.command({
   id = "carly",
   title = t("LLM 额度: Carly Token 消耗诊断", "LLM Quota: Analyze Token Usage with Carly"),
   icon = "sparkle",
   run = function(cx)
      cx:ask_carly(t(
         "请查看我当前 LLM 的 Token 消耗总量、各模型分布以及各个 Provider (Gemini/OpenAI/Kimi等) 的额度剩余情况，分析消耗偏高的模块并给出节省成本、避免超额限流的最佳实践建议。",
         "Please check my total LLM token consumption, model breakdown, and rate limits for providers (Gemini, OpenAI, Kimi, etc.), identify high usage, and recommend cost optimizations."
      ))
   end,
})

tern.css("llm-quota-window-style", [[
   [data-surface="plugin.llm-quota.main"].sf-main {
      padding: 12px 16px;
      overflow-y: auto;
   }
   [data-surface="plugin.llm-quota.main"].sf-dock {
      padding: 8px 14px;
      border-top: 1px solid var(--border, rgba(255, 255, 255, 0.08));
   }
   [data-surface="plugin.llm-quota.main"].sf-layer {
      padding: 24px 32px;
   }
]])
