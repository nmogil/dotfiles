-- Image paste is separate from Cmd+V, which remains Rex's normal text paste.
-- Module pinned in rex-image-paste/UPSTREAM.md; no automatic downloads.
require("rex-image-paste").setup()
rex.bind("cmd+shift+v", "image_paste")
