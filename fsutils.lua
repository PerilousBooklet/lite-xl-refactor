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

--- Lists every regular file in the project, as paths relative to the
-- project root. Prefers core's own (already-filtered, already-ignored-dirs)
-- index when available, falling back to a manual recursive scan.
-- Shared by refactorview.lua (project-wide find) and movefile.lua
-- (import-reference scanning) so both stay in sync.
function fsutils.collect_project_files()
  local files = {}

  if core.project_files then
    for _, entry in ipairs(core.project_files) do
      if entry.type == "file" then
        table.insert(files, entry.filename)
      end
    end
  end

  if #files > 0 then return files end

  -- fallback: walk the project directory manually
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
          else
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
