// Crash and hang containment for engines that share OmniPlay's process.
//
// iOS gives an app one process, so a native engine's fault is the app's fault. The handlers here do two things:
// write down where and why (signal, thread, engine, the faulting stack symbolised, the tail of stderr) before
// anything else, then keep the app alive when that is possible:
//   - a fault on the main thread inside an engine's main loop jumps back out of the engine (`op_crash_engine_call`);
//   - a fault on a thread an engine started (audio, workers, ScummVM's engine thread) stops that thread only;
//   - a main thread that has not turned its run loop for OP_CRASH_HANG_SECONDS inside an engine is pulled out too.
// Anything else (a fault in OmniPlay's own queues, or on the main thread outside an engine) still ends the app,
// with the report written first.
//
// Handlers only use calls that are safe in a signal handler, plus dladdr, which crash reporters rely on in practice.

#include "crash_guard.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define MAX_DEPTH 8
#define MAX_FRAMES 64
#define STALL_REPORT_SECONDS 5
// Sent to the main thread by the watcher. Ruby takes SIGUSR1/2 for itself, so these are the quieter two.
#define DIAGNOSE_SIGNAL SIGINFO
#define ABORT_SIGNAL SIGEMT

static const int fault_signals[] = {SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP, SIGSYS};

typedef struct {
    sigjmp_buf jump;
    const char *engine;
    uintptr_t frame;
} recovery_t;

static pthread_t main_thread;
static char directory[1024];
static int stderr_fd = -1;
static int notify_pipe[2] = {-1, -1};
static char summary[512];
static recovery_t recoveries[MAX_DEPTH];
static volatile sig_atomic_t depth;
/// The engine thread's signal when the main thread is being pulled out because of it, else 0.
static volatile sig_atomic_t pending_signal;
static _Atomic(pthread_t) handling;
static _Atomic unsigned long heartbeat;
static _Atomic int run_loop_asleep;
static char alternate_stack[128 * 1024];
/// The most recent log lines, kept here because the session's host.log is written a second behind.
static char recent[16 * 1024];
static _Atomic size_t recent_end;

// MARK: Writing without malloc

static void put(int fd, const char *s) {
    if (fd >= 0 && s) {
        write(fd, s, strlen(s));
    }
}

static void hex(char out[19], uintptr_t value) {
    out[0] = '0';
    out[1] = 'x';
    for (int i = 0; i < 16; i++) {
        out[2 + i] = "0123456789abcdef"[(value >> (60 - 4 * i)) & 15];
    }
    out[18] = 0;
}

static void put_hex(int fd, uintptr_t value) {
    char b[19];
    hex(b, value);
    put(fd, b);
}

static void put_dec(int fd, long value) {
    char b[24];
    int i = 23;
    b[i] = 0;
    int negative = value < 0;
    unsigned long v = negative ? -(unsigned long)value : (unsigned long)value;
    do {
        b[--i] = (char)('0' + v % 10);
        v /= 10;
    } while (v && i > 1);
    if (negative) {
        b[--i] = '-';
    }
    put(fd, b + i);
}

static void put_two(int fd, long v) {
    char b[3] = {(char)('0' + v / 10 % 10), (char)('0' + v % 10), 0};
    put(fd, b);
}

/// "2026-10-05 08:50:44 UTC", by hand: gmtime and strftime are not safe here. (Hinnant's days-to-civil.)
static void put_time(int fd) {
    long t = (long)time(NULL), days = t / 86400, rest = t % 86400;
    long z = days + 719468, era = z / 146097, doe = z - era * 146097;
    long yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    long doy = doe - (365 * yoe + yoe / 4 - yoe / 100), mp = (5 * doy + 2) / 153;
    long day = doy - (153 * mp + 2) / 5 + 1, month = mp < 10 ? mp + 3 : mp - 9, year = yoe + era * 400 + (month <= 2);
    put_dec(fd, year);
    put(fd, "-");
    put_two(fd, month);
    put(fd, "-");
    put_two(fd, day);
    put(fd, " ");
    put_two(fd, rest / 3600);
    put(fd, ":");
    put_two(fd, rest / 60 % 60);
    put(fd, ":");
    put_two(fd, rest % 60);
    put(fd, " UTC");
}

static const char *base_name(const char *path) {
    const char *slash = path ? strrchr(path, '/') : NULL;
    return slash ? slash + 1 : (path ? path : "?");
}

static const char *signal_name(int sig) {
    switch (sig) {
    case SIGSEGV: return "SIGSEGV";
    case SIGBUS: return "SIGBUS";
    case SIGILL: return "SIGILL";
    case SIGFPE: return "SIGFPE";
    case SIGABRT: return "SIGABRT";
    case SIGTRAP: return "SIGTRAP";
    case SIGSYS: return "SIGSYS";
    case ABORT_SIGNAL: return "hang";
    case DIAGNOSE_SIGNAL: return "stall";
    default: return "signal";
    }
}

static const char *signal_meaning(int sig) {
    switch (sig) {
    case SIGSEGV: return "bad memory access";
    case SIGBUS: return "bad memory access (alignment, or a mapped file went away)";
    case SIGILL: return "illegal instruction";
    case SIGFPE: return "arithmetic error";
    case SIGABRT: return "abort (an assertion, an uncaught exception or a fatal engine error)";
    case SIGTRAP: return "trap (a runtime check failed)";
    case SIGSYS: return "bad system call";
    case ABORT_SIGNAL: return "the main thread stopped responding";
    default: return "";
    }
}

static int open_report(const char *name) {
    char path[sizeof(directory) + 32];
    path[0] = 0;
    strlcpy(path, directory, sizeof(path));
    strlcat(path, "/", sizeof(path));
    strlcat(path, name, sizeof(path));
    return path[1] ? open(path, O_WRONLY | O_CREAT | O_APPEND, 0644) : -1;
}

// MARK: The faulting stack

typedef struct {
    uintptr_t pc[MAX_FRAMES];
    int count;
    /// Frames between the fault and the innermost recovery point.
    int inside;
    /// The walk got to the recovery point, so every frame in between is known.
    int reached;
} frames_t;

static void walk(const ucontext_t *context, uintptr_t stop_at, frames_t *out) {
    out->count = 0;
    out->inside = -1;
    out->reached = 0;
    uintptr_t pc = 0, fp = 0;
#if defined(__arm64__)
    pc = (uintptr_t)__darwin_arm_thread_state64_get_pc(context->uc_mcontext->__ss);
    fp = (uintptr_t)__darwin_arm_thread_state64_get_fp(context->uc_mcontext->__ss);
#elif defined(__x86_64__)
    pc = context->uc_mcontext->__ss.__rip;
    fp = context->uc_mcontext->__ss.__rbp;
#endif
    out->pc[out->count++] = pc;
    pthread_t self = pthread_self();
    uintptr_t high = (uintptr_t)pthread_get_stackaddr_np(self);
    uintptr_t low = high - pthread_get_stacksize_np(self);
    while (fp && (fp & 7) == 0 && fp >= low && fp + 16 <= high && out->count < MAX_FRAMES) {
        if (stop_at && fp >= stop_at && out->inside < 0) {
            out->inside = out->count;
            out->reached = 1;
        }
        uintptr_t next = ((uintptr_t *)fp)[0];
        uintptr_t ret = ((uintptr_t *)fp)[1];
        if (!ret) {
            break;
        }
        out->pc[out->count++] = ret;
        if (next <= fp) {
            break;
        }
        fp = next;
    }
    if (out->inside < 0) {
        out->inside = out->count;
    }
}

/// Jumping out across a libdispatch frame would leave its queue marked as draining forever (the main queue, and
/// with it every main-actor task), so a fault under one is not recovered. Neither is one the walk could not follow
/// all the way back to the engine's entry: Swift async frames end the frame-pointer chain, and an unseen drain
/// below them wedges the app just the same.
static int unsafe_to_leave(const frames_t *frames) {
    if (!frames->reached) {
        return 1;
    }
    for (int i = 0; i < frames->inside; i++) {
        Dl_info info;
        if (dladdr((void *)frames->pc[i], &info) && info.dli_fname && strstr(info.dli_fname, "libdispatch")) {
            return 1;
        }
    }
    return 0;
}

/// GCD and Swift concurrency workers start at `start_wqthread`: OmniPlay's own queues and tasks. Threads engines
/// create start at `thread_start`. (A queue label cannot tell them apart: outside a queue it names a global queue.)
static int is_workqueue_thread(const frames_t *frames) {
    Dl_info info;
    return frames->count && dladdr((void *)frames->pc[frames->count - 1], &info) && info.dli_sname
        && strcmp(info.dli_sname, "start_wqthread") == 0;
}

static void put_frames(int fd, const frames_t *frames) {
    for (int i = 0; i < frames->count; i++) {
        Dl_info info;
        memset(&info, 0, sizeof(info));
        dladdr((void *)frames->pc[i], &info);
        put(fd, "  ");
        put_dec(fd, i);
        put(fd, "  ");
        put(fd, base_name(info.dli_fname));
        put(fd, "  ");
        put_hex(fd, frames->pc[i]);
        if (info.dli_fbase) {
            put(fd, " = ");
            put_hex(fd, (uintptr_t)info.dli_fbase);
            put(fd, " + ");
            put_hex(fd, frames->pc[i] - (uintptr_t)info.dli_fbase);
        }
        if (info.dli_sname) {
            put(fd, "  ");
            put(fd, info.dli_sname);
            put(fd, " + ");
            put_dec(fd, (long)(frames->pc[i] - (uintptr_t)info.dli_saddr));
        }
        put(fd, "\n");
    }
}

static void put_stderr_tail(int fd) {
    struct stat st;
    if (stderr_fd < 0 || fstat(stderr_fd, &st) != 0 || st.st_size == 0) {
        return;
    }
    char tail[2048];
    off_t from = st.st_size > (off_t)sizeof(tail) ? st.st_size - (off_t)sizeof(tail) : 0;
    ssize_t n = pread(stderr_fd, tail, sizeof(tail), from);
    if (n > 0) {
        put(fd, "stderr, last lines:\n");
        write(fd, tail, (size_t)n);
        put(fd, "\n");
    }
}

static void put_recent(int fd) {
    size_t end = atomic_load(&recent_end);
    if (!end) {
        return;
    }
    size_t size = sizeof(recent), start = end > size ? end - size : 0;
    put(fd, "log, last lines:\n");
    size_t from = start % size, to = end % size;
    if (end - start == size || to < from) {
        write(fd, recent + from, size - from);
        write(fd, recent, to);
    } else {
        write(fd, recent + from, to - from);
    }
}

/// "SIGSEGV, bad memory access at 0x10, in RenPy853, while Ren'Py 8.5.3 ran". The symbol is in the stack below it.
static void compose_summary(int sig, const siginfo_t *info, const frames_t *frames, const char *engine) {
    char b[19];
    summary[0] = 0;
    strlcat(summary, signal_name(sig), sizeof(summary));
    strlcat(summary, ", ", sizeof(summary));
    strlcat(summary, signal_meaning(sig), sizeof(summary));
    if (sig == SIGSEGV || sig == SIGBUS) {
        hex(b, (uintptr_t)info->si_addr);
        strlcat(summary, " at ", sizeof(summary));
        strlcat(summary, b, sizeof(summary));
    }
    Dl_info where;
    if (frames->count && dladdr((void *)frames->pc[0], &where)) {
        strlcat(summary, ", in ", sizeof(summary));
        strlcat(summary, base_name(where.dli_fname), sizeof(summary));
    }
    if (engine) {
        strlcat(summary, ", while ", sizeof(summary));
        strlcat(summary, engine, sizeof(summary));
        strlcat(summary, " ran", sizeof(summary));
    }
}

// MARK: Handlers

static void install_handlers(void);

/// Back to the system's handler: returning from a fault re-runs the instruction and the app ends with Apple's report.
static void die(int sig) {
    signal(sig, SIG_DFL);
    atomic_store(&handling, (pthread_t)0);
    if (sig == SIGABRT || sig == SIGSYS) {
        raise(sig);
    }
}

static void handler(int sig, siginfo_t *info, void *raw) {
    pthread_t self = pthread_self();
    if (atomic_load(&handling) == self) { // faulted inside this handler
        die(sig);
        return;
    }
    atomic_store(&handling, self);
    int is_main = pthread_equal(self, main_thread);
    int level = is_main ? depth : 0;
    const char *engine = level > 0 ? recoveries[level - 1].engine : NULL;
    frames_t frames;
    walk((const ucontext_t *)raw, level > 0 ? recoveries[level - 1].frame : 0, &frames);

    if (sig == DIAGNOSE_SIGNAL) {
        int fd = open_report("stalls.txt");
        put(fd, "=== main thread busy for ");
        put_dec(fd, STALL_REPORT_SECONDS);
        put(fd, " s, at ");
        put_time(fd);
        put(fd, engine ? ", in " : "");
        put(fd, engine ? engine : "");
        put(fd, " ===\n");
        put_frames(fd, &frames);
        close(fd);
        atomic_store(&handling, (pthread_t)0);
        return;
    }

    int ours = !is_main && is_workqueue_thread(&frames);
    int thread_crash = sig == ABORT_SIGNAL && pending_signal;
    const char *outcome;
    int recover = 0, park = 0;
    if (is_main) {
        recover = level > 0 && !unsafe_to_leave(&frames);
        outcome = recover ? "left the game; OmniPlay kept running"
            : sig == ABORT_SIGNAL ? "could not leave the game safely; it stays stuck"
                                  : "OmniPlay closed";
    } else {
        park = !ours;
        outcome = park ? "stopped this thread; OmniPlay kept running" : "OmniPlay closed";
    }
    // The first crash is the cause: an abandoned engine's other threads often fault after it.
    int first = summary[0] == 0;
    if (first && !thread_crash) {
        compose_summary(sig, info, &frames, engine);
    }

    int fd = open_report("crash.txt");
    put(fd, "=== OmniPlay crash report, ");
    put_time(fd);
    put(fd, " ===\nwhat: ");
    if (thread_crash) {
        put(fd, "leaving the game after an engine thread crashed");
    } else if (first) {
        put(fd, summary);
    } else {
        put(fd, signal_name(sig));
        put(fd, ", ");
        put(fd, signal_meaning(sig));
        put(fd, " (after the first crash above)");
    }
    put(fd, "\nthread: ");
    if (is_main) {
        put(fd, "main");
    } else {
        char name[64] = "";
        pthread_getname_np(self, name, sizeof(name));
        put(fd, name[0] ? name : "unnamed");
    }
    put(fd, is_main ? "" : ours ? " (a GCD or Swift concurrency worker)" : " (started by an engine or library)");
    put(fd, "\nengine: ");
    put(fd, engine ? engine : "none on this thread");
    put(fd, "\noutcome: ");
    put(fd, outcome);
    put(fd, "\nstack:\n");
    put_frames(fd, &frames);
    put_recent(fd);
    put_stderr_tail(fd);
    put(fd, "\n");
    close(fd);

    if (recover) {
        int code = thread_crash ? pending_signal : sig;
        pending_signal = 0;
        depth = level - 1;
        atomic_store(&handling, (pthread_t)0);
        siglongjmp(recoveries[level - 1].jump, code);
    }
    if (sig == ABORT_SIGNAL) { // stuck where it cannot be left; keep waiting
        pending_signal = 0;
        atomic_store(&handling, (pthread_t)0);
        return;
    }
    if (park) {
        unsigned char byte = (unsigned char)sig;
        write(notify_pipe[1], &byte, 1);
        if (depth > 0) { // the engine on the main thread depends on this thread; leave it too
            pending_signal = sig;
            pthread_kill(main_thread, ABORT_SIGNAL);
        }
        sigset_t all;
        sigfillset(&all);
        pthread_sigmask(SIG_BLOCK, &all, NULL);
        atomic_store(&handling, (pthread_t)0);
        for (;;) {
            sleep(3600);
        }
    }
    die(sig);
}

static void install_handlers(void) {
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = handler;
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_SIGINFO | SA_ONSTACK;
    for (size_t i = 0; i < sizeof(fault_signals) / sizeof(fault_signals[0]); i++) {
        sigaction(fault_signals[i], &action, NULL);
    }
    action.sa_flags = SA_SIGINFO | SA_RESTART;
    sigaction(DIAGNOSE_SIGNAL, &action, NULL);
    sigaction(ABORT_SIGNAL, &action, NULL);
}

// MARK: Main-thread watcher

static void observe_run_loop(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info) {
    (void)observer;
    (void)info;
    atomic_fetch_add(&heartbeat, 1);
    atomic_store(&run_loop_asleep, activity == kCFRunLoopBeforeWaiting);
}

/// Counts seconds in which the main run loop neither turned nor slept. Suspended with the app, so time in the
/// background or under a debugger never counts.
static void *watch_main(void *unused) {
    (void)unused;
    pthread_setname_np("OmniPlay main-thread watcher");
    unsigned long last = 0;
    int stalled = 0;
    for (;;) {
        sleep(1);
        unsigned long now = atomic_load(&heartbeat);
        if (now != last || atomic_load(&run_loop_asleep)) {
            last = now;
            stalled = 0;
            continue;
        }
        stalled++;
        if (stalled == STALL_REPORT_SECONDS) {
            pthread_kill(main_thread, DIAGNOSE_SIGNAL);
        }
        if (stalled == OP_CRASH_HANG_SECONDS && depth > 0) {
            pthread_kill(main_thread, ABORT_SIGNAL);
        }
    }
    return NULL;
}

// MARK: API

void op_crash_install(void) {
    main_thread = pthread_self();
    stack_t stack = {.ss_sp = alternate_stack, .ss_size = sizeof(alternate_stack), .ss_flags = 0};
    sigaltstack(&stack, NULL);
    if (pipe(notify_pipe) == 0) {
        fcntl(notify_pipe[1], F_SETFL, O_NONBLOCK);
    }
    install_handlers();
    CFRunLoopObserverRef observer =
        CFRunLoopObserverCreate(NULL, kCFRunLoopAllActivities, true, 0, observe_run_loop, NULL);
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
    pthread_t watcher;
    pthread_create(&watcher, NULL, watch_main, NULL);
    pthread_detach(watcher);
}

void op_crash_set_directory(const char *path) {
    strlcpy(directory, path ? path : "", sizeof(directory));
    summary[0] = 0; // a new session starts with no cause
}

void op_crash_set_stderr_fd(int fd) { stderr_fd = fd; }

void op_crash_note(const char *line) {
    size_t length = strlen(line), size = sizeof(recent);
    if (length >= size) {
        return;
    }
    size_t at = atomic_fetch_add(&recent_end, length + 1);
    for (size_t i = 0; i < length; i++) {
        recent[(at + i) % size] = line[i];
    }
    recent[(at + length) % size] = '\n';
}

int op_crash_notify_fd(void) { return notify_pipe[0]; }

const char *op_crash_last_summary(void) { return summary; }

int op_crash_engine_call(const char *engine, int (^body)(void)) {
    if (!pthread_main_np() || depth >= MAX_DEPTH) {
        return body();
    }
    int index = depth;
    recovery_t *recovery = &recoveries[index];
    recovery->engine = engine;
    recovery->frame = (uintptr_t)__builtin_frame_address(0);
    int sig = sigsetjmp(recovery->jump, 1);
    if (sig == 0) {
        depth = index + 1;
        int status = body();
        depth = index;
        // Engines install handlers of their own (Ruby takes SIGSEGV); OmniPlay's come back once the engine is done.
        install_handlers();
        return status;
    }
    depth = index;
    install_handlers();
    return OP_CRASH_STATUS_BASE - sig;
}
