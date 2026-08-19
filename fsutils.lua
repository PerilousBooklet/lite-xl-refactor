-- Stolen from the treeview-extender plugin
local core = require "core"
local fsutils = {}

--- Checks whether a file or directory exists
-- @param string path Path of object to be checked
function fsutils.is_object_exist(path)
  local stat = system.get_file_info(path)
  if not stat or (stat.type ~= "file" and stat.type ~= "dir") then
    return false
  end
  return true
end

--- Checks whether an object is a directory
-- @param string path Path of object to be checked
function fsutils.is_dir(path)
  local file_info = system.get_file_info(path)
  if (file_info ~= nil) then
    return file_info.type == "dir"
  end
  return false
end

--- Moves object (file or directory) to another path
-- @param string old_abs_filename Absolute old filename
-- @param string new_abs_filename Absolute new filename
-- @return boolean true on success, false on failure (caller must check --
--         callers that assume a move happened when it didn't will corrupt
--         state, e.g. by rewriting imports to point at paths that were
--         never actually created)
function fsutils.move_object(old_abs_filename, new_abs_filename)
  local res, err = os.rename(old_abs_filename, new_abs_filename)
  if res then -- successfully renamed
    core.log("Moved \"%s\" to \"%s\"", old_abs_filename, new_abs_filename)
    return true
  else
    core.error("Error while moving \"%s\" to \"%s\": %s", old_abs_filename, new_abs_filename, err)
    return false
  end
end

--- Recursively creates a directory and any missing parent directories.
-- Needed before a move/rename into a path whose parent doesn't exist yet
-- (os.rename fails outright in that case).
-- @param string abs_path Absolute directory path to ensure exists
-- @return boolean true if the directory exists (or was created), false on failure
function fsutils.mkdir_p(abs_path)
  abs_path = abs_path:gsub("[/\\]+$", "")
  if abs_path == "" or fsutils.is_dir(abs_path) then return true end

  local parent = abs_path:match("^(.*)[/\\][^/\\]+$")
  if parent and parent ~= "" and not fsutils.is_dir(parent) then
    if not fsutils.mkdir_p(parent) then return false end
  end

  local ok, err = system.mkdir(abs_path)
  if not ok and not fsutils.is_dir(abs_path) then
    core.error("[refactor] failed to create directory \"%s\": %s", abs_path, tostring(err))
    return false
  end
  return true
end

--- Copy source file to destination path
-- @param string source_abs_filename Absolute source filename
-- @param string dest_abs_filename Absolute destination filename
function fsutils.copy_file(source_abs_filename, dest_abs_filename)
  local source_file = io.open(source_abs_filename, "rb")
  local dest_file = io.open(dest_abs_filename, "wb")
  if source_file ~= nil and dest_file ~= nil then
    local chunk_size = 2^13 -- 8KB
    while true do
      local chunk = source_file:read(chunk_size)
      if not chunk then break end
      dest_file:write(chunk)
    end
    source_file:close()
    dest_file:close()
  end
end

function fsutils.project_dir()
  return core.project_dir or core.root_project().path
end

--- Converts an absolute path to a project-relative, unix-style path.
-- Shared by movefile.lua (move destination prompts) and init.lua (the
-- folder-scoped refactor context-menu command) so both compute this the
-- same way.
-- @param string abs_path Absolute path, expected to be inside the project
function fsutils.to_project_rel(abs_path)
  local project_dir = fsutils.project_dir()
  local rel = abs_path
  if rel:sub(1, #project_dir) == project_dir then
    rel = rel:sub(#project_dir + 2) -- strip "project_dir" + separator
  end
  return (rel:gsub("\\", "/"))
end

--- Lists every regular file in the project, as paths relative to the
-- project root. Prefers core's own (already-filtered, already-ignored-dirs)
-- index when available, falling back to a manual recursive scan.
-- Shared by refactorview.lua (project-wide or folder-scoped find) and
-- movefile.lua (import-reference scanning) so both stay in sync.
-- @param string|nil dir_rel If given, only files nested under this
--        project-relative folder are returned. nil/empty means the
--        whole project.
function fsutils.collect_project_files(dir_rel)
  local prefix = nil
  if dir_rel and dir_rel ~= "" then
    prefix = (dir_rel:gsub("\\", "/"):gsub("/+$", "")) .. "/"
  end

  local function matches_prefix(relname)
    if not prefix then return true end
    relname = relname:gsub("\\", "/")
    return relname:sub(1, #prefix) == prefix
  end

  -- NOTE: checking #core.project_files > 0 here (rather than the old
  -- "if #files > 0 then return files end" after filtering) matters for
  -- the scoped case: a folder can legitimately contain zero matching
  -- files, and that must return an empty list, not silently fall through
  -- to a full unscoped scan of the whole project.
  if core.project_files and #core.project_files > 0 then
    local files = {}
    for _, entry in ipairs(core.project_files) do
      if entry.type == "file" and matches_prefix(entry.filename) then
        table.insert(files, entry.filename)
      end
    end
    return files
  end

  -- fallback: walk the project directory manually
  local files = {}
  local function scan(dir, rel)
    local list = system.list_dir(dir) or {}
    for _, name in ipairs(list) do
      if name ~= ".git" then
        local abs = dir .. PATHSEP .. name
        local relname = rel == "" and name or (rel .. PATHSEP .. name)
        local info = system.get_file_info(abs)
        if info then
          if info.type == "dir" then
            scan(abs, relname)
          elseif matches_prefix(relname) then
            table.insert(files, relname)
          end
        end
      end
    end
  end
  scan(fsutils.project_dir(), "")
  return files
end

return fsutils
