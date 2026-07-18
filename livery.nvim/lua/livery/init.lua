-- livery.nvim — palette overlay for the vestiary theme contract.
-- Reads ~/.config/livery/{current,default}/nvim/livery.lua (pure data,
-- rendered by adapters/nvim), applies a curated highlight overlay on top of
-- whatever colorscheme is active, and watches the contract dir to re-apply
-- live when the Look flips. Theme-supported, not theme-critical: with no
-- contract present this is a no-op and the colorscheme is untouched.

local M = {}

local uv = vim.uv or vim.loop

M.config = {
  runtime = vim.fn.expand("~/.config/livery"),
  overlay = true, -- apply the highlight overlay
  watch = true,   -- re-apply when the contract flips
}

function M.palette()
  for _, link in ipairs({ "current", "default" }) do
    local path = M.config.runtime .. "/" .. link .. "/nvim/livery.lua"
    local chunk = loadfile(path)
    if chunk then
      local ok, palette = pcall(chunk)
      if ok and type(palette) == "table" then
        return palette
      end
    end
  end
  return nil
end

local function hl(group, spec)
  vim.api.nvim_set_hl(0, group, spec)
end

-- The curated overlay: relationships, not a full colorscheme. Syntax-adjacent
-- accents would come from terminal.base16 slots (per contract docs), which is
-- deliberately out of scope for the overlay — the colorscheme owns syntax.
function M.apply()
  local p = M.palette()
  if not p then
    return false
  end
  local ui = p.ui or {}
  local sig = p.signals or {}
  local term = p.terminal or {}

  if term.ansi then
    for i = 0, 15 do
      vim.g["terminal_color_" .. i] = term.ansi[i + 1]
    end
  end

  if M.config.overlay then
    hl("Visual", { bg = ui.selection })
    hl("FloatBorder", { fg = ui.outlineVariant or ui.outline })
    hl("WinSeparator", { fg = ui.outlineVariant or ui.outline })
    hl("Search", { bg = ui.selection, fg = ui.text })
    hl("IncSearch", { bg = ui.primary, fg = ui.onPrimary or ui.background })
    hl("DiagnosticError", { fg = sig.error })
    hl("DiagnosticWarn", { fg = sig.warning })
    hl("DiagnosticInfo", { fg = sig.info })
    hl("DiagnosticHint", { fg = ui.tertiary })
    hl("GitSignsAdd", { fg = sig.success })
    hl("GitSignsChange", { fg = sig.info })
    hl("GitSignsDelete", { fg = sig.error })
  end

  vim.api.nvim_exec_autocmds("User", { pattern = "LiveryApplied", modeline = false })
  return true
end

-- A lualine theme built from the palette; nil when no contract is present so
-- callers can fall back: theme = require("livery").lualine_theme() or "auto".
function M.lualine_theme()
  local p = M.palette()
  if not p then
    return nil
  end
  local ui = p.ui or {}
  local on_accent = ui.onPrimary or ui.background
  local function mode(accent)
    return {
      a = { bg = accent, fg = on_accent, gui = "bold" },
      b = { bg = ui.surface, fg = ui.text },
      c = { bg = "NONE", fg = ui.textMuted },
    }
  end
  local theme = {
    normal = mode(ui.primary),
    insert = mode(ui.secondary),
    visual = mode(ui.selection),
    replace = mode(p.signals and p.signals.error or ui.primary),
    command = mode(ui.tertiary),
    inactive = {
      a = { bg = "NONE", fg = ui.textMuted },
      b = { bg = "NONE", fg = ui.textMuted },
      c = { bg = "NONE", fg = ui.textMuted },
    },
  }
  return theme
end

local watcher

local function watch()
  if watcher then
    watcher:stop()
  end
  watcher = uv.new_fs_event()
  if not watcher then
    return
  end
  -- Watching the runtime root sees the atomic `current` symlink flip.
  watcher:start(M.config.runtime, {}, function()
    vim.schedule(function()
      -- Debounce: the flip is one rename, but be tolerant of write bursts.
      if M._pending then
        return
      end
      M._pending = true
      vim.defer_fn(function()
        M._pending = false
        M.apply()
      end, 150)
    end)
  end)
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  M.apply()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("LiveryOverlay", { clear = true }),
    callback = function()
      -- Re-assert the overlay after any colorscheme (re)load.
      vim.schedule(M.apply)
    end,
  })
  if M.config.watch and uv.fs_stat(M.config.runtime) then
    watch()
  end
end

return M
