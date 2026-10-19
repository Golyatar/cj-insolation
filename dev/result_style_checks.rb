# frozen_string_literal: true
module CJResultStyleChecks
  def self.run
    model = Sketchup.active_model
    before = model.entities.length
    checks = []
    model.start_operation('CJ temporary result styles', true)
    begin
      layers = CJ::ResultStyle.tags(model)
      visibility = layers.values.map { |tag| [tag,tag.visible?] }
      layers.each_value { |tag| tag.visible = true }
      checks << {name:'result_tags_one_folder',passed:layers.values.all? { |tag| tag.folder.name == 'Инсоляция' } && layers.values.uniq.length == 5}
      anchor = (model.bounds.empty? ? ORIGIN : model.bounds.max).offset(Geom::Vector3d.new(100.m,100.m,100.m))
      results = Array.new(90) { {hit_dist:nil} }
      batch = CJ::RayTubesUp.build_batch(model,[{origin:anchor,results:results},{origin:anchor.offset(X_AXIS,1.m),results:[]}],mode: :summary)
      points = batch.entities.grep(Sketchup::Group)
      markers = points.map { |p| p.entities.grep(Sketchup::Group).find { |g| g.layer == layers[:spheres] } }
      if CJ::ResultStyle.radius > 0
        checks << {name:'sphere_pass_fail_colors',passed:markers.map { |m| m.get_attribute('CJ_Insolation','passed') } == [true,false] && markers[0].entities.grep(Sketchup::ComponentInstance)[0].definition.entities.grep(Sketchup::Face)[0].material.color.green > 150}
        checks << {name:'sphere_radius_mm',passed:(markers[0].bounds.width.to_mm - CJ::ResultStyle.radius*2).abs < 0.1}
      else
        checks << {name:'zero_radius_disables_spheres',passed:markers.compact.empty?}
      end
      checks << {name:'labels_separate_tag',passed:points.all? { |p| p.entities.grep(Sketchup::Text).all? { |t| t.layer == layers[:labels] } }}
      definition = CJ::WindowComponents.definition(model)
      orientation = Geom::Transformation.axes(anchor,X_AXIS,Z_AXIS,Geom::Vector3d.new(0,-1,0))
      window = model.entities.add_instance(definition,orientation)
      entry = CJ::WindowComponents.collect(model)[:windows].find { |w| w[:path_ids].include?(window.persistent_id) }
      window_batch = CJ::RayTubesUp.build_batch(model,[entry.merge(results:results)],mode: :summary)
      mark = window_batch.entities.grep(Sketchup::Group)[0].entities.grep(Sketchup::Group)[0]
      face = mark.entities.grep(Sketchup::Face)[0]
      checks << {name:'window_vertical_plane_green_no_sphere',passed:mark.layer==layers[:windows] && face.normal.dot(Z_AXIS).abs<1e-8 && face.material.color.green>150 && mark.entities.grep(Sketchup::ComponentInstance).empty?}
      layers[:windows].visible = false
      visible = model.drawing_element_visible?(Sketchup::InstancePath.new([window_batch,window_batch.entities.grep(Sketchup::Group)[0],mark,face]))
      checks << {name:'window_plane_independent_visibility',passed:!visible && layers[:labels].visible?,plane_visible:visible,labels_visible:layers[:labels].visible?}
    ensure
      visibility&.each { |tag, visible| tag.visible = visible if tag.valid? }
      model.abort_operation
    end
    checks << {name:'style_fixture_rolled_back',passed:model.entities.length==before}
    checks
  end
end
