# frozen_string_literal: true
require 'json'
require 'tmpdir'
module CJCppChecks
  extend self
  def clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
  def run
    @model = Sketchup.active_model
    raise 'Use an empty test model' unless @model.entities.length.zero?
    @directory = Dir.mktmpdir('cj-cpp-parity-')
    @model.start_operation('CJ C++ comparison fixture', true)
    d = @model.definitions.add('CJ_CPP_TEST_BLOCK')
    face = d.entities.add_face([[0,0,0],[10.m,0,0],[10.m,10.m,0],[0,10.m,0]])
    face.reverse! if face.normal.z < 0
    face.pushpull(30.m)
    1000.times { |i| @model.entities.add_instance(d, Geom::Transformation.translation([((i%40)-20)*15.m, ((i/40)-12)*15.m, 0])) }
    # A face with an actual inner loop, plus a hidden obstacle and nested transforms.
    g = @model.entities.add_group
    g.entities.add_face([500.m,0,0],[510.m,0,0],[510.m,0,10.m],[500.m,0,10.m])
    hole = g.entities.add_face([502.m,0,1.m],[508.m,0,1.m],[508.m,0,8.m],[502.m,0,8.m])
    hole.erase!
    nested = g.entities.add_group
    nested.entities.add_instance(d, Geom::Transformation.scaling(-0.5, 1.3, 0.8))
    nested.transformation = Geom::Transformation.translation([520.m,0,0])*Geom::Transformation.rotation(ORIGIN,Z_AXIS,37.degrees)
    hidden = @model.entities.add_instance(d,Geom::Transformation.translation([12.m,12.m,0]))
    hidden.hidden = true
    @model.commit_operation
    @points = 30.times.map { |i| Geom::Point3d.new((12.5+(i%6)*15).m,(12.5+(i/6)*15).m,1.5.m) }
    @points += [Geom::Point3d.new(505.m,-10.m,2.m), Geom::Point3d.new(501.m,-10.m,2.m)]
    @vectors = CJ::RayTubesUp.ray_vectors + [Y_AXIS, X_AXIS, Z_AXIS, Geom::Vector3d.new(0,-1,0)]
    before = clock
    @model.start_operation('CJ reference probe',true)
    begin
      @golden = CJ::RayTubesUp.without_results(@model) do
        @points.flat_map { |p| @vectors.map { |v| hit=CJ::RayTubesUp.raycast_world(@model,p,v);hit ? hit[1] : -1.0 } }
      end
    ensure
      @model.abort_operation
    end
    @reference_ms=(clock-before)*1000
    @started=clock
    @triangles=CJ::NativeEngine.write_input(File.join(@directory,'input.bin'),@model,@points,@vectors)
    @export_ms=(clock-@started)*1000
    @pid=Process.spawn(CJ::NativeEngine.executable,File.join(@directory,'input.bin'),File.join(@directory,'output.bin'),err:File.join(@directory,'error.txt'))
    UI.start_timer(0.02,false) { poll }
    :scheduled
  end
  def poll
    done=Process.waitpid2(@pid,Process::WNOHANG)
    unless done
      UI.start_timer(0.02,false) { poll };return
    end
    raise File.read(File.join(@directory,'error.txt')) unless done[1].success?
    native_ms=(clock-@started)*1000
    bytes=File.binread(File.join(@directory,'output.bin'))
    actual=bytes.byteslice(16..-1).unpack('E*')
    failures=[]
    @golden.zip(actual).each_with_index do |(expected,value),i|
      failures << {ray:i,expected:expected,actual:value} unless value && (expected<0)==(value<0) && (expected-value).abs<1e-5
    end
    @report={passed:failures.empty?,rays:@golden.length,triangles:@triangles, mismatches:failures.first(10), mismatch_count:failures.length,
             sketchup_ms:@reference_ms,cpp_including_export_ms:native_ms,export_ms:@export_ms,
             scope:'1000 blocks, hidden instance, nested rotation/mirror/nonuniform scale, face with hole; all original directions plus axis probes. Excludes result drawing.'}
    finish
  rescue StandardError => error
    @report={passed:false,error:error.message,trace:error.backtrace.first(5)}
    finish
  end
  def finish
    @model.start_operation('CJ comparison cleanup',true)
    @model.entities.clear!
    @model.commit_operation
    FileUtils.remove_entry(@directory)
    File.write(File.expand_path('../reports/cpp_check.json',__dir__),JSON.pretty_generate(@report))
    @report
  end
end
