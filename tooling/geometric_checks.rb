# frozen_string_literal: true

module CJGeometryChecks
  def self.run
    model = Sketchup.active_model
    before = model.entities.length
    checks = []
    Kernel.load(File.join(CJBridge::ROOT, 'dev', 'result_style_checks.rb'))
    checks.concat(CJResultStyleChecks.run)
    if defined?(CJ::WindowComponents)
      Kernel.load(File.join(CJBridge::ROOT, 'dev', 'window_component_checks.rb'))
      checks.concat(CJWindowComponentChecks.run)
    end
    group = nil
    operation_started = false
    plugin = CJ::RayTubesUp
    original_vectors = plugin.ray_vectors
    timings = {}
    clock = lambda { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    begin
      model.start_operation('CJ temporary geometry checks', true)
      operation_started = true
      group = model.entities.add_group
      group.name = 'CJ_TEMPORARY_TEST_ONLY'
      # Put the fixture beyond existing model bounds so unrelated geometry cannot intercept +X rays.
      bounds = model.bounds
      anchor = Geom::Point3d.new(bounds.max.x + 1000.m, bounds.max.y + 1000.m, bounds.max.z + 1000.m)
      group.transform!(Geom::Transformation.translation(anchor))
      entities = group.entities
      entities.add_face([10.m, -2.m, -2.m], [10.m, 2.m, -2.m], [10.m, 2.m, 2.m], [10.m, -2.m, 2.m])
      direction = Geom::Vector3d.new(1, 0, 0)
      ray = [anchor, direction]
      wall_hit = model.raytest(ray, true)
      checks << { name: 'nested_wall_hit', passed: wall_hit && (anchor.distance(wall_hit[0]) - 10.m).abs < 0.1.mm }
      occluder = entities.add_group
      occluder.entities.add_face([5.m, -2.m, -2.m], [5.m, 2.m, -2.m], [5.m, 2.m, 2.m], [5.m, -2.m, 2.m])
      visible_hit = model.raytest(ray, true)
      checks << { name: 'visible_occluder_obstructs_ray', passed: visible_hit && visible_hit[1].include?(occluder) }
      occluder.hidden = true
      hidden_hit = model.raytest(ray, true)
      checks << { name: 'hidden_occluder_excluded_with_true', passed: hidden_hit && (anchor.distance(hidden_hit[0]) - 10.m).abs < 0.1.mm }
      included_hit = model.raytest(ray, false)
      checks << { name: 'hidden_occluder_included_with_false', passed: included_hit && included_hit[1].include?(occluder) }
      occluder.hidden = false
      occluder.set_attribute('CJ_Insolation', 'result', true)
      plugin.instance_variable_set(:@ray_vectors, [direction])
      points = [anchor, anchor.offset(Geom::Vector3d.new(0, 1, 0), 1.m)]
      signature = lambda { |values| values.map { |entry| entry[:results].map { |r| r[:hit_dist] && r[:hit_dist].round(6) } } }
      singles = points.map { |point| plugin.calculate_points(model, [point]).first }
      batch_results = plugin.calculate_points(model, points)
      checks << { name: 'single_equals_batch', passed: signature.call(singles) == signature.call(batch_results) }
      checks << { name: 'obstacle_behind_result_found', passed: batch_results.all? { |r| (r[:results][0][:hit_dist] - 10.m).abs < 0.1.mm } }
      checks << { name: 'previous_result_visibility_restored', passed: !occluder.hidden? }
      begin
        plugin.without_results(model) { raise 'TEST_RESTORE' }
      rescue RuntimeError => error
        raise unless error.message == 'TEST_RESTORE'
      end
      checks << { name: 'visibility_restored_after_exception', passed: !occluder.hidden? }
      batch = plugin.build_batch(model, batch_results)
      checks << { name: 'one_group_per_point', passed: batch.entities.grep(Sketchup::Group).length == 2 }
      checks << { name: 'world_coordinates_preserved', passed: model.entities.include?(batch) && batch.entities.grep(Sketchup::Group).map { |g| g.get_attribute('CJ_Insolation', 'origin') } == points.map(&:to_a) }
      repeated = plugin.calculate_points(model, points)
      checks << { name: 'repeat_ignores_drawn_batch', passed: signature.call(repeated) == signature.call(batch_results) }
      occluder.delete_attribute('CJ_Insolation', 'result')
      occluder.name = 'Insolation_20261014_010000'
      occluder.layer = plugin.ensure_tag(model, plugin::DEFAULT_TAG_NAME)
      legacy = plugin.calculate_points(model, points)
      checks << { name: 'legacy_results_ignored', passed: signature.call(legacy) == signature.call(batch_results) }
      occluder.name = 'Architecture'
      ordinary = plugin.calculate_points(model, [anchor])
      checks << { name: 'ordinary_geometry_on_rays_tag_not_ignored', passed: ordinary[0][:results][0][:hit_dist] < 10.m }
      occluder.hidden = true
      plugin.instance_variable_set(:@ray_vectors, original_vectors)
      started = clock.call
      full_results = plugin.calculate_points(model, points)
      timings[:calculate_two_points_ms] = ((clock.call - started) * 1000).round(2)
      started = clock.call
      full_batch = plugin.build_batch(model, full_results)
      timings[:default_lines_two_points_ms] = ((clock.call - started) * 1000).round(2)
      checks << { name: 'full_510_vector_batch_built', passed: full_results.all? { |entry| entry[:results].length == 510 } && full_batch.entities.grep(Sketchup::Group).length == 2 }
      checks << { name: 'full_vector_repeat_stable', passed: signature.call(plugin.calculate_points(model, points)) == signature.call(full_results) }
      [:lines, :summary].each do |mode|
        started = clock.call
        fast_batch = plugin.build_batch(model, full_results, mode: mode)
        timings["#{mode}_two_points_ms"] = ((clock.call - started) * 1000).round(2)
        point_groups = fast_batch.entities.grep(Sketchup::Group)
        checks << { name: "#{mode}_only_result_markers_no_cones", passed: point_groups.length == 2 && point_groups.all? { |g| g.entities.grep(Sketchup::Group).all? { |m| !m.get_attribute('CJ_Insolation', 'passed').nil? } && g.entities.grep(Sketchup::Face).empty? } }
        checks << { name: "#{mode}_preserves_results", passed: point_groups.map { |g| g.get_attribute('CJ_Insolation', 'clear_count') } == full_results.map { |entry| plugin.clear_streaks(entry[:results]).sum } }
        checks << { name: "#{mode}_does_not_obstruct_repeat", passed: signature.call(plugin.calculate_points(model, points)) == signature.call(full_results) }
      end
      started = clock.call
      surface_batch = plugin.build_batch(model, full_results, mode: :surface)
      timings[:surface_two_points_ms] = ((clock.call - started) * 1000).round(2)
      checks << { name: 'surface_faces_built', passed: surface_batch.entities.grep(Sketchup::Group).all? { |g| g.entities.grep(Sketchup::Face).length >= 509 } }
      checks << { name: 'surface_does_not_obstruct_repeat', passed: signature.call(plugin.calculate_points(model, points)) == signature.call(full_results) }
      mixed_results = [
        { i: 0, dir: Geom::Vector3d.new(1, 0, 0), hit_dist: 10.m },
        { i: 1, dir: Geom::Vector3d.new(1, 1, 0).normalize, hit_dist: nil },
        { i: 2, dir: Geom::Vector3d.new(0, 1, 0), hit_dist: 10.m }
      ]
      mixed = [{ origin: anchor, results: mixed_results }]
      colored_lines = plugin.build_batch(model, mixed, mode: :lines).entities.grep(Sketchup::Group).first.entities.grep(Sketchup::Edge)
      colors = colored_lines.map { |edge| edge.material.color.to_a.first(3) }
      checks << { name: 'line_materials_red_green', passed: colors.count([255, 0, 0]) == 2 && colors.count([0, 200, 0]) == 1 }
      mixed_surface_entities = plugin.build_batch(model, mixed, mode: :surface).entities.grep(Sketchup::Group).first.entities
      mixed_surface = mixed_surface_entities.grep(Sketchup::Face)
      checks << { name: 'surface_transition_red_green', passed: mixed_surface.length == 4 && mixed_surface.count { |f| f.material.color.to_a.first(3) == [255, 0, 0] } == 2 && mixed_surface.all? { |f| f.back_material.color == f.material.color } }
      markers = mixed_surface_entities.grep(Sketchup::Group).select { |g| !g.get_attribute('CJ_Insolation', 'ray').nil? }
      checks << { name: 'outer_markers_unambiguous', passed: markers.length == 6 && markers.map { |m| [m.get_attribute('CJ_Insolation', 'ray'), m.get_attribute('CJ_Insolation', 'blocked')] } == [[0, true], [0, true], [1, false], [1, false], [2, true], [2, true]] && markers.all? { |m| m.entities.grep(Sketchup::Text).length == 1 } }
      annotation_results = ([nil] * 60 + [10.m] * 20 + [nil] * 40).each_with_index.map { |distance, i| { i: i, dir: direction, hit_dist: distance } }
      numbered = plugin.surface_annotations(annotation_results)
      checks << { name: 'independent_cumulative_minute_numbers', passed: numbered.map { |m| [m[:blocked], m[:minute]] } == [[false, 1], [false, 60], [true, 1], [true, 20], [false, 61], [false, 100]] }
      [[[], false], [[89], false], [[90], true], [[60, 59], false], [[60, 60], true], [[59, 59, 2], false], [[60, 30, 30], true], [[90, 30], true]].each_with_index do |(lengths, expected), index|
        distances = []
        lengths.each { |length| distances << 1.m unless distances.empty?; distances.concat([nil] * length) }
        assessment = plugin.assess_insolation(distances.map { |distance| { hit_dist: distance } })
        checks << { name: "insolation_threshold_#{index}", passed: assessment[:passed] == expected }
      end
      single_long = plugin.assess_insolation(Array.new(120) { { hit_dist: nil } })
      checks << { name: 'single_interval_is_continuous_not_intermittent', passed: single_long[:continuous] && !single_long[:intermittent] }
      point_groups = surface_batch.entities.grep(Sketchup::Group)
      checks << { name: 'surface_opacity_50_percent', passed: point_groups.all? { |g| g.entities.grep(Sketchup::Face).all? { |f| (f.material.alpha - 0.5).abs < 0.01 && (f.back_material.alpha - 0.5).abs < 0.01 } } }
      numbers = point_groups.map { |g| g.get_attribute('CJ_Insolation', 'point_number') }
      checks << { name: 'persistent_number_labels', passed: numbers.uniq.length == 2 && point_groups.all? { |g| g.entities.grep(Sketchup::Text).any? { |t| t.text.start_with?("Точка #{g.get_attribute('CJ_Insolation', 'point_number')}\n") } } }
      root_loader = File.join(CJBridge::ROOT, 'src', 'cj_insolation.rb')
      RubyVM::InstructionSequence.compile_file(root_loader)
      checks << { name: 'extension_loader_compiles', passed: true }
    ensure
      plugin.instance_variable_set(:@ray_vectors, original_vectors)
      model.abort_operation if operation_started
    end
    checks << { name: 'temporary_geometry_rolled_back', passed: !group.valid? && model.entities.length == before }
    report = { passed: checks.all? { |check| check[:passed] }, checks: checks, timings: timings, scope: 'Two points, 510 vectors each, temporary small fixture; timings are not a forecast for large building models. Mouse interaction not verified.', checked_at: Time.now.utc.iso8601 }
    CJBridge.write_json(File.join(CJBridge::ROOT, 'reports', 'geometry_check.json'), report)
    report
  end
end
