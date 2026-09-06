#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "../vendor/picohttpparser/picohttpparser.c"

#define LE_HTTP1_MAX_HEADERS 256

typedef struct {
    size_t name_offset;
    size_t name_length;
    size_t value_offset;
    size_t value_length;
} le_http_header_slice;

typedef struct {
    SV *buffer;
    int consumed;
    int minor_version;
    size_t method_offset;
    size_t method_length;
    size_t target_offset;
    size_t target_length;
    size_t num_headers;
    le_http_header_slice *headers;
} le_http_request_state;

static void
validate_limits(STRLEN buffer_len, UV last_len, UV max_headers)
{
    if (last_len > (UV)buffer_len)
        croak("last_len exceeds buffer length");
    if (max_headers == 0 || max_headers > LE_HTTP1_MAX_HEADERS)
        croak("max_headers must be between 1 and %d", LE_HTTP1_MAX_HEADERS);
}

static int
parse_request_strict(
    const char *buf,
    size_t buffer_len,
    const char **method,
    size_t *method_len,
    const char **path,
    size_t *path_len,
    int *minor_version,
    struct phr_header *headers,
    size_t *num_headers,
    size_t last_len
)
{
    int consumed = phr_parse_request(
        buf,
        buffer_len,
        method,
        method_len,
        path,
        path_len,
        minor_version,
        headers,
        num_headers,
        last_len
    );
    size_t i;

    if (consumed <= 0)
        return consumed;

    /* RFC 9112 requires recipients to reject or replace obs-fold.  The
     * Linux::Event HTTP layer chooses rejection rather than silently
     * normalizing ambiguous input.  pico marks continuation lines by
     * returning a header entry with name == NULL. */
    for (i = 0; i < *num_headers; ++i) {
        if (headers[i].name == NULL)
            return -1;
    }

    return consumed;
}

static int
ascii_equal_ci(const char *left, size_t left_len, const char *right, size_t right_len)
{
    size_t i;

    if (left_len != right_len)
        return 0;

    for (i = 0; i < left_len; ++i) {
        unsigned char a = (unsigned char)left[i];
        unsigned char b = (unsigned char)right[i];

        if (a >= 'A' && a <= 'Z')
            a = (unsigned char)(a + ('a' - 'A'));
        if (b >= 'A' && b <= 'Z')
            b = (unsigned char)(b + ('a' - 'A'));
        if (a != b)
            return 0;
    }

    return 1;
}

static le_http_request_state *
request_state_from_object(SV *self)
{
    SV *inner;
    le_http_request_state *state;

    if (!SvROK(self) || !sv_derived_from(self, "Linux::Event::Net::HTTP::Request"))
        croak("not a Linux::Event::Net::HTTP::Request object");

    inner = SvRV(self);
    state = INT2PTR(le_http_request_state *, SvIV(inner));
    if (state == NULL)
        croak("HTTP request state has already been released");

    return state;
}

static SV *
request_slice_sv(le_http_request_state *state, size_t offset, size_t length)
{
    STRLEN buffer_len;
    const char *buf = SvPVbyte(state->buffer, buffer_len);

    if (offset > (size_t)buffer_len || length > (size_t)buffer_len - offset)
        croak("corrupt HTTP request slice");

    return newSVpvn(buf + offset, length);
}

static SV *
new_request_object(
    SV *buffer,
    const char *buf,
    int consumed,
    int minor_version,
    const char *method,
    size_t method_len,
    const char *path,
    size_t path_len,
    const struct phr_header *headers,
    size_t num_headers
)
{
    le_http_request_state *state;
    SV *object;
    size_t i;

    (void)buffer;

    Newxz(state, 1, le_http_request_state);
    state->buffer = newSVpvn(buf, (STRLEN)consumed);
    state->consumed = consumed;
    state->minor_version = minor_version;
    state->method_offset = (size_t)(method - buf);
    state->method_length = method_len;
    state->target_offset = (size_t)(path - buf);
    state->target_length = path_len;
    state->num_headers = num_headers;

    if (num_headers != 0) {
        Newxz(state->headers, num_headers, le_http_header_slice);
        for (i = 0; i < num_headers; ++i) {
            state->headers[i].name_offset = (size_t)(headers[i].name - buf);
            state->headers[i].name_length = headers[i].name_len;
            state->headers[i].value_offset = (size_t)(headers[i].value - buf);
            state->headers[i].value_length = headers[i].value_len;
        }
    }

    object = newSV(0);
    sv_setref_pv(
        object,
        "Linux::Event::Net::HTTP::Request",
        (void *)state
    );

    return object;
}

MODULE = Linux::Event::Net::HTTP::_Parser::HTTP1    PACKAGE = Linux::Event::Net::HTTP::_Parser::HTTP1
PROTOTYPES: DISABLE

const char *
pico_version(CLASS)
    const char *CLASS
  CODE:
    (void)CLASS;
    RETVAL = PICOHTTPPARSER_VERSION;
  OUTPUT:
    RETVAL

int
probe_request(CLASS, buffer, last_len = 0, max_headers = 100)
    const char *CLASS
    SV *buffer
    UV last_len
    UV max_headers
  PREINIT:
    STRLEN buffer_len;
    const char *buf;
    const char *method;
    size_t method_len;
    const char *path;
    size_t path_len;
    int minor_version;
    struct phr_header headers[LE_HTTP1_MAX_HEADERS];
    size_t num_headers;
  CODE:
    (void)CLASS;
    buf = SvPVbyte(buffer, buffer_len);
    validate_limits(buffer_len, last_len, max_headers);
    num_headers = (size_t)max_headers;
    RETVAL = parse_request_strict(
        buf,
        (size_t)buffer_len,
        &method,
        &method_len,
        &path,
        &path_len,
        &minor_version,
        headers,
        &num_headers,
        (size_t)last_len
    );
  OUTPUT:
    RETVAL

SV *
parse_request(CLASS, buffer, last_len = 0, max_headers = 100)
    const char *CLASS
    SV *buffer
    UV last_len
    UV max_headers
  PREINIT:
    STRLEN buffer_len;
    const char *buf;
    const char *method;
    size_t method_len;
    const char *path;
    size_t path_len;
    int minor_version;
    struct phr_header headers[LE_HTTP1_MAX_HEADERS];
    size_t num_headers;
    int consumed;
  CODE:
    (void)CLASS;
    buf = SvPVbyte(buffer, buffer_len);
    validate_limits(buffer_len, last_len, max_headers);
    num_headers = (size_t)max_headers;
    consumed = parse_request_strict(
        buf,
        (size_t)buffer_len,
        &method,
        &method_len,
        &path,
        &path_len,
        &minor_version,
        headers,
        &num_headers,
        (size_t)last_len
    );

    if (consumed == -2)
        XSRETURN_UNDEF;
    if (consumed == -1)
        croak("malformed HTTP/1 request");

    RETVAL = new_request_object(
        buffer,
        buf,
        consumed,
        minor_version,
        method,
        method_len,
        path,
        path_len,
        headers,
        num_headers
    );
  OUTPUT:
    RETVAL

SV *
parse_request_offsets(CLASS, buffer, last_len = 0, max_headers = 100)
    const char *CLASS
    SV *buffer
    UV last_len
    UV max_headers
  PREINIT:
    STRLEN buffer_len;
    const char *buf;
    const char *method;
    size_t method_len;
    const char *path;
    size_t path_len;
    int minor_version;
    struct phr_header headers[LE_HTTP1_MAX_HEADERS];
    size_t num_headers;
    int consumed;
    size_t i;
    AV *result;
    AV *header_list;
    AV *row;
  CODE:
    (void)CLASS;
    buf = SvPVbyte(buffer, buffer_len);
    validate_limits(buffer_len, last_len, max_headers);
    num_headers = (size_t)max_headers;
    consumed = parse_request_strict(
        buf,
        (size_t)buffer_len,
        &method,
        &method_len,
        &path,
        &path_len,
        &minor_version,
        headers,
        &num_headers,
        (size_t)last_len
    );

    if (consumed == -2)
        XSRETURN_UNDEF;
    if (consumed == -1)
        croak("malformed HTTP/1 request");

    result = newAV();
    av_push(result, newSViv(consumed));
    av_push(result, newSViv(minor_version));
    av_push(result, newSVuv((UV)(method - buf)));
    av_push(result, newSVuv((UV)method_len));
    av_push(result, newSVuv((UV)(path - buf)));
    av_push(result, newSVuv((UV)path_len));

    header_list = newAV();
    for (i = 0; i < num_headers; ++i) {
        row = newAV();
        av_push(row, newSVuv((UV)(headers[i].name - buf)));
        av_push(row, newSVuv((UV)headers[i].name_len));
        av_push(row, newSVuv((UV)(headers[i].value - buf)));
        av_push(row, newSVuv((UV)headers[i].value_len));
        av_push(header_list, newRV_noinc((SV *)row));
    }
    av_push(result, newRV_noinc((SV *)header_list));

    RETVAL = newRV_noinc((SV *)result);
  OUTPUT:
    RETVAL

MODULE = Linux::Event::Net::HTTP::_Parser::HTTP1    PACKAGE = Linux::Event::Net::HTTP::Request

SV *
method(self)
    SV *self
  PREINIT:
    le_http_request_state *state;
  CODE:
    state = request_state_from_object(self);
    RETVAL = request_slice_sv(state, state->method_offset, state->method_length);
  OUTPUT:
    RETVAL

SV *
target(self)
    SV *self
  PREINIT:
    le_http_request_state *state;
  CODE:
    state = request_state_from_object(self);
    RETVAL = request_slice_sv(state, state->target_offset, state->target_length);
  OUTPUT:
    RETVAL

SV *
http_version(self)
    SV *self
  PREINIT:
    le_http_request_state *state;
  CODE:
    state = request_state_from_object(self);
    RETVAL = newSVpvf("1.%d", state->minor_version);
  OUTPUT:
    RETVAL

UV
header_count(self)
    SV *self
  PREINIT:
    le_http_request_state *state;
  CODE:
    state = request_state_from_object(self);
    RETVAL = (UV)state->num_headers;
  OUTPUT:
    RETVAL

SV *
header_name(self, index)
    SV *self
    UV index
  PREINIT:
    le_http_request_state *state;
    le_http_header_slice *header;
  CODE:
    state = request_state_from_object(self);
    if (index >= (UV)state->num_headers)
        croak("header index out of range");
    header = &state->headers[index];
    RETVAL = request_slice_sv(state, header->name_offset, header->name_length);
  OUTPUT:
    RETVAL

SV *
header_value(self, index)
    SV *self
    UV index
  PREINIT:
    le_http_request_state *state;
    le_http_header_slice *header;
  CODE:
    state = request_state_from_object(self);
    if (index >= (UV)state->num_headers)
        croak("header index out of range");
    header = &state->headers[index];
    RETVAL = request_slice_sv(state, header->value_offset, header->value_length);
  OUTPUT:
    RETVAL

SV *
header(self, name)
    SV *self
    SV *name
  PREINIT:
    le_http_request_state *state;
    STRLEN buffer_len;
    STRLEN name_len;
    const char *buf;
    const char *wanted;
    size_t i;
  CODE:
    state = request_state_from_object(self);
    buf = SvPVbyte(state->buffer, buffer_len);
    wanted = SvPVbyte(name, name_len);

    for (i = 0; i < state->num_headers; ++i) {
        le_http_header_slice *header = &state->headers[i];
        if (ascii_equal_ci(
                buf + header->name_offset,
                header->name_length,
                wanted,
                (size_t)name_len
            )) {
            RETVAL = request_slice_sv(state, header->value_offset, header->value_length);
            goto header_found;
        }
    }

    XSRETURN_UNDEF;

  header_found:
  OUTPUT:
    RETVAL

void
header_values(self, name)
    SV *self
    SV *name
  PREINIT:
    le_http_request_state *state;
    STRLEN buffer_len;
    STRLEN name_len;
    const char *buf;
    const char *wanted;
    size_t i;
  PPCODE:
    state = request_state_from_object(self);
    buf = SvPVbyte(state->buffer, buffer_len);
    wanted = SvPVbyte(name, name_len);

    for (i = 0; i < state->num_headers; ++i) {
        le_http_header_slice *header = &state->headers[i];
        if (ascii_equal_ci(
                buf + header->name_offset,
                header->name_length,
                wanted,
                (size_t)name_len
            )) {
            XPUSHs(sv_2mortal(request_slice_sv(
                state,
                header->value_offset,
                header->value_length
            )));
        }
    }

IV
_consumed(self)
    SV *self
  PREINIT:
    le_http_request_state *state;
  CODE:
    state = request_state_from_object(self);
    RETVAL = (IV)state->consumed;
  OUTPUT:
    RETVAL

void
DESTROY(self)
    SV *self
  PREINIT:
    SV *inner;
    le_http_request_state *state;
  CODE:
    if (!SvROK(self))
        XSRETURN_EMPTY;

    inner = SvRV(self);
    state = INT2PTR(le_http_request_state *, SvIV(inner));
    if (state == NULL)
        XSRETURN_EMPTY;

    if (state->buffer != NULL)
        SvREFCNT_dec(state->buffer);
    if (state->headers != NULL)
        Safefree(state->headers);
    Safefree(state);
    sv_setiv(inner, 0);
