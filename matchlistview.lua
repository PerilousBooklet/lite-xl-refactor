-- Generic scrollable "list of files -> expandable list of matches" view,
-- where every file and every match has a small checkbox toggling whether
-- it's included when some final action (a button drawn at the bottom of
-- the view) gets triggered. This used to be the entire body of
-- RefactorView; it's pulled out here so RefactorView (find & replace
-- preview) and MoveView (import-rewrite preview before a file move) can
-- share it instead of duplicating a few hundred lines of scrolling, zoom,
-- checkbox, and curtain-expand plumbing.
--
-- A subclass must, at minimum:
--   * populate self.results as { { filename = str, matches = { {
--       selected = bool, line = n, col = n, len = n, ... }, ... } }, ... }
--     (extra per-match fields are fine -- draw_match_row is the only
--     thing that needs to understand them)
--   * override :draw_match_row(item, match, x, y, w, h, tx, cb_y)
--   * override :get_button_label() and :on_button_pressed()
--   * override :get_name() (and :__tostring(), same as any View)
--
-- It may optionally override :draw_file_row (a sensible default -- a
-- checkbox, an expand/collapse chevron, and "filename (N)" -- is provided)
-- and :open_match (default: opens item.filename and selects
-- match.line, columns match.col to match.col + match.len, which is what
-- both current subclasses want).

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local View = require "core.view"
local keymap = require "core.keymap"
local viewutils = require "plugins.refactor.viewutils"

local MatchListView = View:extend()

MatchListView.context = "session"

function MatchListView:__tostring() return "MatchListView" end

function MatchListView:new()
  MatchListView.super.new(self)
  self.scrollable = true
  self.yoffset = 0

  -- list of { filename = str, matches = { {selected=bool, line=n, ...}, ... } }
  self.results = {}

  -- per-item animation state, keyed by the item table itself (weak keys so
  -- entries disappear along with the item)
  self.item_heights = setmetatable({}, { __mode = "k" })
  self.expanding = {}

  -- expand/collapse state, kept separate from item_heights (see
  -- get_item_height/toggle_expand) so it survives the item_heights cache
  -- being dropped whenever the view is zoomed
  self.expanded_state = setmetatable({}, { __mode = "k" })

  -- an independent copy of style.font, so this view can be zoomed with
  -- ctrl+scroll without resizing the font used by the rest of the editor
  self.base_font_size = style.font:get_size()
  self.font = style.font:copy(self.base_font_size)
  self.zoom = 1.0
  self.checkbox_size = math.floor(self.font:get_height() * 0.8)

  self.button_height = self.font:get_height() + style.padding.y * 2
  self.button_hovered = false
  self.button_pressed = false

  -- when false, no checkbox is drawn or hit-tested on either file or
  -- match rows -- clicking a row always expands/opens it instead of
  -- toggling selection, and every match is implicitly included
  self.checkboxes = true
end

-- ---------------------------------------------------------------------------
-- item height / expand-collapse
-- ---------------------------------------------------------------------------

function MatchListView:get_item_height(item)
  local h = self.item_heights[item]
  local lh = self.font:get_height() + style.padding.y
  if not h then
    h = {}
    h.normal = lh
    h.expanded = lh + #item.matches * lh
    local start_expanded = self.expanded_state[item]
    h.current = start_expanded and h.expanded or h.normal
    h.target = h.current
    self.item_heights[item] = h
  end
  return h
end

function MatchListView:is_item_expanded(item)
  local h = self:get_item_height(item)
  return h.target == h.expanded
end

function MatchListView:toggle_expand(item)
  local h = self:get_item_height(item)

  -- drop any pending expand/collapse animation already queued for this item
  for i = #self.expanding, 1, -1 do
    if self.expanding[i] == h then
      table.remove(self.expanding, i)
    end
  end

  if h.target == h.expanded then
    -- collapsing: snap shut immediately so the lines disappear right away
    -- instead of lingering on screen while slowly shrinking
    h.target = h.normal
    h.current = h.normal
    self.expanded_state[item] = false
  else
    -- expanding: keep the smooth grow animation
    h.target = h.expanded
    table.insert(self.expanding, h)
    self.expanded_state[item] = true
  end
end

-- ---------------------------------------------------------------------------
-- iterate every visible row (both file-header rows and, if a file is
-- expanded, its match rows) -- used by both draw() and mouse handling.
-- ---------------------------------------------------------------------------

function MatchListView:each_visible_row()
  local x, y = self:get_content_offset()
  y = y + style.padding.y + self.yoffset
  local lh = self.font:get_height() + style.padding.y
  return coroutine.wrap(function()
    for i, item in ipairs(self.results) do
      local h = self:get_item_height(item)
      coroutine.yield("file", item, nil, x, y, self.size.x, lh)
      local rest = h.current - lh
      if rest > 0 then
        local ly = y + lh
        for _, match in ipairs(item.matches) do
          coroutine.yield("match", item, match, x, ly, self.size.x, lh)
          ly = ly + lh
        end
      end
      y = y + h.current
    end
  end)
end

-- ---------------------------------------------------------------------------
-- selection helpers
-- ---------------------------------------------------------------------------

local function file_all_selected(item)
  for _, match in ipairs(item.matches) do
    if not match.selected then return false end
  end
  return #item.matches > 0
end

local function set_file_selected(item, value)
  for _, match in ipairs(item.matches) do
    match.selected = value
  end
end

-- selected/total match counts across every file -- used by the default
-- button label, and available to subclasses that want their own wording
function MatchListView:count_selected()
  local total, selected = 0, 0
  for _, item in ipairs(self.results) do
    for _, match in ipairs(item.matches) do
      total = total + 1
      if match.selected then selected = selected + 1 end
    end
  end
  return selected, total
end

-- ---------------------------------------------------------------------------
-- scrolling
-- ---------------------------------------------------------------------------

-- reserve room at the bottom of the view for the action button
function MatchListView:get_content_bounds()
  local x, y = self:get_content_offset()
  return x, y, self.size.x, self.size.y - self.button_height
end

function MatchListView:get_scrollable_size()
  local _, y_off = self:get_content_offset()
  local last_y, last_h = y_off, 0
  for _, item, match, x, y, w, h in self:each_visible_row() do
    last_y, last_h = y, h
  end
  if not config.scroll_past_end then
    return last_y + last_h - y_off + style.padding.y
  end
  return last_y + self.size.y - y_off
end

-- ---------------------------------------------------------------------------
-- bottom button
-- ---------------------------------------------------------------------------

function MatchListView:get_button_rect()
  local x = self.position.x
  local y = self.position.y + self.size.y - self.button_height
  return x, y, self.size.x, self.button_height
end

-- subclasses are expected to override these two
function MatchListView:get_button_label()
  local selected, total = self:count_selected()
  return string.format("%d/%d selected", selected, total)
end

function MatchListView:on_button_pressed()
end

-- ---------------------------------------------------------------------------
-- zoom (ctrl+scroll-wheel, local to this view)
-- ---------------------------------------------------------------------------

local MIN_ZOOM = 0.5
local MAX_ZOOM = 3.0
local ZOOM_STEP = 0.1

function MatchListView:set_zoom(new_zoom)
  new_zoom = common.clamp(new_zoom, MIN_ZOOM, MAX_ZOOM)
  if new_zoom == self.zoom then return end

  self.zoom = new_zoom
  self.font:set_size(self.base_font_size * self.zoom)
  self.checkbox_size = math.floor(self.font:get_height() * 0.8)
  self.button_height = self.font:get_height() + style.padding.y * 2

  if self.icon_font then
    self.icon_font:set_size(self.icon_base_size * self.zoom)
  end

  -- row heights were computed against the old font size; drop the cache
  -- so each_visible_row/get_item_height recompute them against the new
  -- font on the next frame. expand/collapse state itself lives in
  -- expanded_state (not item_heights), so it's unaffected by this reset.
  self.item_heights = setmetatable({}, { __mode = "k" })
  self.expanding = {}
end

-- ctrl+scroll zooms just this view; plain scroll falls through to the
-- normal View scrolling behavior untouched
function MatchListView:on_mouse_wheel(y, ...)
  if keymap.modkeys["ctrl"] then
    self:set_zoom(self.zoom + (y > 0 and ZOOM_STEP or -ZOOM_STEP))
    return true
  end
  return MatchListView.super.on_mouse_wheel(self, y, ...)
end

-- ---------------------------------------------------------------------------
-- mouse handling
-- ---------------------------------------------------------------------------

function MatchListView:on_mouse_moved(mx, my, ...)
  if MatchListView.super.on_mouse_moved(self, mx, my, ...) then return end
  local bx, by, bw, bh = self:get_button_rect()
  self.button_hovered = viewutils.point_in_rect(mx, my, bx, by, bw, bh)
end

function MatchListView:on_mouse_pressed(button, px, py, clicks)
  if MatchListView.super.on_mouse_pressed(self, button, px, py, clicks) then
    return true
  end

  -- the action button always lives at a fixed spot regardless of scroll
  local bx, by, bw, bh = self:get_button_rect()
  if viewutils.point_in_rect(px, py, bx, by, bw, bh) then
    self:on_button_pressed()
    return true
  end

  for kind, item, match, x, y, w, h in self:each_visible_row() do
    if viewutils.point_in_rect(px, py, x, y, w, h) then
      local cb_x = x + style.padding.x
      local cb_y = y + common.round((h - self.checkbox_size) / 2)

      local on_checkbox = false
      if self.checkboxes then
        if kind == "file" then
          on_checkbox = viewutils.point_in_rect(px, py, cb_x, cb_y, self.checkbox_size, self.checkbox_size)
        else
          -- NOTE: the padding for line-type items is `style.padding.x`
          on_checkbox = viewutils.point_in_rect(px, py, cb_x + style.padding.x, cb_y, self.checkbox_size, self.checkbox_size)
        end
      end

      if kind == "file" then
        if on_checkbox then
          set_file_selected(item, not file_all_selected(item))
        else
          self:toggle_expand(item)
        end
      else -- "match"
        if on_checkbox then
          match.selected = not match.selected
        else
          self:open_match(item, match)
        end
      end
      return true
    end
  end

  return true
end

-- scrolls a DocView so that the given line ends up vertically centered
local function center_on_line(dv, line)
  if not (dv and dv.get_line_screen_position) then return end
  -- the DocView may have just been added to a node and not yet have a
  -- valid size/scroll set up for this frame, so do the actual centering
  -- on the next update tick.
  core.add_thread(function()
    coroutine.yield()
    local _, y = dv:get_line_screen_position(line)
    local _, oy = dv:get_content_offset()
    local target = math.max(0, y - oy - dv.size.y / 2)
    dv.scroll.to.y = target
    dv.scroll.y = target
  end)
end

-- default: open item.filename and select match.line, from match.col to
-- match.col + match.len -- both current subclasses fit this shape
function MatchListView:open_match(item, match)
  local ok, doc = pcall(core.open_doc, item.filename)
  if ok and doc then
    local dv = core.root_view:open_doc(doc)
    local col1 = match.col or 1
    local col2 = col1 + (match.len or 0)
    doc:set_selection(match.line, col1, match.line, col2)
    center_on_line(dv, match.line)
  end
end

-- ---------------------------------------------------------------------------
-- update / animation
-- ---------------------------------------------------------------------------

function MatchListView:update()
  local expanding = self.expanding[1]
  if expanding then
    self:move_towards(expanding, "current", expanding.target, nil, "matchlistview")
    if expanding.current == expanding.target then
      table.remove(self.expanding, 1)
    end
  end

  self:move_towards("yoffset", 0, nil, "matchlistview")

  MatchListView.super.update(self)
end

-- ---------------------------------------------------------------------------
-- drawing
-- ---------------------------------------------------------------------------

-- default file row: checkbox, expand/collapse chevron, "filename (N)"
function MatchListView:draw_file_row(item, x, y, w, h, tx, cb_y)
  if self.checkboxes then
    viewutils.draw_checkbox(tx, cb_y, file_all_selected(item), self.checkbox_size)
    tx = tx + self.checkbox_size + style.padding.x
  end

  viewutils.ensure_icon_font(self)
  if self.icon_font then
    local glyphs = viewutils.discover_chevron_glyphs()
    local glyph = self:is_item_expanded(item) and glyphs.expanded or glyphs.collapsed
    tx = viewutils.draw_expand_chevron(self.icon_font, glyph, tx, y, h, style.text)
    -- WIP: set proper fixed width
    tx = tx + style.padding.x / 2
  else
    -- discovery failed (e.g. TreeView's internals changed enough that no
    -- draw_text call happened) -- fall back to a plain text arrow rather
    -- than showing nothing
    local arrow = self:is_item_expanded(item) and "v " or "> "
    tx = common.draw_text(self.font, style.text, arrow, "left", tx, y, w, h)
  end

  local label = item.filename .. "  (" .. #item.matches .. ")"
  common.draw_text(self.font, style.text, label, "left", tx, y, w, h)
end

-- subclasses must override this
function MatchListView:draw_match_row(item, match, x, y, w, h, tx, cb_y)
end

function MatchListView:draw()
  self:draw_background(style.background)

  for kind, item, match, x, y, w, h in self:each_visible_row() do
    if y + h >= self.position.y and y <= self.position.y + self.size.y - self.button_height then
      core.push_clip_rect(x, y, w, h)

      local tx = x + style.padding.x
      local cb_y = y + common.round((h - self.checkbox_size) / 2)

      if kind == "file" then
        self:draw_file_row(item, x, y, w, h, tx, cb_y)
      else
        tx = tx + style.padding.x
        if self.checkboxes then
          viewutils.draw_checkbox(tx, cb_y, match.selected, self.checkbox_size)
          tx = tx + self.checkbox_size + style.padding.x
        end
        self:draw_match_row(item, match, x, y, w, h, tx, cb_y)
      end

      core.pop_clip_rect()
    end
  end

  self:draw_scrollbar()
  self:draw_action_button()
end

function MatchListView:draw_action_button()
  local x, y, w, h = self:get_button_rect()
  core.push_clip_rect(x, y, w, h)
  renderer.draw_rect(x, y, w, h, style.background2 or style.background)
  renderer.draw_rect(x, y, w, 1, style.divider)

  local label = self:get_button_label()

  local bw = math.min(w - style.padding.x * 2, self.font:get_width(label) + style.padding.x * 4)
  local bx = x + common.round((w - bw) / 2)
  local by = y + common.round((h - (self.font:get_height() + style.padding.y)) / 2)
  local bh = self.font:get_height() + style.padding.y

  local color = self.button_hovered and style.accent or style.text
  renderer.draw_rect(bx, by, bw, bh, style.dim)
  renderer.draw_rect(bx + 1, by + 1, bw - 2, bh - 2, style.background)
  common.draw_text(self.font, color, label, "center", bx, by, bw, bh)

  core.pop_clip_rect()
end

return MatchListView
