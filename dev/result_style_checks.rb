# frozen_string_literal: true
module CJResultStyleChecks
  def self.run
    model = Sketchup.active_model
    before = model.entities.length
    checks = []
    model.start_operation('CJ temporary result styles', true)
    begin
      sets = CJ::ResultStyle.organize_existing(model)
      layers = sets[true]
      visibility = sets.values.flat_map(&:values).map { |tag| [tag,tag.visible?] }
      visibility.each { |tag, _| tag.visible = true }
      checks << {name:'two_status_folders_same_five_tags',passed:sets.all? { |passed, tags| tags.values.all? { |tag| tag.folder.name == (passed ? 'Проходят' : 'Не проходят') && tag.folder.folder.name == 'Инсоляция' } && tags.values.uniq.length == 5 } && (sets[true].values & sets[false].values).empty?}
      anchor = (model.bounds.empty? ? ORIGIN : model.bounds.max).offset(Geom::Vector3d.new(100.m,100.m,100.m))
      results = Array.new(90) { {hit_dist:nil} }
      batch = CJ::RayTubesUp.build_batch(model,[{origin:anchor,results:results},{origin:anchor.offset(X_AXIS,1.m),results:[]}],mode: :summary)
      points = batch.entities.grep(Sketchup::Group)
      markers = points.each_with_index.map { |p, i| p.entities.grep(Sketchup::Group).find { |g| g.layer == sets[i == 0][:spheres] } }
      if CJ::ResultStyle.radius > 0
        checks << {name:'sphere_pass_fail_colors',passed:markers.map { |m| m.get_attribute('CJ_Insolation','passed') } == [true,false] && markers[0].entities.grep(Sketchup::ComponentInstance)[0].definition.entities.grep(Sketchup::Face)[0].material.color.green > 150}
        checks << {name:'sphere_radius_mm',passed:(markers[0].bounds.width.to_mm - CJ::ResultStyle.radius*2).abs < 0.1}
      else
        checks << {name:'zero_radius_disables_spheres',passed:markers.compact.empty?}
      end
      checks << {name:'labels_separate_status_tags',passed:points.each_with_index.all? { |p, i| p.entities.grep(Sketchup::Text).all? { |t| t.layer == sets[i == 0][:labels] } }}
      if markers.compact.length == 2
        marker_visible = lambda do |index|
          instance = markers[index].entities.grep(Sketchup::ComponentInstance).first
          face = instance.definition.entities.grep(Sketchup::Face).first
          model.drawing_element_visible?(Sketchup::InstancePath.new([batch,points[index],markers[index],instance,face]))
        end
        failed_folder = sets[false][:spheres].folder
        failed_folder.visible = false
        checks << {name:'failed_folder_hides_only_failed_results',passed:!marker_visible.call(1) && marker_visible.call(0)}
        failed_folder.visible = true
        sets[false][:spheres].visible = false
        checks << {name:'status_spheres_independent',passed:layers[:spheres].visible? && sets[false][:labels].visible? && !marker_visible.call(1)}
        sets[false][:spheres].visible = true
      end
      old_labels = CJ::ResultStyle.tags(model)[:labels]
      points.each { |p| p.entities.grep(Sketchup::Text).each { |t| t.layer = old_labels } }
      CJ::ResultStyle.organize_existing(model)
      checks << {name:'legacy_results_reassigned_without_recalculation',passed:points.each_with_index.all? { |p,i| p.entities.grep(Sketchup::Text).all? { |t| t.layer == sets[i == 0][:labels] } }}
      directed = 90.times.map { |i| {i:i, dir:Geom::Vector3d.new(Math.cos(i*0.01),Math.sin(i*0.01),0.2),hit_dist:nil} }
      [:lines, :surface].each do |mode|
        styled = CJ::RayTubesUp.build_batch(model,[{origin:anchor,results:directed},{origin:anchor.offset(X_AXIS,1.m),results:directed.first(2)}],mode:mode)
        correct = styled.entities.grep(Sketchup::Group).each_with_index.all? do |point,index|
          allowed = sets[index == 0].values
          point.entities.to_a.all? { |entity| allowed.include?(entity.layer) }
        end
        checks << {name:"#{mode}_uses_own_status_tags",passed:correct}
      end
      id = "style-check:#{SecureRandom.uuid}"
      old = CJ::RayTubesUp.build_batch(model,[{origin:anchor,results:results,source_id:id}],mode: :summary)
      CJ::SavedPoints.remove_results(model,[id])
      replacement = CJ::RayTubesUp.build_batch(model,[{origin:anchor,results:[],source_id:id}],mode: :summary)
      point = replacement.entities.grep(Sketchup::Group).first
      checks << {name:'recalculation_can_change_status_folder',passed:!old.valid? && point.get_attribute('CJ_Insolation','passed') == false && point.entities.all? { |entity| sets[false].values.include?(entity.layer) } && batch.valid?}
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
