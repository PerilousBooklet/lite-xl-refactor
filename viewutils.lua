-- Shared small drawing/interaction helpers used by every view in this
-- plugin that shows a checkbox-and-curtain list of matches (RefactorView,
-- MoveView). Kept in one place so the chevron glyph discovery hack (see
-- below) only ever runs once, and so the two views can't drift apart on
-- how a checkbox or a highlighted span gets drawn.

local common = require "core.common"
local style = require "core.style"
local TreeView = require "plugins.treeview"

local viewutils = {}

viewutils.CHECK_FILL = { common.color "#ffffff" }
viewutils.RED_BG = { common.color "#a33a3a" }
viewutils.GREEN_BG = { common.color "#3a9a4d" }
viewutils.HIGHLIGHT_FG = { common.color "#ffffff" }

-- draws `text` on top of a solid background rectangle, returns the x
-- position right after the drawn text (so callers can chain draw calls)
function viewutils.draw_highlighted(font, text, x, y, h, bg_color, fg_color)
  local tw = font:get_width(text)
  if tw > 0 then
    renderer.draw_rect(x, y, tw, h, bg_color)
    common.draw_text(font, fg_color, text, "left", x, y, tw, h)
  end
  return x + tw
end

-- draws a small square, outlined, filled white when `selected` is true
function viewutils.draw_checkbox(x, y, selected, s)
  renderer.draw_rect(x, y, s, s, style.dim)
  if selected then
    renderer.draw_rect(x + 1, y + 1, s - 2, s - 2, viewutils.CHECK_FILL)
  else
    renderer.draw_rect(x + 1, y + 1, s - 2, s - 2, style.background)
  end
end

function viewutils.point_in_rect(px, py, x, y, w, h)
  return px >= x and py >= y and px < x + w and py < y + h
end

-- ---------------------------------------------------------------------------
-- chevron glyph discovery
--
-- TreeView's expand/collapse chevron is drawn from its own icon font using
-- characters that aren't exposed as named constants anywhere -- and that
-- font (style.icon_font) is shared globally, so resizing it to match a
-- view's own zoom would resize the real project tree's icons too.
--
-- Rather than hardcoding a private-use-area codepoint (which could
-- silently render as a blank box if the bundled icon font or its
-- codepoints ever change), we discover the actual (font, character) pair
-- for both states exactly once: temporarily swap out renderer.draw_text
-- with a wrapper that records what it was called with, invoke TreeView's
-- own public draw_item_chevron off-screen for both expanded states, then
-- put the real renderer.draw_text back. From then on callers draw the
-- chevron themselves with their own independent, resizable copy of that
-- font. Cached at module scope so this only ever happens once, no matter
-- how many views end up using it.
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

viewutils.discover_chevron_glyphs = discover_chevron_glyphs

-- draws a single already-resolved chevron glyph with the given (zoomable)
-- font, and returns the x position right after it
function viewutils.draw_expand_chevron(font, glyph_text, x, y, h, color)
  local tw = font:get_width(glyph_text)
  common.draw_text(font, color, glyph_text, "left", x, y, tw, h)
  return x + tw
end

-- lazily creates `view`'s own independent, resizable copy of whatever
-- font TreeView's chevron turned out to use, storing it on
-- view.icon_font / view.icon_base_size. `view.zoom` must already exist.
-- A no-op after the first successful call.
function viewutils.ensure_icon_font(view)
  if view.icon_font then return end
  local glyphs = discover_chevron_glyphs()
  if not glyphs then return end
  view.icon_base_size = glyphs.font:get_size()
  view.icon_font = glyphs.font:copy(view.icon_base_size * view.zoom)
end

return viewutils
