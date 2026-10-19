# frozen_string_literal: true
require 'json'

# Independent SketchUp Point3d#transform is the reference for the numeric path.
module CJCoordinateTransformChecks
  extend self
  def run
    random = Random.new(5183)
    coordinates = 100.times.flat_map { 3.times.map { random.rand(-10000.0..10000.0) } }
    transforms = [Geom::Transformation.new, Geom::Transformation.translation([1e6,-2e6,7e5]),
                  Geom::Transformation.scaling(-1,2,0.1), Geom::Transformation.scaling(0,1,1),
                  Geom::Transformation.new([1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,2])]
    50.times do
      translation = Geom::Transformation.translation(3.times.map { random.rand(-1e6..1e6) })
      rotation = Geom::Transformation.rotation(ORIGIN, Geom::Vector3d.new(1,2,3), random.rand(-Math::PI..Math::PI))
      scale = Geom::Transformation.scaling(random.rand(-3.0..3.0),random.rand(0.1..4.0),random.rand(0.1..2.0))
      transforms << translation * rotation * scale
      transforms << translation * Geom::Transformation.rotation(ORIGIN, Z_AXIS, random.rand(-Math::PI..Math::PI)) * scale
    end
    maximum = 0.0
    failures = []
    transforms.each_with_index do |transform, index|
      expected = coordinates.each_slice(3).flat_map { |p| Geom::Point3d.new(p).transform(transform).to_a }
      actual = CJ::NativeEngine.transform_coordinates(coordinates, transform.to_a)
      error = expected.zip(actual).map { |a,b| (a-b).abs }.max
      maximum = [maximum,error].max
      failures << index if error > 1e-7
    end
    report = {passed: failures.empty?, transforms: transforms.length, vertices: coordinates.length/3,
              max_error_mm: maximum.to_mm, failures: failures}
    File.write(File.expand_path('../reports/coordinate_transform_check.json', __dir__), JSON.pretty_generate(report))
    report
  end
end
