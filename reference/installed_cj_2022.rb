# frozen_string_literal: true
# cj_ray_tubes_up.rb — raytest first, build later (prevents self-intersection with previously drawn tubes)

require 'sketchup.rb'

module CJ
  module RayTubesUp
    extend self

    PLUGIN_MENU = 'CJ'.freeze
    CMD_NAME = 'Test_v0'.freeze

    # --- Defaults (adapt as needed) ---
    DEFAULT_RADIUS_MM = 25.0
    DEFAULT_MAX_LEN_M = 10.0
    DEFAULT_TAG_NAME  = 'RAYS'.freeze
    CIRCLE_SEGMENTS   = 24

    RAY_COUNT = 100
    STEP_DEG  = 1.0

    def log(msg)
      puts("[CJ::RayTubesUp] #{msg}")
    end

    def ensure_tag(model, name)
      return nil if name.nil? || name.strip.empty?
      tags = model.layers # UI: Tags, API: Layers
      tag = tags[name]
      tag ||= tags.add(name)
      tag
    end

    # Returns [hit_point(Geom::Point3d), distance(Float)] or nil
    def raycast_world(model, origin, dir)
      d = dir.clone
      d.normalize!
      ray = [origin, d]
      hit = model.raytest(ray, true) # true: include hidden + nested geometry
      return nil unless hit
      hit_pt = hit[0]
      [hit_pt, origin.distance(hit_pt)]
    end

    # Build tube inside a group so we can safely tag/color it
    def add_tube_group(entities, origin, dir, length, radius, color, tag: nil, name: nil)
      return nil if length <= 0.0

      grp = entities.add_group
      grp.name = name if name

      ge = grp.entities

      d = dir.clone
      d.normalize!
      end_pt = origin.offset(d, length)
      path_edge = ge.add_line(origin, end_pt)

      circle_edges = ge.add_circle(origin, d, radius, CIRCLE_SEGMENTS)
      face = ge.add_face(circle_edges.map { |e| e.start.position })
      face.reverse! if face.normal.dot(d) < 0
      face.followme(path_edge)

      path_edge.erase! rescue nil
      face.erase! rescue nil

      mat = Sketchup.active_model.materials.add("CJ_RayTube_#{Time.now.to_i}_#{rand(1_000_000)}")
      mat.color = color
      grp.material = mat
      grp.layer = tag if tag

      grp
    end

    def run
      model = Sketchup.active_model
      origin = Geom::Point3d.new(0, 0, 0)

      radius = DEFAULT_RADIUS_MM.mm
      maxlen = (DEFAULT_MAX_LEN_M * 1000.0).mm # meters -> mm -> internal units

      tag = ensure_tag(model, DEFAULT_TAG_NAME)

      # ---------- Phase 1: raytest ONLY (no geometry creation) ----------
      log("Raytest phase (no drawing)...")
      results = [] # [{i:, ang_deg:, dir:, hit_dist: Float or nil, hit_pt: Point3d or nil}]

      RAY_COUNT.times do |i|
        ang_deg = i * STEP_DEG
        ang_rad = ang_deg.degrees
        dir = Geom::Vector3d.new(Math.cos(ang_rad), 0.0, Math.sin(ang_rad)) # XZ fan upward

        hit = raycast_world(model, origin, dir)

        if hit
          hit_pt, dist = hit
          log("  Ray##{i} #{ang_deg}deg HIT dist=#{dist}")
          results << { i: i, ang_deg: ang_deg, dir: dir, hit_dist: dist, hit_pt: hit_pt }
        else
          log("  Ray##{i} #{ang_deg}deg CLEAR")
          results << { i: i, ang_deg: ang_deg, dir: dir, hit_dist: nil, hit_pt: nil }
        end
      end

      # ---------- Phase 2: build geometry ----------
      log("Build phase (drawing tubes)...")
      model.start_operation('CJ Инсоляция', true)

      results.each do |r|
        i       = r[:i]
        ang_deg = r[:ang_deg]
        dir     = r[:dir]

        if r[:hit_dist]
          dist = r[:hit_dist]
          add_tube_group(
            model.active_entities,
            origin, dir, dist, radius,
            Sketchup::Color.new(255, 0, 0),
            tag: tag,
            name: "Ray#{i}_HIT_#{ang_deg}deg"
          )
        else
          add_tube_group(
            model.active_entities,
            origin, dir, maxlen, radius,
            Sketchup::Color.new(0, 200, 0),
            tag: tag,
            name: "Ray#{i}_CLEAR_#{ang_deg}deg"
          )
        end
      end

      model.commit_operation
      model.active_view.invalidate
      log("Done.")
    rescue => e
      model.abort_operation rescue nil
      log("ERROR: #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}")
      raise
    end

    unless file_loaded?(__FILE__)
      UI.menu('Plugins').add_submenu(PLUGIN_MENU).add_item(CMD_NAME) { run }
      file_loaded(__FILE__)
    end
  end
end