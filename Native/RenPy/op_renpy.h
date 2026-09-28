// The C interface of one embedded Ren'Py engine (RenPy853.framework, RenPy837.framework, RenPy787.framework).
//
// Each engine is a separate dylib so its CPython, SDL and FFmpeg stay in their own image; these functions are
// the only symbols it exports. The host never links the framework: it dlopens it on the first Ren'Py launch
// and resolves these names, so the prototypes here are the contract Swift's function types must match.
//
// Threading: op_renpy_run takes the main thread for the whole session, exactly as SDL's own UIKit entry point
// would. SDL's event pump spins CFRunLoop between frames, so the host's UI and main-actor work keep running
// inside that call; every other function here is safe to call from there. op_renpy_command is the engine's
// side of the same mailbox and is read by the host's Python module through ctypes.

#ifndef OP_RENPY_H
#define OP_RENPY_H

#ifdef __cplusplus
extern "C" {
#endif

// Host → engine requests, read by the engine at its next periodic tick (about 20 per second).
enum {
    OP_RENPY_COMMAND_RUN = 0,
    OP_RENPY_COMMAND_PAUSE = 1,
    OP_RENPY_COMMAND_STOP = 2,
};

// Engine → host progress, set by the host's Python module.
enum {
    OP_RENPY_STATUS_IDLE = 0,
    OP_RENPY_STATUS_BOOTING = 1,
    OP_RENPY_STATUS_RUNNING = 2,
    OP_RENPY_STATUS_PAUSED = 3,
    OP_RENPY_STATUS_EXITED = 4,
    // The game ended and Python is still alive, waiting inside Ren'Py's own restart loop for the next game.
    OP_RENPY_STATUS_PARKED = 5,
};

// The Ren'Py release this framework carries, e.g. "8.5.3".
const char *op_renpy_version(void);

// Runs Ren'Py on the calling thread, which must be the main thread, until the game quits; returns the exit
// status. argv[0] must be the framework's binary path: the engine finds its `base/` folder (main.py, renpy/,
// lib/pythonX.Y) beside it. The rest is Ren'Py's own command line: `<basedir> --savedir <dir>`.
// One call per process: Python cannot be initialised twice, so the engine is spent when this returns. Leaving a
// game does not return: Python parks in Ren'Py's restart loop (OP_RENPY_STATUS_PARKED) and runs the next game the
// host names, so this call normally lasts for the rest of the process.
int op_renpy_run(int argc, char **argv);

// Host → engine mailbox.
void op_renpy_request(int command);
int op_renpy_command(void);

// Engine → host progress.
void op_renpy_set_status(int status);
int op_renpy_status(void);

// The host's settings for the game to run, as one JSON object (paths for saves, logs, overlays, the pause frame).
// Set before op_renpy_run, and again before the host asks a parked engine to run another game; copied here.
void op_renpy_set_session(const char *json);
const char *op_renpy_session(void);

// Runs the main run loop for up to `seconds` and drains UIKit's tracking mode, the way SDL's own event pump
// does: the paused engine waits here so the host's UI keeps drawing and taking touches.
void op_renpy_idle(double seconds);

// The UIWindow SDL opened for the game, or NULL before it exists. SDL 2.0.20 predates UIScene and creates it
// without one, so the host attaches it to its own scene; until then the window is never shown.
void *op_renpy_window(void);

// Application lifecycle, forwarded to SDL because the host, not SDL, is the app delegate:
// 0 will resign active, 1 did enter background, 2 will enter foreground, 3 did become active, 4 memory warning.
void op_renpy_app_event(int event);

// Typed state requests for the Game Tools, as JSON (RuntimeCore's StateWire protocol). The host enqueues one
// request with a reply callback (returns 0 while another is in flight); Python takes it with op_renpy_state_take and
// answers with op_renpy_state_reply, which calls the callback. op_renpy_state_cancel drops an unanswered request and
// returns its context. All on the main thread.
typedef void (*op_renpy_state_reply_fn)(void *context, const char *json);
int op_renpy_state_request(const char *json, op_renpy_state_reply_fn reply, void *context);
const char *op_renpy_state_take(void);
void op_renpy_state_reply(const char *json);
void *op_renpy_state_cancel(void);

#ifdef __cplusplus
}
#endif

#endif
