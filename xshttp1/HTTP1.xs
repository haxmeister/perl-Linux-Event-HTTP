#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "../vendor/picohttpparser/picohttpparser.c"

#define LE_HTTP1_MAX_HEADERS 256

static void
validate_limits(STRLEN buffer_len, UV last_len, UV max_headers)
{
    if (last_len > (UV)buffer_len)
        croak("last_len exceeds buffer length");
    if (max_headers == 0 || max_headers > LE_HTTP1_MAX_HEADERS)
        croak("max_headers must be between 1 and %d", LE_HTTP1_MAX_HEADERS);
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
    RETVAL = phr_parse_request(
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
    consumed = phr_parse_request(
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
        if (headers[i].name == NULL)
            av_push(row, newSViv(-1));
        else
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
