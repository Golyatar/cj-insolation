# frozen_string_literal: true
module CJ
  module WindowComponents
    extend self
    DICT = 'CJ_Window' unless const_defined?(:DICT, false)
    DEFAULTS = [1300.0, 1400.0, 300.0, 150.0, 70.0, 60.0].freeze unless const_defined?(:DEFAULTS, false)

    def validate(values)
      raise 'Ожидаются шесть положительных размеров в мм.' unless values.is_a?(Array) && values.length==6 && values.all? { |v| v.is_a?(Numeric) && v.finite? && v>0 }
      w,h,wall,rear,depth,rim=values
      raise 'Рама слишком широкая для окна.' unless rim*2<[w,h].min
      raise 'Внутренняя линия окна должна находиться внутри стены, а глубина рамы не превышать посадку.' unless depth<=rear && rear<=wall
    end

    def local_point(values)
      validate(values)
      w,h,_wall,rear,_depth,rim=values.map(&:mm)
      left=Geom::Point3d.new(rim,rear,rim);right=Geom::Point3d.new(w-rim,rear,rim)
      plan=WindowPlacement.plan_intersection(left,right,Geom::Point3d.new(0,0,rim),Geom::Point3d.new(w,0,rim))
      p=WindowPlacement.height_point(plan,left,right,Geom::Point3d.new(0,0,h))
      # Component XY is the facade plane; positive Z faces outside.
      Geom::Point3d.new(p.x,p.z,-p.y)
    end

    def rectangle(entities,x0,y0,x1,y1,z)
      entities.add_face([x0,y0,z],[x1,y0,z],[x1,y1,z],[x0,y1,z])
    end

    def definition(model, values=DEFAULTS)
      validate(values)
      existing=model.definitions.find { |d| d.get_attribute(DICT,'version')==1 && d.get_attribute(DICT,'parameters_mm')==values }
      return existing if existing
      w,h,wall,rear,depth,rim=values.map(&:mm)
      d=model.definitions.add("CJ Окно #{values[0].round}×#{values[1].round} · посадка #{values[3].round}")
      e=d.entities
      front=-(rear-depth)
      ring=rectangle(e,0,0,w,h,front)
      hole=rectangle(e,rim,rim,w-rim,h-rim,front)
      hole.erase!
      ring.pushpull(-depth)
      bar=rectangle(e,w/2-rim/2,rim,w/2+rim/2,h-rim,front)
      bar.pushpull(-depth)
      corners=[[0,0],[w,0],[w,h],[0,h]]
      corners.each_with_index do |a,i|
        b=corners[(i+1)%4]
        e.add_face([a[0],a[1],0],[b[0],b[1],0],[b[0],b[1],-wall],[a[0],a[1],-wall])
      end
      material=model.materials['CJ_Window_Frame'] || model.materials.add('CJ_Window_Frame')
      material.color=Sketchup::Color.new(225,230,237)
      e.grep(Sketchup::Face).each { |f| f.material=material;f.back_material=material }
      point=local_point(values)
      d.set_attribute(DICT,'version',1)
      d.set_attribute(DICT,'parameters_mm',values)
      d.set_attribute(DICT,'point_mm',point.to_a.map(&:to_mm))
      d.set_attribute(DICT,'size_source','https://oknardia.ru/catalog/standard_opening/')
      d.behavior.is2d=true
      d.behavior.snapto=SnapTo_Vertical
      d.behavior.cuts_opening=true
      d
    end

    def remove_old_markers(model)
      markers=model.definitions.flat_map do |d|
        next [] unless d.get_attribute(DICT,'version')==1
        raw=d.get_attribute(DICT,'point_mm')
        next [] unless raw.is_a?(Array) && raw.length==3
        p=Geom::Point3d.new(raw.map(&:mm))
        d.entities.grep(Sketchup::ConstructionPoint).select { |e| e.position.distance(p).to_f<0.1.mm.to_f }
      end
      return 0 if markers.empty?
      model.start_operation('CJ: убрать маркеры окон',true)
      begin
        markers.each(&:erase!);model.commit_operation
      rescue StandardError
        model.abort_operation;raise
      end
      markers.length
    end

    def collect(model)
      windows=[];skipped=[]
      visit=lambda do |entities,transform,path,ancestors|
        entities.each do |e|
          next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
          next if e.hidden? || !e.layer.visible? || e.get_attribute('CJ_Insolation','result',false)
          tr=transform*e.transformation;ids=path+[e.persistent_id]
          d=e.definition
          if d.get_attribute(DICT,'version')==1
            raw=d.get_attribute(DICT,'point_mm')
            params = d.get_attribute(DICT, 'parameters_mm')
            begin
              validate(params)
            rescue StandardError
              skipped << ids
              next
            end
            up=Geom::Vector3d.new(0,1,0).transform(tr)
            valid=raw.is_a?(Array) && raw.length==3 && raw.all? { |x| x.is_a?(Numeric) && x.finite? } && up.length>1e-8 && up.normalize.dot(Z_AXIS)>0.999
            if valid
              w,h,_wall,rear,depth,rim = params.map(&:mm)
              z = -(rear-depth) + 0.5.mm
              plane = [[rim,rim,z],[w-rim,rim,z],[w-rim,h-rim,z],[rim,h-rim,z]].map { |p| Geom::Point3d.new(p).transform(tr) }
              windows << { origin:Geom::Point3d.new(raw.map(&:mm)).transform(tr),path_ids:ids,definition:d.name,window_plane:plane }
            else
              skipped << ids
            end
          elsif !ancestors.include?(d)
            visit.call(d.entities,tr,ids,ancestors+[d])
          end
        end
      end
      visit.call(model.entities,Geom::Transformation.new,[],[])
      { windows:windows,skipped:skipped }
    end

    def insert
      model=Sketchup.active_model
      raise 'Выйдите из редактирования группы перед вставкой.' if model.active_path
      remove_old_markers(model)
      place(model, CJ::Settings.values['window'])
    rescue StandardError=>e
      UI.messagebox(e.message)
    end

    def place(model, values)
      model.start_operation('CJ: компонент окна',true)
      begin
        d=definition(model,values)
        model.commit_operation
      rescue StandardError
        model.abort_operation;raise
      end
      model.place_component(d,true)
      Sketchup.set_status_text('Разместите окна на наружных вертикальных гранях; Esc — закончить. Затем «Рассчитать окна CJ».')
    end

    def calculate
      model=Sketchup.active_model
      raise 'Выйдите из редактирования группы перед расчётом.' if model.active_path
      remove_old_markers(model)
      entries=collect(model)
      raise 'Нет видимых вертикальных окон CJ. Сначала вставьте компонент кнопкой «Вставить окно CJ».' if entries[:windows].empty?
      message="Найдено окон CJ: #{entries[:windows].length}.\nТочки заданы параметрами компонента; соседние выступы будут затенять лучи, но не перемещают эти точки."
      message+="\nПропущено наклонённых или повреждённых окон: #{entries[:skipped].length}." unless entries[:skipped].empty?
      RayTubesUp.activate_pick_tool(entries[:windows].map { |e| e[:origin] },model,message,window_planes:entries[:windows].map { |e| e[:window_plane] })
    rescue StandardError=>e
      UI.messagebox(e.message)
    end

  end
end
