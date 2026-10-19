# frozen_string_literal: true

module CJ
  module PointObservers
    extend self

    def snapshot(model)
      SavedPoints.all(model).to_h { |g| [SavedPoints.source_id(g), SavedPoints.origin(g).to_a] }
    end

    def watch(model)
      @watchers ||= {}
      @watchers[model] ||= begin
        observer = Watcher.new(model)
        model.add_observer(observer)
        observer
      end
    end

    def forget(model)
      observer = (@watchers || {}).delete(model)
      observer&.reset
    end

    def updating?
      !!@updating
    end

    def paused
      @pause_depth = (@pause_depth || 0) + 1
      yield
    ensure
      @pause_depth -= 1
      (@watchers || {}).each_value(&:refresh)
    end

    def paused?
      (@pause_depth || 0) > 0
    end

    # Timer callback, never edits the model from an observer callback.
    # Transparent operation joins the completed native Move for one-step Undo.
    def rebuild(model, entries)
      return if entries.empty?
      mode = Settings.mode
      ids = entries.map { |g| SavedPoints.source_id(g) }
      previous_batches = RayTubesUp.result_groups(model)
      states = RayTubesUp.raycast_exclusions(model).map { |g| [g, g.hidden?] }
      options = %w[EdgeColorMode DisplayColorByLayer MaterialTransparency].to_h { |key| [key, model.rendering_options[key]] }
      @updating = true
      model.start_operation('CJ: пересчитать перемещённые точки', true, false, true)
      begin
        states.each { |g, _| g.hidden = true }
        calculations = RayTubesUp.calculate_points(model, entries.map { |g| SavedPoints.origin(g) })
        calculations.each_with_index { |c, i| c[:source_id] = ids[i] }
        states.each { |g, hidden| g.hidden = hidden if g.valid? }
        batch = RayTubesUp.build_batch(model, calculations, mode: mode)
        SavedPoints.remove_results(model, ids, except: batch)
        model.rendering_options['EdgeColorMode'] = 0 if mode == :lines
        model.rendering_options['DisplayColorByLayer'] = false if mode == :lines
        model.rendering_options['MaterialTransparency'] = true if mode == :surface
        Sketchup.set_status_text("CJ: обновлено точек — #{entries.length}.")
      rescue StandardError => error
        # A transparent operation must never be aborted: that would undo Move.
        (RayTubesUp.result_groups(model) - previous_batches).each { |g| g.erase! if g.valid? }
        options.each { |key, value| model.rendering_options[key] = value }
        RayTubesUp.log("Автопересчёт: #{error.class}: #{error.message}")
        Sketchup.set_status_text('CJ: не удалось обновить результат. Нажмите «Пересчитать точки CJ».')
      ensure
        states.each { |g, hidden| g.hidden = hidden if g.valid? }
        model.commit_operation
        @updating = false
        watch(model).refresh
        model.active_view.invalidate
      end
    end

    class Watcher < Sketchup::ModelObserver
      def initialize(model)
        @model = model
        @pending = []
        refresh
      end

      def refresh
        @snapshot = PointObservers.snapshot(@model)
      end

      def reset
        UI.stop_timer(@timer) if @timer
        @timer = nil
        @pending = []
      end

      def onTransactionCommit(model)
        current = PointObservers.snapshot(model)
        changed = current.keys.select { |id| current[id] != @snapshot[id] }
        @snapshot = current
        return if PointObservers.updating? || PointObservers.paused? || !Settings.values['live']
        return if changed.empty?
        @pending |= changed
        schedule
      rescue StandardError => error
        RayTubesUp.log("Наблюдение за точками: #{error.message}")
      end

      def schedule
        UI.stop_timer(@timer) if @timer
        @timer = UI.start_timer(0.15, false) { flush }
      end

      def flush
        @timer = nil
        unless Sketchup.active_model.equal?(@model) && !@model.active_path && Settings.values['live']
          reset
          return
        end
        if SavedPoints.busy?
          schedule
          return
        end
        ids = @pending
        @pending = []
        # Explicit calculations may have already updated these points.
        result_origins = RayTubesUp.result_groups(@model).flat_map do |batch|
          batch.entities.grep(Sketchup::Group).map do |g|
            [g.get_attribute('CJ_Insolation', 'source_id'), g.get_attribute('CJ_Insolation', 'origin')]
          end
        end.to_h
        entries = SavedPoints.visible(@model).select do |g|
          id = SavedPoints.source_id(g)
          ids.include?(id) && result_origins[id] != SavedPoints.origin(g).to_a
        end
        PointObservers.rebuild(@model, entries)
      rescue StandardError => error
        RayTubesUp.log("Автопересчёт: #{error.message}")
      end

      def onTransactionUndo(_model)
        reset
        refresh
      end

      alias onTransactionRedo onTransactionUndo
      alias onTransactionAbort onTransactionUndo

      def onDeleteModel(model)
        PointObservers.forget(model)
      end
    end

    class ApplicationWatcher < Sketchup::AppObserver
      def onNewModel(model)
        PointObservers.watch(model)
      end

      alias onOpenModel onNewModel
    end

    unless @app_observer
      @app_observer = ApplicationWatcher.new
      Sketchup.add_observer(@app_observer)
    end
  end
end

CJ::PointObservers.watch(Sketchup.active_model)
