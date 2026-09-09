#include "RealtimeGain.h"

#include <stdatomic.h>
#include <string.h>
#include <math.h>

static float clamp_gain(float value) {
    if (value < 0.0f) return 0.0f;
    if (!isfinite(value)) return 1.0f;
    if (value > 4.0f / 3.0f) return 4.0f / 3.0f;
    return value;
}

static uint32_t bits_for_float(float value) {
    uint32_t bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static float float_for_bits(uint32_t bits) {
    float value = 0.0f;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

void avc_realtime_gain_init(AVCRealtimeGain *gain, float initialValue) {
    const uint32_t bits = bits_for_float(clamp_gain(initialValue));
    atomic_init(&gain->targetBits, bits);
    atomic_init(&gain->currentBits, bits);
}

void avc_realtime_gain_set_target(AVCRealtimeGain *gain, float value) {
    atomic_store_explicit(
        &gain->targetBits,
        bits_for_float(clamp_gain(value)),
        memory_order_relaxed
    );
}

float avc_realtime_gain_target(const AVCRealtimeGain *gain) {
    return float_for_bits(atomic_load_explicit(&gain->targetBits, memory_order_relaxed));
}

void avc_realtime_gain_process(
    AVCRealtimeGain *gain,
    const float *input,
    float *output,
    size_t count,
    float rampCoefficient
) {
    const float target = avc_realtime_gain_target(gain);
    float current = float_for_bits(
        atomic_load_explicit(&gain->currentBits, memory_order_relaxed)
    );
    const float coefficient = fminf(clamp_gain(rampCoefficient), 1.0f);

    for (size_t index = 0; index < count; index += 1) {
        current += (target - current) * coefficient;
        // 增强时限制峰值，避免超出有效样本范围。 / Bound boosted peaks to valid samples.
        const float sample = input[index] * current;
        output[index] = fminf(fmaxf(sample, -1.0f), 1.0f);
    }

    atomic_store_explicit(
        &gain->currentBits,
        bits_for_float(current),
        memory_order_relaxed
    );
}
