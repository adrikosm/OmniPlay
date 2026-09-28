# OmniPlay's hook into every game it runs. omniplay_host.py copies this file into a host folder on the search
# path, so it is loaded like any of the game's own scripts. Kept to what 7.x and 8.x both understand.

init 999 python hide:
    import omniplay_host
    import os

    # The scripts loaded and initialised: errors from here on get Ren'Py's own error screen (see start_session).
    os.environ.pop("RENPY_SIMPLE_EXCEPTIONS", None)

    # Ren'Py Sync uploads saves to sync.renpy.org. OmniPlay has no network; fail closed instead of timing out.
    if hasattr(config, "has_sync"):
        config.has_sync = False

    config.periodic_callbacks.append(omniplay_host.periodic)

    # Developer switches the player turned on in Ren'Py Tools; the game's own files stay as they are.
    switches = omniplay_host.switches()
    if switches.get("developer"):
        config.developer = True
    if switches.get("console"):
        config.console = True
    if switches.get("rollback"):
        config.rollback_enabled = True
        config.hard_rollback_limit = 256
    if switches.get("skipUnseen"):
        config.allow_skipping = True
        preferences.skip_unseen = True
    if switches.get("skipSplash"):
        config.label_overrides["splashscreen"] = "_omniplay_no_splash"

    # Translation packs: an MTool dictionary filters dialogue and menu text; a tl/ pack sets the language.
    if omniplay_host.load_translation():
        # 8.x keeps a list of filters; 7.x has one, which the dictionary goes in front of.
        try:
            config.say_menu_text_filters.append(omniplay_host.translate_text)
        except Exception:
            config.say_menu_text_filter = omniplay_host.chain_text_filter(config.say_menu_text_filter)
        # DejaVu Sans, Ren'Py's default, has no CJK: translated CJK text takes those glyphs from OmniPlay's font.
        if omniplay_host.cjk_font():
            omniplay_host.apply_cjk_font(renpy.style.styles, FontGroup, omniplay_host.cjk_font())
    if omniplay_host.language():
        config.default_language = omniplay_host.language()
        if hasattr(config, "language"):
            config.language = omniplay_host.language()

    # Media the engine cannot decode was converted before launch; the game still asks for it by its old name.
    if omniplay_host.has_media_remap():
        omniplay_host.chain_open(config.file_open_callback)
        config.file_open_callback = omniplay_host.open_media
        omniplay_host.hint_converted_images(renpy.display.pgrender)

label _omniplay_no_splash:
    return
