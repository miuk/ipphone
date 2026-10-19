#ifndef PJSIP_BRIDGE_H
#define PJSIP_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct IPPJSIPEndpoint IPPJSIPEndpoint;

typedef enum IPPJSIPTransport {
    IP_PJSIP_TRANSPORT_UDP = 0,
    IP_PJSIP_TRANSPORT_TCP = 1,
    IP_PJSIP_TRANSPORT_TLS = 2
} IPPJSIPTransport;

typedef enum IPPJSIPRegistrationState {
    IP_PJSIP_REGISTRATION_UNREGISTERED = 0,
    IP_PJSIP_REGISTRATION_REGISTERING = 1,
    IP_PJSIP_REGISTRATION_REGISTERED = 2,
    IP_PJSIP_REGISTRATION_UNREGISTERING = 3,
    IP_PJSIP_REGISTRATION_FAILED = 4
} IPPJSIPRegistrationState;

typedef enum IPPJSIPCallState {
    IP_PJSIP_CALL_IDLE = 0,
    IP_PJSIP_CALL_OUTGOING = 1,
    IP_PJSIP_CALL_RINGING = 2,
    IP_PJSIP_CALL_INCOMING = 3,
    IP_PJSIP_CALL_CONNECTED = 4,
    IP_PJSIP_CALL_DISCONNECTING = 5,
    IP_PJSIP_CALL_ENDED = 6,
    IP_PJSIP_CALL_FAILED = 7
} IPPJSIPCallState;

typedef enum IPPJSIPMediaState {
    IP_PJSIP_MEDIA_IDLE = 0,
    IP_PJSIP_MEDIA_STARTING = 1,
    IP_PJSIP_MEDIA_ACTIVE = 2,
    IP_PJSIP_MEDIA_FAILED = 3
} IPPJSIPMediaState;

typedef enum IPPJSIPDTMFMode {
    IP_PJSIP_DTMF_TELEPHONE_EVENT = 0,
    IP_PJSIP_DTMF_IN_BAND = 1
} IPPJSIPDTMFMode;

/// Creates an inert endpoint handle. Call `ip_pjsip_endpoint_start_udp` to
/// initialize PJSIP and create a UDP transport.
IPPJSIPEndpoint *ip_pjsip_endpoint_create(void);

/// Initializes PJSIP and starts a UDP transport. Pass 0 to let the operating
/// system select the local SIP port.
bool ip_pjsip_endpoint_start_udp(
    IPPJSIPEndpoint *endpoint,
    uint16_t port,
    uint16_t rtp_port,
    int audio_input_device,
    int audio_output_device,
    char *error_buffer,
    int error_buffer_length
);

/// Initializes PJSIP and starts the selected SIP transport. TLS uses TLS
/// 1.2/1.3 and verifies the server certificate unless explicitly disabled.
/// local_ip_address is the bind and published address, or NULL for automatic.
bool ip_pjsip_endpoint_start(
    IPPJSIPEndpoint *endpoint,
    IPPJSIPTransport transport,
    uint16_t port,
    uint16_t rtp_port,
    int audio_input_device,
    int audio_output_device,
    bool allow_self_signed_certificate,
    const char *local_ip_address,
    char *error_buffer,
    int error_buffer_length
);

/// Returns the bound UDP port, or 0 when the endpoint is not running.
uint16_t ip_pjsip_endpoint_bound_port(const IPPJSIPEndpoint *endpoint);

/// Processes pending SIP messages and timers without blocking.
void ip_pjsip_endpoint_poll(IPPJSIPEndpoint *endpoint);

/// Starts REGISTER with Digest authentication and automatic refresh.
bool ip_pjsip_endpoint_register(
    IPPJSIPEndpoint *endpoint,
    const char *registrar_uri,
    const char *address_of_record,
    const char *user_id,
    const char *password,
    uint32_t expiration,
    char *error_buffer,
    int error_buffer_length
);

/// Sends REGISTER with Expires: 0 for the current registration.
bool ip_pjsip_endpoint_unregister(
    IPPJSIPEndpoint *endpoint,
    char *error_buffer,
    int error_buffer_length
);

IPPJSIPRegistrationState ip_pjsip_endpoint_registration_state(
    const IPPJSIPEndpoint *endpoint
);
int ip_pjsip_endpoint_registration_status_code(const IPPJSIPEndpoint *endpoint);
uint32_t ip_pjsip_endpoint_registration_expiration(const IPPJSIPEndpoint *endpoint);
const char *ip_pjsip_endpoint_registration_message(const IPPJSIPEndpoint *endpoint);

/// Sends an outgoing INVITE with PCMU and telephone-event media capabilities.
bool ip_pjsip_endpoint_make_call(
    IPPJSIPEndpoint *endpoint,
    const char *local_uri,
    const char *destination_uri,
    const char *target_uri,
    bool uses_explicit_uri,
    const char *user_id,
    const char *password,
    uint16_t rtp_port,
    char *error_buffer,
    int error_buffer_length
);

/// Answers the current incoming INVITE with 200 OK.
bool ip_pjsip_endpoint_answer_call(
    IPPJSIPEndpoint *endpoint,
    char *error_buffer,
    int error_buffer_length
);

/// Ends an outgoing, incoming, or established call using the appropriate
/// SIP message (CANCEL, final response, or BYE).
bool ip_pjsip_endpoint_end_call(
    IPPJSIPEndpoint *endpoint,
    int status_code,
    char *error_buffer,
    int error_buffer_length
);

IPPJSIPCallState ip_pjsip_endpoint_call_state(const IPPJSIPEndpoint *endpoint);
int ip_pjsip_endpoint_call_status_code(const IPPJSIPEndpoint *endpoint);
const char *ip_pjsip_endpoint_call_message(const IPPJSIPEndpoint *endpoint);
const char *ip_pjsip_endpoint_remote_uri(const IPPJSIPEndpoint *endpoint);

IPPJSIPMediaState ip_pjsip_endpoint_media_state(const IPPJSIPEndpoint *endpoint);
const char *ip_pjsip_endpoint_media_message(const IPPJSIPEndpoint *endpoint);
bool ip_pjsip_endpoint_set_muted(IPPJSIPEndpoint *endpoint, bool muted);
bool ip_pjsip_endpoint_is_muted(const IPPJSIPEndpoint *endpoint);
uint32_t ip_pjsip_endpoint_rtp_tx_packets(const IPPJSIPEndpoint *endpoint);
uint32_t ip_pjsip_endpoint_rtp_rx_packets(const IPPJSIPEndpoint *endpoint);
uint32_t ip_pjsip_endpoint_rtp_rx_lost(const IPPJSIPEndpoint *endpoint);
uint32_t ip_pjsip_endpoint_rtp_rx_jitter_usec(const IPPJSIPEndpoint *endpoint);

/// Sends one DTMF digit for the active call. If telephone-event is requested
/// but was not negotiated, the digit is sent in-band and `used_mode` reports
/// the fallback. Successful sends also play the digit on the call's audio
/// output device as local feedback, independently of microphone muting.
bool ip_pjsip_endpoint_send_dtmf(
    IPPJSIPEndpoint *endpoint,
    char digit,
    IPPJSIPDTMFMode requested_mode,
    uint32_t duration_milliseconds,
    IPPJSIPDTMFMode *used_mode,
    char *error_buffer,
    int error_buffer_length
);
bool ip_pjsip_endpoint_telephone_event_available(const IPPJSIPEndpoint *endpoint);

/// Removes the oldest sanitized SIP message summary from the diagnostic
/// queue. Message bodies and authentication header values are never stored.
bool ip_pjsip_endpoint_pop_sip_log(
    IPPJSIPEndpoint *endpoint,
    char *buffer,
    int buffer_length
);

/// Stops PJSIP. Safe to call more than once.
void ip_pjsip_endpoint_stop(IPPJSIPEndpoint *endpoint);

/// Stops PJSIP and releases the endpoint handle.
void ip_pjsip_endpoint_destroy(IPPJSIPEndpoint *endpoint);

/// Returns the linked PJSIP version string.
const char *ip_pjsip_version(void);

#ifdef __cplusplus
}
#endif

#endif
