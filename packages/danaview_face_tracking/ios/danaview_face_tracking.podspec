# OWNER: VED-16
#
# Placeholder (D-33) created by INT-101. VED-16 replaces this file: the CocoaPods spec of
# danaview_face_tracking. Until then it builds the empty plugin class in Classes/Glue/ only, at the app's
# deployment targets (iOS 15.0).
Pod::Spec.new do |s|
  s.name             = 'danaview_face_tracking'
  s.version          = '1.2.0'
  s.summary          = 'Danaview face tracking plugin (face mesh, pose, segmentation, video sampling).'
  s.description      = 'Danaview face tracking plugin (face mesh, pose, segmentation, video sampling).'
  s.homepage         = 'https://vecvel.com'
  s.license          = { :type => 'Proprietary', :text => 'Copyright Vecvel' }
  s.author           = { 'Vecvel' => 'support@vecvel.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
