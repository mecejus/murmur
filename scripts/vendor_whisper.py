#!/usr/bin/env python3
"""Copy the parts of a whisper.cpp release that murmur builds into Vendor/whisper.

whisper.cpp's own build is CMake. This machine-independent script replaces it
with a fixed file list SwiftPM can compile, so the project builds with nothing
but `swift build`: CPU (NEON + Accelerate), BLAS (Accelerate) and Metal.

CMake normally generates two things at build time; this script generates them
once instead and they are committed with the sources:
  - ggml-version.h
  - the embedded Metal shader sources: the preprocessed text of each kernel
    kind in metal/, and an assembly file per kind that .incbin's it between
    the ggml_metallib_<kind>_start/_end symbols ggml-metal-device.m reads. The shaders are compiled by the Metal framework at model load, so
    no Metal compiler (full Xcode) is needed to build murmur.

Usage: scripts/vendor_whisper.py /path/to/whisper.cpp-<version> <version>
"""

import pathlib
import re
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEST = ROOT / "Vendor" / "whisper"

GGML_HEADERS = [
    "ggml.h", "ggml-alloc.h", "ggml-backend.h", "ggml-cpu.h", "ggml-metal.h",
    "ggml-blas.h", "gguf.h", "ggml-cpp.h", "ggml-opt.h",
]

GGML_SRC = [
    "ggml.c", "ggml.cpp", "ggml-alloc.c", "ggml-backend.cpp",
    "ggml-backend-meta.cpp", "ggml-backend-reg.cpp", "ggml-opt.cpp",
    "ggml-threading.cpp", "ggml-threading.h", "ggml-quants.c", "ggml-quants.h",
    "gguf.cpp", "ggml-common.h", "ggml-impl.h", "ggml-backend-impl.h",
    "ggml-feats.h", "ggml-backend-dl.h", "ggml-backend-dl.cpp",
]

CPU_SRC = [
    "ggml-cpu.c", "ggml-cpu.cpp", "repack.cpp", "repack.h", "hbm.cpp", "hbm.h",
    "quants.c", "quants.h", "traits.cpp", "traits.h", "ggml-cpu-impl.h",
    "common.h", "binary-ops.h", "binary-ops.cpp", "unary-ops.h",
    "unary-ops.cpp", "simd-mappings.h", "simd-gemm.h", "vec.h", "vec.cpp",
    "ops.h", "ops.cpp", "arch-fallback.h",
    "arch/arm/quants.c", "arch/arm/repack.cpp", "arch/arm/cpu-feats.cpp",
    # x86-only paths, compiled upstream on every platform; empty on ARM.
    "amx/amx.cpp", "amx/amx.h", "amx/common.h", "amx/mmq.cpp", "amx/mmq.h",
    "tiled/tiled.cpp", "tiled/tiled.h", "tiled/tiled-kernel.cpp", "tiled/tiled-kernel.h",
    "llamafile/sgemm.h",
]

METAL_SRC = [
    "ggml-metal.cpp", "ggml-metal-device.m", "ggml-metal-device.cpp",
    "ggml-metal-common.cpp", "ggml-metal-context.m", "ggml-metal-fusion.cpp",
    "ggml-metal-ops.cpp", "ggml-metal-tuning.cpp", "ggml-metal-common.h",
    "ggml-metal-context.h", "ggml-metal-device.h", "ggml-metal-impl.h",
    "ggml-metal-ops.h", "ggml-metal-fusion.h", "ggml-metal-tuning.h",
]

# Must match GGML_METAL_LIBS in ggml-metal-device.m and METALLIB_KERNEL_SOURCES
# in ggml-metal/CMakeLists.txt. Read from the CMake file below so a release
# that adds a kernel fails loudly here rather than at model load.
KERNEL_HEADERS = ["common.h", "dequantize.h", "quantize.h", "fa_common.metal", "fa_vec_common.metal"]


def copy(src_root, rel_paths, dest_dir, src_sub):
    for rel in rel_paths:
        src = src_root / src_sub / rel
        dst = dest_dir / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)


def kernel_kinds(src_root):
    cmake = (src_root / "ggml/src/ggml-metal/CMakeLists.txt").read_text()
    block = re.search(r"set\(METALLIB_KERNEL_SOURCES(.*?)\)", cmake, re.S).group(1)
    return re.findall(r"kernels/(\w+)\.metal", block)


def embed_metal(src_root, out_dir, text_dir):
    kdir = src_root / "ggml/src/ggml-metal/kernels"
    common = (src_root / "ggml/src/ggml-common.h").read_text()
    impl = (src_root / "ggml/src/ggml-metal/ggml-metal-impl.h").read_text()
    out_dir.mkdir(parents=True, exist_ok=True)
    text_dir.mkdir(parents=True, exist_ok=True)
    kinds = kernel_kinds(src_root)
    for kind in kinds:
        src = (kdir / f"{kind}.metal").read_text()
        # Same steps as the CMake recipe: prepend the shared headers this
        # kernel includes, drop the includes, inline ggml-common.h and
        # ggml-metal-impl.h.
        headers = ["common.h"]
        for h in KERNEL_HEADERS[1:]:
            if f'#include "{h}"' in src:
                headers.append(h)
        text = "".join((kdir / h).read_text() for h in headers) + src
        lines = []
        for line in text.splitlines(keepends=True):
            if any(f'#include "{h}"' in line for h in KERNEL_HEADERS) or "#pragma once" in line:
                continue
            if "__embed_ggml-common.h__" in line:
                lines.append(common)
                continue
            if '#include "ggml-metal-impl.h"' in line:
                lines.append(impl)
                continue
            lines.append(line)
        (text_dir / f"{kind}.metal.txt").write_text("".join(lines))
        sym = kind.replace("-", "_")
        # .incbin finds the text through the target's header search path
        # (Package.swift adds Vendor/whisper/metal).
        with open(out_dir / f"metallib-{kind}.s", "w") as f:
            f.write("// Generated by scripts/vendor_whisper.py. Do not edit.\n")
            f.write(".section __DATA,__ggml_metallib\n")
            f.write(f".globl _ggml_metallib_{sym}_start\n_ggml_metallib_{sym}_start:\n")
            f.write(f'.incbin "{kind}.metal.txt"\n')
            f.write(f".globl _ggml_metallib_{sym}_end\n_ggml_metallib_{sym}_end:\n")
    return kinds


# Local fixes to upstream, applied as exact text substitutions so a release
# that changes the surrounding code fails here instead of silently skipping.
PATCHES = [
    (
        "src/whisper.cpp",
        # Language auto-detection in whisper_full ran before the call's
        # audio_ctx was stored in the state, so it encoded with whatever
        # audio_ctx the *previous* call used: a stale, possibly too short
        # window (garbage language guesses), or a second full 30 s encode.
        # Store it first.
        """    // auto-detect language if not specified
    if (params.language == nullptr""",
        """    // overwrite audio_ctx before language detection, which encodes with it
    // (murmur patch, see scripts/vendor_whisper.py)
    if (params.audio_ctx > whisper_n_audio_ctx(ctx)) {
        WHISPER_LOG_ERROR("%s: audio_ctx is larger than the maximum allowed (%d > %d)\\n", __func__, params.audio_ctx, whisper_n_audio_ctx(ctx));
        return -5;
    }
    state->exp_n_audio_ctx = params.audio_ctx;

    // true once language detection has encoded the window at seek 0
    bool lang_detect_encoded = false;

    // auto-detect language if not specified
    if (params.language == nullptr""",
    ),
    (
        "src/whisper.cpp",
        # Detection encodes the first window, then the main loop encoded the
        # very same window again: on large models that doubled the time of
        # every auto-language dictation. Remember the detection encode...
        """        state->lang_id = lang_id;
        params.language = whisper_lang_str(lang_id);
""",
        """        state->lang_id = lang_id;
        params.language = whisper_lang_str(lang_id);
        lang_detect_encoded = true;
""",
    ),
    (
        "src/whisper.cpp",
        # ...and skip the main loop's first encode when it is the same one.
        # The decoder state the detection step used is reset below; the
        # encoder output and cross-attention cache it leaves are exactly what
        # this encode would have produced.
        """        // encode audio features starting at offset seek
        if (!whisper_encode_internal(*ctx, *state, seek, params.n_threads, params.abort_callback, params.abort_callback_user_data)) {""",
        """        // encode audio features starting at offset seek
        // (murmur patch: reuse the language-detection encode of window 0)
        const bool reuse_encode = lang_detect_encoded && seek == 0;
        lang_detect_encoded = false;
        if (!reuse_encode && !whisper_encode_internal(*ctx, *state, seek, params.n_threads, params.abort_callback, params.abort_callback_user_data)) {""",
    ),
]


def apply_patches():
    for rel, old, new in PATCHES:
        path = DEST / rel
        text = path.read_text()
        if text.count(old) != 1:
            sys.exit(f"patch for {rel} no longer applies; review it against this release")
        path.write_text(text.replace(old, new))


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src_root = pathlib.Path(sys.argv[1]).resolve()
    version = sys.argv[2]

    if DEST.exists():
        shutil.rmtree(DEST)
    DEST.mkdir(parents=True)

    copy(src_root, ["whisper.h"], DEST / "include", "include")
    copy(src_root, GGML_HEADERS, DEST / "include", "ggml/include")
    # The ANE encoder is compiled in upstream unconditionally and only used
    # when ANEFORGE_ENCODER is set; murmur clears that variable at startup.
    copy(src_root, ["whisper.cpp", "whisper-arch.h", "aneforge/whisper-aneforge.h",
                    "aneforge/whisper-aneforge.cpp"], DEST / "src", "src")
    copy(src_root, GGML_SRC, DEST / "ggml", "ggml/src")
    copy(src_root, CPU_SRC, DEST / "ggml/ggml-cpu", "ggml/src/ggml-cpu")
    copy(src_root, METAL_SRC, DEST / "ggml/ggml-metal", "ggml/src/ggml-metal")
    copy(src_root, ["ggml-blas.cpp"], DEST / "ggml/ggml-blas", "ggml/src/ggml-blas")
    shutil.copy2(src_root / "LICENSE", DEST / "LICENSE")

    (DEST / "ggml/ggml-version.h").write_text(
        f'#pragma once\n\n#define GGML_VERSION "{version}"\n#define GGML_COMMIT  "v{version}"\n'
    )
    apply_patches()
    kinds = embed_metal(src_root, DEST / "ggml/ggml-metal/embed", DEST / "metal")
    # Swift sees only the C API. SwiftPM's generated umbrella would also pull
    # in ggml-cpp.h, which is C++.
    (DEST / "include/module.modulemap").write_text(
        'module CWhisper {\n    header "whisper.h"\n    header "ggml-backend.h"\n    export *\n}\n'
    )
    (DEST / "VERSION").write_text(f"whisper.cpp v{version}\n")
    print(f"vendored whisper.cpp v{version}: {len(kinds)} Metal kernel kinds")


if __name__ == "__main__":
    main()
