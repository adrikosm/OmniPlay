// The host side of the Godot 4.4 framework: what Godot 4.4's iOS export template (platform/ios/app_delegate.mm) does
// at launch, without owning the application. It mirrors Native/godot/modules/omniplay/op_godot.mm for 4.7; 4.4 still
// names its classes AppDelegate/ViewController/GodotView (built with a GD44 prefix, Native/godot44/objc-renames.txt).

#include "op_godot44.h"

#include "core/config/engine.h"
#include "core/config/project_settings.h"
#include "core/input/input.h"
#include "core/input/input_event.h"
#include "core/os/keyboard.h"
#include "core/os/main_loop.h"
#include "core/version.h"
#include "main/main.h"
#import "platform/ios/app_delegate.h"
#import "platform/ios/godot_view.h"
#import "platform/ios/os_ios.h"
#import "platform/ios/view_controller.h"

// Added by Native/patches/godot44/0001: 4.4 keeps the view controller in a file-static that only its own launch sets.
@interface AppDelegate (OmniPlay)
+ (void)setViewController:(ViewController *)viewController;
@end

#import <UIKit/UIKit.h>

#include <atomic>

#define OP_EXPORT extern "C" __attribute__((visibility("default")))

// user:// and the cache go where OmniPlay keeps the game's saves and caches (stock iOS Godot uses Documents).
class OmniPlayOS : public OS_IOS {
public:
	String user_dir;
	String cache_dir;
	String get_user_data_dir(const String &p_user_dir) const override { return user_dir; }
	String get_cache_path() const override { return cache_dir.is_empty() ? OS_IOS::get_cache_path() : cache_dir; }
};

// The export template generates these for the project's native iOS plugins; imported games bring none that run.
void godot_ios_plugins_initialize() {}
void godot_ios_plugins_deinitialize() {}

static OmniPlayOS *os = nullptr;
static ViewController *controller = nil;
static std::atomic<int> status{OP_GODOT44_STATUS_IDLE};


OP_EXPORT const char *op_godot44_version(void) { return VERSION_FULL_CONFIG; }

OP_EXPORT int op_godot44_setup(int argc, char **argv, const char *user_dir, const char *cache_dir) {
	if (os)
		return ERR_ALREADY_IN_USE;
	os = new OmniPlayOS();
	os->user_dir = String::utf8(user_dir ? user_dir : "");
	os->cache_dir = String::utf8(cache_dir ? cache_dir : "");
	Error err = Main::setup(argv[0], argc - 1, &argv[1], false);
	if (err != OK) {
		status = OP_GODOT44_STATUS_FAILED;
		return err;
	}
	os->initialize_modules();
	// Desktop exports carry only S3TC/BPTC textures, chosen under the "s3tc"/"bptc" features, which the phone's GPU
	// does not report: every such texture fails to load (4.5 added a decompressible fallback; 4.4 has none). Claiming
	// the features picks them, and GLES3 decompresses what the GPU cannot sample, as the Godot 3 shim does.
	ProjectSettings::get_singleton()->set("_custom_features", "s3tc,bptc");
	// Compiled shaders are a cache, not the game's data: without this they land in user://, among the saves (and in
	// every save backup). The renderer reads the path when setup2 creates it.
	if (!os->cache_dir.is_empty())
		Engine::get_singleton()->set_shader_cache_path(os->cache_dir);
	status = OP_GODOT44_STATUS_SET_UP;
	return OK;
}

OP_EXPORT void *op_godot44_view_controller(void) {
	if (!controller && os) {
		controller = [[ViewController alloc] init];
		controller.godotView.useCADisplayLink = bool(GLOBAL_DEF("display.iOS/use_cadisplaylink", true)) ? YES : NO;
		controller.godotView.renderingInterval = 1.0 / 60;
		[AppDelegate setViewController:controller];
		// 4.4 starts drawing when the app delegate hears the app become active, which already happened; 4.7's view
		// controller starts it itself.
		[controller.godotView startRendering];
		status = OP_GODOT44_STATUS_RUNNING;
	}
	return (__bridge void *)controller;
}

OP_EXPORT void op_godot44_request(int command) {
	if (!controller)
		return;
	switch (command) {
	case OP_GODOT44_COMMAND_PAUSE:
		if (status == OP_GODOT44_STATUS_RUNNING) {
			os->on_focus_out();
			[controller.godotView stopRendering];
			status = OP_GODOT44_STATUS_PAUSED;
		}
		break;
	case OP_GODOT44_COMMAND_RUN:
		if (status == OP_GODOT44_STATUS_PAUSED) {
			[controller.godotView startRendering];
			os->on_focus_in();
			status = OP_GODOT44_STATUS_RUNNING;
		}
		break;
	case OP_GODOT44_COMMAND_STOP:
		// Godot cannot be set up again in this process; stopping sends the game what iOS sends on backgrounding
		// (NOTIFICATION_APPLICATION_PAUSED, where games save) and stops drawing.
		if (status == OP_GODOT44_STATUS_RUNNING || status == OP_GODOT44_STATUS_PAUSED) {
			os->on_enter_background();
			[controller.godotView stopRendering];
			status = OP_GODOT44_STATUS_STOPPED;
		}
		break;
	default:
		break;
	}
}

OP_EXPORT int op_godot44_status(void) { return status; }
// The engine's own count: it advances only when Godot actually draws.
OP_EXPORT unsigned long op_godot44_frames(void) {
	return status >= OP_GODOT44_STATUS_RUNNING && Engine::get_singleton() ? Engine::get_singleton()->get_frames_drawn() : 0;
}

OP_EXPORT void op_godot44_key(const char *name, int pressed) {
	int now = status;
	if (!name || !Input::get_singleton() || (now != OP_GODOT44_STATUS_SET_UP && now != OP_GODOT44_STATUS_RUNNING && now != OP_GODOT44_STATUS_PAUSED))
		return;
	Key key = find_keycode(String::utf8(name));
	if (key == Key::NONE)
		return;
	Ref<InputEventKey> event;
	event.instantiate();
	event->set_keycode(key);
	event->set_physical_keycode(key);
	event->set_pressed(pressed != 0);
	Input::get_singleton()->parse_input_event(event);
}

OP_EXPORT void op_godot44_app_event(int event) {
	if (!os || status == OP_GODOT44_STATUS_STOPPED)
		return;
	switch (event) {
	case 0: os->on_focus_out(); break;
	case 1: os->on_enter_background(); break;
	// Paused from the menu: leave the engine asleep; on_exit_background would restart rendering and audio.
	case 2: if (status == OP_GODOT44_STATUS_RUNNING) os->on_exit_background(); break;
	case 3: if (status == OP_GODOT44_STATUS_RUNNING) os->on_focus_in(); break;
	case 4:
		if (OS::get_singleton()->get_main_loop())
			OS::get_singleton()->get_main_loop()->notification(MainLoop::NOTIFICATION_OS_MEMORY_WARNING);
		break;
	default: break;
	}
}
