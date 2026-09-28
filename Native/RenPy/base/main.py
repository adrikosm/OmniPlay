# OmniPlay's entry point for an embedded Ren'Py engine. launcher_main (librenpython) runs base/main.py; this
# one prepares the host side and hands over to Ren'Py's own renpy.py, which ships beside it unchanged as
# launcher.py (a module named renpy* would be swept into Ren'Py's module snapshot). Written for Python 2.7 and 3:
# the same file goes into all three engine frameworks.

import os
import sys

# Isolated mode keeps the script's own folder off sys.path.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import omniplay_host  # noqa: E402

omniplay_host.install()

try:
    import launcher  # noqa: E402

    launcher.main()
except SystemExit as e:
    # Ren'Py ends every run with sys.exit. Left alone, that reaches Py_Exit and takes the whole app with it;
    # caught here, the script returns and the host gets its main thread back.
    omniplay_host.exited(e.code)
