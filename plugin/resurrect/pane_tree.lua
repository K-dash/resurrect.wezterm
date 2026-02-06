local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local utils = require("resurrect.utils")

---@class pane_tree_module
---@field max_nlines integer
local pub = {}
pub.max_nlines = 3500

---@alias Pane any
---@alias PaneInformation {left: integer, top: integer, height: integer, width: integer}
---@alias pane_tree {left: integer, top: integer, height: integer, width: integer, bottom: pane_tree?, right: pane_tree?, text: string, cwd: string, domain?: string, process?: local_process_info?, pane: Pane?, is_active: boolean, is_zoomed: boolean, alt_screen_active: boolean}
---@alias local_process_info {name: string, argv: string[], cwd: string, executable: string}

---compare function returns true if a is more left than b
---@param a PaneInformation
---@param b PaneInformation
---@return boolean
local function compare_pane_by_coord(a, b)
	if a.left == b.left then
		return a.top < b.top
	else
		return a.left < b.left
	end
end

---@param root PaneInformation
---@param pane PaneInformation
---@return boolean
local function is_right(root, pane)
	if root.left + root.width < pane.left then
		return true
	end
	return false
end

---@param root PaneInformation
---@param pane PaneInformation
---@return boolean
local function is_bottom(root, pane)
	if root.top + root.height < pane.top then
		return true
	end
	return false
end

---@param root pane_tree
---@param panes PaneInformation
---@return pane_tree | nil
local function pop_connected_bottom(root, panes)
	for i, pane in ipairs(panes) do
		if root.left == pane.left and root.top + root.height + 1 == pane.top then
			table.remove(panes, i)
			return pane
		end
	end
end

---@param root pane_tree
---@param panes PaneInformation
---@return pane_tree | nil
local function pop_connected_right(root, panes)
	for i, pane in ipairs(panes) do
		if root.top == pane.top and root.left + root.width + 1 == pane.left then
			table.remove(panes, i)
			return pane
		end
	end
end

--- Pre-extract pane metadata into each PaneInformation table directly,
--- so that even after .pane is set to nil on a shared reference, the
--- saved fields (domain, cwd, text, etc.) remain accessible.
---@param panes PaneInformation[]
local function pre_extract_all_pane_info(panes)
	for _, p in ipairs(panes) do
		if p.pane and not p._pane_info_extracted then
			local domain = p.pane:get_domain_name()
			local spawnable = wezterm.mux.get_domain(domain):is_spawnable()
			p._pane_info_extracted = true
			p._spawnable = spawnable

			if not spawnable then
				p._domain = domain
			else
				p._domain = domain

				local cwd_obj = p.pane:get_current_working_dir()
				if not cwd_obj then
					p._cwd = ""
				else
					p._cwd = cwd_obj.file_path
					if utils.is_windows then
						p._cwd = p._cwd:gsub("^/([a-zA-Z]):", "%1:")
					end
				end

				if domain == "local" then
					p._alt_screen_active = p.pane:is_alt_screen_active()
					if p._alt_screen_active then
						local process_info = p.pane:get_foreground_process_info()
						process_info.children = nil
						process_info.pid = nil
						process_info.ppid = nil
						p._process = process_info
					else
						local nlines = p.pane:get_dimensions().scrollback_rows
						if nlines > pub.max_nlines then
							nlines = pub.max_nlines
						end
						p._text = p.pane:get_lines_as_escapes(nlines)
					end
				end
			end
		end
	end
end

---@param root pane_tree | nil
---@param panes PaneInformation[]
---@return pane_tree | nil
local function insert_panes(root, panes)
	if root == nil then
		return nil
	end

	-- Use pre-extracted info (works even if .pane was nilled by a sibling subtree)
	if root._pane_info_extracted then
		if not root._spawnable then
			wezterm.log_warn("Domain " .. (root._domain or "?") .. " is not spawnable")
			wezterm.emit("resurrect.error", "Domain " .. (root._domain or "?") .. " is not spawnable")
		else
			root.domain = root._domain
			root.cwd = root._cwd
			root.alt_screen_active = root._alt_screen_active
			root.process = root._process
			root.text = root._text
		end
	elseif root.pane == nil then
		wezterm.log_warn("resurrect: skipping pane with nil pane field and no cached info")
		return nil
	end

	-- Clean up internal fields
	root.pane = nil
	root._pane_info_extracted = nil
	root._spawnable = nil
	root._domain = nil
	root._cwd = nil
	root._alt_screen_active = nil
	root._process = nil
	root._text = nil

	if #panes == 0 then
		return root
	end

	local right, bottom = {}, {}
	for _, pane in ipairs(panes) do
		if is_right(root, pane) then
			table.insert(right, pane)
		end
		if is_bottom(root, pane) then
			table.insert(bottom, pane)
		end
	end

	if #right > 0 then
		local right_child = pop_connected_right(root, right)
		root.right = insert_panes(right_child, right)
	end

	if #bottom > 0 then
		local bottom_child = pop_connected_bottom(root, bottom)
		root.bottom = insert_panes(bottom_child, bottom)
	end

	return root
end

---Create a pane tree from a list of PaneInformation
---@param panes PaneInformation
---@return pane_tree | nil
function pub.create_pane_tree(panes)
	-- Pre-extract all pane info before tree construction so that
	-- shared references (same pane in both right and bottom) don't
	-- lose their metadata when .pane gets nilled out.
	pre_extract_all_pane_info(panes)
	table.sort(panes, compare_pane_by_coord)
	local root = table.remove(panes, 1)
	return insert_panes(root, panes)
end

---maps over the pane tree
---@param pane_tree pane_tree
---@param f fun(pane_tree: pane_tree): pane_tree
---@return nil
function pub.map(pane_tree, f)
	if pane_tree == nil then
		return nil
	end

	pane_tree = f(pane_tree)
	if pane_tree.right then
		pub.map(pane_tree.right, f)
	end
	if pane_tree.bottom then
		pub.map(pane_tree.bottom, f)
	end

	return pane_tree
end

function pub.fold(pane_tree, acc, f)
	if pane_tree == nil then
		return acc
	end

	acc = f(acc, pane_tree)
	if pane_tree.right then
		acc = pub.fold(pane_tree.right, acc, f)
	end
	if pane_tree.bottom then
		acc = pub.fold(pane_tree.bottom, acc, f)
	end

	return acc
end

return pub
