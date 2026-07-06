#include "BootLog.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/stat.h>

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

// Runs before main(). If this line is present in the log, dyld
// successfully loaded PocketClaude's own binary — meaning any crash
// happened later (Swift App.init, SwiftUI, UIKit hookup) rather than
// during library load / signature verification.
__attribute__((constructor))
static void pocket_ctor_marker(void) {
    write_line("dylib_ctor");
}

void pocket_boot_log(const char *phase) {
    write_line(phase);
}
