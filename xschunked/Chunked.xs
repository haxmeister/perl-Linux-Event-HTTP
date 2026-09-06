#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "../vendor/picohttpparser/picohttpparser.c"

static struct phr_chunked_decoder *
decoder_from_object(SV *self)
{
    SV *inner;
    struct phr_chunked_decoder *decoder;

    if (!SvROK(self) ||
        !sv_derived_from(
            self,
            "Linux::Event::Net::HTTP::_Parser::HTTP1::Chunked"
        ))
        croak("not an HTTP/1 chunked decoder object");

    inner = SvRV(self);
    decoder = INT2PTR(struct phr_chunked_decoder *, SvIV(inner));
    if (decoder == NULL)
        croak("HTTP/1 chunked decoder state has already been released");

    return decoder;
}

MODULE = Linux::Event::Net::HTTP::_Parser::HTTP1::Chunked    PACKAGE = Linux::Event::Net::HTTP::_Parser::HTTP1::Chunked
PROTOTYPES: DISABLE

SV *
new(CLASS)
    const char *CLASS
  PREINIT:
    struct phr_chunked_decoder *decoder;
  CODE:
    Newxz(decoder, 1, struct phr_chunked_decoder);
    decoder->consume_trailer = 1;
    RETVAL = newSV(0);
    sv_setref_pv(RETVAL, CLASS, (void *)decoder);
  OUTPUT:
    RETVAL

void
feed(self, buffer, emit = 1)
    SV *self
    SV *buffer
    int emit
  PREINIT:
    struct phr_chunked_decoder *decoder;
    STRLEN buffer_len;
    char *buf;
    size_t decoded_len;
    ssize_t result;
    size_t leftover;
    SV *decoded = NULL;
  PPCODE:
    decoder = decoder_from_object(self);

    if (SvREADONLY(buffer))
        croak("chunked decoder input buffer must be writable");

    sv_force_normal(buffer);
    buf = SvPVbyte_force(buffer, buffer_len);
    decoded_len = (size_t)buffer_len;

    result = phr_decode_chunked(decoder, buf, &decoded_len);
    if (result == -1)
        croak("malformed HTTP/1 chunked request body");

    if (emit && decoded_len != 0)
        decoded = newSVpvn(buf, decoded_len);

    if (result >= 0) {
        leftover = (size_t)result;
        if (leftover != 0)
            memmove(buf, buf + decoded_len, leftover);
        SvCUR_set(buffer, (STRLEN)leftover);
        buf[leftover] = '\0';
    } else {
        SvCUR_set(buffer, 0);
        buf[0] = '\0';
    }
    SvUTF8_off(buffer);

    EXTEND(SP, 2);
    PUSHs(sv_2mortal(newSViv(result >= 0 ? 1 : 0)));
    if (decoded != NULL)
        PUSHs(sv_2mortal(decoded));
    else
        PUSHs(&PL_sv_undef);

void
DESTROY(self)
    SV *self
  PREINIT:
    SV *inner;
    struct phr_chunked_decoder *decoder;
  CODE:
    if (!SvROK(self))
        XSRETURN_EMPTY;

    inner = SvRV(self);
    decoder = INT2PTR(struct phr_chunked_decoder *, SvIV(inner));
    if (decoder == NULL)
        XSRETURN_EMPTY;

    Safefree(decoder);
    sv_setiv(inner, 0);
