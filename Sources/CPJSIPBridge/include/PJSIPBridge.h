#ifndef PJSIP_BRIDGE_H
#define PJSIP_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct IPPJSIPEndpoint IPPJSIPEndpoint;

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
