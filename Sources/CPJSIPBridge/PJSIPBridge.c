#include "PJSIPBridge.h"

#include <pjlib-util.h>
#include <pjnath.h>
#include <pjsip.h>
#include <pjsip_ua.h>
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
    pjsip_regc *registration_client;
    uint16_t bound_port;
    IPPJSIPRegistrationState registration_state;
    int registration_status_code;
    uint32_t registration_expiration;
    char registration_message[256];
};

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
    endpoint->registration_state = IP_PJSIP_REGISTRATION_UNREGISTERED;
    endpoint->running = true;
    return true;
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
    const pjsip_host_port *local = &endpoint->transport->local_name;
    const bool ipv6 = memchr(local->host.ptr, ':', (size_t)local->host.slen) != NULL;
    snprintf(
        contact_buffer,
        sizeof(contact_buffer),
        ipv6 ? "<sip:%s@[%.*s]:%d;transport=udp>" : "<sip:%s@%.*s:%d;transport=udp>",
        user_id,
        (int)local->host.slen,
        local->host.ptr,
        local->port
    );

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
