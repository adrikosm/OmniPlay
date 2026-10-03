// The host side of the Godot 3 framework: what platform/iphone's AppDelegate does at launch, without owning the app.

#include "op_godot3.h"

#include "core/engine.h"
#include "core/os/input.h"
#include "core/os/input_event.h"
#include "core/os/keyboard.h"
#include "core/project_settings.h"
#include "core/version.h"
#include "main/main.h"
#include "platform/iphone/os_iphone.h"
#import "platform/iphone/app_delegate.h"
#import "platform/iphone/godot_view.h"
#import "platform/iphone/view_controller.h"

#import <UIKit/UIKit.h>

#include <atomic>

#define OP_EXPORT extern "C" __attribute__((visibility("default")))

extern int iphone_main(int, char **, String, String);

@interface AppDelegate (OmniPlay)
- (void)createViewController; // implemented in app_delegate.mm, not declared in its header
@end

// The export template generates these for native iOS plugins; imported games bring none that run.
void godot_ios_plugins_initialize() {}
void godot_ios_plugins_deinitialize() {}

static std::atomic<int> status{OP_GODOT3_STATUS_IDLE};


OP_EXPORT const char *op_godot3_version(void) { return VERSION_FULL_CONFIG; }

OP_EXPORT int op_godot3_setup(int argc, char **argv, const char *user_dir, const char *cache_dir) {
	if (status != OP_GODOT3_STATUS_IDLE)
		return ERR_ALREADY_IN_USE;
	int err = iphone_main(argc, argv, String::utf8(user_dir ? user_dir : ""), String::utf8(cache_dir ? cache_dir : ""));
	status = err == 0 ? OP_GODOT3_STATUS_SET_UP : OP_GODOT3_STATUS_FAILED;
	if (err == 0) {
		// Desktop exports carry only S3TC textures, remapped under the "s3tc" feature, which Godot 3 never reports on
		// iOS: every such texture fails to load. Claiming the feature picks them; the renderer still reports no S3TC
		// hardware, so GLES3 decompresses them (squish), as Godot 4 does on its own.
		// ponytail: a pack with both S3TC and ETC2 now prefers S3TC and pays the decompression; fine until one shows up.
		ProjectSettings::get_singleton()->set("_custom_features", "s3tc");
	}
	return err;
}

OP_EXPORT void *op_godot3_window(void) {
	AppDelegate *delegate = [AppDelegate getSingleton];
	if (!delegate.window && status == OP_GODOT3_STATUS_SET_UP) {
		delegate.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
		[delegate createViewController];
		// Godot 3 starts drawing (and with it setup2, which creates input) when the app gains focus, which its own
		// app delegate reports; this is that moment.
		OSIPhone::get_singleton()->on_focus_in();
		status = OP_GODOT3_STATUS_RUNNING;
	}
	return (__bridge void *)delegate.window;
}

OP_EXPORT void op_godot3_request(int command) {
	GodotView *view = AppDelegate.viewController.godotView;
	OSIPhone *os = OSIPhone::get_singleton();
	if (!view || !os)
		return;
	switch (command) {
	case OP_GODOT3_COMMAND_PAUSE:
		if (status == OP_GODOT3_STATUS_RUNNING) {
			os->on_focus_out();
			[view stopRendering];
			status = OP_GODOT3_STATUS_PAUSED;
		}
		break;
	case OP_GODOT3_COMMAND_RUN:
		if (status == OP_GODOT3_STATUS_PAUSED) {
			[view startRendering];
			os->on_focus_in();
			status = OP_GODOT3_STATUS_RUNNING;
		}
		break;
	case OP_GODOT3_COMMAND_STOP:
		// As in Godot 4: send what iOS sends on backgrounding (NOTIFICATION_APP_PAUSED, where games save).
		if (status == OP_GODOT3_STATUS_RUNNING || status == OP_GODOT3_STATUS_PAUSED) {
			os->on_enter_background();
			[view stopRendering];
			status = OP_GODOT3_STATUS_STOPPED;
		}
		break;
	default:
		break;
	}
}

OP_EXPORT int op_godot3_status(void) { return status; }
// The engine's own count: it advances only when Godot actually draws.
OP_EXPORT unsigned long op_godot3_frames(void) {
	return status >= OP_GODOT3_STATUS_RUNNING && Engine::get_singleton() ? Engine::get_singleton()->get_frames_drawn() : 0;
}

OP_EXPORT void op_godot3_key(const char *name, int pressed) {
	int now = status;
	if (!name || !Input::get_singleton() || (now != OP_GODOT3_STATUS_SET_UP && now != OP_GODOT3_STATUS_RUNNING && now != OP_GODOT3_STATUS_PAUSED))
		return;
	int key = find_keycode(String::utf8(name));
	if (!key)
		return;
	Ref<InputEventKey> event;
	event.instance();
	event->set_scancode(key);
	event->set_physical_scancode(key);
	event->set_pressed(pressed != 0);
	Input::get_singleton()->parse_input_event(event);
}

OP_EXPORT void op_godot3_app_event(int event) {
	OSIPhone *os = OSIPhone::get_singleton();
	if (!os || status == OP_GODOT3_STATUS_STOPPED)
		return;
	switch (event) {
	case 0: os->on_focus_out(); break;
	case 1: os->on_enter_background(); break;
	// Paused from the menu: leave the engine asleep; on_exit_background would restart rendering.
	case 2: if (status == OP_GODOT3_STATUS_RUNNING) os->on_exit_background(); break;
	case 3: if (status == OP_GODOT3_STATUS_RUNNING) os->on_focus_in(); break;
	default: break;
	}
}
