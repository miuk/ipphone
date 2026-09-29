#include "PJSIPBridge.h"

#include <pjlib-util.h>
#include <pj/rand.h>
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
    pjsip_inv_session *invite_session;
    pjsip_module app_module;
    pj_pool_t *call_pool;
    uint16_t bound_port;
    IPPJSIPRegistrationState registration_state;
    int registration_status_code;
    uint32_t registration_expiration;
    char registration_message[256];
    IPPJSIPCallState call_state;
    int call_status_code;
    char call_message[256];
    char remote_uri[PJSIP_MAX_URL_SIZE];
    bool local_termination;
};

static IPPJSIPEndpoint *active_endpoint = NULL;
static pjsip_inv_callback invite_callbacks;

static pjmedia_sdp_session *create_inactive_sdp(
    IPPJSIPEndpoint *endpoint,
    uint16_t rtp_port
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

    const pjsip_host_port *local = &endpoint->transport->local_name;
    const bool ipv6 = memchr(local->host.ptr, ':', (size_t)local->host.slen) != NULL;
    char text[1024];
    int length = snprintf(
        text,
        sizeof(text),
        "v=0\r\n"
        "o=- %u %u IN %s %.*s\r\n"
        "s=IPPhone\r\n"
        "c=IN %s %.*s\r\n"
        "t=0 0\r\n"
        "m=audio %u RTP/AVP 0\r\n"
        "a=rtpmap:0 PCMU/8000\r\n"
        "a=inactive\r\n",
        (unsigned)pj_rand(),
        (unsigned)pj_rand(),
        ipv6 ? "IP6" : "IP4",
        (int)local->host.slen,
        local->host.ptr,
        ipv6 ? "IP6" : "IP4",
        (int)local->host.slen,
        local->host.ptr,
        (unsigned)rtp_port
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
        endpoint->call_state = endpoint->local_termination || invite->cause < 300
            ? IP_PJSIP_CALL_ENDED
            : IP_PJSIP_CALL_FAILED;
        endpoint->invite_session = NULL;
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
    PJ_UNUSED_ARG(offer);
    IPPJSIPEndpoint *endpoint = active_endpoint;
    if (endpoint == NULL || endpoint->invite_session != invite) {
        return;
    }
    pjmedia_sdp_session *answer = create_inactive_sdp(endpoint, 9);
    if (answer != NULL) {
        pjsip_inv_set_sdp_answer(invite, answer);
    }
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

    pjsip_dialog *dialog = NULL;
    pj_status_t status = pjsip_dlg_create_uas_and_inc_lock(
        pjsip_ua_instance(),
        rdata,
        NULL,
        &dialog
    );
    if (status != PJ_SUCCESS) {
        pjsip_endpt_respond_stateless(endpoint->sip_endpoint, rdata, 500, NULL, NULL, NULL);
        return PJ_TRUE;
    }

    pjmedia_sdp_session *sdp = create_inactive_sdp(endpoint, 9);
    status = pjsip_inv_create_uas(dialog, rdata, sdp, 0, &endpoint->invite_session);
    if (status != PJ_SUCCESS) {
        pjsip_dlg_dec_lock(dialog);
        pjsip_endpt_respond_stateless(endpoint->sip_endpoint, rdata, 500, NULL, NULL, NULL);
        return PJ_TRUE;
    }

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
    status = pjsip_inv_usage_init(endpoint->sip_endpoint, &invite_callbacks);
    if (status != PJ_SUCCESS) {
        copy_status_error(error_buffer, error_buffer_length, "pjsip_inv_usage_init", status);
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

bool ip_pjsip_endpoint_make_call(
    IPPJSIPEndpoint *endpoint,
    const char *local_uri,
    const char *destination_uri,
    const char *target_uri,
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

    pjmedia_sdp_session *sdp = create_inactive_sdp(endpoint, rtp_port);
    if (sdp == NULL) {
        copy_error(error_buffer, error_buffer_length, "Unable to create local SDP");
        return false;
    }

    const pjsip_host_port *local = &endpoint->transport->local_name;
    const bool ipv6 = memchr(local->host.ptr, ':', (size_t)local->host.slen) != NULL;
    char contact_buffer[PJSIP_MAX_URL_SIZE];
    snprintf(
        contact_buffer,
        sizeof(contact_buffer),
        ipv6 ? "<sip:%s@[%.*s]:%d;transport=udp>" : "<sip:%s@%.*s:%d;transport=udp>",
        user_id,
        (int)local->host.slen,
        local->host.ptr,
        local->port
    );
    pj_str_t local_uri_string = pj_str((char *)local_uri);
    pj_str_t contact = pj_str(contact_buffer);
    pj_str_t remote_uri = pj_str((char *)destination_uri);
    pj_str_t target = pj_str((char *)target_uri);
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
