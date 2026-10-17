# IOS-01 spike (V-N9): precompiled `-fcikernel` Metal Core Image kernels shipped from a
# CocoaPods-style library target, the way the danaview_editor_engine plugin pod will ship them.
#
# The kernels are compiled AHEAD of the app build by tools/build_metallibs.sh
# (`metal -c -fcikernel` + `metallib -cikernel`, one metallib per SDK: iphoneos and
# iphonesimulator) and committed under Prebuilt/. The pod ships them as plain resources in its
# resource bundle, so the app build never needs the Metal compiler (Xcode 26 no longer ships it;
# it is the optional "Metal Toolchain" download). Works for static libraries (no `use_frameworks!`,
# the default here) and for `use_frameworks!` (dynamic or static frameworks): see
# tools/verify_pod_linkage.sh.
Pod::Spec.new do |s|
  s.name             = 'DVSpikeKernels'
  s.version          = '0.0.1'
  s.summary          = 'IOS-01 spike: -fcikernel Metal CI kernels in a CocoaPods library target.'
  s.description      = 'Throwaway spike pod (not shipped). Mirrors the planned danaview_editor_engine podspec settings.'
  s.homepage         = 'https://vecvel.com'
  s.license          = { :type => 'Proprietary', :text => 'Copyright Vecvel' }
  s.author           = { 'Vecvel' => 'support@vecvel.com' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.0'
  s.source_files     = 'Classes/**/*.swift'
  s.frameworks       = 'CoreImage', 'Metal'
  # A static library cannot carry resources: the metallibs go into DVSpikeKernels.bundle, which
  # CocoaPods copies into the app (static lib) or the framework (use_frameworks!).
  s.resource_bundles = { 'DVSpikeKernels' => ['Prebuilt/*.metallib'] }
  s.preserve_paths   = 'Kernels/*.ci.metal', 'Prebuilt/BUILD_INFO.txt'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    # D-41: every API newer than the deployment target must be guarded.
    'OTHER_CFLAGS' => '$(inherited) -Werror=unguarded-availability-new',
  }
end
