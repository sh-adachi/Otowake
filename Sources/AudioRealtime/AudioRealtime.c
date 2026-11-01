#include "AudioRealtime.h"
#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <libproc.h>
#include <dlfcn.h>
#include <pthread.h>

struct OWRenderState {
    _Atomic(float) targetGain;
    _Atomic(float) peak;
    _Atomic(uint64_t) callbacks, signals, invalid;
    float currentGain, rampStep;
    uint32_t inputOffset, left, right;
};

OWRenderState *OWRenderCreate(uint32_t offset, uint32_t left, uint32_t right,
                              float gain, double sampleRate) {
    OWRenderState *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    atomic_init(&s->targetGain, fminf(1, fmaxf(0, gain)));
    atomic_init(&s->peak, 0);
    atomic_init(&s->callbacks, 0);
    atomic_init(&s->signals, 0);
    atomic_init(&s->invalid, 0);
    s->currentGain = fminf(1, fmaxf(0, gain));
    s->rampStep = 1.0f / (float)(fmax(8000, sampleRate) * 0.005);
    s->inputOffset = offset; s->left = left; s->right = right;
    return s;
}
void OWRenderDestroy(OWRenderState *s) { free(s); }
void OWRenderSetGain(OWRenderState *s, float gain) {
    atomic_store_explicit(&s->targetGain, isfinite(gain) ? fminf(1, fmaxf(0, gain)) : 0, memory_order_relaxed);
}
float OWRenderPeak(OWRenderState *s) { return atomic_load_explicit(&s->peak, memory_order_relaxed); }
uint64_t OWRenderCallbacks(OWRenderState *s) { return atomic_load_explicit(&s->callbacks, memory_order_relaxed); }
uint64_t OWRenderSignalCallbacks(OWRenderState *s) { return atomic_load_explicit(&s->signals, memory_order_relaxed); }
uint64_t OWRenderInvalidBuffers(OWRenderState *s) { return atomic_load_explicit(&s->invalid, memory_order_relaxed); }

typedef struct { float *samples; uint32_t stride, frames; } Channel;
static Channel channel(const AudioBufferList *list, uint32_t index) {
    if (!list) return (Channel){0};
    for (uint32_t i = 0; i < list->mNumberBuffers; ++i) {
        const AudioBuffer *b = &list->mBuffers[i];
        if (index < b->mNumberChannels) {
            if (!b->mData || !b->mNumberChannels) return (Channel){0};
            return (Channel){(float *)b->mData + index, b->mNumberChannels,
                b->mDataByteSize / (sizeof(float) * b->mNumberChannels)};
        }
        index -= b->mNumberChannels;
    }
    return (Channel){0};
}
void OWRenderProcess(OWRenderState *s, const AudioBufferList *input, AudioBufferList *output) {
    if (!s) return;
    // HAL owns these buffers. Write silence to every unused output channel.
    if (output) for (uint32_t b = 0; b < output->mNumberBuffers; ++b)
        if (output->mBuffers[b].mData) memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
    atomic_fetch_add_explicit(&s->callbacks, 1, memory_order_relaxed);
    Channel inL = channel(input, s->inputOffset), inR = channel(input, s->inputOffset + 1);
    Channel outL = channel(output, s->left), outR = channel(output, s->right);
    if (!inL.samples || !inR.samples || !outL.samples || !outR.samples) {
        atomic_fetch_add_explicit(&s->invalid, 1, memory_order_relaxed);
        atomic_store_explicit(&s->peak, 0, memory_order_relaxed);
        return;
    }
    uint32_t n = inL.frames;
    if (inR.frames < n) n = inR.frames;
    if (outL.frames < n) n = outL.frames;
    if (outR.frames < n) n = outR.frames;
    float target = atomic_load_explicit(&s->targetGain, memory_order_relaxed);
    float gain = s->currentGain, peak = 0, sourcePeak = 0;
    for (uint32_t f = 0; f < n; ++f) {
        gain += fminf(s->rampStep, fmaxf(-s->rampStep, target - gain));
        float l = inL.samples[f * inL.stride], r = inR.samples[f * inR.stride];
        // A malformed source must never inject NaN into the hardware mixer.
        if (!isfinite(l)) l = 0;
        if (!isfinite(r)) r = 0;
        sourcePeak = fmaxf(sourcePeak, fmaxf(fabsf(l), fabsf(r)));
        l = fminf(1, fmaxf(-1, l * gain)); r = fminf(1, fmaxf(-1, r * gain));
        if (s->left == s->right) outL.samples[f * outL.stride] = (l + r) * 0.5f;
        else { outL.samples[f * outL.stride] = l; outR.samples[f * outR.stride] = r; }
        peak = fmaxf(peak, fmaxf(fabsf(l), fabsf(r)));
    }
    s->currentGain = gain;
    atomic_store_explicit(&s->peak, peak, memory_order_relaxed);
    if (sourcePeak > 0.00001f) atomic_fetch_add_explicit(&s->signals, 1, memory_order_relaxed);
}
OSStatus OWAudioIOProc(AudioObjectID device, const AudioTimeStamp *now,
    const AudioBufferList *input, const AudioTimeStamp *inputTime,
    AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    OWRenderProcess(context, input, output);
    return noErr;
}
OSStatus OWEnableTapStreams(AudioObjectID device, AudioDeviceIOProcID proc,
                           uint32_t streams, uint32_t physical) {
    if (streams <= physical) return kAudioHardwareBadStreamError;
    size_t bytes = offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) + streams * sizeof(UInt32);
    AudioHardwareIOProcStreamUsage *usage = calloc(1, bytes);
    if (!usage) return kAudioHardwareUnspecifiedError;
    usage->mIOProc = (void *)proc;
    usage->mNumberStreams = streams;
    for (uint32_t i = physical; i < streams; ++i) usage->mStreamIsOn[i] = 1;
    AudioObjectPropertyAddress a = { kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain };
    OSStatus err = AudioObjectSetPropertyData(device, &a, 0, NULL, (UInt32)bytes, usage);
    free(usage);
    return err;
}
int32_t OWParentPID(int32_t pid) {
    struct proc_bsdinfo info = {0};
    int n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    return n == sizeof(info) ? (int32_t)info.pbi_ppid : 0;
}

typedef pid_t (*ResponsiblePIDFunction)(pid_t);
static ResponsiblePIDFunction responsiblePIDFunction;
static pthread_once_t responsibilityOnce = PTHREAD_ONCE_INIT;
static void resolveResponsibilityFunction(void) {
    // XPC services have launchd as parent. This optional libSystem symbol lets
    // us identify the actual owning app without guessing that all WebKit is Safari.
    responsiblePIDFunction = (ResponsiblePIDFunction)dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
}
int32_t OWResponsiblePID(int32_t pid) {
    pthread_once(&responsibilityOnce, resolveResponsibilityFunction);
    if (!responsiblePIDFunction || pid <= 1) return 0;
    pid_t result = responsiblePIDFunction(pid);
    return result > 1 ? result : 0;
}

struct OWIOHandle { AudioObjectID device; AudioDeviceIOProcID proc; bool started; };
OSStatus OWIOCreate(AudioObjectID device, OWRenderState *state, uint32_t streams,
                    uint32_t physical, OWIOHandle **handle) {
    *handle = NULL;
    OWIOHandle *h = calloc(1, sizeof(*h));
    if (!h) return kAudioHardwareUnspecifiedError;
    h->device = device;
    OSStatus err = AudioDeviceCreateIOProcID(device, OWAudioIOProc, state, &h->proc);
    if (!err) err = OWEnableTapStreams(device, h->proc, streams, physical);
    if (err) { if (h->proc) AudioDeviceDestroyIOProcID(device, h->proc); free(h); return err; }
    *handle = h;
    return noErr;
}
OSStatus OWIOStart(OWIOHandle *h) {
    OSStatus err = AudioDeviceStart(h->device, h->proc);
    if (!err) h->started = true;
    return err;
}
void OWIODestroy(OWIOHandle *h) {
    if (!h) return;
    if (h->started) AudioDeviceStop(h->device, h->proc);
    AudioDeviceDestroyIOProcID(h->device, h->proc);
    free(h);
}
