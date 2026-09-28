// The C interface of the embedded ScummVM (ScummVM.framework): adventure games and interactive fiction.
//
// ScummVM is a separate dylib, dlopened on first use like the EasyRPG Player; these functions are its only exported
// symbols. Unlike the other engines it is built to switch games: op_scummvm_start runs scummvm_main on its own thread
// once per process, and where ScummVM would show its launcher the thread waits for the host instead. Between games
// it detects folders (op_scummvm_detect); op_scummvm_play hands it the next game.
//
// Paths: ScummVM's filesystem is chrooted to the app's home directory (NSHomeDirectory()), so every path given to it,
// in settings or on the command line, is relative to that directory and starts with "/".
//
// Threading: UIKit functions are called from the main thread; detect runs off it. The engine draws through its UIWindow
// (op_scummvm_window), which the host places in its scene.

#ifndef OP_SCUMMVM_H
#define OP_SCUMMVM_H

#ifdef __cplusplus
extern "C" {
#endif

// Host → ScummVM requests while a game runs.
enum {
    OP_SCUMMVM_COMMAND_RUN = 0,
    OP_SCUMMVM_COMMAND_PAUSE = 1,
    OP_SCUMMVM_COMMAND_LEAVE = 2,  // back to waiting for the next game (ScummVM's return to launcher)
};

enum {
    OP_SCUMMVM_STATUS_NOT_STARTED = 0,
    OP_SCUMMVM_STATUS_WAITING = 1,  // between games: detect and play are accepted
    OP_SCUMMVM_STATUS_STARTING = 2, // a game was handed over and is being identified and started
    OP_SCUMMVM_STATUS_PLAYING = 3,
    OP_SCUMMVM_STATUS_PAUSED = 4,
    OP_SCUMMVM_STATUS_EXITED = 5,   // scummvm_main returned; not restartable in this process
};

// The ScummVM release this framework carries, e.g. "2026.3.0".
const char *op_scummvm_version(void);

// Creates the game view and window and starts scummvm_main on the engine thread with argv (argv[0] is ignored),
// typically {"scummvm", "-c", "/Library/Caches/…/scummvm.ini"}. Returns 1, or 0 when it already ran. Returns before
// the thread reaches WAITING.
int op_scummvm_start(int argc, char **argv);

int op_scummvm_status(void);

// While WAITING: identifies the game in the folder at `path` with ScummVM's own detection and writes a JSON array of
// candidates, best first ([{"engineid","gameid","description","language","platform","extra"}]) into out. Blocks the
// caller for at most 30 seconds. Returns the number of candidates, 0 for none, -1 when busy, exited or timed out.
int op_scummvm_detect(const char *path, char *out, int size);

// While WAITING: starts the game described by `settings`, "key=value" lines for its config domain (path and
// savepath required; engineid and gameid optional, detected from path when missing; any other ScummVM key allowed).
// Returns 1 when handed over, 0 when not WAITING.
int op_scummvm_play(const char *settings);

// Why the last game ended: 0 when it quit normally or was left, otherwise ScummVM's error code; `out` gets ScummVM's
// message for it.
int op_scummvm_last_result(char *out, int size);

void op_scummvm_request(int command);

// Frames the engine has polled since start; stops advancing while it is paused, waiting, or stuck.
unsigned long op_scummvm_frames(void);

// A key press with release, as a ScummVM keycode (Common::KeyCode, e.g. 27 Escape, 13 Return) and its character.
void op_scummvm_key(int keycode, int ascii);

// Opens ScummVM's in-game menu (save, load, options), as its own two-finger gesture would.
void op_scummvm_main_menu(void);

// The UIWindow holding ScummVM's view; created by op_scummvm_start without a scene.
void *op_scummvm_window(void);

// Appends ScummVM's messages to the file at `path` (a real path, not chrooted) from now on; NULL stops.
void op_scummvm_log(const char *path);

// 0 will resign active, 1 did enter background, 2 will enter foreground, 3 did become active.
void op_scummvm_app_event(int event);

#ifdef __cplusplus
}
#endif

#endif
