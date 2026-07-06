// Boot log — early diagnostic. A __attribute__((constructor)) in
// BootLog.c writes a `dylib_ctor` line to $HOME/Documents/pocket-claude-boot.log
// before Swift startup runs, so we can distinguish pre-main dyld/amfid
// crashes (no log file created at all) from Swift-side crashes (log file
// exists with some entries but stops before the last-expected phase).

#ifndef POCKETCLAUDE_BOOT_LOG_H
#define POCKETCLAUDE_BOOT_LOG_H

#ifdef __cplusplus
extern "C" {
#endif

// Append `phase` to the boot log with a Unix timestamp. Safe to call
// before Foundation is initialized. Silently no-ops on I/O errors so a
// broken log path can't cascade into a real crash.
void pocket_boot_log(const char *phase);

#ifdef __cplusplus
}
#endif

#endif
