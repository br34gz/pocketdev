// Bootstrap for qemu-aarch64-softmmu loaded from an embedded framework.
// The frameworks come from UTM-SE.ipa (TCTI-interpreter build, matches
// Pocket Claude's accepted "slow mode" - spec sections 2 and 6). Entry
// points are qemu_init(argc, argv, envp) followed by a blocking
// qemu_main_loop(); patterned on utmapp/UTM's QEMULauncher/Bootstrap.c.
//
// Every phase writes to the boot log so a crash inside qemu_init (which
// is documented to exit(2) on argv errors) leaves a breadcrumb - see
// the atexit hook installed in pocket_qemu_run.

#ifndef POCKETCLAUDE_QEMU_BOOTSTRAP_H
#define POCKETCLAUDE_QEMU_BOOTSTRAP_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Load qemu-aarch64-softmmu.framework and run it. argv MUST include
// argv[0]. Blocks until qemu_main_loop returns. Returns:
//    0  qemu_main_loop returned normally
//   -1  dlopen failed
//   -2  dlsym failed
// If qemu_init calls exit(2) internally, the process terminates and
// the installed atexit hook logs `qemu_exit_hook` beforehand.
int pocket_qemu_run(const char *dylib_path, int argc, const char **argv);

// Decompress a zstd-compressed file to a destination path using libzstd
// from the embedded zstd.1.framework. Returns 0 on success, negative on
// error.
int pocket_zstd_decompress_file(const char *zstd_framework_path,
                                const char *src_path,
                                const char *dst_path);

#ifdef __cplusplus
}
#endif

#endif
