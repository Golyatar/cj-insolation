# frozen_string_literal: true
require 'tmpdir'
require 'fileutils'
require 'digest'

module CJ
  # Session-only v1 geometry snapshot. Observers invalidate; never calculate/edit.
  module GeometryCache
    extend self
    class Invalid < StandardError; end

    def state(model)
      @states ||= {}
      @states[model] ||= State.new(model)
    end

    def forget(model)
      (@states || {}).delete(model)&.release
    end

    class EntityChanges < Sketchup::EntitiesObserver
      def initialize(entry); @entry = entry; end
      def onElementModified(_entities, entity); @entry.changed(entity); end
      alias onElementAdded onElementModified
      def onElementRemoved(_entities, id); @entry.removed(id); end
      def onActiveSectionPlaneChanged(_entities); @entry.invalidate; end
    end

    class ModelChanges < Sketchup::ModelObserver
      def initialize(entry); @entry = entry; end
      def onTransactionUndo(_model); @entry.invalidate(:undo); end
      def onTransactionRedo(_model); @entry.invalidate(:redo); end
      def onTransactionAbort(_model); @entry.invalidate(:abort); end
      def onDeleteModel(model); GeometryCache.forget(model); end
    end

    class State
      attr_reader :file, :stats

      def initialize(model)
        @model = model
        @generation = 0
        @key = nil
        @pending, @ignored, @collections, @tags = {}, {}, {}, {}
        @directory = Dir.mktmpdir('cj-geometry-cache-')
        @file = File.join(@directory, 'scene.bin')
        @entities_observer = EntityChanges.new(self)
        @model_observer = ModelChanges.new(self)
        model.add_observer(@model_observer)
        watch(model.entities)
      end

      def watch(entities)
        return if @collections.key?(entities)
        entities.add_observer(@entities_observer)
        @collections[entities] = true
      end

      def ignored?(entity)
        entity.valid? && (entity.get_attribute('CJ_CalculationPoint', 'id') || entity.get_attribute('CJ_Insolation', 'result', false))
      end

      def remember(entity)
        @ignored[entity.entityID] = entity if ignored?(entity)
      end

      def excluded
        @ignored.values.select { |entity| ignored?(entity) }
      end

      def changed(entity)
        # SketchUp also forwards material changes through these callbacks.
        # Materials do not change the geometry used by the v1 ray worker.
        return if entity.valid? && !%w[Face Edge Vertex Group ComponentInstance Image SectionPlane].include?(entity.typename)
        @pending[entity.entityID] = entity
      rescue StandardError
        invalidate
      end

      def removed(id)
        @pending.delete(id)
        invalidate([:removed, id]) unless @ignored.delete(id)
      end

      def invalidate(reason = :geometry)
        @last_invalidation = reason
        @generation += 1
        @key = nil
      end

      def flush
        pending, @pending = @pending, {}
        pending.each do |id, entity|
          if ignored?(entity)
            remember(entity)
          else
            @ignored.delete(id)
            invalidate([:modified, id, entity.valid? ? entity.typename : 'deleted'])
          end
        end
      end

      def track(tag)
        @tags[tag.entityID] = tag
      end

      def tag_state(tags)
        tags.map do |tag|
          return nil unless tag.valid?
          parents, folder = [], tag.folder
          while folder
            parents << [folder.entityID, folder.visible?]
            folder = folder.folder
          end
          [tag.entityID, tag.visible?, parents]
        end
      end

      def fingerprint
        flush
        [@generation, tag_state(@tags.values), @model.rendering_options['DisplaySectionCuts']]
      end

      def token
        flush
        [@generation, tag_state(@model.layers.to_a), @model.rendering_options['DisplaySectionCuts']]
      end

      def valid?
        !@model.active_path && @key && @key == fingerprint && File.file?(@file) && File.size(@file) == @size
      end

      def begin_export
        @tags.clear
        token
      end

      def store(path, state, original_token)
        return path unless !@model.active_path && original_token == token
        @key = nil
        File.delete(@file) if File.file?(@file)
        File.rename(path, @file)
        @size = File.size(@file)
        @digest = state.fetch(:geometry_digest).hexdigest
        @stats = {triangles: state[:triangles], unique_triangles: state[:unique_triangles]}
        @key = fingerprint
        @file
      end

      def current?
        @key && @key == fingerprint
      end

      def write(path, points, vectors, state, &checkpoint)
        raise Invalid, 'Снимок геометрии устарел' unless valid?
        state[:cache_hit] = true
        state[:total_triangles] = @stats[:triangles]
        state[:unique_triangles] = @stats[:unique_triangles]
        bytes = @stats[:triangles] * 72
        digest = Digest::SHA256.new
        File.open(@file, 'rb') do |source|
          state[:cache_source] = source
          header = source.read(20)
          raise Invalid, 'Некорректный снимок геометрии' unless header&.byteslice(0, 8) == 'CJIN0001' && header.byteslice(8, 4).unpack1('L<') == @stats[:triangles]
          File.open(path, 'wb') do |output|
            state[:file] = output
            output.write('CJIN0001' + [@stats[:triangles], points.length, vectors.length].pack('L<3'))
            copied = 0
            while copied < bytes
              data = source.read([4 * 1024 * 1024, bytes - copied].min)
              raise Invalid, 'Снимок геометрии обрезан' unless data && !data.empty?
              digest.update(data)
              output.write(data)
              copied += data.bytesize
              checkpoint&.call(copied / 72, true)
            end
            raise Invalid, 'Снимок геометрии повреждён' unless digest.hexdigest == @digest
            points.each { |point| output.write(point.to_a.pack('E3')) }
            vectors.each { |vector| output.write(vector.to_a.pack('E3')) }
          end
        end
        raise Invalid, 'Модель изменилась во время подготовки' unless current?
        @stats[:triangles]
      rescue Invalid
        invalidate
        raise
      end

      def release
        @collections.each_key { |entities| entities.remove_observer(@entities_observer) rescue nil }
        @model.remove_observer(@model_observer) rescue nil
        FileUtils.remove_entry(@directory) if File.directory?(@directory)
      rescue StandardError
        # A closing model may still have a worker reading its snapshot.
      end
    end
  end
end

unless defined?(CJ_GEOMETRY_CACHE_EXIT_REGISTERED)
  CJ_GEOMETRY_CACHE_EXIT_REGISTERED = true
  at_exit { (CJ::GeometryCache.instance_variable_get(:@states) || {}).keys.each { |model| CJ::GeometryCache.forget(model) } }
end
