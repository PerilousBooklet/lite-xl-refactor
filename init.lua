--mod-version:3
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local fsutils = require "plugins.refactor.fsutils"
local movefile = require "plugins.refactor.movefile"

local TreeView = require "plugins.treeview"
local RefactorView = require "plugins.refactor.refactorview"

-- FIX: when changing project, fsutils lib is missing

-- TODO: allow choosing sub-folder from within which to search for refactoring (useful when the codebase is huge)
-- TODO: allow regex use
-- TODO: HIGH PRIORITY: check reliability of regex handling logic

-- TODO: HIGH PRIORITY: check reliability of search logic
-- TODO: HIGH PRIORITY: check reliability of replacement logic
-- TODO: HIGH PRIORITY: check reliability of folder-and-its-contents move logic

-- REVIEW: remove unnecessary comments
-- REVIEW: full code review

local function open_refactor_view(find_text, replace_text)
  local node = core.root_view:get_active_node_default()
  node:add_view(RefactorView(find_text, replace_text))
end

command.add(nil, {
  ["refactor:find-and-replace"] = function()
    core.command_view:enter("Find in project", {
      submit = function(find_text)
        if find_text == "" then return end
        core.command_view:enter("Replace with", {
          submit = function(replace_text)
            open_refactor_view(find_text, replace_text or "")
          end,
        })
      end,
    })
  end,
})

-- Refactor a file/folder
-- works on both files and directories -- only requires something in the
-- tree view to be hovered
command.add(
  function()
    return TreeView.hovered_item ~= nil
  end,
  {
    ["refactor:move-file"] = function()
      movefile.prompt_move(TreeView.hovered_item.abs_filename)
    end,
  }
)

local treeview_menu = TreeView.contextmenu
treeview_menu:register(
  function()
    return TreeView.hovered_item and TreeView.hovered_item.abs_filename ~= fsutils.project_dir()
  end,
  {
    treeview_menu.DIVIDER,
    {
      text = "Move",
      command = "refactor:move-file"
    }
  }
)

keymap.add {
  ["ctrl+shift+h"] = "refactor:find-and-replace",
}
