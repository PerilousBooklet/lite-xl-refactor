-- A View (modeled directly on core/logview.lua) that shows the results of a
-- project-wide "find" as a list of files. Each file row can be clicked to
-- unroll a "curtain" showing every matching line inside that file. Both file
-- rows and individual match rows have a small checkbox at the start of the
-- row that toggles whether that file/line should be included when the
-- replacement is finally applied via the button drawn at the bottom of the
-- view.

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local View = require "core.view"
local keymap = require "core.keymap"
local fsutils = require "plugins.refactor.fsutils"
local TreeView = require "plugins.treeview"

-- ---------------------------------------------------------------------------
-- small helpers
-- ---------------------------------------------------------------------------

local function count_lines(text)
  if text == "" then return 0 end
  local l = 1
  for _ in text:gmatch("\n") do l = l + 1 end
  return l
end

-- white fill used for a "checked" checkbox
local CHECK_FILL = { common.color "#ffffff" }

-- backgrounds used to highlight the matched text vs. its replacement
local RED_BG = { common.color "#a33a3a" }
local GREEN_BG = { common.color "#3a9a4d" }
local HIGHLIGHT_FG = { common.color "#ffffff" }

-- draws `text` on top of a solid background rectangle, returns the x
-- position right after the drawn text (so callers can chain draw calls)
local function draw_highlighted(font, text, x, y, h, bg_color, fg_color)
  local tw = font:get_width(text)
  if tw > 0 then
    renderer.draw_rect(x, y, tw, h, bg_color)
    common.draw_text(font, fg_color, text, "left", x, y, tw, h)
  end
  return x + tw
end

-- draws a small square, outlined, filled white when `selected` is true.
-- `s` (the checkbox side length) is passed in rather than read from a
-- module-level constant, since it now derives from this view's own
-- (zoomable) font instead of the shared style.font.
local function draw_checkbox(x, y, selected, s)
  renderer.draw_rect(x, y, s, s, style.dim)
  if selected then
    renderer.draw_rect(x + 1, y + 1, s - 2, s - 2, CHECK_FILL)
  else
    renderer.draw_rect(x + 1, y + 1, s - 2, s - 2, style.background)
  end
end

local function point_in_rect(px, py, x, y, w, h)
  return px >= x and py >= y and px < x + w and py < y + h
end

-- escapes a plain string so it can be safely used as a Lua pattern
local function escape_pattern(text)
  return (text:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1"))
end

-- escapes a plain replacement string so gsub doesn't treat "%" specially
local function escape_replacement(text)
  return (text:gsub("%%", "%%%%"))
end

-- ---------------------------------------------------------------------------
-- chevron glyph discovery
--
-- TreeView's expand/collapse chevron is drawn from its own icon font using
-- characters that aren't exposed as named constants anywhere -- and that
-- font (style.icon_font) is shared globally, so resizing it to match our
-- own zoom would resize the real project tree's icons too.
--
-- Rather than hardcoding a private-use-area codepoint (which could
-- silently render as a blank box if the bundled icon font or its
-- codepoints ever change), we discover the actual (font, character) pair
-- for both states exactly once: temporarily swap out renderer.draw_text
-- with a wrapper that records what it was called with, invoke TreeView's
-- own public draw_item_chevron off-screen for both expanded states, then
-- put the real renderer.draw_text back. From then on we draw the chevron
-- ourselves with our own independent, resizable copy of that font.
-- ---------------------------------------------------------------------------

local chevron_glyphs = nil -- { font = <icon font>, collapsed = "..", expanded = ".." }, discovered lazily

local function discover_chevron_glyphs()
  if chevron_glyphs then return chevron_glyphs end

  local captured = {}
  local real_draw_text = renderer.draw_text
  renderer.draw_text = function(font, text, x, y, color)
    table.insert(captured, { font = font, text = text })
    return real_draw_text(font, text, x, y, color)
  end

  -- draw both states far off-screen -- we only want to see what (font,
  -- character) each one used, not the resulting pixels
  local ok = pcall(function()
    TreeView.draw_item_chevron(TreeView, { type = "dir", expanded = false }, false, false, -10000, -10000, 0, 16)
    TreeView.draw_item_chevron(TreeView, { type = "dir", expanded = true }, false, false, -10000, -10000, 0, 16)
  end)

  renderer.draw_text = real_draw_text

  if ok and captured[1] and captured[2] then
    chevron_glyphs = {
      font = captured[1].font,
      collapsed = captured[1].text,
      expanded = captured[2].text,
    }
  end

  return chevron_glyphs
end

-- draws a single already-resolved chevron glyph with the given (zoomable)
-- font, and returns the x position right after it
local function draw_expand_chevron(font, glyph_text, x, y, h, color)
  local tw = font:get_width(glyph_text)
  common.draw_text(font, color, glyph_text, "left", x, y, tw, h)
  return x + tw
end


-- ---------------------------------------------------------------------------
-- RefactorView
-- ---------------------------------------------------------------------------

local RefactorView = View:extend()

RefactorView.context = "session"

function RefactorView:__tostring() return "RefactorView" end


function RefactorView:new(find_text, replace_text)
  RefactorView.super.new(self)
  self.scrollable = true
  self.yoffset = 0

  self.find_text = find_text
  self.replace_text = replace_text or ""

  -- list of { filename = str, matches = { {line=n, text=str, col=n, selected=bool}, ... } }
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

  self.searching = true
  self.files_scanned = 0
  self.files_total = 0

  self.button_height = self.font:get_height() + style.padding.y * 2
  self.button_hovered = false
  self.button_pressed = false

  core.status_view:show_message("i", style.text,
    "click a file to expand it, click a square to (de)select, then hit Replace")

  self:begin_search()
end


function RefactorView:get_name()
  return "Refactor: " .. self.find_text
end


-- lazily creates this view's own independent, resizable copy of whatever
-- font TreeView's chevron turned out to use (see discover_chevron_glyphs
-- above). A no-op after the first successful call.
function RefactorView:ensure_icon_font()
  if self.icon_font then return end
  local glyphs = discover_chevron_glyphs()
  if not glyphs then return end
  self.icon_base_size = glyphs.font:get_size()
  self.icon_font = glyphs.font:copy(self.icon_base_size * self.zoom)
end


-- ---------------------------------------------------------------------------
-- item height / expand-collapse (same shape as LogView)
-- ---------------------------------------------------------------------------

function RefactorView:get_item_height(item)
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


local function is_expanded(self, item)
  local h = self:get_item_height(item)
  return h.target == h.expanded
end


function RefactorView:toggle_expand(item)
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

function RefactorView:each_visible_row()
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


-- ---------------------------------------------------------------------------
-- scrolling
-- ---------------------------------------------------------------------------

-- reserve room at the bottom of the view for the "Replace" button
function RefactorView:get_content_bounds()
  local x, y = self:get_content_offset()
  return x, y, self.size.x, self.size.y - self.button_height
end


function RefactorView:get_scrollable_size()
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
-- mouse handling
-- ---------------------------------------------------------------------------

function RefactorView:get_button_rect()
  local x = self.position.x
  local y = self.position.y + self.size.y - self.button_height
  return x, y, self.size.x, self.button_height
end


-- ---------------------------------------------------------------------------
-- zoom (ctrl+scroll-wheel, local to this view)
-- ---------------------------------------------------------------------------

local MIN_ZOOM = 0.5
local MAX_ZOOM = 3.0
local ZOOM_STEP = 0.1

function RefactorView:set_zoom(new_zoom)
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
function RefactorView:on_mouse_wheel(y, ...)
  if keymap.modkeys["ctrl"] then
    self:set_zoom(self.zoom + (y > 0 and ZOOM_STEP or -ZOOM_STEP))
    return true
  end
  return RefactorView.super.on_mouse_wheel(self, y, ...)
end


function RefactorView:on_mouse_moved(mx, my, ...)
  if RefactorView.super.on_mouse_moved(self, mx, my, ...) then return end
  local bx, by, bw, bh = self:get_button_rect()
  self.button_hovered = point_in_rect(mx, my, bx, by, bw, bh)
end


function RefactorView:on_mouse_pressed(button, px, py, clicks)
  if RefactorView.super.on_mouse_pressed(self, button, px, py, clicks) then
    return true
  end

  -- the "Replace" button always lives at a fixed spot regardless of scroll
  local bx, by, bw, bh = self:get_button_rect()
  if point_in_rect(px, py, bx, by, bw, bh) then
    self:apply_replacement()
    return true
  end

  -- don't let clicks below the button area (shouldn't happen, but be safe)
  -- fall through to the scrollable rows
  for kind, item, match, x, y, w, h in self:each_visible_row() do
    if point_in_rect(px, py, x, y, w, h) then
      local cb_x = x + style.padding.x
      local cb_y = y + common.round((h - self.checkbox_size) / 2)

      local on_checkbox = nil
      if kind == "file" then
        on_checkbox = point_in_rect(px, py, cb_x, cb_y, self.checkbox_size, self.checkbox_size)
      else
        -- NOTE: the padding for line-type items is `style.padding.x`
        on_checkbox = point_in_rect(px, py, cb_x + style.padding.x, cb_y, self.checkbox_size, self.checkbox_size)
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


function RefactorView:open_match(item, match)
  local ok, doc = pcall(core.open_doc, item.filename)
  if ok and doc then
    local dv = core.root_view:open_doc(doc)
    local col1 = match.col or 1
    local col2 = col1 + #self.find_text
    doc:set_selection(match.line, col1, match.line, col2)
    center_on_line(dv, match.line)
  end
end


-- ---------------------------------------------------------------------------
-- update / animation (mirrors LogView:update)
-- ---------------------------------------------------------------------------

function RefactorView:update()
  local expanding = self.expanding[1]
  if expanding then
    self:move_towards(expanding, "current", expanding.target, nil, "refactorview")
    if expanding.current == expanding.target then
      table.remove(self.expanding, 1)
    end
  end

  self:move_towards("yoffset", 0, nil, "refactorview")

  RefactorView.super.update(self)
end


-- ---------------------------------------------------------------------------
-- drawing
-- ---------------------------------------------------------------------------

function RefactorView:draw()
  self:draw_background(style.background)

  local lh = self.font:get_height() + style.padding.y

  for kind, item, match, x, y, w, h in self:each_visible_row() do
    if y + h >= self.position.y and y <= self.position.y + self.size.y - self.button_height then
      core.push_clip_rect(x, y, w, h)

      local tx = x + style.padding.x
      local cb_y = y + common.round((h - self.checkbox_size) / 2)

      if kind == "file" then
        draw_checkbox(tx, cb_y, file_all_selected(item), self.checkbox_size)
        tx = tx + self.checkbox_size + style.padding.x

        self:ensure_icon_font()
        if self.icon_font then
          local glyph = is_expanded(self, item) and chevron_glyphs.expanded or chevron_glyphs.collapsed
          tx = draw_expand_chevron(self.icon_font, glyph, tx, y, lh, style.text)
          tx = tx + style.padding.x / 4
        else
          -- discovery failed (e.g. TreeView's internals changed enough
          -- that no draw_text call happened) -- fall back to a plain
          -- text arrow rather than showing nothing
          local arrow = is_expanded(self, item) and "v " or "> "
          tx = common.draw_text(self.font, style.text, arrow, "left", tx, y, w, lh)
        end

        local label = item.filename .. "  (" .. #item.matches .. ")"
        common.draw_text(self.font, style.text, label, "left", tx, y, w, lh)
      else
        tx = tx + style.padding.x
        draw_checkbox(tx, cb_y, match.selected, self.checkbox_size)
        tx = tx + self.checkbox_size + style.padding.x

        local lineno = tostring(match.line) .. ": "
        tx = common.draw_text(self.font, style.dim, lineno, "left", tx, y, w, lh)

        local col = match.col or 1
        local find_len = #self.find_text
        local prefix = match.text:sub(1, col - 1)
        local matched = match.text:sub(col, col + find_len - 1)
        local suffix = match.text:sub(col + find_len)

        tx = common.draw_text(self.font, style.text, prefix, "left", tx, y, w, lh)
        tx = draw_highlighted(self.font, matched, tx, y, lh, RED_BG, HIGHLIGHT_FG)
        tx = draw_highlighted(self.font, self.replace_text, tx, y, lh, GREEN_BG, HIGHLIGHT_FG)
        common.draw_text(self.font, style.text, suffix, "left", tx, y, w, lh)
      end

      core.pop_clip_rect()
    end
  end

  if self.searching then
    local msg = string.format("searching... (%d/%d files, %d matches)",
      self.files_scanned, self.files_total, #self.results)
    core.status_view:show_message("i", style.text, msg)
  end

  self:draw_scrollbar()
  self:draw_replace_button()
end


function RefactorView:draw_replace_button()
  local x, y, w, h = self:get_button_rect()
  core.push_clip_rect(x, y, w, h)
  renderer.draw_rect(x, y, w, h, style.background2 or style.background)
  renderer.draw_rect(x, y, w, 1, style.divider)

  local total, selected = 0, 0
  for _, item in ipairs(self.results) do
    for _, match in ipairs(item.matches) do
      total = total + 1
      if match.selected then selected = selected + 1 end
    end
  end

  local label = string.format("Replace %d/%d selected match%s",
    selected, total, total == 1 and "" or "es")

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


-- ---------------------------------------------------------------------------
-- searching the project
-- ---------------------------------------------------------------------------

local function is_probably_binary(chunk)
  return chunk:find("\0", 1, true) ~= nil
end

-- delegates to fsutils so this listing logic is shared with movefile.lua
-- instead of being duplicated in two places
local function collect_project_files()
  return fsutils.collect_project_files()
end

function RefactorView:begin_search()
  local view = self
  core.add_thread(function()
    local files = collect_project_files()
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
