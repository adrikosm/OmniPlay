// The C interface of the embedded EasyRPG Player (EasyRPG.framework), which plays RPG Maker 2000 and 2003 games.
//
// The Player is a separate dylib so its SDL2, liblcf and codecs stay in their own image; these functions are the
// only symbols it exports. The host never links the framework: it dlopens it on the first RPG Maker 2000/2003
// launch and resolves these names, so the prototypes here are the contract Swift's function types must match.
//
// Threading: op_easyrpg_run takes the main thread for the whole session, exactly as SDL's own UIKit entry point
// would. SDL's event pump spins CFRunLoop between frames, and a paused Player idles in the run loop, so the host's
// UI and main-actor work keep running inside that call; every other function here is called from there.

#ifndef OP_EASYRPG_H
#define OP_EASYRPG_H

#ifdef __cplusplus
extern "C" {
#endif

// Host → Player requests, read between frames.
enum {
    OP_EASYRPG_COMMAND_RUN = 0,
    OP_EASYRPG_COMMAND_PAUSE = 1,
    OP_EASYRPG_COMMAND_STOP = 2,
};

// Player → host progress.
enum {
    OP_EASYRPG_STATUS_IDLE = 0,
    OP_EASYRPG_STATUS_BOOTING = 1,
    OP_EASYRPG_STATUS_RUNNING = 2,
    OP_EASYRPG_STATUS_PAUSED = 3,
    OP_EASYRPG_STATUS_EXITED = 4,
};

// The Player release this framework carries, e.g. "0.8.1.1".
const char *op_easyrpg_version(void);

// Runs the Player on the calling thread, which must be the main thread, until the game quits or the host asks it
// to stop; returns the Player's exit code. argv is the Player's own command line (argv[0] is ignored), e.g.
// `easyrpg-player --project-path <game> --save-path <dir> --config-path <dir>`.
int op_easyrpg_run(int argc, char **argv);

void op_easyrpg_request(int command);
int op_easyrpg_status(void);

// Frames drawn since the Player started; stops advancing while it is paused or stuck.
unsigned long op_easyrpg_frames(void);

// A key press or release, as an SDL scancode (USB HID usage page 0x07).
void op_easyrpg_key(int scancode, int down);

// Writes the current frame as a PNG to `path`; returns 1 on success. Call it while the Player is paused.
int op_easyrpg_snapshot(const char *path);

// The UIWindow SDL opened for the game, or NULL before it exists. SDL creates it without a UIScene, so the host
// attaches it to its own scene; until then the window is never shown.
void *op_easyrpg_window(void);

// Application lifecycle, forwarded to SDL because the host, not SDL, is the app delegate:
// 0 will resign active, 1 did enter background, 2 will enter foreground, 3 did become active, 4 memory warning.
void op_easyrpg_app_event(int event);

// Which RPG Maker 2000/2003 RTP the folder at `path` holds, by the Player's own RTP file tables (eleven official
// and fan releases). Writes the best match as "<2000|2003>\t<name>\t<files found>\t<files expected>" and returns 1,
// or returns 0 when no RTP file is there. Needs no running Player; call it when none is running.
int op_easyrpg_rtp_detect(const char *path, char *out, int size);

#ifdef __cplusplus
}
#endif

#endif
