# OWNER: HOM-02
#
# The CocoaPods spec of danaview_library_native (ARCH v1.2 §4.3, §8): one pod for iOS and macOS
# (shared darwin/ sources), at the app's deployment targets (iOS 15.0, macOS 10.15). Classes/Glue/
# holds the generated Pigeon Swift (LibraryApi.g.swift) and the plugin glue; each native capability
# lives in its own Classes/<Capability>/ directory. XCTests are in Tests/<Capability>/ and run
# through Tests/PhotoLibrary/run_xctests.sh (no app host needed); they are not part of the pod.
# System frameworks only, nothing that opens a socket (rule 21).
Pod::Spec.new do |s|
  s.name             = 'danaview_library_native'
  s.version          = '1.2.0'
  s.summary          = 'Danaview library native plugin (photo library, pickers, save out, share, open in, Quick Look, thumbnails, inbox).'
  s.description      = 'Danaview library native plugin (photo library, pickers, save out, share, open in, Quick Look, thumbnails, inbox).'
  s.homepage         = 'https://vecvel.com'
  s.license          = { :type => 'Proprietary', :text => 'Copyright Vecvel' }
  s.author           = { 'Vecvel' => 'support@vecvel.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.swift'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '10.15'
  s.frameworks       = 'Photos', 'ImageIO'
  s.ios.frameworks   = 'PhotosUI', 'UIKit'
  s.osx.frameworks   = 'Cocoa'
  s.weak_frameworks  = 'UniformTypeIdentifiers'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
