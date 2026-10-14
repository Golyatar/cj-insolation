# frozen_string_literal: true

# Coordinates in millimeters. Instance paths distinguish repeated definitions.
module CJModelCapture
  def self.point(point, transform)
    point.transform(transform).to_a.map(&:to_mm)
  end

  def self.record(entity, transform, path)
    info = CJBridge.entity_info(entity).merge(path_ids: path)
    if entity.respond_to?(:bounds) && !entity.bounds.empty?
      corners = 8.times.map { |i| point(entity.bounds.corner(i), transform) }
      info[:bounds_mm] = { min: 3.times.map { |i| corners.map { |p| p[i] }.min },
                           max: 3.times.map { |i| corners.map { |p| p[i] }.max } }
    end
    if entity.is_a?(Sketchup::Text)
      info[:text] = entity.text
      info[:attachment_point_mm] = point(entity.point, transform) if entity.respond_to?(:point)
    elsif entity.is_a?(Sketchup::Edge)
      info[:endpoints_mm] = entity.vertices.map { |v| point(v.position, transform) }
    elsif entity.is_a?(Sketchup::Face)
      info[:loops_mm] = entity.loops.map { |loop| { outer: loop.outer?, vertices: loop.vertices.map { |v| point(v.position, transform) } } }
      info[:back_material] = entity.back_material&.name
    elsif entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
      matrix = (transform * entity.transformation).to_a
      (12..14).each { |i| matrix[i] = matrix[i].to_mm }
      info[:world_transform_mm] = matrix
      info[:definition_name] = entity.definition.name
    end
    info
  end

  def self.run(command, args, model, directory)
    stamp = SecureRandom.uuid
    if command == 'view'
      path = File.join(directory, "view-#{stamp}.png")
      ok = model.active_view.write_image(filename: path, width: 1200, height: 900, antialias: true)
      raise 'View image export failed' unless ok
      return { path: path, model_token: model.object_id.to_s }
    elsif command == 'export'
      format = args.fetch('format', 'dae')
      raise ArgumentError, 'Use dae or obj' unless %w[dae obj].include?(format)
      path = File.join(directory, "model-#{stamp}.#{format}")
      raise 'Model export failed or format unavailable' unless model.export(path, false)
      return { path: path, model_token: model.object_id.to_s }
    end
    limit = Integer(args.fetch('limit', 5000))
    depth_limit = Integer(args.fetch('depth', 8))
    raise ArgumentError, 'Invalid snapshot limits' unless (1..10000).cover?(limit) && (0..32).cover?(depth_limit)
    selection_only = args.fetch('selection_only', false)
    records = []
    omitted = false
    visit = lambda do |entities, transform, parents, depth, definitions|
      entities.each do |entity|
        if records.length >= limit
          omitted = true
          break
        end
        path = parents + [entity.persistent_id]
        records << record(entity, transform, path)
        if entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
          definition = entity.definition
          if depth >= depth_limit || definitions.include?(definition.persistent_id)
            omitted = true unless definition.entities.empty?
          else
            visit.call(definition.entities, transform * entity.transformation, path, depth + 1, definitions + [definition.persistent_id])
          end
        end
      end
    end
    roots = selection_only ? model.selection.to_a : model.entities.to_a
    transform = selection_only ? model.edit_transform : Geom::Transformation.new
    parents = selection_only ? (model.active_path || []).map(&:persistent_id) : []
    visit.call(roots, transform, parents, 0, [])
    summary = { root_count: roots.length, counts: records.group_by { |r| r[:type] }.transform_values(&:length),
                truncated: omitted, selection_only: selection_only }
    data = { version: 1, units: 'mm', model_token: model.object_id.to_s, title: model.title,
             model_path: model.path, captured_at: Time.now.utc.iso8601, summary: summary, entities: records }
    path = File.join(directory, "snapshot-#{stamp}.json")
    CJBridge.write_json(path, data)
    { path: path, model_token: data[:model_token], summary: summary,
      root_entities: records.select { |r| r[:path_ids].length == parents.length + 1 }.first(100),
      entities: args.fetch('include_geometry', false) ? records : nil }
  end
end
