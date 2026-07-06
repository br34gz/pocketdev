#include "BootLog.h"

#include <dlfcn.h>
#include <mach/mach.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

// MAP_JIT lives in Darwin's <sys/mman.h> on modern SDKs but on iOS
// the constant is 0x800. Guard the include so an older SDK still
// compiles.
#ifndef MAP_JIT
#define MAP_JIT 0x800
#endif

static void write_line(const char *phase) {
    // On iOS, $HOME points at the app sandbox root; Documents/ is a
    // sibling of Library/. Both exist by default for a launched app.
    const char *home = getenv("HOME");
    if (!home) return;
    char dir[1024];
    char path[1152];
    snprintf(dir, sizeof(dir), "%s/Documents", home);
    // mkdir is a no-op if it exists; we do it defensively for the
    // pre-main constructor case where the sandbox may not have been
    // touched yet.
    mkdir(dir, 0755);
    snprintf(path, sizeof(path), "%s/pocket-claude-boot.log", dir);
    FILE *f = fopen(path, "a");
    if (!f) return;
    time_t t = time(NULL);
    fprintf(f, "%ld\t%s\n", (long)t, phase ? phase : "(null)");
    fclose(f);
}

void pocket_boot_log(const char *phase) {
    write_line(phase);
}

// JIT probe - see header for return values. We deliberately do NOT
// try to execute code we wrote; on a device without the runtime
// exec grant that would SIGKILL us. The mmap-and-toggle result is a
// sufficient proxy: if MAP_JIT succeeds and the W/X toggle doesn't
// fault, the app has the JIT entitlement and QEMU's TCG will emit
// native code freely. The user's actual boot time will tell us
// whether execute-grant is in place too (from StikDebug etc).
int pocket_probe_jit(void) {
    size_t page = 16384;  // iOS arm64 uses 16 KB pages
    void *p = mmap(NULL, page,
                   PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (p == MAP_FAILED) {
        return 0;  // jit_unavailable
    }
    // pthread_jit_write_protect_np is marked macOS-only in the iOS
    // SDK but does exist at runtime on iOS 17+ - dlsym it to bypass
    // the SDK availability check. If the symbol is missing we still
    // report success on the mmap; the write below stays permitted
    // because MAP_JIT with PROT_WRITE was already accepted.
    void (*toggle)(int) = dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np");
    if (toggle) toggle(0);  // W enabled, X disabled
    ((uint32_t *)p)[0] = 0xD503201F;  // NOP
    ((uint32_t *)p)[1] = 0xD65F03C0;  // RET
    if (toggle) toggle(1);  // W disabled, X enabled
    munmap(p, page);
    return 1;  // jit_allowed
}

void pocket_boot_log_rss(void) {
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(),
                                 MACH_TASK_BASIC_INFO,
                                 (task_info_t)&info,
                                 &count);
    char buf[64];
    if (kr == KERN_SUCCESS) {
        unsigned long long rss_mb = (unsigned long long)(info.resident_size / (1024ULL * 1024ULL));
        snprintf(buf, sizeof(buf), "rss_mb=%llu", rss_mb);
    } else {
        snprintf(buf, sizeof(buf), "rss_mb=?");
    }
    write_line(buf);
}

// Signal handler: log the signal, then re-raise with the default
// disposition so the process still terminates properly.
static void pocket_signal_handler(int sig) {
    char msg[48];
    snprintf(msg, sizeof(msg), "signal_received sig=%d", sig);
    // write_line uses fopen/fprintf/fclose. Async-signal-safe? Not
    // strictly. But we're already dying; if the write itself faults
    // we're no worse off than not having the line.
    write_line(msg);
    signal(sig, SIG_DFL);
    raise(sig);
}

// Constructor runs before main(). Installs signal handlers for the
// signals we might see leading up to a jetsam / abort. SIGKILL itself
// cannot be caught - that is what iOS's memory manager sends - but
// SIGTERM sometimes precedes it, and SIGABRT/SIGBUS/SIGSEGV would
// catch our own crashes.
__attribute__((constructor))
static void pocket_ctor_marker(void) {
    signal(SIGTERM, pocket_signal_handler);
    signal(SIGABRT, pocket_signal_handler);
    signal(SIGBUS,  pocket_signal_handler);
    signal(SIGSEGV, pocket_signal_handler);
    signal(SIGILL,  pocket_signal_handler);
    write_line("dylib_ctor");
}
