# Replaces Ren'Py's iossupport module, which sitecustomize imports at startup on iOS. The original sends
# stdout and stderr to an Objective-C Log class through pyobjus and routes webbrowser to openURL. OmniPlay
# writes the engine's output to the session log the host names, and keeps games from leaving the app.
# Python 2.7 and 3 alike.

import os
import sys


# The open file stays at module level: Ren'Py's own log objects keep a reference to sys.stdout, and Ren'Py
# snapshots its modules by pickling them, so the stream object itself must hold nothing unpicklable.
_file = None


class LogFile(object):
    encoding = "utf-8"
    errors = "replace"

    def write(self, s):
        if not isinstance(s, bytes):
            s = s.encode("utf-8", "replace")
        _file.write(s)

    def writelines(self, lines):
        for line in lines:
            self.write(line)

    def flush(self):
        pass

    def isatty(self):
        return False

    def fileno(self):
        return _file.fileno()


_path = None


def open_log(path):
    """Sends the engine's output to `path` from now on; each game an engine runs logs into its own session."""
    global _file, _path
    if not path or path == _path:
        return
    old = _file
    # Unbuffered, so the last lines before a crash are on disk.
    _file = open(path, "ab", 0)
    _path = path
    sys.stdout = sys.stderr = LogFile()
    if old is not None:
        old.close()


open_log(os.environ.get("OMNIPLAY_RENPY_LOG"))


def open_url(url, *args, **kwargs):
    sys.stdout.write("OmniPlay: blocked opening %s\n" % (url,))
    return False


import webbrowser  # noqa: E402

webbrowser.open = open_url
webbrowser.open_new = open_url
webbrowser.open_new_tab = open_url
