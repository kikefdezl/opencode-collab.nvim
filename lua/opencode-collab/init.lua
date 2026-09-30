local watcher = require("opencode-collab.watcher")

local M = {}

function M.setup(opts)
	watcher.setup(opts)

	vim.api.nvim_create_user_command("OpenCodeCollabSession", function(args)
		local session_id = args.args ~= "" and args.args or nil
		watcher.set_session(session_id)
		vim.notify("OpenCode Collab session: " .. (session_id or "auto (by cwd)"), vim.log.levels.INFO)
	end, {
		nargs = "?",
		desc = "Pin or clear the OpenCode Collab session ID",
	})
end

return M
