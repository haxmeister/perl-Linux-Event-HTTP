#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "stream_consumer_abi.h"
#include "unblock_http1_native_abi.h"

/* The provider tables have different contracts. Never cast one to the other. */
typedef struct {
    const les_consumer_host_api_v1_t *host;
    void *host_context;
    SV *stream;
    const ub_http1_input_ops_v1 *input_ops;
    void *input_context;
} bridge_context;

static void *
bridge_create(pTHX_ const les_consumer_host_api_v1_t *host,
    void *host_context, SV *stream)
{
    bridge_context *ctx;
    dSP;
    UV address;
    if (host->abi_version != LES_CONSUMER_ABI_VERSION
        || host->struct_size < LES_CONSUMER_HOST_V1_RETAIN_REQUIRED_SIZE
        || !host->retain || !host->release)
        croak("HTTP bridge requires Linux::Event consumer lifetime support");
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    PUTBACK;
    call_pv("Linux::Event::HTTP::_NativeBridge::_input_operations_address", G_SCALAR);
    SPAGAIN;
    address = POPu;
    PUTBACK;
    FREETMPS;
    LEAVE;
    {
        const ub_http1_input_ops_v1 *ops = INT2PTR(const ub_http1_input_ops_v1 *, address);
        if (!ops || ops->abi_version != UB_HTTP1_INPUT_ABI_VERSION
            || ops->struct_size < sizeof(ub_http1_input_ops_v1)
            || !ops->create || !ops->input || !ops->eof || !ops->destroy)
            croak("incompatible Unblock::HTTP1 native input ABI");
        Newxz(ctx, 1, bridge_context);
        ctx->input_ops = ops;
    }
    ctx->host = host;
    ctx->host_context = host_context;
    ctx->stream = newSVsv(stream);
    sv_rvweaken(ctx->stream);
    return ctx;
}

static int
bridge_input(pTHX_ void *opaque, const char *data, size_t length, size_t *consumed)
{
    bridge_context *ctx = (bridge_context *)opaque;
    const les_consumer_host_api_v1_t *host = ctx->host;
    void *host_context = ctx->host_context;
    int jump_status;
    int result = UB_HTTP1_INPUT_OK;
    dJMPENV;
    *consumed = 0;
    if (!host->retain(aTHX_ host_context))
        return LES_CONSUMER_CLOSE;
    JMPENV_PUSH(jump_status);
    if (jump_status == 0) {
        if (!ctx->input_context) {
            SV **engine;
            if (!SvROK(ctx->stream) || SvTYPE(SvRV(ctx->stream)) != SVt_PVHV)
                croak("HTTP bridge stream is unavailable");
            engine = hv_fetch((HV *)SvRV(ctx->stream), "http_engine", 11, 0);
            if (!engine || !SvROK(*engine))
                croak("HTTP bridge received input before engine attachment");
            ctx->input_context = ctx->input_ops->create(aTHX_ *engine);
            if (!ctx->input_context)
                croak("HTTP bridge could not create input context");
        }
        result = ctx->input_ops->input(aTHX_ ctx->input_context, data, length, consumed);
        if (*consumed > length)
            croak("HTTP engine consumed beyond its borrowed input window");
        switch (result) {
        case UB_HTTP1_INPUT_OK:
        case UB_HTTP1_INPUT_MORE:
            break;
        case UB_HTTP1_INPUT_CLOSED:
            /* End has already queued the final output. Discard trailing HTTP
             * input; do not close the socket ahead of its pending writes. */
            *consumed = length;
            break;
        case UB_HTTP1_INPUT_SWITCH:
            croak("native generic protocol handoff is not implemented yet");
        default:
            croak("HTTP engine returned an unknown native input status");
        }
        JMPENV_POP;
    } else {
        JMPENV_POP;
        host->release(aTHX_ host_context);
        JMPENV_JUMP(jump_status);
    }
    /* May destroy ctx and the host after reentrant close. Last access. */
    host->release(aTHX_ host_context);
    return LES_CONSUMER_CONTINUE;
}

static void
bridge_event(pTHX_ void *opaque, uint32_t event, int error, const char *message)
{
    /* Ordinary Stream lifecycle callbacks deliver EOF/error exactly once. */
    PERL_UNUSED_ARG(opaque);
    PERL_UNUSED_ARG(event);
    PERL_UNUSED_ARG(error);
    PERL_UNUSED_ARG(message);
    PERL_UNUSED_CONTEXT;
}

static void
bridge_destroy(pTHX_ void *opaque)
{
    bridge_context *ctx = (bridge_context *)opaque;
    if (!ctx) return;
    if (ctx->input_context)
        ctx->input_ops->destroy(aTHX_ ctx->input_context);
    SvREFCNT_dec(ctx->stream);
    Safefree(ctx);
}

static const les_consumer_ops_v1_t bridge_ops = {
    LES_CONSUMER_ABI_VERSION, sizeof(les_consumer_ops_v1_t),
    "Linux::Event::HTTP Unblock HTTP1 input", LES_CONSUMER_F_RAW_INPUT,
    bridge_create, NULL, bridge_event, bridge_destroy, NULL, bridge_input
};

MODULE = Linux::Event::HTTP::_NativeBridge PACKAGE = Linux::Event::HTTP::_NativeBridge
PROTOTYPES: DISABLE

UV
_operations_address()
  CODE:
    RETVAL = PTR2UV(&bridge_ops);
  OUTPUT:
    RETVAL
