# frozen_string_literal: true

# Load in SketchUp Ruby Console after CJ, then:
# CJPerformanceChecks.run(points: [Geom::Point3d.new(0, 0, 1000.mm)])
# Supply representative points in a test model. Coordinates use SketchUp units.
require 'json'
require 'fileutils'

module CJPerformanceChecks
  extend self

  def clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def run(points:, samples: 20, budget_seconds: 10.0)
    raise 'A benchmark is already running' if @running
    raise ArgumentError, 'Supply points and at least two samples' if points.empty? || samples < 2
    raise ArgumentError, 'Invalid time budget' unless budget_seconds.finite? && budget_seconds > 0
    model = Sketchup.active_model
    raise 'Wait for the CJ calculation to finish' if CJ::RayTubesUp.instance_variable_get(:@active_calculation)
    origins = points.map(&:clone)
    vectors = CJ::RayTubesUp.ray_vectors
    raise 'No ray vectors loaded' if vectors.empty?
    started = clock
    timings = []
    @running = true
    tick = lambda do
      begin
        raise 'Active model changed; benchmark cancelled' unless Sketchup.active_model.equal?(model)
        raise 'CJ calculation started; benchmark cancelled' if CJ::RayTubesUp.instance_variable_get(:@active_calculation)
        # Different origins avoid timing an identical repeated query only.
        origin = origins[timings.length % origins.length].offset(X_AXIS, (timings.length % 10).mm)
        elapsed = nil
        CJ::RayTubesUp.without_results(model) do
          before = clock
          vectors.each { |direction| CJ::RayTubesUp.raycast_world(model, origin, direction) }
          elapsed = (clock - before) * 1000.0
        end
        timings << elapsed
        if timings.length >= samples || clock - started >= budget_seconds
          sorted = timings.sort
          report = {
            scope: 'Full raycast per moving point only; excludes drawing, geometry edits and mouse latency',
            sketchup: Sketchup.version, model: model.title,
            rays_per_point: vectors.length, samples: timings.length,
            requested_samples: samples, budget_reached: timings.length < samples,
            median_ms: sorted[sorted.length / 2],
            p95_ms: sorted[[(sorted.length * 0.95).ceil - 1, 0].max],
            max_ms: sorted.last, samples_ms: timings
          }
          directory = File.expand_path('../reports', __dir__)
          FileUtils.mkdir_p(directory)
          File.write(File.join(directory, 'performance_check.json'), JSON.pretty_generate(report))
          puts "[CJ performance] #{JSON.generate(report)}"
          @running = false
        else
          UI.start_timer(0.02, false, &tick)
        end
      rescue StandardError => error
        @running = false
        warn "[CJ performance] #{error.class}: #{error.message}"
      end
    end
    UI.start_timer(0.02, false, &tick)
    :scheduled
  end
end
