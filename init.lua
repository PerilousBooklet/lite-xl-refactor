-- mod-version:3
local command = require "core.command"
local keymap = require "core.keymap"


----------------
-- Brainstorm --
----------------

-- 1. draw the tabview
-- 2. make sure there can only be one at a time
-- 3. draw a few example items (complete with sub-items and square toggle buttons)
-- 4. extend the existing text search to project-wide
-- 5. draw colored backgrounds for matched and new text
-- 6. draw some kind of confirmation button
-- 7. 


-----------------------------
-- REFERENCE DOCS TO STUDY --
-----------------------------

-- jgmdev's implementation
-- https://github.com/pragtical/pragtical/pull/48
-- https://github.com/pragtical/widget/commits/master/searchreplacelist.lua

-- which files to read from:
-- 1. ./data/core/doc/search.lua
-- 2. ./data/plugins/projectsearch.lua (?)
-- 3. https://github.com/pragtical/widget/blob/master/searchreplacelist.lua (for the square toggle button)

-- Reusing existing code from other plugins
-- 1. Lite XL's logging tab toggable lines
-- 2. jgmdev's refactor PR's togglable button
-- 3. lite-xl-fullbar's bar to add a bottom bar to an EmptyView, 
--    the 2 buttons should be placed in the center of the bar


----------
-- Init --
----------

-- ?


--------------
-- COMMANDS --
--------------

command.add(nil, {
  ["refactor:find-to-replace-text-in-project"] = function ()
  	-- ...
  end
})


-----------------
-- Keybindings --
-----------------

keymap.add({ ["ctrl+shift+r"] = "refactor:find-to-replace-text-in-project" })
