# frozen_string_literal: true
require 'tmpdir'
require 'fileutils'

module CJ
  module NativeEngine
    extend self
    class Unsupported < StandardError; end
    attr_reader :last_metrics

    def executable
      packaged = File.join(__dir__, 'bin', 'cj_engine.exe')
      File.file?(packaged) ? packaged : File.expand_path('../native/build/cj_engine.exe', __dir__)
    end

    def write_input(path, model, points, vectors)
      triangles = 0
      excluded = RayTubesUp.raycast_exclusions(model)
      File.open(path, 'wb') do |file|
        file.write('CJIN0001' + [0, points.length, vectors.length].pack('L<3'))
        visit = lambda do |entities, transform, ancestry|
          raise Unsupported, 'активное сечение' if entities.grep(Sketchup::SectionPlane).any?(&:active?)
          entities.each do |entity|
            next unless entity.is_a?(Sketchup::Drawingelement)
            next if excluded.include?(entity) || entity.get_attribute('CJ_Insolation', 'result', false)
            next if entity.hidden? || !entity.layer.visible?
            path_entities = ancestry + [entity]
            instance = entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
            # Before SU 2026 visibility queries cannot end at an instance.
            next unless instance || model.drawing_element_visible?(Sketchup::InstancePath.new(path_entities))
            if entity.is_a?(Sketchup::Face)
              mesh = entity.mesh(0)
              mesh.polygons.each do |indices|
                raise Unsupported, 'нетриангулированная поверхность' unless indices.length == 3
                coordinates = indices.flat_map { |i| mesh.point_at(i.abs).transform(transform).to_a }
                file.write(coordinates.pack('E*'))
                triangles += 1
              end
            elsif entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
              if entity.respond_to?(:glued_to) && entity.glued_to && entity.definition.behavior.cuts_opening?
                raise Unsupported, 'приклеенный компонент, прорезающий проём'
              end
              visit.call(entity.definition.entities, transform * entity.transformation, path_entities)
            elsif entity.is_a?(Sketchup::Image)
              raise Unsupported, 'изображение в модели'
            end
          end
        end
        visit.call(model.entities, Geom::Transformation.new, [])
        points.each { |p| file.write(p.to_a.pack('E3')) }
        vectors.each { |v| file.write(v.to_a.pack('E3')) }
        file.seek(8)
        file.write([triangles].pack('L<'))
      end
      triangles
    end

    def start(job)
      return false unless Settings.values['engine'] == 'cpp'
      unless File.file?(executable)
        RayTubesUp.log('C++ движок не найден; расчёт выполняется в SketchUp.')
        return false
      end
      directory = Dir.mktmpdir('cj-engine-')
      job[:native] = { directory: directory, started: Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      triangles = write_input(File.join(directory, 'input.bin'), job[:model], job[:points], job[:vectors])
      job[:native][:triangles] = triangles
      job[:native][:export_ms] = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - job[:native][:started]) * 1000
      job[:native][:pid] = Process.spawn(executable, File.join(directory, 'input.bin'), File.join(directory, 'output.bin'),
                                          out: File::NULL, err: File.join(directory, 'error.txt'))
      Sketchup.set_status_text("CJ C++: #{job[:points].length} точек, #{triangles} треугольников")
      job[:timer] = UI.start_timer(0.03, false) { poll(job) }
      true
    rescue StandardError => error
      RayTubesUp.log("C++ → SketchUp: #{error.message}")
      cleanup(job)
      false
    end

    def read_output(job)
      data = File.binread(File.join(job[:native][:directory], 'output.bin'))
      np, nd = data.byteslice(8, 8)&.unpack('L<2')
      unless data.byteslice(0, 8) == 'CJOUT001' && np == job[:points].length && nd == job[:vectors].length && data.bytesize == 16 + np * nd * 8
        raise 'Некорректный ответ C++ движка.'
      end
      distances = data.byteslice(16..-1).unpack('E*')
      job[:calculations].each_with_index do |calculation, i|
        calculation[:results] = job[:vectors].each_with_index.map do |direction, j|
          distance = distances[i * nd + j]
          raise 'Некорректная дистанция C++.' unless distance.finite? && (distance == -1 || distance > 0)
          hit = distance >= 0
          { i: j, dir: direction, hit_dist: hit ? distance : nil,
            hit_pt: hit ? calculation[:origin].offset(direction, distance) : nil }
        end
      end
      @last_metrics = { triangles: job[:native][:triangles], rays: np * nd,
                        export_ms: job[:native][:export_ms],
                        total_before_display_ms: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - job[:native][:started]) * 1000 }
      RayTubesUp.log("C++: #{@last_metrics}")
    end

    def poll(job)
      return unless RayTubesUp.instance_variable_get(:@active_calculation).equal?(job)
      return RayTubesUp.finish_calculation(job, cancelled: true) if job[:cancelled] || !Sketchup.active_model.equal?(job[:model])
      finished = Process.waitpid2(job[:native][:pid], Process::WNOHANG)
      if finished
        job[:native][:pid] = nil
        raise File.read(File.join(job[:native][:directory], 'error.txt')) unless finished[1].success?
        read_output(job)
        RayTubesUp.finish_calculation(job)
      else
        job[:timer] = UI.start_timer(0.03, false) { poll(job) }
      end
    rescue StandardError => error
      RayTubesUp.finish_calculation(job, error: error)
    end

    def cleanup(job)
      state = job && job.delete(:native)
      return unless state
      if state[:pid]
        begin
          unless Process.waitpid(state[:pid], Process::WNOHANG)
            Process.kill('KILL', state[:pid])
            Process.waitpid(state[:pid])
          end
        rescue Errno::ECHILD, Errno::ESRCH
          # Already exited.
        end
      end
      FileUtils.remove_entry(state[:directory]) if File.directory?(state[:directory])
    end
  end
end
