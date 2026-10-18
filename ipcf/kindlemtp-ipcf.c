/*
 * kindlemtp-ipcf: calls the MTP responder's IPCF4 service on Kindle firmware 5.19 and later,
 * where tizen-mtp no longer registers the lipc properties startMtp/stopMtp/isMtpStarted.
 *
 *   kindlemtp-ipcf ping    connect to com.lab126.mtp.service and disconnect (no side effect)
 *   kindlemtp-ipcf start   startMtpAsync(1): same flag and event 11 as lipc "startMtp 1"
 *   kindlemtp-ipcf stop    stopMtpAsync(1):  same flag and event 15 as lipc "stopMtp 1"
 *
 * Exit 0 on success, 2 when libipcn is missing, 3 when the service can't be reached, 4 when the
 * call fails. Reverse engineered from libipcf4.so, libmtp-helper.so and volumd of firmware 5.19.5
 * (docs/design.md, "Firmware 5.19"). libipcn is loaded with dlopen so the binary also runs, and
 * fails cleanly, on firmware that doesn't have it.
 */
#include <dlfcn.h>
#include <signal.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define SERVICE "com.lab126.mtp.service"
#define CODE_CONNECT 0xffff /* IpcnSkeleton::onConnectionCall: add a session */
#define CODE_START 0x65     /* MtpHelperService::startMtpAsync(int) */
#define CODE_STOP 0x66      /* MtpHelperService::stopMtpAsync(int) */

typedef struct { uint32_t binder; void *local; } ipcn_handle; /* remote: binder handle; local: endpoint */
typedef void ipcn_runtime, ipcn_payload, ipcn_buffer, ipcn_identity;

/* An endpoint is a struct whose first word points at its callbacks (IpcnEndpoint::IpcnEndpoint). */
struct ipcn_ops {
    int (*on_call)(void *, void *, unsigned, ipcn_identity *, ipcn_buffer *, ipcn_payload *);
    int (*on_call_oneway)(void *, void *, unsigned, ipcn_identity *, ipcn_buffer *);
    void (*acquired)(void *, void *);
    void (*released)(void *, void *);
};
struct ipcn_endpoint { const struct ipcn_ops *ops; uint32_t pad[31]; };

static int (*p_create)(ipcn_runtime **, int, int, int);
static int (*p_run_loop)(ipcn_runtime *);
static int (*p_bind)(ipcn_runtime *, const char *, void (*)(ipcn_runtime *, void *, const char *, ipcn_handle), void *);
static int (*p_valid)(ipcn_runtime *, ipcn_handle *);
static int (*p_acquire)(ipcn_runtime *, ipcn_handle *);
static ipcn_payload *(*p_payload_alloc)(void);
static ipcn_buffer *(*p_buffer_alloc)(void);
static int (*p_write_i32)(ipcn_payload *, int32_t);
static void (*p_write_endpoint)(ipcn_payload *, struct ipcn_endpoint *);
static int (*p_payload_error)(ipcn_payload *);
static int (*p_call)(ipcn_runtime *, ipcn_handle *, unsigned, ipcn_payload *, ipcn_buffer *);
static int (*p_call_oneway)(ipcn_runtime *, ipcn_handle *, unsigned, ipcn_payload *);
static uint16_t (*p_read_u16)(ipcn_buffer *);
static ipcn_handle (*p_read_endpoint)(ipcn_buffer *);
static int (*p_buffer_error)(ipcn_buffer *);
static int (*p_reply_done)(ipcn_runtime *, ipcn_buffer *);

static int on_call(void *rt, void *ep, unsigned code, ipcn_identity *id, ipcn_buffer *in, ipcn_payload *out)
{
    (void)rt; (void)ep; (void)code; (void)id; (void)in; (void)out;
    return 0;
}
static int on_call_oneway(void *rt, void *ep, unsigned code, ipcn_identity *id, ipcn_buffer *in)
{
    (void)rt; (void)ep; (void)code; (void)id; (void)in;
    return 0;
}
static void noop(void *rt, void *ep) { (void)rt; (void)ep; }
static const struct ipcn_ops ops = { on_call, on_call_oneway, noop, noop };
static struct ipcn_endpoint endpoint = { &ops, { 0 } };

static ipcn_handle service;
static volatile int bound; /* 1 valid handle, -1 failed */

static void bind_cb(ipcn_runtime *rt, void *ctx, const char *name, ipcn_handle h)
{
    (void)ctx; (void)name;
    service = h;
    bound = p_valid(rt, &service) ? 1 : -1;
}

static void *loop(void *rt)
{
    p_run_loop(rt);
    return NULL;
}

/* _exit: the run-loop thread is still inside libipcn, so skip atexit handlers and destructors. */
static void done(int rc)
{
    fflush(stdout);
    _exit(rc);
}

#define SYM(var, name) if (!(*(void **)&var = dlsym(lib, name))) { fprintf(stderr, "missing %s\n", name); done(2); }
#define FAIL(rc, ...) do { fprintf(stderr, __VA_ARGS__); done(rc); } while (0)

int main(int argc, char **argv)
{
    unsigned code;
    /* The plugin runs this on KOReader's UI thread: never hang there. SIGALRM kills us, and a
     * killed ping is an unanswered one (the 10 s matches liblipc's timeout). */
    alarm(10);
    if (argc != 2) goto usage;
    if (!strcmp(argv[1], "ping")) code = 0;
    else if (!strcmp(argv[1], "start")) code = CODE_START;
    else if (!strcmp(argv[1], "stop")) code = CODE_STOP;
    else goto usage;

    void *lib = dlopen("libipcn.so.0", RTLD_NOW);
    /* stdout, so the plugin can tell firmware without IPCF4 (lipc it is) from a failed call */
    if (!lib) { printf("no_ipcn\n"); FAIL(2, "%s\n", dlerror()); }
    SYM(p_create, "ipcn_create") SYM(p_run_loop, "ipcn_run_loop") SYM(p_bind, "ipcn_service_bind")
    SYM(p_valid, "ipcn_handle_is_valid") SYM(p_acquire, "ipcn_handle_acquire")
    SYM(p_payload_alloc, "ipcn_payload_alloc") SYM(p_buffer_alloc, "ipcn_buffer_alloc")
    SYM(p_write_i32, "ipcn_write_i32") SYM(p_write_endpoint, "ipcn_write_endpoint")
    SYM(p_call, "ipcn_call") SYM(p_call_oneway, "ipcn_call_oneway") SYM(p_read_u16, "ipcn_read_u16")
    SYM(p_read_endpoint, "ipcn_read_endpoint") SYM(p_buffer_error, "ipcn_buffer_last_error")
    SYM(p_reply_done, "ipcn_reply_done") SYM(p_payload_error, "ipcn_payload_last_error")

    /* Same as libmtp-helper's start_mtp_ipcf4_service: flags 0, 4 threads, 16 KiB buffers. */
    ipcn_runtime *rt = NULL;
    int rc = p_create(&rt, 0, 4, 0x4000);
    if (rc) FAIL(3, "ipcn_create %d\n", rc);
    pthread_t t;
    if (pthread_create(&t, NULL, loop, rt)) FAIL(3, "pthread_create\n");
    pthread_detach(t);

    /* libipcn 0.1.0 asks the service manager and calls back before returning (9: no such
     * service); waiting covers a library that calls back from the run loop instead. */
    rc = p_bind(rt, SERVICE, bind_cb, NULL);
    if (rc) FAIL(3, "ipcn_service_bind %d\n", rc);
    for (int i = 0; i < 300 && !bound; i++) usleep(10000);
    if (bound != 1) FAIL(3, "bind %s\n", bound ? "invalid handle" : "timeout");

    /* Session handshake, as IpcnProxy::serviceBindCallback: send our endpoint, read the session
     * id (u16) and the session endpoint. The service drops oneway calls without a session. */
    ipcn_payload *req = p_payload_alloc();
    ipcn_buffer *reply = p_buffer_alloc();
    if (!req || !reply) FAIL(3, "alloc\n");
    p_write_endpoint(req, &endpoint);
    if (p_payload_error(req)) FAIL(3, "write endpoint\n");
    rc = p_call(rt, &service, CODE_CONNECT, req, reply);
    if (rc) FAIL(3, "connect call %d\n", rc);
    uint16_t sid = p_read_u16(reply);
    ipcn_handle session = p_read_endpoint(reply);
    int berr = p_buffer_error(reply);
    /* read_endpoint does not acquire, and reply_done frees the buffer that holds the only
     * reference: acquire first, as IpcnEndpointHandle::getInstance does before replyDone. */
    int ok = sid && !berr && p_valid(rt, &session) && !p_acquire(rt, &session);
    p_reply_done(rt, reply);
    if (!ok) FAIL(3, "session sid=%u err=%d\n", sid, berr);
    if (!code) { printf("ok session=%u\n", sid); done(0); }

    ipcn_payload *p = p_payload_alloc();
    if (!p) FAIL(4, "alloc\n");
    p_write_i32(p, 1);
    if (p_payload_error(p)) FAIL(4, "write i32\n");
    rc = p_call_oneway(rt, &session, code, p);
    if (rc) FAIL(4, "call 0x%x %d\n", code, rc);
    /* Oneway: the service drops the call if our session dies first, so stay up a moment. */
    usleep(500000);
    printf("ok\n");
    done(0);

usage:
    FAIL(1, "usage: kindlemtp-ipcf ping|start|stop\n");
}
