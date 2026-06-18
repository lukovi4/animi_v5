#include "AnimiEngineDiagnosticsCShim.h"

#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/stat.h>

/// See the header for the full security contract. This file is the only place `openat`/`mkdirat`
/// with `O_NOFOLLOW`/`O_EXCL` are called; Swift cannot express the variadic forms.

static aen_shim_result aen_make_result(aen_shim_op op, int err) {
    aen_shim_result result;
    result.op = op;
    result.err = (int32_t)err;
    return result;
}

aen_shim_result aen_write_supplemental_file_exclusively(
    const char *staging_root_path,
    const char *const *components,
    size_t component_count,
    const uint8_t *data,
    size_t length
) {
    if (staging_root_path == NULL || components == NULL || component_count == 0) {
        return aen_make_result(AEN_OP_INVALID_ARG, EINVAL);
    }
    if (length > 0 && data == NULL) {
        return aen_make_result(AEN_OP_INVALID_ARG, EINVAL);
    }

    // Open the staging root. O_NOFOLLOW: the staging root itself must not be a symlink.
    int parent_fd = open(staging_root_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (parent_fd < 0) {
        return aen_make_result(AEN_OP_OPEN_ROOT, errno);
    }

    // Walk/create the parent directory components (all but the last).
    for (size_t i = 0; i + 1 < component_count; i++) {
        const char *component = components[i];

        if (mkdirat(parent_fd, component, 0755) != 0) {
            int e = errno;
            if (e != EEXIST) {
                close(parent_fd);
                return aen_make_result(AEN_OP_MKDIRAT, e);
            }
        }

        // O_NOFOLLOW: a symlinked directory component fails with ELOOP and is rejected.
        int child_fd = openat(parent_fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (child_fd < 0) {
            int e = errno;
            close(parent_fd);
            return aen_make_result(AEN_OP_OPEN_DIR, e);
        }
        close(parent_fd);
        parent_fd = child_fd;
    }

    // Create the leaf file exclusively. O_EXCL rejects an existing target (no overwrite);
    // O_NOFOLLOW rejects a symlinked leaf.
    const char *leaf = components[component_count - 1];
    int file_fd = openat(parent_fd, leaf,
                         O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (file_fd < 0) {
        int e = errno;
        close(parent_fd);
        return aen_make_result(AEN_OP_OPEN_LEAF, e);
    }

    // Checked complete write loop: retry EINTR and short writes; fail on any error.
    size_t offset = 0;
    while (offset < length) {
        ssize_t written = write(file_fd, data + offset, length - offset);
        if (written < 0) {
            if (errno == EINTR) {
                continue;
            }
            int e = errno;
            close(file_fd);
            close(parent_fd);
            return aen_make_result(AEN_OP_WRITE, e);
        }
        if (written == 0) {
            // Defensive: a zero-length write with bytes remaining is an unexpected failure.
            close(file_fd);
            close(parent_fd);
            return aen_make_result(AEN_OP_WRITE, EIO);
        }
        offset += (size_t)written;
    }

    // Host-to-device flush before declaring success (fsync; F_FULLFSYNC is not required in
    // Task 003). Retry EINTR.
    int fsync_result;
    do {
        fsync_result = fsync(file_fd);
    } while (fsync_result != 0 && errno == EINTR);
    if (fsync_result != 0) {
        int e = errno;
        close(file_fd);
        close(parent_fd);
        return aen_make_result(AEN_OP_FSYNC, e);
    }

    // A failed close can report a deferred write error and must not be ignored. Call close exactly
    // once — on Darwin the descriptor is already closed even when close returns EINTR, so retrying
    // would risk closing an unrelated reused fd.
    if (close(file_fd) != 0) {
        int e = errno;
        close(parent_fd);
        return aen_make_result(AEN_OP_CLOSE, e);
    }

    close(parent_fd);
    return aen_make_result(AEN_OP_OK, 0);
}
