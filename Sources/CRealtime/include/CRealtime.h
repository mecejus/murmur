#ifndef MURMUR_CREALTIME_H
#define MURMUR_CREALTIME_H

// Everything that runs on CoreAudio's real-time IO thread lives behind this
// header. The rule for that thread: no allocation, no locks, no syscalls that
// can block, no Objective-C or Swift runtime. Memory is allocated up front by
// the create functions, which run on ordinary threads.

#include <stdint.h>
#include <MacTypes.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Single-producer single-consumer ring of float samples.
//
// The producer is the audio callback, the consumer is the drain timer. When
// the ring is full the producer drops the newest samples (it never waits)
// and counts them, so an overrun shows up in the log instead of as a stall.
// ---------------------------------------------------------------------------

typedef struct mm_ring mm_ring;

// capacity is rounded up to a power of two. Returns NULL on allocation failure.
mm_ring *mm_ring_create(uint32_t capacity);
void mm_ring_destroy(mm_ring *ring);

uint32_t mm_ring_capacity(const mm_ring *ring);

// Producer side. Writes up to n samples and returns how many fit; the rest
// are added to the dropped counter.
uint32_t mm_ring_write(mm_ring *ring, const float *samples, uint32_t n);

// Consumer side. Reads up to max samples into out, returns the count.
uint32_t mm_ring_read(mm_ring *ring, float *out, uint32_t max);

// Samples waiting to be read.
uint32_t mm_ring_available(const mm_ring *ring);

// Total samples dropped because the ring was full, and resets the counter.
uint64_t mm_ring_take_dropped(mm_ring *ring);

// Discards everything unread. Consumer side only, while the producer is idle.
void mm_ring_clear(mm_ring *ring);

// ---------------------------------------------------------------------------
// Microphone capture through an AUHAL unit on one input device.
//
// The unit is created and initialized once per device and then started and
// stopped for each dictation. The input callback renders into a buffer
// allocated at create time and copies into the ring. Nothing else happens on
// the IO thread.
// ---------------------------------------------------------------------------

typedef struct mm_capture mm_capture;

// Creates a capture unit bound to device (an AudioDeviceID; 0 means the
// current default input). On failure returns NULL and stores the OSStatus in
// *status.
mm_capture *mm_capture_create(uint32_t device, mm_ring *ring, OSStatus *status);
void mm_capture_destroy(mm_capture *cap);

// The device sample rate the ring is filled at, in Hz.
double mm_capture_sample_rate(const mm_capture *cap);
uint32_t mm_capture_device(const mm_capture *cap);

OSStatus mm_capture_start(mm_capture *cap);
OSStatus mm_capture_stop(mm_capture *cap);

// Stops the unit writing into the ring, immediately. A single atomic store,
// safe from any thread, including while another thread is stuck inside a
// CoreAudio call on this unit.
void mm_capture_disarm(mm_capture *cap);

// Number of IO callbacks since create. A running unit whose count stops
// moving has lost its device.
uint64_t mm_capture_callbacks(const mm_capture *cap);

// Most recent non-zero AudioUnitRender status, and clears it.
OSStatus mm_capture_take_render_error(mm_capture *cap);

// Callbacks that were skipped because they delivered more frames than the
// preallocated buffer holds, and clears the count.
uint64_t mm_capture_take_oversized(mm_capture *cap);

// The current default input device, or 0 if there is none.
uint32_t mm_default_input_device(void);

// 1 if the device still exists and is alive.
int mm_device_is_alive(uint32_t device);

#ifdef __cplusplus
}
#endif

#endif
