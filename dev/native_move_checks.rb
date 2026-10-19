# frozen_string_literal: true
require 'json'

# Uses native model transactions, selection and the built-in Move tool.
# Positions are scripted; physical mouse interaction is a separate manual check.
module CJNativeMoveChecks
  extend self

  def results
    CJ::RayTubesUp.result_groups(@model).flat_map { |b| b.entities.grep(Sketchup::Group) }
  end

  def check(name, value)
    @checks << { name: name, passed: !!value }
  end

  def later(&block)
    UI.start_timer(0.5, false) do
      begin
        block.call
      rescue StandardError => error
        complete(error)
      end
    end
  end

  def run
    raise 'Already running' if @running
    @model = Sketchup.active_model
    raise 'Use an empty test model' unless @model.entities.length.zero?
    @running = true
    @checks = []
    @raw = Sketchup.read_default(CJ::Settings::KEY, 'values', '{}')
    @radius = CJ::ResultStyle.radius
    CJ::Settings.save(CJ::Settings.values.merge('mode' => 'summary', 'live' => true))
    CJ::PointObservers.paused do
      @model.start_operation('CJ native Move fixture', true)
      @points = [0, 2, 4].map { |x| CJ::SavedPoints.add(@model, Geom::Point3d.new(x.m, 0, 2.m)) }
      @originals = @points.map { |p| CJ::SavedPoints.origin(p) }
      @ids = @points.map { |p| CJ::SavedPoints.source_id(p) }
      calculations = CJ::RayTubesUp.calculate_points(@model, @originals)
      calculations.each_with_index { |c, i| c[:source_id] = @ids[i] }
      CJ::RayTubesUp.build_batch(@model, calculations, mode: :summary)
      @model.commit_operation
    end
    CJ::SavedPoints.select_points
    check('select_all_native_groups', @model.selection.to_a.sort_by(&:persistent_id) == @points.sort_by(&:persistent_id))
    @model.selection.clear
    @model.selection.add(@points.first(2))
    Sketchup.send_action('selectMoveTool:')
    later do
      check('built_in_move_tool_active', @model.tools.active_tool_name == 'MoveTool')
      @untouched_result = results.find { |g| g.get_attribute('CJ_Insolation', 'source_id') == @ids[2] }.persistent_id
      @model.start_operation('Move', true)
      @model.entities.transform_entities(Geom::Transformation.translation([0, 3.m, 0]), @model.selection.to_a)
      @model.commit_operation
      later { moved }
    end
    :scheduled
  rescue StandardError => error
    complete(error)
  end

  def matching_results?
    @points.all? do |point|
      group = results.find { |g| g.get_attribute('CJ_Insolation', 'source_id') == CJ::SavedPoints.source_id(point) }
      group && Geom::Point3d.new(group.get_attribute('CJ_Insolation', 'origin')).distance(CJ::SavedPoints.origin(point)).to_f < 1e-7
    end
  end

  def moved
    check('two_selected_points_moved', @points.first(2).each_with_index.all? { |p, i| CJ::SavedPoints.origin(p).distance(@originals[i].offset(Y_AXIS, 3.m)).to_f < 1e-7 })
    check('only_three_results_no_duplicates', results.length == 3)
    check('moved_results_match_new_origins', matching_results?)
    check('unselected_result_untouched', results.any? { |g| g.persistent_id == @untouched_result })
    check('native_selection_preserved', @model.selection.to_a.sort_by(&:persistent_id) == @points.first(2).sort_by(&:persistent_id))
    @model.start_operation('CJ raycast probe', true)
    begin
      calc = CJ::RayTubesUp.calculate_points(@model, @points.map { |p| CJ::SavedPoints.origin(p) })
      check('point_markers_do_not_shadow_rays', calc.all? { |c| c[:results].all? { |r| r[:hit_dist].nil? } })
    ensure
      @model.abort_operation
    end
    Sketchup.undo
    later do
      check('one_undo_restores_both_points', @points.each_with_index.all? { |p, i| CJ::SavedPoints.origin(p).distance(@originals[i]).to_f < 1e-7 })
      check('one_undo_restores_results', matching_results?)
      Sketchup.redo
      later { redone }
    end
  end

  def redone
    check('redo_restores_move_and_results', matching_results? && CJ::SavedPoints.origin(@points[0]).distance(@originals[0].offset(Y_AXIS, 3.m)).to_f < 1e-7)
    before = @points.map { |p| CJ::SavedPoints.origin(p) }
    @model.start_operation('Move cancelled', true)
    @model.entities.transform_entities(Geom::Transformation.translation([10.m, 0, 0]), @points.first(2))
    @model.abort_operation
    later do
      check('cancelled_move_keeps_positions', @points.each_with_index.all? { |p, i| CJ::SavedPoints.origin(p).distance(before[i]).to_f < 1e-7 })
      check('cancelled_move_keeps_results', matching_results?)
      CJ::Settings.save(CJ::Settings.values.merge('live' => false))
      @model.start_operation('Move manual mode', true)
      @model.entities.transform_entities(Geom::Transformation.translation([0, 1.m, 0]), [@points[2]])
      @model.commit_operation
      later do
        check('manual_mode_waits_for_button', !matching_results?)
        CJ::SavedPoints.calculate([@points[2]])
        later do
          if CJ::SavedPoints.busy?
            later { finish_manual }
          else
            finish_manual
          end
        end
      end
    end
  end

  def finish_manual
    check('manual_recalculation_works', matching_results? && results.length == 3)
    complete
  end

  def complete(error = nil)
    return unless @running
    @model.select_tool(nil)
    CJ::PointObservers.paused do
      @model.start_operation('CJ native Move fixture cleanup', true)
      @model.entities.clear!
      @model.commit_operation
      CJ::PointObservers.watch(@model).reset
    end
    Sketchup.write_default(CJ::Settings::KEY, 'values', @raw)
    Sketchup.write_default('CJ_ResultStyle', 'radius_mm', @radius)
    @running = false
    check('native_fixture_removed', @model.entities.length.zero?)
    report = { passed: error.nil? && @checks.all? { |c| c[:passed] }, checks: @checks,
               error: error&.message, trace: error&.backtrace&.first(5),
               scope: 'Native selection, built-in Move activation, scripted multi-entity native transforms, actual observers, timers and Undo/Redo.' }
    File.write(File.expand_path('../reports/native_move_check.json', __dir__), JSON.pretty_generate(report))
    report
  end
end
