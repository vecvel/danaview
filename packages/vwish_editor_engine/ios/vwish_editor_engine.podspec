# OWNER: ENG-07 (from ENG-01's placeholder; ENG-06 adds the IOS-01 spike build settings, then freezes it)
#
# iOS side of the editor engine plugin (ARCH §4.4, §12.6). Platform iOS 15.0, the app's
# IOS_DEPLOYMENT_TARGET (ARCH §3.1, D-29, D-41; D-43(c) owner defaults 2026-10-08, revisable).
# OTHER_CFLAGS turns unguarded uses of newer C/ObjC APIs into errors (D-41); Swift already rejects
# unguarded newer APIs. The privacy manifest ships in its own resource bundle (ARCH §20.4). No
# bundled media resources: the composition spacer is generated at runtime by IOS-08. ENG-06 adds the
# frameworks and the prebuilt Core Image kernel metallibs (IOS-01 §3; no .metal sources under
# Classes/, Xcode 26 has no Metal toolchain).
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
  s.resource_bundles = { 'vwish_editor_engine_privacy' => ['Resources/PrivacyInfo.xcprivacy'] }
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'OTHER_CFLAGS' => '$(inherited) -Werror=unguarded-availability-new',
  }
end
