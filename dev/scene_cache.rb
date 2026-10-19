# frozen_string_literal: true
require 'tmpdir'
require 'fileutils'

module CJ
  # Observers only invalidate data. They never start calculations or edit models.
  module SceneCache
    extend self

    def internal
      @internal = (@internal || 0) + 1
      yield
    ensure
      @internal -= 1
    end

    def internal?
      (@internal || 0) > 0
    end

    def state(model)
      @states ||= {}
      @states[model] ||= State.new(model)
    end

    def watch(model, entities)
      state(model).watch(entities) if model.is_a?(Sketchup::Model)
    end

    def forget(model)
      (@states || {}).delete(model)&.release
    end

    def write(path, model, points, vectors)
      return SceneExport.write(path,model,points,vectors) unless model.is_a?(Sketchup::Model)
      entry = state(model)
      key = entry.fingerprint
      if entry.key == key && File.file?(entry.file)
        File.open(entry.file,'rb') do |source|
          header = source.read(24)
          meshes,instances,old_points,old_vectors = header.byteslice(8,16).unpack('L<4')
          geometry_bytes = source.size - 24 - (old_points+old_vectors)*24
          File.open(path,'wb') do |output|
            output.write('CJIN0002'+[meshes,instances,points.length,vectors.length].pack('L<4'))
            IO.copy_stream(source,output,geometry_bytes)
            points.each { |p| output.write(p.to_a.pack('E3')) }
            vectors.each { |v| output.write(v.to_a.pack('E3')) }
          end
        end
        SceneExport.set_stats(entry.stats.merge(cache_hit:true,bytes:File.size(path)))
        entry.stats[:triangles]
      else
        triangles = SceneExport.write(path,model,points,vectors)
        FileUtils.copy_file(path,entry.file)
        entry.store(key,SceneExport.last_stats)
        triangles
      end
    end

    class EntityChanges < Sketchup::EntitiesObserver
      def initialize(state)
        @state = state
      end
      def onElementModified(_entities, entity)
        return if SceneCache.internal?
        return if entity.get_attribute('CJ_CalculationPoint','id') || entity.get_attribute('CJ_Insolation','result',false)
        @state.invalidate
      end
      alias onElementAdded onElementModified
      def onElementRemoved(_entities, _id)
        @state.invalidate unless SceneCache.internal?
      end
      def onActiveSectionPlaneChanged(_entities)
        @state.invalidate unless SceneCache.internal?
      end
    end

    class ModelChanges < Sketchup::ModelObserver
      def initialize(state)
        @state = state
      end
      def onTransactionUndo(_model)
        @state.invalidate
      end
      alias onTransactionRedo onTransactionUndo
      alias onTransactionAbort onTransactionUndo
      def onDeleteModel(model)
        SceneCache.forget(model)
      end
    end

    class State
      attr_reader :file, :key, :stats
      def initialize(model)
        @model = model
        @generation = 0
        @collections = {}
        @directory = Dir.mktmpdir('cj-scene-cache-')
        @file = File.join(@directory,'scene.bin')
        @observer = EntityChanges.new(self)
        @model_observer = ModelChanges.new(self)
        model.add_observer(@model_observer)
        watch(model.entities)
      end
      def watch(entities)
        return if @collections.key?(entities)
        entities.add_observer(@observer)
        @collections[entities] = true
      end
      def invalidate
        @generation += 1
        @key = nil
      end
      def fingerprint
        tags = @model.layers.map do |tag|
          folders = []
          parent = tag.folder
          while parent
            folders << [parent.entityID,parent.visible?]
            parent = parent.folder
          end
          [tag.entityID,tag.visible?,folders]
        end
        [@generation,tags,@model.rendering_options['DisplaySectionCuts']]
      end
      def store(key, stats)
        @key = key
        @stats = stats.dup
      end
      def release
        @collections.each_key { |entities| entities.remove_observer(@observer) rescue nil }
        @model.remove_observer(@model_observer) rescue nil
        FileUtils.remove_entry(@directory) if File.directory?(@directory)
      end
    end
  end
end

at_exit { (CJ::SceneCache.instance_variable_get(:@states) || {}).keys.each { |model| CJ::SceneCache.forget(model) } }
