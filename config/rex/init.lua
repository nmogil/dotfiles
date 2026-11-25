-- Image paste is separate from Cmd+V, which remains Rex's normal text paste.
-- Module pinned in rex-image-paste/UPSTREAM.md; no automatic downloads.
require("rex-image-paste").setup()
rex.bind("cmd+shift+v", "image_paste")

-- Optional private overlay (installed by ./dot rex config from the private companion).
-- Rex puts the loaded config file's directory first on package.path
-- ("<dir>/?.lua"), so this also works with a custom REX_CONFIG. Load the overlay
-- only if its file exists there, then require it normally so that every error
-- inside it fails the config.
local config_dir = package.path:match("^([^;]*)%?%.lua")
if not config_dir then
  error("dotfiles: cannot find the Rex config directory in package.path", 0)
end
local function file_exists(path)
  local file = io.open(path, "r")
  if file then
    file:close()
    return true
  end
  return false
end
if file_exists(config_dir .. "dotfiles_private.lua")
  or file_exists(config_dir .. "dotfiles_private/init.lua") then
  require("dotfiles_private")
end
