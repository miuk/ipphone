#include "PJSIPBridge.h"

#include <pjlib-util.h>
#include <pj/rand.h>
#include <pj/array.h>
#include <pjnath.h>
#include <pjmedia.h>
#include <pjmedia/g711.h>
#include <pjmedia-codec/opus.h>
#include <pjmedia/sound_port.h>
#include <pjmedia/tonegen.h>
#include <pjmedia/transport_udp.h>
#include <pjsip.h>
#include <pjsip/sip_transport_tcp.h>
#include <pjsip/sip_transport_tls.h>
#include <pjsip_ua.h>
#include <CoreAudio/CoreAudio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct DTMFInjectPort {
    pjmedia_port base;
    pjmedia_port *stream_port;
    pjmedia_port *tone_generator;
    pjmedia_port *feedback_generator;
} DTMFInjectPort;

#define IP_PJSIP_LOG_CAPACITY 32
#define IP_PJSIP_LOG_LENGTH 256

struct IPPJSIPEndpoint {
    bool pj_initialized;
    bool pool_initialized;
    bool running;
    pj_caching_pool caching_pool;
    pjsip_endpoint *sip_endpoint;
    pjsip_transport *transport;
    pjsip_tpfactory *transport_factory;
    IPPJSIPTransport transport_kind;
    bool has_selected_local_address;
    pjsip_regc *registration_client;
    pjsip_inv_session *invite_session;
    pjsip_module app_module;
    pjsip_module log_module;
    pj_pool_t *call_pool;
    pj_pool_t *media_pool;
    pjmedia_endpt *media_endpoint;
    pjmedia_event_mgr *media_event_manager;
    pjmedia_transport *media_transport;
    bool media_transport_started;
    pjmedia_transport_op media_transport_ops;
    pj_status_t (*original_send_rtp)(pjmedia_transport *, const void *, pj_size_t);
    int tx_event_payload;
    unsigned audio_rtp_clock;
    unsigned tx_event_clock;
    bool event_timestamp_initialized;
    uint32_t event_source_timestamp;
    uint32_t event_wire_timestamp;
    unsigned event_timestamp_remainder;
    uint16_t event_last_duration;
    uint32_t event_extended_duration;
    pjmedia_stream *media_stream;
    pjmedia_snd_port *sound_port;
    DTMFInjectPort *dtmf_inject_port;
    pjmedia_port *tone_generator;
    uint16_t bound_port;
    uint16_t rtp_port;
    int audio_input_device;
    int audio_output_device;
    IPPJSIPRegistrationState registration_state;
    int registration_status_code;
    uint32_t registration_expiration;
    char registration_message[256];
    IPPJSIPCallState call_state;
    int call_status_code;
    char call_message[256];
    char remote_uri[PJSIP_MAX_URL_SIZE];
    bool local_termination;
    bool audio_initialized;
    bool g711_initialized;
    bool opus_initialized;
    bool offer_opus, offer_pcmu, prefer_opus, accept_opus, accept_pcmu;
    char media_codec[64];
    bool muted;
    bool telephone_event_available;
    IPPJSIPMediaState media_state;
    char media_message[256];
    char sip_logs[IP_PJSIP_LOG_CAPACITY][IP_PJSIP_LOG_LENGTH];
    unsigned sip_log_head;
    unsigned sip_log_count;
};

static IPPJSIPEndpoint *active_endpoint = NULL;
static pjsip_inv_callback invite_callbacks;

static void push_sip_log(IPPJSIPEndpoint *endpoint, const char *direction, pjsip_msg *message) {
    if (endpoint == NULL || message == NULL) {
        return;
    }
    unsigned index = (endpoint->sip_log_head + endpoint->sip_log_count) % IP_PJSIP_LOG_CAPACITY;
    if (endpoint->sip_log_count == IP_PJSIP_LOG_CAPACITY) {
        endpoint->sip_log_head = (endpoint->sip_log_head + 1) % IP_PJSIP_LOG_CAPACITY;
        index = (endpoint->sip_log_head + endpoint->sip_log_count - 1) % IP_PJSIP_LOG_CAPACITY;
    } else {
        endpoint->sip_log_count++;
    }
    pjsip_cseq_hdr *cseq = PJSIP_MSG_CSEQ_HDR(message);
    unsigned cseq_number = cseq == NULL ? 0 : (unsigned)cseq->cseq;
    if (message->type == PJSIP_REQUEST_MSG) {
        snprintf(
            endpoint->sip_logs[index],
            IP_PJSIP_LOG_LENGTH,
            "%s request %.*s (CSeq %u)",
            direction,
            (int)message->line.req.method.name.slen,
            message->line.req.method.name.ptr,
            cseq_number
        );
    } else {
        snprintf(
            endpoint->sip_logs[index],
            IP_PJSIP_LOG_LENGTH,
            "%s response %d %.*s (CSeq %u %.*s)",
            direction,
            message->line.status.code,
            (int)message->line.status.reason.slen,
            message->line.status.reason.ptr,
            cseq_number,
            cseq == NULL ? 0 : (int)cseq->method.name.slen,
            cseq == NULL ? "" : cseq->method.name.ptr
        );
    }
}

static pj_bool_t log_rx_request(pjsip_rx_data *rdata) {
    push_sip_log(active_endpoint, "RX", rdata->msg_info.msg);
    return PJ_FALSE;
}

static pj_bool_t log_rx_response(pjsip_rx_data *rdata) {
    push_sip_log(active_endpoint, "RX", rdata->msg_info.msg);
    return PJ_FALSE;
}

static void enclose_from_to_uris(pjsip_tx_data *tdata) {
    pj_bool_t changed = PJ_FALSE;
    for (pjsip_hdr *header = tdata->msg->hdr.next;
         header != &tdata->msg->hdr;
         header = header->next) {
        if (header->type != PJSIP_H_FROM && header->type != PJSIP_H_TO) {
            continue;
        }
        pjsip_fromto_hdr *fromto = (pjsip_fromto_hdr *)header;
        // Existing name-addr objects already print angle brackets and retain
        // their display names. Wrap only bare URIs, leaving header tags intact.
        if (fromto->uri != NULL && pjsip_uri_get_uri(fromto->uri) == fromto->uri) {
            pjsip_name_addr *name_addr = pjsip_name_addr_create(tdata->pool);
            name_addr->uri = fromto->uri;
            fromto->uri = (pjsip_uri *)name_addr;
            changed = PJ_TRUE;
        }
    }
    if (changed) {
        pjsip_tx_data_invalidate_msg(tdata);
    }
}

static pj_status_t log_tx_request(pjsip_tx_data *tdata) {
    enclose_from_to_uris(tdata);
    push_sip_log(active_endpoint, "TX", tdata->msg);
    return PJ_SUCCESS;
}

static pj_status_t log_tx_response(pjsip_tx_data *tdata) {
    enclose_from_to_uris(tdata);
    push_sip_log(active_endpoint, "TX", tdata->msg);
    return PJ_SUCCESS;
}

static const pjsip_host_port *endpoint_local_name(const IPPJSIPEndpoint *endpoint) {
    if (endpoint->transport != NULL) {
        return &endpoint->transport->local_name;
    }
    if (endpoint->transport_factory != NULL) {
        return &endpoint->transport_factory->addr_name;
    }
    return NULL;
}

static const char *endpoint_transport_name(const IPPJSIPEndpoint *endpoint) {
    switch (endpoint->transport_kind) {
    case IP_PJSIP_TRANSPORT_TCP:
        return "tcp";
    case IP_PJSIP_TRANSPORT_TLS:
        return "tls";
    case IP_PJSIP_TRANSPORT_UDP:
    default:
        return "udp";
    }
}

static pjsip_tpselector endpoint_transport_selector(const IPPJSIPEndpoint *endpoint) {
    pjsip_tpselector selector;
    pj_bzero(&selector, sizeof(selector));
    if (endpoint->transport != NULL) {
        selector.type = PJSIP_TPSELECTOR_TRANSPORT;
        selector.u.transport = endpoint->transport;
    } else {
        selector.type = PJSIP_TPSELECTOR_LISTENER;
        selector.u.listener = endpoint->transport_factory;
    }
    return selector;
}

static bool build_local_contact(const IPPJSIPEndpoint *endpoint, const pj_str_t *user,
                                char *buffer, size_t capacity) {
    const pjsip_host_port *local = endpoint_local_name(endpoint);
    if (local == NULL) { return false; }
    const bool ipv6 = memchr(local->host.ptr, ':', (size_t)local->host.slen) != NULL;
    int length = snprintf(buffer, capacity,
        ipv6 ? "<sip:%.*s@[%.*s]:%d;transport=%s>" : "<sip:%.*s@%.*s:%d;transport=%s>",
        (int)user->slen, user->ptr, (int)local->host.slen, local->host.ptr,
        local->port, endpoint_transport_name(endpoint));
    return length > 0 && (size_t)length < capacity;
}

static pj_status_t dtmf_inject_put_frame(pjmedia_port *port, pjmedia_frame *frame) {
    DTMFInjectPort *injector = (DTMFInjectPort *)port;
    if (pjmedia_tonegen_is_busy(injector->tone_generator)) {
        pj_status_t status = pjmedia_port_get_frame(injector->tone_generator, frame);
        if (status != PJ_SUCCESS) {
            return status;
        }
    }
    return pjmedia_port_put_frame(injector->stream_port, frame);
}

static pj_status_t dtmf_inject_get_frame(pjmedia_port *port, pjmedia_frame *frame) {
    DTMFInjectPort *injector = (DTMFInjectPort *)port;
    pj_status_t status = pjmedia_port_get_frame(injector->stream_port, frame);
    if (status != PJ_SUCCESS || !pjmedia_tonegen_is_busy(injector->feedback_generator)) {
        return status;
    }

    // Use a separate generator: capture and playback consume frames independently.
    pj_int16_t samples[PJMEDIA_PIA_SPF(&port->info)];
    pjmedia_frame feedback = {0};
    feedback.buf = samples;
    feedback.size = sizeof(samples);
    status = pjmedia_port_get_frame(injector->feedback_generator, &feedback);
    if (status != PJ_SUCCESS || feedback.type != PJMEDIA_FRAME_TYPE_AUDIO) {
        return PJ_SUCCESS;
    }
    if (frame->type != PJMEDIA_FRAME_TYPE_AUDIO) {
        pj_memcpy(frame->buf, feedback.buf, feedback.size);
        frame->type = PJMEDIA_FRAME_TYPE_AUDIO;
        frame->size = feedback.size;
        return PJ_SUCCESS;
    }

    pj_int16_t *output = frame->buf;
    pj_size_t count = PJ_MIN(frame->size, feedback.size) / sizeof(pj_int16_t);
    for (pj_size_t i = 0; i < count; ++i) {
        int mixed = (int)output[i] + samples[i];
        output[i] = (pj_int16_t)PJ_MAX(-32768, PJ_MIN(32767, mixed));
    }
    return PJ_SUCCESS;
}

static pj_status_t create_dtmf_inject_port(
    IPPJSIPEndpoint *endpoint,
    pjmedia_port *stream_port
) {
    DTMFInjectPort *injector = PJ_POOL_ZALLOC_T(endpoint->call_pool, DTMFInjectPort);
    pj_str_t name = pj_str("dtmf-inject");
    unsigned rate = PJMEDIA_PIA_SRATE(&stream_port->info);
    unsigned channels = PJMEDIA_PIA_CCNT(&stream_port->info);
    unsigned samples = PJMEDIA_PIA_SPF(&stream_port->info);
    pj_status_t status = pjmedia_port_info_init(
        &injector->base.info,
        &name,
        PJMEDIA_SIG_CLASS_PORT('D', 'T', 'F'),
        rate,
        channels,
        16,
        samples
    );
    if (status != PJ_SUCCESS) {
        return status;
    }
    status = pjmedia_tonegen_create(
        endpoint->call_pool,
        rate,
        channels,
        samples,
        16,
        0,
        &injector->tone_generator
    );
    if (status != PJ_SUCCESS) {
        return status;
    }
    injector->stream_port = stream_port;
    injector->base.put_frame = &dtmf_inject_put_frame;
    injector->base.get_frame = &dtmf_inject_get_frame;
    endpoint->dtmf_inject_port = injector;
    endpoint->tone_generator = injector->tone_generator;
    return pjmedia_tonegen_create(
        endpoint->call_pool, rate, channels, samples, 16, 0, &injector->feedback_generator
    );
}

static void destroy_media(IPPJSIPEndpoint *endpoint) {
    if (endpoint->sound_port != NULL) {
        pjmedia_snd_port_disconnect(endpoint->sound_port);
        pjmedia_snd_port_destroy(endpoint->sound_port);
        endpoint->sound_port = NULL;
    }
    if (endpoint->tone_generator != NULL) {
        pjmedia_port_destroy(endpoint->tone_generator);
        endpoint->tone_generator = NULL;
    }
    if (endpoint->dtmf_inject_port != NULL
        && endpoint->dtmf_inject_port->feedback_generator != NULL) {
        pjmedia_port_destroy(endpoint->dtmf_inject_port->feedback_generator);
    }
    endpoint->dtmf_inject_port = NULL;
    if (endpoint->media_transport_started) {
        pjmedia_transport_media_stop(endpoint->media_transport);
        endpoint->media_transport_started = false;
    }
    if (endpoint->media_stream != NULL) {
        pjmedia_stream_destroy(endpoint->media_stream);
        endpoint->media_stream = NULL;
    }
    if (endpoint->media_transport != NULL) {
        pjmedia_transport_close(endpoint->media_transport);
        endpoint->media_transport = NULL;
    }
    if (endpoint->audio_initialized) {
        pjmedia_aud_subsys_shutdown();
        endpoint->audio_initialized = false;
    }
    endpoint->muted = false;
    endpoint->telephone_event_available = false;
    endpoint->media_state = IP_PJSIP_MEDIA_IDLE;
}

static void set_media_error(IPPJSIPEndpoint *endpoint, const char *operation, pj_status_t status) {
    char detail[PJ_ERR_MSG_SIZE];
    pj_strerror(status, detail, sizeof(detail));
    snprintf(
        endpoint->media_message,
        sizeof(endpoint->media_message),
        "%s failed (%d): %s",
        operation,
        status,
        detail
    );
    endpoint->media_state = IP_PJSIP_MEDIA_FAILED;
}

static bool default_audio_device(pj_bool_t capture, int *index, char *name, size_t name_size) {
    AudioObjectPropertyAddress address = {
        capture ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioDeviceID device_id = kAudioObjectUnknown;
    UInt32 size = sizeof(device_id);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &device_id) != noErr ||
        device_id == kAudioObjectUnknown) {
        return false;
    }

    char device_name[PJMEDIA_AUD_DEV_INFO_NAME_LEN] = {0};
    address.mSelector = kAudioDevicePropertyDeviceName;
    size = sizeof(device_name);
    if (AudioObjectGetPropertyData(device_id, &address, 0, NULL, &size, device_name) != noErr) {
        return false;
    }
    device_name[sizeof(device_name) - 1] = '\0';

    for (unsigned i = 0; i < pjmedia_aud_dev_count(); ++i) {
        pjmedia_aud_dev_info info;
        if (pjmedia_aud_dev_get_info((int)i, &info) == PJ_SUCCESS &&
            strcmp(info.driver, "core audio") == 0 &&
            strcmp(info.name, device_name) == 0 &&
            (capture ? info.input_count : info.output_count) > 0) {
            *index = (int)i;
            snprintf(name, name_size, "%s", info.name);
            return true;
        }
    }
    return false;
}

// PJMEDIA 2.17 generates telephone-event timing using the audio RTP clock.
// Convert only event packets when a received answer selects a different clock.
static pj_status_t send_rtp_with_event_clock(pjmedia_transport *transport,
                                            const void *packet, pj_size_t size) {
    IPPJSIPEndpoint *endpoint = transport->user_data;
    const uint8_t *bytes = packet;
    if (endpoint->tx_event_clock == 0 || endpoint->tx_event_clock == endpoint->audio_rtp_clock
        || size != 16 || bytes[0] != 0x80 || (bytes[1] & 0x7f) != endpoint->tx_event_payload) {
        return endpoint->original_send_rtp(transport, packet, size);
    }
    uint8_t converted[16];
    memcpy(converted, bytes, sizeof(converted));
    uint32_t timestamp = ((uint32_t)bytes[4] << 24) | ((uint32_t)bytes[5] << 16)
        | ((uint32_t)bytes[6] << 8) | bytes[7];
    bool new_event = !endpoint->event_timestamp_initialized || timestamp != endpoint->event_source_timestamp;
    if (!endpoint->event_timestamp_initialized) {
        uint64_t scaled = (uint64_t)timestamp * endpoint->tx_event_clock;
        endpoint->event_wire_timestamp = (uint32_t)(scaled / endpoint->audio_rtp_clock);
        endpoint->event_timestamp_remainder = (unsigned)(scaled % endpoint->audio_rtp_clock);
        endpoint->event_timestamp_initialized = true;
    } else if (new_event) {
        // Unsigned deltas preserve continuity when the source timestamp wraps.
        uint32_t delta = timestamp - endpoint->event_source_timestamp;
        uint64_t scaled = (uint64_t)delta * endpoint->tx_event_clock + endpoint->event_timestamp_remainder;
        endpoint->event_wire_timestamp += (uint32_t)(scaled / endpoint->audio_rtp_clock);
        endpoint->event_timestamp_remainder = (unsigned)(scaled % endpoint->audio_rtp_clock);
    }
    endpoint->event_source_timestamp = timestamp;
    if (new_event) {
        endpoint->event_last_duration = 0;
        endpoint->event_extended_duration = 0;
    }
    uint16_t duration = ((uint16_t)bytes[14] << 8) | bytes[15];
    endpoint->event_extended_duration += (uint16_t)(duration - endpoint->event_last_duration);
    endpoint->event_last_duration = duration;
    uint16_t wire_duration = (uint16_t)((uint64_t)endpoint->event_extended_duration
        * endpoint->tx_event_clock / endpoint->audio_rtp_clock);
    for (unsigned i = 0; i < 4; ++i) {
        converted[4 + i] = (uint8_t)(endpoint->event_wire_timestamp >> (24 - 8 * i));
    }
    converted[14] = (uint8_t)(wire_duration >> 8);
    converted[15] = (uint8_t)wire_duration;
    return endpoint->original_send_rtp(transport, converted, sizeof(converted));
}

static int matching_event_payload(const pjmedia_sdp_media *media, unsigned clock_rate) {
    for (unsigned i = 0; i < media->desc.fmt_count; ++i) {
        const pjmedia_sdp_attr *attr = pjmedia_sdp_media_find_attr2(media, "rtpmap", &media->desc.fmt[i]);
        pjmedia_sdp_rtpmap map;
        if (attr != NULL && pjmedia_sdp_attr_get_rtpmap(attr, &map) == PJ_SUCCESS
            && pj_stricmp2(&map.enc_name, "telephone-event") == 0 && map.clock_rate == clock_rate) {
            return (int)pj_strtoul(&media->desc.fmt[i]);
        }
    }
    return -1;
}

static void start_media(IPPJSIPEndpoint *endpoint, pjsip_inv_session *invite) {
    if (endpoint->media_stream != NULL || invite->neg == NULL) {
        return;
    }
    endpoint->media_state = IP_PJSIP_MEDIA_STARTING;

    const pjmedia_sdp_session *local_sdp = NULL;
    const pjmedia_sdp_session *remote_sdp = NULL;
    pj_status_t status = pjmedia_sdp_neg_get_active_local(invite->neg, &local_sdp);
    if (status == PJ_SUCCESS) {
        status = pjmedia_sdp_neg_get_active_remote(invite->neg, &remote_sdp);
    }
    if (status != PJ_SUCCESS || local_sdp == NULL || remote_sdp == NULL) {
        set_media_error(endpoint, "SDP negotiation", status);
        return;
    }

    pjmedia_stream_info info;
    status = pjmedia_stream_info_from_sdp(
        &info,
        endpoint->call_pool,
        endpoint->media_endpoint,
        local_sdp,
        remote_sdp,
        0
    );
    if (status != PJ_SUCCESS) {
        set_media_error(endpoint, "pjmedia_stream_info_from_sdp", status);
        return;
    }
    if (pj_stricmp2(&info.fmt.encoding_name, "PCMU") != 0
        && pj_stricmp2(&info.fmt.encoding_name, "opus") != 0) {
        snprintf(endpoint->media_message, sizeof(endpoint->media_message), "Remote endpoint did not negotiate a supported audio codec");
        endpoint->media_state = IP_PJSIP_MEDIA_FAILED;
        return;
    }
    if (info.param == NULL) {
        info.param = PJ_POOL_ZALLOC_T(endpoint->call_pool, pjmedia_codec_param);
        status = pjmedia_codec_mgr_get_default_param(
            pjmedia_endpt_get_codec_mgr(endpoint->media_endpoint),
            &info.fmt,
            info.param
        );
        if (status != PJ_SUCCESS) {
            set_media_error(endpoint, "Audio codec parameters", status);
            return;
        }
    }
    // Keep sending RTP during silence so the peer receives a continuous stream.
    info.param->setting.vad = 0;
    // Opus always uses a 48 kHz RTP clock, even when PCM sampling is lower.
    unsigned audio_clock = pj_stricmp2(&info.fmt.encoding_name, "opus") == 0 ? 48000 : 8000;
    unsigned event_clock = audio_clock;
    // Accept an 8 kHz event selected by the remote answer alongside Opus,
    // provided that this event was included in our negotiated local offer.
    if (audio_clock == 48000 && pjmedia_sdp_neg_was_answer_remote(invite->neg)
        && matching_event_payload(remote_sdp->media[0], 48000) < 0
        && matching_event_payload(remote_sdp->media[0], 8000) >= 0
        && matching_event_payload(local_sdp->media[0], 8000) >= 0) {
        event_clock = 8000;
    }
    info.rx_event_pt = matching_event_payload(local_sdp->media[0], event_clock);
    info.tx_event_pt = matching_event_payload(remote_sdp->media[0], event_clock);
    if (info.rx_event_pt < 0 || info.tx_event_pt < 0) {
        info.rx_event_pt = info.tx_event_pt = -1;
    }
    endpoint->telephone_event_available = info.tx_event_pt >= 0;
    endpoint->tx_event_payload = info.tx_event_pt;
    endpoint->audio_rtp_clock = audio_clock;
    endpoint->tx_event_clock = endpoint->telephone_event_available ? event_clock : 0;
    endpoint->event_timestamp_initialized = false;

    status = pjmedia_stream_create(
        endpoint->media_endpoint,
        endpoint->call_pool,
        &info,
        endpoint->media_transport,
        endpoint,
        &endpoint->media_stream
    );
    if (status != PJ_SUCCESS) {
        set_media_error(endpoint, "pjmedia_stream_create", status);
        return;
    }
    status = pjmedia_transport_media_start(
        endpoint->media_transport,
        endpoint->call_pool,
        local_sdp,
        remote_sdp,
        0
    );
    if (status != PJ_SUCCESS) {
        set_media_error(endpoint, "pjmedia_transport_media_start", status);
        return;
    }
    endpoint->media_transport_started = true;
    status = pjmedia_stream_start(endpoint->media_stream);
    if (status != PJ_SUCCESS) {
        set_media_error(endpoint, "pjmedia_stream_start", status);
        return;
    }

    status = pjmedia_aud_subsys_init(&endpoint->caching_pool.factory);
    if (status != PJ_SUCCESS) {
        set_media_error(endpoint, "pjmedia_aud_subsys_init", status);
        return;
    }
    endpoint->audio_initialized = true;

    int input_device = endpoint->audio_input_device;
    int output_device = endpoint->audio_output_device;
    char input_name[PJMEDIA_AUD_DEV_INFO_NAME_LEN] = {0};
    char output_name[PJMEDIA_AUD_DEV_INFO_NAME_LEN] = {0};
    if (input_device < 0 || output_device < 0) {
        status = pjmedia_aud_dev_refresh();
        if (status != PJ_SUCCESS) {
            set_media_error(endpoint, "Audio device refresh", status);
            return;
        }
    }
    if (input_device < 0 && !default_audio_device(PJ_TRUE, &input_device, input_name, sizeof(input_name))) {
        snprintf(endpoint->media_message, sizeof(endpoint->media_message), "Could not find the macOS default input device");
        endpoint->media_state = IP_PJSIP_MEDIA_FAILED;
        return;
    }
    if (output_device < 0 && !default_audio_device(PJ_FALSE, &output_device, output_name, sizeof(output_name))) {
        snprintf(endpoint->media_message, sizeof(endpoint->media_message), "Could not find the macOS default output device");
        endpoint->media_state = IP_PJSIP_MEDIA_FAILED;
        return;
    }
    pjmedia_aud_dev_info device_info;
    if (pjmedia_aud_dev_get_info(input_device, &device_info) == PJ_SUCCESS) {
        snprintf(input_name, sizeof(input_name), "%s", device_info.name);
    }
    if (pjmedia_aud_dev_get_info(output_device, &device_info) == PJ_SUCCESS) {
        snprintf(output_name, sizeof(output_name), "%s", device_info.name);
    }

    pjmedia_port *stream_port = NULL;
    status = pjmedia_stream_get_port(endpoint->media_stream, &stream_port);
    if (status == PJ_SUCCESS) {
        status = create_dtmf_inject_port(endpoint, stream_port);
    }
    if (status == PJ_SUCCESS) {
        status = pjmedia_snd_port_create(
            endpoint->call_pool,
            input_device,
            output_device,
            PJMEDIA_PIA_SRATE(&stream_port->info),
            PJMEDIA_PIA_CCNT(&stream_port->info),
            PJMEDIA_PIA_SPF(&stream_port->info),
            16,
            0,
            &endpoint->sound_port
        );
    }
    if (status == PJ_SUCCESS) {
        status = pjmedia_snd_port_connect(endpoint->sound_port, &endpoint->dtmf_inject_port->base);
    }
    if (status != PJ_SUCCESS) {
        set_media_error(endpoint, "Audio device", status);
        return;
    }

    snprintf(endpoint->media_codec, sizeof(endpoint->media_codec), "%.*s/%u",
             (int)info.fmt.encoding_name.slen, info.fmt.encoding_name.ptr, info.fmt.clock_rate);
    endpoint->media_state = IP_PJSIP_MEDIA_ACTIVE;
    snprintf(endpoint->media_message, sizeof(endpoint->media_message),
             "%s send/receive active (input: %s, output: %s)",
             endpoint->media_codec,
             input_name[0] ? input_name : "unknown",
             output_name[0] ? output_name : "unknown");
}

// Keep only events matching the audio codec that the remote-order negotiator
// will select. PJSIP otherwise falls back to an event with a different clock.
static void limit_answer_event_clock(pj_pool_t *pool, pjmedia_sdp_session *answer,
                                    const pjmedia_sdp_session *offer) {
    if (offer == NULL || offer->media_count == 0 || answer->media_count == 0) { return; }
    pjmedia_sdp_media *local = answer->media[0];
    pjmedia_sdp_media *remote = offer->media[0];
    unsigned clock_rate = 0;
    for (unsigned i = 0; i < remote->desc.fmt_count && clock_rate == 0; ++i) {
        for (unsigned j = 0; j < local->desc.fmt_count; ++j) {
            pjmedia_sdp_attr *attr = pjmedia_sdp_media_find_attr2(local, "rtpmap", &local->desc.fmt[j]);
            pjmedia_sdp_rtpmap map;
            if (attr == NULL || pjmedia_sdp_attr_get_rtpmap(attr, &map) != PJ_SUCCESS
                || pj_stricmp2(&map.enc_name, "telephone-event") == 0) { continue; }
            if (pjmedia_sdp_neg_fmt_match(pool, remote, i, local, j, 0) == PJ_SUCCESS) {
                clock_rate = map.clock_rate;
                break;
            }
        }
    }
    if (clock_rate == 0) { return; } // The normal negotiator rejects incompatible audio.
    for (unsigned i = 0; i < local->desc.fmt_count; ) {
        pj_str_t payload = local->desc.fmt[i];
        pjmedia_sdp_attr *attr = pjmedia_sdp_media_find_attr2(local, "rtpmap", &payload);
        pjmedia_sdp_rtpmap map;
        if (attr != NULL && pjmedia_sdp_attr_get_rtpmap(attr, &map) == PJ_SUCCESS
            && pj_stricmp2(&map.enc_name, "telephone-event") == 0 && map.clock_rate != clock_rate) {
            pjmedia_sdp_media_remove_attr(local, attr);
            attr = pjmedia_sdp_media_find_attr2(local, "fmtp", &payload);
            if (attr != NULL) { pjmedia_sdp_media_remove_attr(local, attr); }
            pj_array_erase(local->desc.fmt, sizeof(local->desc.fmt[0]), local->desc.fmt_count, i);
            local->desc.fmt_count--;
        } else {
            ++i;
        }
    }
}

static pjmedia_sdp_session *create_audio_sdp(
    IPPJSIPEndpoint *endpoint,
    uint16_t rtp_port,
    bool answering,
    bool telephone_event,
    const pjmedia_sdp_session *offer
) {
    if (endpoint->call_pool == NULL) {
        endpoint->call_pool = pj_pool_create(
            &endpoint->caching_pool.factory,
            "ipphone-call",
            2048,
            2048,
            NULL
        );
    }
    if (endpoint->call_pool == NULL) {
        return NULL;
    }

    const pjsip_host_port *local = endpoint_local_name(endpoint);
    if (local == NULL) {
        return NULL;
    }
    const bool ipv6 = memchr(local->host.ptr, ':', (size_t)local->host.slen) != NULL;
    if (endpoint->media_transport == NULL) {
        int address_family = ipv6 ? pj_AF_INET6() : pj_AF_INET();
        if (pjmedia_transport_udp_create3(
                endpoint->media_endpoint,
                address_family,
                "ipphone-rtp",
                &local->host,
                rtp_port,
                0,
                &endpoint->media_transport
            ) != PJ_SUCCESS) {
            return NULL;
        }
        endpoint->media_transport_ops = *endpoint->media_transport->op;
        endpoint->original_send_rtp = endpoint->media_transport_ops.send_rtp;
        endpoint->media_transport_ops.send_rtp = &send_rtp_with_event_clock;
        endpoint->media_transport->user_data = endpoint;
        endpoint->media_transport->op = &endpoint->media_transport_ops;
        endpoint->rtp_port = rtp_port;
    }
    bool opus = answering ? endpoint->accept_opus : endpoint->offer_opus;
    bool pcmu = answering ? endpoint->accept_pcmu : endpoint->offer_pcmu;
    if (!opus && !pcmu) { return NULL; }
    const char *formats = opus && pcmu
        ? (endpoint->prefer_opus ? "111 0" : "0 111") : (opus ? "111" : "0");
    char text[1024];
    int length = snprintf(
        text,
        sizeof(text),
        "v=0\r\n"
        "o=- %u %u IN %s %.*s\r\n"
        "s=IPPhone\r\n"
        "c=IN %s %.*s\r\n"
        "t=0 0\r\n"
        "m=audio %u RTP/AVP %s%s%s\r\n"
        "%s%s%s%s"
        "a=sendrecv\r\n",
        (unsigned)pj_rand(),
        (unsigned)pj_rand(),
        ipv6 ? "IP6" : "IP4",
        (int)local->host.slen,
        local->host.ptr,
        ipv6 ? "IP6" : "IP4",
        (int)local->host.slen,
        local->host.ptr,
        (unsigned)rtp_port,
        formats,
        telephone_event && opus ? " 102" : "",
        telephone_event && pcmu ? " 101" : "",
        opus ? "a=rtpmap:111 opus/48000/2\r\na=fmtp:111 stereo=0;sprop-stereo=0\r\n" : "",
        pcmu ? "a=rtpmap:0 PCMU/8000\r\n" : "",
        telephone_event && opus ? "a=rtpmap:102 telephone-event/48000\r\na=fmtp:102 0-16\r\n" : "",
        telephone_event && pcmu ? "a=rtpmap:101 telephone-event/8000\r\na=fmtp:101 0-16\r\n" : ""
    );
    if (length <= 0 || length >= (int)sizeof(text)) {
        return NULL;
    }

    char *sdp_text = pj_pool_alloc(endpoint->call_pool, (pj_size_t)length + 1);
    memcpy(sdp_text, text, (size_t)length + 1);
    pjmedia_sdp_session *sdp = NULL;
    if (pjmedia_sdp_parse(endpoint->call_pool, sdp_text, (pj_size_t)length, &sdp) != PJ_SUCCESS) {
        return NULL;
    }
    if (answering) { limit_answer_event_clock(endpoint->call_pool, sdp, offer); }
    return sdp;
}

static void set_remote_uri(IPPJSIPEndpoint *endpoint, const pjsip_from_hdr *from) {
    if (from == NULL || from->uri == NULL) {
        endpoint->remote_uri[0] = '\0';
        return;
    }
    int length = pjsip_uri_print(
        PJSIP_URI_IN_FROMTO_HDR,
        from->uri,
        endpoint->remote_uri,
        sizeof(endpoint->remote_uri) - 1
    );
    if (length < 0) {
        endpoint->remote_uri[0] = '\0';
    } else {
        endpoint->remote_uri[length] = '\0';
    }
}

static void invite_state_changed(pjsip_inv_session *invite, pjsip_event *event) {
    PJ_UNUSED_ARG(event);
    IPPJSIPEndpoint *endpoint = active_endpoint;
    if (endpoint == NULL || endpoint->invite_session != invite) {
        return;
    }

    switch (invite->state) {
    case PJSIP_INV_STATE_CALLING:
        endpoint->call_state = IP_PJSIP_CALL_OUTGOING;
        break;
    case PJSIP_INV_STATE_INCOMING:
        endpoint->call_state = IP_PJSIP_CALL_INCOMING;
        break;
    case PJSIP_INV_STATE_EARLY:
        if (invite->role == PJSIP_ROLE_UAC) {
            endpoint->call_state = IP_PJSIP_CALL_RINGING;
        }
        break;
    case PJSIP_INV_STATE_CONNECTING:
    case PJSIP_INV_STATE_CONFIRMED:
        endpoint->call_state = IP_PJSIP_CALL_CONNECTED;
        endpoint->call_status_code = 200;
        snprintf(endpoint->call_message, sizeof(endpoint->call_message), "Connected");
        break;
    case PJSIP_INV_STATE_DISCONNECTED:
        endpoint->call_status_code = invite->cause;
        snprintf(
            endpoint->call_message,
            sizeof(endpoint->call_message),
            "%.*s",
            (int)invite->cause_text.slen,
            invite->cause_text.ptr == NULL ? "" : invite->cause_text.ptr
        );
        endpoint->call_state = endpoint->local_termination
                || invite->cause < 300
                || invite->cause == PJSIP_SC_REQUEST_TERMINATED
            ? IP_PJSIP_CALL_ENDED
            : IP_PJSIP_CALL_FAILED;
        endpoint->invite_session = NULL;
        destroy_media(endpoint);
        break;
    default:
        break;
    }
}

static void invite_new_session(pjsip_inv_session *invite, pjsip_event *event) {
    PJ_UNUSED_ARG(invite);
    PJ_UNUSED_ARG(event);
}

static void invite_rx_offer(
    pjsip_inv_session *invite,
    const pjmedia_sdp_session *offer
) {
    pjmedia_sdp_neg_set_prefer_remote_codec_order(invite->neg, PJ_TRUE);
    IPPJSIPEndpoint *endpoint = active_endpoint;
    if (endpoint == NULL || endpoint->invite_session != invite) {
        return;
    }
    pjmedia_sdp_session *answer = create_audio_sdp(endpoint, endpoint->rtp_port, true, true, offer);
    if (answer != NULL) {
        pjsip_inv_set_sdp_answer(invite, answer);
    }
}

static void invite_media_update(pjsip_inv_session *invite, pj_status_t status) {
    IPPJSIPEndpoint *endpoint = active_endpoint;
    if (endpoint == NULL || endpoint->invite_session != invite) {
        return;
    }
    if (status != PJ_SUCCESS) {
        set_media_error(endpoint, "SDP negotiation", status);
        return;
    }
    start_media(endpoint, invite);
}

static pj_bool_t incoming_request(pjsip_rx_data *rdata) {
    IPPJSIPEndpoint *endpoint = active_endpoint;
    if (endpoint == NULL || rdata->msg_info.msg->line.req.method.id != PJSIP_INVITE_METHOD) {
        return PJ_FALSE;
    }
    if (endpoint->invite_session != NULL) {
        pjsip_endpt_respond_stateless(
            endpoint->sip_endpoint,
            rdata,
            PJSIP_SC_BUSY_HERE,
            NULL,
            NULL,
            NULL
        );
        return PJ_TRUE;
    }

    pjsip_rdata_sdp_info *sdp_info = pjsip_rdata_get_sdp_info(rdata);
    pjmedia_sdp_session *sdp = create_audio_sdp(endpoint, endpoint->rtp_port, true, true, sdp_info->sdp);
    if (sdp == NULL) {
        pjsip_endpt_respond_stateless(endpoint->sip_endpoint, rdata, 488, NULL, NULL, NULL);
        destroy_media(endpoint);
        return PJ_TRUE;
    }
    unsigned options = 0;
    pjsip_tx_data *rejection = NULL;
    if (pjsip_inv_verify_request(rdata, &options, sdp, NULL,
                                 endpoint->sip_endpoint, &rejection) != PJ_SUCCESS) {
        if (rejection != NULL) {
            pjsip_endpt_send_response2(endpoint->sip_endpoint, rdata, rejection, NULL, NULL);
        }
        destroy_media(endpoint);
        return PJ_TRUE;
    }

    char contact_buffer[PJSIP_MAX_URL_SIZE];
    pj_str_t contact;
    pj_str_t *local_contact = NULL;
    if (endpoint->has_selected_local_address) {
        pjsip_uri *to_uri = pjsip_uri_get_uri(rdata->msg_info.to->uri);
        if ((PJSIP_URI_SCHEME_IS_SIP(to_uri) || PJSIP_URI_SCHEME_IS_SIPS(to_uri)) &&
            build_local_contact(endpoint, &((pjsip_sip_uri *)to_uri)->user,
                                contact_buffer, sizeof(contact_buffer))) {
            contact = pj_str(contact_buffer);
            local_contact = &contact;
        }
    }
    pjsip_dialog *dialog = NULL;
    pj_status_t status = pjsip_dlg_create_uas_and_inc_lock(
        pjsip_ua_instance(),
        rdata,
        local_contact,
        &dialog
    );
    if (status != PJ_SUCCESS) {
        pjsip_endpt_respond_stateless(endpoint->sip_endpoint, rdata, 500, NULL, NULL, NULL);
        return PJ_TRUE;
    }

    if (endpoint->has_selected_local_address) {
        pjsip_tpselector selector = endpoint_transport_selector(endpoint);
        pjsip_dlg_set_transport(dialog, &selector);
    }

    status = pjsip_inv_create_uas(dialog, rdata, sdp, options, &endpoint->invite_session);
    if (status != PJ_SUCCESS) {
        pjsip_dlg_dec_lock(dialog);
        pjsip_endpt_respond_stateless(endpoint->sip_endpoint, rdata, 500, NULL, NULL, NULL);
        return PJ_TRUE;
    }

    pjmedia_sdp_neg_set_prefer_remote_codec_order(endpoint->invite_session->neg, PJ_TRUE);
    pjmedia_sdp_neg_set_answer_multiple_codecs(endpoint->invite_session->neg, PJ_FALSE);
    set_remote_uri(endpoint, rdata->msg_info.from);
    endpoint->call_state = IP_PJSIP_CALL_INCOMING;
    endpoint->local_termination = false;
    endpoint->call_status_code = 180;
    snprintf(endpoint->call_message, sizeof(endpoint->call_message), "Incoming call");

    pjsip_tx_data *response = NULL;
    status = pjsip_inv_initial_answer(
        endpoint->invite_session,
        rdata,
        PJSIP_SC_RINGING,
        NULL,
        NULL,
        &response
    );
    if (status == PJ_SUCCESS) {
        status = pjsip_inv_send_msg(endpoint->invite_session, response);
    }
    pjsip_dlg_dec_lock(dialog);
    if (status != PJ_SUCCESS) {
        endpoint->call_state = IP_PJSIP_CALL_FAILED;
        endpoint->call_status_code = 500;
        snprintf(endpoint->call_message, sizeof(endpoint->call_message), "Unable to send 180 Ringing");
    }
    return PJ_TRUE;
}

static void registration_callback(struct pjsip_regc_cbparam *param) {
    IPPJSIPEndpoint *endpoint = (IPPJSIPEndpoint *)param->token;
    if (endpoint == NULL) {
        return;
    }

    endpoint->registration_status_code = param->code;
    endpoint->registration_expiration = param->expiration;
    if (param->reason.ptr != NULL && param->reason.slen > 0) {
        snprintf(
            endpoint->registration_message,
            sizeof(endpoint->registration_message),
            "%.*s",
            (int)param->reason.slen,
            param->reason.ptr
        );
    } else if (param->status != PJ_SUCCESS) {
        pj_strerror(
            param->status,
            endpoint->registration_message,
            sizeof(endpoint->registration_message)
        );
    } else {
        endpoint->registration_message[0] = '\0';
    }

    if (param->status != PJ_SUCCESS) {
        endpoint->registration_state = IP_PJSIP_REGISTRATION_FAILED;
    } else if (param->is_unreg && param->code >= 200 && param->code < 300) {
        endpoint->registration_state = IP_PJSIP_REGISTRATION_UNREGISTERED;
    } else if (param->code >= 200 && param->code < 300) {
        endpoint->registration_state = IP_PJSIP_REGISTRATION_REGISTERED;
    } else {
        endpoint->registration_state = IP_PJSIP_REGISTRATION_FAILED;
    }
}

static void copy_error(char *buffer, int length, const char *message) {
    if (buffer == NULL || length <= 0) {
        return;
    }
    snprintf(buffer, (size_t)length, "%s", message);
}

static void copy_status_error(
    char *buffer,
    int length,
    const char *operation,
    pj_status_t status
) {
    char status_message[PJ_ERR_MSG_SIZE];
    pj_strerror(status, status_message, sizeof(status_message));

    if (buffer == NULL || length <= 0) {
        return;
    }
    snprintf(
        buffer,
        (size_t)length,
        "%s failed (%d): %s",
        operation,
        status,
        status_message
    );
}

IPPJSIPEndpoint *ip_pjsip_endpoint_create(void) {
    IPPJSIPEndpoint *endpoint = calloc(1, sizeof(IPPJSIPEndpoint));
    ip_pjsip_endpoint_set_codecs(endpoint, true, true, true, true, true);
    return endpoint;
}

bool ip_pjsip_endpoint_start(
    IPPJSIPEndpoint *endpoint,
    IPPJSIPTransport transport_kind,
    uint16_t port,
    uint16_t rtp_port,
    int audio_input_device,
    int audio_output_device,
    bool allow_self_signed_certificate,
    const char *local_ip_address,
    char *error_buffer,
    int error_buffer_length
) {
    if (endpoint == NULL) {
        copy_error(error_buffer, error_buffer_length, "Endpoint is null");
        return false;
    }
    if (endpoint->running) {
        copy_error(error_buffer, error_buffer_length, "Endpoint is already running");
        return false;
    }

    pj_status_t status = pj_init();
    if (status != PJ_SUCCESS) {
        copy_status_error(error_buffer, error_buffer_length, "pj_init", status);
        return false;
    }
    endpoint->pj_initialized = true;

    status = pjlib_util_init();
    if (status != PJ_SUCCESS) {
        copy_status_error(error_buffer, error_buffer_length, "pjlib_util_init", status);
        ip_pjsip_endpoint_stop(endpoint);
        return false;
    }

    status = pjnath_init();
    if (status != PJ_SUCCESS) {
        copy_status_error(error_buffer, error_buffer_length, "pjnath_init", status);
        ip_pjsip_endpoint_stop(endpoint);
        return false;
    }

    pj_caching_pool_init(&endpoint->caching_pool, NULL, 0);
    endpoint->pool_initialized = true;
    endpoint->rtp_port = rtp_port;
    endpoint->audio_input_device = audio_input_device;
    endpoint->audio_output_device = audio_output_device;
    endpoint->transport_kind = transport_kind;
    endpoint->has_selected_local_address = local_ip_address != NULL && local_ip_address[0] != '\0';

    status = pjmedia_endpt_create2(
        &endpoint->caching_pool.factory,
        NULL,
        1,
        &endpoint->media_endpoint
    );
    if (status != PJ_SUCCESS) {
        copy_status_error(error_buffer, error_buffer_length, "pjmedia_endpt_create2", status);
        ip_pjsip_endpoint_stop(endpoint);
        return false;
    }
    status = pjmedia_codec_g711_init(endpoint->media_endpoint);
    if (status != PJ_SUCCESS) {
        copy_status_error(error_buffer, error_buffer_length, "pjmedia_codec_g711_init", status);
        ip_pjsip_endpoint_stop(endpoint);
        return false;
    }
    endpoint->g711_initialized = true;
    status = pjmedia_codec_opus_init(endpoint->media_endpoint);
    if (status != PJ_SUCCESS) {
        copy_status_error(error_buffer, error_buffer_length, "pjmedia_codec_opus_init", status);
        ip_pjsip_endpoint_stop(endpoint);
        return false;
    }
    endpoint->opus_initialized = true;
    endpoint->media_pool = pjmedia_endpt_create_pool(
        endpoint->media_endpoint,
        "ipphone-media",
        1024,
        1024
    );
    if (endpoint->media_pool == NULL) {
        copy_error(error_buffer, error_buffer_length, "Unable to create media pool");
        ip_pjsip_endpoint_stop(endpoint);
        return false;
    }
    status = pjmedia_event_mgr_create(
        endpoint->media_pool,
        PJMEDIA_EVENT_MGR_NO_THREAD,
        &endpoint->media_event_manager
    );
    if (status != PJ_SUCCESS) {
        copy_status_error(error_buffer, error_buffer_length, "pjmedia_event_mgr_create", status);
        ip_pjsip_endpoint_stop(endpoint);
        return false;
    }

    status = pjsip_endpt_create(
        &endpoint->caching_pool.factory,
        "ipphone",
        &endpoint->sip_endpoint
    );
    if (status != PJ_SUCCESS) {
        copy_status_error(
            error_buffer,
            error_buffer_length,
            "pjsip_endpt_create",
            status
        );
        ip_pjsip_endpoint_stop(endpoint);
        return false;
    }

    status = pjsip_tsx_layer_init_module(endpoint->sip_endpoint);
    if (status != PJ_SUCCESS) {
        copy_status_error(
            error_buffer,
            error_buffer_length,
            "pjsip_tsx_layer_init_module",
            status
        );
        ip_pjsip_endpoint_stop(endpoint);
        return false;
    }

    status = pjsip_ua_init_module(endpoint->sip_endpoint, NULL);
    if (status != PJ_SUCCESS) {
        copy_status_error(error_buffer, error_buffer_length, "pjsip_ua_init_module", status);
        ip_pjsip_endpoint_stop(endpoint);
        return false;
    }

    status = pjsip_100rel_init_module(endpoint->sip_endpoint);
    if (status != PJ_SUCCESS) {
        copy_status_error(error_buffer, error_buffer_length, "pjsip_100rel_init_module", status);
        ip_pjsip_endpoint_stop(endpoint);
        return false;
    }

    pj_bzero(&invite_callbacks, sizeof(invite_callbacks));
    invite_callbacks.on_state_changed = &invite_state_changed;
    invite_callbacks.on_new_session = &invite_new_session;
    invite_callbacks.on_rx_offer = &invite_rx_offer;
    invite_callbacks.on_media_update = &invite_media_update;
    status = pjsip_inv_usage_init(endpoint->sip_endpoint, &invite_callbacks);
    if (status != PJ_SUCCESS) {
        copy_status_error(error_buffer, error_buffer_length, "pjsip_inv_usage_init", status);
        ip_pjsip_endpoint_stop(endpoint);
        return false;
    }

    pj_bzero(&endpoint->log_module, sizeof(endpoint->log_module));
    endpoint->log_module.name = pj_str("mod-ipphone-log");
    endpoint->log_module.id = -1;
    endpoint->log_module.priority = PJSIP_MOD_PRIORITY_TRANSPORT_LAYER + 1;
    endpoint->log_module.on_rx_request = &log_rx_request;
    endpoint->log_module.on_rx_response = &log_rx_response;
    endpoint->log_module.on_tx_request = &log_tx_request;
    endpoint->log_module.on_tx_response = &log_tx_response;
    active_endpoint = endpoint;
    status = pjsip_endpt_register_module(endpoint->sip_endpoint, &endpoint->log_module);
    if (status != PJ_SUCCESS) {
        active_endpoint = NULL;
        copy_status_error(error_buffer, error_buffer_length, "pjsip log module", status);
        ip_pjsip_endpoint_stop(endpoint);
        return false;
    }

    pj_bzero(&endpoint->app_module, sizeof(endpoint->app_module));
    endpoint->app_module.name = pj_str("mod-ipphone");
    endpoint->app_module.id = -1;
    endpoint->app_module.priority = PJSIP_MOD_PRIORITY_APPLICATION;
    endpoint->app_module.on_rx_request = &incoming_request;
    active_endpoint = endpoint;
    status = pjsip_endpt_register_module(endpoint->sip_endpoint, &endpoint->app_module);
    if (status != PJ_SUCCESS) {
        active_endpoint = NULL;
        copy_status_error(error_buffer, error_buffer_length, "pjsip_endpt_register_module", status);
        ip_pjsip_endpoint_stop(endpoint);
        return false;
    }

    pj_sockaddr address;
    pj_str_t local_ip = pj_str((char *)(local_ip_address == NULL ? "" : local_ip_address));
    int address_family = strchr(local_ip.ptr, ':') == NULL ? pj_AF_INET() : pj_AF_INET6();
    status = pj_sockaddr_init(address_family, &address,
                              local_ip.slen == 0 ? NULL : &local_ip, port);
    if (status != PJ_SUCCESS) {
        copy_status_error(error_buffer, error_buffer_length, "Invalid local SIP address", status);
        ip_pjsip_endpoint_stop(endpoint);
        return false;
    }
    // Derive the published address from the bound socket so ephemeral ports
    // are included. Supplying an explicit UDP published port of 0 preserves
    // that zero rather than substituting the actual bound port.
    const char *transport_operation = NULL;
    switch (transport_kind) {
    case IP_PJSIP_TRANSPORT_UDP:
        transport_operation = "pjsip_udp_transport_start2";
        pjsip_udp_transport_cfg udp_config;
        pjsip_udp_transport_cfg_default(&udp_config, address_family);
        udp_config.bind_addr = address;
        status = pjsip_udp_transport_start2(endpoint->sip_endpoint, &udp_config, &endpoint->transport);
        break;
    case IP_PJSIP_TRANSPORT_TCP:
        transport_operation = "pjsip_tcp_transport_start3";
        pjsip_tcp_transport_cfg tcp_config;
        pjsip_tcp_transport_cfg_default(&tcp_config, address_family);
        tcp_config.bind_addr = address;
        status = pjsip_tcp_transport_start3(endpoint->sip_endpoint, &tcp_config, &endpoint->transport_factory);
        break;
    case IP_PJSIP_TRANSPORT_TLS: {
        transport_operation = "pjsip_tls_transport_start2";
        pjsip_tls_setting tls_settings;
        pjsip_tls_setting_default(&tls_settings);
        tls_settings.proto = PJ_SSL_SOCK_PROTO_TLS1_2 | PJ_SSL_SOCK_PROTO_TLS1_3;
        tls_settings.verify_server = allow_self_signed_certificate ? PJ_FALSE : PJ_TRUE;
        tls_settings.verify_client = PJ_FALSE;
        tls_settings.require_client_cert = PJ_FALSE;
        status = pjsip_tls_transport_start2(
            endpoint->sip_endpoint,
            &tls_settings,
            &address,
            NULL,
            1,
            &endpoint->transport_factory
        );
        break;
    }
    default:
        copy_error(error_buffer, error_buffer_length, "Unsupported SIP transport");
        ip_pjsip_endpoint_stop(endpoint);
        return false;
    }
    if (status != PJ_SUCCESS) {
        copy_status_error(
            error_buffer,
            error_buffer_length,
            transport_operation,
            status
        );
        ip_pjsip_endpoint_stop(endpoint);
        return false;
    }

    const pjsip_host_port *local = endpoint_local_name(endpoint);
    endpoint->bound_port = local == NULL ? 0 : (uint16_t)local->port;
    endpoint->registration_state = IP_PJSIP_REGISTRATION_UNREGISTERED;
    endpoint->running = true;
    return true;
}

bool ip_pjsip_endpoint_start_udp(
    IPPJSIPEndpoint *endpoint,
    uint16_t port,
    uint16_t rtp_port,
    int audio_input_device,
    int audio_output_device,
    char *error_buffer,
    int error_buffer_length
) {
    return ip_pjsip_endpoint_start(
        endpoint,
        IP_PJSIP_TRANSPORT_UDP,
        port,
        rtp_port,
        audio_input_device,
        audio_output_device,
        true,
        NULL,
        error_buffer,
        error_buffer_length
    );
}

uint16_t ip_pjsip_endpoint_bound_port(const IPPJSIPEndpoint *endpoint) {
    if (endpoint == NULL || !endpoint->running) {
        return 0;
    }
    return endpoint->bound_port;
}

void ip_pjsip_endpoint_poll(IPPJSIPEndpoint *endpoint) {
    if (endpoint == NULL || endpoint->sip_endpoint == NULL) {
        return;
    }
    pj_time_val timeout = {0, 0};
    pjsip_endpt_handle_events(endpoint->sip_endpoint, &timeout);
}

bool ip_pjsip_endpoint_register(
    IPPJSIPEndpoint *endpoint,
    const char *registrar_uri,
    const char *address_of_record,
    const char *user_id,
    const char *password,
    uint32_t expiration,
    char *error_buffer,
    int error_buffer_length
) {
    if (endpoint == NULL || !endpoint->running) {
        copy_error(error_buffer, error_buffer_length, "Endpoint is not running");
        return false;
    }
    if (endpoint->registration_client != NULL) {
        if (endpoint->registration_state == IP_PJSIP_REGISTRATION_UNREGISTERED
            || endpoint->registration_state == IP_PJSIP_REGISTRATION_FAILED) {
            pjsip_regc_destroy2(endpoint->registration_client, PJ_TRUE);
            endpoint->registration_client = NULL;
        } else {
            copy_error(error_buffer, error_buffer_length, "Registration client already exists");
            return false;
        }
    }

    pj_status_t status = pjsip_regc_create(
        endpoint->sip_endpoint,
        endpoint,
        &registration_callback,
        &endpoint->registration_client
    );
    if (status != PJ_SUCCESS) {
        copy_status_error(error_buffer, error_buffer_length, "pjsip_regc_create", status);
        return false;
    }

    char contact_buffer[PJSIP_MAX_URL_SIZE];
    pj_str_t contact_user = pj_str((char *)user_id);
    if (!build_local_contact(endpoint, &contact_user, contact_buffer, sizeof(contact_buffer))) {
        copy_error(error_buffer, error_buffer_length, "Unable to create local SIP Contact");
        pjsip_regc_destroy(endpoint->registration_client);
        endpoint->registration_client = NULL;
        return false;
    }

    pj_str_t registrar = pj_str((char *)registrar_uri);
    pj_str_t aor = pj_str((char *)address_of_record);
    pj_str_t contact = pj_str(contact_buffer);
    status = pjsip_regc_init(
        endpoint->registration_client,
        &registrar,
        &aor,
        &aor,
        1,
        &contact,
        expiration
    );
    if (status != PJ_SUCCESS) {
        copy_status_error(error_buffer, error_buffer_length, "pjsip_regc_init", status);
        pjsip_regc_destroy(endpoint->registration_client);
        endpoint->registration_client = NULL;
        return false;
    }

    if (endpoint->has_selected_local_address) {
        pjsip_tpselector selector = endpoint_transport_selector(endpoint);
        pjsip_regc_set_transport(endpoint->registration_client, &selector);
    }

    pjsip_cred_info credential;
    pj_bzero(&credential, sizeof(credential));
    credential.realm = pj_str("*");
    credential.scheme = pj_str("digest");
    credential.username = pj_str((char *)user_id);
    credential.data_type = PJSIP_CRED_DATA_PLAIN_PASSWD;
    credential.data = pj_str((char *)password);
    status = pjsip_regc_set_credentials(endpoint->registration_client, 1, &credential);
    if (status != PJ_SUCCESS) {
        copy_status_error(error_buffer, error_buffer_length, "pjsip_regc_set_credentials", status);
        pjsip_regc_destroy(endpoint->registration_client);
        endpoint->registration_client = NULL;
        return false;
    }

    pjsip_tx_data *request = NULL;
    status = pjsip_regc_register(endpoint->registration_client, PJ_TRUE, &request);
    if (status == PJ_SUCCESS) {
        status = pjsip_regc_send(endpoint->registration_client, request);
    }
    if (status != PJ_SUCCESS) {
        copy_status_error(error_buffer, error_buffer_length, "REGISTER", status);
        pjsip_regc_destroy(endpoint->registration_client);
        endpoint->registration_client = NULL;
        return false;
    }

    endpoint->registration_state = IP_PJSIP_REGISTRATION_REGISTERING;
    endpoint->registration_status_code = 0;
    endpoint->registration_expiration = 0;
    snprintf(endpoint->registration_message, sizeof(endpoint->registration_message), "REGISTER sent");
    return true;
}

bool ip_pjsip_endpoint_unregister(
    IPPJSIPEndpoint *endpoint,
    char *error_buffer,
    int error_buffer_length
) {
    if (endpoint == NULL || endpoint->registration_client == NULL) {
        copy_error(error_buffer, error_buffer_length, "No registration exists");
        return false;
    }

    pjsip_tx_data *request = NULL;
    pj_status_t status = pjsip_regc_unregister(endpoint->registration_client, &request);
    if (status == PJ_SUCCESS) {
        status = pjsip_regc_send(endpoint->registration_client, request);
    }
    if (status != PJ_SUCCESS) {
        copy_status_error(error_buffer, error_buffer_length, "Unregister", status);
        return false;
    }

    endpoint->registration_state = IP_PJSIP_REGISTRATION_UNREGISTERING;
    endpoint->registration_status_code = 0;
    snprintf(endpoint->registration_message, sizeof(endpoint->registration_message), "Unregister sent");
    return true;
}

IPPJSIPRegistrationState ip_pjsip_endpoint_registration_state(
    const IPPJSIPEndpoint *endpoint
) {
    return endpoint == NULL ? IP_PJSIP_REGISTRATION_UNREGISTERED : endpoint->registration_state;
}

int ip_pjsip_endpoint_registration_status_code(const IPPJSIPEndpoint *endpoint) {
    return endpoint == NULL ? 0 : endpoint->registration_status_code;
}

uint32_t ip_pjsip_endpoint_registration_expiration(const IPPJSIPEndpoint *endpoint) {
    return endpoint == NULL ? 0 : endpoint->registration_expiration;
}

const char *ip_pjsip_endpoint_registration_message(const IPPJSIPEndpoint *endpoint) {
    return endpoint == NULL ? "" : endpoint->registration_message;
}

void ip_pjsip_endpoint_set_codecs(IPPJSIPEndpoint *endpoint, bool offer_opus,
    bool offer_pcmu, bool prefer_opus, bool accept_opus, bool accept_pcmu) {
    if (endpoint == NULL) { return; }
    endpoint->offer_opus = offer_opus;
    endpoint->offer_pcmu = offer_pcmu;
    endpoint->prefer_opus = prefer_opus;
    endpoint->accept_opus = accept_opus;
    endpoint->accept_pcmu = accept_pcmu;
}

const char *ip_pjsip_endpoint_media_codec(const IPPJSIPEndpoint *endpoint) {
    return endpoint == NULL ? "" : endpoint->media_codec;
}

bool ip_pjsip_endpoint_make_call(
    IPPJSIPEndpoint *endpoint,
    const char *local_uri,
    const char *destination_uri,
    const char *target_uri,
    bool uses_explicit_uri,
    bool offer_telephone_event,
    const char *user_id,
    const char *password,
    uint16_t rtp_port,
    char *error_buffer,
    int error_buffer_length
) {
    if (endpoint == NULL || !endpoint->running) {
        copy_error(error_buffer, error_buffer_length, "Endpoint is not running");
        return false;
    }
    if (endpoint->invite_session != NULL) {
        copy_error(error_buffer, error_buffer_length, "A call is already active");
        return false;
    }
    if (endpoint->call_pool != NULL) {
        pj_pool_release(endpoint->call_pool);
        endpoint->call_pool = NULL;
    }

    pjmedia_sdp_session *sdp = create_audio_sdp(endpoint, rtp_port, false, offer_telephone_event, NULL);
    if (sdp == NULL) {
        copy_error(error_buffer, error_buffer_length, "Unable to create local SDP");
        return false;
    }

    char contact_buffer[PJSIP_MAX_URL_SIZE];
    pj_str_t contact_user = pj_str((char *)user_id);
    if (!build_local_contact(endpoint, &contact_user, contact_buffer, sizeof(contact_buffer))) {
        copy_error(error_buffer, error_buffer_length, "Unable to create local SIP Contact");
        return false;
    }
    pj_str_t local_uri_string = pj_str((char *)local_uri);
    pj_str_t contact = pj_str(contact_buffer);
    pj_str_t remote_uri = pj_str((char *)destination_uri);
    pj_str_t target = pj_str((char *)(uses_explicit_uri ? destination_uri : target_uri));
    pjsip_dialog *dialog = NULL;
    pj_status_t status = pjsip_dlg_create_uac(
        pjsip_ua_instance(),
        &local_uri_string,
        &contact,
        &remote_uri,
        &target,
        &dialog
    );
    if (status != PJ_SUCCESS) {
        copy_status_error(error_buffer, error_buffer_length, "pjsip_dlg_create_uac", status);
        return false;
    }

    if (uses_explicit_uri) {
        // Preserve an explicitly supplied port when serializing To headers.
        pjsip_cfg()->endpt.allow_port_in_fromto_hdr = PJ_TRUE;
        // Keep the full Request-URI independent from the To identity, whose
        // URI parameters must be removed (including unknown extensions).
        dialog->remote.info->uri = pjsip_uri_clone(dialog->pool, dialog->remote.info->uri);
        pjsip_sip_uri *to_uri = pjsip_uri_get_uri(dialog->remote.info->uri);
        to_uri->user_param = pj_str("");
        to_uri->method_param = pj_str("");
        to_uri->transport_param = pj_str("");
        to_uri->ttl_param = -1;
        to_uri->lr_param = 0;
        to_uri->maddr_param = pj_str("");
        pj_list_init(&to_uri->other_param);
    } else {
        // Number destinations use the configured SIP server for routing.
        pjsip_sip_uri *remote_sip_uri = pjsip_uri_get_uri(dialog->remote.info->uri);
        pjsip_sip_uri *target_sip_uri = pjsip_uri_get_uri(dialog->target);
        pj_strdup(dialog->pool, &target_sip_uri->user, &remote_sip_uri->user);
    }

    pjsip_cred_info credential;
    pj_bzero(&credential, sizeof(credential));
    credential.realm = pj_str("*");
    credential.scheme = pj_str("digest");
    credential.username = pj_str((char *)user_id);
    credential.data_type = PJSIP_CRED_DATA_PLAIN_PASSWD;
    credential.data = pj_str((char *)password);
    pjsip_auth_clt_set_credentials(&dialog->auth_sess, 1, &credential);

    status = pjsip_inv_create_uac(dialog, sdp, 0, &endpoint->invite_session);
    if (status != PJ_SUCCESS) {
        copy_status_error(error_buffer, error_buffer_length, "pjsip_inv_create_uac", status);
        pjsip_dlg_terminate(dialog);
        return false;
    }

    // The INVITE usage must retain the dialog before a setter acquires and
    // releases its lock; a dialog with no usages is destroyed on unlock.
    if (endpoint->has_selected_local_address) {
        pjsip_tpselector selector = endpoint_transport_selector(endpoint);
        pjsip_dlg_set_transport(dialog, &selector);
    }

    pjsip_tx_data *request = NULL;
    status = pjsip_inv_invite(endpoint->invite_session, &request);
    if (status == PJ_SUCCESS) {
        status = pjsip_inv_send_msg(endpoint->invite_session, request);
    }
    if (status != PJ_SUCCESS) {
        copy_status_error(error_buffer, error_buffer_length, "INVITE", status);
        pjsip_inv_terminate(endpoint->invite_session, 500, PJ_FALSE);
        endpoint->invite_session = NULL;
        return false;
    }

    endpoint->call_state = IP_PJSIP_CALL_OUTGOING;
    endpoint->local_termination = false;
    endpoint->call_status_code = 0;
    snprintf(endpoint->call_message, sizeof(endpoint->call_message), "INVITE sent");
    snprintf(endpoint->remote_uri, sizeof(endpoint->remote_uri), "%s", destination_uri);
    return true;
}

bool ip_pjsip_endpoint_answer_call(
    IPPJSIPEndpoint *endpoint,
    char *error_buffer,
    int error_buffer_length
) {
    if (endpoint == NULL || endpoint->invite_session == NULL
        || endpoint->call_state != IP_PJSIP_CALL_INCOMING) {
        copy_error(error_buffer, error_buffer_length, "There is no incoming call to answer");
        return false;
    }

    pjsip_tx_data *response = NULL;
    pj_status_t status = pjsip_inv_answer(
        endpoint->invite_session,
        PJSIP_SC_OK,
        NULL,
        NULL,
        &response
    );
    if (status == PJ_SUCCESS) {
        status = pjsip_inv_send_msg(endpoint->invite_session, response);
    }
    if (status != PJ_SUCCESS) {
        copy_status_error(error_buffer, error_buffer_length, "Answer", status);
        return false;
    }
    endpoint->call_state = IP_PJSIP_CALL_CONNECTED;
    snprintf(endpoint->call_message, sizeof(endpoint->call_message), "200 OK sent");
    return true;
}

bool ip_pjsip_endpoint_end_call(
    IPPJSIPEndpoint *endpoint,
    int status_code,
    char *error_buffer,
    int error_buffer_length
) {
    if (endpoint == NULL || endpoint->invite_session == NULL) {
        copy_error(error_buffer, error_buffer_length, "There is no active call");
        return false;
    }

    endpoint->local_termination = true;
    pjsip_tx_data *request = NULL;
    pj_status_t status = pjsip_inv_end_session(
        endpoint->invite_session,
        status_code,
        NULL,
        &request
    );
    if (status == PJ_SUCCESS && request != NULL) {
        status = pjsip_inv_send_msg(endpoint->invite_session, request);
    }
    if (status != PJ_SUCCESS) {
        copy_status_error(error_buffer, error_buffer_length, "End call", status);
        return false;
    }
    if (endpoint->invite_session != NULL) {
        endpoint->call_state = IP_PJSIP_CALL_DISCONNECTING;
        snprintf(endpoint->call_message, sizeof(endpoint->call_message), "Call termination initiated");
    }
    return true;
}

IPPJSIPCallState ip_pjsip_endpoint_call_state(const IPPJSIPEndpoint *endpoint) {
    return endpoint == NULL ? IP_PJSIP_CALL_IDLE : endpoint->call_state;
}

int ip_pjsip_endpoint_call_status_code(const IPPJSIPEndpoint *endpoint) {
    return endpoint == NULL ? 0 : endpoint->call_status_code;
}

const char *ip_pjsip_endpoint_call_message(const IPPJSIPEndpoint *endpoint) {
    return endpoint == NULL ? "" : endpoint->call_message;
}

const char *ip_pjsip_endpoint_remote_uri(const IPPJSIPEndpoint *endpoint) {
    return endpoint == NULL ? "" : endpoint->remote_uri;
}

IPPJSIPMediaState ip_pjsip_endpoint_media_state(const IPPJSIPEndpoint *endpoint) {
    return endpoint == NULL ? IP_PJSIP_MEDIA_IDLE : endpoint->media_state;
}

const char *ip_pjsip_endpoint_media_message(const IPPJSIPEndpoint *endpoint) {
    return endpoint == NULL ? "" : endpoint->media_message;
}

bool ip_pjsip_endpoint_set_muted(IPPJSIPEndpoint *endpoint, bool muted) {
    if (endpoint == NULL || endpoint->media_stream == NULL) {
        return false;
    }
    pj_status_t status = muted
        ? pjmedia_stream_pause(endpoint->media_stream, PJMEDIA_DIR_ENCODING)
        : pjmedia_stream_resume(endpoint->media_stream, PJMEDIA_DIR_ENCODING);
    if (status == PJ_SUCCESS) {
        endpoint->muted = muted;
        return true;
    }
    return false;
}

bool ip_pjsip_endpoint_is_muted(const IPPJSIPEndpoint *endpoint) {
    return endpoint != NULL && endpoint->muted;
}

static pjmedia_rtcp_stat media_stats(const IPPJSIPEndpoint *endpoint) {
    pjmedia_rtcp_stat stats;
    pj_bzero(&stats, sizeof(stats));
    if (endpoint != NULL && endpoint->media_stream != NULL) {
        pjmedia_stream_get_stat(endpoint->media_stream, &stats);
    }
    return stats;
}

uint32_t ip_pjsip_endpoint_rtp_tx_packets(const IPPJSIPEndpoint *endpoint) {
    return media_stats(endpoint).tx.pkt;
}

uint32_t ip_pjsip_endpoint_rtp_rx_packets(const IPPJSIPEndpoint *endpoint) {
    return media_stats(endpoint).rx.pkt;
}

uint32_t ip_pjsip_endpoint_rtp_rx_lost(const IPPJSIPEndpoint *endpoint) {
    return media_stats(endpoint).rx.loss;
}

uint32_t ip_pjsip_endpoint_rtp_rx_jitter_usec(const IPPJSIPEndpoint *endpoint) {
    int mean = media_stats(endpoint).rx.jitter.mean;
    return mean > 0 ? (uint32_t)mean : 0;
}

bool ip_pjsip_endpoint_send_dtmf(
    IPPJSIPEndpoint *endpoint,
    char digit,
    IPPJSIPDTMFMode requested_mode,
    uint32_t duration_milliseconds,
    IPPJSIPDTMFMode *used_mode,
    char *error_buffer,
    int error_buffer_length
) {
    if (endpoint == NULL || endpoint->media_stream == NULL
        || endpoint->media_state != IP_PJSIP_MEDIA_ACTIVE) {
        copy_error(error_buffer, error_buffer_length, "DTMF requires an active audio call");
        return false;
    }
    if (!((digit >= '0' && digit <= '9') || digit == '*' || digit == '#')) {
        copy_error(error_buffer, error_buffer_length, "Invalid DTMF digit");
        return false;
    }
    if (duration_milliseconds < 40 || duration_milliseconds > 5000) {
        copy_error(error_buffer, error_buffer_length, "DTMF duration must be between 40 and 5000 ms");
        return false;
    }

    IPPJSIPDTMFMode actual_mode = requested_mode;
    if (actual_mode == IP_PJSIP_DTMF_TELEPHONE_EVENT
        && !endpoint->telephone_event_available) {
        actual_mode = IP_PJSIP_DTMF_IN_BAND;
    }
    if (used_mode != NULL) {
        *used_mode = actual_mode;
    }

    pj_status_t status;
    if (actual_mode == IP_PJSIP_DTMF_TELEPHONE_EVENT) {
        char digit_text[] = {digit, '\0'};
        pj_str_t digits = pj_str(digit_text);
        status = pjmedia_stream_dial_dtmf2(
            endpoint->media_stream,
            &digits,
            duration_milliseconds
        );
    } else {
        if (endpoint->muted) {
            copy_error(error_buffer, error_buffer_length, "Unmute the microphone before sending in-band DTMF");
            return false;
        }
        if (endpoint->tone_generator == NULL) {
            copy_error(error_buffer, error_buffer_length, "In-band DTMF generator is unavailable");
            return false;
        }
        pjmedia_tone_digit tone = {
            .digit = digit,
            .on_msec = (short)duration_milliseconds,
            .off_msec = 50,
            .volume = 0
        };
        status = pjmedia_tonegen_play_digits(endpoint->tone_generator, 1, &tone, 0);
    }
    if (status != PJ_SUCCESS) {
        copy_status_error(error_buffer, error_buffer_length, "Send DTMF", status);
        return false;
    }
    pjmedia_tone_digit feedback = {
        .digit = digit,
        .on_msec = (short)duration_milliseconds,
        .off_msec = 50,
        .volume = 0
    };
    // Playback follows the sound port's selected output, including while muted.
    pjmedia_tonegen_play_digits(endpoint->dtmf_inject_port->feedback_generator, 1, &feedback, 0);
    return true;
}

bool ip_pjsip_endpoint_telephone_event_available(const IPPJSIPEndpoint *endpoint) {
    return endpoint != NULL && endpoint->telephone_event_available;
}

bool ip_pjsip_endpoint_pop_sip_log(
    IPPJSIPEndpoint *endpoint,
    char *buffer,
    int buffer_length
) {
    if (endpoint == NULL || buffer == NULL || buffer_length <= 0 || endpoint->sip_log_count == 0) {
        return false;
    }
    snprintf(buffer, (size_t)buffer_length, "%s", endpoint->sip_logs[endpoint->sip_log_head]);
    endpoint->sip_log_head = (endpoint->sip_log_head + 1) % IP_PJSIP_LOG_CAPACITY;
    endpoint->sip_log_count--;
    return true;
}

void ip_pjsip_endpoint_stop(IPPJSIPEndpoint *endpoint) {
    if (endpoint == NULL || !endpoint->pj_initialized) {
        return;
    }

    if (endpoint->sip_endpoint != NULL) {
        if (endpoint->registration_client != NULL) {
            pjsip_regc_destroy(endpoint->registration_client);
            endpoint->registration_client = NULL;
        }
        pjsip_endpt_destroy(endpoint->sip_endpoint);
        endpoint->sip_endpoint = NULL;
    }
    if (active_endpoint == endpoint) {
        active_endpoint = NULL;
    }
    destroy_media(endpoint);
    if (endpoint->opus_initialized) {
        pjmedia_codec_opus_deinit();
        endpoint->opus_initialized = false;
    }
    if (endpoint->g711_initialized) {
        pjmedia_codec_g711_deinit();
        endpoint->g711_initialized = false;
    }
    if (endpoint->media_endpoint != NULL) {
        pjmedia_endpt_destroy(endpoint->media_endpoint);
        endpoint->media_endpoint = NULL;
    }
    if (endpoint->media_event_manager != NULL) {
        pjmedia_event_mgr_destroy(endpoint->media_event_manager);
        endpoint->media_event_manager = NULL;
    }
    if (endpoint->media_pool != NULL) {
        pj_pool_release(endpoint->media_pool);
        endpoint->media_pool = NULL;
    }
    if (endpoint->call_pool != NULL) {
        pj_pool_release(endpoint->call_pool);
        endpoint->call_pool = NULL;
    }
    if (endpoint->pool_initialized) {
        pj_caching_pool_destroy(&endpoint->caching_pool);
        endpoint->pool_initialized = false;
    }
    pj_shutdown();

    endpoint->pj_initialized = false;
    endpoint->running = false;
    endpoint->transport = NULL;
    endpoint->transport_factory = NULL;
    endpoint->bound_port = 0;
}

void ip_pjsip_endpoint_destroy(IPPJSIPEndpoint *endpoint) {
    if (endpoint == NULL) {
        return;
    }
    ip_pjsip_endpoint_stop(endpoint);
    free(endpoint);
}

const char *ip_pjsip_version(void) {
    return pj_get_version();
}
