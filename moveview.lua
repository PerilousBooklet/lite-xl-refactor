-- Shows, before a file/folder move actually happens, every import/require
-- reference across the project that the move would rewrite -- the same
-- checkbox-and-curtain list as RefactorView (find & replace), but for
-- reviewing/pruning an import rewrite instead of a text replacement.
-- Nothing on disk changes until the button at the bottom is pressed; the
-- move (and only the still-selected rewrites) then happens via
-- movefile.perform.

local core = require "core"
local common = require "core.common"
local style = require "core.style"
local viewutils = require "plugins.refactor.viewutils"
local MatchListView = require "plugins.refactor.matchlistview"

local MoveView = MatchListView:extend()

-- splits `a` and `b` (assumed to differ somewhere) into a common leading
-- part, the bit that actually changed, and a common trailing part -- e.g.
-- "./old/foo.lua" vs "./new/foo.lua" -> prefix "./", a_mid "old",
-- b_mid "new", suffix "/foo.lua" -- so only the bit that changed needs
-- to be highlighted, not the whole import string
local function diff_parts(a, b)
  local max_prefix = math.min(#a, #b)
  local prefix_len = 0
  while prefix_len < max_prefix
      and a:sub(prefix_len + 1, prefix_len + 1) == b:sub(prefix_len + 1, prefix_len + 1) do
    prefix_len = prefix_len + 1
  end

  local max_suffix = math.min(#a, #b) - prefix_len
  local suffix_len = 0
  while suffix_len < max_suffix
      and a:sub(#a - suffix_len, #a - suffix_len) == b:sub(#b - suffix_len, #b - suffix_len) do
    suffix_len = suffix_len + 1
  end

  local common_prefix = a:sub(1, prefix_len)
  local common_suffix = a:sub(#a - suffix_len + 1)
  local a_mid = a:sub(prefix_len + 1, #a - suffix_len)
  local b_mid = b:sub(prefix_len + 1, #b - suffix_len)

  return common_prefix, a_mid, common_suffix, b_mid
end

function MoveView:__tostring() return "MoveView" end

-- `preview` is the table returned by movefile.preview(old_rel, new_rel):
--   { old_rel, new_rel, moving_dir, moved_has_known_language,
--     files = { { filename, matches = { { line, col, len, old_import,
--     new_import, line_text, selected }, ... } }, ... } }
function MoveView:new(preview)
  MoveView.super.new(self)

  self.checkboxes = false

  self.old_rel = preview.old_rel
  self.new_rel = preview.new_rel
  self.moving_dir = preview.moving_dir
  self.moved_has_known_language = preview.moved_has_known_language
  self.results = preview.files

  core.status_view:show_message("i", style.text,
    "click a file to expand it, click a line to jump to it, then hit Move")
end

function MoveView:get_name()
  return "Move: " .. self.old_rel .. " -> " .. self.new_rel
end

-- ---------------------------------------------------------------------------
-- drawing
-- ---------------------------------------------------------------------------

function MoveView:draw_match_row(item, match, x, y, w, h, tx, cb_y)
  local lineno = tostring(match.line) .. ": "
  tx = common.draw_text(self.font, style.dim, lineno, "left", tx, y, w, h)

  local col = match.col or 1
  local old_len = #match.old_import
  local prefix = match.line_text:sub(1, col - 1)
  local suffix = match.line_text:sub(col + old_len)

  local common_prefix, old_mid, common_suffix, new_mid = diff_parts(match.old_import, match.new_import)

  tx = common.draw_text(self.font, style.text, prefix, "left", tx, y, w, h)

  tx = common.draw_text(self.font, style.text, common_prefix, "left", tx, y, w, h)
  tx = viewutils.draw_highlighted(self.font, old_mid, tx, y, h, viewutils.RED_BG, viewutils.HIGHLIGHT_FG)
  tx = viewutils.draw_highlighted(self.font, new_mid, tx, y, h, viewutils.GREEN_BG, viewutils.HIGHLIGHT_FG)
  tx = common.draw_text(self.font, style.text, common_suffix, "left", tx, y, w, h)

  common.draw_text(self.font, style.text, suffix, "left", tx, y, w, h)
end

-- ---------------------------------------------------------------------------
-- bottom button
-- ---------------------------------------------------------------------------

function MoveView:get_button_label()
  local _, total = self:count_selected()
  if total == 0 then
    return "Move (no references to update)"
  end
  return string.format("Move & update %d reference%s",
    total, total == 1 and "" or "s")
end

function MoveView:on_button_pressed()
  -- required lazily rather than at file scope: movefile.lua requires
  -- this file to open it, so requiring movefile back at the top of this
  -- file would be a require cycle. By the time a button click can
  -- happen, both modules have long since finished loading, so this is
  -- safe.
  local movefile = require "plugins.refactor.movefile"

  -- no checkboxes here, so there's nothing to deselect -- every detected
  -- reference gets updated, same as calling perform() with no preview at all
  movefile.perform(self.old_rel, self.new_rel)
end

return MoveView
