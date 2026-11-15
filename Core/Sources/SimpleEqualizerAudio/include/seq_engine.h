// AVAudioEngine を、C のコールバックにつなぐ。
//
// Swift から直接つなぐと、音声のスレッドで Swift のコードが動く(Swift のクロージャが間に入る)。
// それを避けるため、つなぐところだけを Objective-C で書く。
// ここの2つの関数は、音声のスレッドでは動かない。ただし、seq_engine_connect_input がエンジンに渡すブロックは、
// 音声のスレッドで呼ばれる。ブロックの中では、C の関数(seq_render_state_engine_input)を1つ呼ぶだけにしてある。
// ここを直したら、機械語を調べる(docs/failures.md)。

#ifndef SEQ_ENGINE_H
#define SEQ_ENGINE_H

#include "seq_render.h"

#ifdef __OBJC__
#import <AVFAudio/AVFAudio.h>

NS_ASSUME_NONNULL_BEGIN

// エンジンの入力を、state の置き場(チャンネル別に並べ替えた音)につなぐ。
// エンジンを手動レンダリングに切り替えたあと、部品をつなぐ前に呼ぶ。
// エンジンは、state より先に止めて捨てる(エンジンが state を指し続けるため)。
bool seq_engine_connect_input(SEQRenderState *state, AVAudioEngine *engine, AVAudioFormat *format);

// エンジンを呼ぶ入口を、state に渡す(seq_render_state_attach_engine を呼ぶ)。
// エンジンを始めたあと、コールバックを始める前に呼ぶ。
bool seq_engine_attach(SEQRenderState *state, AVAudioEngine *engine, uint32_t channels, uint32_t capacity);

NS_ASSUME_NONNULL_END

#endif
#endif
