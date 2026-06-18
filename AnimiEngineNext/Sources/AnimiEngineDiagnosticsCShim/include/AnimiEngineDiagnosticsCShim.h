#ifndef ANIMI_ENGINE_DIAGNOSTICS_CSHIM_H
#define ANIMI_ENGINE_DIAGNOSTICS_CSHIM_H

#include <stddef.h>
#include <stdint.h>

/// Task-003 §10.1 corrective shim — secure, descriptor-relative supplemental-artifact creation.
///
/// This target exists **only** because Swift's Darwin overlay marks the variadic `open`/`openat`/
/// `syscall` as unavailable, so the mandated `openat`/`O_NOFOLLOW`/`O_EXCL` write cannot be expressed
/// in pure Swift. It exposes exactly one operation and no generic filesystem API.

/// The shim operation that failed (or `AEN_OP_OK` on success). Returned to Swift so a typed error
/// can name the precise step.
typedef enum {
    AEN_OP_OK = 0,
    AEN_OP_OPEN_ROOT,      ///< opening the staging root directory
    AEN_OP_MKDIRAT,        ///< creating an intermediate directory
    AEN_OP_OPEN_DIR,       ///< opening an intermediate directory (O_NOFOLLOW)
    AEN_OP_OPEN_LEAF,      ///< creating the leaf file (O_CREAT|O_EXCL|O_NOFOLLOW)
    AEN_OP_WRITE,          ///< writing the file bytes
    AEN_OP_FSYNC,          ///< host-to-device flush of the leaf file (fsync)
    AEN_OP_CLOSE,          ///< closing the leaf file descriptor
    AEN_OP_INVALID_ARG     ///< a NULL / zero-component argument
} aen_shim_op;

/// Structured result: which operation failed and the captured `errno` (0 on success).
typedef struct {
    aen_shim_op op;
    int32_t err;           ///< errno value captured at the point of failure (0 on success)
} aen_shim_result;

/// Create one supplemental file exclusively, walking descriptor-relative from `staging_root_path`.
///
/// `components` is an array of `component_count` NUL-terminated path components (already validated by
/// Swift: relative, no `.`/`..`/empty/NUL/separator). The last component is the leaf file; the
/// preceding components are directories created as needed.
///
/// Security contract (Task-003 corrective pass, §10.1):
///   * staging root opened with `O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC`;
///   * each directory component created with `mkdirat` (tolerating `EEXIST`) then opened with
///     `O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC` — a symlinked component fails (`ELOOP`);
///   * the leaf created with `O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC` — an existing
///     target is never overwritten (`EEXIST`) and a symlinked leaf is rejected;
///   * `data` (`length` bytes) written with a checked loop that retries `EINTR`/short writes;
///   * the leaf is `fsync`'d (host-to-device flush; `F_FULLFSYNC` is not required in Task 003) and
///     its `close` result is checked — a failure of either is reported as `AEN_OP_FSYNC`/`AEN_OP_CLOSE`;
///   * every descriptor is closed on every return path;
///   * no absolute path is ever reconstructed or re-walked; no generic FS surface is exposed.
///
/// Returns `{AEN_OP_OK, 0}` on a fully-written file, else the failing operation and its errno.
aen_shim_result aen_write_supplemental_file_exclusively(
    const char *staging_root_path,
    const char *const *components,
    size_t component_count,
    const uint8_t *data,
    size_t length
);

#endif /* ANIMI_ENGINE_DIAGNOSTICS_CSHIM_H */
