-- A View (modeled directly on core/logview.lua) that shows the results of a
-- project-wide (or folder-scoped) "find" as a list of files. Each file row
-- can be clicked to unroll a "curtain" showing every matching line inside
-- that file. Both file rows and individual match rows have a small
-- checkbox at the start of the row that toggles whether that file/line
-- should be included when the replacement is finally applied via the
-- button drawn at the bottom of the view.
--
-- The generic scrolling/zoom/checkbox/curtain machinery all lives in
-- matchlistview.lua now (shared with MoveView); this file only supplies
-- what's specific to find & replace: running the search, drawing the
-- red/green match-vs-replacement highlighting, and applying the edits.

local core = require "core"
local common = require "core.common"
local style = require "core.style"
local fsutils = require "plugins.refactor.fsutils"
local viewutils = require "plugins.refactor.viewutils"
local MatchListView = require "plugins.refactor.matchlistview"

-- escapes a plain string so it can be safely used as a Lua pattern
local function escape_pattern(text)
  return (text:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1"))
end

-- escapes a plain replacement string so gsub doesn't treat "%" specially
local function escape_replacement(text)
  return (text:gsub("%%", "%%%%"))
end

-- ---------------------------------------------------------------------------
-- RefactorView
-- ---------------------------------------------------------------------------

local RefactorView = MatchListView:extend()

function RefactorView:__tostring() return "RefactorView" end

-- `scope_dir`, if given, is a project-relative folder path; the search
-- (and eventual replacement) is limited to files nested under it. nil
-- means "search the whole project", same as before.
function RefactorView:new(find_text, replace_text, scope_dir)
  RefactorView.super.new(self)

  self.find_text = find_text
  self.replace_text = replace_text or ""
  self.scope_dir = scope_dir

  self.searching = true
  self.files_scanned = 0
  self.files_total = 0

  core.status_view:show_message("i", style.text,
    self.scope_dir
      and ("click a file to expand it, click a square to (de)select, then hit Replace (scoped to " .. self.scope_dir .. ")")
      or "click a file to expand it, click a square to (de)select, then hit Replace")

  self:begin_search()
end

function RefactorView:get_name()
  if self.scope_dir then
    return "Refactor: " .. self.find_text .. " (in " .. self.scope_dir .. ")"
  end
  return "Refactor: " .. self.find_text
end

-- ---------------------------------------------------------------------------
-- drawing
-- ---------------------------------------------------------------------------

function RefactorView:draw_match_row(item, match, x, y, w, h, tx, cb_y)
  local lineno = tostring(match.line) .. ": "
  tx = common.draw_text(self.font, style.dim, lineno, "left", tx, y, w, h)

  local col = match.col or 1
  local find_len = #self.find_text
  local prefix = match.text:sub(1, col - 1)
  local matched = match.text:sub(col, col + find_len - 1)
  local suffix = match.text:sub(col + find_len)

  tx = common.draw_text(self.font, style.text, prefix, "left", tx, y, w, h)
  tx = viewutils.draw_highlighted(self.font, matched, tx, y, h, viewutils.RED_BG, viewutils.HIGHLIGHT_FG)
  tx = viewutils.draw_highlighted(self.font, self.replace_text, tx, y, h, viewutils.GREEN_BG, viewutils.HIGHLIGHT_FG)
  common.draw_text(self.font, style.text, suffix, "left", tx, y, w, h)
end

function RefactorView:draw()
  RefactorView.super.draw(self)
  if self.searching then
    local msg = string.format("searching... (%d/%d files, %d matches)",
      self.files_scanned, self.files_total, #self.results)
    core.status_view:show_message("i", style.text, msg)
  end
end

-- ---------------------------------------------------------------------------
-- bottom button
-- ---------------------------------------------------------------------------

function RefactorView:get_button_label()
  local selected, total = self:count_selected()
  return string.format("Replace %d/%d selected match%s",
    selected, total, total == 1 and "" or "es")
end

function RefactorView:on_button_pressed()
  self:apply_replacement()
end

-- ---------------------------------------------------------------------------
-- searching the project
-- ---------------------------------------------------------------------------

local function is_probably_binary(chunk)
  return chunk:find("\0", 1, true) ~= nil
end

-- delegates to fsutils so this listing logic is shared with movefile.lua
-- instead of being duplicated in two places. `scope_dir`, if given,
-- limits the listing to that project-relative folder.
local function collect_project_files(scope_dir)
  return fsutils.collect_project_files(scope_dir)
end

function RefactorView:begin_search()
  local view = self
  core.add_thread(function()
    local files = collect_project_files(view.scope_dir)
    view.files_total = #files

    for _, relname in ipairs(files) do
      view.files_scanned = view.files_scanned + 1

      local abs = relname
      if core.project_dir and not relname:find("^/") and not relname:find("^%a:[/\\]") then
        abs = core.project_dir .. PATHSEP .. relname
      end

      local fp = io.open(abs, "rb")
      if fp then
        local head = fp:read(4096) or ""
        if not is_probably_binary(head) then
          fp:seek("set", 0)
          local content = fp:read("*a") or ""
          fp:close()

          local matches = {}
          local lineno = 0
          for line in (content .. "\n"):gmatch("([^\n]*)\n") do
            lineno = lineno + 1
            local col = line:find(view.find_text, 1, true)
            if col then
              table.insert(matches, {
                line = lineno,
                col = col,
                text = line,
                selected = true,
                len = #view.find_text,
              })
            end
          end

          if #matches > 0 then
            table.insert(view.results, {
              filename = relname,
              matches = matches,
            })
          end
        else
          fp:close()
        end
      end

      if view.files_scanned % 20 == 0 then
        coroutine.yield()
      end
    end

    view.searching = false
    core.status_view:show_message("i", style.text,
      string.format("found %d matches in %d files", (function()
        local n = 0
        for _, item in ipairs(view.results) do n = n + #item.matches end
        return n
      end)(), #view.results))
  end)
end

-- ---------------------------------------------------------------------------
-- applying the replacement
-- ---------------------------------------------------------------------------

function RefactorView:apply_replacement()
  if self.searching then
    core.status_view:show_message("!", style.text, "still searching, please wait")
    return
  end

  local files_changed = 0
  local matches_changed = 0

  for _, item in ipairs(self.results) do
    local any_selected = false
    for _, match in ipairs(item.matches) do
      if match.selected then any_selected = true end
    end

    if any_selected then
      local abs = item.filename
      if core.project_dir and not abs:find("^/") and not abs:find("^%a:[/\\]") then
        abs = core.project_dir .. PATHSEP .. item.filename
      end

      local fp = io.open(abs, "rb")
      if fp then
        local content = fp:read("*a") or ""
        fp:close()

        local lineno = 0
        local out = {}
        for line in (content .. "\n"):gmatch("([^\n]*)\n") do
          lineno = lineno + 1
          local replaced = line
          for _, match in ipairs(item.matches) do
            if match.line == lineno and match.selected then
              replaced = replaced:gsub(
                escape_pattern(self.find_text),
                escape_replacement(self.replace_text)
              )
              matches_changed = matches_changed + 1
            end
          end
          table.insert(out, replaced)
        end
        -- gmatch with the trailing "\n" trick above adds one extra empty
        -- line at the end; drop it to preserve the original file ending.
        if out[#out] == "" and content:sub(-1) ~= "\n" then
          table.remove(out)
        end

        local new_content = table.concat(out, "\n")
        if content:sub(-1) == "\n" then
          new_content = new_content .. "\n"
        end

        local wf = io.open(abs, "wb")
        if wf then
          wf:write(new_content)
          wf:close()
          files_changed = files_changed + 1

          -- if the file is already open in an editor, reload it from disk
          for _, doc in ipairs(core.docs) do
            if doc.filename == item.filename or doc.abs_filename == abs then
              doc:reload()
            end
          end
        end
      end
    end
  end

  core.status_view:show_message("i", style.text,
    string.format("replaced %d match(es) across %d file(s)", matches_changed, files_changed))
end

return RefactorView
