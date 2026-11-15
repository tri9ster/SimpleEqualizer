// swift-tools-version: 6.0
import PackageDescription

// 音を出さずに確かめられる処理をまとめたパッケージ。
// アプリを起動せずに、`swift test` で自動テストを動かせる。
let package = Package(
    name: "SimpleEqualizerCore",
    // 文言の元の言語。英語の訳は、各ターゲットの Resources/Localizable.xcstrings にある。
    defaultLocalization: "ja",
    // アプリと同じ(macOS 27)。エンジンの部品をつなぐ関数に、macOS 27 のものを使う。
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "SimpleEqualizerCore", targets: ["SimpleEqualizerCore", "SimpleEqualizerAudio", "SimpleEqualizerEngine"]),
    ],
    targets: [
        // 音声に触らない処理(音量の換算、状態の保存など)。
        .target(name: "SimpleEqualizerCore", resources: [.process("Resources")]),
        // 音声のスレッドで動く関数。C で書く(理由は docs/specification.md の12章)。
        // エンジンをつなぐところ(seq_engine.m)だけは Objective-C。音声のスレッドで動くのは、C の関数を1つ呼ぶブロックだけ。
        .target(
            name: "SimpleEqualizerAudio",
            linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("AVFAudio")]
        ),
        // 音を加工するエンジン(イコライザー、ラウドネス)の組み立て。装置には触らないので、音を出さずにテストできる。
        .target(
            name: "SimpleEqualizerEngine", dependencies: ["SimpleEqualizerCore", "SimpleEqualizerAudio"],
            resources: [.process("Resources")]),
        .testTarget(name: "SimpleEqualizerCoreTests", dependencies: ["SimpleEqualizerCore"]),
        .testTarget(name: "SimpleEqualizerAudioTests", dependencies: ["SimpleEqualizerAudio"]),
        .testTarget(
            name: "SimpleEqualizerEngineTests",
            dependencies: ["SimpleEqualizerEngine", "SimpleEqualizerCore", "SimpleEqualizerAudio"]),
    ]
)
