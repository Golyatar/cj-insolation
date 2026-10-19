# frozen_string_literal: true
require 'json'

module CJ
  module WindowPlacement
    extend self
    Z = Geom::Vector3d.new(0, 0, 1) unless const_defined?(:Z, false)

    def faces(model)
      result = []
      walk = lambda do |entities, transform, ancestors|
        entities.each do |e|
          next if e.hidden? || !e.layer.visible?
          if e.is_a?(Sketchup::Face)
            result << descriptor(e, transform)
            raise 'Слишком много граней: выберите модель поменьше для первого режима.' if result.length > 10000
          elsif e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
            next if e.get_attribute('CJ_Insolation', 'result', false)
            next if ancestors.include?(e.definition)
            walk.call(e.definition.entities, transform * e.transformation, ancestors + [e.definition])
          end
        end
      end
      walk.call(model.entities, Geom::Transformation.new, [])
      result
    end

    def descriptor(face, transform)
      { id: face.persistent_id, loops: face.loops.map { |l| { outer: l.outer?, points: l.vertices.map { |v| v.position.transform(transform) } } } }
    end

    def basis(points)
      normal = nil
      points.drop(2).each do |p|
        n = (points[1] - points[0]).cross(p - points[0])
        if n.length > 1e-8
          normal = n.normalize
          break
        end
      end
      raise 'Не удалось определить плоскость.' unless normal
      normal
    end

    def aperture(face, clicked = nil)
      loops = face[:loops].reject { |l| l[:outer] }
      loops = face[:loops] if loops.empty?
      loop = clicked ? loops.min_by { |l| center(l[:points]).distance(clicked) } : loops.first
      pts = loop[:points]
      n = basis(pts)
      raise 'Выберите вертикальную грань окна или рамы.' if n.z.abs > 0.01
      u = Z.cross(n).normalize
      u.reverse! if u.x < -1e-6 || (u.x.abs < 1e-6 && u.y < 0)
      h = pts.map { |p| p.to_a.zip(u.to_a).sum { |a, b| a * b } }
      min_h, max_h = h.minmax
      min_z, max_z = pts.map(&:z).minmax
      raise 'Контур окна вырожден.' if max_h-min_h<0.1.mm || max_z-min_z<0.1.mm
      raise 'Нужен прямоугольный контур окна.' unless pts.all? { |p| v = p.to_a.zip(u.to_a).sum { |a, b| a * b }; [(v-min_h).abs, (v-max_h).abs].min < 0.1.mm || [(p.z-min_z).abs, (p.z-max_z).abs].min < 0.1.mm }
      base = pts.first
      left = base.offset(u, min_h - base.to_a.zip(u.to_a).sum { |a,b| a*b }); left.z = min_z
      right = left.offset(u, max_h-min_h)
      { left: left, right: right, top: max_z, width: max_h-min_h, normal: n, u: u, points: pts }
    end

    def center(points)
      Geom::Point3d.new(3.times.map { |i| points.sum { |p| p[i] } / points.length })
    end

    def plan_intersection(inner_left, inner_right, outer_left, outer_right)
      a, b = inner_left, outer_right
      c, d = inner_right, outer_left
      ux, uy = b.x-a.x, b.y-a.y
      vx, vy = d.x-c.x, d.y-c.y
      det = ux*vy-uy*vx
      raise 'Граничные линии параллельны или вырождены.' if det.abs < 1e-10
      t = ((c.x-a.x)*vy-(c.y-a.y)*vx)/det
      Geom::Point3d.new(a.x+t*ux, a.y+t*uy, a.z)
    end

    def height_point(plan, left, right, upper)
      n = (right-left).cross(upper-left)
      raise 'Плоскость затенения вырождена или параллельна Z.' if n.length < 1e-10 || n.z.abs < n.length*1e-8
      z = left.z - (n.x*(plan.x-left.x) + n.y*(plan.y-left.y))/n.z
      Geom::Point3d.new(plan.x, plan.y, z)
    end

    def slice(face, z)
      face[:loops].flat_map do |l|
        pts = l[:points]
        pts.each_with_index.flat_map do |a, i|
          b = pts[(i+1)%pts.length]
          if (a.z-z).abs < 0.01.mm && (b.z-z).abs < 0.01.mm
            [a,b]
          elsif (a.z-z)*(b.z-z) <= 0 && (a.z-b.z).abs > 1e-8
            t = (z-a.z)/(b.z-a.z)
            [Geom::Point3d.new(a.x+t*(b.x-a.x), a.y+t*(b.y-a.y), z)]
          else
            []
          end
        end
      end
    end

    def propose(window_face, wall_face, all_faces, clicked = nil)
      w = aperture(window_face, clicked)
      holes = wall_face[:loops].reject { |l| l[:outer] }
      raise 'В выбранной грани стены нет отверстия. Выберите наружную стену вокруг проёма.' if holes.empty?
      wall_loop = holes.min_by { |l| center(l[:points]).distance(center(w[:points])) }
      wall = aperture({ loops: [wall_loop] })
      raise 'Плоскости окна и стены должны быть параллельны.' if w[:normal].dot(wall[:normal]).abs < 0.99
      raise 'Проём стены не соответствует выбранному окну.' unless (w[:left]-wall[:left]).dot(w[:u]) >= -0.5.mm && (wall[:right]-w[:right]).dot(w[:u]) >= -0.5.mm && wall[:top] >= w[:top]-0.5.mm && wall[:left].z <= w[:left].z+0.5.mm
      delta = center(wall[:points])-center(w[:points]); delta.z=0
      out = wall[:normal].clone
      out.reverse! if out.dot(delta)<0
      raise 'Стена и окно в одной плоскости: укажите внутреннюю линию окна.' if delta.dot(out).abs < 0.1.mm
      # Prefer the rear frame contour with matching aperture dimensions.
      matches = all_faces.filter_map do |f|
        begin
          pts=f[:loops].flat_map { |l| l[:points] }
          next unless basis(f[:loops].first[:points]).dot(w[:normal]).abs>0.99
          offset=(pts.first-w[:left]).dot(w[:normal])
          shift=Geom::Vector3d.new(0,0,0)
          if offset.abs>=1e-8
            shift=w[:normal].clone;shift.length=offset.abs
            shift.reverse! if offset<0
          end
          corners=[w[:left],w[:right]].flat_map { |p| q=p.clone;q.z=w[:top];[p,q] }.map { |p| p+shift }
          next unless corners.all? { |p| pts.any? { |v| p.distance(v)<0.5.mm } }
          a=w.merge(left:w[:left]+shift,right:w[:right]+shift,points:w[:points].map { |p| p+shift })
          displacement=a[:left]-w[:left]
          next unless displacement.length<150.mm && displacement.dot(w[:u]).abs<0.5.mm
          a
        rescue StandardError
          nil
        end
      end
      w = ([w]+matches).min_by { |a| (a[:left]-wall[:left]).dot(out) }
      mid = center([w[:left],w[:right]])
      limits=[wall[:left].clone,wall[:right].clone]
      limits.each { |p| p.z=w[:left].z }
      candidates=all_faces.flat_map { |f| slice(f,w[:left].z) }.select do |p|
        d=p-mid
        (p-wall[:left]).dot(out)>0.1.mm && d.dot(out)>0 && d.dot(out)<w[:width]*10 && d.dot(w[:u]).abs<w[:width]*5
      end
      2.times do |side|
        origin=side==0 ? w[:right] : w[:left]
        options=candidates.select { |p| side==0 ? (p-w[:left]).dot(w[:u])<0 : (p-w[:right]).dot(w[:u])>0 }
        limits[side]=([limits[side]]+options).min_by { |p| ((p-origin).dot(w[:u])).abs / [(p-origin).dot(out),0.01.mm].max }
      end
      upper=wall[:left].clone; upper.z=wall[:top]
      roof=all_faces.select do |f|
        p=f[:loops].first[:points]
        next false unless basis(p).z.abs>0.99 && p.first.z>w[:top]+0.1.mm && p.first.z<w[:top]+w[:width]*20
        plane=p.first.z
        sample=Geom::Point3d.new(mid.x,mid.y,plane)
        # Convex horizontal slab faces; holes and concave slabs need manual selection.
        next false unless f[:loops].length==1
        sides=p.each_with_index.map { |a,i| (p[(i+1)%p.length]-a).cross(sample-a).z }
        (sides.all? { |s| s>=-1e-6 } || sides.all? { |s| s<=1e-6 }) && p.any? { |q| (q-wall[:left]).dot(out)>0.1.mm }
      end.min_by { |f| f[:loops].first[:points].first.z }
      upper=roof[:loops].first[:points].max_by { |p| (p-mid).dot(out) } if roof
      { window: w, limits: limits, upper: upper, shade: roof ? 'нижний край верхнего выступа' : 'верх наружного проёма', out: out }
    end

    class Tool
      def initialize
        @model=Sketchup.active_model; @points=[]; @ip=Sketchup::InputPoint.new
      end
      def valid_model!
        raise 'Вернитесь в исходную модель и выйдите из редактирования группы.' unless Sketchup.active_model.equal?(@model) && !@model.active_path
      end
      def activate
        valid_model!
        @state=:window
        @dialog=UI::HtmlDialog.new(dialog_title:'CJ — точка по окну',width:430,height:570,preferences_key:'CJ_WindowPoint_v1',resizable:true,scrollable:true)
        @dialog.set_html(<<~HTML)
          <!doctype html><meta charset="utf-8"><style>body{font:14px 'Segoe UI';padding:18px;background:#f5f6f8;color:#202832}button{display:block;width:100%;padding:10px;margin:8px 0;border:1px solid #bdc8d5;border-radius:6px;background:white;cursor:pointer}#status{white-space:pre-wrap;line-height:1.5}small{color:#526171}</style>
          <h2>Расчётная точка по окну</h2><p id="status">Выберите грань рамы с отверстием или стекло.</p>
          <button onclick="sketchup.action('window')">1. Указать окно / внутренний контур</button>
          <button onclick="sketchup.action('wall')">2. Указать наружную стену вокруг проёма</button>
          <small>Голубой — окно, зелёный — границы в плане, фиолетовый — плоскость, красный — расчётная точка.</small>
          <button onclick="sketchup.action('left')">Уточнить левую границу: выбрать вершину</button>
          <button onclick="sketchup.action('right')">Уточнить правую границу: выбрать вершину</button>
          <button onclick="sketchup.action('shade')">Уточнить верхний выступ: выбрать горизонтальное ребро</button>
          <button onclick="sketchup.action('add')">Добавить предложенную точку</button>
          <button onclick="sketchup.action('run')">Рассчитать добавленные точки</button>
          <small>Распознавание — предложение. Проверьте подсветку и положение точки перед добавлением. Esc — отменить текущий инструмент.</small>
        HTML
        @dialog.add_action_callback('action') do |_context,action|
          begin
            valid_model!
            case action
            when 'window' then @window=nil;@proposal=nil;@state=:window
            when 'wall' then raise('Сначала укажите окно.') unless @window;@state=:wall
            when 'left','right','shade' then raise('Сначала укажите окно и стену.') unless @proposal;@state=action.to_sym
            when 'add'
              raise('Нет предложенной точки.') unless @proposal
              @points << calculation.clone unless @points.any? { |p| p.distance(calculation)<0.1.mm }
              @proposal=nil;@window=nil;@state=:window
            when 'run'
              raise('Добавьте хотя бы одну точку.') if @points.empty?
              points=@points.map(&:clone);@model.select_tool(nil)
              CJ::RayTubesUp.activate_pick_tool(points,@model)
              next
            end
            update
          rescue StandardError=>e
            message(e.message)
          end
        end
        @dialog.set_on_closed { @model.select_tool(nil) unless @closing }
        @dialog.show
        update
      rescue StandardError=>e
        UI.messagebox(e.message);@model.select_tool(nil)
      end
      def calculation
        w=@proposal[:window]
        plan=WindowPlacement.plan_intersection(w[:left],w[:right],*@proposal[:limits])
        WindowPlacement.height_point(plan,w[:left],w[:right],@proposal[:upper])
      end
      def message(text)
        @dialog.execute_script("document.getElementById('status').textContent=#{JSON.generate(text)}") if @dialog
      end
      def update
        text={window:'Выберите грань рамы с отверстием или стекло.',wall:'Выберите наружную грань стены вокруг этого проёма.',left:'Укажите левую ограничивающую вершину выступа.',right:'Укажите правую ограничивающую вершину выступа.',shade:'Выберите наружное горизонтальное ребро верхнего выступа.',preview:'Проверьте границы и расчётную точку.'}[@state]
        if @proposal
          p=calculation
          text+="\nZ модели: #{p.z.to_mm.round(1)} мм.\nПлоскость: #{@proposal[:shade]}."
        end
        text+="\nДобавлено точек: #{@points.length}"
        message(text);Sketchup.set_status_text(text.lines.first);@model.active_view.invalidate
      end
      def onMouseMove(_flags,x,y,view)
        @ip.pick(view,x,y);view.invalidate
      end
      def onLButtonDown(_flags,x,y,view)
        valid_model!
        @ip.pick(view,x,y)
        helper=view.pick_helper;helper.do_pick(x,y)
        path=helper.path_at(0) || [];entity=path.last;transform=helper.transformation_at(0) || Geom::Transformation.new
        if @state==:window || @state==:wall
          raise 'Нажмите на грань, а не на ребро.' unless entity.is_a?(Sketchup::Face)
          f=WindowPlacement.descriptor(entity,transform)
          if @state==:window
            WindowPlacement.aperture(f,@ip.position);@window=f;@clicked=@ip.position.clone;@state=:wall
          else
            @proposal=WindowPlacement.propose(@window,f,WindowPlacement.faces(@model),@clicked);@state=:preview
          end
        elsif [:left,:right].include?(@state)
          raise 'Укажите вершину.' unless @ip.valid? && @ip.vertex
          p=@ip.position.clone;p.z=@proposal[:window][:left].z
          @proposal[:limits][@state==:left ? 0 : 1]=p;@state=:preview
        elsif @state==:shade
          raise 'Выберите горизонтальное ребро.' unless entity.is_a?(Sketchup::Edge)
          pts=entity.vertices.map { |v| v.position.transform(transform) }
          w=@proposal[:window];direction=pts[1]-pts[0]
          raise 'Ребро должно быть горизонтальным и параллельным нижнему краю окна.' if direction.z.abs>0.1.mm || direction.length<0.1.mm || direction.normalize.dot(w[:u]).abs<0.99
          @proposal[:upper]=WindowPlacement.center(pts);@proposal[:shade]='выбранное ребро';@state=:preview
        end
        update
      rescue StandardError=>e
        message(e.message)
      end
      def draw(view)
        @ip.draw(view) if @ip.valid?
        view.draw_points(@points,8,1,'red') unless @points.empty?
        if @window
          w=WindowPlacement.aperture(@window,@clicked);view.drawing_color='cyan';view.line_width=3
          view.draw(GL_LINE_LOOP,w[:points])
        end
        return unless @proposal
        w=@proposal[:window];p=calculation;plan=Geom::Point3d.new(p.x,p.y,w[:left].z)
        view.drawing_color='green';view.line_width=2
        view.draw(GL_LINES,[w[:left],@proposal[:limits][1],w[:right],@proposal[:limits][0]])
        view.draw_text(view.screen_coords(@proposal[:limits][0]),'Левая граница')
        view.draw_text(view.screen_coords(@proposal[:limits][1]),'Правая граница')
        view.drawing_color='purple'
        upper=@proposal[:upper]
        a=upper.offset(w[:u],(w[:left]-upper).dot(w[:u]))
        b=upper.offset(w[:u],(w[:right]-upper).dot(w[:u]))
        view.draw(GL_LINE_LOOP,[w[:left],w[:right],b,a])
        view.draw(GL_LINES,[plan,p]);view.draw_points([p],12,1,'red')
      rescue StandardError
        nil
      end
      def getExtents
        box=Geom::BoundingBox.new;box.add(@points) unless @points.empty?
        if @proposal
          box.add(calculation,@proposal[:upper],*@proposal[:limits],@proposal[:window][:left],@proposal[:window][:right])
        end
        box
      end
      def onCancel(_reason,view)
        view.model.select_tool(nil)
      end
      def deactivate(view)
        @closing=true
        @dialog.close if @dialog;@dialog=nil;view.invalidate
      end
    end

    def activate
      raise 'Выйдите из редактирования группы перед выбором окна.' if Sketchup.active_model.active_path
      Sketchup.active_model.select_tool(Tool.new)
    rescue StandardError=>e
      UI.messagebox(e.message)
    end
  end
end
