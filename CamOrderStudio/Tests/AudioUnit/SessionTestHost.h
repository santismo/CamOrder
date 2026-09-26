#pragma once
#include "CamOrderBridge.h"
#ifdef __cplusplus
extern "C" {
#endif
void *COTestHostCreate(void);
COBridge *COTestHostBridge(void *host);
int32_t COTestHostRender(void *host, double seconds, bool playing, bool recording);
void COTestHostDispose(void *host);
#ifdef __cplusplus
}
#endif
