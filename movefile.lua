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
      local replacement = callback(cap)
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
-- main entry point
-- ---------------------------------------------------------------------------

-- old_rel, new_rel: project-relative paths to a file OR a directory
function movefile.perform(old_rel, new_rel)
  old_rel = langconfig.normalize_rel(langconfig.to_unix(old_rel))
  new_rel = langconfig.normalize_rel(langconfig.to_unix(new_rel))

  if new_rel == "" then
    core.error("refactor: destination path is empty")
    return
  end
  -- normalize_rel collapses "a/../b" down, but can't collapse a leading
  -- ".." (there's nothing to pop), so a surviving ".." here means the
  -- typed path tried to climb above the project root -- reject it rather
  -- than silently moving something out of the project.
  if new_rel == ".." or new_rel:match("^%.%./") then
    core.error("refactor: destination \"%s\" is outside the project folder", new_rel)
    return
  end

  local project_dir = fsutils.project_dir()
  local old_abs = project_dir .. PATHSEP .. old_rel:gsub("/", PATHSEP)
  local new_abs = project_dir .. PATHSEP .. new_rel:gsub("/", PATHSEP)

  if fsutils.is_object_exist(new_abs) then
    core.error("refactor: destination already exists: %s", new_rel)
    return
  end
  if not fsutils.is_object_exist(old_abs) then
    core.error("refactor: source does not exist: %s", old_rel)
    return
  end

  local moving_dir = fsutils.is_dir(old_abs)

  if moving_dir then
    -- guard against moving a directory into (or onto) itself
    local old_prefix = strip_trailing_slash(old_rel) .. "/"
    if strip_trailing_slash(new_rel) == strip_trailing_slash(old_rel)
        or new_rel:sub(1, #old_prefix) == old_prefix then
      core.error("refactor: can't move a directory into itself: %s", new_rel)
      return
    end
  end

  -- snapshot the old -> new path mapping for every file that's about to
  -- move, *before* anything on disk changes
  local mapping = build_move_mapping(old_rel, new_rel, moving_dir)

  local mapping_by_noext = {}
  local mapping_by_exact = {}
  local moved_has_known_language = false
  for old_key, new_val in pairs(mapping) do
    local key_unix = langconfig.to_unix(old_key)
    mapping_by_noext[langconfig.strip_ext(key_unix)] = new_val
    mapping_by_exact[key_unix] = new_val
    if find_language(old_key) then moved_has_known_language = true end
  end

  -- 1. make sure the destination's parent directory exists (os.rename
  --    fails outright otherwise), then move the file/directory on disk.
  --    Everything below reads/writes files at their *new* locations (or
  --    their untouched locations) -- so if the move itself fails, we must
  --    stop here rather than rewrite imports to point at paths that were
  --    never actually created.
  local new_parent = langconfig.dirname(new_rel)
  if new_parent ~= "" then
    fsutils.mkdir_p(project_dir .. PATHSEP .. new_parent:gsub("/", PATHSEP))
  end

  if not fsutils.move_object(old_abs, new_abs) then
    core.error("refactor: move failed, nothing was rewritten")
    return
  end

  -- 2. point any already-open docs at their new location so the reload
  --    step further down (and any other editor bookkeeping) works
  retarget_open_docs(mapping, project_dir)

  -- reverse lookup: given a file's *current* (post-move) path, find the
  -- path it used to have, if it moved at all
  local rev_mapping = {}
  for old_key, new_val in pairs(mapping) do
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

        local changed_this_file = false

        local new_content = rewrite_imports(content, lang, function(import_str)
          local target_old
          if lang.only_relative then
            target_old = lang.import_to_path(import_str, old_importer_dir)
          else
            target_old = lang.import_to_path(import_str)
          end
          target_old = langconfig.normalize_rel(target_old)

          -- if the reference already names a specific extension (HTML
          -- src="./foo.js", or an explicit-extension JS import), match
          -- exactly so moving "foo.js" can't be confused with an
          -- unrelated "foo.png" that merely shares a base name.
          -- Extension-less references (the JS/Lua/Python norm) match
          -- against the noext form as before.
          local mapped_new
          if target_old:match("%.[%w_]+$") then
            mapped_new = mapping_by_exact[target_old]
          else
            mapped_new = mapping_by_noext[langconfig.strip_ext(target_old)]
          end

          if lang.only_relative then
            -- importer didn't move and target didn't move: nothing to do
            if new_importer_dir == old_importer_dir and not mapped_new then
              return nil
            end
            local target_new = mapped_new or target_old
            local rel = langconfig.relative_path(target_new, new_importer_dir)
            local new_import = lang.path_to_import(rel, new_importer_dir)
            if new_import == import_str then return nil end
            changed_this_file = true
            imports_changed = imports_changed + 1
            return new_import
          else
            -- absolute/project-rooted imports (Lua, Python): the
            -- importer's own location is irrelevant to its own
            -- resolution, only whether the *target* moved matters
            if not mapped_new then return nil end
            local new_import = lang.path_to_import(mapped_new)
            if new_import == import_str then return nil end
            changed_this_file = true
            imports_changed = imports_changed + 1
            return new_import
          end
        end)

        if changed_this_file then
          local wf = io.open(abs, "wb")
          if wf then
            wf:write(new_content)
            wf:close()
            files_changed = files_changed + 1
            reload_if_open(relname, abs)
          end
        end
      end
    end
  end

  reload_if_open(new_rel, new_abs)

  if moved_has_known_language then
    core.status_view:show_message("i", nil, string.format(
      "moved %s -> %s (%d import(s) updated across %d file(s))",
      old_rel, new_rel, imports_changed, files_changed))
  else
    core.status_view:show_message("i", nil, string.format(
      "moved %s -> %s (no known language among the moved file(s), imports left untouched)",
      old_rel, new_rel))
  end
end

-- ---------------------------------------------------------------------------
-- UI entry point: prompt for a destination, then perform the move
-- ---------------------------------------------------------------------------

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
      movefile.perform(old_rel, new_rel)
    end,
  })
end

return movefile
