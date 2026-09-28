// The C interface of the embedded Godot 3 engine (Godot3.framework): imported Godot 3 PCK exports.
//
// Like op_godot.h for Godot 4: Godot 3's iOS platform is a static library for Godot's own app; these functions do what
// its AppDelegate does at launch. Its Objective-C classes are compiled with a GD3 prefix (GD3AppDelegate, ...) so they
// cannot collide with anything else in the process. One game per process. Main thread only.

#ifndef OP_GODOT3_H
#define OP_GODOT3_H

#ifdef __cplusplus
extern "C" {
#endif

enum { OP_GODOT3_COMMAND_RUN = 0, OP_GODOT3_COMMAND_PAUSE = 1, OP_GODOT3_COMMAND_STOP = 2 };
enum { OP_GODOT3_STATUS_IDLE = 0, OP_GODOT3_STATUS_SET_UP = 1, OP_GODOT3_STATUS_RUNNING = 2, OP_GODOT3_STATUS_PAUSED = 3,
       OP_GODOT3_STATUS_STOPPED = 4, OP_GODOT3_STATUS_FAILED = 5 };

const char *op_godot3_version(void);

// Godot's command line (argv[0] is a path whose folder becomes the working directory), user:// and the cache.
int op_godot3_setup(int argc, char **argv, const char *user_dir, const char *cache_dir);

// A scene-less UIWindow whose root is Godot's view controller; the host places it in its scene.
void *op_godot3_window(void);

void op_godot3_request(int command);
int op_godot3_status(void);
unsigned long op_godot3_frames(void);
void op_godot3_app_event(int event);

// A key from the host's touch controls, by Godot's key name ("Up", "Z", "Shift"); unknown names are ignored.
void op_godot3_key(const char *name, int pressed);

#ifdef __cplusplus
}
#endif

#endif
