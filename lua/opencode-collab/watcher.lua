local core = require("opencode-collab.core")
local api = require("opencode-collab.api")

local M = {}

local baseline = {} -- path -> string (last known content to agent)
local pending = {} -- path -> true (files waiting for debounce flush)
local timer = nil
local cfg = core.default_config

local function buf_text(buf)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	return table.concat(lines, "\n") .. "\n"
end

local function flush()
	timer = nil
	local chunks, paths = {}, {}
	local cwd = (vim.uv or vim.loop).cwd()

	for path in pairs(pending) do
		local buf = vim.fn.bufnr(path)
		if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
			local new_text = buf_text(buf)
			local old_text = baseline[path] or ""
			if old_text ~= new_text then
				local diff = core.make_diff(old_text, new_text, cfg.max_bytes)
				if diff then
					table.insert(chunks, { path = core.rel_path(path), diff = diff })
					table.insert(paths, { path = path, text = new_text })
				end
			end
		end
	end

	pending = {}
	if #chunks == 0 then
		return
	end

	local text = core.format_burst(chunks, cfg.max_files_per_burst)
	local payload = core.create_synthetic_payload(text)

	api.resolve_session(cfg, cwd, function(session_id, err)
		if not session_id then
			vim.schedule(function()
				vim.notify("OpenCode Collab: " .. (err or "No active session"), vim.log.levels.WARN)
			end)
			return
		end

		api.send_synthetic(cfg, session_id, payload, function(ok, send_err)
			vim.schedule(function()
				if ok then
					for _, p in ipairs(paths) do
						baseline[p.path] = p.text
					end
					local summary = #chunks == 1 and chunks[1].path
						or string.format("%d files", #chunks)
					vim.notify(
						string.format("OpenCode Collab: Steered diff for %s", summary),
						vim.log.levels.INFO
					)
				else
					-- Keep baseline unchanged so the next save re-diffs against what the agent last knew
					vim.notify("OpenCode Collab: Send failed: " .. tostring(send_err), vim.log.levels.WARN)
				end
			end)
		end)
	end)
end

local function schedule_flush()
	local uv = vim.uv or vim.loop
	if timer then
		timer:stop()
	else
		timer = uv.new_timer()
	end
	timer:start(cfg.debounce_ms, 0, vim.schedule_wrap(flush))
end

function M.setup(config)
	cfg = vim.tbl_deep_extend("force", core.default_config, config or {})
	vim.o.autoread = true

	local cwd = (vim.uv or vim.loop).cwd()
	local group = vim.api.nvim_create_augroup("OpenCodeCollab", { clear = true })

	-- Initialize baseline for any currently loaded buffers
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) then
			local path = vim.api.nvim_buf_get_name(buf)
			if core.is_tracked(path, cwd, vim.bo[buf].buftype, cfg.ignore) then
				baseline[path] = buf_text(buf)
			end
		end
	end

	-- Initial / Re-baseline: what Neovim reads from disk is what the agent knows
	vim.api.nvim_create_autocmd({ "BufReadPost", "FileChangedShellPost" }, {
		group = group,
		callback = function(args)
			local path = vim.api.nvim_buf_get_name(args.buf)
			if core.is_tracked(path, cwd, vim.bo[args.buf].buftype, cfg.ignore) then
				baseline[path] = buf_text(args.buf)
			end
		end,
	})

	-- User manual save: schedule debounced flush
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		callback = function(args)
			local path = vim.api.nvim_buf_get_name(args.buf)
			if not core.is_tracked(path, cwd, vim.bo[args.buf].buftype, cfg.ignore) then
				return
			end
			if baseline[path] == nil then
				baseline[path] = ""
				if vim.fn.getfsize(path) == 0 then
					return
				end
			end
			pending[path] = true
			schedule_flush()
		end,
	})

	-- Promptly reload files modified by agent so they re-baseline without conflict
	vim.api.nvim_create_autocmd({ "FocusGained", "CursorHold", "BufEnter" }, {
		group = group,
		command = "silent! checktime",
	})

	-- Flush any pending edits on exit
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			if timer then
				timer:stop()
				timer = nil
			end
			flush()
		end,
	})
end

function M.set_session(session_id)
	cfg.session_id = session_id
end

function M.get_session()
	return cfg.session_id
end

return M
