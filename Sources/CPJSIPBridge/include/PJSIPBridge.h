#ifndef PJSIP_BRIDGE_H
#define PJSIP_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct IPPJSIPEndpoint IPPJSIPEndpoint;

typedef enum IPPJSIPRegistrationState {
    IP_PJSIP_REGISTRATION_UNREGISTERED = 0,
    IP_PJSIP_REGISTRATION_REGISTERING = 1,
    IP_PJSIP_REGISTRATION_REGISTERED = 2,
    IP_PJSIP_REGISTRATION_UNREGISTERING = 3,
    IP_PJSIP_REGISTRATION_FAILED = 4
} IPPJSIPRegistrationState;

/// Creates an inert endpoint handle. Call `ip_pjsip_endpoint_start_udp` to
/// initialize PJSIP and create a UDP transport.
IPPJSIPEndpoint *ip_pjsip_endpoint_create(void);

/// Initializes PJSIP and starts a UDP transport. Pass 0 to let the operating
/// system select the local SIP port.
bool ip_pjsip_endpoint_start_udp(
    IPPJSIPEndpoint *endpoint,
    uint16_t port,
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
