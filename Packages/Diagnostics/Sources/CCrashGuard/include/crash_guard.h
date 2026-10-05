#ifndef OMNIPLAY_CRASH_GUARD_H
#define OMNIPLAY_CRASH_GUARD_H

#include <stdint.h>

/// Fault handlers, the main-thread stall watcher and the notification pipe. Call once, on the main thread.
void op_crash_install(void);

/// Where `crash.txt` and `stalls.txt` are written: the running game's session folder, else the host's.
void op_crash_set_directory(const char *path);

/// The open stderr log, whose tail goes into each crash report; -1 for none.
void op_crash_set_stderr_fd(int fd);

/// Runs an engine's main loop under a recovery point. A fault on the main thread inside it, or a hang of over
/// `OP_CRASH_HANG_SECONDS`, abandons the engine and returns `OP_CRASH_STATUS_BASE - signal` instead of ending the app.
int op_crash_engine_call(const char *engine, int (^__attribute__((noescape)) body)(void));

/// Keeps `line` among the recent log lines every crash report ends with.
void op_crash_note(const char *line);

/// Readable end of the pipe that gets one byte (the signal) whenever a thread outside the main thread crashed and
/// was stopped instead of the app.
int op_crash_notify_fd(void);

/// One line naming what happened and where: the first crash or hang since the directory last changed, else empty.
const char *op_crash_last_summary(void);

/// Engine exit statuses that mean "abandoned after this signal" are `-1000 - signal`.
#define OP_CRASH_STATUS_BASE (-1000)
#define OP_CRASH_HANG_SECONDS 45

#endif
