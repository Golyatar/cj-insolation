# frozen_string_literal: true
module CJ
  # Each definition is triangulated once. Instances carry only a matrix;
  # coordinate transforms and triangle expansion run in the C++ worker.
  module SceneExport
    extend self
    attr_reader :last_stats

    def set_stats(stats)
      @last_stats = stats
    end

    def write(path, model, points, vectors)
      tags = model.layers.to_h do |tag|
        visible = tag.visible?
        folder = tag.folder
        while folder
          visible &&= folder.visible?
          folder = folder.folder
        end
        [tag.entityID, visible]
      end
      excluded = RayTubesUp.raycast_exclusions(model).to_h { |e| [e.entityID,true] }
      images = {}
      model.definitions.each { |d| d.instances.each { |e| images[e.entityID] = d } if d.image? }
      nodes = {}
      meshes = []
      mesh_sizes = []
      cuts = model.rendering_options['DisplaySectionCuts']
      read_node = nil
      read_node = lambda do |entities, key|
        return nodes[key] if nodes.key?(key)
        SceneCache.watch(model,entities)
        node = {mesh:nil,children:[]}
        nodes[key] = node
        patches = []
        count = 0
        entities.each do |e|
          instance = e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
          face = e.is_a?(Sketchup::Face)
          image = e.is_a?(Sketchup::Image)
          if cuts && e.is_a?(Sketchup::SectionPlane) && e.active?
            raise NativeEngine::Unsupported, 'активное сечение'
          end
          next unless instance || face || image
          next if excluded[e.entityID] || e.hidden? || !tags.fetch(e.layer.entityID,false)
          if face
            mesh = e.mesh(0)
            polygons = mesh.polygons
            raise NativeEngine::Unsupported, 'нетриангулированная поверхность' unless polygons.all? { |p| p.length==3 }
            vertices = mesh.points.flat_map(&:to_a)
            indices = polygons.flatten.map { |i| i.abs-1 }
            patches << [mesh.count_points,polygons.length].pack('L<2') + vertices.pack('E*') + indices.pack('L<*')
            count += polygons.length
          else
            next if e.get_attribute('CJ_Insolation','result',false)
            if instance && e.respond_to?(:glued_to) && e.glued_to && e.definition.behavior.cuts_opening?
              raise NativeEngine::Unsupported, 'приклеенный компонент, прорезающий проём'
            end
            definition = instance ? e.definition : images[e.entityID]
            raise NativeEngine::Unsupported, 'не найдена геометрия изображения' unless definition
            child = read_node.call(definition.entities,definition.entityID)
            node[:children] << [child,e.transformation]
          end
        end
        unless patches.empty?
          node[:mesh] = meshes.length
          meshes << [patches.length].pack('L<') + patches.join
          mesh_sizes << count
        end
        node
      end
      root = read_node.call(model.entities,:root)
      instances = []
      triangles = 0
      walk = nil
      walk = lambda do |node,transform|
        if node[:mesh]
          instances << [node[:mesh]].pack('L<') + transform.to_a.pack('E16')
          triangles += mesh_sizes[node[:mesh]]
        end
        node[:children].each { |child,tr| walk.call(child,transform*tr) }
      end
      walk.call(root,Geom::Transformation.new)
      File.open(path,'wb') do |file|
        file.write('CJIN0002'+[meshes.length,instances.length,points.length,vectors.length].pack('L<4'))
        meshes.each { |data| file.write(data) }
        instances.each { |data| file.write(data) }
        points.each { |p| file.write(p.to_a.pack('E3')) }
        vectors.each { |v| file.write(v.to_a.pack('E3')) }
      end
      @last_stats = {meshes:meshes.length,instances:instances.length,unique_triangles:mesh_sizes.sum,triangles:triangles,bytes:File.size(path),cache_hit:false}
      triangles
    end
  end
end
