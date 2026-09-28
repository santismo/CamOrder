#pragma once
#include "CamOrderBridge.h"
#ifdef __cplusplus
extern "C" {
#endif
void *COTestHostCreate(void);
COBridge *COTestHostBridge(void *host);
void COTestHostSetTempo(void *host, double tempo, double beatZeroSeconds, bool available);
int32_t COTestHostRender(void *host, double seconds, bool playing, bool recording);
int32_t COTestHostRestoreProject(void *host, CFDataRef data);
void COTestHostDispose(void *host);
#ifdef __cplusplus
}
#endif
