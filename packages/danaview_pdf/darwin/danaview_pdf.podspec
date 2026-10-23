# OWNER: HOM-24
#
# The CocoaPods spec of danaview_pdf (ARCH v1.2 §4.3, §8): one pod for iOS and macOS (shared darwin/
# sources), at the app's deployment targets (iOS 15.0, macOS 10.15). Classes/Glue/ holds the
# generated Pigeon Swift (PdfApi.g.swift) and the plugin glue; Viewer/ (PDFKit platform view), Text/
# (extraction, search), Tools/, Annotate/, Sign/ and Compress/ hold one capability each. XCTests are
# in Tests/<Capability>/ and run through Tests/Viewer/run_xctests.sh (no app host needed); they are
# not part of the pod. System frameworks only, nothing that opens a socket (rule 21).
Pod::Spec.new do |s|
  s.name             = 'danaview_pdf'
  s.version          = '1.2.0'
  s.summary          = 'Danaview PDF plugin (PDFKit viewer, text and page tools).'
  s.description      = 'Danaview PDF plugin (PDFKit viewer, text and page tools).'
  s.homepage         = 'https://vecvel.com'
  s.license          = { :type => 'Proprietary', :text => 'Copyright Vecvel' }
  s.author           = { 'Vecvel' => 'support@vecvel.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.swift'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '10.15'
  s.frameworks       = 'PDFKit', 'ImageIO', 'CoreGraphics'
  s.ios.frameworks   = 'UIKit'
  s.osx.frameworks   = 'Cocoa'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
