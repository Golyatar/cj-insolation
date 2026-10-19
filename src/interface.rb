# frozen_string_literal: true

module CJ
  module Interface
    extend self
    attr_reader :commands, :toolbar

    def install
      return if @toolbar
      # SketchUp cannot remove individual buttons from an existing toolbar.
      # Hide the previous development panel when reloading in the same session.
      UI.toolbar('CJ').hide if defined?(CJ::RAY_TUBES_UP_UI_LOADED)
      @toolbar = UI::Toolbar.new('CJ Инсоляция')
      menu = UI.menu('Plugins').add_submenu('CJ Инсоляция')
      @commands = {}
      entries = [
        [:pick, 'Инсоляция — выбрать точки', 'insolation.png', -> { RayTubesUp.activate_pick_tool }],
        [:settings, 'Настройки CJ', 'settings.svg', -> { Settings.show }],
        [:window_point, 'Инсоляция — точка по окну', 'window_point.svg', -> { WindowPlacement.activate }],
        [:insert, 'Вставить окно CJ', 'window_insert.svg', -> { WindowComponents.insert }],
        [:windows, 'Рассчитать окна CJ', 'windows_batch.svg', -> { WindowComponents.calculate }],
        [:select, 'Выделить точки CJ', 'point_select.svg', -> { SavedPoints.select_points }],
        [:recalculate, 'Пересчитать точки CJ', 'point_recalculate.svg', -> { SavedPoints.recalculate }],
        [:updates, 'Версия и обновления', 'updates.svg', -> { Updates.show }]
      ]
      entries.each do |id, name, icon, action|
        command = UI::Command.new(name, &action)
        command.tooltip = name
        command.status_bar_text = id == :select ? 'Выделить сохранённые точки; M — обычный инструмент перемещения SketchUp' : name
        command.small_icon = File.join(__dir__, 'icons', icon)
        command.large_icon = command.small_icon
        @commands[id] = command
        @toolbar.add_item(command)
        menu.add_item(command)
      end
      @toolbar.show
      UI.start_timer(15, false) do
        Updates.check(true) if Time.now.to_i - Sketchup.read_default('CJ_Updates', 'last_check', 0).to_i >= 86_400
      end
    end
  end
end

CJ::Interface.install
