local M = {}

M.default_config = {
	url = vim.env.OPENCODE_URL, -- nil defaults to `opencode api` CLI
	session_id = nil, -- override to pin a specific session
	debounce_ms = 1500,
	max_bytes = 8000,
	max_files_per_burst = 5,
	ignore = { "%.git/", "node_modules/", "%.opencode/" },
}

--- Check if a file should be tracked
function M.is_tracked(path, cwd, buftype, ignore_patterns)
	if not path or path == "" then
		return false
	end
	if buftype and buftype ~= "" then
		return false
	end
	local abs_path = vim.fn.fnamemodify(path, ":p")
	if not vim.startswith(abs_path, cwd) then
		return false
	end
	ignore_patterns = ignore_patterns or M.default_config.ignore
	for _, pat in ipairs(ignore_patterns) do
		if abs_path:find(pat) then
			return false
		end
	end
	return true
end

--- Get relative path to cwd
function M.rel_path(path)
	return vim.fn.fnamemodify(path, ":.")
end

--- Generate unified diff between old_text and new_text
function M.make_diff(old_text, new_text, max_bytes)
	if old_text == new_text then
		return nil
	end
	local d = vim.text.diff(old_text, new_text, { result_type = "unified", ctxlen = 3 })
	if not d or d == "" then
		return nil
	end
	max_bytes = max_bytes or M.default_config.max_bytes
	if #d > max_bytes then
		d = d:sub(1, max_bytes) .. "\n... [diff truncated; run `git diff` or re-read the file]"
	end
	return d
end

function M.wrap_file_edit(rel_path, diff)
	return string.format(
		'<user-file-edit path="%s">\n'
			.. "The user edited this file manually in their editor. Treat the change as likely intentional and authoritative, and add it to your mental model. Re-read the file before editing it and do not revert these changes."
			.. "\n%s\n</user-file-edit>",
		rel_path,
		diff
	)
end

function M.format_burst(chunks, max_files_per_burst)
	if not chunks or #chunks == 0 then
		return nil
	end
	max_files_per_burst = max_files_per_burst or M.default_config.max_files_per_burst
	if #chunks > max_files_per_burst then
		local names = {}
		for _, c in ipairs(chunks) do
			table.insert(names, c.path)
		end
		return string.format(
			"<user-file-edit>\nThe user manually edited %d files (not via your tools): %s.\n"
				.. "Treat as intentional; re-read before editing and do not revert.\n</user-file-edit>",
			#chunks,
			table.concat(names, ", ")
		)
	end

	local parts = {}
	for _, c in ipairs(chunks) do
		table.insert(parts, M.wrap_file_edit(c.path, c.diff))
	end
	return table.concat(parts, "\n\n")
end

function M.create_synthetic_payload(text)
	return {
		text = text,
		delivery = "steer",
		resume = false, -- Never wake up the agent based on file saves
		metadata = { source = "opencode-collab" },
	}
end

return M
