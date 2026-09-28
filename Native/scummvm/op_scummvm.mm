// The host side of the ScummVM framework: replaces the ios7 backend's main, app delegate and scene delegate
// (ios7_main.mm, ios7_app_delegate.mm, ios7_scene_delegate.mm), which assume ScummVM owns UIApplication.
//
// The backend reaches UIKit only through +[iOS7AppDelegate iPhoneView] and friends, so this file provides that class
// over a view and window of its own. scummvm_main runs on a dedicated thread; OmniPlay's patch (Native/patches/scummvm)
// turns ScummVM's launcher into omniplay_next_game, where that thread waits between games for the host's requests.
// Built with the backend's flags (manual reference counting).

#define FORBIDDEN_SYMBOL_ALLOW_ALL
// ScummVM's C++ headers first: Objective-C's YES and NO macros break them once UIKit is in.
#include "backends/platform/ios7/ios7_osys_main.h"
#include "base/main.h"
#include "base/version.h"
#include "common/config-manager.h"
#include "common/error.h"
#include "common/events.h"
#include "common/fs.h"
#include "common/language.h"
#include "common/platform.h"
#include "engines/engine.h"
#include "engines/metaengine.h"
#include "base/plugins.h"

#include "backends/platform/ios7/ios7_app_delegate.h"
#include "backends/platform/ios7/ios7_common.h"
#include "backends/platform/ios7/ios7_scummvm_view_controller.h"
#include "backends/platform/ios7/ios7_video.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <string>

#include "op_scummvm.h"

#define OP_EXPORT extern "C" __attribute__((visibility("default")))

bool omniplay_log(const char *message);

static iOS7ScummVMViewController *s_controller;
static iPhoneView *s_view;
static UIWindow *s_window;

@implementation iOS7AppDelegate
+ (iOS7AppDelegate *)iOS7AppDelegate { return nil; }
+ (iPhoneView *)iPhoneView { return s_view; }
+ (UIInterfaceOrientation)currentOrientation { return [s_controller currentOrientation]; }
+ (void)setKeyWindow:(UIWindow *)window {}
@end

// Engine-thread state. Requests from the host wait under the mutex; the engine thread serves them between games.
static std::atomic<int> s_status{OP_SCUMMVM_STATUS_NOT_STARTED};
static std::atomic<int> s_command{OP_SCUMMVM_COMMAND_RUN};
static std::atomic<unsigned long> s_frames{0};
static std::atomic<bool> s_leave{false};

enum class Job { none, detect, play };
static std::mutex s_mutex;
static std::condition_variable s_wake;
static Job s_job = Job::none;
static std::string s_jobInput;   // detect: the folder; play: the settings
static std::string s_jobOutput;  // detect: the JSON
static int s_jobCount = 0;
static bool s_jobDone = false;
static bool s_detectAbandoned = false;
static int s_lastCode = 0;
static std::string s_lastMessage;

static std::string json_escape(const Common::String &text) {
	std::string out;
	for (const char *c = text.c_str(); *c; c++) {
		switch (*c) {
		case '"': out += "\\\""; break;
		case '\\': out += "\\\\"; break;
		case '\n': out += "\\n"; break;
		default:
			if ((unsigned char)*c < 0x20) {
				char buffer[8];
				snprintf(buffer, sizeof buffer, "\\u%04x", *c);
				out += buffer;
			} else {
				out += *c;
			}
		}
	}
	return out;
}

// ScummVM's code for a language or platform, or "" when it has none (unknown language or platform is NULL).
static const char *code(const char *value) { return value ? value : ""; }

static DetectedGames detect(const Common::String &path) {
	Common::FSNode dir(Common::Path(path, '/'));
	Common::FSList files;
	if (!dir.isDirectory() || !dir.getChildren(files, Common::FSNode::kListAll))
		return DetectedGames();
	return EngineMan.detectGames(files).listRecognizedGames();
}

static std::string detect_json(const DetectedGames &games) {
	std::string json = "[";
	for (uint i = 0; i < games.size(); i++) {
		const DetectedGame &game = games[i];
		if (i)
			json += ",";
		json += "{\"engineid\":\"" + json_escape(game.engineId) + "\",\"gameid\":\"" + json_escape(game.gameId) +
			"\",\"description\":\"" + json_escape(game.description) + "\",\"language\":\"" +
			code(Common::getLanguageCode(game.language)) + "\",\"platform\":\"" + code(Common::getPlatformCode(game.platform)) +
			"\",\"extra\":\"" + json_escape(game.extra) + "\"}";
	}
	return json + "]";
}

// Makes the game's config domain from the host's key=value lines and selects it. Without engineid/gameid the game in
// `path` is detected and the best candidate taken. The domain is named after the game id, as ScummVM names targets,
// because save files are named after the domain: a PC ScummVM's "monkey.001" then drops straight into the game's saves.
static Common::String s_domain;

static bool configure_game(const std::string &settings) {
	Common::StringMap values;
	size_t start = 0;
	while (start < settings.size()) {
		size_t end = settings.find('\n', start);
		if (end == std::string::npos)
			end = settings.size();
		std::string line = settings.substr(start, end - start);
		size_t eq = line.find('=');
		if (eq != std::string::npos)
			values[Common::String(line.substr(0, eq).c_str())] = Common::String(line.substr(eq + 1).c_str());
		start = end + 1;
	}
	if (!values.contains("gameid") || !values.contains("engineid")) {
		DetectedGames games = detect(values.getValOrDefault("path"));
		if (games.empty()) {
			std::lock_guard<std::mutex> lock(s_mutex);
			s_lastCode = Common::kNoGameDataFoundError;
			s_lastMessage = "ScummVM does not recognise the game in this folder.";
			return false;
		}
		values["engineid"] = games[0].engineId;
		values["gameid"] = games[0].gameId;
		if (!values.contains("language") && games[0].language != Common::UNK_LANG)
			values["language"] = code(Common::getLanguageCode(games[0].language));
		if (!values.contains("platform") && games[0].platform != Common::kPlatformUnknown)
			values["platform"] = code(Common::getPlatformCode(games[0].platform));
	}
	if (!s_domain.empty() && ConfMan.hasGameDomain(s_domain))
		ConfMan.removeGameDomain(s_domain);
	s_domain = values["gameid"];
	if (ConfMan.hasGameDomain(s_domain))
		ConfMan.removeGameDomain(s_domain);
	ConfMan.addGameDomain(s_domain);
	Common::ConfigManager::Domain *d = ConfMan.getDomain(s_domain);
	for (Common::StringMap::const_iterator it = values.begin(); it != values.end(); ++it)
		d->setVal(it->_key, it->_value);
	ConfMan.setActiveDomain(s_domain);
	// Continue: when the engine keeps an autosave and one exists for this game, start from it. Leaving through the
	// host autosaves first (omniplay_poll), so this is where the player left off.
	if (values.getValOrDefault("omniplay_continue", "1") == "1") {
		const Plugin *plugin = PluginMan.findEnginePlugin(values["engineid"]);
		if (plugin) {
			MetaEngine &meta = plugin->get<MetaEngine>();
			int slot = meta.getAutosaveSlot();
			// listSaves, not querySaveMetaInfos: some engines answer the latter only for player slots (Beneath a
			// Steel Sky's autosave is slot 0, which its querySaveMetaInfos never reports).
			bool saved = false;
			if (slot >= 0 && meta.hasFeature(MetaEngine::kSupportsLoadingDuringStartup)) {
				SaveStateList saves = meta.listSaves(s_domain.c_str());
				for (SaveStateList::const_iterator it = saves.begin(); it != saves.end() && !saved; ++it)
					saved = it->getSaveSlot() == slot;
			}
			if (saved) {
				ConfMan.setInt("save_slot", slot, Common::ConfigManager::kTransientDomain);
				omniplay_log(Common::String::format("OmniPlay: continuing %s from autosave slot %d\n", s_domain.c_str(), slot).c_str());
			}
		}
	}
	return true;
}

bool omniplay_next_game() {
	ConfMan.setActiveDomain("");
	std::unique_lock<std::mutex> lock(s_mutex);
	for (;;) {
		s_status = OP_SCUMMVM_STATUS_WAITING;
		s_wake.wait(lock, [] { return s_job != Job::none && !s_jobDone; });
		Job job = s_job;
		std::string input = s_jobInput;
		if (job == Job::detect) {
			// Detection can do slow disk work. Keep its job reserved, but never hold the host's mutex over it.
			lock.unlock();
			DetectedGames games = detect(Common::String(input.c_str()));
			std::string output = detect_json(games);
			lock.lock();
			if (s_detectAbandoned) {
				s_job = Job::none;
			} else {
				s_jobOutput = std::move(output);
				s_jobCount = (int)games.size();
				s_jobDone = true;
			}
			s_wake.notify_all();
			continue;
		}
		s_job = Job::none;
		s_status = OP_SCUMMVM_STATUS_STARTING;
		s_command = OP_SCUMMVM_COMMAND_RUN;
		s_leave = false;
		s_lastCode = 0;
		s_lastMessage.clear();
		lock.unlock();
		if (configure_game(input))
			return true;
		lock.lock();
		// Nothing to run: the host hears about it through last_result and the status going back to WAITING.
	}
}

void omniplay_game_result(const Common::Error &result) {
	std::lock_guard<std::mutex> lock(s_mutex);
	s_lastCode = result.getCode() == Common::kUserCanceled ? 0 : result.getCode();
	s_lastMessage = s_lastCode ? result.getDesc().c_str() : "";
}

static std::mutex s_logMutex;
static FILE *s_log;

bool omniplay_log(const char *message) {
	std::lock_guard<std::mutex> lock(s_logMutex);
	if (!s_log)
		return false;
	fputs(message, s_log);
	fflush(s_log);
	return true;
}

OP_EXPORT void op_scummvm_log(const char *path) {
	std::lock_guard<std::mutex> lock(s_logMutex);
	if (s_log)
		fclose(s_log);
	s_log = path ? fopen(path, "a") : nullptr;
}

bool omniplay_poll(Common::Event &event) {
	if (s_status == OP_SCUMMVM_STATUS_STARTING)
		s_status = OP_SCUMMVM_STATUS_PLAYING;
	s_frames++;
	if (s_leave.exchange(false)) {
		// Leaving through the host keeps the player's place: the engine's own autosave, where it allows one now
		// (ScummVM autosaves from event polling too, so the engine is at a safe point here).
		if (g_engine) {
			bool can = g_engine->getAutosaveSlot() >= 0 && g_engine->canSaveAutosaveCurrently();
			g_engine->saveAutosaveIfEnabled();
			omniplay_log(can ? "OmniPlay: leaving; autosaved\n" : "OmniPlay: leaving; the game cannot autosave now\n");
		}
		event.type = Common::EVENT_RETURN_TO_LAUNCHER;
		return true;
	}
	return false;
}

OP_EXPORT const char *op_scummvm_version(void) { return gScummVMVersion; }

OP_EXPORT int op_scummvm_start(int argc, char **argv) {
	if (s_status != OP_SCUMMVM_STATUS_NOT_STARTED || s_view)
		return 0;
	CGRect rect = [[UIScreen mainScreen] bounds];
	s_controller = [[iOS7ScummVMViewController alloc] init];
	s_view = [[iPhoneView alloc] initWithFrame:rect];
	s_view.multipleTouchEnabled = NO;
	s_controller.view = s_view;
	s_window = [[UIWindow alloc] initWithFrame:rect];
	s_window.rootViewController = s_controller;
	// The OSystem must be built on the main thread (it asks UIKit for paths and the screen).
	iOS7_buildSharedOSystemInstance();

	// strdup'd and never freed: ScummVM keeps argv for the life of the process.
	char **copy = (char **)calloc(argc + 1, sizeof(char *));
	for (int i = 0; i < argc; i++)
		copy[i] = strdup(argv[i]);
	// ScummVM allows 300 KB stack frames; a dispatch queue's 512 KB stack is not enough.
	NSThread *thread = [[NSThread alloc] initWithBlock:^{
		g_system = OSystem_iOS7::sharedInstance();
		scummvm_main(argc, copy);
		{
			std::lock_guard<std::mutex> lock(s_mutex);
			s_status = OP_SCUMMVM_STATUS_EXITED;
		}
		s_wake.notify_all();
	}];
	thread.stackSize = 8 << 20;
	thread.name = @"ScummVM";
	[thread start];
	return 1;
}

OP_EXPORT int op_scummvm_status(void) {
	int status = s_status;
	if (status == OP_SCUMMVM_STATUS_PLAYING && s_command == OP_SCUMMVM_COMMAND_PAUSE)
		return OP_SCUMMVM_STATUS_PAUSED;
	return status;
}

OP_EXPORT int op_scummvm_detect(const char *path, char *out, int size) {
	std::unique_lock<std::mutex> lock(s_mutex, std::try_to_lock);
	if (!lock.owns_lock() || !path || s_status != OP_SCUMMVM_STATUS_WAITING || s_job != Job::none)
		return -1;
	s_job = Job::detect;
	s_jobInput = path;
	s_jobDone = false;
	s_detectAbandoned = false;
	s_wake.notify_all();
	if (!s_wake.wait_for(lock, std::chrono::seconds(30), [] { return s_jobDone || s_status == OP_SCUMMVM_STATUS_EXITED; }) || !s_jobDone) {
		// A late result belongs to this request only. Reject more jobs until the engine has discarded it.
		s_detectAbandoned = true;
		return -1;
	}
	s_job = Job::none;
	if (out && size > 0)
		snprintf(out, size, "%s", s_jobOutput.c_str());
	return s_jobCount;
}

OP_EXPORT int op_scummvm_play(const char *settings) {
	std::unique_lock<std::mutex> lock(s_mutex, std::try_to_lock);
	if (!lock.owns_lock() || !settings || s_status != OP_SCUMMVM_STATUS_WAITING || s_job != Job::none)
		return 0;
	s_job = Job::play;
	s_jobInput = settings;
	s_jobDone = false;
	s_status = OP_SCUMMVM_STATUS_STARTING;
	s_wake.notify_all();
	return 1;
}

OP_EXPORT int op_scummvm_last_result(char *out, int size) {
	std::lock_guard<std::mutex> lock(s_mutex);
	if (out && size > 0)
		snprintf(out, size, "%s", s_lastMessage.c_str());
	return s_lastCode;
}

OP_EXPORT void op_scummvm_request(int command) {
	int previous = s_command.exchange(command);
	switch (command) {
	case OP_SCUMMVM_COMMAND_PAUSE:
		// The backend's own suspend: the engine pauses, audio stops, and the thread waits for the resume.
		if (previous != OP_SCUMMVM_COMMAND_PAUSE)
			[s_view applicationSuspend];
		break;
	case OP_SCUMMVM_COMMAND_RUN:
		if (previous == OP_SCUMMVM_COMMAND_PAUSE)
			[s_view applicationResume];
		break;
	case OP_SCUMMVM_COMMAND_LEAVE:
		if (previous == OP_SCUMMVM_COMMAND_PAUSE)
			[s_view applicationResume];
		s_leave = true;
		break;
	default:
		break;
	}
}

OP_EXPORT unsigned long op_scummvm_frames(void) { return s_frames; }

OP_EXPORT void op_scummvm_key(int keycode, int ascii) {
	(void)ascii;  // the backend derives the character from the keycode for printable keys
	[s_view addEvent:InternalEvent(kInputKeyPressed, keycode, 0)];
}

OP_EXPORT void op_scummvm_main_menu(void) { [s_view addEvent:InternalEvent(kInputMainMenu, 0, 0)]; }

OP_EXPORT void *op_scummvm_window(void) { return (void *)s_window; }

OP_EXPORT void op_scummvm_app_event(int event) {
	switch (event) {
	case 0:
		if (s_command != OP_SCUMMVM_COMMAND_PAUSE)
			[s_view applicationSuspend];
		break;
	case 1: [s_view saveApplicationState]; break;
	case 3:
		if (s_command != OP_SCUMMVM_COMMAND_PAUSE)
			[s_view applicationResume];
		break;
	default: break;
	}
}
