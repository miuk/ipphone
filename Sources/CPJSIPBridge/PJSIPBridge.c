#include "PJSIPBridge.h"

#include <pjlib-util.h>
#include <pjnath.h>
#include <pjsip.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct IPPJSIPEndpoint {
    bool pj_initialized;
    bool pool_initialized;
    bool running;
    pj_caching_pool caching_pool;
    pjsip_endpoint *sip_endpoint;
    pjsip_transport *transport;
    uint16_t bound_port;
};

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
    return calloc(1, sizeof(IPPJSIPEndpoint));
}

bool ip_pjsip_endpoint_start_udp(
    IPPJSIPEndpoint *endpoint,
    uint16_t port,
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

    pj_sockaddr_in address;
    pj_sockaddr_in_init(&address, NULL, port);
    status = pjsip_udp_transport_start(
        endpoint->sip_endpoint,
        &address,
        NULL,
        1,
        &endpoint->transport
    );
    if (status != PJ_SUCCESS) {
        copy_status_error(
            error_buffer,
            error_buffer_length,
            "pjsip_udp_transport_start",
            status
        );
        ip_pjsip_endpoint_stop(endpoint);
        return false;
    }

    endpoint->bound_port = (uint16_t)endpoint->transport->local_name.port;
    endpoint->running = true;
    return true;
}

uint16_t ip_pjsip_endpoint_bound_port(const IPPJSIPEndpoint *endpoint) {
    if (endpoint == NULL || !endpoint->running) {
        return 0;
    }
    return endpoint->bound_port;
}

void ip_pjsip_endpoint_stop(IPPJSIPEndpoint *endpoint) {
    if (endpoint == NULL || !endpoint->pj_initialized) {
        return;
    }

    if (endpoint->sip_endpoint != NULL) {
        pjsip_endpt_destroy(endpoint->sip_endpoint);
        endpoint->sip_endpoint = NULL;
    }
    if (endpoint->pool_initialized) {
        pj_caching_pool_destroy(&endpoint->caching_pool);
        endpoint->pool_initialized = false;
    }
    pj_shutdown();

    endpoint->pj_initialized = false;
    endpoint->running = false;
    endpoint->transport = NULL;
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
