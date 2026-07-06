// Boot log — early diagnostic. A __attribute__((constructor)) in
// BootLog.c writes a `dylib_ctor` line to $HOME/Documents/pocketdev-boot.log
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

// Log the current process's resident set size, in MB. Uses
// mach_task_basic_info; the sample happens at call time. Useful for
// jetsam-kill forensics from the atexit hook.
void pocket_boot_log_rss(void);

// JIT capability probe. Attempts an mmap with PROT_EXEC|MAP_JIT and,
// on success, exercises pthread_jit_write_protect_np toggling. Does
// NOT execute synthesized code, because on iOS with strict signature
// enforcement an unauthorized exec faults SIGKILL (unrecoverable).
// Returns:
//   0  jit_unavailable     - MAP_JIT mmap failed (typical sideload)
//   1  jit_allowed         - mmap succeeded, W/X toggle succeeded
//   2  jit_toggle_failed   - mmap succeeded, W/X toggle set errno
int pocket_probe_jit(void);

#ifdef __cplusplus
}
#endif

#endif
