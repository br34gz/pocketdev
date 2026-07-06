#include "QEMUBootstrap.h"
#include "BootLog.h"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// ---------------------------------------------------------------- QEMU

typedef int   (*qemu_init_fn)(int, const char *[], const char *[]);
typedef void  (*qemu_main_loop_fn)(void);
typedef void  (*qemu_cleanup_fn)(void);

// atexit hook: qemu_init is documented to exit(2) on argv errors. On
// Darwin, atexit handlers run on any exit() call (voluntary termination)
// so this leaves a breadcrumb in the boot log even if qemu terminates
// the process. Doesn't run on SIGKILL / SIGABRT but qemu_init uses
// exit(2), which triggers this path.
static void pocket_qemu_atexit_hook(void) {
    pocket_boot_log("qemu_exit_hook");
    pocket_boot_log_rss();
}

static int pocket_qemu_hook_armed = 0;

int pocket_qemu_run(const char *dylib_path, int argc, const char **argv) {
    // Arm the atexit hook once per process lifetime. atexit is idempotent
    // in effect but pushes duplicate entries onto its LIFO stack, so we
    // guard here.
    if (!pocket_qemu_hook_armed) {
        atexit(pocket_qemu_atexit_hook);
        pocket_qemu_hook_armed = 1;
        pocket_boot_log("qemu_atexit_armed");
    }

    pocket_boot_log("qemu_bootstrap_dlopen_start");
    void *dl = dlopen(dylib_path, RTLD_LOCAL | RTLD_LAZY | RTLD_FIRST);
    if (!dl) {
        pocket_boot_log("qemu_bootstrap_dlopen_failed");
        fprintf(stderr, "pocket-claude: dlopen(%s) failed: %s\n",
                dylib_path, dlerror());
        return -1;
    }
    pocket_boot_log("qemu_bootstrap_dlopen_ok");

    qemu_init_fn q_init = (qemu_init_fn) dlsym(dl, "qemu_init");
    qemu_main_loop_fn q_loop = (qemu_main_loop_fn) dlsym(dl, "qemu_main_loop");
    qemu_cleanup_fn q_cleanup = (qemu_cleanup_fn) dlsym(dl, "qemu_cleanup");
    if (!q_init || !q_loop || !q_cleanup) {
        pocket_boot_log("qemu_bootstrap_dlsym_failed");
        fprintf(stderr, "pocket-claude: dlsym failed: %s\n", dlerror());
        return -2;
    }
    pocket_boot_log("qemu_bootstrap_dlsym_ok");

    const char *envp[] = { NULL };
    pocket_boot_log("qemu_init_call");
    q_init(argc, argv, envp);
    // If we reach here, qemu_init returned without exit()ing. Rare but
    // it does happen on some paths.
    pocket_boot_log("qemu_init_return");

    pocket_boot_log("qemu_main_loop_entered");
    q_loop();
    pocket_boot_log("qemu_main_loop_returned");
    q_cleanup();
    return 0;
}

// ---------------------------------------------------------------- stderr

int pocket_qemu_redirect_stderr(const char *path) {
    // v0.3.0 boot log showed qemu_init_call -> qemu_exit_hook with no
    // qemu_init_return: qemu called exit() from inside its argv parser,
    // most likely on a socket-bind failure whose actual error message
    // only exists on stderr. This redirects stderr to a file so the
    // next crash leaves the real error string behind.
    if (!freopen(path, "w", stderr)) {
        return -1;
    }
    setvbuf(stderr, NULL, _IONBF, 0);
    return 0;
}

// ---------------------------------------------------------------- zstd

// libzstd streaming decompression API; declared here as the shape we
// dlsym rather than including <zstd.h> so the app builds without the
// header (framework ships binary only).

typedef struct ZSTD_DStream_ ZSTD_DStream;
typedef struct { const void *src; size_t size; size_t pos; } ZSTD_inBuffer;
typedef struct { void *dst; size_t size; size_t pos; } ZSTD_outBuffer;

typedef ZSTD_DStream* (*ZSTD_createDStream_fn)(void);
typedef size_t (*ZSTD_freeDStream_fn)(ZSTD_DStream*);
typedef size_t (*ZSTD_initDStream_fn)(ZSTD_DStream*);
typedef size_t (*ZSTD_decompressStream_fn)(ZSTD_DStream*, ZSTD_outBuffer*, ZSTD_inBuffer*);
typedef unsigned (*ZSTD_isError_fn)(size_t);
typedef const char* (*ZSTD_getErrorName_fn)(size_t);
typedef size_t (*ZSTD_DStreamInSize_fn)(void);
typedef size_t (*ZSTD_DStreamOutSize_fn)(void);

int pocket_zstd_decompress_file(const char *framework_path,
                                const char *src_path,
                                const char *dst_path) {
    pocket_boot_log("zstd_decompress_start");
    void *dl = dlopen(framework_path, RTLD_LOCAL | RTLD_LAZY);
    if (!dl) {
        pocket_boot_log("zstd_dlopen_failed");
        fprintf(stderr, "pocket-claude: dlopen zstd (%s) failed: %s\n",
                framework_path, dlerror());
        return -1;
    }
    ZSTD_createDStream_fn      _create   = dlsym(dl, "ZSTD_createDStream");
    ZSTD_freeDStream_fn        _free     = dlsym(dl, "ZSTD_freeDStream");
    ZSTD_initDStream_fn        _init     = dlsym(dl, "ZSTD_initDStream");
    ZSTD_decompressStream_fn   _decomp   = dlsym(dl, "ZSTD_decompressStream");
    ZSTD_isError_fn            _isErr    = dlsym(dl, "ZSTD_isError");
    ZSTD_getErrorName_fn       _errName  = dlsym(dl, "ZSTD_getErrorName");
    ZSTD_DStreamInSize_fn      _inSize   = dlsym(dl, "ZSTD_DStreamInSize");
    ZSTD_DStreamOutSize_fn     _outSize  = dlsym(dl, "ZSTD_DStreamOutSize");
    if (!_create || !_free || !_init || !_decomp || !_isErr || !_inSize || !_outSize) {
        pocket_boot_log("zstd_dlsym_failed");
        fprintf(stderr, "pocket-claude: zstd dlsym failed: %s\n", dlerror());
        return -2;
    }

    FILE *fin = fopen(src_path, "rb");
    if (!fin) { perror("zstd: fopen src"); return -3; }
    FILE *fout = fopen(dst_path, "wb");
    if (!fout) { perror("zstd: fopen dst"); fclose(fin); return -4; }

    size_t inBufSize  = _inSize();
    size_t outBufSize = _outSize();
    void *inBuf  = malloc(inBufSize);
    void *outBuf = malloc(outBufSize);
    ZSTD_DStream *ds = _create();
    _init(ds);

    int rc = 0;
    size_t nread;
    while ((nread = fread(inBuf, 1, inBufSize, fin)) > 0) {
        ZSTD_inBuffer input = { inBuf, nread, 0 };
        while (input.pos < input.size) {
            ZSTD_outBuffer output = { outBuf, outBufSize, 0 };
            size_t r = _decomp(ds, &output, &input);
            if (_isErr(r)) {
                fprintf(stderr, "pocket-claude: zstd error: %s\n", _errName(r));
                rc = -5; goto done;
            }
            if (output.pos > 0) {
                if (fwrite(outBuf, 1, output.pos, fout) != output.pos) {
                    perror("zstd: fwrite"); rc = -6; goto done;
                }
            }
        }
    }
done:
    _free(ds);
    free(inBuf); free(outBuf);
    fclose(fin); fclose(fout);
    if (rc != 0) unlink(dst_path);
    pocket_boot_log(rc == 0 ? "zstd_decompress_ok" : "zstd_decompress_failed");
    return rc;
}
