// The two calls app_bridge.h does not make, because they belong to the host and not to the engine:
// starting the engine's own entry point, and saying whether it is linked at all.
//
// OmniPlay keeps SwiftUI's @main and therefore does not link SDL2main, whose main() would call
// UIApplicationMain with SDL's app delegate. The host owns UIApplication; the engine's entry point
// (SDL_main after SDL's main macro renames it) is called on the main thread instead, once per process.
// It blocks in mkxp_waitForGamePath(), which pumps CFRunLoop so UIKit keeps drawing, and afterwards SDL's
// own event pump keeps the run loop alive for the rest of the session.

#ifndef OMNIPLAY_MKXP_H
#define OMNIPLAY_MKXP_H

#ifdef __cplusplus
extern "C" {
#endif

// 1 when the engine objects are in this binary, 0 on the Mac where the bridge is header stubs.
int omniplay_mkxp_linked(void);

// Runs the engine on the calling thread, which must be the main thread, and returns its exit status.
// Returns before doing anything where the engine is not linked. One call per process: the Ruby VM it
// starts cannot be re-initialised, so the engine dies with the session and the slot is spent.
int omniplay_mkxp_run(void);

#ifdef __cplusplus
}
#endif

#endif
