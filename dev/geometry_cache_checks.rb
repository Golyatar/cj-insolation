# frozen_string_literal: true
# Offline protocol/state checks. Live observer delivery is checked separately.
require 'json'
require 'tmpdir'
require 'fileutils'
require 'digest'
module Sketchup
  class EntitiesObserver; end
  class ModelObserver; end
end
require_relative '../src/geometry_cache'
require_relative '../src/native_engine'

module CJGeometryCacheChecks
  extend self
  class Collection
    attr_reader :observers
    def initialize; @observers = []; end
    def add_observer(observer); @observers << observer; end
    def remove_observer(observer); @observers.delete(observer); end
  end
  class Tag
    attr_accessor :visible, :folder
    attr_reader :entityID
    def initialize(id); @entityID = id; @visible = true; end
    def visible?; @visible; end
    def valid?; true; end
  end
  class Entity
    attr_accessor :valid, :point, :result
    attr_reader :entityID
    def initialize(id); @entityID = id; @valid = true; end
    def valid?; @valid; end
    def typename; 'Group'; end
    def get_attribute(dict, key, fallback = nil)
      return @point if dict == 'CJ_CalculationPoint' && key == 'id'
      return @result if dict == 'CJ_Insolation' && key == 'result'
      fallback
    end
  end
  class Model < Collection
    attr_reader :entities, :layers, :rendering_options
    attr_accessor :active_path
    def initialize
      super
      @entities = Collection.new
      @layers = [Tag.new(1)]
      @rendering_options = {'DisplaySectionCuts' => false}
    end
  end
  Vector = Struct.new(:x, :y, :z) do
    def to_a; [x, y, z]; end
  end

  def run
    checks = []
    model = Model.new
    entry = CJ::GeometryCache.state(model)
    directory = Dir.mktmpdir('cj-cache-check-')
    geometry = [0,0,10, 10,0,10, 0,10,10].pack('E*')
    seed = lambda do
      token = entry.begin_export
      entry.track(model.layers.first)
      path = File.join(directory, 'cold.bin')
      File.binwrite(path, 'CJIN0001'+[1,1,1].pack('L<3')+geometry+[1,1,0,0,0,1].pack('E*'))
      state = {triangles: 1, unique_triangles: 1, geometry_digest: Digest::SHA256.new.update(geometry)}
      adopted = entry.store(path, state, token)
      raise 'Snapshot not adopted' unless adopted == entry.file && !File.exist?(path)
    end
    check = lambda { |name, passed| checks << {name: name, passed: !!passed}; raise name unless passed }
    seed.call
    points = [Vector.new(1,1,0), Vector.new(20,20,0)]
    vectors = [Vector.new(0,0,1), Vector.new(0,0,-1)]
    output = File.join(directory, 'warm.bin')
    state = {}
    entry.write(output, points, vectors, state)
    bytes = File.binread(output)
    check.call('v1_header_geometry_and_new_point_direction_tail', bytes.byteslice(0,20) == 'CJIN0001'+[1,2,2].pack('L<3') && bytes.byteslice(20,72) == geometry && bytes.byteslice(92..-1) == (points+vectors).flat_map(&:to_a).pack('E*'))
    check.call('cache_hit_does_not_read_geometry_api', state[:cache_hit] && state[:unique_triangles] == 1)
    material = Entity.new(9)
    def material.typename; 'Material'; end
    entry.changed(material)
    check.call('material_notifications_do_not_invalidate_geometry', entry.valid?)
    point = Entity.new(10)
    point.point = 'saved'
    entry.changed(point)
    check.call('point_add_move_does_not_invalidate', entry.valid? && entry.excluded.include?(point))
    result = Entity.new(11)
    result.result = true
    entry.changed(result)
    check.call('result_add_does_not_invalidate', entry.valid?)
    entry.removed(11)
    check.call('result_removal_does_not_invalidate', entry.valid?)
    model.layers << Tag.new(20)
    check.call('unused_display_tag_does_not_invalidate', entry.valid?)
    model.layers.first.visible = false
    check.call('obstacle_tag_visibility_invalidates', !entry.valid?)
    model.layers.first.visible = true
    seed.call
    parent = Tag.new(22)
    model.layers.first.folder = parent
    check.call('folder_move_invalidates', !entry.valid?)
    seed.call
    parent.visible = false
    check.call('parent_folder_visibility_invalidates', !entry.valid?)
    parent.visible = true
    seed.call
    model.rendering_options['DisplaySectionCuts'] = true
    check.call('section_cut_mode_invalidates', !entry.valid?)
    model.rendering_options['DisplaySectionCuts'] = false
    seed.call
    entry.changed(Entity.new(30))
    check.call('geometry_add_move_or_edit_invalidates', !entry.valid?)
    seed.call
    entry.removed(31)
    check.call('geometry_delete_invalidates', !entry.valid?)
    seed.call
    point.point = nil
    entry.changed(point)
    entry.valid?
    seed.call
    entry.removed(point.entityID)
    check.call('former_point_geometry_removal_invalidates', !entry.valid?)
    [:onTransactionUndo, :onTransactionRedo, :onTransactionAbort].each do |method|
      seed.call
      model.observers.first.public_send(method, model)
      check.call("#{method}_invalidates", !entry.valid?)
    end
    seed.call
    model.active_path = [1]
    check.call('open_component_edit_disables_reuse', !entry.valid?)
    model.active_path = nil
    seed.call
    File.open(entry.file,'r+b') { |file| file.seek(20); file.write([99.0].pack('E')) }
    rejected = false
    begin
      entry.write(output, points, vectors, {})
    rescue CJ::GeometryCache::Invalid
      rejected = true
    end
    check.call('same_size_corruption_rejected_before_worker', rejected && !entry.valid?)
    seed.call
    # Simulate abandoning a Fiber while both cache source and output are open.
    cancelled_dir = Dir.mktmpdir('cj-cache-cancel-')
    job = {native: {directory: cancelled_dir}}
    fiber = Fiber.new do
      entry.write(File.join(cancelled_dir,'input.bin'), points, vectors, job[:native]) { Fiber.yield }
    end
    fiber.resume
    source, target = job[:native].values_at(:cache_source, :file)
    CJ::NativeEngine.cleanup(job)
    check.call('cancel_closes_both_files_and_preserves_snapshot', source.closed? && target.closed? && !File.exist?(cancelled_dir) && File.file?(entry.file))
    cached_path = entry.file
    CJ::GeometryCache.forget(model)
    check.call('release_detaches_observers_and_removes_snapshot', !File.exist?(cached_path) && model.observers.empty? && model.entities.observers.empty?)
    {passed: checks.all? { |item| item[:passed] }, checks: checks}
  ensure
    CJ::GeometryCache.forget(model) if model
    FileUtils.remove_entry(directory) if directory && File.directory?(directory)
  end
end
puts JSON.pretty_generate(CJGeometryCacheChecks.run) if $PROGRAM_NAME == __FILE__
