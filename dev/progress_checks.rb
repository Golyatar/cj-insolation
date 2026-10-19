# frozen_string_literal: true
require 'json'
require 'tmpdir'

# Run in a model without an active CJ job. Cancels a temporary job via the
# rendered HTML button; existing points/results/selection are preserved.
module CJProgressChecks
  extend self

  def run
    model = Sketchup.active_model
    raise 'Calculation in progress' if CJ::RayTubesUp.instance_variable_get(:@active_calculation)
    raise 'Exit group editing' if model.active_path
    raise 'Select C++ to test cooperative export' unless CJ::Settings.values['engine'] == 'cpp'
    raise 'Stable worker changed' unless CJ::NativeEngine.approved?
    UI.stop_timer(@timer) if @timer
    @cancel_sent = @worker_started = @directory = nil
    @before = {entities: model.entities.length, selection: model.selection.to_a,
               modified: model.modified?, hidden: CJ::RayTubesUp.raycast_exclusions(model).to_h { |g| [g, g.hidden?] }}
    @checks = []
    @started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @job = CJ::RayTubesUp.run_from_points([Geom::Point3d.new(0, 0, 1.m)], mode: :summary)
    @checks << {name: 'waits_for_rendered_dialog_before_export', passed: @job[:phase] == :waiting_ui && !@job[:native] && !@job[:operation_started]}
    @ticks = 0
    @render_info = nil
    @job[:dialog].add_action_callback('progress_probe') do |_context, info|
      @render_info = info
    end
    @timer = UI.start_timer(0.02, true) { poll }
    :scheduled
  end

  def poll
    @ticks += 1
    active = CJ::RayTubesUp.instance_variable_get(:@active_calculation)
    unless active.equal?(@job)
      UI.stop_timer(@timer)
      model = Sketchup.active_model
      @checks << {name: 'real_dialog_rendered', passed: @render_info && @render_info['title'] == 'Подготовка модели'}
      @checks << {name: 'dialog_has_no_vertical_scroll', passed: @render_info && @render_info['scrollHeight'] <= @render_info['height']}
      @checks << {name: 'cancel_button_fully_visible', passed: @render_info && @render_info['buttonBottom'] <= @render_info['height']}
      @checks << {name: 'export_bar_has_real_fraction', passed: @render_info && @render_info['fraction'].to_f > 0 && @render_info['fraction'].to_f < 100 && !@render_info['busy']}
      @checks << {name: 'other_ui_timers_run_during_export', passed: @ticks >= 3, ticks: @ticks}
      @checks << {name: 'cancelled_before_worker_launch', passed: @cancel_sent && !@worker_started && !@job[:native]}
      @checks << {name: 'partial_export_removed', passed: @directory && !File.exist?(@directory)}
      @checks << {name: 'user_model_preserved', passed: model.entities.length == @before[:entities] && model.selection.to_a == @before[:selection] && model.modified? == @before[:modified] && @before[:hidden].all? { |g, hidden| g.valid? && g.hidden? == hidden }}
      @report = {passed: @checks.all? { |c| c[:passed] }, checks: @checks,
                 ready_and_cancel_ms: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started) * 1000,
                 render_info: @render_info}
      File.write(File.expand_path('../reports/progress_check.json', __dir__), JSON.pretty_generate(@report))
      return
    end
    native = @job[:native]
    @directory ||= native && native[:directory]
    @worker_started ||= native && native[:pid]
    if native && native[:total_triangles].to_i > 0 && native[:triangles].to_i >= [4096, native[:total_triangles] / 50].max && !@cancel_sent
      @cancel_sent = true
      @job[:dialog].execute_script("sketchup.progress_probe({title:document.getElementById('label').textContent,scrollHeight:document.documentElement.scrollHeight,height:window.innerHeight,buttonBottom:document.getElementById('cancel').getBoundingClientRect().bottom,fraction:document.getElementById('bar').getAttribute('aria-valuenow'),busy:document.getElementById('bar').classList.contains('busy')});document.getElementById('cancel').click()")
    end
    if Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started > 30 && !@cancel_sent
      @cancel_sent = true
      CJ::RayTubesUp.finish_calculation(@job, cancelled: true)
    end
  rescue StandardError => error
    UI.stop_timer(@timer)
    CJ::RayTubesUp.finish_calculation(@job, cancelled: true) if @job
    File.write(File.expand_path('../reports/progress_check.json', __dir__), JSON.pretty_generate({passed: false, error: error.message, backtrace: error.backtrace.first(6)}))
  end

  def run_complete
    model = Sketchup.active_model
    raise 'Calculation in progress' if CJ::RayTubesUp.instance_variable_get(:@active_calculation)
    raise 'Exit group editing' if model.active_path
    raise 'Select C++' unless CJ::Settings.values['engine'] == 'cpp'
    points = CJ::SavedPoints.visible(model).last(3).map { |g| CJ::SavedPoints.origin(g) }
    raise 'Place three saved points first' unless points.length == 3
    @full_before = {entities: model.entities.length, modified: model.modified?, selection: model.selection.to_a,
                    hidden: CJ::RayTubesUp.raycast_exclusions(model).to_h { |g| [g, g.hidden?] }}
    @reference = CJ::RayTubesUp.calculate_points(model, points).flat_map { |c| c[:results].map { |r| r[:hit_dist]&.to_f || -1.0 } }
    @full_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @full_job = CJ::RayTubesUp.run_from_points(points, mode: :summary)
    @full_ticks = 0
    @full_phases = []
    @full_timer = UI.start_timer(0.01, true) { poll_complete }
    :scheduled
  end

  def poll_complete
    @full_ticks += 1
    phase = @full_job[:phase]
    @full_phases << phase unless @full_phases.last == phase
    if phase == :drawing
      UI.stop_timer(@full_timer)
      actual = @full_job[:calculations].flat_map { |c| c[:results].map { |r| r[:hit_dist] || -1.0 } }
      differences = @reference.zip(actual)
      mismatch_count = differences.count { |a, b| !b || (a < 0) != (b < 0) }
      max_error = differences.select { |a, b| b && a >= 0 && b >= 0 }.map { |a, b| (a - b).abs.to_mm }.max || 0
      metrics = CJ::NativeEngine.last_metrics
      CJ::RayTubesUp.finish_calculation(@full_job, cancelled: true)
      model = Sketchup.active_model
      preserved = model.entities.length == @full_before[:entities] && model.modified? == @full_before[:modified] && model.selection.to_a == @full_before[:selection] && @full_before[:hidden].all? { |g, h| g.valid? && g.hidden? == h }
      report = {passed: mismatch_count.zero? && max_error < 0.01 && preserved && @full_phases.include?(:exporting) && @full_phases.include?(:cpp),
                points: 3, rays: actual.length, sun_shadow_mismatches: mismatch_count, max_distance_error_mm: max_error,
                phases: @full_phases, ui_timer_ticks: @full_ticks, metrics: metrics, model_preserved: preserved,
                scope: 'Full export and saved worker on real points; final drawing deliberately cancelled to preserve existing results'}
      File.write(File.expand_path('../reports/progress_full_check.json', __dir__), JSON.pretty_generate(report))
    elsif !CJ::RayTubesUp.instance_variable_get(:@active_calculation).equal?(@full_job) || Process.clock_gettime(Process::CLOCK_MONOTONIC) - @full_started > 90
      raise 'Full progress check ended early or exceeded 90 seconds'
    end
  rescue StandardError => error
    UI.stop_timer(@full_timer)
    CJ::RayTubesUp.finish_calculation(@full_job, cancelled: true)
    File.write(File.expand_path('../reports/progress_full_check.json', __dir__), JSON.pretty_generate({passed: false, error: error.message, phases: @full_phases}))
  end
end
