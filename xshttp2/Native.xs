#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <nghttp2/nghttp2.h>
#include "../xshttp1/stream_consumer_abi.h"

#include <stdint.h>
#include <string.h>

typedef struct leh2_state_s leh2_state_t;
typedef struct leh2_provider_s leh2_provider_t;

struct leh2_provider_s {
    leh2_state_t *state;
    int32_t stream_id;
    SV *body;
    STRLEN offset;
    SV *callback;
    SV *callback_data;
    unsigned int deferred;
    leh2_provider_t *next;
};

struct leh2_state_s {
    nghttp2_session *session;
    HV *callbacks;
    SV *callback_error;
    unsigned int in_nghttp2;
    unsigned int close_pending;
    unsigned int closed;
    leh2_provider_t *providers;
};


static void
leh2_provider_free(leh2_provider_t *provider)
{
    if (!provider)
        return;
    if (provider->body)
        SvREFCNT_dec(provider->body);
    if (provider->callback)
        SvREFCNT_dec(provider->callback);
    if (provider->callback_data)
        SvREFCNT_dec(provider->callback_data);
    Safefree(provider);
}

static leh2_provider_t *
leh2_provider_find(leh2_state_t *state, int32_t stream_id)
{
    leh2_provider_t *provider;

    for (provider = state->providers; provider; provider = provider->next) {
        if (provider->stream_id == stream_id)
            return provider;
    }
    return NULL;
}

static void
leh2_provider_add(leh2_state_t *state, leh2_provider_t *provider)
{
    provider->next = state->providers;
    state->providers = provider;
}

static void
leh2_provider_remove(leh2_state_t *state, int32_t stream_id)
{
    leh2_provider_t **slot = &state->providers;

    while (*slot) {
        leh2_provider_t *provider = *slot;
        if (provider->stream_id == stream_id) {
            *slot = provider->next;
            leh2_provider_free(provider);
            return;
        }
        slot = &provider->next;
    }
}

static void
leh2_provider_remove_all(leh2_state_t *state)
{
    leh2_provider_t *provider = state->providers;

    state->providers = NULL;
    while (provider) {
        leh2_provider_t *next = provider->next;
        leh2_provider_free(provider);
        provider = next;
    }
}

static leh2_state_t *
leh2_state_from_sv(SV *self)
{
    SV *inner;
    leh2_state_t *state;

    if (!SvROK(self))
        croak("native HTTP/2 session is not an object");

    inner = SvRV(self);
    state = INT2PTR(leh2_state_t *, SvIV(inner));
    if (!state)
        croak("native HTTP/2 session is already destroyed");

    return state;
}

static void
leh2_finish_close(leh2_state_t *state)
{
    if (!state || state->closed)
        return;

    if (state->session) {
        nghttp2_session_del(state->session);
        state->session = NULL;
    }
    leh2_provider_remove_all(state);
    state->closed = 1;
    state->close_pending = 0;
}

static void
leh2_leave_nghttp2(leh2_state_t *state)
{
    if (state->in_nghttp2)
        --state->in_nghttp2;

    if (!state->in_nghttp2 && state->close_pending)
        leh2_finish_close(state);
}

static void
leh2_store_callback_error(pTHX_ leh2_state_t *state)
{
    if (!state->callback_error)
        state->callback_error = newSVsv(ERRSV);
    sv_setsv(ERRSV, &PL_sv_undef);
}

static int
leh2_call(pTHX_ leh2_state_t *state, const char *name, I32 argc, SV **argv)
{
    SV **slot;
    I32 i;
    dSP;

    if (!state || state->closed || state->close_pending)
        return 0;

    slot = hv_fetch(state->callbacks, name, (I32)strlen(name), 0);
    if (!slot || !SvOK(*slot))
        return 0;

    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    for (i = 0; i < argc; ++i)
        XPUSHs(sv_2mortal(argv[i]));
    PUTBACK;

    call_sv(*slot, G_DISCARD | G_EVAL);
    SPAGAIN;

    if (SvTRUE(ERRSV)) {
        leh2_store_callback_error(aTHX_ state);
        PUTBACK;
        FREETMPS;
        LEAVE;
        return NGHTTP2_ERR_CALLBACK_FAILURE;
    }

    PUTBACK;
    FREETMPS;
    LEAVE;
    return 0;
}

static int
leh2_on_begin_headers(nghttp2_session *session, const nghttp2_frame *frame,
    void *user_data)
{
    leh2_state_t *state = (leh2_state_t *)user_data;
    SV *args[3];
    dTHX;

    (void)session;
    args[0] = newSViv(frame->hd.stream_id);
    args[1] = newSViv(frame->hd.type);
    args[2] = newSViv(frame->hd.flags);
    return leh2_call(aTHX_ state, "on_begin_headers", 3, args);
}

static int
leh2_on_header(nghttp2_session *session, const nghttp2_frame *frame,
    const uint8_t *name, size_t namelen, const uint8_t *value,
    size_t valuelen, uint8_t flags, void *user_data)
{
    leh2_state_t *state = (leh2_state_t *)user_data;
    SV *args[4];
    dTHX;

    (void)session;
    args[0] = newSViv(frame->hd.stream_id);
    args[1] = newSVpvn((const char *)name, namelen);
    args[2] = newSVpvn((const char *)value, valuelen);
    args[3] = newSViv(flags);
    return leh2_call(aTHX_ state, "on_header", 4, args);
}

static int
leh2_on_data_chunk_recv(nghttp2_session *session, uint8_t flags,
    int32_t stream_id, const uint8_t *data, size_t len, void *user_data)
{
    leh2_state_t *state = (leh2_state_t *)user_data;
    SV *args[3];
    dTHX;

    (void)session;
    args[0] = newSViv(stream_id);
    args[1] = newSVpvn((const char *)data, len);
    args[2] = newSViv(flags);
    return leh2_call(aTHX_ state, "on_data_chunk_recv", 3, args);
}

static int
leh2_on_frame_recv(nghttp2_session *session, const nghttp2_frame *frame,
    void *user_data)
{
    leh2_state_t *state = (leh2_state_t *)user_data;
    HV *frame_hv = newHV();
    SV *args[1];
    dTHX;

    (void)session;

    hv_stores(frame_hv, "type", newSViv(frame->hd.type));
    hv_stores(frame_hv, "flags", newSViv(frame->hd.flags));
    hv_stores(frame_hv, "stream_id", newSViv(frame->hd.stream_id));
    hv_stores(frame_hv, "length", newSVuv(frame->hd.length));

    if (frame->hd.type == NGHTTP2_GOAWAY) {
        hv_stores(frame_hv, "last_stream_id",
            newSViv(frame->goaway.last_stream_id));
        hv_stores(frame_hv, "error_code",
            newSVuv(frame->goaway.error_code));
    } else if (frame->hd.type == NGHTTP2_RST_STREAM) {
        hv_stores(frame_hv, "error_code",
            newSVuv(frame->rst_stream.error_code));
    }

    args[0] = newRV_noinc((SV *)frame_hv);
    return leh2_call(aTHX_ state, "on_frame_recv", 1, args);
}

static int
leh2_on_stream_close(nghttp2_session *session, int32_t stream_id,
    uint32_t error_code, void *user_data)
{
    leh2_state_t *state = (leh2_state_t *)user_data;
    SV *args[2];
    int rv;
    dTHX;

    (void)session;
    args[0] = newSViv(stream_id);
    args[1] = newSVuv(error_code);
    rv = leh2_call(aTHX_ state, "on_stream_close", 2, args);
    leh2_provider_remove(state, stream_id);
    return rv;
}

static ssize_t
leh2_data_read(nghttp2_session *session, int32_t stream_id,
    uint8_t *buf, size_t length, uint32_t *data_flags,
    nghttp2_data_source *source, void *user_data)
{
    leh2_provider_t *provider = (leh2_provider_t *)source->ptr;
    leh2_state_t *state = (leh2_state_t *)user_data;
    dTHX;

    (void)session;
    (void)stream_id;

    if (!provider || provider->state != state)
        return NGHTTP2_ERR_CALLBACK_FAILURE;
    if (state->closed || state->close_pending)
        return NGHTTP2_ERR_CALLBACK_FAILURE;

    if (provider->body) {
        STRLEN body_len;
        const char *body = SvPVbyte(provider->body, body_len);
        STRLEN remaining = body_len - provider->offset;
        size_t take = remaining < (STRLEN)length
            ? (size_t)remaining : length;

        if (take) {
            Copy(body + provider->offset, buf, take, uint8_t);
            provider->offset += (STRLEN)take;
        }
        if (provider->offset == body_len)
            *data_flags |= NGHTTP2_DATA_FLAG_EOF;
        provider->deferred = 0;
        return (ssize_t)take;
    }

    if (provider->callback) {
        int count;
        int eof = 0;
        SV *data_sv = NULL;
        STRLEN data_len = 0;
        const char *data = NULL;
        dSP;

        ENTER;
        SAVETMPS;
        PUSHMARK(SP);
        mPUSHi(provider->stream_id);
        mPUSHu((UV)length);
        if (provider->callback_data)
            XPUSHs(provider->callback_data);
        PUTBACK;

        count = call_sv(provider->callback, G_ARRAY | G_EVAL);
        SPAGAIN;

        if (SvTRUE(ERRSV)) {
            leh2_store_callback_error(aTHX_ state);
            PUTBACK;
            FREETMPS;
            LEAVE;
            return NGHTTP2_ERR_CALLBACK_FAILURE;
        }

        if (count == 0) {
            PUTBACK;
            FREETMPS;
            LEAVE;
            provider->deferred = 1;
            return NGHTTP2_ERR_DEFERRED;
        }

        if (count >= 2) {
            SV *eof_sv = POPs;
            eof = SvTRUE(eof_sv) ? 1 : 0;
            --count;
        }

        data_sv = POPs;
        if (!SvOK(data_sv)) {
            while (--count > 0)
                (void)POPs;
            PUTBACK;
            FREETMPS;
            LEAVE;
            provider->deferred = 1;
            return NGHTTP2_ERR_DEFERRED;
        }

        if (SvROK(data_sv)) {
            while (--count > 0)
                (void)POPs;
            PUTBACK;
            FREETMPS;
            LEAVE;
            state->callback_error = newSVpvs(
                "HTTP/2 data provider returned a reference"
            );
            return NGHTTP2_ERR_CALLBACK_FAILURE;
        }

        data = SvPVbyte(data_sv, data_len);
        if ((size_t)data_len > length) {
            while (--count > 0)
                (void)POPs;
            PUTBACK;
            FREETMPS;
            LEAVE;
            state->callback_error = newSVpvs(
                "HTTP/2 data provider exceeded requested length"
            );
            return NGHTTP2_ERR_CALLBACK_FAILURE;
        }

        if (data_len)
            Copy(data, buf, data_len, uint8_t);
        while (--count > 0)
            (void)POPs;

        PUTBACK;
        FREETMPS;
        LEAVE;

        if (!data_len && !eof) {
            provider->deferred = 1;
            return NGHTTP2_ERR_DEFERRED;
        }

        if (eof)
            *data_flags |= NGHTTP2_DATA_FLAG_EOF;
        provider->deferred = 0;
        return (ssize_t)data_len;
    }

    return NGHTTP2_ERR_CALLBACK_FAILURE;
}

static leh2_provider_t *
leh2_provider_new(pTHX_ leh2_state_t *state, SV *body,
    SV *callback, SV *callback_data)
{
    leh2_provider_t *provider;

    Newxz(provider, 1, leh2_provider_t);
    provider->state = state;

    if (body && SvOK(body)) {
        STRLEN len;
        (void)SvPVbyte(body, len);
        if (len)
            provider->body = newSVsv(body);
    }

    if (callback && SvOK(callback)) {
        if (!SvROK(callback) || SvTYPE(SvRV(callback)) != SVt_PVCV) {
            leh2_provider_free(provider);
            croak("data callback must be a coderef");
        }
        provider->callback = SvREFCNT_inc(callback);
        if (callback_data && SvOK(callback_data))
            provider->callback_data = SvREFCNT_inc(callback_data);
    }

    if (!provider->body && !provider->callback) {
        leh2_provider_free(provider);
        return NULL;
    }

    return provider;
}

static nghttp2_nv *
leh2_make_nv(pTHX_ SV *headers, size_t *count)
{
    AV *av;
    SSize_t last;
    size_t i;
    nghttp2_nv *nva;

    if (!SvROK(headers) || SvTYPE(SvRV(headers)) != SVt_PVAV)
        croak("headers must be an array reference");

    av = (AV *)SvRV(headers);
    last = av_len(av);
    *count = last < 0 ? 0 : (size_t)last + 1;

    if (!*count)
        return NULL;

    Newxz(nva, *count, nghttp2_nv);

    for (i = 0; i < *count; ++i) {
        SV **pair_slot = av_fetch(av, (SSize_t)i, 0);
        AV *pair;
        SV **name_slot;
        SV **value_slot;
        STRLEN namelen, valuelen;
        const char *name;
        const char *value;

        if (!pair_slot || !SvROK(*pair_slot)
            || SvTYPE(SvRV(*pair_slot)) != SVt_PVAV) {
            Safefree(nva);
            croak("each header must be a [name, value] pair");
        }

        pair = (AV *)SvRV(*pair_slot);
        if (av_len(pair) != 1) {
            Safefree(nva);
            croak("each header must contain exactly name and value");
        }

        name_slot = av_fetch(pair, 0, 0);
        value_slot = av_fetch(pair, 1, 0);
        if (!name_slot || !value_slot || SvROK(*name_slot)
            || SvROK(*value_slot)) {
            Safefree(nva);
            croak("header name and value must be scalars");
        }

        name = SvPVbyte(*name_slot, namelen);
        value = SvPVbyte(*value_slot, valuelen);
        nva[i].name = (uint8_t *)name;
        nva[i].value = (uint8_t *)value;
        nva[i].namelen = namelen;
        nva[i].valuelen = valuelen;
        nva[i].flags = NGHTTP2_NV_FLAG_NONE;
    }

    return nva;
}

static void
leh2_throw_if_callback_failed(pTHX_ leh2_state_t *state)
{
    if (state->callback_error) {
        SV *error = state->callback_error;
        state->callback_error = NULL;
        croak_sv(error);
    }
}


typedef struct leh2_raw_context_s {
    const les_consumer_host_api_v1_t *host;
    void *host_context;
    SV *stream;
    SV *session_obj;
    leh2_state_t *state;
    CV *write_cv;
} leh2_raw_context_t;

static CV *
leh2_raw_find_method(pTHX_ SV *stream, const char *name)
{
    GV *gv;
    CV *cv;

    if (!SvROK(stream))
        croak("native HTTP/2 raw consumer stream is not an object");

    gv = gv_fetchmethod_autoload(SvSTASH(SvRV(stream)), name, 0);
    if (!gv || !(cv = GvCV(gv)))
        croak("native HTTP/2 raw consumer method %s is unavailable", name);

    return (CV *)SvREFCNT_inc((SV *)cv);
}

static int
leh2_raw_write(pTHX_ leh2_raw_context_t *context, SV *bytes)
{
    dSP;

    if (!context->write_cv)
        context->write_cv = leh2_raw_find_method(aTHX_ context->stream, "write");

    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    XPUSHs(context->stream);
    XPUSHs(bytes);
    PUTBACK;
    call_sv((SV *)context->write_cv, G_DISCARD | G_EVAL);
    SPAGAIN;

    if (SvTRUE(ERRSV)) {
        sv_setsv(ERRSV, &PL_sv_undef);
        PUTBACK;
        FREETMPS;
        LEAVE;
        return 0;
    }

    PUTBACK;
    FREETMPS;
    LEAVE;
    return 1;
}

static int
leh2_raw_flush(pTHX_ leh2_raw_context_t *context)
{
    leh2_state_t *state = context->state;

    while (!state->closed && nghttp2_session_want_write(state->session)) {
        const uint8_t *data = NULL;
        ssize_t rv;
        SV *bytes;

        ++state->in_nghttp2;
        rv = nghttp2_session_mem_send(state->session, &data);
        if (rv > 0)
            bytes = newSVpvn((const char *)data, (STRLEN)rv);
        else
            bytes = NULL;
        leh2_leave_nghttp2(state);

        if (state->callback_error)
            return 0;
        if (rv < 0)
            return 0;
        if (rv == 0)
            break;
        if (!bytes)
            return 0;

        sv_2mortal(bytes);
        if (!leh2_raw_write(aTHX_ context, bytes))
            return 0;
        if (state->closed)
            break;
        if (context->host->is_closed(aTHX_ context->host_context))
            break;
    }

    return 1;
}

static void *
leh2_raw_consumer_create(pTHX_
    const les_consumer_host_api_v1_t *host,
    void *host_context,
    SV *stream)
{
    leh2_raw_context_t *context;
    HV *stream_hv;
    SV **slot;

    if (!host || host->abi_version != LES_CONSUMER_ABI_VERSION)
        croak("native HTTP/2 raw consumer ABI mismatch");
    if (host->struct_size < LES_CONSUMER_HOST_V1_RETAIN_REQUIRED_SIZE
        || !host->retain || !host->release)
        croak("native HTTP/2 raw consumer requires host lifetime retention");
    if (!SvROK(stream) || SvTYPE(SvRV(stream)) != SVt_PVHV)
        croak("native HTTP/2 raw consumer requires hash-based Stream object");

    stream_hv = (HV *)SvRV(stream);
    slot = hv_fetch(
        stream_hv,
        "_http2_native_session",
        (I32)(sizeof("_http2_native_session") - 1),
        0
    );
    if (!slot || !SvOK(*slot))
        croak("native HTTP/2 Stream has no attached session");

    Newxz(context, 1, leh2_raw_context_t);
    context->host = host;
    context->host_context = host_context;
    context->stream = SvREFCNT_inc(stream);
    context->session_obj = SvREFCNT_inc(*slot);
    context->state = leh2_state_from_sv(context->session_obj);
    return context;
}

static int
leh2_raw_consumer_input(pTHX_
    void *opaque,
    const char *data,
    size_t length,
    size_t *consumed)
{
    leh2_raw_context_t *context = (leh2_raw_context_t *)opaque;
    leh2_state_t *state;
    ssize_t rv;
    int result = LES_CONSUMER_CONTINUE;

    if (!context || !consumed)
        return LES_CONSUMER_ERROR;

    state = context->state;
    *consumed = 0;

    if (!context->host->retain(aTHX_ context->host_context))
        return LES_CONSUMER_CLOSE;

    if (state->closed) {
        result = LES_CONSUMER_CLOSE;
        goto done;
    }

    ++state->in_nghttp2;
    rv = nghttp2_session_mem_recv(
        state->session,
        (const uint8_t *)data,
        length
    );
    leh2_leave_nghttp2(state);

    if (rv < 0 || state->callback_error) {
        result = LES_CONSUMER_ERROR;
        goto done;
    }

    *consumed = (size_t)rv;

    if (!state->closed && !leh2_raw_flush(aTHX_ context)) {
        result = LES_CONSUMER_ERROR;
        goto done;
    }

    if (context->host->is_closed(aTHX_ context->host_context))
        result = LES_CONSUMER_CLOSE;

done:
    context->host->release(aTHX_ context->host_context);
    return result;
}

static void
leh2_raw_consumer_event(pTHX_
    void *opaque,
    uint32_t event,
    int error,
    const char *message)
{
    PERL_UNUSED_ARG(opaque);
    PERL_UNUSED_ARG(event);
    PERL_UNUSED_ARG(error);
    PERL_UNUSED_ARG(message);
    PERL_UNUSED_CONTEXT;
}

static void
leh2_raw_consumer_destroy(pTHX_ void *opaque)
{
    leh2_raw_context_t *context = (leh2_raw_context_t *)opaque;

    PERL_UNUSED_CONTEXT;

    if (!context)
        return;

    if (context->write_cv)
        SvREFCNT_dec((SV *)context->write_cv);
    if (context->session_obj)
        SvREFCNT_dec(context->session_obj);
    if (context->stream)
        SvREFCNT_dec(context->stream);

    Safefree(context);
}

static const les_consumer_ops_v1_t leh2_raw_consumer_ops = {
    LES_CONSUMER_ABI_VERSION,
    sizeof(les_consumer_ops_v1_t),
    "Linux::Event::HTTP::_HTTP2 native raw input",
    LES_CONSUMER_F_RAW_INPUT,
    leh2_raw_consumer_create,
    NULL,
    leh2_raw_consumer_event,
    leh2_raw_consumer_destroy,
    NULL,
    leh2_raw_consumer_input
};

MODULE = Linux::Event::HTTP::_HTTP2::Native  PACKAGE = Linux::Event::HTTP::_HTTP2::Native
PROTOTYPES: DISABLE

UV
_raw_consumer_operations_address()
CODE:
    RETVAL = PTR2UV(&leh2_raw_consumer_ops);
OUTPUT:
    RETVAL

SV *
_new(class, is_server, callbacks)
    const char *class
    int is_server
    SV *callbacks
PREINIT:
    leh2_state_t *state;
    nghttp2_session_callbacks *cbs = NULL;
    int rv;
    SV *inner;
CODE:
    if (!SvROK(callbacks) || SvTYPE(SvRV(callbacks)) != SVt_PVHV)
        croak("_new(): callbacks must be a hash reference");

    Newxz(state, 1, leh2_state_t);
    state->callbacks = (HV *)SvREFCNT_inc(SvRV(callbacks));

    rv = nghttp2_session_callbacks_new(&cbs);
    if (rv != 0) {
        SvREFCNT_dec((SV *)state->callbacks);
        Safefree(state);
        croak("nghttp2_session_callbacks_new: %s", nghttp2_strerror(rv));
    }

    nghttp2_session_callbacks_set_on_begin_headers_callback(
        cbs, leh2_on_begin_headers);
    nghttp2_session_callbacks_set_on_header_callback(cbs, leh2_on_header);
    nghttp2_session_callbacks_set_on_data_chunk_recv_callback(
        cbs, leh2_on_data_chunk_recv);
    nghttp2_session_callbacks_set_on_frame_recv_callback(
        cbs, leh2_on_frame_recv);
    nghttp2_session_callbacks_set_on_stream_close_callback(
        cbs, leh2_on_stream_close);

    if (is_server)
        rv = nghttp2_session_server_new(&state->session, cbs, state);
    else
        rv = nghttp2_session_client_new(&state->session, cbs, state);

    nghttp2_session_callbacks_del(cbs);

    if (rv != 0) {
        SvREFCNT_dec((SV *)state->callbacks);
        Safefree(state);
        croak("nghttp2 session creation failed: %s", nghttp2_strerror(rv));
    }

    inner = newSViv(PTR2IV(state));
    RETVAL = newRV_noinc(inner);
    sv_bless(RETVAL, gv_stashpv(class, GV_ADD));
OUTPUT:
    RETVAL

SV *
library_version(class)
    SV *class
PREINIT:
    const nghttp2_info *info;
CODE:
    (void)class;
    info = nghttp2_version(0);
    RETVAL = newSVpv(info && info->version_str ? info->version_str : "", 0);
OUTPUT:
    RETVAL

int
available(class)
    SV *class
CODE:
    (void)class;
    RETVAL = 1;
OUTPUT:
    RETVAL

void
start(self, max_concurrent_streams = 100)
    SV *self
    UV max_concurrent_streams
PREINIT:
    leh2_state_t *state;
    nghttp2_settings_entry iv[1];
    int rv;
CODE:
    state = leh2_state_from_sv(self);
    if (state->closed)
        croak("start(): session is closed");
    if (max_concurrent_streams > UINT32_MAX)
        croak("start(): max_concurrent_streams is too large");

    iv[0].settings_id = NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS;
    iv[0].value = (uint32_t)max_concurrent_streams;
    rv = nghttp2_submit_settings(
        state->session, NGHTTP2_FLAG_NONE, iv, 1);
    if (rv != 0)
        croak("nghttp2_submit_settings: %s", nghttp2_strerror(rv));

IV
submit_request(self, headers)
    SV *self
    SV *headers
PREINIT:
    leh2_state_t *state;
    nghttp2_nv *nva;
    size_t nvlen;
    int32_t stream_id;
CODE:
    state = leh2_state_from_sv(self);
    if (state->closed)
        croak("submit_request(): session is closed");

    nva = leh2_make_nv(aTHX_ headers, &nvlen);
    stream_id = nghttp2_submit_request(
        state->session, NULL, nva, nvlen, NULL, NULL);
    if (nva)
        Safefree(nva);
    if (stream_id < 0)
        croak("nghttp2_submit_request: %s", nghttp2_strerror(stream_id));
    RETVAL = stream_id;
OUTPUT:
    RETVAL

void
submit_response(self, stream_id, headers)
    SV *self
    IV stream_id
    SV *headers
PREINIT:
    leh2_state_t *state;
    nghttp2_nv *nva;
    size_t nvlen;
    int rv;
CODE:
    state = leh2_state_from_sv(self);
    if (state->closed)
        croak("submit_response(): session is closed");

    nva = leh2_make_nv(aTHX_ headers, &nvlen);
    rv = nghttp2_submit_response(
        state->session, (int32_t)stream_id, nva, nvlen, NULL);
    if (nva)
        Safefree(nva);
    if (rv != 0)
        croak("nghttp2_submit_response: %s", nghttp2_strerror(rv));

UV
mem_recv(self, bytes)
    SV *self
    SV *bytes
PREINIT:
    leh2_state_t *state;
    STRLEN len;
    const uint8_t *data;
    ssize_t rv;
CODE:
    state = leh2_state_from_sv(self);
    if (state->closed)
        croak("mem_recv(): session is closed");

    data = (const uint8_t *)SvPVbyte(bytes, len);
    ++state->in_nghttp2;
    rv = nghttp2_session_mem_recv(state->session, data, (size_t)len);
    leh2_leave_nghttp2(state);
    leh2_throw_if_callback_failed(aTHX_ state);

    if (rv < 0)
        croak("nghttp2_session_mem_recv: %s", nghttp2_strerror((int)rv));
    RETVAL = (UV)rv;
OUTPUT:
    RETVAL

SV *
mem_send(self)
    SV *self
PREINIT:
    leh2_state_t *state;
    const uint8_t *data = NULL;
    ssize_t rv;
CODE:
    state = leh2_state_from_sv(self);
    if (state->closed)
        croak("mem_send(): session is closed");

    ++state->in_nghttp2;
    rv = nghttp2_session_mem_send(state->session, &data);
    if (rv >= 0 && rv > 0)
        RETVAL = newSVpvn((const char *)data, (STRLEN)rv);
    else
        RETVAL = newSVpvn("", 0);
    leh2_leave_nghttp2(state);
    leh2_throw_if_callback_failed(aTHX_ state);

    if (rv < 0) {
        SvREFCNT_dec(RETVAL);
        croak("nghttp2_session_mem_send: %s", nghttp2_strerror((int)rv));
    }
OUTPUT:
    RETVAL

int
want_read(self)
    SV *self
PREINIT:
    leh2_state_t *state;
CODE:
    state = leh2_state_from_sv(self);
    RETVAL = state->closed ? 0 : nghttp2_session_want_read(state->session);
OUTPUT:
    RETVAL

int
want_write(self)
    SV *self
PREINIT:
    leh2_state_t *state;
CODE:
    state = leh2_state_from_sv(self);
    RETVAL = state->closed ? 0 : nghttp2_session_want_write(state->session);
OUTPUT:
    RETVAL

IV
last_proc_stream_id(self)
    SV *self
PREINIT:
    leh2_state_t *state;
CODE:
    state = leh2_state_from_sv(self);
    if (state->closed)
        croak("last_proc_stream_id(): session is closed");
    RETVAL = nghttp2_session_get_last_proc_stream_id(state->session);
OUTPUT:
    RETVAL

void
close(self)
    SV *self
PREINIT:
    leh2_state_t *state;
CODE:
    state = leh2_state_from_sv(self);
    if (!state->closed) {
        if (state->in_nghttp2)
            state->close_pending = 1;
        else
            leh2_finish_close(state);
    }

int
is_closed(self)
    SV *self
PREINIT:
    leh2_state_t *state;
CODE:
    state = leh2_state_from_sv(self);
    RETVAL = state->closed ? 1 : 0;
OUTPUT:
    RETVAL

void
DESTROY(self)
    SV *self
PREINIT:
    SV *inner;
    leh2_state_t *state;
CODE:
    if (!SvROK(self))
        XSRETURN_EMPTY;

    inner = SvRV(self);
    state = INT2PTR(leh2_state_t *, SvIV(inner));
    if (!state)
        XSRETURN_EMPTY;

    if (!state->closed)
        leh2_finish_close(state);

    if (state->callback_error)
        SvREFCNT_dec(state->callback_error);
    if (state->callbacks)
        SvREFCNT_dec((SV *)state->callbacks);

    Safefree(state);
    sv_setiv(inner, 0);
