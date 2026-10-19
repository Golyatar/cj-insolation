# frozen_string_literal: true
require 'json'
require 'tmpdir'

module CJExportVisibilityChecks
  extend self
  ExportView = Struct.new(:entities, :definitions, :layers, :rendering_options) unless const_defined?(:ExportView, false)

  def quad(entities, x)
    entities.add_face([x,0,0],[x+1.m,0,0],[x+1.m,1.m,0],[x,1.m,0])
  end

  def run
    model = Sketchup.active_model
    raise 'Exit group editing' if model.active_path
    before = model.entities.length
    old_options = %w[DrawHiddenGeometry DrawHiddenObjects].to_h { |key| [key,model.rendering_options[key]] }
    checks = []
    directory = Dir.mktmpdir('cj-export-check-')
    model.start_operation('CJ temporary export visibility checks',true)
    begin
      fixture = model.entities.add_group
      quad(fixture.entities,0)
      quad(fixture.entities,2.m).hidden = true
      hidden = fixture.entities.add_group
      quad(hidden.entities,0)
      hidden.hidden = true
      tag = model.layers.add('CJ_TEMP_HIDDEN_TAG')
      quad(fixture.entities,4.m).layer = tag
      tag.visible = false
      folder = model.layers.add_folder('CJ_TEMP_HIDDEN_FOLDER')
      child_folder = folder.add_folder('nested')
      folder_tag = model.layers.add('CJ_TEMP_FOLDER_TAG')
      child_folder.add_layer(folder_tag)
      container = fixture.entities.add_group
      quad(container.entities,0)
      container.layer = folder_tag
      folder.visible = false
      icon = File.expand_path('../src/icons/insolation.png',__dir__)
      fixture.entities.add_image(icon,[6.m,0,0],1.m)
      fixture.entities.add_image(icon,[8.m,0,0],1.m).hidden = true
      plane = fixture.entities.add_section_plane([0,0,-1.m],[0,0,1])
      plane.activate
      view = ExportView.new(fixture.entities,model.definitions.select(&:image?),model.layers,{'DisplaySectionCuts'=>false})
      count = CJ::NativeEngine.write_input(File.join(directory,'input.bin'),view,[Geom::Point3d.new(0,0,1.m)],[Z_AXIS])
      checks << {name:'only_visible_face_and_image_exported',passed:count==4,triangles:count}
      old_options.each_key { |key| model.rendering_options[key] = true }
      count = CJ::NativeEngine.write_input(File.join(directory,'shown.bin'),view,[Geom::Point3d.new(0,0,1.m)],[Z_AXIS])
      checks << {name:'show_hidden_options_do_not_include_hidden_geometry',passed:count==4}
      view.rendering_options['DisplaySectionCuts'] = true
      refused = false
      begin
        CJ::NativeEngine.write_input(File.join(directory,'section.bin'),view,[Geom::Point3d.new(0,0,1.m)],[Z_AXIS])
      rescue CJ::NativeEngine::Unsupported
        refused = true
      end
      checks << {name:'enabled_section_cuts_still_require_fallback',passed:refused}
    ensure
      old_options.each { |key,value| model.rendering_options[key] = value }
      model.abort_operation
      FileUtils.remove_entry(directory)
    end
    checks << {name:'user_geometry_preserved',passed:!fixture.valid? && model.entities.length==before}
    report = {passed:checks.all? { |c| c[:passed] },checks:checks}
    File.write(File.expand_path('../reports/export_visibility_check.json',__dir__),JSON.pretty_generate(report))
    report
  end
end
