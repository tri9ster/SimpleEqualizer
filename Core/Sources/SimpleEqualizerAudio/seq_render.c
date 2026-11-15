#include "seq_render.h"

#include <Block.h>
#include <math.h>
#include <stddef.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// 画面とコールバックの間の値は、ロックを使わない方法(アトミック)で受け渡す。
// 小数は、そのままではアトミックにできないので、ビットの並びとして持つ。
struct SEQRenderState {
    _Atomic uint32_t target_gain_bits;
    _Atomic uint32_t input_peak_bits;
    _Atomic uint64_t callback_count;
    _Atomic uint64_t mismatch_count;
    // 止める前に、音を消している途中か。
    _Atomic bool fading_out;
    // いま掛けている倍率が 0 か。画面の側が、音が消えきったかを知るために読む。
    _Atomic bool silent;
    // 始めてから、無音でない音を1回でも受け取ったか。
    _Atomic bool received_signal;
    // リミッターが働いた回の数。
    _Atomic uint64_t limit_count;
    // リミッターが倍率を戻すときの、1フレームあたりの割合。サンプリング周波数から決める。
    _Atomic uint32_t limiter_release_bits;
    // いま掛けている倍率。コールバックだけが読み書きする。
    float current_gain;
    // リミッターがいま掛けている倍率(1 で、何もしていない)。コールバックだけが読み書きする。
    // 1 のすぐ手前で、足す量が小さすぎて進まなくなるのを避けるため、倍精度で持つ。
    double limiter_gain;

    // エンジンを通せなかった回の数。
    _Atomic uint64_t engine_fallback_count;
    // ここから下は、エンジンをつなぐとき・外すとき(コールバックが止まっている間)にだけ書き換える。
    // エンジンを呼ぶブロック。NULL なら、つないでいない。
    SEQEngineRenderBlock engine_block;
    uint32_t engine_channels;
    uint32_t engine_capacity;
    // 並べ替えの置き場。チャンネル c の音は、先頭から c × engine_capacity の位置に置く。
    float *engine_input;
    float *engine_output;
    AudioBufferList *engine_input_list;
    AudioBufferList *engine_output_list;
    // いま、エンジンに頼んでいるフレーム数。加工の最中でなければ 0。コールバックだけが読み書きする。
    uint32_t engine_pending_frames;
};

// リミッターの上限。フルスケールちょうど。これより下にすると、増幅していなくても、
// フルスケールまで使っている音源(多くの音楽)で働いてしまい、元の音が変わる。
#define SEQ_LIMITER_CEILING 1.0f
// リミッターが倍率を戻す速さ(秒)。この時間で、下げた分の約 63% が戻る。
#define SEQ_LIMITER_RELEASE_SECONDS 0.1
// 倍率がここまで戻ったら、1 に戻しきる(いつまでも 1 の手前に留まらないようにする)。
#define SEQ_LIMITER_SNAP 0.9999
// リミッターが下げる倍率の下限(−40 dB)。壊れた、とても大きな値が1サンプル混ざったときに、
// 倍率がほぼ 0 まで落ちて、そのあとしばらく無音になるのを防ぐ。これより大きい分は、切り落としに任せる。
#define SEQ_LIMITER_FLOOR 0.01
#define SEQ_DEFAULT_SAMPLE_RATE 48000.0

static float limiter_release_for(double sample_rate) {
    if (!isfinite(sample_rate) || sample_rate <= 0.0) {
        sample_rate = SEQ_DEFAULT_SAMPLE_RATE;
    }
    return (float)(1.0 - exp(-1.0 / (SEQ_LIMITER_RELEASE_SECONDS * sample_rate)));
}

static inline uint32_t bits_from_float(float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static inline float float_from_bits(uint32_t bits) {
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

SEQRenderState *seq_render_state_create(void) {
    SEQRenderState *state = calloc(1, sizeof(SEQRenderState));
    if (state == NULL) {
        abort();
    }
    atomic_init(&state->target_gain_bits, bits_from_float(0.0f));
    atomic_init(&state->input_peak_bits, bits_from_float(0.0f));
    atomic_init(&state->callback_count, 0);
    atomic_init(&state->mismatch_count, 0);
    atomic_init(&state->fading_out, false);
    atomic_init(&state->silent, true);
    atomic_init(&state->received_signal, false);
    atomic_init(&state->limit_count, 0);
    atomic_init(&state->limiter_release_bits, bits_from_float(limiter_release_for(SEQ_DEFAULT_SAMPLE_RATE)));
    atomic_init(&state->engine_fallback_count, 0);
    state->current_gain = 0.0f;
    state->limiter_gain = 1.0;
    return state;
}

void seq_render_state_destroy(SEQRenderState *state) {
    if (state == NULL) {
        return;
    }
    seq_render_state_detach_engine(state);
    free(state);
}

static AudioBufferList *allocate_channel_list(uint32_t channels, float *data, uint32_t capacity) {
    AudioBufferList *list = calloc(1, offsetof(AudioBufferList, mBuffers) + channels * sizeof(AudioBuffer));
    if (list == NULL) {
        abort();
    }
    list->mNumberBuffers = channels;
    for (uint32_t channel = 0; channel < channels; channel++) {
        list->mBuffers[channel].mNumberChannels = 1;
        list->mBuffers[channel].mDataByteSize = 0;
        list->mBuffers[channel].mData = data + (size_t)channel * capacity;
    }
    return list;
}

bool seq_render_state_attach_engine(SEQRenderState *state, uint32_t channels, uint32_t capacity,
                                    SEQEngineRenderBlock block) {
    seq_render_state_detach_engine(state);
    if (block == NULL || channels == 0 || channels > SEQ_ENGINE_MAX_CHANNELS || capacity == 0) {
        return false;
    }
    const size_t count = (size_t)channels * capacity;
    state->engine_input = calloc(count, sizeof(float));
    state->engine_output = calloc(count, sizeof(float));
    if (state->engine_input == NULL || state->engine_output == NULL) {
        abort();
    }
    state->engine_input_list = allocate_channel_list(channels, state->engine_input, capacity);
    state->engine_output_list = allocate_channel_list(channels, state->engine_output, capacity);
    state->engine_channels = channels;
    state->engine_capacity = capacity;
    state->engine_pending_frames = 0;
    state->engine_block = Block_copy(block);
    return true;
}

void seq_render_state_detach_engine(SEQRenderState *state) {
    if (state->engine_block != NULL) {
        Block_release(state->engine_block);
    }
    state->engine_block = NULL;
    state->engine_channels = 0;
    state->engine_capacity = 0;
    state->engine_pending_frames = 0;
    free(state->engine_input);
    free(state->engine_output);
    free(state->engine_input_list);
    free(state->engine_output_list);
    state->engine_input = NULL;
    state->engine_output = NULL;
    state->engine_input_list = NULL;
    state->engine_output_list = NULL;
}

bool seq_render_state_has_engine(const SEQRenderState *state) {
    return state->engine_block != NULL;
}

const AudioBufferList *seq_render_state_engine_input(SEQRenderState *state, uint32_t frames) {
    if (state->engine_pending_frames == 0 || frames != state->engine_pending_frames) {
        return NULL;
    }
    return state->engine_input_list;
}

uint64_t seq_render_state_engine_fallback_count(const SEQRenderState *state) {
    return atomic_load_explicit(&state->engine_fallback_count, memory_order_relaxed);
}

void seq_render_state_set_target_gain(SEQRenderState *state, float gain) {
    // 数でない値は、比較がすべて偽になる。先に 0 にする。
    if (isnan(gain) || gain < 0.0f) {
        gain = 0.0f;
    } else if (gain > 1.0f) {
        gain = 1.0f;
    }
    atomic_store_explicit(&state->target_gain_bits, bits_from_float(gain), memory_order_relaxed);
}

float seq_render_state_target_gain(const SEQRenderState *state) {
    return float_from_bits(atomic_load_explicit(&state->target_gain_bits, memory_order_relaxed));
}

float seq_limiter_ceiling(void) {
    return SEQ_LIMITER_CEILING;
}

void seq_render_state_set_sample_rate(SEQRenderState *state, double sample_rate) {
    atomic_store_explicit(&state->limiter_release_bits, bits_from_float(limiter_release_for(sample_rate)),
                          memory_order_relaxed);
}

uint64_t seq_render_state_limit_count(const SEQRenderState *state) {
    return atomic_load_explicit(&state->limit_count, memory_order_relaxed);
}

void seq_render_state_reset(SEQRenderState *state) {
    state->current_gain = 0.0f;
    state->limiter_gain = 1.0;
    atomic_store_explicit(&state->limit_count, 0, memory_order_relaxed);
    atomic_store_explicit(&state->engine_fallback_count, 0, memory_order_relaxed);
    atomic_store_explicit(&state->input_peak_bits, bits_from_float(0.0f), memory_order_relaxed);
    atomic_store_explicit(&state->callback_count, 0, memory_order_relaxed);
    atomic_store_explicit(&state->mismatch_count, 0, memory_order_relaxed);
    atomic_store_explicit(&state->fading_out, false, memory_order_relaxed);
    atomic_store_explicit(&state->silent, true, memory_order_relaxed);
    atomic_store_explicit(&state->received_signal, false, memory_order_relaxed);
}

void seq_render_state_set_fading_out(SEQRenderState *state, bool fading_out) {
    atomic_store_explicit(&state->fading_out, fading_out, memory_order_relaxed);
}

bool seq_render_state_is_silent(const SEQRenderState *state) {
    return atomic_load_explicit(&state->silent, memory_order_relaxed);
}

bool seq_render_state_has_received_signal(const SEQRenderState *state) {
    return atomic_load_explicit(&state->received_signal, memory_order_relaxed);
}

float seq_render_state_input_peak(const SEQRenderState *state) {
    return float_from_bits(atomic_load_explicit(&state->input_peak_bits, memory_order_relaxed));
}

uint64_t seq_render_state_callback_count(const SEQRenderState *state) {
    return atomic_load_explicit(&state->callback_count, memory_order_relaxed);
}

uint64_t seq_render_state_mismatch_count(const SEQRenderState *state) {
    return atomic_load_explicit(&state->mismatch_count, memory_order_relaxed);
}

static void fill_with_silence(AudioBufferList *output) {
    for (UInt32 index = 0; index < output->mNumberBuffers; index++) {
        AudioBuffer *buffer = &output->mBuffers[index];
        if (buffer->mData != NULL) {
            memset(buffer->mData, 0, buffer->mDataByteSize);
        }
    }
}

// 音量を掛けたあとの音を、上限に収める。フレームごとに、全部のチャンネルの中でいちばん大きい値を見て、
// 全チャンネルに同じ倍率を掛ける(音の位置を動かさない)。
static void apply_limiter(SEQRenderState *state, AudioBufferList *output) {
    const UInt32 buffer_count = output->mNumberBuffers;
    UInt32 max_frames = 0;
    for (UInt32 index = 0; index < buffer_count; index++) {
        const AudioBuffer *buffer = &output->mBuffers[index];
        if (buffer->mData == NULL || buffer->mNumberChannels == 0) {
            continue;
        }
        const UInt32 frames = buffer->mDataByteSize / (UInt32)sizeof(float) / buffer->mNumberChannels;
        if (frames > max_frames) {
            max_frames = frames;
        }
    }

    const double release =
        (double)float_from_bits(atomic_load_explicit(&state->limiter_release_bits, memory_order_relaxed));
    double gain = state->limiter_gain;
    bool limited = false;

    for (UInt32 frame = 0; frame < max_frames; frame++) {
        float peak = 0.0f;
        for (UInt32 index = 0; index < buffer_count; index++) {
            const AudioBuffer *buffer = &output->mBuffers[index];
            const UInt32 channels = buffer->mNumberChannels;
            if (buffer->mData == NULL || channels == 0
                || frame >= buffer->mDataByteSize / (UInt32)sizeof(float) / channels) {
                continue;
            }
            const float *samples = (const float *)buffer->mData;
            for (UInt32 channel = 0; channel < channels; channel++) {
                const float magnitude = fabsf(samples[frame * channels + channel]);
                if (magnitude > peak) {
                    peak = magnitude;
                }
            }
        }

        // このフレームを上限に収めるのに要る倍率。超えていなければ 1。
        double needed = (peak > SEQ_LIMITER_CEILING) ? (double)SEQ_LIMITER_CEILING / (double)peak : 1.0;
        if (needed < SEQ_LIMITER_FLOOR) {
            needed = SEQ_LIMITER_FLOOR;
        }
        if (needed < gain) {
            // 超えそうなときは、すぐに下げる。
            gain = needed;
        } else if (gain < 1.0) {
            // 超えなくなったら、ゆっくり戻す。
            gain += (1.0 - gain) * release;
            if (gain > SEQ_LIMITER_SNAP) {
                gain = 1.0;
            }
            if (gain > needed) {
                gain = needed;
            }
        }
        if (gain >= 1.0) {
            continue;
        }
        limited = true;
        const float applied = (float)gain;

        for (UInt32 index = 0; index < buffer_count; index++) {
            AudioBuffer *buffer = &output->mBuffers[index];
            const UInt32 channels = buffer->mNumberChannels;
            if (buffer->mData == NULL || channels == 0
                || frame >= buffer->mDataByteSize / (UInt32)sizeof(float) / channels) {
                continue;
            }
            float *samples = (float *)buffer->mData;
            for (UInt32 channel = 0; channel < channels; channel++) {
                float sample = samples[frame * channels + channel] * applied;
                // 計算の誤差への備え。フルスケールは超えさせない。
                if (sample > 1.0f) {
                    sample = 1.0f;
                } else if (sample < -1.0f) {
                    sample = -1.0f;
                }
                samples[frame * channels + channel] = sample;
            }
        }
    }

    state->limiter_gain = gain;
    if (limited) {
        atomic_fetch_add_explicit(&state->limit_count, 1, memory_order_relaxed);
    }
}

// 取り出した音(左右が交互の1本)をチャンネル別に並べ替え、エンジンに通す。
// planes に、チャンネルごとの、このあと使う音の場所を入れる。エンジンを通せたら加工した音、通せなかったら並べ替えただけの音。
// 入力の最大値を peak に入れる。エンジンを通せたら true を返す。
// 呼ぶ前に、channels と frames が、つないだエンジンに合っていることを確かめておく。
static bool render_through_engine(SEQRenderState *state, const float *from, UInt32 channels, UInt32 frames,
                                  const float *planes[SEQ_ENGINE_MAX_CHANNELS], float *peak) {
    const uint32_t capacity = state->engine_capacity;
    const UInt32 bytes = frames * (UInt32)sizeof(float);
    float input_peak = 0.0f;

    for (UInt32 channel = 0; channel < channels; channel++) {
        float *plane = state->engine_input + (size_t)channel * capacity;
        for (UInt32 frame = 0; frame < frames; frame++) {
            float sample = from[frame * channels + channel];
            // 数でない値や無限大は、エンジンに渡す前に無音に置き換える(フィルターの中に残り続けるのを防ぐ)。
            if (!isfinite(sample)) {
                sample = 0.0f;
            }
            const float magnitude = fabsf(sample);
            if (magnitude > input_peak) {
                input_peak = magnitude;
            }
            plane[frame] = sample;
        }
        planes[channel] = plane;
        state->engine_input_list->mBuffers[channel].mDataByteSize = bytes;
        // エンジンが、置き場の場所や長さを書き換えることがある。毎回、元に戻す。
        state->engine_output_list->mBuffers[channel].mData = state->engine_output + (size_t)channel * capacity;
        state->engine_output_list->mBuffers[channel].mDataByteSize = bytes;
    }
    state->engine_input_list->mNumberBuffers = channels;
    state->engine_output_list->mNumberBuffers = channels;
    *peak = input_peak;

    OSStatus error = 0;
    state->engine_pending_frames = frames;
    const long status = state->engine_block(frames, state->engine_output_list, &error);
    state->engine_pending_frames = 0;

    // 0 は「頼んだ音を全部返した」。それ以外(エラー、音が足りない、いまはできない)は、加工した音を使わない。
    bool succeeded = (status == 0) && state->engine_output_list->mNumberBuffers == channels;
    for (UInt32 channel = 0; succeeded && channel < channels; channel++) {
        const AudioBuffer *buffer = &state->engine_output_list->mBuffers[channel];
        if (buffer->mData == NULL || buffer->mDataByteSize < bytes) {
            succeeded = false;
        }
    }
    if (succeeded) {
        for (UInt32 channel = 0; channel < channels; channel++) {
            planes[channel] = (const float *)state->engine_output_list->mBuffers[channel].mData;
        }
    }
    return succeeded;
}

void seq_render(SEQRenderState *state, const AudioBufferList *input, AudioBufferList *output) {
    atomic_fetch_add_explicit(&state->callback_count, 1, memory_order_relaxed);

    // 先に無音で埋める。形が合わないときは、そのまま無音を出す。
    fill_with_silence(output);

    const UInt32 output_count = output->mNumberBuffers;
    const UInt32 input_count = input->mNumberBuffers;
    if (output_count == 0 || input_count < output_count) {
        atomic_fetch_add_explicit(&state->mismatch_count, 1, memory_order_relaxed);
        atomic_store_explicit(&state->input_peak_bits, bits_from_float(0.0f), memory_order_relaxed);
        return;
    }
    // 集約装置の入力には、出力装置が持つ入力が先に、タップが最後に並ぶ。後ろから出力と同じ数だけ使う。
    const UInt32 input_offset = input_count - output_count;

    // 消している途中は、目標の倍率に関係なく 0 へ下げる。
    const bool fading_out = atomic_load_explicit(&state->fading_out, memory_order_relaxed);
    const float target = fading_out ? 0.0f : seq_render_state_target_gain(state);
    const float start = state->current_gain;
    float peak = 0.0f;
    // 音量を掛けたあとの音の、いちばん大きい値。リミッターを通す必要があるかを決める。
    float output_peak = 0.0f;
    bool did_copy = false;

    for (UInt32 index = 0; index < output_count; index++) {
        const AudioBuffer *source = &input->mBuffers[input_offset + index];
        AudioBuffer *destination = &output->mBuffers[index];
        if (source->mDataByteSize != destination->mDataByteSize
            || source->mNumberChannels != destination->mNumberChannels
            || source->mNumberChannels == 0
            || source->mData == NULL
            || destination->mData == NULL) {
            atomic_fetch_add_explicit(&state->mismatch_count, 1, memory_order_relaxed);
            continue;
        }
        const UInt32 channels = source->mNumberChannels;
        const UInt32 frames = source->mDataByteSize / (UInt32)sizeof(float) / channels;
        if (frames == 0) {
            continue;
        }
        const float *from = (const float *)source->mData;
        float *to = (float *)destination->mData;

        // 倍率を、1回の呼び出しの中でなめらかに変える(急に変えると雑音が出る)。
        // 足し込まずに毎回計算し、最後のフレームでちょうど目標になるようにする。
        const float step = (target - start) / (float)frames;
        did_copy = true;

        if (state->engine_block != NULL) {
            // エンジンに通せるのは、左右が交互の1本で、チャンネル数とフレーム数が、つないだときの形に合う回だけ。
            // 通せなかった回は、取り出した音をそのまま使う(無音にしない)。どちらの場合も、音量とリミッターは掛ける。
            bool processed = false;
            if (output_count == 1 && channels == state->engine_channels && frames <= state->engine_capacity) {
                const float *planes[SEQ_ENGINE_MAX_CHANNELS];
                float input_peak = 0.0f;
                processed = render_through_engine(state, from, channels, frames, planes, &input_peak);
                if (input_peak > peak) {
                    peak = input_peak;
                }
                for (UInt32 frame = 0; frame < frames; frame++) {
                    const float gain = (frame + 1 == frames) ? target : start + step * (float)(frame + 1);
                    for (UInt32 channel = 0; channel < channels; channel++) {
                        float sample = planes[channel][frame];
                        // エンジンが数でない値を返した場合に備える。
                        if (!isfinite(sample)) {
                            sample = 0.0f;
                        }
                        const float scaled = sample * gain;
                        const float scaled_magnitude = fabsf(scaled);
                        if (scaled_magnitude > output_peak) {
                            output_peak = scaled_magnitude;
                        }
                        to[frame * channels + channel] = scaled;
                    }
                }
                if (!processed) {
                    atomic_fetch_add_explicit(&state->engine_fallback_count, 1, memory_order_relaxed);
                }
                continue;
            }
            atomic_fetch_add_explicit(&state->engine_fallback_count, 1, memory_order_relaxed);
        }

        for (UInt32 frame = 0; frame < frames; frame++) {
            const float gain = (frame + 1 == frames) ? target : start + step * (float)(frame + 1);
            for (UInt32 channel = 0; channel < channels; channel++) {
                float sample = from[frame * channels + channel];
                // 数でない値や無限大は、倍率 0 を掛けても数でない値になり、雑音として出る。無音に置き換える。
                if (!isfinite(sample)) {
                    sample = 0.0f;
                }
                const float magnitude = fabsf(sample);
                if (magnitude > peak) {
                    peak = magnitude;
                }
                const float scaled = sample * gain;
                const float scaled_magnitude = fabsf(scaled);
                if (scaled_magnitude > output_peak) {
                    output_peak = scaled_magnitude;
                }
                to[frame * channels + channel] = scaled;
            }
        }
    }

    // 音量を掛けたあとの音を、上限に収める。上限を超えておらず、下げていた倍率も戻りきっているとき
    // (ほとんどの回)は、何もすることがないので通さない。
    if (output_peak > SEQ_LIMITER_CEILING || state->limiter_gain < 1.0) {
        apply_limiter(state, output);
    }

    // 音を出せなかった回は、倍率を進めない(次に出せたときに、いまの倍率からなめらかに変える)。
    if (did_copy) {
        state->current_gain = target;
        atomic_store_explicit(&state->silent, target == 0.0f, memory_order_relaxed);
    }
    atomic_store_explicit(&state->input_peak_bits, bits_from_float(peak), memory_order_relaxed);
    if (peak > 0.0f) {
        atomic_store_explicit(&state->received_signal, true, memory_order_relaxed);
    }
}

OSStatus seq_io_proc(AudioObjectID inDevice,
                     const AudioTimeStamp *inNow,
                     const AudioBufferList *inInputData,
                     const AudioTimeStamp *inInputTime,
                     AudioBufferList *outOutputData,
                     const AudioTimeStamp *inOutputTime,
                     void *inClientData) {
    (void)inDevice;
    (void)inNow;
    (void)inInputTime;
    (void)inOutputTime;
    if (inClientData == NULL) {
        fill_with_silence(outOutputData);
        return noErr;
    }
    seq_render((SEQRenderState *)inClientData, inInputData, outOutputData);
    return noErr;
}
