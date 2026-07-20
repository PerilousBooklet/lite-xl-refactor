--mod-version:3

-- init.lua
--
-- "Refactor" plugin: project-wide find & replace with a review UI.
--
-- Install by copying this whole folder into your `data/plugins` directory
-- as e.g. `data/plugins/refactor/`, so that it contains:
--   data/plugins/refactor/init.lua
--   data/plugins/refactor/refactorview.lua
--
-- It adds a command (bound by default to ctrl+shift+h) that asks for a
-- search string and a replacement string, runs a project-wide search in the
-- background, and opens a RefactorView where you can expand each file,
-- tick/untick individual matches (or a whole file at once) and then hit the
-- "Replace" button at the bottom of the view to apply the change.

local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"

local RefactorView = require "plugins.refactor.refactorview"

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


keymap.add {
  ["ctrl+shift+h"] = "refactor:find-and-replace",
}

