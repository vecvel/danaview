# IOS-01 spike (V-N9, alternative): `[[stitchable]]` Metal Core Image kernels (iOS 15+), compiled
# without -fcikernel but linked with `-framework CoreImage` (tools/build_metallibs.sh), loaded with
# the same CIKernel(functionName:fromMetalLibraryData:) call. Compared against DVSpikeKernels.
Pod::Spec.new do |s|
  s.name             = 'DVSpikeStitchable'
  s.version          = '0.0.1'
  s.summary          = 'IOS-01 spike: [[stitchable]] Metal CI kernels without -fcikernel.'
  s.description      = 'Throwaway spike pod (not shipped).'
  s.homepage         = 'https://vecvel.com'
  s.license          = { :type => 'Proprietary', :text => 'Copyright Vecvel' }
  s.author           = { 'Vecvel' => 'support@vecvel.com' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.0'
  s.source_files     = 'Classes/**/*.swift'
  s.frameworks       = 'CoreImage', 'Metal'
  s.resource_bundles = { 'DVSpikeStitchable' => ['Prebuilt/*.metallib'] }
  s.preserve_paths   = 'Kernels/*.metal', 'Prebuilt/BUILD_INFO.txt'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'OTHER_CFLAGS' => '$(inherited) -Werror=unguarded-availability-new',
  }
end
