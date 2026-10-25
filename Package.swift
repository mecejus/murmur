// swift-tools-version:6.0
import PackageDescription

// whisper.cpp is vendored (see scripts/vendor_whisper.py) and compiled here
// directly, so the whole project builds with `swift build` and links into a
// single binary: no CMake, no dylibs, no Metal compiler.
let ggmlDefines: [(String, String?)] = [
    ("NDEBUG", nil),
    ("GGML_USE_CPU", nil),
    ("GGML_USE_METAL", nil),
    ("GGML_USE_BLAS", nil),
    ("GGML_USE_ACCELERATE", nil),
    ("GGML_BLAS_USE_ACCELERATE", nil),
    ("ACCELERATE_NEW_LAPACK", nil),
    ("ACCELERATE_LAPACK_ILP64", nil),
    ("GGML_METAL_EMBED_LIBRARY", nil),
    ("GGML_METAL_NDEBUG", nil),
    ("GGML_SCHED_MAX_COPIES", "4"),
    ("_DARWIN_C_SOURCE", nil),
    ("_XOPEN_SOURCE", "600"),
    ("WHISPER_VERSION", "\"1.9.5\""),
]
let ggmlHeaderPaths = [
    "include", "ggml", "ggml/ggml-cpu", "ggml/ggml-metal",
    // .incbin in ggml/ggml-metal/embed/*.s resolves through this.
    "metal",
]
let ggmlFlags = ["-O3", "-mcpu=apple-m1", "-fno-objc-arc", "-Wno-shorten-64-to-32"]

let ggmlC: [CSetting] =
    ggmlDefines.map { .define($0.0, to: $0.1) } +
    ggmlHeaderPaths.map { .headerSearchPath($0) } +
    [.unsafeFlags(ggmlFlags)]
let ggmlCXX: [CXXSetting] =
    ggmlDefines.map { .define($0.0, to: $0.1) } +
    ggmlHeaderPaths.map { .headerSearchPath($0) } +
    [.unsafeFlags(ggmlFlags)]

let package = Package(
    name: "murmur",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "murmur", targets: ["murmur"]),
    ],
    targets: [
        .target(
            name: "CWhisper",
            path: "Vendor/whisper",
            exclude: ["metal", "LICENSE", "VERSION"],
            sources: ["src", "ggml"],
            publicHeadersPath: "include",
            cSettings: ggmlC,
            cxxSettings: ggmlCXX,
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
        // The only code on CoreAudio's real-time thread: the input callback
        // and the lock-free ring it writes into. Plain C so nothing on that
        // thread can allocate, take a lock or touch a language runtime.
        .target(
            name: "CRealtime",
            path: "Sources/CRealtime",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
            ]
        ),
        .target(
            name: "MurmurCore",
            dependencies: ["CWhisper", "CRealtime"],
            path: "Sources/MurmurCore",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .executableTarget(
            name: "murmur",
            dependencies: ["MurmurCore"],
            path: "Sources/murmur",
            linkerSettings: [
                // An embedded Info.plist gives the bare binary an identity
                // for the microphone and Accessibility permission prompts.
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist", "-Xlinker", "Resources/Info.plist"]),
            ]
        ),
        .testTarget(
            name: "MurmurCoreTests",
            dependencies: ["MurmurCore"],
            path: "Tests/MurmurCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
