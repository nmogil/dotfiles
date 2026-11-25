-- Image paste is separate from Cmd+V, which remains Rex's normal text paste.
-- Module pinned in rex-image-paste/UPSTREAM.md; no automatic downloads.
require("rex-image-paste").setup()
rex.bind("cmd+shift+v", "image_paste")

-- Optional private overlay (installed by ./dot rex config from the private companion).
-- Absent overlay: skipped quietly. Any other error inside it still fails the config.
local overlay_ok, overlay_err = pcall(require, "dotfiles_private")
if not overlay_ok then
  local message = tostring(overlay_err)
  local missing = message:find("module dotfiles_private not found", 1, true)
    or message:find("module 'dotfiles_private' not found", 1, true)
  if not missing then
    error(overlay_err, 0)
  end
end
