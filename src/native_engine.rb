# frozen_string_literal: true
require 'tmpdir'
require 'fileutils'
require 'digest'
require 'fiber'

module CJ
  module NativeEngine
    extend self
    class Unsupported < StandardError; end
    attr_reader :last_metrics
    APPROVED_SHA256 = 'b6a02b00a3cb35cd93976be0d070683f275c6b8e61b98c474dd75a97b3c0e376'.freeze unless const_defined?(:APPROVED_SHA256, false)

    def executable
      packaged = File.join(__dir__, 'bin', 'cj_engine.exe')
      File.file?(packaged) ? packaged : File.expand_path('../native/stable/cj_engine.exe', __dir__)
    end

    def approved?(path = executable)
      File.file?(path) && Digest::SHA256.file(path).hexdigest == APPROVED_SHA256
    end

    def write_input(path, model, points, vectors, excluded: nil, state: nil, &checkpoint)
      triangles = 0
      meshes = {} # Reuse local face meshes only within this export.
      excluded ||= RayTubesUp.raycast_exclusions(model)
      image_definitions = {}
      model.definitions.each do |definition|
        checkpoint&.call
        next unless definition.image?
        definition.instances.each { |image| image_definitions[image.entityID] = definition }
      end
      visible_tags = model.layers.to_h do |tag|
        visible = tag.visible?
        folder = tag.folder
        while folder
          visible &&= folder.visible?
          folder = folder.folder
        end
        [tag.entityID, visible]
      end
      File.open(path, 'wb') do |file|
        state[:file] = file if state
        file.write('CJIN0001' + [0, points.length, vectors.length].pack('L<3'))
        buffer = ''.b
        visit = lambda do |entities, transform, ancestry|
          entities.each do |entity|
            checkpoint&.call(triangles)
            if model.rendering_options['DisplaySectionCuts'] && entity.is_a?(Sketchup::SectionPlane) && entity.active?
              raise Unsupported, 'активное сечение'
            end
            instance = entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
            next unless instance || entity.is_a?(Sketchup::Face) || entity.is_a?(Sketchup::Image)
            next if excluded.include?(entity) || entity.get_attribute('CJ_Insolation', 'result', false)
            next if entity.hidden? || !visible_tags.fetch(entity.layer.entityID, false)
            path_entities = ancestry + [entity]
            # Visibility is explicit, including tag folders: hidden geometry is
            # excluded even when SketchUp's Show Hidden options are enabled.
            if entity.is_a?(Sketchup::Face)
              local_triangles = meshes[entity.entityID] ||= begin
                mesh = entity.mesh(0)
                vertices = mesh.points
                mesh.polygons.map do |indices|
                  raise Unsupported, 'нетриангулированная поверхность' unless indices.length == 3
                  indices.map { |i| vertices[i.abs - 1] }
                end
              end
              local_triangles.each do |triangle|
                coordinates = triangle.flat_map { |point| point.transform(transform).to_a }
                buffer << coordinates.pack('E*')
                if buffer.bytesize >= 262144
                  file.write(buffer)
                  buffer.clear
                end
                triangles += 1
                checkpoint&.call(triangles)
              end
            elsif entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
              if entity.respond_to?(:glued_to) && entity.glued_to && entity.definition.behavior.cuts_opening?
                raise Unsupported, 'приклеенный компонент, прорезающий проём'
              end
              visit.call(entity.definition.entities, transform * entity.transformation, path_entities)
            elsif entity.is_a?(Sketchup::Image)
              definition = image_definitions[entity.entityID]
              raise Unsupported, 'не найдена геометрия изображения' unless definition
              visit.call(definition.entities, transform * entity.transformation, path_entities)
            end
          end
        end
        visit.call(model.entities, Geom::Transformation.new, [])
        file.write(buffer) unless buffer.empty?
        points.each { |p| file.write(p.to_a.pack('E3')) }
        vectors.each { |v| file.write(v.to_a.pack('E3')) }
        file.seek(8)
        file.write([triangles].pack('L<'))
      end
      triangles
    end

    def start(job)
      return false unless Settings.values['engine'] == 'cpp'
      worker = executable
      unless approved?(worker)
        RayTubesUp.log('Сохранённый рабочий C++ движок отсутствует или изменён; расчёт выполняется в SketchUp.')
        return false
      end
      directory = Dir.mktmpdir('cj-engine-')
      job[:native] = { directory: directory, started: Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      state = job[:native]
      state[:worker] = worker
      state[:fiber] = Fiber.new do
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.08
        checks = 0
        checkpoint = lambda do |count = nil|
          state[:triangles] = count if count
          checks += 1
          if checks % 128 == 0 && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            Fiber.yield
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.08
          end
        end
        RayTubesUp.prepare_calculation(job, &checkpoint)
        write_input(File.join(directory, 'input.bin'), job[:model], job[:points], job[:vectors],
                    excluded: job[:hidden_states].map(&:first), state: state, &checkpoint)
      end
      job[:phase] = :exporting
      RayTubesUp.update_calculation_phase(job, 'Подготовка модели', 'Проверка видимой геометрии…')
      job[:timer] = UI.start_timer(0.001, false) { export_chunk(job) }
      true
    rescue StandardError => error
      RayTubesUp.log("C++ → SketchUp: #{error.message}")
      cleanup(job)
      false
    end

    def export_chunk(job)
      return unless RayTubesUp.instance_variable_get(:@active_calculation).equal?(job)
      return RayTubesUp.finish_calculation(job, cancelled: true) if job[:cancelled] || !Sketchup.active_model.equal?(job[:model])
      state = job[:native]
      result = state[:fiber].resume
      if state[:fiber].alive?
        count = state[:triangles] || 0
        RayTubesUp.update_calculation_phase(job, 'Подготовка модели', "Подготовлено треугольников: #{count}")
        job[:timer] = UI.start_timer(0.001, false) { export_chunk(job) }
      else
        state.delete(:fiber)
        state[:triangles] = result
        state[:export_ms] = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - state[:started]) * 1000
        raise 'Рабочий EXE изменён во время подготовки.' unless approved?(state[:worker])
        state[:pid] = Process.spawn(state[:worker], File.join(state[:directory], 'input.bin'), File.join(state[:directory], 'output.bin'),
                                    out: File::NULL, err: File.join(state[:directory], 'error.txt'))
        job[:phase] = :cpp
        RayTubesUp.update_calculation_phase(job, 'Расчёт инсоляции', "Точек: #{job[:points].length}; направлений: #{job[:total_rays]}")
        job[:timer] = UI.start_timer(0.03, false) { poll(job) }
      end
    rescue StandardError => error
      RayTubesUp.log("C++ → SketchUp: #{error.message}")
      cleanup(job)
      RayTubesUp.start_sketchup_calculation(job)
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
        RayTubesUp.schedule_calculation_finish(job)
      else
        job[:timer] = UI.start_timer(0.03, false) { poll(job) }
      end
    rescue StandardError => error
      RayTubesUp.finish_calculation(job, error: error)
    end

    def cleanup(job)
      state = job && job.delete(:native)
      return unless state
      # HtmlDialog callbacks can run in a different Ruby callback context.
      # Own and close the file directly; do not resume an abandoned export there.
      file = state.delete(:file)
      file.close if file && !file.closed?
      state.delete(:fiber)
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
