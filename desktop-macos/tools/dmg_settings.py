# dmgbuild settings for the drag-and-drop installer.
# Usage: dmgbuild -s tools/dmg_settings.py -D app=<MarkItDown.app> -D background=<file.tiff> \
#            -D icon=<AppIcon.icns> "MarkItDown" <output.dmg>
# dmgbuild writes the Finder window layout (.DS_Store) itself, so no Finder scripting is needed.
import os.path

app = defines["app"]  # noqa: F821 (provided by dmgbuild)
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]  # noqa: F821 (volume icon)

background = defines["background"]  # noqa: F821
window_rect = ((200, 120), (640, 400))
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
icon_size = 112
text_size = 13
arrange_by = None
# Keep in sync with make_dmg_background.swift.
icon_locations = {app_name: (170, 190), "Applications": (470, 190)}
