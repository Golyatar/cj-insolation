# frozen_string_literal: true
module CJWindowChecks
  def self.run
    fixture=JSON.parse(File.read(File.join(__dir__,'window_examples.json'),encoding:'UTF-8'))
    faces=fixture['faces'].map { |e| { path:e['path_ids'], id:e['persistent_id'], loops:e['loops_mm'].map { |l| { outer:l['outer'], points:l['vertices'].map { |p| Geom::Point3d.new(p.map(&:mm)) } } } } }
    checks=[]
    [0,37].each do |angle|
      transform=Geom::Transformation.rotation(ORIGIN,Z_AXIS,angle.degrees)
      rotated=faces.map { |f| f.merge(loops:f[:loops].map { |l| l.merge(points:l[:points].map { |p| p.transform(transform) }) }) }
      fixture['tests'].each_with_index do |t,i|
        window=rotated.find { |f| f[:path]==t['window'] };wall=rotated.find { |f| f[:path]==t['wall'] }
        begin
          proposal=CJ::WindowPlacement.propose(window,wall,rotated)
          w=proposal[:window]
          plan=CJ::WindowPlacement.plan_intersection(w[:left],w[:right],*proposal[:limits])
          actual=CJ::WindowPlacement.height_point(plan,w[:left],w[:right],proposal[:upper])
          expected=Geom::Point3d.new(t['expected'].map(&:mm)).transform(transform)
          checks << { name:"window_example_#{i+1}_rotation_#{angle}",passed:actual.distance(expected)<0.1.mm,error_mm:actual.distance(expected).to_mm, actual_mm:actual.to_a.map(&:to_mm),shade:proposal[:shade] }
        rescue StandardError=>e
          checks << { name:"window_example_#{i+1}_rotation_#{angle}",passed:false,error:"#{e.class}: #{e.message}",trace:e.backtrace.first(3) }
        end
      end
    end
    checks
  end
end
