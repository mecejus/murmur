#include "CRealtime.h"

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <stdatomic.h>
#include <stdlib.h>

// Frames the render buffer holds. CoreAudio slices are normally 512 or less;
// 8192 covers any IO buffer size a user can pick in Audio MIDI Setup.
#define MM_MAX_FRAMES 8192

struct mm_capture {
    AudioUnit unit;
    AudioDeviceID device;
    double sample_rate;
    mm_ring *ring;

    // Preallocated render target: one mono float buffer.
    AudioBufferList abl;
    float *frames;

    // Set while this unit may write into the ring. Cleared by stop, and by
    // mm_capture_disarm from any thread, so a unit whose control call hung
    // (and was abandoned) can never become a second producer on the ring.
    _Atomic int armed;
    _Atomic uint64_t callbacks;
    _Atomic int32_t render_error;
    _Atomic uint64_t oversized;
};

// Runs on the real-time IO thread.
static OSStatus mm_input_cb(void *ref, AudioUnitRenderActionFlags *flags,
                            const AudioTimeStamp *ts, UInt32 bus,
                            UInt32 nframes, AudioBufferList *unused) {
    (void)unused;
    mm_capture *c = (mm_capture *)ref;
    atomic_fetch_add_explicit(&c->callbacks, 1, memory_order_relaxed);
    if (!atomic_load_explicit(&c->armed, memory_order_acquire)) return noErr;
    if (nframes > MM_MAX_FRAMES) {
        atomic_fetch_add_explicit(&c->oversized, 1, memory_order_relaxed);
        return noErr;
    }
    c->abl.mNumberBuffers = 1;
    c->abl.mBuffers[0].mNumberChannels = 1;
    c->abl.mBuffers[0].mDataByteSize = nframes * sizeof(float);
    c->abl.mBuffers[0].mData = c->frames;
    OSStatus st = AudioUnitRender(c->unit, flags, ts, bus, nframes, &c->abl);
    if (st != noErr) {
        atomic_store_explicit(&c->render_error, st, memory_order_relaxed);
        return noErr;
    }
    mm_ring_write(c->ring, c->frames, nframes);
    return noErr;
}

uint32_t mm_default_input_device(void) {
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    AudioDeviceID dev = kAudioObjectUnknown;
    UInt32 size = sizeof(dev);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, &dev) != noErr) {
        return 0;
    }
    return dev == kAudioObjectUnknown ? 0 : dev;
}

int mm_device_is_alive(uint32_t device) {
    if (device == 0) return 0;
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyDeviceIsAlive,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 alive = 0;
    UInt32 size = sizeof(alive);
    if (AudioObjectGetPropertyData(device, &addr, 0, NULL, &size, &alive) != noErr) {
        return 0;
    }
    return alive ? 1 : 0;
}

static void mm_capture_dispose_unit(mm_capture *c) {
    if (c->unit) {
        AudioUnitUninitialize(c->unit);
        AudioComponentInstanceDispose(c->unit);
        c->unit = NULL;
    }
}

mm_capture *mm_capture_create(uint32_t device, mm_ring *ring, OSStatus *status) {
    OSStatus st = noErr;
    mm_capture *c = calloc(1, sizeof(*c));
    float *frames = calloc(MM_MAX_FRAMES, sizeof(float));
    if (!c || !frames) {
        free(c);
        free(frames);
        if (status) *status = -108; // memFullErr
        return NULL;
    }
    c->frames = frames;
    c->ring = ring;
    atomic_init(&c->armed, 0);
    atomic_init(&c->callbacks, 0);
    atomic_init(&c->render_error, 0);
    atomic_init(&c->oversized, 0);

    if (device == 0) device = mm_default_input_device();
    if (device == 0) {
        st = kAudioHardwareBadDeviceError;
        goto fail;
    }
    c->device = device;

    AudioComponentDescription desc = {
        .componentType = kAudioUnitType_Output,
        .componentSubType = kAudioUnitSubType_HALOutput,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
    };
    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    if (!comp) {
        st = kAudioUnitErr_InvalidElement;
        goto fail;
    }
    if ((st = AudioComponentInstanceNew(comp, &c->unit)) != noErr) goto fail;

    // Input on element 1, output on element 0 off: a capture-only unit.
    UInt32 on = 1, off = 0;
    if ((st = AudioUnitSetProperty(c->unit, kAudioOutputUnitProperty_EnableIO,
                                   kAudioUnitScope_Input, 1, &on, sizeof(on))) != noErr) goto fail;
    if ((st = AudioUnitSetProperty(c->unit, kAudioOutputUnitProperty_EnableIO,
                                   kAudioUnitScope_Output, 0, &off, sizeof(off))) != noErr) goto fail;
    if ((st = AudioUnitSetProperty(c->unit, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0, &device, sizeof(device))) != noErr) goto fail;

    // The unit converts format and channel count but not sample rate on the
    // input side, so ask for mono float at whatever rate the device runs.
    AudioStreamBasicDescription hw = {0};
    UInt32 size = sizeof(hw);
    if ((st = AudioUnitGetProperty(c->unit, kAudioUnitProperty_StreamFormat,
                                   kAudioUnitScope_Input, 1, &hw, &size)) != noErr) goto fail;
    if (hw.mSampleRate <= 0) {
        st = kAudioUnitErr_FormatNotSupported;
        goto fail;
    }
    c->sample_rate = hw.mSampleRate;

    AudioStreamBasicDescription fmt = {
        .mSampleRate = hw.mSampleRate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
        .mBytesPerPacket = sizeof(float),
        .mFramesPerPacket = 1,
        .mBytesPerFrame = sizeof(float),
        .mChannelsPerFrame = 1,
        .mBitsPerChannel = 32,
    };
    if ((st = AudioUnitSetProperty(c->unit, kAudioUnitProperty_StreamFormat,
                                   kAudioUnitScope_Output, 1, &fmt, sizeof(fmt))) != noErr) goto fail;

    UInt32 max_frames = MM_MAX_FRAMES;
    AudioUnitSetProperty(c->unit, kAudioUnitProperty_MaximumFramesPerSlice,
                         kAudioUnitScope_Global, 0, &max_frames, sizeof(max_frames));

    AURenderCallbackStruct cb = {mm_input_cb, c};
    if ((st = AudioUnitSetProperty(c->unit, kAudioOutputUnitProperty_SetInputCallback,
                                   kAudioUnitScope_Global, 0, &cb, sizeof(cb))) != noErr) goto fail;

    if ((st = AudioUnitInitialize(c->unit)) != noErr) goto fail;

    if (status) *status = noErr;
    return c;

fail:
    mm_capture_dispose_unit(c);
    free(c->frames);
    free(c);
    if (status) *status = st;
    return NULL;
}

void mm_capture_destroy(mm_capture *c) {
    if (!c) return;
    atomic_store_explicit(&c->armed, 0, memory_order_release);
    if (c->unit) AudioOutputUnitStop(c->unit);
    mm_capture_dispose_unit(c);
    free(c->frames);
    free(c);
}

double mm_capture_sample_rate(const mm_capture *c) { return c->sample_rate; }
uint32_t mm_capture_device(const mm_capture *c) { return c->device; }

OSStatus mm_capture_start(mm_capture *c) {
    atomic_store_explicit(&c->armed, 1, memory_order_release);
    OSStatus st = AudioOutputUnitStart(c->unit);
    if (st != noErr) atomic_store_explicit(&c->armed, 0, memory_order_release);
    return st;
}

OSStatus mm_capture_stop(mm_capture *c) {
    atomic_store_explicit(&c->armed, 0, memory_order_release);
    return AudioOutputUnitStop(c->unit);
}

void mm_capture_disarm(mm_capture *c) {
    atomic_store_explicit(&c->armed, 0, memory_order_release);
}

uint64_t mm_capture_callbacks(const mm_capture *c) {
    return atomic_load_explicit(&((mm_capture *)c)->callbacks, memory_order_relaxed);
}

OSStatus mm_capture_take_render_error(mm_capture *c) {
    return atomic_exchange_explicit(&c->render_error, 0, memory_order_relaxed);
}

uint64_t mm_capture_take_oversized(mm_capture *c) {
    return atomic_exchange_explicit(&c->oversized, 0, memory_order_relaxed);
}
