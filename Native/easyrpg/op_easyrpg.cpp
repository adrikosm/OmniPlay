// The host side of the EasyRPG Player framework: replaces the Player's src/platform/sdl/main.cpp.
//
// SDL's own UIKit entry point would make SDL the app delegate and call main from inside UIApplicationMain.
// OmniPlay owns UIApplication, so it calls op_easyrpg_run on the main thread instead and owes SDL the two calls
// that entry point would have made around main. The run loop is Player::Run's own, with the host's pause and stop
// checked between frames.

#include "op_easyrpg.h"

#include <SDL.h>
#include <SDL_syswm.h>

#include <algorithm>
#include <atomic>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "baseui.h"
#include "filefinder.h"
#include "game_config.h"
#include "game_clock.h"
#include "graphics.h"
#include "output.h"
#include "player.h"
#include "rtp.h"
#include "scene.h"
#include "scene_logo.h"
#include "transition.h"
#include "version.h"

#define OP_EXPORT __attribute__((visibility("default")))

// The SDL2 build comes from the mkxp-z dependency tree, where SDL's GL view reports a lost context to mkxp-z.
// The Player draws with Metal and never reaches that view, so the hook has nothing to tell.
extern "C" void mkxp_setGLContextBroken(void) {}

static std::atomic<int> command{OP_EASYRPG_COMMAND_RUN};
static std::atomic<int> status{OP_EASYRPG_STATUS_IDLE};
static std::atomic<unsigned long> frames{0};

// A tap's release must not beat the Player's logic to the key. The Player loops faster than its 60 Hz logic, so a
// release that arrives soon after the press can land before any logic frame has seen the key down, and the tap is
// lost (about two taps in three on the simulator). A release sooner than this after its press waits in the loop.
// Host key calls and the loop share the main thread, so plain containers are enough.
static constexpr Uint32 min_hold_ms = 50;
static std::map<int, Uint32> pressed_at;
static std::vector<int> held_releases;

static void push_key(int scancode, bool down) {
    SDL_Event event{};
    event.type = down ? SDL_KEYDOWN : SDL_KEYUP;
    event.key.state = down ? SDL_PRESSED : SDL_RELEASED;
    event.key.keysym.scancode = static_cast<SDL_Scancode>(scancode);
    event.key.keysym.sym = SDL_GetKeyFromScancode(event.key.keysym.scancode);
    SDL_PushEvent(&event);
}

// A paused Player waits here. SDL's UIKit event pump spins CFRunLoop in the default and tracking modes, so the
// host's UI keeps drawing and taking touches, sheet scrolling included. (CoreFoundation's own header cannot be
// used in this file: its QuickDraw Rect collides with the Player's.)
static void idle() {
    SDL_PumpEvents();
    SDL_Delay(10);
}

OP_EXPORT const char *op_easyrpg_version(void) { return Version::STRING; }

OP_EXPORT int op_easyrpg_run(int argc, char **argv) {
    command = OP_EASYRPG_COMMAND_RUN;
    status = OP_EASYRPG_STATUS_BOOTING;
    frames = 0;
    // Without SDL_SetMainReady SDL_Init refuses to start. Without the event pump SDL_PumpEvents returns without
    // spinning CFRunLoop, and the host freezes the moment the Player has the main thread.
    SDL_SetMainReady();
    SDL_iPhoneSetEventPump(SDL_TRUE);
    // The Player draws through SDL's 2D renderer. Metal keeps it off OpenGL ES, which in OmniPlay's process
    // resolves to whichever GL image loaded first.
    SDL_SetHint(SDL_HINT_RENDER_DRIVER, "metal");
    Player::Init(std::vector<std::string>(argv, argv + argc));
    // The log file is buffered, so a Player that crashes or hangs would lose the lines that explain it. From here
    // every line is written through (the Init lines go out with the first one).
    Game_Config::GetLogFileOutput() << std::unitbuf;
    // Controllers reach the Player as keys from the host's input layer, which reads the same GCControllers; SDL
    // reading them too would double every press. The Player opened the subsystem in Init and only ever reacts to
    // its events, so closing it again leaves the host as the one source.
    SDL_QuitSubSystem(SDL_INIT_GAMECONTROLLER);

    // Player::Run, with the host's requests between frames.
    Scene::Push(std::make_shared<Scene_Logo>());
    Graphics::UpdateSceneCallback();
    Player::reset_flag = false;
    Game_Clock::ResetFrame(Game_Clock::now());
    status = OP_EASYRPG_STATUS_RUNNING;
    while (Transition::instance().IsActive() || (Scene::instance && Scene::instance->type != Scene::Null)) {
        int request = command;
        if (request == OP_EASYRPG_COMMAND_STOP) {
            // The Player's own quit path: the next update pops every scene and the loop ends in Player::Exit.
            Player::exit_flag = true;
        } else if (request == OP_EASYRPG_COMMAND_PAUSE) {
            if (status != OP_EASYRPG_STATUS_PAUSED) {
                Player::Pause();
                status = OP_EASYRPG_STATUS_PAUSED;
            }
            idle();
            continue;
        } else if (status == OP_EASYRPG_STATUS_PAUSED) {
            Player::Resume();
            status = OP_EASYRPG_STATUS_RUNNING;
        }
        Player::MainLoop();
        frames++;
        for (auto it = held_releases.begin(); it != held_releases.end();) {
            if (SDL_GetTicks() - pressed_at[*it] < min_hold_ms) { ++it; continue; }
            push_key(*it, false);
            it = held_releases.erase(it);
        }
    }
    SDL_iPhoneSetEventPump(SDL_FALSE);
    status = OP_EASYRPG_STATUS_EXITED;
    return Player::exit_code;
}

OP_EXPORT void op_easyrpg_request(int value) { command = value; }
OP_EXPORT int op_easyrpg_status(void) { return status; }
OP_EXPORT unsigned long op_easyrpg_frames(void) { return frames; }

OP_EXPORT void op_easyrpg_key(int scancode, int down) {
    if (down) {
        pressed_at[scancode] = SDL_GetTicks();
        // A second tap before the first one's release went out: the key simply stays down.
        held_releases.erase(std::remove(held_releases.begin(), held_releases.end(), scancode), held_releases.end());
    } else if (pressed_at.count(scancode) && SDL_GetTicks() - pressed_at[scancode] < min_hold_ms) {
        held_releases.push_back(scancode);
        return;
    }
    push_key(scancode, down);
}

OP_EXPORT int op_easyrpg_snapshot(const char *path) {
    if (!path || !DisplayUi) return 0;
    auto stream = FileFinder::Root().OpenOutputStream(path, std::ios_base::binary | std::ios_base::out | std::ios_base::trunc);
    return stream && Output::TakeScreenshot(stream) ? 1 : 0;
}

OP_EXPORT void *op_easyrpg_window(void) {
    // The Player opens one window; its id is 1 unless something opened and closed another first.
    for (Uint32 id = 1; id <= 16; id++) {
        SDL_Window *window = SDL_GetWindowFromID(id);
        if (!window) continue;
        SDL_SysWMinfo info;
        SDL_VERSION(&info.version);
        if (SDL_GetWindowWMInfo(window, &info)) return info.info.uikit.window;  // void * outside Objective-C
    }
    return nullptr;
}

OP_EXPORT void op_easyrpg_app_event(int event) {
    switch (event) {
    case 0: SDL_OnApplicationWillResignActive(); break;
    case 1: SDL_OnApplicationDidEnterBackground(); break;
    case 2: SDL_OnApplicationWillEnterForeground(); break;
    case 3: SDL_OnApplicationDidBecomeActive(); break;
    case 4: SDL_OnApplicationDidReceiveMemoryWarning(); break;
    default: break;
    }
}

OP_EXPORT int op_easyrpg_rtp_detect(const char *path, char *out, int size) {
    if (!path || !out || size <= 0) return 0;
    auto fs = FileFinder::Root().Create(FileFinder::MakeCanonical(path));
    if (!fs) return 0;
    auto hits = RTP::Detect(fs, 0);
    if (hits.empty()) return 0;
    const auto &best = hits.front();
    snprintf(out, size, "%d\t%s\t%d\t%d", best.version, best.name.c_str(), best.hits, best.max);
    return 1;
}
