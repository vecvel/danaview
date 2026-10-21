# OWNER: HOM-02
#
# Placeholder (D-33) created by INT-101. HOM-02 replaces this file: the CocoaPods spec of
# danaview_library_native. Until then it builds the empty plugin class in Classes/Glue/ only, at the app's
# deployment targets (iOS 15.0, macOS 10.15).
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
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
