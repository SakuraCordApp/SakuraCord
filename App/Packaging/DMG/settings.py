import os


application = os.environ["SAKURACORD_DMG_APP_BUNDLE"]
background_image = os.environ["SAKURACORD_DMG_BACKGROUND"]

format = "UDZO"
filesystem = "HFS+"
compression_level = 9

files = [application]
symlinks = {"Applications": "/Applications"}
hide_extensions = []

background = background_image
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
arrange_by = None
show_icon_preview = True
show_item_info = False
label_pos = "bottom"
text_size = 14
icon_size = 128

window_rect = ((160, 100), (858, 400))
icon_locations = {
    "SakuraCord.app": (221, 190),
    "Applications": (637, 190),
}
