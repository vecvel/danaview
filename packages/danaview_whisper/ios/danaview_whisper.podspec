# OWNER: AI-05 (skeleton by AI-02)
#
# danaview_whisper for iOS (ai.md §4.4, ARCH D-29/D-41):
#   * Frameworks/WhisperCore.xcframework: whisper.cpp + ggml as a static library (device arm64,
#     simulator arm64 + x86_64), deployment target 15.0, Metal with the embedded library, Accelerate and
#     BLAS off. It is a BUILD OUTPUT (git-ignored): tool/build_ios_xcframework.sh makes it, and this
#     podspec stops `pod install` with a clear message when it is missing.
#   * Classes/dv_whisper_forwarder.cpp compiles the C ABI shim (src/dv_*.cpp) into this pod. Under
#     use_frameworks! the pod is a dynamic framework that exports only dv_* (whisper/ggml are hidden),
#     which Dart opens as danaview_whisper.framework/danaview_whisper (DynamicLibrary.process() fallback).
#   * Classes/*.swift: the device-profile platform channel (AI-06).
#   * Resources/PrivacyInfo.xcprivacy: DiskSpace E174.1 (DeviceProfiler.freeDiskBytes) only; ggml's
#     sysctlbyname/clock_gettime are not required-reason APIs (V-A13, rationale in the manifest).
#   * Metal is linked (MTLCreateSystemDefaultDevice in dv_cpu.cpp and ggml-metal); it exists on every
#     iOS 15 device, so no weak linking is needed. MetalKit is not used by ggml's sources and is not linked.
#     Accelerate is NOT linked (no NEWLAPACK symbols; checked by the build script and check_ios_min_os.sh).
whisper_xcframework = File.join(File.dirname(__FILE__), 'Frameworks', 'WhisperCore.xcframework')
unless File.exist?(File.join(whisper_xcframework, 'Info.plist'))
  whisper_missing_message = <<~MSG
    danaview_whisper: ios/Frameworks/WhisperCore.xcframework is missing.
    It is a build output (git-ignored). Build it once, then run `pod install` / the Flutter build again:

        packages/danaview_whisper/tool/build_ios_xcframework.sh --if-missing

    It needs Xcode and CMake >= 3.28 (brew install cmake); nothing is downloaded.
  MSG
  if defined?(Pod::Informative)
    raise Pod::Informative, whisper_missing_message
  else
    raise whisper_missing_message
  end
end

Pod::Spec.new do |s|
  s.name             = 'danaview_whisper'
  s.version          = '1.1.0'
  s.summary          = 'On-device speech recognition (whisper.cpp) for Danaview Auto captions.'
  s.description      = 'FFI plugin wrapping a small C ABI over whisper.cpp; iOS and Android only.'
  s.homepage         = 'https://vecvel.com'
  s.license          = { :type => 'Proprietary', :text => 'Copyright Vecvel; third-party notices in LICENSE-THIRD-PARTY.md' }
  s.author           = { 'Vecvel' => 'support@vecvel.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.{swift,cpp,h}'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'
  s.swift_version = '5.0'

  s.vendored_frameworks = 'Frameworks/WhisperCore.xcframework'
  s.frameworks = 'Metal', 'Foundation'
  s.libraries = 'c++'
  s.resource_bundles = { 'danaview_whisper_privacy' => ['Resources/PrivacyInfo.xcprivacy'] }

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    # The forwarder #includes ../../src/*.cpp; they include whisper.h / ggml.h from the vendored tree
    # (the same headers the xcframework was built from and ships).
    'HEADER_SEARCH_PATHS' => '$(inherited) "${PODS_TARGET_SRCROOT}/../src" ' \
                             '"${PODS_TARGET_SRCROOT}/../third_party/whisper.cpp/include" ' \
                             '"${PODS_TARGET_SRCROOT}/../third_party/whisper.cpp/ggml/include"',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) DV_IOS=1',
    # D-41: any API newer than iOS 15.0 must sit behind @available / __builtin_available.
    'OTHER_CFLAGS' => '$(inherited) -Werror=unguarded-availability-new',
    # The shim's internal C++ (namespace dv) stays hidden; only DV_API (visibility "default") is exported.
    'OTHER_CPLUSPLUSFLAGS' => '$(inherited) -Werror=unguarded-availability-new -fvisibility=hidden -fvisibility-inlines-hidden',
    # ggml's embedded Metal library is assembled from a .s file whose start/end labels are global
    # (-fvisibility does not apply to assembly); keep them out of the framework's export table.
    'OTHER_LDFLAGS' => '$(inherited) -Wl,-unexported_symbol,_ggml_metallib_*',
  }
end
