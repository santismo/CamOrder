#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct COBridge COBridge;
typedef struct {
    double seconds, tempo, beat, hostSeconds;
    double lastRenderSeconds, startSeconds, startHostSeconds;
    uint32_t frames, playing, recording, valid;
    uint64_t renderCount, callbackFailures;
    double lastAttemptSeconds;
    int32_t callbackStatus;
    uint32_t callbackVersion;
} COTransport;
enum { kCamOrderBridgeProperty = 64000 };
void CORetainBridge(COBridge *bridge);
void COReleaseBridge(COBridge *bridge);
void COSetTransportInterest(COBridge *bridge, bool interested);
bool COReadTransport(COBridge *bridge, COTransport *result);
bool COBridgeIsAlive(COBridge *bridge);
CFDataRef COCopyState(COBridge *bridge) CF_RETURNS_RETAINED;
void COSetState(COBridge *bridge, CFDataRef state);
uint64_t COStateRevision(COBridge *bridge);
CFTypeRef COGetSession(COBridge *bridge);
void COSetSession(COBridge *bridge, CFTypeRef session);
#ifdef __cplusplus
}
#endif
