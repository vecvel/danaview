# OWNER: ENG-06 [INTEGRATION] (ENG-01 placeholder -> ENG-07 -> ENG-06). FROZEN 2026-10-11 (D-42):
# later changes need a new lead-approved [INTEGRATION] ticket (BUILD_PLAN §2).
#
# iOS side of the editor engine plugin (ARCH §4.4, §12.6). Build settings from the IOS-01 spike
# (docs/editor/spikes/IOS-01.md §3, V-N9), recorded in ARCH §13.2.
#
# - Platform iOS 15.0, the app's IOS_DEPLOYMENT_TARGET (ARCH §3.1, D-29, D-41; D-43(c) owner
#   defaults 2026-10-08, revisable). OTHER_CFLAGS turns unguarded uses of newer C/ObjC APIs into
#   errors (D-41); Swift already rejects unguarded newer APIs.
# - Frameworks: the engine's AVFoundation / Core Image on Metal stack. BackgroundTasks is weak-linked
#   (ARCH §3.1: BGContinuedProcessingTask is iOS 26 and sits behind #available).
# - Core Image kernels are PREBUILT `-fcikernel` metallibs, one per SDK
#   (vw_kernels.iphoneos.metallib, vw_kernels.iphonesimulator.metallib, plus BUILD_INFO.txt with
#   the source and output SHA-256), built by IOS-09 from Classes/Render/Shaders/VwishKernels.metal
#   with `metal -c -fcikernel -target air64-apple-ios15.0[-simulator]` + `metallib -cikernel`
#   (as spikes/ios_engine/tools/build_metallibs.sh). Xcode 26 ships no Metal toolchain, so the app
#   build never compiles .metal files: source_files is Swift only, and MTL_COMPILER_FLAGS /
#   MTLLINKER_FLAGS are deliberately NOT set. Both metallibs ship in every build (≈ 8 KB each).
# - The metallibs ship in the `VWEditorKernels` resource bundle. It lands at
#   App.app/VWEditorKernels.bundle (static library or static framework linkage) or at
#   App.app/Frameworks/vwish_editor_engine.framework/VWEditorKernels.bundle (dynamic frameworks), so
#   the loader (IOS-09 Kernels.swift) finds it with Bundle(for: <a class of this pod>), never
#   Bundle.main, picks `.iphonesimulator` / `.iphoneos` with `#if targetEnvironment(simulator)`
#   and calls CIKernel(functionName:fromMetalLibraryData:). Until IOS-09 lands the bundle is empty.
#   Guarded by example/ios/RunnerTests/BuildConfig/BuildConfigTests.swift.
# - The privacy manifest ships in its own resource bundle (ARCH §20.4). No bundled media resources:
#   the composition spacer is generated at runtime by IOS-08.
# - Info.plist keys (UIBackgroundModes, BGTaskSchedulerPermittedIdentifiers for the iPad
#   `continued` kind) and the GPU entitlement are app-side (INT-03, IOS-13), not pod settings.
Pod::Spec.new do |s|
  s.name             = 'vwish_editor_engine'
  s.version          = '1.1.0'
  s.summary          = 'Vwish video editor engine (AVFoundation + Core Image on Metal).'
  s.description      = 'Native preview, export and media services for the Vwish video editor.'
  s.homepage         = 'https://vecvel.com'
  s.license          = { :type => 'Proprietary', :text => 'Copyright Vecvel' }
  s.author           = { 'Vecvel' => 'support@vecvel.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.0'
  s.frameworks       = 'AVFoundation', 'CoreImage', 'CoreMedia', 'CoreVideo', 'Metal',
                       'MediaToolbox', 'VideoToolbox'
  s.weak_frameworks  = 'BackgroundTasks'
  s.resource_bundles = {
    'vwish_editor_engine_privacy' => ['Resources/PrivacyInfo.xcprivacy'],
    'VWEditorKernels' => ['Classes/Render/Shaders/Prebuilt/*.metallib'],
  }
  s.preserve_paths   = 'Classes/Render/Shaders/*.metal', 'Classes/Render/Shaders/Prebuilt/BUILD_INFO.txt'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'OTHER_CFLAGS' => '$(inherited) -Werror=unguarded-availability-new',
  }
end
