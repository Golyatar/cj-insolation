# frozen_string_literal: true
module CJWindowComponentChecks
  def self.run
    model=Sketchup.active_model;before=model.entities.length;checks=[]
    model.start_operation('CJ: temporary component checks',true)
    begin
      d=CJ::WindowComponents.definition(model)
      checks << {name:'window_component_has_invisible_point',passed:d.get_attribute('CJ_Window','point_mm').length==3 && d.entities.grep(Sketchup::ConstructionPoint).empty?}
      checks << {name:'window_component_gluing_enabled',passed:d.behavior.is2d? && d.behavior.cuts_opening?}
      group=model.entities.add_group
      anchor=Geom::Point3d.new(model.bounds.max.x+100.m,model.bounds.max.y+100.m,model.bounds.max.z+100.m)
      group.transform!(Geom::Transformation.translation(anchor))
      orientation=Geom::Transformation.axes(ORIGIN,X_AXIS,Z_AXIS,Geom::Vector3d.new(0,-1,0))
      first=group.entities.add_instance(d,orientation)
      nested=group.entities.add_group
      nested.transform!(Geom::Transformation.translation([5.m,0,0])*Geom::Transformation.rotation(ORIGIN,Z_AXIS,37.degrees))
      second=nested.entities.add_instance(d,orientation)
      raw=Geom::Point3d.new(d.get_attribute('CJ_Window','point_mm').map(&:mm))
      entries=CJ::WindowComponents.collect(model)[:windows].select { |w| w[:path_ids].include?(group.persistent_id) }
      expected=[raw.transform(group.transformation*first.transformation),raw.transform(group.transformation*nested.transformation*second.transformation)]
      checks << {name:'window_component_nested_copies_found',passed:entries.length==2 && expected.all? { |p| entries.any? { |e| p.distance(e[:origin]).to_f<0.01.mm.to_f } },actual:entries.map { |e| e[:origin].to_a.map(&:to_mm) },expected:expected.map { |p| p.to_a.map(&:to_mm) }}
      second.hidden=true
      checks << {name:'hidden_window_component_skipped',passed:CJ::WindowComponents.collect(model)[:windows].count { |w| w[:path_ids].include?(group.persistent_id) }==1}
      second.hidden=false
      tilted=group.entities.add_instance(d,Geom::Transformation.translation([10.m,0,0]))
      checks << {name:'tilted_window_component_rejected',passed:CJ::WindowComponents.collect(model)[:skipped].any? { |path| path.include?(tilted.persistent_id) }}
      # Native glued opening must be respected by the actual insolation ray query.
      face=group.entities.add_face([-1.m,0,-1.m],[3.m,0,-1.m],[3.m,0,3.m],[-1.m,0,3.m])
      first.glued_to=face
      ray=CJ::RayTubesUp.raycast_world(model,expected.first,Geom::Vector3d.new(0,-1,0))
      checks << {name:'glued_window_opening_passes_ray',passed:ray.nil?}
    ensure
      model.abort_operation
    end
    checks << {name:'window_component_fixture_rolled_back',passed:model.entities.length==before && !group.valid?}
    checks
  end
end
