# frozen_string_literal: true

require 'json'

module CJDevelopment
  ROOT = File.expand_path('..', __dir__) unless const_defined?(:ROOT, false)
  SOURCE = File.join(ROOT, 'src', 'cj.rb') unless const_defined?(:SOURCE, false)

  def self.reload
    # Compile before loading so a syntax error does not partially redefine the plugin.
    RubyVM::InstructionSequence.compile_file(SOURCE)
    RubyVM::InstructionSequence.compile_file(File.join(ROOT, 'src', 'window_placement.rb'))
    RubyVM::InstructionSequence.compile_file(File.join(ROOT, 'src', 'window_components.rb'))
    RubyVM::InstructionSequence.compile_file(File.join(ROOT, 'src', 'result_style.rb'))
    RubyVM::InstructionSequence.compile_file(File.join(ROOT, 'src', 'updates.rb'))
    %w[settings saved_points interface point_observers].each { |name| RubyVM::InstructionSequence.compile_file(File.join(ROOT, 'src', name + '.rb')) }
    previous_verbose = $VERBOSE
    begin
      $VERBOSE = nil # Existing constants are expected during development reloads.
      if defined?(CJ::RayTubesUp)
        plugin = CJ::RayTubesUp
        [:add_cone_group, :csv_report, :choose_csv_directory, :export_csv, :connect_bridge].each do |name|
          plugin.send(:remove_method, name) if plugin.instance_methods(false).include?(name)
        end
        [:DEFAULT_RADIUS_MM, :CIRCLE_SEGMENTS, :CONE_HALF_ANGLE_DEG].each do |name|
          plugin.send(:remove_const, name) if plugin.const_defined?(name, false)
        end
      end
      Kernel.load(SOURCE)
      CJ::WindowComponents.remove_old_markers(Sketchup.active_model) if defined?(CJ::WindowComponents)
      CJ::RayTubesUp.remove_instance_variable(:@ray_vectors) if CJ::RayTubesUp.instance_variable_defined?(:@ray_vectors)
    ensure
      $VERBOSE = previous_verbose
    end
    puts "[CJDevelopment] Loaded #{SOURCE}"
    true
  end

  def self.check
    checks = []
    Kernel.load(File.join(ROOT, 'dev', 'update_checks.rb'))
    checks.concat(CJUpdateChecks.run)
    if defined?(CJ::WindowPlacement)
      Kernel.load(File.join(__dir__, 'window_checks.rb'))
      checks.concat(CJWindowChecks.run)
    end
    vectors = CJ::RayTubesUp.ray_vectors
    checks << { name: 'vectors_present', passed: !vectors.empty?, count: vectors.length }
    checks << { name: 'normalized_vectors', passed: vectors.all? { |v| (v.length - 1.0).abs < 1e-9 } }

    cases = [
      [[], []],
      [[nil, nil, nil], [3]],
      [[10.0, 20.0], []],
      [[nil, nil, 10.0, nil, 20.0, nil, nil], [2, 1, 2]]
    ]
    cases.each_with_index do |(distances, expected), index|
      actual = CJ::RayTubesUp.clear_streaks(distances.map { |d| { hit_dist: d } })
      checks << { name: "clear_streaks_#{index}", passed: actual == expected, actual: actual, expected: expected }
    end

    model = Sketchup.active_model
    # API probe only: does not draw, change visibility, or save the user's model.
    probe = CJ::RayTubesUp.raycast_world(model, Geom::Point3d.new(0, 0, 1000.m), Geom::Vector3d.new(0, 0, 1))
    checks << { name: 'raytest_api', passed: probe.nil? || (probe[0].is_a?(Geom::Point3d) && probe[1] >= 0) }
    commands = CJ::Interface.commands
    checks << { name: 'insolation_icon_registered', passed: commands[:pick].small_icon && File.file?(commands[:pick].small_icon) }
    checks << { name: 'bridge_separate_from_plugin', passed: commands.values.none? { |c| c.menu_text.include?('Bridge') } }
    report = {
      checked_at: Time.now.iso8601,
      sketchup_version: Sketchup.version,
      ruby_version: RUBY_VERSION,
      source: SOURCE,
      scope: 'Load, example window placement with rotation, vectors, intervals and read-only raytest. No model geometry edits.',
      passed: checks.all? { |c| c[:passed] },
      checks: checks
    }
    path = File.join(ROOT, 'reports', 'session_check.json')
    File.write(path, JSON.pretty_generate(report), mode: 'w', encoding: 'UTF-8')
    puts "[CJDevelopment] #{report[:passed] ? 'PASS' : 'FAIL'}: #{checks.length} checks. Report: #{path}"
    report
  end
end

require 'time'
CJDevelopment.reload
CJDevelopment.check
