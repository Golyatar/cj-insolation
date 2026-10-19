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
      # Read each definition once. Expanding its instances needs no further
      # SketchUp entity/mesh calls, and still produces the saved worker's v1 data.
      nodes = {}
      cuts = model.rendering_options['DisplaySectionCuts']
      excluded_ids = excluded.to_h { |entity| [entity.entityID, true] }
      read_node = nil
      read_node = lambda do |entities, key|
        return nodes[key] if nodes.key?(key)
        node = {coordinates: [], children: []}
        nodes[key] = node
        entities.each do |entity|
          checkpoint&.call
          if cuts && entity.is_a?(Sketchup::SectionPlane) && entity.active?
            raise Unsupported, 'активное сечение'
          end
          instance = entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
          face = entity.is_a?(Sketchup::Face)
          image = entity.is_a?(Sketchup::Image)
          next unless instance || face || image
          next if excluded_ids[entity.entityID] || entity.get_attribute('CJ_Insolation', 'result', false)
          next if entity.hidden? || !visible_tags.fetch(entity.layer.entityID, false)
          if face
            mesh = entity.mesh(0)
            vertices = mesh.points.map(&:to_a)
            mesh.polygons.each do |indices|
              raise Unsupported, 'нетриангулированная поверхность' unless indices.length == 3
              indices.each { |i| node[:coordinates].concat(vertices[i.abs - 1]) }
              checkpoint&.call
            end
          else
            if instance && entity.respond_to?(:glued_to) && entity.glued_to && entity.definition.behavior.cuts_opening?
              raise Unsupported, 'приклеенный компонент, прорезающий проём'
            end
            definition = instance ? entity.definition : image_definitions[entity.entityID]
            raise Unsupported, 'не найдена геометрия изображения' unless definition
            child = read_node.call(definition.entities, definition.entityID)
            node[:children] << [child, entity.transformation]
          end
        end
        node[:triangle_count] = node[:coordinates].length / 9 + node[:children].sum { |child, _| child.fetch(:triangle_count) }
        node
      end
      root = read_node.call(model.entities, :root)
      state[:total_triangles] = root[:triangle_count] if state
      File.open(path, 'wb') do |file|
        state[:file] = file if state
        file.write('CJIN0001' + [0, points.length, vectors.length].pack('L<3'))
        buffer = ''.b
        visit = lambda do |node, transform|
          matrix = transform.to_a
          node[:coordinates].each_slice(9216) do |coordinates|
            buffer << transform_coordinates(coordinates, matrix).pack('E*')
            if buffer.bytesize >= 262144
              file.write(buffer)
              buffer.clear
            end
            triangles += coordinates.length / 9
            checkpoint&.call(triangles, true)
          end
          node[:children].each { |child, local| visit.call(child, transform * local) }
        end
        visit.call(root, Geom::Transformation.new)
        file.write(buffer) unless buffer.empty?
        points.each { |p| file.write(p.to_a.pack('E3')) }
        vectors.each { |v| file.write(v.to_a.pack('E3')) }
        file.seek(8)
        file.write([triangles].pack('L<'))
      end
      state[:unique_triangles] = nodes.values.sum { |node| node[:coordinates].length / 9 } if state
      triangles
    end

    def transform_coordinates(coordinates, m)
      # Preserve native behavior for unusual homogeneous/projective transforms.
      unless m[3] == 0 && m[7] == 0 && m[11] == 0 && m[15] == 1
        tr = Geom::Transformation.new(m)
        return coordinates.each_slice(3).flat_map { |p| Geom::Point3d.new(p).transform(tr).to_a }
      end
      output = Array.new(coordinates.length)
      a,b,c,d,e,f,g,h,i,tx,ty,tz = m.values_at(0,1,2,4,5,6,8,9,10,12,13,14)
      index = 0
      if b == 0 && c == 0 && d == 0 && f == 0 && g == 0 && h == 0
        return coordinates if a == 1 && e == 1 && i == 1 && tx == 0 && ty == 0 && tz == 0
        while index < coordinates.length
          output[index] = a * coordinates[index] + tx
          output[index+1] = e * coordinates[index+1] + ty
          output[index+2] = i * coordinates[index+2] + tz
          index += 3
        end
      elsif c == 0 && f == 0 && g == 0 && h == 0
        while index < coordinates.length
          x,y = coordinates[index],coordinates[index+1]
          output[index] = a*x+d*y+tx
          output[index+1] = b*x+e*y+ty
          output[index+2] = i*coordinates[index+2]+tz
          index += 3
        end
      else
        while index < coordinates.length
          x,y,z = coordinates[index],coordinates[index+1],coordinates[index+2]
          output[index] = a*x+d*y+g*z+tx
          output[index+1] = b*x+e*y+h*z+ty
          output[index+2] = c*x+f*y+i*z+tz
          index += 3
        end
      end
      output
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
        checkpoint = lambda do |count = nil, force = false|
          state[:triangles] = count if count
          checks += 1
          if (force || checks % 128 == 0) && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
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
        total = state[:total_triangles]
        detail = total ? "Подготовлено треугольников: #{count} из #{total}" : 'Чтение видимой геометрии…'
        RayTubesUp.update_calculation_phase(job, 'Подготовка модели', detail, done: count, total: total)
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
                        unique_triangles: job[:native][:unique_triangles],
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
