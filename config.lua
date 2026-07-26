-- Per-language definitions used by the refactor plugin to detect and
-- rewrite import/require statements when a file is moved.
--
-- To support a new language, add an entry to `languages` below; nothing
-- else in the plugin needs to change.
--
-- Each entry needs:
--   extensions      : list of file extensions (no dot) this language uses
--   import_patterns : list of Lua patterns, each with exactly one capture
--                      group that captures the import/module string
--   only_relative   : true if imports are relative to the importing file
--                      (e.g. JS "./foo"); false if they're rooted at the
--                      project root (e.g. Lua/Python dotted modules)
--   path_to_import(str, importer_dir)
--                    : converts a project-relative path (or, for
--                      only_relative languages, a path already made
--                      relative to importer_dir) into this language's
--                      import syntax
--   import_to_path(import_str, importer_dir)
--                    : converts a captured import string back into a
--                      project-relative path (extension-less; comparison
--                      against the moved file is done extension-agnostic)

local config = {}

function config.to_unix(path)
  return (path:gsub("\\", "/"))
end

function config.strip_ext(path)
  return (path:gsub("%.[^./\\]+$", ""))
end

function config.dirname(path)
  path = config.to_unix(path)
  return path:match("^(.*)/[^/]+$") or ""
end

-- collapses "./" and resolves ".." segments in a project-relative path
function config.normalize_rel(path)
  path = config.to_unix(path)
  local parts = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." then
      if #parts > 0 and parts[#parts] ~= ".." then
        table.remove(parts)
      else
        table.insert(parts, part)
      end
    elseif part ~= "." then
      table.insert(parts, part)
    end
  end
  return table.concat(parts, "/")
end

-- path of `target` (project-relative) expressed relative to `from_dir`
-- (also project-relative), e.g. relative_path("src/utils/bar.js", "src/components")
-- -> "../utils/bar.js"
function config.relative_path(target, from_dir)
  target = config.to_unix(target)
  from_dir = config.to_unix(from_dir or "")

  local function split(p)
    local parts = {}
    for part in p:gmatch("[^/]+") do table.insert(parts, part) end
    return parts
  end

  local from_parts = split(from_dir)
  local to_parts = split(target)

  local i = 1
  while from_parts[i] and to_parts[i] and from_parts[i] == to_parts[i] do
    i = i + 1
  end

  local rel_parts = {}
  for _ = 1, (#from_parts - i + 1) do table.insert(rel_parts, "..") end
  for j = i, #to_parts do table.insert(rel_parts, to_parts[j]) end

  local rel = table.concat(rel_parts, "/")
  return rel ~= "" and rel or "."
end

config.languages = {

  lua = {
    extensions = { "lua" },
    import_patterns = {
      "require%s*%(?%s*[\"']([%w%.%_%-/]+)[\"']%)?",
    },
    only_relative = false,
    -- "a/b/c" -> "a.b.c" (dotted, no extension)
    path_to_import = function(rel_path)
      local no_ext = config.strip_ext(config.to_unix(rel_path))
      return (no_ext:gsub("/", "."))
    end,
    -- "a.b.c" -> "a/b/c" (project-relative, no extension)
    import_to_path = function(import_str)
      return (import_str:gsub("%.", "/"))
    end,
  },

  javascript = {
    extensions = { "js", "jsx", "ts", "tsx", "mjs", "cjs" },
    import_patterns = {
      "from%s+[\"'](%.[%w%.%_%-/]+)[\"']",
      "require%s*%(%s*[\"'](%.[%w%.%_%-/]+)[\"']%s*%)",
      "import%s*%(%s*[\"'](%.[%w%.%_%-/]+)[\"']%s*%)", -- dynamic import()
    },
    only_relative = true, -- ignore bare specifiers like "react"
    -- `rel_path` here is already relative to the importer's directory
    -- (the caller computes that via config.relative_path first)
    path_to_import = function(rel_path)
      local no_ext = config.strip_ext(config.to_unix(rel_path))
      if not no_ext:match("^%.%.?/") then
        no_ext = "./" .. no_ext
      end
      return no_ext
    end,
    import_to_path = function(import_str, importer_dir)
      local combined = (importer_dir ~= "" and (importer_dir .. "/") or "") .. import_str
      return config.normalize_rel(combined)
    end,
  },

  html = {
    extensions = { "html", "htm" },
    import_patterns = {
      "src%s*=%s*[\"'](%.[%w%.%_%-/]+)[\"']",  -- <script src="./foo.js">, <img src="./foo.png">
      "href%s*=%s*[\"'](%.[%w%.%_%-/]+)[\"']",  -- <link href="./foo.css">, <a href="./foo.html">
    },
    only_relative = true,
    -- unlike JS import specifiers, HTML attribute references keep their
    -- file extension (src="./foo.js", not src="./foo") -- so, unlike the
    -- javascript entry above, no strip_ext here
    path_to_import = function(rel_path)
      local unix_path = config.to_unix(rel_path)
      if not unix_path:match("^%.%.?/") then
        unix_path = "./" .. unix_path
      end
      return unix_path
    end,
    import_to_path = function(import_str, importer_dir)
      local combined = (importer_dir ~= "" and (importer_dir .. "/") or "") .. import_str
      return config.normalize_rel(combined)
    end,
  },

  python = {
    extensions = { "py" },
    import_patterns = {
      "from%s+([%w_%.]+)%s+import",
      "import%s+([%w_%.]+)",
    },
    only_relative = false,
    path_to_import = function(rel_path)
      local no_ext = config.strip_ext(config.to_unix(rel_path))
      return (no_ext:gsub("/", "."))
    end,
    import_to_path = function(import_str)
      return (import_str:gsub("%.", "/"))
    end,
  },

}

return config
