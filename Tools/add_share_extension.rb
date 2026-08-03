#!/usr/bin/env ruby
# Adds the BirdShare share-extension target (the "BirdApp" entry in the Photos
# share sheet) to BirdApp.xcodeproj. Idempotent for its own wiring only: it
# removes any previous BirdShare target/group/dependency first and never touches
# BirdWidget, so it is safe to re-run on a project that already has the widget.
#
# Companion to add_widget_target.rb — same recipe, different extension point.
require 'xcodeproj'

TEAM     = 'JKMR84FU58'
DEPLOY   = '26.5'
NAME     = 'BirdShare'
BUNDLE   = 'Altamirano.BirdApp.BirdShare'
SOURCES  = %w[ShareViewController.swift]
# Compiled into BOTH the app and the extension: the App Group inbox they hand
# the photo through.
SHARED   = %w[SharedPhotoInbox.swift]
LANGS    = %w[en es fr de it pt-PT]

project_path = File.expand_path('../BirdApp.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)

app_target = project.targets.find { |t| t.name == 'BirdApp' }
raise 'App target not found' unless app_target

# --- clean any previous run of THIS script ------------------------------------
app_target.dependencies.dup.each do |dep|
  if dep.target.respond_to?(:name) && dep.target.name == NAME
    app_target.dependencies.delete(dep)
    dep.remove_from_project
  end
end
project.targets.select { |t| t.name == NAME }.each(&:remove_from_project)

# the shared file, wherever it was previously referenced
app_target.source_build_phase.files.dup.each do |bf|
  next unless bf.file_ref.nil? || SHARED.include?(bf.display_name.to_s)
  app_target.source_build_phase.files.delete(bf)
  bf.remove_from_project
end
shared_group = project.main_group.children.find { |c| c.respond_to?(:display_name) && c.display_name == 'Shared' }
raise 'Shared group not found (run add_widget_target.rb first)' unless shared_group
shared_group.children.dup.each do |ref|
  ref.remove_from_project if SHARED.include?(ref.display_name.to_s)
end

grp = project.main_group.children.find { |c| c.respond_to?(:display_name) && c.display_name == NAME }
grp.remove_from_project if grp
project.products_group.children.dup.each do |ref|
  ref.remove_from_project if ref.respond_to?(:path) && ref.path.to_s == "#{NAME}.appex"
end

# --- create the extension target ----------------------------------------------
ext = project.new_target(:app_extension, NAME, :ios, DEPLOY, nil, :swift)

# The gem auto-links Foundation.framework with a hardcoded (wrong) SDK path; drop it.
ext.frameworks_build_phase.files.dup.each do |bf|
  bf.remove_from_project if bf.display_name.to_s.include?('Foundation')
end

ext.build_configurations.each do |config|
  bs = config.build_settings
  bs['PRODUCT_BUNDLE_IDENTIFIER'] = BUNDLE
  bs['PRODUCT_NAME'] = '$(TARGET_NAME)'
  bs['INFOPLIST_FILE'] = "#{NAME}/Info.plist"
  bs['GENERATE_INFOPLIST_FILE'] = 'NO'
  bs['CODE_SIGN_ENTITLEMENTS'] = "#{NAME}/#{NAME}.entitlements"
  bs['CODE_SIGN_STYLE'] = 'Automatic'
  bs['DEVELOPMENT_TEAM'] = TEAM
  bs['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOY
  bs['SWIFT_VERSION'] = '5.0'
  # Match the app so the shared file compiles the same way in both targets.
  bs['SWIFT_APPROACHABLE_CONCURRENCY'] = 'YES'
  bs['SWIFT_DEFAULT_ACTOR_ISOLATION'] = 'MainActor'
  bs['TARGETED_DEVICE_FAMILY'] = '1,2'
  bs['SKIP_INSTALL'] = 'YES'
  bs['SWIFT_EMIT_LOC_STRINGS'] = 'YES'
  # Copied from the app so the two bundles agree — Xcode warns when an embedded
  # extension's version differs. Re-run this script after bumping the app's.
  app_config = app_target.build_configurations.find { |c| c.name == config.name } || app_target.build_configurations.first
  bs['MARKETING_VERSION'] = app_config.build_settings['MARKETING_VERSION'] || '1.0'
  bs['CURRENT_PROJECT_VERSION'] = app_config.build_settings['CURRENT_PROJECT_VERSION'] || '1'
  bs['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']
end

# --- source files (group path is the folder; refs are bare filenames) ---------
ext_group = project.main_group.new_group(NAME, NAME)
SOURCES.each { |f| ext.add_file_references([ext_group.new_reference(f)]) }
ext_group.new_reference('Info.plist')
ext_group.new_reference("#{NAME}.entitlements")

# --- localized Localizable.strings (one PBXVariantGroup, one ref per language) -
variant = project.new(Xcodeproj::Project::Object::PBXVariantGroup)
variant.name = 'Localizable.strings'
variant.source_tree = '<group>'
LANGS.each do |lang|
  ref = project.new(Xcodeproj::Project::Object::PBXFileReference)
  ref.path = "#{lang}.lproj/Localizable.strings"   # relative to the BirdShare group
  ref.name = lang
  ref.source_tree = '<group>'
  ref.last_known_file_type = 'text.plist.strings'
  variant.children << ref
end
ext_group.children << variant
ext.resources_build_phase.add_file_reference(variant)

# --- the inbox, compiled into both targets ------------------------------------
SHARED.each do |f|
  ref = shared_group.new_reference(f)
  ext.add_file_references([ref])
  app_target.add_file_references([ref])
end

# --- embed the extension in the app -------------------------------------------
app_target.add_dependency(ext)
embed = app_target.copy_files_build_phases.find { |ph| ph.name == 'Embed Foundation Extensions' }
unless embed
  embed = app_target.new_copy_files_build_phase('Embed Foundation Extensions')
  embed.symbol_dst_subfolder_spec = :plug_ins
end
embed.files.dup.each do |bf|
  if bf.file_ref.nil? || bf.display_name.to_s == "#{NAME}.appex"
    embed.files.delete(bf)
    bf.remove_from_project
  end
end
build_file = embed.add_file_reference(ext.product_reference)
build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

project.save
puts "OK: targets = #{project.targets.map(&:name).join(', ')}"
