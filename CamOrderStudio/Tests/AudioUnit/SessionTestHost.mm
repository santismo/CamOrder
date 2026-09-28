#include "SessionTestHost.h"
#import <AudioToolbox/AudioToolbox.h>
#include <mach/mach_time.h>
#include <cstdlib>
extern "C" AudioComponentPlugInInterface *CamOrderStudioAUFactory(const AudioComponentDescription *);
struct TestHost {
    AudioUnit unit = nullptr;
    COBridge *bridge = nullptr;
    double seconds = 0, renderSample = 0;
    bool playing = false, recording = false, inputReady = false;
};
static OSStatus transport(void *context, Boolean *playing, Boolean *changed, Float64 *sample, Boolean *cycling, Float64 *start, Float64 *end) {
    auto &host = *(TestHost *)context;
    if (!host.inputReady) return kAudioUnitErr_CannotDoInCurrentContext;
    if (playing) *playing = host.playing;
    if (changed) *changed = false;
    if (sample) *sample = host.seconds * 48000;
    if (cycling) *cycling = false;
    if (start) *start = 0; if (end) *end = 0;
    return noErr;
}
static OSStatus input(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *, UInt32, UInt32 frames, AudioBufferList *buffers) {
    ((TestHost *)context)->inputReady = true;
    *flags |= kAudioUnitRenderAction_OutputIsSilence;
    for (unsigned c = 0; c < buffers->mNumberBuffers; ++c) {
        memset(buffers->mBuffers[c].mData, 0, frames * sizeof(float));
        buffers->mBuffers[c].mDataByteSize = frames * sizeof(float);
    }
    return noErr;
}
void *COTestHostCreate() {
    auto *host = new TestHost;
    AudioComponentDescription description = {kAudioUnitType_Effect, 'CmSt', 'Sntm', 0, 0};
    static auto component = AudioComponentRegister(&description, CFSTR("CamOrder Session Test"), 0x502, CamOrderStudioAUFactory);
    if (!component || AudioComponentInstanceNew(component, &host->unit)) abort();
    AudioStreamBasicDescription format = {48000, kAudioFormatLinearPCM, kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved, 4, 1, 4, 2, 32, 0};
    if (AudioUnitSetProperty(host->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof(format)) ||
        AudioUnitSetProperty(host->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, sizeof(format))) abort();
    HostCallbackInfo callbacks = {}; callbacks.hostUserData = host; callbacks.transportStateProc = transport;
    AURenderCallbackStruct render = {input, host};
    AudioUnitSetProperty(host->unit, kAudioUnitProperty_HostCallbacks, kAudioUnitScope_Global, 0, &callbacks, sizeof(callbacks));
    AudioUnitSetProperty(host->unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &render, sizeof(render));
    if (AudioUnitInitialize(host->unit)) abort();
    UInt32 bytes = sizeof(host->bridge);
    if (AudioUnitGetProperty(host->unit, kCamOrderBridgeProperty, kAudioUnitScope_Global, 0, &host->bridge, &bytes)) abort();
    return host;
}
COBridge *COTestHostBridge(void *value) { return ((TestHost *)value)->bridge; }
int32_t COTestHostRender(void *value, double seconds, bool playing, bool recording) {
    auto &host = *(TestHost *)value;
    host.seconds = seconds; host.playing = playing; host.recording = recording; host.inputReady = false;
    AudioTimeStamp timestamp = {}; timestamp.mSampleTime = host.renderSample; host.renderSample += 512;
    timestamp.mHostTime = mach_absolute_time(); timestamp.mFlags = kAudioTimeStampSampleTimeValid | kAudioTimeStampHostTimeValid;
    struct { UInt32 count; AudioBuffer buffers[2]; } buffers = {2, {{1, 0, nullptr}, {1, 0, nullptr}}};
    AudioUnitRenderActionFlags flags = 0;
    return AudioUnitRender(host.unit, &flags, &timestamp, 0, 512, (AudioBufferList *)&buffers);
}
int32_t COTestHostRestoreProject(void *value, CFDataRef data) {
    auto &host = *(TestHost *)value;
    CFPropertyListRef original = nullptr;
    UInt32 size = sizeof(original);
    auto result = AudioUnitGetProperty(host.unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &original, &size);
    if (result != noErr) return result;
    auto state = CFDictionaryCreateMutableCopy(nullptr, 0, (CFDictionaryRef)original);
    CFDictionarySetValue(state, CFSTR("CamOrderProject"), data);
    result = AudioUnitSetProperty(host.unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &state, sizeof(state));
    CFRelease(state); CFRelease(original);
    return result;
}
void COTestHostDispose(void *value) {
    auto *host = (TestHost *)value;
    AudioUnitUninitialize(host->unit);
    AudioComponentInstanceDispose(host->unit);
    delete host;
}
