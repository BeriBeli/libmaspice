"""Build provenance supplied by the runner that compiles the tested consumer."""
import os

BUILD_INSTRUMENTATION = {
    "swift-boundary-asan": "Swift/C/ObjC ASan; C/ObjC UBSan; Zig ReleaseSafe; prebuilt dependency artifacts not sanitizer-instrumented",
    "swiftpm-release": "SwiftPM Release; Swift/C/ObjC not sanitizer-instrumented; Zig ReleaseSafe",
}

def instrumentation():
    build = os.environ.get("SWIFTSPICE_TEST_BUILD")
    if build is None:
        return "build configuration unspecified; sanitizer coverage not asserted"
    return BUILD_INSTRUMENTATION[build]
