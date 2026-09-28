// app_bridge.h is header-only: it declares the live bridge on iOS and degrades to inline no-op stubs
// elsewhere, so this package compiles and tests on the Mac without the engine objects. The engine boot in
// omniplay_mkxp.h is the one thing the host has to implement itself; see that header for why.
#include "app_bridge.h"
#include "omniplay_mkxp.h"

#if MKXPZ_MOBILE

// The engine's own entry point and the two calls SDL's own main() makes around it. Declared rather than
// included: pulling in SDL_main.h would drag SDL's headers into a module Swift imports, and these three
// symbols are all of SDL the host needs.
extern int SDL_main(int argc, char *argv[]);
extern void SDL_SetMainReady(void);
extern void SDL_iPhoneSetEventPump(int enabled);

int omniplay_mkxp_linked(void) { return 1; }

int omniplay_mkxp_run(void) {
    // Both of these are what SDL_UIKitRunApp does around SDL_main, and both matter here.
    // Without SDL_SetMainReady, SDL_Init refuses to start at all. Without the event pump, SDL_PumpEvents
    // returns without spinning CFRunLoop, so UIKit stops drawing and the main queue stops draining the
    // moment the engine takes the main thread: a black window and a frozen host.
    SDL_SetMainReady();
    SDL_iPhoneSetEventPump(1);
    // Static so argv[0], which the engine keeps as its PhysFS base name, outlives every frame of this call.
    static char arg0[] = "OmniPlay";
    static char *argv[] = {arg0, 0};
    int status = SDL_main(1, argv);
    SDL_iPhoneSetEventPump(0);
    return status;
}

#else

int omniplay_mkxp_linked(void) { return 0; }
int omniplay_mkxp_run(void) { return -1; }

#endif
