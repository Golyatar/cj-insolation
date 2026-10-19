# frozen_string_literal: true
require 'securerandom'

module CJ
  module SavedPoints
    extend self
    DICT = 'CJ_CalculationPoint' unless const_defined?(:DICT, false)

    def busy?
      !!RayTubesUp.instance_variable_get(:@active_calculation)
    end

    def guard!(model)
      raise 'Вернитесь в исходную модель и выйдите из группы.' unless Sketchup.active_model.equal?(model) && !model.active_path
      raise 'Дождитесь окончания текущего расчёта.' if busy?
    end

    def all(model)
      model.entities.grep(Sketchup::Group).select { |g| g.get_attribute(DICT, 'id') }
    end

    def origin(group)
      Geom::Point3d.new(0, 0, 0).transform(group.transformation)
    end

    # Persistent IDs survive saving; native copies get a different ID automatically.
    def source_id(group)
      "point:#{group.persistent_id}"
    end

    def visible(model)
      all(model).select { |g| !g.hidden? && g.layer.visible? && !g.locked? }
    end

    def add(model, point)
      group = model.entities.add_group
      marker(group)
      group.transformation = Geom::Transformation.translation(point.to_a)
      group.name = 'Расчётная точка CJ'
      group.set_attribute(DICT, 'id', SecureRandom.uuid)
      group
    end

    def marker(group)
      return if group.get_attribute(DICT, 'marker_version') == 1
      group.make_unique
      group.entities.add_cpoint(ORIGIN) if group.entities.grep(Sketchup::ConstructionPoint).empty?
      [X_AXIS, Y_AXIS, Z_AXIS].each do |axis|
        edge = group.entities.add_line(ORIGIN.offset(axis, -75.mm), ORIGIN.offset(axis, 75.mm))
        edge.material = Sketchup::Color.new(255, 145, 20)
      end
      group.set_attribute(DICT, 'marker_version', 1)
    end

    def create_and_calculate(points, mode: Settings.mode)
      model = Sketchup.active_model
      guard!(model)
      model.start_operation('CJ: сохранить расчётные точки', true)
      begin
        entries = points.map do |point|
          all(model).find { |g| origin(g).distance(point) < 0.1.mm } || add(model, point)
        end.uniq
        model.commit_operation
      rescue StandardError
        model.abort_operation
        raise
      end
      calculate(entries, mode: mode)
    rescue StandardError => error
      UI.messagebox(error.message)
    end

    def calculate(entries, mode: Settings.mode)
      model = Sketchup.active_model
      guard!(model)
      raise 'Нет сохранённых расчётных точек.' if entries.empty?
      RayTubesUp.run_from_points(entries.map { |g| origin(g) }, mode: mode,
                                source_ids: entries.map { |g| source_id(g) })
    end

    def recalculate
      model = Sketchup.active_model
      guard!(model)
      selected = model.selection.to_a & visible(model)
      calculate(selected.empty? ? visible(model) : selected)
    rescue StandardError => error
      UI.messagebox(error.message)
    end

    def select_points
      model = Sketchup.active_model
      guard!(model)
      points = visible(model)
      raise 'Нет сохранённых расчётных точек.' if points.empty?
      if points.any? { |p| p.get_attribute(DICT, 'marker_version') != 1 }
        model.start_operation('CJ: показать маркеры точек', true)
        begin
          points.each { |p| marker(p) }
          model.commit_operation
        rescue StandardError
          model.abort_operation
          raise
        end
      end
      model.select_tool(nil)
      model.selection.clear
      model.selection.add(points)
      Sketchup.set_status_text('Выделены точки CJ. M — перемещение; Shift — изменить набор выделения.')
    rescue StandardError => error
      UI.messagebox(error.message)
    end

    # Compatibility for a button created by the earlier development version.
    def move
      model = Sketchup.active_model
      guard!(model)
      select_points if (model.selection.to_a & visible(model)).empty?
      Sketchup.send_action('selectMoveTool:') unless model.selection.empty?
    rescue StandardError => error
      UI.messagebox(error.message)
    end

    # Called inside the caller's undo operation, after calculation succeeds.
    def remove_results(model, ids, except: nil)
      RayTubesUp.result_groups(model).each do |batch|
        next if batch == except
        batch.entities.grep(Sketchup::Group).each do |group|
          group.erase! if ids.include?(group.get_attribute('CJ_Insolation', 'source_id'))
        end
        batch.erase! if batch.entities.length.zero?
      end
    end

  end
end
