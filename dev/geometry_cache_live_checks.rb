# frozen_string_literal: true
require 'json'
require 'tmpdir'

# A private cache with a tiny fixture, never used by production calculations.
# Committed observer notifications are tested with normal operations;
# only explicitly owned fixture objects/tags are removed afterwards. No SKP is saved.
module CJGeometryCacheLiveChecks
  extend self
  View = Struct.new(:entities, :definitions, :layers, :rendering_options) unless const_defined?(:View, false)

  def run
    @model = Sketchup.active_model
    raise 'Calculation in progress' if CJ::RayTubesUp.instance_variable_get(:@active_calculation)
    raise 'Exit component editing' if @model.active_path
    raise 'Use an already modified scratch model for committed observer checks' unless @model.modified?
    @before = {entities: @model.entities.length, selection: @model.selection.to_a, modified: @model.modified?, layers: @model.layers.length}
    @checks, @index = [], 0
    @owned_tags, @owned_folders, @display_original = [], [], []
    @directory = Dir.mktmpdir('cj-cache-live-check-')
    @fixture_id = SecureRandom.uuid
    @model.start_operation('CJ temporary geometry cache checks', true)
    @fixture = @model.entities.add_group
    @fixture.set_attribute('CJ_CacheTest', 'id', @fixture_id)
    anchor = @model.bounds.max.offset(Geom::Vector3d.new(100.m,100.m,100.m))
    @face = @fixture.entities.add_face([anchor,anchor.offset(X_AXIS,1.m),anchor.offset(Y_AXIS,1.m)])
    @model.commit_operation
    @entry = CJ::GeometryCache::State.new(@model)
    @view = View.new(@fixture.entities, @model.definitions.select(&:image?), @model.layers, {'DisplaySectionCuts'=>false})
    @points, @vectors = [anchor.offset(Z_AXIS,1.m)], [Z_AXIS]
    @steps = [
      -> { seed; check('initial_snapshot_valid', @entry.valid?); compare; operation { @point = CJ::SavedPoints.add(@model, @points.first) } },
      -> { check('native_point_creation_keeps_snapshot', @entry.valid? && @entry.excluded.include?(@point)); operation { @point.transform!(Geom::Transformation.translation([1.m,0,0])) } },
      -> { check('native_point_move_keeps_snapshot', @entry.valid?); operation { add_display_tags; @result=CJ::RayTubesUp.build_batch(@model,[{origin:@points.first,results:[]}],mode: :summary) } },
      -> { check('result_creation_and_display_tags_keep_snapshot', @entry.valid?); operation { @result.erase! } },
      -> { check('result_removal_keeps_snapshot', @entry.valid?); operation { p=@points.first.offset(X_AXIS,3.m); @other=@fixture.entities.add_face([p,p.offset(X_AXIS,1.m),p.offset(Y_AXIS,1.m)]) } },
      -> { check('nested_geometry_add_invalidates', !@entry.valid?); seed; compare; operation { @fixture.entities.transform_entities(Geom::Transformation.translation([0,0,10.mm]), @other) } },
      -> { check('nested_geometry_edit_invalidates', !@entry.valid?); seed; operation { @fixture.transform!(Geom::Transformation.translation([1.m,0,0])) } },
      -> { check('instance_move_invalidates', !@entry.valid?); seed; operation { @face.hidden = true } },
      -> { check('hidden_face_invalidates', !@entry.valid?); seed; operation { @face.hidden=false; @tag=@model.layers.add('CJ_cache_test_'+@fixture_id); @owned_tags<<@tag; @face.layer=@tag } },
      -> { check('tag_assignment_invalidates', !@entry.valid?); seed; operation { @tag.visible=false } },
      -> { check('tag_visibility_invalidates', !@entry.valid?); seed; operation { @tag.visible=true; @folder=@model.layers.add_folder('CJ_cache_test_'+@fixture_id); @owned_folders<<@folder; @folder.add_layer(@tag) } },
      -> { seed; operation { @folder.visible=false } },
      -> { check('parent_folder_visibility_invalidates', !@entry.valid?); seed; operation { @folder.visible=true; @other.erase! } },
      -> { check('nested_geometry_removal_invalidates', !@entry.valid?); seed; compare; @model.start_operation('CJ cache aborted fixture change',true); @fixture.entities.add_line([0,0,0],[1,1,1]); @model.abort_operation },
      -> { check('abort_invalidates', !@entry.valid?) },
      -> { finish }
    ]
    schedule
    :scheduled
  rescue StandardError => error
    fail_check(error)
  end

  def operation
    @model.start_operation('CJ cache fixture change', true)
    yield
    @model.commit_operation
  rescue StandardError
    @model.abort_operation
    raise
  end

  def seed
    path = File.join(@directory,'cold.bin')
    token = @entry.begin_export
    state = {cache_entry:@entry, geometry_digest:Digest::SHA256.new}
    count = CJ::NativeEngine.write_input(path,@view,@points,@vectors,excluded:[],state:state)
    state[:triangles] = count
    @entry.store(path,state,token)
  end

  def compare
    fresh, warm = %w[fresh.bin warm.bin].map { |name| File.join(@directory,name) }
    CJ::NativeEngine.write_input(fresh,@view,@points,@vectors,excluded:[])
    @entry.write(warm,@points,@vectors,{})
    check('cached_geometry_matches_fresh_'+@checks.length.to_s, File.binread(fresh)==File.binread(warm))
  end

  def check(name, passed)
    @checks << {name:name,passed:!!passed,reason:passed ? nil : @entry.instance_variable_get(:@last_invalidation)}
    raise name unless passed
  end

  def schedule
    @timer = UI.start_timer(0.02,false) do
      begin
        step=@steps[@index]
        @index+=1
        step.call
        schedule if @index<@steps.length
      rescue StandardError => error
        fail_check(error)
      end
    end
  end

  def cleanup
    @entry&.release
    @model.start_operation('CJ: remove owned cache test fixture',true)
    owned=[@fixture,@point,@result].compact.select(&:valid?)
    @model.entities.erase_entities(owned) unless owned.empty?
    @display_original.each do |tag,name,parent,visible|
      next unless tag.valid?
      tag.name=name
      if parent && parent.valid?
        parent.add_layer(tag)
      elsif tag.folder
        tag.folder.remove_layer(tag)
      end
      tag.visible=visible
    end
    @owned_tags.each { |tag| @model.layers.remove(tag,true) if tag.valid? }
    @owned_folders.reverse_each do |folder|
      next unless folder.valid? && folder.layers.empty? && folder.folders.empty?
      (folder.folder || @model.layers).remove_folder(folder)
    end
    @model.commit_operation
    FileUtils.remove_entry(@directory) if @directory && File.directory?(@directory)
  end

  def all_folders(items=@model.layers.folders)
    items.flat_map { |folder| [folder]+all_folders(folder.folders) }
  end

  def add_display_tags
    tags=@model.layers.to_a
    folders=all_folders
    @display_original=tags.select{|tag|tag.name.start_with?('CJ · ')}.map{|tag|[tag,tag.name,tag.folder,tag.visible?]}
    CJ::ResultStyle.tags(@model,passed:true)
    CJ::ResultStyle.tags(@model,passed:false)
    @owned_tags.concat(@model.layers.to_a-tags)
    @owned_folders.concat(all_folders-folders)
  end

  def finish
    cleanup
    check('user_model_restored', @model.entities.length == @before[:entities] && @model.selection.to_a == @before[:selection] && @model.modified? == @before[:modified] && @model.layers.length == @before[:layers])
    save({passed:true,checks:@checks,scope:'Committed native observer events on owned temporary fixture; active user geometry restored; no SKP saved'})
  end

  def fail_check(error)
    cleanup
    save({passed:false,checks:@checks,error:error.message,trace:error.backtrace.first(8)})
  end

  def save(report)
    File.write(File.expand_path('../reports/geometry_cache_live_check.json',__dir__),JSON.pretty_generate(report))
  end
end
