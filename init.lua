--mod-version:3
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

