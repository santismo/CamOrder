#include <AudioUnitSDK/AUEffectBase.h>
#include <AudioUnitSDK/AUPlugInDispatch.h>
#include "CamOrderBridge.h"
#import <AppKit/AppKit.h>
#import <AudioUnit/AUCocoaUIView.h>
#include <atomic>
#include <mutex>
#include <cstring>
#include <cmath>
#include <mach/mach_time.h>

// The render thread publishes only lock-free primitive values. UI/state work is separate.
struct COBridge {
    std::atomic<unsigned> references{1};
    std::atomic<bool> alive{true}, transportInterest{false};
    std::atomic<uint64_t> sequence{0}, revision{0}, renderCount{0}, callbackFailures{0};
    std::atomic<double> lastAttemptSeconds{0};
    std::atomic<int32_t> callbackStatus{0};
    std::atomic<uint32_t> callbackVersion{0};
    std::atomic<double> seconds{0}, tempo{120}, beat{0}, hostSeconds{0}, lastRenderSeconds{0};
    std::atomic<double> startSeconds{0}, startHostSeconds{0};
    std::atomic<uint32_t> frames{0}, playing{0}, recording{0}, valid{0};
    std::mutex stateMutex;
    CFDataRef state = nullptr;
    CFTypeRef session = nullptr; // main thread only
    ~COBridge() { if (state) CFRelease(state); }
};
static_assert(std::atomic<double>::is_always_lock_free);
static_assert(std::atomic<uint64_t>::is_always_lock_free);
void CORetainBridge(COBridge *b) { ++b->references; }
void COReleaseBridge(COBridge *b) { if (--b->references == 0) delete b; }
void COSetTransportInterest(COBridge *b, bool interested) { b->transportInterest = interested; }
bool COBridgeIsAlive(COBridge *b) { return b->alive.load(); }
uint64_t COStateRevision(COBridge *b) { return b->revision.load(); }
bool COReadTransport(COBridge *b, COTransport *s) {
    for (int attempt = 0; attempt < 4; ++attempt) {
        auto sequence = b->sequence.load();
        if (sequence & 1) continue;
        s->seconds = b->seconds.load(); s->tempo = b->tempo.load(); s->beat = b->beat.load();
        s->hostSeconds = b->hostSeconds.load(); s->lastRenderSeconds = b->lastRenderSeconds.load();
        s->startSeconds = b->startSeconds.load(); s->startHostSeconds = b->startHostSeconds.load();
        s->frames = b->frames.load(); s->playing = b->playing.load();
        s->recording = b->recording.load(); s->valid = b->valid.load();
        s->renderCount = b->renderCount.load(); s->callbackFailures = b->callbackFailures.load();
        s->lastAttemptSeconds = b->lastAttemptSeconds.load(); s->callbackStatus = b->callbackStatus.load();
        s->callbackVersion = b->callbackVersion.load();
        if (sequence == b->sequence.load()) return true;
    }
    return false;
}
CFDataRef COCopyState(COBridge *b) {
    std::lock_guard<std::mutex> guard(b->stateMutex);
    return b->state ? (CFDataRef)CFRetain(b->state) : nullptr;
}
void COSetState(COBridge *b, CFDataRef data) {
    std::lock_guard<std::mutex> guard(b->stateMutex);
    if ((!data && !b->state) || (data && b->state && CFEqual(data, b->state))) return;
    if (data) CFRetain(data);
    if (b->state) CFRelease(b->state);
    b->state = data;
    ++b->revision;
}
CFTypeRef COGetSession(COBridge *b) { return b->session; }
void COSetSession(COBridge *b, CFTypeRef session) {
    if (session) CFRetain(session);
    if (b->session) CFRelease(b->session);
    b->session = session;
}

extern "C" void *CamOrderCreateView(COBridge *bridge);
extern "C" void CamOrderCloseSession(CFTypeRef session);
@interface CamOrderStudioAUViewFactory : NSObject <AUCocoaUIBase>
@end
@implementation CamOrderStudioAUViewFactory
- (unsigned)interfaceVersion { return 0; }
- (NSString *)description { return @"CamOrder Studio"; }
- (NSView *)uiViewForAudioUnit:(AudioUnit)unit withSize:(NSSize)size {
    COBridge *bridge = nullptr;
    UInt32 bytes = sizeof(bridge);
    if (AudioUnitGetProperty(unit, kCamOrderBridgeProperty, kAudioUnitScope_Global, 0, &bridge, &bytes) != noErr) return nil;
    return CFBridgingRelease(CamOrderCreateView(bridge));
}
@end

class CamOrderStudioAU : public ausdk::AUEffectBase {
    COBridge *bridge = new COBridge;
    double ticksToSeconds = 0;
    bool renderingViaRender = false; // audio thread only
public:
    explicit CamOrderStudioAU(AudioComponentInstance instance) : AUEffectBase(instance, true) {
        CreateElements();
        mach_timebase_info_data_t info;
        mach_timebase_info(&info);
        ticksToSeconds = double(info.numer) / double(info.denom) / 1e9;
    }
    ~CamOrderStudioAU() override {
        bridge->alive = false;
        // Timer can still read the retained bridge, never a disposed AudioUnit pointer.
        auto retained = bridge;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (auto session = retained->session) CamOrderCloseSession(session);
            COSetSession(retained, nullptr);
            COReleaseBridge(retained);
        });
    }
    UInt32 SupportedNumChannels(const AUChannelInfo **info) override {
        static const AUChannelInfo channels[] = {{1,1}, {2,2}};
        if (info) *info = channels;
        return 2;
    }
    bool SupportsTail() override { return true; }
    void publishTransport(const AudioTimeStamp &time, UInt32 frames) {
        Boolean playing = false, changed = false, cycling = false, recording = false;
        Float64 sample = 0, cycleStart = 0, cycleEnd = 0, beat = 0, tempo = 120;
        // Prefer the established AUv2 transport callback. The recording extension is
        // unnecessary: either Play or Record starts an armed video take.
        auto result = CallHostTransportState(&playing, &changed, &sample, &cycling, &cycleStart, &cycleEnd);
        uint32_t version = 1;
        auto &callbacks = GetHostCallbackInfo();
        if ((result != noErr || !std::isfinite(sample)) && callbacks.transportStateProc2) {
            version = 2;
            result = callbacks.transportStateProc2(callbacks.hostUserData, &playing, &recording,
                &changed, &sample, &cycling, &cycleStart, &cycleEnd);
        }
        const double now = mach_absolute_time() * ticksToSeconds;
        ++bridge->sequence;
        ++bridge->renderCount;
        bridge->lastAttemptSeconds = now;
        bridge->callbackStatus = result;
        bridge->callbackVersion = version;
        if (result != noErr || !std::isfinite(sample)) {
            ++bridge->callbackFailures;
            ++bridge->sequence;
            return; // Preserve the last good position; failure is not a Stop command.
        }
        CallHostBeatAndTempo(&beat, &tempo);
        bridge->seconds = sample / GetSampleRate();
        bridge->tempo = tempo; bridge->beat = beat;
        bridge->hostSeconds = (time.mFlags & kAudioTimeStampHostTimeValid) && time.mHostTime != 0
            ? time.mHostTime * ticksToSeconds : now;
        const bool resumedAfterGap = now - bridge->lastRenderSeconds.load() > 0.5;
        bridge->lastRenderSeconds = now;
        bridge->frames = frames;
        // A suspended channel may miss Stop and the next Play entirely. Its old
        // start anchor must not place a new take using that unobserved interval.
        if (playing && (!bridge->playing.load() || resumedAfterGap)) {
            bridge->startSeconds = sample / GetSampleRate();
            bridge->startHostSeconds = bridge->hostSeconds.load();
        }
        bridge->playing = playing; bridge->recording = recording;
        bridge->valid = true;
        ++bridge->sequence;
    }
    OSStatus Render(AudioUnitRenderActionFlags &flags, const AudioTimeStamp &time, UInt32 frames) override {
        renderingViaRender = true;
        const auto result = AUEffectBase::Render(flags, time, frames);
        renderingViaRender = false;
        // Query while still inside the render call, after the host supplied input.
        if (result == noErr) publishTransport(time, frames);
        if (bridge->transportInterest.load() && !ShouldBypassEffect()) flags &= ~kAudioUnitRenderAction_OutputIsSilence;
        return result;
    }
    OSStatus ProcessBufferLists(AudioUnitRenderActionFlags &flags, const AudioBufferList &input,
                                AudioBufferList &output, UInt32 frames) override {
        // AudioUnitProcess is a separate host entry point; it never calls Render.
        if (!renderingViaRender) publishTransport(CurrentRenderTime(), frames);
        for (UInt32 i = 0; i < output.mNumberBuffers; ++i) {
            const auto &source = input.mBuffers[i];
            auto &target = output.mBuffers[i];
            if (target.mData != source.mData) std::memcpy(target.mData, source.mData, source.mDataByteSize);
            target.mDataByteSize = source.mDataByteSize;
        }
        // Keep transport processing active for a video project, including silent
        // audio. Samples remain bit-for-bit unchanged; no keep-alive sound is added.
        if (bridge->transportInterest.load() && !ShouldBypassEffect()) flags &= ~kAudioUnitRenderAction_OutputIsSilence;
        return noErr;
    }
    OSStatus GetPropertyInfo(AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement element, UInt32 &size, bool &writable) override {
        if (scope == kAudioUnitScope_Global && element == 0) {
            if (id == kCamOrderBridgeProperty) { size = sizeof(COBridge *); writable = false; return noErr; }
            if (id == kAudioUnitProperty_CocoaUI) { size = sizeof(AudioUnitCocoaViewInfo); writable = false; return noErr; }
        }
        return AUEffectBase::GetPropertyInfo(id, scope, element, size, writable);
    }
    OSStatus GetProperty(AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement element, void *data) override {
        if (scope == kAudioUnitScope_Global && element == 0) {
            if (id == kCamOrderBridgeProperty) { *(COBridge **)data = bridge; return noErr; }
            if (id == kAudioUnitProperty_CocoaUI) {
                auto *info = (AudioUnitCocoaViewInfo *)data;
                info->mCocoaAUViewBundleLocation = (CFURLRef)CFBridgingRetain([NSBundle bundleForClass:CamOrderStudioAUViewFactory.class].bundleURL);
                info->mCocoaAUViewClass[0] = (CFStringRef)CFRetain(CFSTR("CamOrderStudioAUViewFactory"));
                return noErr;
            }
        }
        return AUEffectBase::GetProperty(id, scope, element, data);
    }
    OSStatus SaveState(CFPropertyListRef *out) override {
        auto status = AUEffectBase::SaveState(out);
        if (status != noErr) return status;
        auto state = COCopyState(bridge);
        if (state) { CFDictionarySetValue((CFMutableDictionaryRef)*out, CFSTR("CamOrderProject"), state); CFRelease(state); }
        return noErr;
    }
    OSStatus RestoreState(CFPropertyListRef data) override {
        auto status = AUEffectBase::RestoreState(data);
        if (status != noErr) return status;
        auto state = (CFDataRef)CFDictionaryGetValue((CFDictionaryRef)data, CFSTR("CamOrderProject"));
        if (state && CFGetTypeID(state) != CFDataGetTypeID()) return kAudioUnitErr_InvalidPropertyValue;
        COSetState(bridge, state);
        return noErr;
    }
};
AUSDK_COMPONENT_ENTRY(ausdk::AUBaseProcessFactory, CamOrderStudioAU)
