#ifndef APP_VOLUME_CONTROL_REALTIME_GAIN_H
#define APP_VOLUME_CONTROL_REALTIME_GAIN_H

#include <stddef.h>
#include <stdint.h>

typedef struct AVCRealtimeGain {
    _Atomic(uint32_t) targetBits;
    _Atomic(uint32_t) currentBits;
} AVCRealtimeGain;

void avc_realtime_gain_init(AVCRealtimeGain *gain, float initialValue);
void avc_realtime_gain_set_target(AVCRealtimeGain *gain, float value);
float avc_realtime_gain_target(const AVCRealtimeGain *gain);
void avc_realtime_gain_process(
    AVCRealtimeGain *gain,
    const float *input,
    float *output,
    size_t count,
    float rampCoefficient
);

#endif
