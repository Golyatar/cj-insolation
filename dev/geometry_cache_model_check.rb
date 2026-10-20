# frozen_string_literal: true
require 'json'
require 'tmpdir'

# Read actual geometry, then run the real warm UI/worker path on virtual points.
# Cancel before drawing, preserving the active model's existing points/results.
module CJGeometryCacheModelCheck
  extend self
  def clock; Process.clock_gettime(Process::CLOCK_MONOTONIC); end

  def run
    @model=Sketchup.active_model
    raise 'Calculation in progress' if CJ::RayTubesUp.instance_variable_get(:@active_calculation)
    raise 'Exit component editing' if @model.active_path
    raise 'Choose C++' unless CJ::Settings.values['engine']=='cpp'
    @before={entities:@model.entities.length,modified:@model.modified?,selection:@model.selection.to_a}
    @points=CJ::SavedPoints.visible(@model).last(3).map{|group|CJ::SavedPoints.origin(group)}
    if @points.length<3
      bounds=@model.bounds
      @points=3.times.map{|i|Geom::Point3d.new(bounds.min.x-10.m,bounds.min.y+(bounds.max.y-bounds.min.y)*(i+1)/4.0,bounds.min.z+1.5.m)}
    end
    @vectors=CJ::RayTubesUp.ray_vectors
    @golden=CJ::RayTubesUp.calculate_points(@model,@points).flat_map{|calculation|calculation[:results].map{|result|result[:hit_dist] || -1.0}}
    CJ::GeometryCache.forget(@model)
    @entry=CJ::GeometryCache.state(@model)
    @directory=Dir.mktmpdir('cj-cache-model-check-')
    @state={cache_entry:@entry,geometry_digest:Digest::SHA256.new}
    @started=clock
    @fiber=Fiber.new do
      deadline=clock+0.08
      checks=0
      checkpoint=lambda do |count=nil,force=false|
        checks+=1
        if (force || checks%128==0) && clock>=deadline
          Fiber.yield
          deadline=clock+0.08
        end
      end
      excluded=CJ::RayTubesUp.result_groups(@model,&checkpoint)+CJ::SavedPoints.all(@model)
      excluded.each{|entity|@entry.remember(entity)}
      token=@entry.begin_export
      path=File.join(@directory,'cold.bin')
      @state[:triangles]=CJ::NativeEngine.write_input(path,@model,@points,@vectors,excluded:excluded,state:@state,&checkpoint)
      @entry.store(path,@state,token)
    end
    @ticks=0
    cold_tick
    :scheduled
  rescue StandardError => error
    failure(error)
  end

  def cold_tick
    @ticks+=1
    raise 'Active model changed' unless Sketchup.active_model.equal?(@model)
    @fiber.resume
    if @fiber.alive?
      @timer=UI.start_timer(0.001,false){cold_tick}
    else
      @cold_ms=(clock-@started)*1000
      raise 'Cold cache not valid' unless @entry.valid?
      @job=CJ::RayTubesUp.run_from_points(@points,mode: :summary)
      @timer=UI.start_timer(0.01,false){warm_tick}
    end
  rescue StandardError => error
    failure(error)
  end

  def warm_tick
    @ticks+=1
    if @job[:phase]==:drawing
      actual=@job[:calculations].flat_map{|calculation|calculation[:results].map{|result|result[:hit_dist] || -1.0}}
      pairs=@golden.zip(actual)
      mismatch=pairs.count{|a,b|!b || (a<0)!=(b<0)}
      error=pairs.select{|a,b|b && a>=0 && b>=0}.map{|a,b|(a-b).abs.to_mm}.max || 0
      metrics=CJ::NativeEngine.last_metrics
      CJ::RayTubesUp.finish_calculation(@job,cancelled:true)
      preserved=@model.entities.length==@before[:entities] && @model.modified? == @before[:modified] && @model.selection.to_a==@before[:selection]
      save({passed:mismatch.zero? && error<0.01 && preserved && metrics[:geometry_cache_hit],
            cold_preparation_ms:@cold_ms,warm_metrics:metrics,rays:actual.length,mismatches:mismatch,max_error_mm:error,
            ui_ticks:@ticks,user_model_preserved:preserved,scope:'Fresh v1 snapshot then warm production job with virtual points; cancelled before drawing; no SKP saved'})
      cleanup
    else
      raise 'Job ended early' unless CJ::RayTubesUp.instance_variable_get(:@active_calculation).equal?(@job)
      raise 'Cache model test exceeded 90 seconds' if clock-@started>90
      @timer=UI.start_timer(0.01,false){warm_tick}
    end
  rescue StandardError => error
    failure(error)
  end

  def save(report)
    File.write(File.expand_path('../reports/geometry_cache_model_check.json',__dir__),JSON.pretty_generate(report))
  end

  def cleanup
    @state[:file].close if @state && @state[:file] && !@state[:file].closed?
    @fiber=nil
    CJ::GeometryCache.forget(@model) if @model
    FileUtils.remove_entry(@directory) if @directory && File.directory?(@directory)
  end

  def failure(error)
    CJ::RayTubesUp.finish_calculation(@job,cancelled:true) if @job
    cleanup
    save({passed:false,error:error.message,trace:error.backtrace.first(6)})
  end
end
