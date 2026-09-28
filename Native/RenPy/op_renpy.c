// The host side of one Ren'Py engine framework. Everything Ren'Py-specific happens in Python (base/main.py and
// base/omniplay_host.py); this file only replaces the prototype's main.c and gives the host a mailbox.
//
// The prototype app boots through SDL_UIKitRunApp, which makes SDL the app delegate and calls launcher_main
// from inside UIApplicationMain. OmniPlay owns UIApplication, so it calls op_renpy_run on the main thread
// instead and owes SDL the two calls SDL_UIKitRunApp would have made around launcher_main.
//
// SDL's headers are not part of the renios package, so the handful of SDL declarations used here are written
// out. They are stable across the SDL 2.0.20 builds all three engines ship.

#include "op_renpy.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifndef OP_RENPY_VERSION
#error "OP_RENPY_VERSION must be defined by the build (e.g. -DOP_RENPY_VERSION=\"8.5.3\")"
#endif

#define OP_EXPORT __attribute__((visibility("default")))

// librenpython.a: the launcher Ren'Py's own executables call. It finds base/ beside argv[0], sets up Python
// (the Python 2 and 3 builds differ here, which is why the host never initialises Python itself) and runs
// base/main.py.
extern int launcher_main(int argc, char **argv);

// libSDL2.a
typedef struct SDL_Window SDL_Window;
typedef struct {
    uint8_t major, minor, patch;
} SDL_version;
typedef struct {
    SDL_version version;
    int subsystem;
    union {
        struct {
            void *window;
            unsigned int framebuffer, colorbuffer, resolveFramebuffer;
        } uikit;
        uint8_t dummy[64];
    } info;
} SDL_SysWMinfo;

extern void SDL_SetMainReady(void);
extern void SDL_iPhoneSetEventPump(int enabled);
extern SDL_Window *SDL_GetWindowFromID(uint32_t id);
extern int SDL_GetWindowWMInfo(SDL_Window *window, SDL_SysWMinfo *info);
extern void SDL_OnApplicationWillResignActive(void);
extern void SDL_OnApplicationDidEnterBackground(void);
extern void SDL_OnApplicationWillEnterForeground(void);
extern void SDL_OnApplicationDidBecomeActive(void);
extern void SDL_OnApplicationDidReceiveMemoryWarning(void);

// MetalANGLE: one of its functions pins the image the GL lookups below go to.
extern void *eglGetDisplay(void *display_id);

// SDL looks every GL function up with dlsym(RTLD_DEFAULT, name), which answers with the first loaded image that
// exports the name. In OmniPlay that is Apple's OpenGLES, loaded at launch for mkxp-z, whose glGetString has no
// context and returns NULL. build-renpy.sh relinks SDL_uikitopengles.o with its dlsym reference renamed to this
// function, which asks MetalANGLE first.
void *opdls(void *handle, const char *name) {
    static void *angle;
    if (handle == RTLD_DEFAULT) {
        if (!angle) {
            Dl_info info;
            if (dladdr((void *)eglGetDisplay, &info)) angle = dlopen(info.dli_fname, RTLD_LAZY | RTLD_NOLOAD);
        }
        void *found = angle ? dlsym(angle, name) : NULL;
        if (found) return found;
    }
    return dlsym(handle, name);
}

// SDL's GLES1 renderer calls three entry points only Apple's OpenGLES has. Ren'Py never selects that renderer,
// so no-op stand-ins keep Apple's GL out of the framework's link entirely.
void glBlendEquationOES(unsigned int mode) { (void)mode; }
void glBlendEquationSeparateOES(unsigned int rgb, unsigned int alpha) { (void)rgb; (void)alpha; }
void glBlendFuncSeparateOES(unsigned int a, unsigned int b, unsigned int c, unsigned int d) { (void)a; (void)b; (void)c; (void)d; }

static atomic_int command = OP_RENPY_COMMAND_RUN;
static atomic_int status = OP_RENPY_STATUS_IDLE;

OP_EXPORT const char *op_renpy_version(void) { return OP_RENPY_VERSION; }

OP_EXPORT int op_renpy_run(int argc, char **argv) {
    atomic_store(&command, OP_RENPY_COMMAND_RUN);
    atomic_store(&status, OP_RENPY_STATUS_BOOTING);
    // Without SDL_SetMainReady SDL_Init refuses to start. Without the event pump SDL_PumpEvents returns without
    // spinning CFRunLoop, and the host freezes the moment the engine has the main thread.
    SDL_SetMainReady();
    SDL_iPhoneSetEventPump(1);
    int rc = launcher_main(argc, argv);
    SDL_iPhoneSetEventPump(0);
    atomic_store(&status, OP_RENPY_STATUS_EXITED);
    return rc;
}

OP_EXPORT void op_renpy_request(int value) { atomic_store(&command, value); }
OP_EXPORT int op_renpy_command(void) { return atomic_load(&command); }
OP_EXPORT void op_renpy_set_status(int value) { atomic_store(&status, value); }
OP_EXPORT int op_renpy_status(void) { return atomic_load(&status); }

// Written by the host and read by Python, both on the main thread.
static char *session;

OP_EXPORT void op_renpy_set_session(const char *json) {
    free(session);
    session = json ? strdup(json) : NULL;
}

OP_EXPORT const char *op_renpy_session(void) { return session; }

// Typed state requests (the Game Tools): the host leaves one JSON request and a reply callback; Python takes it at
// its next periodic tick, or while the game is paused, and answers through op_renpy_state_reply. One request is in
// flight at a time, and every call is on the main thread.
typedef void (*op_renpy_state_reply_fn)(void *context, const char *json);
static char *state_request;
static op_renpy_state_reply_fn state_reply_fn;
static void *state_context;

OP_EXPORT int op_renpy_state_request(const char *json, op_renpy_state_reply_fn reply, void *context) {
    if (state_request || !json) return 0;
    state_request = strdup(json);
    state_reply_fn = reply;
    state_context = context;
    return 1;
}

OP_EXPORT const char *op_renpy_state_take(void) { return state_request; }

static void *state_clear(void) {
    void *context = state_context;
    free(state_request);
    state_request = NULL;
    state_reply_fn = NULL;
    state_context = NULL;
    return context;
}

OP_EXPORT void op_renpy_state_reply(const char *json) {
    op_renpy_state_reply_fn reply = state_reply_fn;
    void *context = state_clear();
    if (reply) reply(context, json);
}

// Drops an unanswered request (the host timed out) and hands its context back for the host to release.
OP_EXPORT void *op_renpy_state_cancel(void) { return state_clear(); }

OP_EXPORT void op_renpy_idle(double seconds) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, true);
    while (CFRunLoopRunInMode(CFSTR("UITrackingRunLoopMode"), 0, true) == kCFRunLoopRunHandledSource) {}
}

OP_EXPORT void *op_renpy_window(void) {
    // Ren'Py opens one window; its id is 1 unless something opened and closed another first.
    for (uint32_t id = 1; id <= 16; id++) {
        SDL_Window *window = SDL_GetWindowFromID(id);
        if (!window) continue;
        SDL_SysWMinfo info = {.version = {2, 0, 20}};
        if (SDL_GetWindowWMInfo(window, &info)) return info.info.uikit.window;
    }
    return NULL;
}

OP_EXPORT void op_renpy_app_event(int event) {
    switch (event) {
    case 0: SDL_OnApplicationWillResignActive(); break;
    case 1: SDL_OnApplicationDidEnterBackground(); break;
    case 2: SDL_OnApplicationWillEnterForeground(); break;
    case 3: SDL_OnApplicationDidBecomeActive(); break;
    case 4: SDL_OnApplicationDidReceiveMemoryWarning(); break;
    default: break;
    }
}
