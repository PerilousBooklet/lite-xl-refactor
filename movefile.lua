-- Moves a project file OR directory to a new path and rewrites every
-- import/require statement in the project that refers to anything that
-- moved -- including relative imports written *inside* a moved file
-- itself, whose meaning changes purely because the file's own location
-- changed, even if what it points at didn't move.
--
-- Directory moves are handled by snapshotting an old-path -> new-path
-- mapping for every file nested under the directory *before* touching the
-- disk, then treating every file in the project (moved or not) uniformly:
-- for each import, resolve what it used to point at, look up whether that
-- target moved, and re-derive the import string from the importer's
-- (possibly new) location to the target's (possibly new) location. Two
-- files that moved together as siblings naturally end up unchanged,
-- since their relative offset to each other never changed.
--
-- Before anything actually moves, movefile.preview() runs this exact same
-- per-file rewrite logic (process_file_imports, below) in a dry run --
-- nothing is written to disk, but every reference that *would* change is
-- collected so it can be shown to the user (see moveview.lua) and
-- individually deselected. movefile.perform() then re-runs the identical
-- logic for real, optionally skipping whichever lines got deselected.
-- Preview and apply sharing one function is what keeps them from ever
-- drifting apart.
--
-- Language-specific syntax details all live in config.lua; this file only
-- orchestrates the move and the bookkeeping around it.

local core = require "core"
local fsutils = require "plugins.refactor.fsutils"
local langconfig = require "plugins.refactor.config"

local movefile = {}

-- ---------------------------------------------------------------------------
-- language lookup
-- ---------------------------------------------------------------------------

local function find_language(rel_path)
  local ext = rel_path:match("%.([%w_]+)$")
  if not ext then return nil end
  for _, lang in pairs(langconfig.languages) do
    for _, e in ipairs(lang.extensions) do
      if e == ext then return lang end
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- pattern-based rewriting
--
-- `import_patterns` in config.lua each have exactly one capture group: the
-- import/module string itself. We can't just gsub(pattern, replacement)
-- because whether/how to replace depends on runtime state (does this
-- import resolve to something that moved?). So we manually walk matches,
-- locate the capture's exact byte range inside the full match, and splice
-- in a replacement only for that range -- everything else (require(...),
-- quote style, whitespace) is left untouched.
--
-- The callback receives (cap, cap_s, content): the captured import
-- string, its starting byte offset, and the content it was found in (as
-- of *this* pattern's pass -- see rewrite_imports). The extra two args
-- only exist so process_file_imports below can report a line/column for
-- display; a callback that only cares about the captured string (as
-- movefile used to have inline) can simply ignore them.
-- ---------------------------------------------------------------------------

local function replace_pattern(content, pattern, callback)
  local out = {}
  local last = 1
  local init = 1
  while true do
    local s, e, cap = content:find(pattern, init)
    if not s then break end
    if cap then
      local whole = content:sub(s, e)
      local rel = whole:find(cap, 1, true)
      local cap_s, cap_e = s, e
      if rel then
        cap_s = s + rel - 1
        cap_e = cap_s + #cap - 1
      end
      local replacement = callback(cap, cap_s, content)
      if replacement and replacement ~= cap then
        table.insert(out, content:sub(last, cap_s - 1))
        table.insert(out, replacement)
        last = cap_e + 1
      end
    end
    if e < init then break end -- safety net against zero-width matches
    init = e + 1
  end
  table.insert(out, content:sub(last))
  return table.concat(out)
end

local function rewrite_imports(content, lang, resolve_fn)
  for _, pattern in ipairs(lang.import_patterns) do
    content = replace_pattern(content, pattern, resolve_fn)
  end
  return content
end

-- ---------------------------------------------------------------------------
-- shared per-file import rewriting
--
-- Used both by the dry-run preview (movefile.preview) and by the real
-- move (movefile.perform), so the two can never drift apart: whatever the
-- preview shows is *exactly* what applying it will do, because both call
-- this same function with the same mapping.
--
-- `is_line_selected`, if given, is a function(line_no) -> bool. A change
-- is only actually spliced into the returned content if it returns true
-- (or if `is_line_selected` itself is nil, meaning "apply everything") --
-- otherwise the change is still detected and reported so a caller can
-- always see every reference, selected or not.
--
-- Returns (new_content, changes), where changes is a list of
-- { line, col, len, old_import, new_import, line_text }, len being the
-- length of old_import (kept as its own field so display code doesn't
-- need to know that).
-- ---------------------------------------------------------------------------

local function process_file_imports(content, lang, old_importer_dir, new_importer_dir,
                                     mapping_by_exact, mapping_by_noext, is_line_selected)
  local changes = {}

  local new_content = rewrite_imports(content, lang, function(import_str, cap_s, current_content)
    local target_old
    if lang.only_relative then
      target_old = lang.import_to_path(import_str, old_importer_dir)
    else
      target_old = lang.import_to_path(import_str)
    end
    target_old = langconfig.normalize_rel(target_old)

    -- if the reference already names a specific extension (HTML
    -- src="./foo.js", or an explicit-extension JS import), match exactly
    -- so moving "foo.js" can't be confused with an unrelated "foo.png"
    -- that merely shares a base name. Extension-less references (the
    -- JS/Lua/Python norm) match against the noext form as before.
    local mapped_new
    if target_old:match("%.[%w_]+$") then
      mapped_new = mapping_by_exact[target_old]
    else
      mapped_new = mapping_by_noext[langconfig.strip_ext(target_old)]
    end

    local new_import
    if lang.only_relative then
      -- importer didn't move and target didn't move: nothing to do
      if new_importer_dir == old_importer_dir and not mapped_new then
        return nil
      end
      local target_new = mapped_new or target_old
      local rel = langconfig.relative_path(target_new, new_importer_dir)
      new_import = lang.path_to_import(rel, new_importer_dir)
    else
      -- absolute/project-rooted imports (Lua, Python): the importer's
      -- own location is irrelevant to its own resolution, only whether
      -- the *target* moved matters
      if not mapped_new then return nil end
      new_import = lang.path_to_import(mapped_new)
    end

    if new_import == import_str then return nil end

    -- figure out where this match lands so it can be shown (and so a
    -- caller can select/deselect it by line number). Computed against
    -- `current_content` -- the file as of this point in the rewrite,
    -- i.e. after any earlier matches in this same pass already applied
    -- their own replacements -- which is what's actually on screen for
    -- every match except this exact one; import strings never contain
    -- newlines, so line numbers stay correct regardless.
    local before = current_content:sub(1, cap_s - 1)
    local line_no, last_nl = 1, 0
    for pos in before:gmatch("()\n") do
      line_no = line_no + 1
      last_nl = pos
    end
    local line_end = current_content:find("\n", cap_s) or (#current_content + 1)

    table.insert(changes, {
      line = line_no,
      col = cap_s - last_nl,
      len = #import_str,
      old_import = import_str,
      new_import = new_import,
      line_text = current_content:sub(last_nl + 1, line_end - 1),
    })

    if is_line_selected and not is_line_selected(line_no) then
      return nil -- detected, but deselected -- leave the original text alone
    end
    return new_import
  end)

  return new_content, changes
end

-- selection is sparse: selection[relname] (if present) maps line numbers
-- to `false` for lines the user deselected in a MoveView -- anything not
-- mentioned (including relname not being a key at all) is applied by
-- default. Returns nil ("apply everything unconditionally") when there's
-- nothing to filter for this file, including when `selection` itself is
-- nil (i.e. movefile.perform was called directly, with no preview step).
local function make_line_selector(selection, relname)
  if not selection then return nil end
  local exceptions = selection[relname]
  if not exceptions then return nil end
  return function(line_no) return exceptions[line_no] ~= false end
end

-- ---------------------------------------------------------------------------
-- open-doc bookkeeping
-- ---------------------------------------------------------------------------

-- if any open doc is backed by a path that moved, point it at the new path.
-- Must run *before* the import-rewrite pass below, since that pass matches
-- docs by their (already up to date) filename/abs_filename to decide
-- whether to reload them.
local function retarget_open_docs(mapping, project_dir)
  for old_rel, new_rel in pairs(mapping) do
    local old_rel_native = old_rel:gsub("/", PATHSEP)
    local new_rel_native = new_rel:gsub("/", PATHSEP)
    local old_abs = project_dir .. PATHSEP .. old_rel_native
    local new_abs = project_dir .. PATHSEP .. new_rel_native
    for _, doc in ipairs(core.docs) do
      if doc.filename == old_rel or doc.filename == old_rel_native or doc.abs_filename == old_abs then
        doc.filename = new_rel_native
        doc.abs_filename = new_abs
      end
    end
  end
end

local function reload_if_open(rel_path, abs_path)
  for _, doc in ipairs(core.docs) do
    if doc.filename == rel_path or doc.abs_filename == abs_path then
      doc:reload()
    end
  end
end

-- ---------------------------------------------------------------------------
-- building the old-path -> new-path mapping for everything that will move
--
-- Computed *before* touching the disk: for a single file this is one
-- entry; for a directory it's every file currently nested under it, with
-- the directory's own prefix swapped out.
-- ---------------------------------------------------------------------------

local function strip_trailing_slash(path)
  return (path:gsub("/+$", ""))
end

local function collect_files_under(dir_rel)
  dir_rel = strip_trailing_slash(langconfig.to_unix(dir_rel))
  local prefix = dir_rel .. "/"
  local matches = {}
  for _, f in ipairs(fsutils.collect_project_files()) do
    f = langconfig.to_unix(f)
    if f:sub(1, #prefix) == prefix then
      table.insert(matches, f)
    end
  end
  return matches
end

local function build_move_mapping(old_rel, new_rel, moving_dir)
  local mapping = {}
  if moving_dir then
    old_rel = strip_trailing_slash(old_rel)
    new_rel = strip_trailing_slash(new_rel)
    for _, f in ipairs(collect_files_under(old_rel)) do
      local suffix = f:sub(#old_rel + 1) -- keeps the leading "/"
      mapping[f] = new_rel .. suffix
    end
  else
    mapping[old_rel] = new_rel
  end
  return mapping
end

-- ---------------------------------------------------------------------------
-- validation + mapping, shared by preview() and perform()
--
-- old_rel, new_rel: project-relative paths to a file OR a directory.
-- Returns (data, nil) on success or (nil, error_message) on failure;
-- never touches disk.
-- ---------------------------------------------------------------------------

local function validate_and_build_mapping(old_rel, new_rel)
  old_rel = langconfig.normalize_rel(langconfig.to_unix(old_rel))
  new_rel = langconfig.normalize_rel(langconfig.to_unix(new_rel))

  if new_rel == "" then
    return nil, "destination path is empty"
  end
  -- normalize_rel collapses "a/../b" down, but can't collapse a leading
  -- ".." (there's nothing to pop), so a surviving ".." here means the
  -- typed path tried to climb above the project root -- reject it rather
  -- than silently moving something out of the project.
  if new_rel == ".." or new_rel:match("^%.%./") then
    return nil, string.format("destination \"%s\" is outside the project folder", new_rel)
  end

  local project_dir = fsutils.project_dir()
  local old_abs = project_dir .. PATHSEP .. old_rel:gsub("/", PATHSEP)
  local new_abs = project_dir .. PATHSEP .. new_rel:gsub("/", PATHSEP)

  if fsutils.is_object_exist(new_abs) then
    return nil, "destination already exists: " .. new_rel
  end
  if not fsutils.is_object_exist(old_abs) then
    return nil, "source does not exist: " .. old_rel
  end

  local moving_dir = fsutils.is_dir(old_abs)

  if moving_dir then
    -- guard against moving a directory into (or onto) itself
    local old_prefix = strip_trailing_slash(old_rel) .. "/"
    if strip_trailing_slash(new_rel) == strip_trailing_slash(old_rel)
        or new_rel:sub(1, #old_prefix) == old_prefix then
      return nil, "can't move a directory into itself: " .. new_rel
    end
  end

  -- snapshot the old -> new path mapping for every file that's about to
  -- move, *before* anything on disk changes
  local mapping = build_move_mapping(old_rel, new_rel, moving_dir)

  local mapping_by_noext, mapping_by_exact = {}, {}
  local moved_has_known_language = false
  for old_key, new_val in pairs(mapping) do
    local key_unix = langconfig.to_unix(old_key)
    mapping_by_noext[langconfig.strip_ext(key_unix)] = new_val
    mapping_by_exact[key_unix] = new_val
    if find_language(old_key) then moved_has_known_language = true end
  end

  return {
    old_rel = old_rel,
    new_rel = new_rel,
    old_abs = old_abs,
    new_abs = new_abs,
    mapping = mapping,
    mapping_by_exact = mapping_by_exact,
    mapping_by_noext = mapping_by_noext,
    moving_dir = moving_dir,
    moved_has_known_language = moved_has_known_language,
  }
end

-- ---------------------------------------------------------------------------
-- preview: dry run -- computes every reference the move would rewrite,
-- without touching disk
-- ---------------------------------------------------------------------------

-- NOTE: like begin_search in refactorview.lua, this reads and scans every
-- project file synchronously rather than a background coroutine, so on a
-- very large project it can briefly stall the UI. Unlike RefactorView's
-- search, that's a acceptable trade-off here for now since a move is a
-- one-off action rather than something triggered repeatedly.
function movefile.preview(old_rel, new_rel)
  local data, err = validate_and_build_mapping(old_rel, new_rel)
  if not data then
    return nil, err
  end

  local project_dir = fsutils.project_dir()
  local results = {}

  for _, relname in ipairs(fsutils.collect_project_files()) do
    relname = langconfig.to_unix(relname)
    local lang = find_language(relname)

    if lang then
      local post_move_relname = data.mapping[relname] or relname
      local old_importer_dir = langconfig.dirname(relname)
      local new_importer_dir = langconfig.dirname(post_move_relname)

      local abs = project_dir .. PATHSEP .. relname:gsub("/", PATHSEP)
      local fp = io.open(abs, "rb")
      if fp then
        local content = fp:read("*a") or ""
        fp:close()

        local _, changes = process_file_imports(
          content, lang, old_importer_dir, new_importer_dir,
          data.mapping_by_exact, data.mapping_by_noext
        )

        if #changes > 0 then
          for _, c in ipairs(changes) do c.selected = true end
          table.insert(results, { filename = relname, matches = changes })
        end
      end
    end
  end

  return {
    old_rel = data.old_rel,
    new_rel = data.new_rel,
    moving_dir = data.moving_dir,
    moved_has_known_language = data.moved_has_known_language,
    files = results,
  }
end

-- ---------------------------------------------------------------------------
-- main entry point: actually perform the move
--
-- `selection`, if given, is { [pre_move_relname] = { [line_no] = false } }
-- as built by MoveView -- see make_line_selector above. Omit it to apply
-- every detected import rewrite unconditionally (the original behavior).
-- ---------------------------------------------------------------------------

function movefile.perform(old_rel, new_rel, selection)
  local data, err = validate_and_build_mapping(old_rel, new_rel)
  if not data then
    core.error("refactor: %s", err)
    return
  end

  local project_dir = fsutils.project_dir()

  -- 1. make sure the destination's parent directory exists (os.rename
  --    fails outright otherwise), then move the file/directory on disk.
  --    Everything below reads/writes files at their *new* locations (or
  --    their untouched locations) -- so if the move itself fails, we must
  --    stop here rather than rewrite imports to point at paths that were
  --    never actually created.
  local new_parent = langconfig.dirname(data.new_rel)
  if new_parent ~= "" then
    fsutils.mkdir_p(project_dir .. PATHSEP .. new_parent:gsub("/", PATHSEP))
  end

  if not fsutils.move_object(data.old_abs, data.new_abs) then
    core.error("refactor: move failed, nothing was rewritten")
    return
  end

  -- 2. point any already-open docs at their new location so the reload
  --    step further down (and any other editor bookkeeping) works
  retarget_open_docs(data.mapping, project_dir)

  -- reverse lookup: given a file's *current* (post-move) path, find the
  -- path it used to have, if it moved at all
  local rev_mapping = {}
  for old_key, new_val in pairs(data.mapping) do
    rev_mapping[new_val] = old_key
  end

  local files_changed, imports_changed = 0, 0

  -- 3. walk every file in the project post-move and fix any import that
  --    either (a) points at something that moved, or (b) is written by a
  --    file that itself moved and so needs re-expressing relative to its
  --    new location, even if the thing it points at didn't move.
  for _, relname in ipairs(fsutils.collect_project_files()) do
    relname = langconfig.to_unix(relname)
    local lang = find_language(relname)

    if lang then
      local old_rel_for_this = rev_mapping[relname]
      local old_importer_dir, new_importer_dir
      if old_rel_for_this then
        old_importer_dir = langconfig.dirname(old_rel_for_this)
        new_importer_dir = langconfig.dirname(relname)
      else
        old_importer_dir = langconfig.dirname(relname)
        new_importer_dir = old_importer_dir
      end

      local abs = project_dir .. PATHSEP .. relname:gsub("/", PATHSEP)
      local fp = io.open(abs, "rb")
      if fp then
        local content = fp:read("*a") or ""
        fp:close()

        -- a preview (if there was one) keyed its selection by each
        -- file's *pre-move* name -- this loop runs post-move, so a file
        -- that just relocated needs to be looked up under its old name
        local selector_key = old_rel_for_this or relname
        local is_line_selected = make_line_selector(selection, selector_key)

        local new_content, changes = process_file_imports(
          content, lang, old_importer_dir, new_importer_dir,
          data.mapping_by_exact, data.mapping_by_noext, is_line_selected
        )

        local applied = 0
        for _, c in ipairs(changes) do
          if not is_line_selected or is_line_selected(c.line) then
            applied = applied + 1
          end
        end

        if applied > 0 then
          local wf = io.open(abs, "wb")
          if wf then
            wf:write(new_content)
            wf:close()
            files_changed = files_changed + 1
            imports_changed = imports_changed + applied
            reload_if_open(relname, abs)
          end
        end
      end
    end
  end

  reload_if_open(data.new_rel, data.new_abs)

  if data.moved_has_known_language then
    core.status_view:show_message("i", nil, string.format(
      "moved %s -> %s (%d import(s) updated across %d file(s))",
      data.old_rel, data.new_rel, imports_changed, files_changed))
  else
    core.status_view:show_message("i", nil, string.format(
      "moved %s -> %s (no known language among the moved file(s), imports left untouched)",
      data.old_rel, data.new_rel))
  end
end

-- ---------------------------------------------------------------------------
-- UI entry points
-- ---------------------------------------------------------------------------

-- computes the preview and opens a MoveView with it, letting the user
-- review/deselect individual references before anything actually moves.
-- If nothing at all references the moved file/folder, there's nothing
-- to review, so the move just happens immediately instead.
function movefile.open_preview(old_rel, new_rel)
  local preview, err = movefile.preview(old_rel, new_rel)
  if not preview then
    core.error("refactor: %s", err)
    return
  end

  if #preview.files == 0 then
    movefile.perform(old_rel, new_rel)
    return
  end

  local MoveView = require "plugins.refactor.moveview"
  local node = core.root_view:get_active_node_default()
  node:add_view(MoveView(preview))
end

-- prompt for a destination, then open the preview for it
function movefile.prompt_move(old_abs_path)
  local project_dir = fsutils.project_dir()
  local old_rel = old_abs_path
  if old_rel:sub(1, #project_dir) == project_dir then
    old_rel = old_rel:sub(#project_dir + 2) -- strip "project_dir" + separator
  end
  old_rel = langconfig.to_unix(old_rel)

  local is_dir = fsutils.is_dir(old_abs_path)
  local prompt_title = is_dir and "Move directory to" or "Move file to"

  core.command_view:enter(prompt_title, {
    text = old_rel,
    submit = function(new_rel)
      if new_rel == "" or langconfig.normalize_rel(new_rel) == langconfig.normalize_rel(old_rel) then
        return
      end
      movefile.open_preview(old_rel, new_rel)
    end,
  })
end

return movefile
