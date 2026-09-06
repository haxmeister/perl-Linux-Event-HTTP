#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

typedef struct {
    size_t name_offset;
    size_t name_length;
    size_t value_offset;
    size_t value_length;
} le_http_header_slice;

typedef struct {
    int consumed;
    int minor_version;
    int body_mode;
    int keep_alive;
    int has_content_length;
    UV content_length;
    size_t method_offset;
    size_t method_length;
    size_t target_offset;
    size_t target_length;
    size_t num_headers;
    le_http_header_slice *headers;
    char *bytes;
} le_http_request_state;

static le_http_request_state *
request_state_from_object(pTHX_ SV *self)
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

static int
request_method_is_head(le_http_request_state *state)
{
    return state->method_length == 4 &&
        memEQ(state->bytes + state->method_offset, "HEAD", 4);
}

MODULE = Linux::Event::Net::HTTP::_Native::Response1    PACKAGE = Linux::Event::Net::HTTP::_Native::Response1
PROTOTYPES: DISABLE

SV *
build_default_final(CLASS, request, body)
    const char *CLASS
    SV *request
    SV *body
  PREINIT:
    le_http_request_state *state;
    SV *body_copy;
    STRLEN body_len;
    const char *body_bytes;
    SV *wire;
  CODE:
    (void)CLASS;
    state = request_state_from_object(aTHX_ request);

    /*
     * This is intentionally a very narrow experimental fast path.  Anything
     * outside the common persistent HTTP/1.1 scalar-response case falls back
     * to the existing Perl response state machine.
     */
    if (state->minor_version != 1 || !state->keep_alive ||
        request_method_is_head(state))
        XSRETURN_UNDEF;

    if (SvROK(body))
        croak("end(): body must be a scalar byte string");

    body_copy = SvOK(body) ? newSVsv(body) : newSVpvn("", 0);
    if (SvUTF8(body_copy) && !sv_utf8_downgrade(body_copy, TRUE)) {
        SvREFCNT_dec(body_copy);
        croak("end(): body contains wide characters; encode it to bytes first");
    }

    body_bytes = SvPVbyte(body_copy, body_len);
    wire = newSVpvf(
        "HTTP/1.1 200 OK\r\nContent-Length: %" UVuf "\r\n\r\n",
        (UV)body_len
    );
    sv_catpvn(wire, body_bytes, body_len);
    SvREFCNT_dec(body_copy);

    RETVAL = wire;
  OUTPUT:
    RETVAL
