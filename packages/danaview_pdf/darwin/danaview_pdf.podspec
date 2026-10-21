# OWNER: HOM-24
#
# Placeholder (D-33) created by INT-101. HOM-24 replaces this file: the CocoaPods spec of
# danaview_pdf. Until then it builds the empty plugin class in Classes/Glue/ only, at the app's
# deployment targets (iOS 15.0, macOS 10.15).
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
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
