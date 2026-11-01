#pragma once
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct OWRenderState OWRenderState;
typedef struct OWIOHandle OWIOHandle;
// Input channels preceding the tap are never read (e.g. a duplex interface's mic).
OWRenderState *OWRenderCreate(uint32_t inputChannelOffset, uint32_t leftOutput,
                              uint32_t rightOutput, float initialGain, double sampleRate);
void OWRenderDestroy(OWRenderState *state);
void OWRenderSetGain(OWRenderState *state, float gain);
float OWRenderPeak(OWRenderState *state);
uint64_t OWRenderCallbacks(OWRenderState *state);
uint64_t OWRenderSignalCallbacks(OWRenderState *state);
uint64_t OWRenderInvalidBuffers(OWRenderState *state);
void OWRenderProcess(OWRenderState *state, const AudioBufferList *input, AudioBufferList *output);
OSStatus OWAudioIOProc(AudioObjectID device, const AudioTimeStamp *now,
    const AudioBufferList *input, const AudioTimeStamp *inputTime,
    AudioBufferList *output, const AudioTimeStamp *outputTime, void *context);
// Disables all physical input streams, retaining only the trailing tap streams.
OSStatus OWEnableTapStreams(AudioObjectID device, AudioDeviceIOProcID proc,
                            uint32_t inputStreams, uint32_t physicalInputStreams);
int32_t OWParentPID(int32_t pid);
// Optional macOS responsibility SPI; returns 0 if unavailable. Control thread only.
int32_t OWResponsiblePID(int32_t pid);
OSStatus OWIOCreate(AudioObjectID device, OWRenderState *state, uint32_t inputStreams,
                    uint32_t physicalInputStreams, OWIOHandle **handle);
OSStatus OWIOStart(OWIOHandle *handle);
void OWIODestroy(OWIOHandle *handle);
