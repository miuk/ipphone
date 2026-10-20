// swift-tools-version: 6.2

import PackageDescription

let pjLibraries = [
    "pjsua-aarch64-apple-darwin27.0.0",
    "pjsip-ua-aarch64-apple-darwin27.0.0",
    "pjsip-simple-aarch64-apple-darwin27.0.0",
    "pjsip-aarch64-apple-darwin27.0.0",
    "pjmedia-codec-aarch64-apple-darwin27.0.0",
    "pjmedia-videodev-aarch64-apple-darwin27.0.0",
    "pjmedia-audiodev-aarch64-apple-darwin27.0.0",
    "pjmedia-aarch64-apple-darwin27.0.0",
    "pjnath-aarch64-apple-darwin27.0.0",
    "pjlib-util-aarch64-apple-darwin27.0.0",
    "pj-aarch64-apple-darwin27.0.0",
    "srtp-aarch64-apple-darwin27.0.0",
    "resample-aarch64-apple-darwin27.0.0",
    "gsmcodec-aarch64-apple-darwin27.0.0",
    "speex-aarch64-apple-darwin27.0.0",
    "ilbccodec-aarch64-apple-darwin27.0.0",
    "g7221codec-aarch64-apple-darwin27.0.0",
    "yuv-aarch64-apple-darwin27.0.0",
    "webrtc-aarch64-apple-darwin27.0.0",
    "ssl",
    "crypto",
]

let package = Package(
    name: "IPPhone",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "IPPhoneApp", targets: ["IPPhoneApp"]),
        .library(name: "IPPhoneCore", targets: ["IPPhoneCore"]),
    ],
    targets: [
        .target(
            name: "CPJSIPBridge",
            path: "Sources/CPJSIPBridge",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags([
                    "-I/opt/homebrew/opt/pjproject/include",
                    "-I/opt/homebrew/opt/opus/include",
                    "-DPJMEDIA_HAS_OPUS_CODEC=1",
                    "-DPJ_AUTOCONF=1",
                    "-DPJ_IS_BIG_ENDIAN=0",
                    "-DPJ_IS_LITTLE_ENDIAN=1",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L/opt/homebrew/opt/pjproject/lib",
                    "-L/opt/homebrew/opt/openssl@4/lib",
                ]),
                .unsafeFlags(["/opt/homebrew/opt/opus/lib/libopus.a"]),
            ] + pjLibraries.map { .linkedLibrary($0) } + [
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreServices"),
                .linkedFramework("AudioUnit"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Foundation"),
                .linkedFramework("Security"),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("VideoToolbox"),
            ]
        ),
        .target(
            name: "IPPhoneCore",
            dependencies: ["CPJSIPBridge"]
        ),
        .executableTarget(
            name: "IPPhoneApp",
            dependencies: ["IPPhoneCore"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Distribution/Info.plist",
                ]),
            ]
        ),
        .testTarget(
            name: "IPPhoneCoreTests",
            dependencies: ["IPPhoneCore"]
        ),
    ]
)
