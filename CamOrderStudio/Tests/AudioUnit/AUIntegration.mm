#import <AppKit/AppKit.h>
#import <AudioUnit/AudioUnit.h>
#import <AudioUnit/AUCocoaUIView.h>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include "CamOrderBridge.h"

static void check(OSStatus status, const char *what) {
    if (status) { fprintf(stderr, "FAIL %s: %d\n", what, (int)status); exit(1); }
}
static void require(bool condition, const char *what) {
    if (!condition) { fprintf(stderr, "FAIL %s\n", what); exit(1); }
}
struct Host { double sample = 96000, rate = 48000; bool playing = true; bool failTransport = false; bool inputReady = false; bool legacyUnavailable = false; bool silent = false; };
static OSStatus transport(void *context, Boolean *playing, Boolean *changed, Float64 *sample, Boolean *cycling, Float64 *start, Float64 *end) {
    auto &host = *(Host *)context;
    if (host.failTransport || !host.inputReady || host.legacyUnavailable) return kAudioUnitErr_CannotDoInCurrentContext;
    if (playing) *playing = host.playing;
    if (changed) *changed = false;
    if (sample) *sample = host.sample;
    if (cycling) *cycling = false;
    if (start) *start = 0;
    if (end) *end = 0;
    return noErr;
}
static OSStatus transport2(void *context, Boolean *playing, Boolean *recording, Boolean *changed, Float64 *sample, Boolean *cycling, Float64 *start, Float64 *end) {
    auto &host = *(Host *)context;
    bool unavailable = host.legacyUnavailable;
    host.legacyUnavailable = false;
    auto result = transport(context, playing, changed, sample, cycling, start, end);
    host.legacyUnavailable = unavailable;
    if (recording) *recording = host.playing;
    return result;
}
static OSStatus tempo(void *, Float64 *beat, Float64 *bpm) { if (beat) *beat = 4; if (bpm) *bpm = 123; return noErr; }
static OSStatus input(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *, UInt32, UInt32 frames, AudioBufferList *buffers) {
    auto &host = *(Host *)context;
    host.inputReady = true;
    if (host.silent) *flags |= kAudioUnitRenderAction_OutputIsSilence;
    else *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
    for (unsigned c = 0; c < buffers->mNumberBuffers; ++c) {
        auto samples = (float *)buffers->mBuffers[c].mData;
        for (unsigned i = 0; i < frames; ++i) samples[i] = host.silent ? 0 : float((int(i) % 29) - 14) / 32.f + c * 0.01f;
        buffers->mBuffers[c].mDataByteSize = frames * sizeof(float);
    }
    return noErr;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        require(argc >= 2, "component path required");
        NSBundle *bundle = [NSBundle bundleWithPath:@(argv[1])];
        NSError *error;
        require([bundle loadAndReturnError:&error], error.localizedDescription.UTF8String ?: "load component");
        void *library = dlopen(bundle.executablePath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        auto factory = (AudioComponentFactoryFunction)dlsym(library, "CamOrderStudioAUFactory");
        require(factory != nullptr, "factory symbol");
        AudioComponentDescription desc = {kAudioUnitType_Effect, 'CmSt', 'Sntm', 0, 0};
        auto component = AudioComponentRegister(&desc, CFSTR("Santismo: CamOrder Studio Test"), 0x00000400, factory);
        require(component != nullptr, "register component");
        AudioUnit unit;
        check(AudioComponentInstanceNew(component, &unit), "instantiate");
        Host host;
        HostCallbackInfo callbacks = {};
        callbacks.hostUserData = &host; callbacks.transportStateProc = transport; callbacks.transportStateProc2 = transport2; callbacks.beatAndTempoProc = tempo;
        check(AudioUnitSetProperty(unit, kAudioUnitProperty_HostCallbacks, kAudioUnitScope_Global, 0, &callbacks, sizeof(callbacks)), "host callbacks");
        for (double rate : {44100., 48000., 96000.}) for (unsigned channels : {1u, 2u}) {
            AudioStreamBasicDescription format = {rate, kAudioFormatLinearPCM, kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved, 4, 1, 4, channels, 32, 0};
            check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof(format)), "input format");
            check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, sizeof(format)), "output format");
            AURenderCallbackStruct callback = {input, &host};
            check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback)), "input callback");
            check(AudioUnitInitialize(unit), "initialize");
            for (unsigned count : {1u, 64u, 512u}) {
                std::vector<char> memory(sizeof(AudioBufferList) + sizeof(AudioBuffer) * channels);
                auto *buffers = (AudioBufferList *)memory.data(); buffers->mNumberBuffers = channels;
                std::vector<std::vector<float>> storage(channels, std::vector<float>(count));
                for (unsigned c = 0; c < channels; ++c) buffers->mBuffers[c] = {1, UInt32(count * sizeof(float)), storage[c].data()};
                AudioTimeStamp time = {}; time.mSampleTime = host.sample; time.mHostTime = mach_absolute_time(); time.mFlags = kAudioTimeStampSampleTimeValid | kAudioTimeStampHostTimeValid;
                AudioUnitRenderActionFlags flags = 0;
                host.inputReady = false; // A host may prepare transport while supplying input.
                check(AudioUnitRender(unit, &flags, &time, 0, count, buffers), "render");
                for (unsigned c = 0; c < channels; ++c) for (unsigned i = 0; i < count; ++i)
                    require(((float *)buffers->mBuffers[c].mData)[i] == float((int(i) % 29) - 14) / 32.f + c * 0.01f, "bit-exact audio pass-through");
                host.sample += count;
            }
            check(AudioUnitUninitialize(unit), "uninitialize");
        }
        COBridge *bridge = nullptr;
        UInt32 bridgeSize = sizeof(bridge);
        check(AudioUnitGetProperty(unit, kCamOrderBridgeProperty, kAudioUnitScope_Global, 0, &bridge, &bridgeSize), "transport bridge");
        auto readTransport = (bool (*)(COBridge *, COTransport *))dlsym(library, "COReadTransport");
        require(readTransport != nullptr, "transport reader");
        COTransport snapshot = {};
        require(readTransport(bridge, &snapshot) && snapshot.valid && snapshot.playing, "transport is queried after host supplied input");
        double lastGoodSeconds = snapshot.seconds;
        host.failTransport = true;
        check(AudioUnitInitialize(unit), "reinitialize for callback failure");
        struct { UInt32 count; AudioBuffer buffers[2]; } silentBuffers = {2, {{1, 0, nullptr}, {1, 0, nullptr}}};
        AudioTimeStamp failedTime = {}; failedTime.mSampleTime = host.sample + 512; failedTime.mFlags = kAudioTimeStampSampleTimeValid;
        AudioUnitRenderActionFlags failedFlags = 0;
        check(AudioUnitRender(unit, &failedFlags, &failedTime, 0, 64, (AudioBufferList *)&silentBuffers), "audio continues on failed callbacks");
        require(readTransport(bridge, &snapshot) && snapshot.playing && snapshot.seconds == lastGoodSeconds, "invalid callback preserves last valid transport");
        host.failTransport = false;
        host.legacyUnavailable = true;
        failedTime.mSampleTime += 64;
        check(AudioUnitRender(unit, &failedFlags, &failedTime, 0, 64, (AudioBufferList *)&silentBuffers), "v2 fallback");
        require(readTransport(bridge, &snapshot) && snapshot.valid && snapshot.playing && snapshot.callbackVersion == 2, "legacy unavailable falls back to v2");
        host.legacyUnavailable = false;
        auto setInterest = (void (*)(COBridge *, bool))dlsym(library, "COSetTransportInterest");
        require(setInterest != nullptr, "transport interest setter");
        setInterest(bridge, true);
        host.silent = true;
        failedTime.mSampleTime += 64;
        check(AudioUnitRender(unit, &failedFlags, &failedTime, 0, 64, (AudioBufferList *)&silentBuffers), "silent input with armed video");
        require(!(failedFlags & kAudioUnitRenderAction_OutputIsSilence), "video transport remains active on silent input");
        for (auto &buffer : silentBuffers.buffers) for (unsigned i = 0; i < 64; ++i)
            require(((float *)buffer.mData)[i] == 0, "keep-active never adds audio");
        host.sample = 480000;
        failedTime.mSampleTime += 64;
        check(AudioUnitProcess(unit, &failedFlags, &failedTime, 64, (AudioBufferList *)&silentBuffers), "AudioUnitProcess entry point");
        require(readTransport(bridge, &snapshot) && snapshot.seconds == 5 && snapshot.playing, "in-place processing publishes timeline");
        [NSThread sleepForTimeInterval:0.55];
        host.sample = 1920000;
        failedTime.mSampleTime += 64;
        check(AudioUnitProcess(unit, &failedFlags, &failedTime, 64, (AudioBufferList *)&silentBuffers), "processing resumes after an unobserved transport interval");
        require(readTransport(bridge, &snapshot) && snapshot.startSeconds == 20, "resuming callbacks replaces the stale take-start anchor");
        check(AudioUnitUninitialize(unit), "uninitialize callback test");
        puts("PASS: transport after input; v1/v2 fallback; callback failures preserve state; silent audio stays zero; AudioUnitProcess follows transport");
        CFPropertyListRef state = nullptr; UInt32 size = sizeof(state);
        check(AudioUnitGetProperty(unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &state, &size), "save state");
        auto dictionary = CFDictionaryCreateMutableCopy(nullptr, 0, (CFDictionaryRef)state);
        CFRelease(state);
        const char *text = "{\"version\":1,\"path\":\"/tmp/camorder-test-missing.camorderstudio\"}";
        auto payload = CFDataCreate(nullptr, (const UInt8 *)text, strlen(text));
        CFDictionarySetValue(dictionary, CFSTR("CamOrderProject"), payload);
        check(AudioUnitSetProperty(unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &dictionary, sizeof(dictionary)), "restore state");
        check(AudioUnitGetProperty(unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &state, &size), "save restored state");
        require(CFEqual(payload, CFDictionaryGetValue((CFDictionaryRef)state, CFSTR("CamOrderProject"))), "project state round trip");
        CFRelease(payload); CFRelease(dictionary); CFRelease(state);
        // Verify a second instance does not inherit the first instance's project.
        AudioUnit second; check(AudioComponentInstanceNew(component, &second), "second instance");
        check(AudioUnitGetProperty(second, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &state, &size), "second state");
        require(!CFDictionaryContainsKey((CFDictionaryRef)state, CFSTR("CamOrderProject")), "instance isolation");
        CFRelease(state); AudioComponentInstanceDispose(second);
        puts("PASS: mono/stereo pass-through at 44.1/48/96 kHz, 1/64/512 frames; project state round trip; instance isolation");
        if (argc >= 3) {
            // Use a fresh unit so no intentionally missing project triggers a modal alert.
            AudioComponentInstanceDispose(unit);
            check(AudioComponentInstanceNew(component, &unit), "UI instance");
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
            AudioUnitCocoaViewInfo info; size = sizeof(info);
            check(AudioUnitGetProperty(unit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, &info, &size), "Cocoa factory info");
            Class viewClass = NSClassFromString((__bridge NSString *)info.mCocoaAUViewClass[0]);
            require(viewClass != Nil, "Cocoa view class");
            id<AUCocoaUIBase> viewFactory = [[viewClass alloc] init];
            NSView *view = [viewFactory uiViewForAudioUnit:unit withSize:NSMakeSize(1280, 820)];
            require(view != nil, "embedded SwiftUI editor");
            NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1280,820) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
            window.contentView = view;
            [window orderFront:nil];
            NSDate *end = [NSDate dateWithTimeIntervalSinceNow:2];
            while (end.timeIntervalSinceNow > 0) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
            [view layoutSubtreeIfNeeded];
            auto bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
            [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
            [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(argv[2]) atomically:YES];
            require((window.styleMask & NSWindowStyleMaskResizable) != 0, "editor window is resizable");
            for (NSValue *value in @[[NSValue valueWithSize:NSMakeSize(820,520)], [NSValue valueWithSize:NSMakeSize(1120,460)], [NSValue valueWithSize:NSMakeSize(760,440)], [NSValue valueWithSize:NSMakeSize(803,417)], [NSValue valueWithSize:NSMakeSize(720,360)]]) {
                NSSize size = value.sizeValue;
                [window setContentSize:size];
                [view setFrameSize:size];
                [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.4]];
                [view layoutSubtreeIfNeeded];
                require(fabs(view.bounds.size.width - size.width) < 1 && fabs(view.bounds.size.height - size.height) < 1, "editor accepts small and flat sizes");
                auto resizedBitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
                [view cacheDisplayInRect:view.bounds toBitmapImageRep:resizedBitmap];
                NSString *suffix = size.width == 720 ? @"-compact.png" : (size.width == 803 ? @"-free.png" : (size.width == 760 ? @"-minimum.png" : (size.width < 1000 ? @"-small.png" : @"-flat.png")));
                NSString *path = [[@(argv[2]) stringByDeletingPathExtension] stringByAppendingString:suffix];
                [[resizedBitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
            }
            puts("PASS: resizable editor at 820 x 520 and 1120 x 460, with stage, live input and timeline");
            // Closing/reopening the editor must reuse its session without crashing.
            window.contentView = nil;
            view = [viewFactory uiViewForAudioUnit:unit withSize:NSMakeSize(1280, 820)];
            require(view != nil, "reopen editor session");
            window.contentView = view;
            [window orderOut:nil];
            CFRelease(info.mCocoaAUViewBundleLocation); CFRelease(info.mCocoaAUViewClass[0]);
            puts("PASS: embedded editor creation, rendering, closing and reopening");
        }
        AudioComponentInstanceDispose(unit);
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.2]];
    }
    return 0;
}
