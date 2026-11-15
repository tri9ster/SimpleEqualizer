// 音声のスレッドで動く関数と、画面との間で受け渡す値。
//
// この中の seq_render と seq_io_proc は、音声のスレッドで呼ばれる。
// メモリの確保、ロック、ログ出力、ファイル操作をしない。

#ifndef SEQ_RENDER_H
#define SEQ_RENDER_H

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SEQRenderState SEQRenderState;

// 作る・捨てる。音声のスレッド以外から呼ぶ。捨てるのは、コールバックを止めたあと。
SEQRenderState *_Nonnull seq_render_state_create(void);
void seq_render_state_destroy(SEQRenderState *_Nullable state);

// 目標の倍率を決める。0 以上 1 以下に収める(元の音量を超えない)。数でない値は 0 にする。
// どのスレッドから呼んでもよい。
void seq_render_state_set_target_gain(SEQRenderState *_Nonnull state, float gain);
float seq_render_state_target_gain(const SEQRenderState *_Nonnull state);

// 止める前に、音をなめらかに消す。true の間は、目標の倍率に関係なく、倍率を 0 へ下げる。
// 目標の倍率は書き換えない(次に始めるときに、そのまま使える)。どのスレッドから呼んでもよい。
void seq_render_state_set_fading_out(SEQRenderState *_Nonnull state, bool fading_out);
// いま掛けている倍率が 0 になっているか(音が消えきったか)。どのスレッドから呼んでもよい。
bool seq_render_state_is_silent(const SEQRenderState *_Nonnull state);

// いま掛けている倍率を 0 に戻し、回数を 0 に戻し、「消している途中」をやめ、「音を受け取った」を消す。
// リミッターが下げていた倍率も元に戻す。目標の倍率とサンプリング周波数は残す。
// コールバックが止まっている間に呼ぶ。
void seq_render_state_reset(SEQRenderState *_Nonnull state);

// 始めてから、無音でない音を1回でも受け取ったか。「システム音声の録音」の許可がないと、ずっと無音のままになる。
// どのスレッドから呼んでもよい。
bool seq_render_state_has_received_signal(const SEQRenderState *_Nonnull state);

// 画面に出すための値。どのスレッドから呼んでもよい。
float seq_render_state_input_peak(const SEQRenderState *_Nonnull state);
uint64_t seq_render_state_callback_count(const SEQRenderState *_Nonnull state);
uint64_t seq_render_state_mismatch_count(const SEQRenderState *_Nonnull state);

// リミッター: 音量を掛けたあとの音が上限を超えるときに、全体の倍率をすぐに下げ、そのあとゆっくり戻す。
// 上限は、フルスケール(1.0)。増幅していない音は、フルスケールまで使っていても変えない。
// 下げる倍率には下限(−40 dB)がある。それでも収まらない分は、±1.0 で切り落とす。
float seq_limiter_ceiling(void);
// リミッターが倍率を戻す速さは、サンプリング周波数で決まる。始める前に渡す。
// 使えない値(0 以下、数でない値、無限大)は、48000 として扱う。コールバックが止まっている間に呼ぶ。
void seq_render_state_set_sample_rate(SEQRenderState *_Nonnull state, double sample_rate);
// リミッターが音を抑えていた回(コールバックの呼び出し)の数。上限を超えた回だけでなく、
// そのあと倍率を戻している途中の回も数える。上限を超えた回数ではない。
// 「いま抑えているか」は、この数が増え続けているかで分かる。始め直すと 0 に戻る。どのスレッドから呼んでもよい。
uint64_t seq_render_state_limit_count(const SEQRenderState *_Nonnull state);

// エンジン(音を加工する部品。イコライザーなど)を呼ぶブロック。AVAudioEngine の manualRenderingBlock と同じ形。
// frames フレームぶんの加工した音を、output(チャンネル別)に書き、うまくいけば 0 を返す。
typedef long (^SEQEngineRenderBlock)(uint32_t frames, AudioBufferList *_Nonnull output, OSStatus *_Nullable error);

// つなげるチャンネル数の上限。
#define SEQ_ENGINE_MAX_CHANNELS 8

// エンジンをつなぐ。つなぐと、コールバックは、取り出した音をエンジンに通してから、音量とリミッターを掛ける。
// channels はエンジンのチャンネル数、capacity は1回に扱えるフレーム数の上限。並べ替えの置き場を、ここで確保する。
// 前につないでいたエンジンは外す。つなげないとき(チャンネル数や置き場の大きさが使えない値)は false を返す。
// コールバックが止まっている間に呼ぶ。
bool seq_render_state_attach_engine(SEQRenderState *_Nonnull state, uint32_t channels, uint32_t capacity,
                                    SEQEngineRenderBlock _Nonnull block);
// エンジンを外す。コールバックが止まっている間に呼ぶ。
void seq_render_state_detach_engine(SEQRenderState *_Nonnull state);
bool seq_render_state_has_engine(const SEQRenderState *_Nonnull state);

// エンジンが、加工する音を受け取るために呼ぶ。チャンネル別に並べ替えた音を返す。
// 加工の最中で、frames が頼んだ長さと同じときだけ返す。それ以外は NULL。音声のスレッドで呼ばれる。
const AudioBufferList *_Nullable seq_render_state_engine_input(SEQRenderState *_Nonnull state, uint32_t frames);

// エンジンをつないでいるのに、エンジンを通せなかった回の数(エンジンが断った、フレーム数が置き場より多い、
// チャンネル数が違う)。その回は、取り出した音をそのまま使う(音量とリミッターは掛かる)。
// 始め直すと 0 に戻る。どのスレッドから呼んでもよい。
uint64_t seq_render_state_engine_fallback_count(const SEQRenderState *_Nonnull state);

// 入力を出力へ写しながら、倍率を掛ける。エンジンをつないでいれば、倍率を掛ける前にエンジンを通す。
// 最後に、リミッターを通す。倍率は、1回の呼び出しの中でなめらかに目標へ近づける。
// 入力と出力の形が合わないときは、無音を出す。
// 入力の本数が出力より多いときは、後ろから出力と同じ数だけ使う(集約装置では、タップが最後に並ぶ)。
void seq_render(SEQRenderState *_Nonnull state,
                const AudioBufferList *_Nonnull input,
                AudioBufferList *_Nonnull output);

// Core Audio に登録するコールバック。inClientData には SEQRenderState を渡す。
OSStatus seq_io_proc(AudioObjectID inDevice,
                     const AudioTimeStamp *_Nonnull inNow,
                     const AudioBufferList *_Nonnull inInputData,
                     const AudioTimeStamp *_Nonnull inInputTime,
                     AudioBufferList *_Nonnull outOutputData,
                     const AudioTimeStamp *_Nonnull inOutputTime,
                     void *_Nullable inClientData);

#ifdef __cplusplus
}
#endif

#endif
