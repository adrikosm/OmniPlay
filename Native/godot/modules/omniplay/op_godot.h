// The C interface of the embedded Godot engine (Godot.framework): imported Godot 4 PCK exports.
//
// Godot's iOS platform is a static library meant for an app whose main and app delegate are Godot's (the export
// template's SwiftUI app). These functions do what that app does, so OmniPlay can own UIApplication: set the engine up
// once, then host Godot's own view controller, whose display link finishes start-up and draws every frame. One game
// per process: Godot's Main cannot be set up twice.
//
// Threading: main thread only.

#ifndef OP_GODOT_H
#define OP_GODOT_H

#ifdef __cplusplus
extern "C" {
#endif

enum { OP_GODOT_COMMAND_RUN = 0, OP_GODOT_COMMAND_PAUSE = 1, OP_GODOT_COMMAND_STOP = 2 };
enum { OP_GODOT_STATUS_IDLE = 0, OP_GODOT_STATUS_SET_UP = 1, OP_GODOT_STATUS_RUNNING = 2, OP_GODOT_STATUS_PAUSED = 3,
       OP_GODOT_STATUS_STOPPED = 4, OP_GODOT_STATUS_FAILED = 5 };

// The engine release, e.g. "4.7.2.stable".
const char *op_godot_version(void);

// Sets the engine up with Godot's own command line (argv[0] is ignored), e.g. `godot --main-pack <game.pck>`, and
// redirects user:// to `user_dir` and the cache to `cache_dir`. Returns 0, or Godot's error code; once per process.
int op_godot_setup(int argc, char **argv, const char *user_dir, const char *cache_dir);

// Godot's view controller (a GDTViewController) for the host to present full screen; created on first call.
void *op_godot_view_controller(void);

void op_godot_request(int command);
int op_godot_status(void);

// Frames drawn since start; stops advancing while paused or stuck.
unsigned long op_godot_frames(void);

// 0 will resign active, 1 did enter background, 2 will enter foreground, 3 did become active, 4 memory warning.
void op_godot_app_event(int event);

// A key from the host's touch controls, by Godot's own key name ("Up", "Z", "Shift", "Escape"); unknown names are
// ignored. Delivered while set up, running or paused, so a release during a pause is not lost.
void op_godot_key(const char *name, int pressed);

#ifdef __cplusplus
}
#endif

#endif
