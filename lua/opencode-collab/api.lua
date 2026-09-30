local M = {}

local function request(cfg, method, path, body, callback)
	local cmd
	if cfg.url and cfg.url ~= "" then
		local url = cfg.url:gsub("/+$", "") .. path
		cmd = { "curl", "-sS", "-X", method, url, "-H", "content-type: application/json" }
		if body then
			vim.list_extend(cmd, { "-d", vim.json.encode(body) })
		end
	else
		if method == "GET" then
			cmd = { "opencode", "api", "get", path }
		elseif method == "POST" then
			cmd = { "opencode", "api", "post", path }
			if body then
				vim.list_extend(cmd, { "--data", vim.json.encode(body) })
			end
		else
			return callback(false, "Unsupported HTTP method: " .. method)
		end
	end

	vim.system(cmd, { text = true }, function(obj)
		vim.schedule(function()
			if obj.code ~= 0 then
				local err = obj.stderr and obj.stderr ~= "" and obj.stderr or ("Process exited with code " .. obj.code)
				return callback(false, err)
			end
			local ok, decoded = pcall(vim.json.decode, obj.stdout or "")
			callback(true, ok and decoded or obj.stdout)
		end)
	end)
end

function M.resolve_session(cfg, cwd, callback)
	if cfg.session_id and cfg.session_id ~= "" then
		return callback(cfg.session_id, nil)
	end

	local path = "/api/session?directory=" .. vim.uri_encode(cwd) .. "&limit=5"
	request(cfg, "GET", path, nil, function(ok, res)
		if not ok or type(res) ~= "table" then
			return callback(nil, "Failed to query sessions: " .. tostring(res))
		end

		local sessions = res.data or res
		if type(sessions) ~= "table" or #sessions == 0 then
			return callback(nil, "No sessions found for cwd: " .. cwd)
		end

		local best_id = nil
		local best_time = -1

		for _, s in ipairs(sessions) do
			local s_dir = (s.location and s.location.directory) or s.directory
			if s_dir == cwd then
				local t = (s.time and s.time.updated) or 0
				if t > best_time then
					best_time = t
					best_id = s.id
				end
			end
		end

		-- If none exactly matched the directory check, fallback to first returned session
		local chosen = best_id or (sessions[1] and sessions[1].id)
		if not chosen then
			return callback(nil, "Could not determine session ID")
		end

		callback(chosen, nil)
	end)
end

function M.send_synthetic(cfg, session_id, payload, callback)
	local path = "/api/session/" .. session_id .. "/synthetic"
	request(cfg, "POST", path, payload, function(ok, res)
		if ok then
			callback(true, nil)
		else
			callback(false, tostring(res))
		end
	end)
end

return M
