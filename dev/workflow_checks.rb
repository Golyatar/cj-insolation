# frozen_string_literal: true
require 'json'

module CJWorkflowChecks
  extend self

  def result_points(model)
    CJ::RayTubesUp.result_groups(model).flat_map { |g| g.entities.grep(Sketchup::Group) }
  end

  def run
    model = Sketchup.active_model
    before = model.entities.length
    checks = []
    settings = CJ::Settings.values
    # Validation must reject combinations that would create an invalid window.
    invalid = settings.merge('window' => [1300, 1400, 300, 150, 70, 800])
    rejected = false
    begin
      CJ::Settings.validate(invalid)
    rescue StandardError
      rejected = true
    end
    checks << { name: 'invalid_window_rejected', passed: rejected }
    checks << { name: 'all_settings_available', passed: settings.keys.sort == %w[live mode radius window] }
    original = Sketchup.read_default(CJ::Settings::KEY, 'values', '{}')
    radius = CJ::ResultStyle.radius
    begin
      changed = settings.merge('mode' => 'surface', 'live' => false, 'window' => [1500, 1600, 300, 150, 70, 60])
      CJ::Settings.save(changed)
      checks << { name: 'settings_persistence_roundtrip', passed: CJ::Settings.values == changed }
    ensure
      Sketchup.write_default(CJ::Settings::KEY, 'values', original)
      Sketchup.write_default('CJ_ResultStyle', 'radius_mm', radius)
    end
    model.start_operation('CJ workflow temporary fixture', true)
    begin
      a = CJ::SavedPoints.add(model, Geom::Point3d.new(0, 0, 2.m))
      b = CJ::SavedPoints.add(model, Geom::Point3d.new(2.m, 0, 2.m))
      checks << { name: 'points_are_independent_saved_entities', passed: CJ::SavedPoints.all(model).include?(a) && a.get_attribute(CJ::SavedPoints::DICT, 'id').is_a?(String) }
      copy = a.copy
      checks << { name: 'native_copy_has_distinct_result_identity', passed: CJ::SavedPoints.source_id(copy) != CJ::SavedPoints.source_id(a) }
      copy.erase!
      ids = [a, b].map { |g| CJ::SavedPoints.source_id(g) }
      calculations = CJ::RayTubesUp.calculate_points(model, [a, b].map { |g| CJ::SavedPoints.origin(g) })
      calculations.each_with_index { |c, i| c[:source_id] = ids[i] }
      CJ::RayTubesUp.build_batch(model, calculations, mode: :summary)
      CJ::SavedPoints.remove_results(model, [ids[0]])
      checks << { name: 'replacement_keeps_other_point_result', passed: result_points(model).map { |g| g.get_attribute('CJ_Insolation', 'source_id') } == [ids[1]] }
      CJ::RayTubesUp.build_batch(model, [calculations[0]], mode: :lines)
      CJ::SavedPoints.remove_results(model, [ids[0]])
      CJ::RayTubesUp.build_batch(model, [calculations[0]], mode: :surface)
      checks << { name: 'repeated_calculation_has_no_duplicates', passed: result_points(model).map { |g| g.get_attribute('CJ_Insolation', 'source_id') }.sort == ids.sort }
      checks << { name: 'no_visible_point_numbers', passed: result_points(model).all? { |g| g.entities.grep(Sketchup::Text).none? { |t| t.text.start_with?('Точка ') } } }
      CJ::SavedPoints.remove_results(model, ids)
      checks << { name: 'points_survive_result_removal', passed: a.valid? && b.valid? && CJ::RayTubesUp.result_groups(model).empty? }
      a.transformation = Geom::Transformation.translation([3.m, 4.m, 5.m])
      checks << { name: 'native_move_updates_calculation_origin', passed: CJ::SavedPoints.origin(a).distance(Geom::Point3d.new(3.m, 4.m, 5.m)).to_f < 0.01.mm.to_f }
    ensure
      model.abort_operation
    end
    checks << { name: 'workflow_fixture_rolled_back', passed: model.entities.length == before }
    report = { passed: checks.all? { |c| c[:passed] }, checks: checks }
    File.write(File.expand_path('../reports/workflow_check.json', __dir__), JSON.pretty_generate(report))
    report
  end
end
