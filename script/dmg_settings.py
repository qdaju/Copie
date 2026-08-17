from pathlib import Path


project_root = Path(defines.get("project_root", Path.cwd())).resolve()

format = "UDZO"
filesystem = "HFS+"
files = [
    str(project_root / "dist/Copie-1.0.xcarchive/Products/Applications/Copie.app"),
]
symlinks = {"应用程序": "/Applications"}

background = str(
    project_root / "script/assets/dmg-background.png"
)

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
window_rect = ((234, 580), (640, 400))
default_view = "icon-view"

icon_size = 96
text_size = 14
label_pos = "bottom"
show_icon_preview = True
icon_locations = {
    "Copie.app": (180, 220),
    "应用程序": (460, 220),
}
