# frozen_string_literal: true
module CJ
  module ResultStyle
    extend self
    NAMES = {green: 'Зелёные лучи и сегменты', red: 'Красные лучи и сегменты', spheres: 'Сферы', windows: 'Плоскости окон', labels: 'Подписи'}.freeze
    def tags(model, passed: nil)
      folder = model.layers.folders.find { |f| f.name == 'Инсоляция' } || model.layers.add_folder('Инсоляция')
      category = passed.nil? ? nil : (passed ? 'Проходят' : 'Не проходят')
      folder = folder.folders.find { |f| f.name == category } || folder.add_folder(category) if category
      NAMES.transform_values do |name|
        full_name = ['CJ', category, name].compact.join(' · ')
        layer = model.layers[full_name]
        legacy = model.layers["CJ · #{name}"]
        if !layer && passed == true && legacy
          layer = legacy
          layer.name = full_name
        end
        unless layer
          layer = model.layers.add(full_name)
          reference = legacy || model.layers["CJ · Проходят · #{name}"]
          layer.visible = reference.visible? if category && reference
        end
        folder.add_layer(layer)
        layer
      end
    end

    # Reassign only our display tags; saved point handles and geometry stay intact.
    # Called within an undo operation. Existing results need no ray calculations.
    def organize_existing(model)
      sets = {true => tags(model, passed: true), false => tags(model, passed: false)}
      keys = {}
      NAMES.each do |key, name|
        ['CJ', 'CJ · Проходят', 'CJ · Не проходят'].each { |prefix| keys["#{prefix} · #{name}"] = key }
      end
      move = lambda do |entities, layers|
        entities.each do |entity|
          key = keys[entity.layer.name] if entity.respond_to?(:layer)
          entity.layer = layers[key] if key
          move.call(entity.entities, layers) if entity.is_a?(Sketchup::Group)
        end
      end
      model.entities.grep(Sketchup::Group).each do |batch|
        next unless batch.get_attribute('CJ_Insolation', 'result', false)
        batch.entities.grep(Sketchup::Group).each do |point|
          passed = point.get_attribute('CJ_Insolation', 'passed')
          move.call(point.entities, sets[passed]) if sets.key?(passed)
        end
      end
      sets
    end
    def radius
      Sketchup.read_default('CJ_ResultStyle', 'radius_mm', 100.0).to_f
    end
    def show
      CJ::Settings.show
    end
    def material(model, passed)
      name = passed ? 'CJ_Passed' : 'CJ_Failed'
      m = model.materials[name] || model.materials.add(name)
      m.color = passed ? [28, 181, 104] : [228, 68, 68]
      m.alpha = 1.0
      m
    end
    def marker(entities, calculation, passed, layers)
      plane = calculation[:window_plane]
      return if !plane && radius <= 0
      group = entities.add_group
      group.name = passed ? 'Инсоляция проходит' : 'Инсоляция не проходит'
      group.layer = layers[plane ? :windows : :spheres]
      group.set_attribute('CJ_Insolation', 'passed', passed)
      m = material(Sketchup.active_model, passed)
      if plane
        face = group.entities.add_face(plane)
        face.material = face.back_material = m if face
      else
        # Small shared definition: each point adds only an instance, not hundreds of faces.
        model = Sketchup.active_model
        name = passed ? 'CJ_ResultSphere_Pass_v1' : 'CJ_ResultSphere_Fail_v1'
        definition = model.definitions[name]
        unless definition
          definition = model.definitions.add(name)
          mesh = Geom::PolygonMesh.new
          rings = (1...8).map do |j|
            theta = Math::PI * j / 8
            (0...16).map { |i| a = 2 * Math::PI * i / 16; Geom::Point3d.new(Math.sin(theta)*Math.cos(a), Math.sin(theta)*Math.sin(a), Math.cos(theta)) }
          end
          16.times do |i|
            k = (i+1)%16
            mesh.add_polygon(Geom::Point3d.new(0,0,1), rings[0][i], rings[0][k])
            rings.each_cons(2) { |a,b| mesh.add_polygon(a[i], b[i], b[k], a[k]) }
            mesh.add_polygon(rings[-1][i], Geom::Point3d.new(0,0,-1), rings[-1][k])
          end
          definition.entities.add_faces_from_mesh(mesh, 0, m, m)
          definition.entities.grep(Sketchup::Edge).each { |edge| edge.soft = edge.smooth = true }
        end
        transform = Geom::Transformation.translation(calculation[:origin].to_a) * Geom::Transformation.scaling(radius.mm)
        group.entities.add_instance(definition, transform)
      end
      group
    end
  end
end
