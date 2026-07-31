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

-- ---------------------------------------------------------------------------
-- shared helper for C and C++, which only differ in which extensions they
-- claim -- the #include syntax and rewrite rules are identical
-- ---------------------------------------------------------------------------

local function make_c_family_language(extensions)
  return {
    extensions = extensions,
    import_patterns = {
      -- Only the quoted form (#include "foo.h") is a relative,
      -- project-local include. Angle-bracket includes (#include <vector>)
      -- are always system/library headers, so they're intentionally not
      -- matched at all -- there's nothing in the project to rewrite them
      -- to. Matching "anything but a quote" (rather than a %w-style
      -- class) so unusual-but-legal header names/paths aren't missed.
      "#include%s*\"([^\"]+)\"",
    },
    only_relative = true,
    -- Unlike JS/HTML, a quoted C/C++ include is not required to start
    -- with "./" -- and, like HTML (and unlike JS), it keeps its file
    -- extension. So this is intentionally just a unix-path conversion:
    -- no prefix added, no extension stripped.
    path_to_import = function(rel_path)
      return config.to_unix(rel_path)
    end,
    import_to_path = function(import_str, importer_dir)
      local combined = (importer_dir ~= "" and (importer_dir .. "/") or "") .. import_str
      return config.normalize_rel(combined)
    end,
  }
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

  c = make_c_family_language({ "c", "h" }),

  cpp = make_c_family_language({ "cpp", "cc", "cxx", "hpp", "hh", "hxx", "tpp", "ipp" }),

  java = {
    extensions = { "java" },
    import_patterns = {
      -- "import static a.b.C.d;" must be tried before the plain import
      -- pattern below. Lua patterns have no alternation, so this needs
      -- to be its own entry rather than an "(?:static%s+)?" group --
      -- and it has to come first, otherwise the plain pattern below
      -- would match first and incorrectly capture the literal word
      -- "static" as the imported name. (If that ever did happen, it's
      -- harmless: "static" won't match any real file path, so nothing
      -- gets rewritten -- but there's no reason to let it happen.)
      "import%s+static%s+([%w_%.]+)%s*;",
      "import%s+([%w_%.]+)%s*;",
    },
    only_relative = false,
    -- "com/foo/Bar.java" -> "com.foo.Bar" (dotted, no extension)
    -- Same caveat as the python entry above, but sharper: this assumes
    -- the project root itself is the Java source root. Real Java
    -- projects almost always root their imports a few directories
    -- below the project root instead (e.g. Maven/Gradle's
    -- src/main/java), which this plugin has no way to detect on its
    -- own -- so import rewriting will silently do nothing for those
    -- layouts rather than rewriting the wrong thing.
    path_to_import = function(rel_path)
      local no_ext = config.strip_ext(config.to_unix(rel_path))
      return (no_ext:gsub("/", "."))
    end,
    import_to_path = function(import_str)
      return (import_str:gsub("%.", "/"))
    end,
  },

  go = {
    extensions = { "go" },
    import_patterns = {
      -- single-line form: import "fmt"  /  import alias "some/pkg"
      "import%s+[%w_]*%s*\"([%w_%.%-/]+)\"",
      -- one entry of a grouped import block, e.g.
      --   import (
      --       "fmt"
      --       alias "some/pkg"
      --   )
      -- anchored on the leading newline + indentation so an arbitrary
      -- quoted string elsewhere in the file isn't picked up as an import
      "\n%s+[%w_]*%s*\"([%w_%.%-/]+)\"",
    },
    only_relative = false,
    -- IMPORTANT CAVEAT, bigger than the ones above: Go doesn't import
    -- individual files at all -- it imports *packages* (directories),
    -- and how an import path maps to a filesystem path depends on the
    -- module path declared in go.mod (or GOPATH, for old-style
    -- workspaces), neither of which this plugin has any visibility
    -- into. What's below is a best-effort approximation that treats
    -- the import path as if it were rooted directly at the project
    -- root, which is only correct for a single-module project with no
    -- import-path remapping. It also means moving a file *within* its
    -- existing package -- the common case -- will compute the same
    -- "import" (the directory doesn't change) and correctly trigger no
    -- rewrite, but moving a file *between* packages will rewrite the
    -- whole package import path project-wide, which is only right if
    -- every file in the old package moved too. Treat Go support here
    -- as considerably less reliable than the other languages.
    path_to_import = function(rel_path)
      return config.dirname(config.to_unix(rel_path))
    end,
    import_to_path = function(import_str)
      return import_str
    end,
  },

}

return config
