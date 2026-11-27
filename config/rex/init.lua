-- Image paste is separate from Cmd+V, which remains Rex's normal text paste.
-- Module pinned in rex-image-paste/UPSTREAM.md; no automatic downloads.
require("rex-image-paste").setup()
rex.bind("cmd+shift+v", "image_paste")

-- Program resume (OSC 7577): Pi 1.7+ reports how to reopen its session, and Rex
-- runs that command after a server restart only if a rule trusts it. Rex
-- (preview.25) ships no Pi rule yet. Pi reports `pi --session <id>`, plus
-- `--agent-dir <dir>` (and `--session-dir <dir>` when it isn't the default) for
-- a non-default profile such as ~/.pi/agent-work. No `flags` tables: Pi's docs say
-- they don't work for Pi yet. Rex never runs program resume as root.
-- See docs/rex-image-paste.md ("Program resume").
if rex.match then
  rex.set("resume.trust.pi", { command = { "pi", "--session", rex.match.uuid } })
  rex.set("resume.trust.pi_profile", {
    command = { "pi", "--agent-dir", rex.match.under("~/.pi"), "--session", rex.match.uuid },
  })
  rex.set("resume.trust.pi_profile_sessions", {
    command = {
      "pi", "--agent-dir", rex.match.under("~/.pi"),
      "--session-dir", rex.match.under("~/.pi"), "--session", rex.match.uuid,
    },
  })
end

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
