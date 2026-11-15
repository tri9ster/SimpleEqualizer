#import "seq_engine.h"

bool seq_engine_connect_input(SEQRenderState *state, AVAudioEngine *engine, AVAudioFormat *format) {
    AVAudioInputNode *input = engine.inputNode;
    // このブロックは、音声のスレッドで呼ばれる。中では、C の関数を1つ呼ぶだけにする。
    // 音声のスレッド向けの入口(macOS 27 から)を使う。Swift からは使えない。
    return [input setRealtimeSafeManualRenderingInputPCMFormat:format
                                                    inputBlock:^const AudioBufferList *(AVAudioFrameCount frames) {
        return seq_render_state_engine_input(state, frames);
    }];
}

bool seq_engine_attach(SEQRenderState *state, AVAudioEngine *engine, uint32_t channels, uint32_t capacity) {
    AVAudioEngineManualRenderingBlock block = engine.manualRenderingBlock;
    if (block == nil) {
        return false;
    }
    // 戻り値の型(AVAudioEngineManualRenderingStatus)は long と同じ大きさで、形は SEQEngineRenderBlock と同じ。
    return seq_render_state_attach_engine(state, channels, capacity, (SEQEngineRenderBlock)block);
}
