# dmgbuild settings for MurmurBee's drag-to-Applications window (used by make_dmg.sh).
# Positions match the artwork from scripts/make_dmg_background.swift: app at x 180, Applications at x 480.
app = defines["app"]  # noqa: F821  (dmgbuild injects `defines`)

files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]  # noqa: F821
background = defines["background"]  # noqa: F821

format = "ULFO"  # lzfse: smaller and faster to open than zlib (macOS 10.11+)
window_rect = ((200, 140), (660, 422))  # 400 pt of content + the title bar
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {"MurmurBee.app": (180, 190), "Applications": (480, 190)}
hide_extension = ["MurmurBee.app"]
