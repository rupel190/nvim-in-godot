-- Godot 4.x development: GDScript LSP + DAP, both over TCP to a *running* Godot editor.
--
-- Godot does not ship a standalone language server: the editor itself listens on
--   LSP  127.0.0.1:6005  (Editor Settings > Network > Language Server)
--   DAP  127.0.0.1:6006  (Editor Settings > Network > Debug Adapter)
-- so the Godot editor must be open on the project for either half to work.
--
-- Because the editor *is* the server, restarting Godot tears down the LSP socket and
-- the gdscript client dies with it -- silently, since Neovim reports that as a clean
-- exit (code 0) and never re-dials. Part 1 therefore carries a small supervisor that
-- reconnects on its own. The DAP half needs nothing of the sort: nvim-dap dials 6006
-- fresh for every debug session, so a restarted editor fixes itself.

local LSP_HOST = "127.0.0.1"
local LSP_PORT = 6005
local DAP_PORT = 6006
local SERVER = "gdscript" -- vim.lsp config name
local FILETYPE = "gdscript" -- buffer filetype the server serves

-- Delays for the retry burst that follows a lost connection, in ms. Deliberately
-- finite: see retry() below.
local RETRY_MS = { 500, 1000, 2000, 4000, 8000, 15000 }
-- Floor on how often *editing activity* may cause a probe.
local COOLDOWN_MS = 2000
-- A refused port on loopback answers in microseconds; this bounds only the
-- pathological case where the SYN is dropped instead of refused.
local PROBE_TIMEOUT_MS = 300

-- Resolve the Godot project root (the directory holding project.godot) from the
-- current buffer. Preferred over DAP's "${workspaceFolder}", which nvim-dap expands
-- to Neovim's *cwd* -- wrong as soon as you launch nvim from a subdirectory.
-- Godot's req_launch rejects the request with WRONG_PATH if this is not a real path.
local function godot_project_root()
  return vim.fs.root(0, "project.godot") or vim.uv.cwd()
end

-------------------------------------------------------------------------------
-- Reconnect supervisor
-------------------------------------------------------------------------------

-- Is a gdscript client still holding a live socket?
--
-- WHY not just `#vim.lsp.get_clients({ name = SERVER }) > 0`: when the socket dies,
-- Neovim runs the LspDetach autocmds *before* it drops the client from its table, so
-- during exactly the event we care about the dead client is still listed. is_stopped()
-- is what separates "present" from "usable".
local function lsp_connected()
  for _, client in ipairs(vim.lsp.get_clients({ name = SERVER })) do
    if not client:is_stopped() then
      return true
    end
  end
  return false
end

-- Ask the kernel whether Godot is listening, without involving vim.lsp at all.
--
-- WHY probe instead of simply re-running vim.lsp.enable() and letting a failed dial
-- be the answer: a failed dial is expensive in both ways that matter here.
--   1. Neovim's TCP transport reports it with a hard-coded
--      vim.notify("Could not connect to 127.0.0.1:6005 ...") -- there is no silent
--      flag -- so a retry loop becomes a notification loop.
--   2. Far worse, the half-built client is *left alive*: never connected, never
--      initialized, never closed. vim.lsp.get_clients() hides it, but
--      vim.lsp.start()'s reuse check does not, so every later attempt happily
--      re-uses the corpse and the LSP stays dead forever.
-- Probing first means a client is only ever created when the port really answers.
local function probe(on_result)
  local sock = assert(vim.uv.new_tcp())
  local timer = assert(vim.uv.new_timer())
  local settled = false

  local function settle(ok)
    if settled then
      return
    end
    settled = true
    if not timer:is_closing() then
      timer:close()
    end
    if not sock:is_closing() then
      sock:close()
    end
    -- Both callbacks below land in a libuv fast event, where nearly no API call is
    -- legal; hand the answer back on the main loop.
    vim.schedule(function()
      on_result(ok)
    end)
  end

  timer:start(PROBE_TIMEOUT_MS, 0, function()
    settle(false)
  end)
  sock:connect(LSP_HOST, LSP_PORT, function(err)
    settle(err == nil)
  end)
end

local probe_in_flight = false
local cooldown_until = 0

--- @param force boolean ignore the activity cooldown (use for one-shot signals)
--- @param on_result? fun(connected: boolean)
local function connect(force, on_result)
  on_result = on_result or function() end
  if vim.v.exiting ~= vim.NIL or probe_in_flight then
    return on_result(false)
  end
  if lsp_connected() then
    return on_result(true)
  end
  if not force and vim.uv.now() < cooldown_until then
    return on_result(false)
  end

  probe_in_flight = true
  cooldown_until = vim.uv.now() + COOLDOWN_MS
  probe(function(port_open)
    if port_open then
      -- Defensive reap, in case a dial ever lost the race with a dying Godot and
      -- left a corpse (see probe()). `_uninitialized` is the only filter that can
      -- see one; it is private, but if a future Neovim drops it the key is simply
      -- ignored and we degrade to today's behaviour rather than to something worse.
      for _, client in ipairs(vim.lsp.get_clients({ name = SERVER, _uninitialized = true })) do
        if not client.initialized then
          pcall(function()
            client:stop(true)
          end)
        end
      end
      -- This is the whole trick, and it is not obvious: vim.lsp.enable() is not just
      -- a setting for future buffers. It ends with a `doautoall` over its own
      -- FileType autocmd group, which re-runs attachment across every buffer that is
      -- already loaded -- so calling it again genuinely re-attaches the .gd files you
      -- already have open, not only the next one you open.
      pcall(vim.lsp.enable, SERVER)
    end
    probe_in_flight = false
    on_result(port_open)
  end)
end

-- Bounded retry burst, started only by an actual disconnect.
--
-- WHY bounded and WHY no standing timer: Godot can be shut for a working day, and a
-- permanent poll would be paying rent forever for a rare event. The burst exists to
-- cover the one case nothing else would catch -- Godot restarting while you sit
-- still in Neovim -- and it gives up after ~30s. From then on the event triggers
-- below are the mechanism, which costs exactly nothing while you are not touching
-- GDScript.
local function retry(step)
  step = step or 1
  if vim.v.exiting ~= vim.NIL or step > #RETRY_MS then
    return
  end
  vim.defer_fn(function()
    connect(true, function(connected)
      if not connected then
        retry(step + 1)
      end
    end)
  end, RETRY_MS[step])
end

local function install_supervisor()
  local group = vim.api.nvim_create_augroup("godot_lsp_reconnect", { clear = true })

  -- The disconnect signal. LspDetach is used rather than the client's on_exit
  -- callback because on_exit fires inside a libuv fast event, where the API is off
  -- limits; LspDetach is already scheduled onto the main loop for us.
  --
  -- It also fires for ordinary buffer deletes and for deliberate stops, so the
  -- lsp_connected() guard decides: if any healthy gdscript client survives, nothing
  -- was lost and there is nothing to do.
  vim.api.nvim_create_autocmd("LspDetach", {
    group = group,
    desc = "Godot: notice the GDScript LSP socket dying",
    callback = function(ev)
      if vim.v.exiting ~= vim.NIL then
        return
      end
      local client = vim.lsp.get_client_by_id(ev.data.client_id)
      if not client or client.name ~= SERVER or lsp_connected() then
        return
      end
      -- Disarm rather than leave the config enabled. While Godot is down an armed
      -- config means every newly opened .gd file dials a dead port and earns its own
      -- "Could not connect" warning; disarmed, opening files is silent. connect()
      -- re-arms the instant the port answers.
      if vim.lsp.is_enabled(SERVER) then
        pcall(vim.lsp.enable, SERVER, false)
      end
      cooldown_until = 0
      retry()
    end,
  })

  -- Coming back to the window is the strongest "something changed" signal there is:
  -- it is literally what alt-tabbing out of a restarted Godot looks like. Worth
  -- bypassing the cooldown for.
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    desc = "Godot: re-check the GDScript LSP on focus",
    callback = function()
      connect(true)
    end,
  })

  -- The safety net for terminals that do not report focus, and for the first .gd
  -- file of the session. Gated on filetype so it is a single table lookup on every
  -- other buffer, and on the cooldown so a burst of BufEnter cannot turn into a
  -- burst of probes.
  vim.api.nvim_create_autocmd({ "FileType", "BufEnter", "InsertEnter" }, {
    group = group,
    desc = "Godot: re-check the GDScript LSP when working in GDScript",
    callback = function(ev)
      if vim.bo[ev.buf].filetype == FILETYPE then
        connect(false)
      end
    end,
  })

  -- Manual override, for when you want an answer instead of a guess. Unlike every
  -- automatic path this one reports what happened.
  vim.api.nvim_create_user_command("GodotLspConnect", function()
    connect(true, function(connected)
      if connected then
        vim.notify("Godot LSP: connected", vim.log.levels.INFO)
      else
        vim.notify(
          ("Godot LSP: nothing listening on %s:%d -- is the Godot editor open?"):format(LSP_HOST, LSP_PORT),
          vim.log.levels.WARN
        )
      end
    end)
  end, { desc = "Godot: (re)connect the GDScript LSP now" })

  vim.keymap.set("n", "<leader>cG", "<cmd>GodotLspConnect<cr>", { desc = "Godot LSP Connect" })
end

return {
  -----------------------------------------------------------------------------
  -- 1) LSP -- GDScript language server over TCP
  -----------------------------------------------------------------------------
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        gdscript = {
          -- WHY NOT `cmd = { "nc", "localhost", "6005" }`:
          -- `cmd` as a string[] is a *process* spawn (jobstart semantics). netcat is
          -- only a dumb pipe, so Neovim's LSP client cannot see the socket at all --
          -- it only sees the nc process. If Godot is not listening, nc exits
          -- immediately and the client dies with "quit with exit code 1"; when the
          -- Godot editor restarts, the socket is torn down, nc exits, and the client
          -- dies the same ungraceful way.
          --
          -- The supported form on nvim 0.11+ is `cmd` as a FUNCTION that builds an RPC
          -- client. vim.lsp.rpc.connect(host, port) returns exactly such a factory.
          cmd = vim.lsp.rpc.connect(LSP_HOST, LSP_PORT),

          -- Neovim maps *.gd -> "gdscript" out of the box. (.tscn/.tres are
          -- "gdresource", *.gdshader is "gdshader" -- Godot's LSP serves none of
          -- those, so they are deliberately not listed here.)
          filetypes = { FILETYPE },

          -- root_markers is the nvim 0.11+ replacement for lspconfig's old
          -- `root_dir = util.root_pattern(...)`. Order is priority. Note it is
          -- IGNORED if you also set root_dir, so set only one of the two.
          root_markers = { "project.godot", ".git" },

          -- Covers the ungraceful half of "Godot went away". A clean editor
          -- shutdown closes the socket with a FIN, which Neovim reads as EOF and
          -- turns into a real client exit -- that is the path LspDetach watches. An
          -- *abortive* close (RST: a crashed or SIGKILLed editor) arrives instead as
          -- a READ_ERROR, and Neovim pointedly does NOT tear the transport down for
          -- that: the client would sit there "not stopped" on a dead socket forever,
          -- and every liveness check in this file would believe it.
          on_error = function(code)
            if code ~= vim.lsp.rpc.client_errors.READ_ERROR then
              return
            end
            vim.schedule(function()
              for _, client in ipairs(vim.lsp.get_clients({ name = SERVER })) do
                if not client:is_stopped() then
                  pcall(function()
                    client:stop(true)
                  end)
                end
              end
            end)
          end,
        },
      },

      -- LazyVim's per-server escape hatch: returning true means "I have set this
      -- server up myself", which skips LazyVim's own vim.lsp.config() +
      -- vim.lsp.enable() pair for it.
      --
      -- WHY take it over: we want the config *registered* but not *armed*. If
      -- LazyVim enables gdscript at startup and Godot is not running yet -- the
      -- normal way round, you open the editor after Neovim -- the dial fails, you get
      -- a "Could not connect" warning, and Neovim is left holding a never-initialized
      -- client that poisons every later reconnect (see probe()).
      --
      -- If this ever misbehaves, `:lsp enable gdscript` arms it by hand and you are
      -- back to stock LazyVim behaviour.
      setup = {
        gdscript = function(server, server_opts)
          vim.lsp.config(server, server_opts)
          install_supervisor()
          -- Covers the case where the .gd buffer's FileType already fired while
          -- lazy.nvim was still loading nvim-lspconfig.
          vim.schedule(function()
            connect(true)
          end)
          return true
        end,
      },
    },
  },

  -----------------------------------------------------------------------------
  -- 2) DAP -- debug a running Godot editor's game over TCP
  -----------------------------------------------------------------------------
  -- Requires mfussenegger/nvim-dap, which is NOT part of stock LazyVim; this spec
  -- installs it. `:Lazy sync` after the rebuild will clone it.
  {
    "mfussenegger/nvim-dap",
    -- stylua: ignore
    keys = {
      { "<leader>db", function() require("dap").toggle_breakpoint() end, desc = "Toggle Breakpoint" },
      { "<leader>dB", function() require("dap").set_breakpoint(vim.fn.input("Breakpoint condition: ")) end, desc = "Breakpoint Condition" },
      { "<leader>dc", function() require("dap").continue() end, desc = "Run/Continue" },
      { "<leader>di", function() require("dap").step_into() end, desc = "Step Into" },
      { "<leader>do", function() require("dap").step_out() end, desc = "Step Out" },
      { "<leader>dO", function() require("dap").step_over() end, desc = "Step Over" },
      { "<leader>dr", function() require("dap").repl.toggle() end, desc = "Toggle REPL" },
      { "<leader>dt", function() require("dap").terminate() end, desc = "Terminate" },
    },
    -- `config` (not `opts`): nvim-dap has no setup(), so lazy.nvim's default handler
    -- would call require("dap").setup(opts) and error. If you later import
    -- lazyvim.plugins.extras.dap.core, switch this to `optional = true` +
    -- `opts = function() ... end` or the two `config`s clash silently.
    config = function()
      local dap = require("dap")

      -- type = "server" means "connect to something already listening" rather than
      -- spawning an adapter binary: Godot's editor *is* the debug adapter. No
      -- reconnect logic needed here -- the dial happens per session, so restarting
      -- Godot is repaired by the next <leader>dc.
      dap.adapters.godot = {
        type = "server",
        host = LSP_HOST,
        port = DAP_PORT,
      }

      -- Key must match the buffer filetype: "gdscript".
      -- Mandatory per entry (nvim-dap): `type`, `request`, `name`.
      --
      -- Godot 4.7 reads only `project` and `scene` from a launch request:
      --   scene = "main"    -> the project's main scene (Godot's default)
      --   scene = "current" -> the scene currently open in the editor
      --   scene = <path>    -> e.g. "res://levels/test.tscn"
      -- The `launch_scene = true` field still shown in the nvim-dap wiki is a
      -- leftover from the old godot-vscode-plugin debugger; Godot's DAP never
      -- reads it, so it is silently ignored. Use `scene` instead.
      dap.configurations.gdscript = {
        {
          type = "godot",
          request = "launch",
          name = "Launch main scene",
          project = godot_project_root,
          scene = "main",
        },
        {
          type = "godot",
          request = "launch",
          name = "Launch current scene",
          project = godot_project_root,
          scene = "current",
        },
      }
      -- Deliberately no request = "attach": Godot's req_attach errors with
      -- NOT_RUNNING unless a debug session is already live.
    end,
  },
}
