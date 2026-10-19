# frozen_string_literal: true
require 'tmpdir'
require 'json'

module CJExportChunkChecks
  extend self
  View = Struct.new(:entities, :definitions, :layers, :rendering_options) unless const_defined?(:View, false)

  def run
    model = Sketchup.active_model
    raise 'Calculation in progress' if CJ::RayTubesUp.instance_variable_get(:@active_calculation)
    raise 'Exit group editing' if model.active_path
    before = model.entities.length
    directory = Dir.mktmpdir('cj-chunk-check-')
    checks = []
    model.start_operation('CJ temporary chunk export test', true)
    begin
      fixture = model.entities.add_group
      block = fixture.entities.add_group
      face = block.entities.add_face([0, 0, 0], [1.m, 0, 0], [1.m, 1.m, 0], [0, 1.m, 0])
      face.pushpull(2.m)
      30.times { |i| fixture.entities.add_instance(block.definition, Geom::Transformation.translation([i*3.m, 0, 0])) }
      view = View.new(fixture.entities, model.definitions.select(&:image?), model.layers, {'DisplaySectionCuts'=>false})
      points = [Geom::Point3d.new(0, 0, 4.m)]
      directions = [Z_AXIS]
      sync = File.join(directory, 'sync.bin')
      chunked = File.join(directory, 'chunked.bin')
      expected = CJ::NativeEngine.write_input(sync, view, points, directions)
      state = {}
      ticks = 0
      fiber = Fiber.new { CJ::NativeEngine.write_input(chunked, view, points, directions, state: state) { Fiber.yield } }
      while fiber.alive?
        fiber.resume
        ticks += 1
      end
      checks << {name: 'chunk_boundaries_preserve_protocol_bytes', passed: File.binread(sync) == File.binread(chunked) && expected > 300 && ticks > 30, resumes: ticks}
      checks << {name: 'completed_export_closes_file', passed: state[:file].closed?}
      state = {directory: Dir.mktmpdir('cj-chunk-cancel-')}
      path = File.join(state[:directory], 'input.bin')
      state[:fiber] = Fiber.new { CJ::NativeEngine.write_input(path, view, points, directions, state: state) { Fiber.yield } }
      state[:fiber].resume while state[:fiber].alive? && !state[:file]
      handle = state[:file]
      cancelled_directory = state[:directory]
      CJ::NativeEngine.cleanup({native: state})
      checks << {name: 'abandoned_export_closes_handle_and_removes_directory', passed: handle.closed? && !File.exist?(cancelled_directory)}
    ensure
      model.abort_operation
      FileUtils.remove_entry(directory)
    end
    checks << {name: 'user_geometry_preserved', passed: model.entities.length == before}
    report = {passed: checks.all? { |c| c[:passed] }, checks: checks}
    File.write(File.expand_path('../reports/export_chunk_check.json', __dir__), JSON.pretty_generate(report))
    report
  end
end
