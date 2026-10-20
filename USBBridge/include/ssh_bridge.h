#ifndef SSH_BRIDGE_H
#define SSH_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle to an SSH session over RNDIS
typedef struct ssh_session ssh_session_t;

/// Result of a command execution
typedef struct {
    char    *stdout_buf;
    uint32_t stdout_len;
    char    *stderr_buf;
    uint32_t stderr_len;
    int      exit_code;
} ssh_exec_result_t;

/// Open an SSH session: RNDIS init → TCP connect → SSH handshake → auth.
/// vid/pid: USB device to open (e.g., RNDIS_VID/RNDIS_PID)
/// host_ip: our IP (e.g., "169.254.13.38")
/// remote_ip: console IP (e.g., "169.254.13.37")
/// Returns NULL on failure.
ssh_session_t *ssh_session_open(uint16_t vid, uint16_t pid,
                                 const char *host_ip, const char *remote_ip);

/// Execute a command and capture stdout/stderr.
/// Caller must call ssh_result_free() on the result.
/// Returns 0 on success, negative on error.
int ssh_exec(ssh_session_t *s, const char *command, ssh_exec_result_t *result,
             int timeout_ms);

/// Execute a command with stdin data piped in (e.g., "cat > /path" or "tar -xvC /dir").
/// Returns 0 on success, negative on error.
int ssh_exec_stdin(ssh_session_t *s, const char *command,
                    const uint8_t *stdin_data, uint32_t stdin_len,
                    ssh_exec_result_t *result, int timeout_ms);

/// Receives stdout chunks from ssh_exec_stream(). Return false to abort.
typedef bool (*ssh_stream_cb)(const uint8_t *data, uint32_t len, void *ctx);

/// Reports stdin bytes written so far by ssh_exec_stream().
typedef void (*ssh_progress_cb)(uint64_t written, uint64_t total, void *ctx);

/// Execute a command, optionally piping stdin_data in, and deliver stdout in
/// chunks to out_cb instead of buffering it (for large downloads such as NAND
/// dumps). stderr is still buffered into result->stderr_buf; result->stdout_buf
/// stays NULL. idle_timeout_ms is reset whenever data moves, so long transfers
/// do not time out while they make progress.
/// Returns 0 on success, -2 if out_cb aborted, other negative values on error.
int ssh_exec_stream(ssh_session_t *s, const char *command,
                    const uint8_t *stdin_data, uint64_t stdin_len,
                    ssh_stream_cb out_cb, ssh_progress_cb progress_cb, void *ctx,
                    ssh_exec_result_t *result, int idle_timeout_ms);

/// Opaque interactive shell (PTY + shell channel)
typedef struct ssh_shell ssh_shell_t;

/// Open an interactive shell with a "vt100" PTY of the given size.
/// Returns NULL on failure. Use only from one thread at a time, together with
/// the other calls on the same session.
ssh_shell_t *ssh_shell_open(ssh_session_t *s, int cols, int rows);

/// Read available output (stdout and stderr merged) for up to timeout_ms.
/// Returns bytes read, 0 if nothing arrived, -1 when the shell has exited.
int ssh_shell_read(ssh_shell_t *sh, uint8_t *buf, uint32_t cap, int timeout_ms);

/// Write keyboard input. Returns bytes written or negative on error.
int ssh_shell_write(ssh_shell_t *sh, const uint8_t *data, uint32_t len);

/// Tell the remote side the terminal size changed.
int ssh_shell_resize(ssh_shell_t *sh, int cols, int rows);

/// Close the shell channel (the SSH session stays open).
void ssh_shell_close(ssh_shell_t *sh);

/// Free memory in an exec result.
void ssh_result_free(ssh_exec_result_t *result);

/// Close the SSH session, TCP connection, and RNDIS device.
void ssh_session_close(ssh_session_t *s);

/// Check if RNDIS device is present on USB.
bool ssh_device_exists(void);

#ifdef __cplusplus
}
#endif

#endif /* SSH_BRIDGE_H */
