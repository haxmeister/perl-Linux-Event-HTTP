#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <nghttp2/nghttp2.h>

#include <stdint.h>
#include <string.h>

typedef struct leh2_state_s {
    nghttp2_session *session;
    HV *callbacks;
    SV *callback_error;
    unsigned int in_nghttp2;
    unsigned int close_pending;
    unsigned int closed;
} leh2_state_t;

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
    dTHX;

    (void)session;
    args[0] = newSViv(stream_id);
    args[1] = newSVuv(error_code);
    return leh2_call(aTHX_ state, "on_stream_close", 2, args);
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

MODULE = Linux::Event::HTTP::_HTTP2::Native  PACKAGE = Linux::Event::HTTP::_HTTP2::Native
PROTOTYPES: DISABLE

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
