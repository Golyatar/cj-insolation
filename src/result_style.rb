# frozen_string_literal: true
module CJ
  module ResultStyle
    extend self
    NAMES = {green: 'Зелёные лучи и сегменты', red: 'Красные лучи и сегменты', spheres: 'Сферы', windows: 'Плоскости окон', labels: 'Подписи'}.freeze
    def tags(model)
      folder = model.layers.folders.find { |f| f.name == 'Инсоляция' } || model.layers.add_folder('Инсоляция')
      NAMES.transform_values do |name|
        layer = model.layers["CJ · #{name}"] || model.layers.add("CJ · #{name}")
        folder.add_layer(layer)
        layer
      end
    end
    def radius
      Sketchup.read_default('CJ_ResultStyle', 'radius_mm', 100.0).to_f
    end
    def show
      return @dialog.bring_to_front if @dialog && @dialog.visible?
      @dialog = UI::HtmlDialog.new(dialog_title: 'CJ — оформление', width: 430, height: 340, resizable: true)
      @dialog.set_html(<<~HTML)
        <!doctype html><meta charset="utf-8"><style>body{font:14px 'Segoe UI';padding:24px;background:#f3f6fa;color:#192e43}h2{font-size:22px}p{line-height:1.6;color:#617287}input{font:inherit;padding:10px;border:1px solid #c9d5e1;border-radius:8px;width:100px}button{background:#ffd36a;border:0;border-radius:8px;padding:12px 20px;cursor:pointer}#error{color:#c53939}</style>
        <h2>Маркеры результата</h2><label>Радиус сферы, мм <input id="radius" type="number" min="0" max="10000" value="#{radius}"></label><p>0 — без сфер. Применяется к следующим расчётам. Зелёный — проходит, красный — не проходит.</p><button onclick="sketchup.save(document.getElementById('radius').value)">Сохранить</button><p id="error" role="alert"></p>
      HTML
      @dialog.add_action_callback('save') do |_context, value|
        begin
          number = Float(value)
          raise ArgumentError unless number.finite? && number >= 0 && number <= 10000
          Sketchup.write_default('CJ_ResultStyle', 'radius_mm', number)
          @dialog.close
        rescue ArgumentError, TypeError
          @dialog.execute_script("document.getElementById('error').textContent='Введите число от 0 до 10000.'")
        end
      end
      @dialog.show
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
    unless const_defined?(:UI_INSTALLED, false)
      command = UI::Command.new('Оформление результатов') { CJ::ResultStyle.show }
      command.tooltip = 'Настроить радиус сфер результата'
      command.small_icon = File.join(__dir__, 'icons', 'settings.svg')
      command.large_icon = command.small_icon
      UI.toolbar('CJ').add_item(command)
      UI.menu('Plugins').add_submenu('CJ').add_item(command)
      UI_INSTALLED = true
    end
  end
end
