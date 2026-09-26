#!/usr/bin/env python3
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

def replace_once(old, new):
    global text
    if old not in text:
        raise SystemExit("expected source fragment not found:\n" + old[:160])
    text = text.replace(old, new, 1)

replace_once(
"""    int pending_free_count;
    int pending_free_cap;
} nghttp2_perl_session;
""",
"""    int pending_free_count;
    int pending_free_cap;
    int is_server;
    int32_t last_peer_stream_id;
    int32_t rejected_stream_id;
} nghttp2_perl_session;
""",
)

replace_once(
"""static ssize_t perl_send_callback(nghttp2_session *session,
                                  const uint8_t *data, size_t length,
                                  int flags, void *user_data);
static int perl_on_begin_headers_callback(nghttp2_session *session,
""",
"""static ssize_t perl_send_callback(nghttp2_session *session,
                                  const uint8_t *data, size_t length,
                                  int flags, void *user_data);
static int perl_on_begin_frame_callback(nghttp2_session *session,
                                        const nghttp2_frame_hd *hd,
                                        void *user_data);
static int perl_on_begin_headers_callback(nghttp2_session *session,
""",
)

replace_once(
"""    nghttp2_session_callbacks_set_send_callback(callbacks, perl_send_callback);
    nghttp2_session_callbacks_set_on_begin_headers_callback(callbacks, perl_on_begin_headers_callback);
""",
"""    nghttp2_session_callbacks_set_send_callback(callbacks, perl_send_callback);
    nghttp2_session_callbacks_set_on_begin_frame_callback(callbacks, perl_on_begin_frame_callback);
    nghttp2_session_callbacks_set_on_begin_headers_callback(callbacks, perl_on_begin_headers_callback);
""",
)

replace_once(
"""/* Begin headers callback */
static int perl_on_begin_headers_callback(nghttp2_session *session,
""",
"""/* Enforce RFC 9113 section 5.1.1 before nghttp2 opens a new peer stream. */
static int perl_on_begin_frame_callback(nghttp2_session *session,
                                        const nghttp2_frame_hd *hd,
                                        void *user_data) {
    nghttp2_perl_session *ps = (nghttp2_perl_session *)user_data;
    int rv;

    if (!ps->is_server || hd->type != NGHTTP2_HEADERS || hd->stream_id <= 0) {
        return 0;
    }

    /* A live stream can legally receive later HEADERS, such as trailers. */
    if (nghttp2_session_get_stream_remote_close(session, hd->stream_id) != -1) {
        return 0;
    }

    if (ps->last_peer_stream_id &&
        hd->stream_id <= ps->last_peer_stream_id) {
        ps->rejected_stream_id = hd->stream_id;
        rv = nghttp2_session_terminate_session(session, NGHTTP2_PROTOCOL_ERROR);
        return rv == 0 ? 0 : NGHTTP2_ERR_CALLBACK_FAILURE;
    }

    ps->last_peer_stream_id = hd->stream_id;
    return 0;
}

/* Begin headers callback */
static int perl_on_begin_headers_callback(nghttp2_session *session,
""",
)

replace_once(
"""    AV *args;
    int ret;

    if (!ps->cb_on_begin_headers || !SvOK(ps->cb_on_begin_headers)) {
""",
"""    AV *args;
    int ret;

    if (ps->rejected_stream_id &&
        frame->hd.stream_id == ps->rejected_stream_id) {
        return 0;
    }

    if (!ps->cb_on_begin_headers || !SvOK(ps->cb_on_begin_headers)) {
""",
)

replace_once(
"""    AV *args;
    int ret;

    if (!ps->cb_on_header || !SvOK(ps->cb_on_header)) {
""",
"""    AV *args;
    int ret;

    if (ps->rejected_stream_id &&
        frame->hd.stream_id == ps->rejected_stream_id) {
        return 0;
    }

    if (!ps->cb_on_header || !SvOK(ps->cb_on_header)) {
""",
)

replace_once(
"""    AV *args;
    int ret;

    if (!ps->cb_on_frame_recv || !SvOK(ps->cb_on_frame_recv)) {
""",
"""    AV *args;
    int ret;

    if (ps->rejected_stream_id &&
        frame->hd.stream_id == ps->rejected_stream_id) {
        return 0;
    }

    if (!ps->cb_on_frame_recv || !SvOK(ps->cb_on_frame_recv)) {
""",
)

replace_once(
"""    AV *args;
    int ret;

    if (!ps->cb_on_data_chunk_recv || !SvOK(ps->cb_on_data_chunk_recv)) {
""",
"""    AV *args;
    int ret;

    if (ps->rejected_stream_id && stream_id == ps->rejected_stream_id) {
        return 0;
    }

    if (!ps->cb_on_data_chunk_recv || !SvOK(ps->cb_on_data_chunk_recv)) {
""",
)

replace_once(
"""    /* Clean up any data provider for this stream */
    remove_data_provider(ps, stream_id);

    if (!ps->cb_on_stream_close || !SvOK(ps->cb_on_stream_close)) {
""",
"""    /* Clean up any data provider for this stream */
    remove_data_provider(ps, stream_id);

    if (ps->rejected_stream_id && stream_id == ps->rejected_stream_id) {
        return 0;
    }

    if (!ps->cb_on_stream_close || !SvOK(ps->cb_on_stream_close)) {
""",
)

replace_once(
"""        /* Allocate our wrapper structure */
        Newxz(ps, 1, nghttp2_perl_session);

        /* Initialize send buffer */
""",
"""        /* Allocate our wrapper structure */
        Newxz(ps, 1, nghttp2_perl_session);
        ps->is_server = 1;

        /* Initialize send buffer */
""",
)

path.write_text(text)
