#!/usr/bin/env ruby
# Adds the BirdWidget app-extension target to BirdApp.xcodeproj and wires the
# App Group on both targets. Idempotent: removes any previous BirdWidget wiring
# first, so it's safe to re-run. Mirrors the proven RadioApp recipe.
require 'xcodeproj'

TEAM    = 'JKMR84FU58'
GROUP   = 'group.Altamirano.BirdApp'
DEPLOY  = '26.5'
SHARED_FILES = %w[BirdWidgetShared.swift BirdIntents.swift]
WIDGET_FILES = %w[BirdWidgetBundle.swift ListenWidget.swift LastBirdWidget.swift]
WIDGET_LANGS = %w[en es fr de it pt-PT]   # localized Localizable.strings for the widget

project_path = File.expand_path('../BirdApp.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)

app_target = project.targets.find { |t| t.name == 'BirdApp' }
raise 'App target not found' unless app_target

# --- clean any previous run ---------------------------------------------------
app_target.dependencies.dup.each do |dep|
  if dep.target.nil? || (dep.target.respond_to?(:name) && dep.target.name == 'BirdWidget')
    app_target.dependencies.delete(dep)
    dep.remove_from_project
  end
end
app_target.copy_files_build_phases.select { |ph| ph.name == 'Embed Foundation Extensions' }.each do |ph|
  app_target.build_phases.delete(ph)
  ph.remove_from_project
end
# shared files already explicitly on the app target (avoid duplicate symbols)
app_target.source_build_phase.files.dup.each do |bf|
  name = bf.display_name.to_s
  if bf.file_ref.nil? || SHARED_FILES.any? { |f| name.include?(f.sub('.swift', '')) }
    app_target.source_build_phase.files.delete(bf)
    bf.remove_from_project
  end
end
project.targets.select { |t| t.name == 'BirdWidget' }.each(&:remove_from_project)
['BirdWidget', 'Shared'].each do |name|
  grp = project.main_group.children.find { |c| c.respond_to?(:display_name) && c.display_name == name }
  grp.remove_from_project if grp
end
project.products_group.children.dup.each do |ref|
  ref.remove_from_project if ref.respond_to?(:path) && ref.path.to_s.include?('BirdWidget.appex')
end

# --- app target: attach the App Group entitlements ----------------------------
app_target.build_configurations.each do |config|
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'BirdApp/BirdApp.entitlements'
end

# --- create the widget target -------------------------------------------------
widget = project.new_target(:app_extension, 'BirdWidget', :ios, DEPLOY, nil, :swift)

# The gem auto-links Foundation.framework with a hardcoded (wrong) SDK path; drop it.
widget.frameworks_build_phase.files.dup.each do |bf|
  bf.remove_from_project if bf.display_name.to_s.include?('Foundation')
end

widget.build_configurations.each do |config|
  bs = config.build_settings
  bs['PRODUCT_BUNDLE_IDENTIFIER'] = 'Altamirano.BirdApp.BirdWidget'
  bs['PRODUCT_NAME'] = '$(TARGET_NAME)'
  bs['INFOPLIST_FILE'] = 'BirdWidget/Info.plist'
  bs['GENERATE_INFOPLIST_FILE'] = 'NO'
  bs['CODE_SIGN_ENTITLEMENTS'] = 'BirdWidget/BirdWidget.entitlements'
  bs['CODE_SIGN_STYLE'] = 'Automatic'
  bs['DEVELOPMENT_TEAM'] = TEAM
  bs['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOY
  bs['SWIFT_VERSION'] = '5.0'
  bs['TARGETED_DEVICE_FAMILY'] = '1,2'
  bs['SKIP_INSTALL'] = 'YES'
  bs['SWIFT_EMIT_LOC_STRINGS'] = 'YES'
  bs['MARKETING_VERSION'] = '1.0'
  bs['CURRENT_PROJECT_VERSION'] = '1'
  bs['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']
end

# --- source files (group path is the folder; refs are bare filenames) ---------
widget_group = project.main_group.new_group('BirdWidget', 'BirdWidget')
WIDGET_FILES.each { |f| widget.add_file_references([widget_group.new_reference(f)]) }

# --- localized Localizable.strings (one PBXVariantGroup, one ref per language) -
variant = project.new(Xcodeproj::Project::Object::PBXVariantGroup)
variant.name = 'Localizable.strings'
variant.source_tree = '<group>'
WIDGET_LANGS.each do |lang|
  ref = project.new(Xcodeproj::Project::Object::PBXFileReference)
  ref.path = "#{lang}.lproj/Localizable.strings"   # resolved relative to the BirdWidget group
  ref.name = lang
  ref.source_tree = '<group>'
  ref.last_known_file_type = 'text.plist.strings'
  variant.children << ref
end
widget_group.children << variant
widget.resources_build_phase.add_file_reference(variant)

# shared models/intents — compiled into BOTH targets
shared_group = project.main_group.new_group('Shared', 'Shared')
SHARED_FILES.each do |f|
  ref = shared_group.new_reference(f)
  widget.add_file_references([ref])
  app_target.add_file_references([ref])
end

# --- embed the extension in the app ------------------------------------------
app_target.add_dependency(widget)
embed = app_target.new_copy_files_build_phase('Embed Foundation Extensions')
embed.symbol_dst_subfolder_spec = :plug_ins
build_file = embed.add_file_reference(widget.product_reference)
build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

project.save
puts "OK: targets = #{project.targets.map(&:name).join(', ')}"
