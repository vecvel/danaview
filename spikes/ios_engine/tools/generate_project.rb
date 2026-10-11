#!/usr/bin/env ruby
# IOS-01 spike: generates DVSpikeHost.xcodeproj (host app + hosted XCTest bundle + UI test bundle).
#
# Run through tools/bootstrap.sh, which uses the xcodeproj gem bundled with CocoaPods and then runs
# `pod install` (local :path pods only, no network). The generated project is throwaway: edit this
# script, not the project.
require 'fileutils'
require 'xcodeproj'

ROOT = File.expand_path('..', __dir__)
PROJECT_PATH = File.join(ROOT, 'DVSpikeHost.xcodeproj')
DEPLOYMENT_TARGET = '15.0'
BUNDLE_ID = 'com.vecvel.danaview.spike.iosengine'

FileUtils.rm_rf(PROJECT_PATH)
project = Xcodeproj::Project.new(PROJECT_PATH)

app = project.new_target(:application, 'DVSpikeHost', :ios, DEPLOYMENT_TARGET, nil, :swift)
unit = project.new_target(:unit_test_bundle, 'DVSpikeTests', :ios, DEPLOYMENT_TARGET, nil, :swift)
ui = project.new_target(:ui_test_bundle, 'DVSpikeUITests', :ios, DEPLOYMENT_TARGET, nil, :swift)
unit.add_dependency(app)
ui.add_dependency(app)

def add_sources(project, target, dir_rel)
  group = project.main_group.find_subpath(dir_rel, true)
  group.set_source_tree('<group>')
  group.set_path(dir_rel)
  Dir.glob(File.join(ROOT, dir_rel, '**', '*.swift')).sort.each do |file|
    ref = group.new_reference(file)
    target.source_build_phase.add_file_reference(ref)
  end
  group
end

add_sources(project, app, 'DVSpikeHost')
add_sources(project, unit, 'DVSpikeTests')
add_sources(project, ui, 'DVSpikeUITests')

# Contract fixtures (CORE-29) are read from the repo, not copied, so the spike checks the real
# grid-cut plan and its expected-active table.
fixtures = project.main_group.new_group('ContractFixtures', '../../packages/danaview_editor_core/test/fixtures/render_plans/contract')
%w[grid_cuts_30fps.json grid_cuts_30fps.expected_active.json].each do |name|
  ref = fixtures.new_reference(File.expand_path(File.join('../../packages/danaview_editor_core/test/fixtures/render_plans/contract', name), ROOT))
  unit.resources_build_phase.add_file_reference(ref)
end

# Committed spike-local fixtures (e.g. the ffmpeg HLG fallback, tools/make_hlg_fixture.sh).
local_fixtures = Dir.glob(File.join(ROOT, 'DVSpikeTests', 'Fixtures', '*')).sort
unless local_fixtures.empty?
  group = project.main_group.find_subpath('DVSpikeTests/Fixtures', true)
  local_fixtures.each do |file|
    unit.resources_build_phase.add_file_reference(group.new_reference(file))
  end
end

common = {
  'IPHONEOS_DEPLOYMENT_TARGET' => DEPLOYMENT_TARGET,
  'SWIFT_VERSION' => '5.0',
  'TARGETED_DEVICE_FAMILY' => '1,2',
  'CODE_SIGN_STYLE' => 'Automatic',
  'CLANG_ENABLE_MODULES' => 'YES',
  'ENABLE_USER_SCRIPT_SANDBOXING' => 'NO',
  # D-41: newer-than-15.0 API use must be guarded (Swift enforces this by default; C/ObjC by flag).
  'OTHER_CFLAGS' => '$(inherited) -Werror=unguarded-availability-new',
}

app.build_configurations.each do |config|
  config.build_settings.merge!(common)
  config.build_settings.merge!(
    'PRODUCT_BUNDLE_IDENTIFIER' => BUNDLE_ID,
    'PRODUCT_NAME' => '$(TARGET_NAME)',
    'INFOPLIST_FILE' => 'DVSpikeHost/App/Info.plist',
    'GENERATE_INFOPLIST_FILE' => 'NO',
    'ENABLE_TESTABILITY' => 'YES',
    'SWIFT_OPTIMIZATION_LEVEL' => config.name == 'Release' ? '-O' : '-Onone',
  )
end

unit.build_configurations.each do |config|
  config.build_settings.merge!(common)
  config.build_settings.merge!(
    'PRODUCT_BUNDLE_IDENTIFIER' => "#{BUNDLE_ID}.tests",
    'PRODUCT_NAME' => '$(TARGET_NAME)',
    'GENERATE_INFOPLIST_FILE' => 'YES',
    'TEST_HOST' => '$(BUILT_PRODUCTS_DIR)/DVSpikeHost.app/DVSpikeHost',
    'BUNDLE_LOADER' => '$(TEST_HOST)',
  )
end

ui.build_configurations.each do |config|
  config.build_settings.merge!(common)
  config.build_settings.merge!(
    'PRODUCT_BUNDLE_IDENTIFIER' => "#{BUNDLE_ID}.uitests",
    'PRODUCT_NAME' => '$(TARGET_NAME)',
    'GENERATE_INFOPLIST_FILE' => 'YES',
    'TEST_TARGET_NAME' => 'DVSpikeHost',
  )
end

project.save

# Shared schemes: DVSpikeHost runs the hosted unit/spike tests; DVSpikeBackground runs the UI test
# that backgrounds an export (real-device fact finding, V-N20/V-N11).
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(unit)
scheme.set_launch_target(app)
scheme.test_action.build_configuration = 'Debug'
# Run tests without LLDB attached (xcodebuild otherwise launches the host with wait_for_debugger,
# which took ~10 min per run on the loaded build machine and perturbs timing measurements).
scheme.test_action.xml_element.attributes['selectedDebuggerIdentifier'] = ''
scheme.test_action.xml_element.attributes['selectedLauncherIdentifier'] = 'Xcode.IDEFoundation.Launcher.PosixSpawn'
scheme.save_as(PROJECT_PATH, 'DVSpikeHost', true)

bg = Xcodeproj::XCScheme.new
bg.add_build_target(app)
bg.add_test_target(ui)
bg.set_launch_target(app)
bg.test_action.xml_element.attributes['selectedDebuggerIdentifier'] = ''
bg.test_action.xml_element.attributes['selectedLauncherIdentifier'] = 'Xcode.IDEFoundation.Launcher.PosixSpawn'
bg.save_as(PROJECT_PATH, 'DVSpikeBackground', true)

puts "Generated #{PROJECT_PATH}"
