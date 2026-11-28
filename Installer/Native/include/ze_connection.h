#ifndef ZE_CONNECTION_H
#define ZE_CONNECTION_H
#include <stdint.h>
// Each session is confined to one serial worker. cancel is the only concurrent
// operation. Call free only after run has returned. All bytes stay in memory.
typedef struct ZeSession ZeSession;
typedef void (*ZeEvent)(void *context, int32_t event, const char *ephemeral_pin);
ZeSession *ze_connection_new(void);
void ze_connection_cancel(const ZeSession *session);
void ze_connection_free(ZeSession *session);
// Input <=128KiB, NUL terminated JSON. Output allocated, free using string_free.
// prepare:{saved: envelope|null, allowNewIdentity: bool}; listen:{}; pair:{}; connect:{};
// query:{requestID: UUID}. No arbitrary service/key/domain inputs are accepted.
char *ze_connection_run(ZeSession *session, const char *operation, const char *input,
                        ZeEvent event, void *context);
void ze_connection_string_free(char *value);
// Event 1 PIN (never evidence), 2 TCP, 3 pair-verify, 4 TLS-PSK/CDTunnel,
// 5 RSD required service present. No event signifies query success.
#endif
