# -*- coding: utf-8 -*-
"""Rhino 7/8 Windows adapter; no observers or dynamic recalculation."""
from __future__ import division
import os
import struct
import tempfile
import shutil
import time
import Rhino
import System
from System.Drawing import Color
from Rhino import Geometry as G
from Rhino import DocObjects as D
import engine_io

ROOT = os.path.dirname(os.path.abspath(__file__))
ROLE = 'CJ.Insolation.Role'
SOURCE = 'CJ.Insolation.Source'


def worker_path():
    packaged = os.path.join(ROOT, 'bin', 'cj_engine.exe')
    return engine_io.approved_worker(packaged if os.path.isfile(packaged) else os.path.join(ROOT, '..', 'native', 'stable', 'cj_engine.exe'))


def objects(doc):
    settings = D.ObjectEnumeratorSettings()
    settings.NormalObjects = True
    settings.LockedObjects = True
    settings.HiddenObjects = True
    settings.ReferenceObjects = True
    return list(doc.Objects.GetObjectList(settings))


def visible(doc, obj):
    if obj.IsHidden or obj.IsDeleted:
        return False
    layer = doc.Layers[obj.Attributes.LayerIndex]
    while layer:
        if not layer.IsVisible:
            return False
        if layer.ParentLayerId == System.Guid.Empty:
            break
        layer = doc.Layers.FindId(layer.ParentLayerId)
    return True


def saved_points(doc, selected_only=False):
    return [obj for obj in objects(doc) if isinstance(obj.Geometry, G.Point)
            and obj.Attributes.GetUserString(ROLE) == 'point' and visible(doc, obj)
            and not obj.IsLocked and (not selected_only or obj.IsSelected(False) != 0)]


def scene_signature(doc):
    """Check once at start/end; no document observers or automatic recalculation."""
    signature, visited = [], set()
    def visit(obj):
        if not visible(doc, obj) or obj.Attributes.GetUserString(ROLE) in ('point','result'):
            return
        key = str(obj.Id)
        if key in visited:
            return
        visited.add(key)
        signature.append((key, int(obj.Geometry.DataCRC(0))))
        if isinstance(obj,D.InstanceObject):
            for child in obj.InstanceDefinition.GetObjects():
                visit(child)
    for obj in objects(doc):
        if not obj.IsInstanceDefinitionGeometry:
            visit(obj)
    return str(doc.ModelUnitSystem), float(doc.ModelAbsoluteTolerance), tuple(sorted(signature))


def layer(doc, path, color):
    parent = System.Guid.Empty
    index = -1
    for name in path.split('::'):
        found = next((item for item in doc.Layers if not item.IsDeleted and item.Name == name and item.ParentLayerId == parent), None)
        if found:
            index, parent = found.Index, found.Id
        else:
            item = D.Layer()
            item.Name, item.ParentLayerId, item.Color = name, parent, color
            index = doc.Layers.Add(item)
            if index < 0:
                raise ValueError('Cannot create CJ layer')
            parent = doc.Layers[index].Id
    return index


def attributes(index, role, source=None):
    attr = D.ObjectAttributes()
    attr.LayerIndex = index
    attr.SetUserString(ROLE, role)
    if source:
        attr.SetUserString(SOURCE, str(source))
    return attr


def add_points(doc, points):
    record = doc.BeginUndoRecord(u'CJ: сохранить расчётные точки')
    created = []
    try:
        index = layer(doc, u'Инсоляция::Расчётные точки', Color.Orange)
        for point in points:
            guid = doc.Objects.AddPoint(point, attributes(index, 'point'))
            if guid == System.Guid.Empty:
                raise ValueError('Cannot add calculation point')
            created.append(guid)
        return created
    except Exception:
        for guid in created:
            doc.Objects.Delete(guid, True)
        raise
    finally:
        doc.EndUndoRecord(record)
        doc.Views.Redraw()


class Exporter(object):
    """Fresh snapshot; definition meshes reused only within this calculation."""
    def __init__(self, doc, origins, vectors, path, mesh_tolerance_mm=1.0):
        self.doc, self.origins, self.vectors, self.path = doc, origins, vectors, path
        self.scale = Rhino.RhinoMath.UnitScale(doc.ModelUnitSystem, Rhino.UnitSystem.Inches)
        if self.scale <= 0 or str(doc.ModelUnitSystem) in ('None', 'CustomUnits'):
            raise ValueError('Set standard model units before calculating')
        self.anchor = origins[0]
        self.triangles, self.processed, self.cache = 0, 0, {}
        self.file = None
        self.params = G.MeshingParameters.Default
        if mesh_tolerance_mm <= 0:
            raise ValueError('Mesh tolerance must be positive')
        self.params.Tolerance = max(doc.ModelAbsoluteTolerance, mesh_tolerance_mm*Rhino.RhinoMath.UnitScale(Rhino.UnitSystem.Millimeters, doc.ModelUnitSystem))
        self.params.RelativeTolerance = 0
        self.params.JaggedSeams = False
        self.total = 0

    def meshes(self, obj):
        key = str(obj.Id)
        if key in self.cache:
            return self.cache[key]
        geo = obj.Geometry
        if isinstance(geo, G.ClippingPlaneSurface):
            raise ValueError('Clipping planes are not supported in this prototype')
        if isinstance(geo, G.Mesh):
            result = [geo.DuplicateMesh()]
        elif isinstance(geo, G.Brep):
            result = list(G.Mesh.CreateFromBrep(geo, self.params) or [])
        elif isinstance(geo, G.Extrusion):
            brep = geo.ToBrep()
            try:
                result = list(G.Mesh.CreateFromBrep(brep, self.params) or [])
            finally:
                brep.Dispose()
        elif isinstance(geo, G.Surface):
            result = [G.Mesh.CreateFromSurface(geo, self.params)]
        elif isinstance(geo, (G.Point, G.Curve, G.AnnotationBase, G.TextDot, G.PointCloud)):
            result = []
        else:
            raise ValueError('Unsupported visible geometry: ' + str(geo.GetType().Name))
        if any(mesh is None or not mesh.IsValid for mesh in result):
            raise ValueError('Meshing failed for ' + str(obj.Id))
        if isinstance(geo, (G.Brep, G.Extrusion, G.Surface)) and not result:
            raise ValueError('Surface produced no mesh')
        self.cache[key] = result
        return result

    def walk(self, obj, transform, stack=()):
        if not visible(self.doc, obj) or obj.Attributes.GetUserString(ROLE) in ('point', 'result'):
            return
        if obj.IsInstanceDefinitionGeometry and not stack:
            return
        if isinstance(obj, D.InstanceObject):
            definition = obj.InstanceDefinition
            key = str(definition.Id)
            if key in stack:
                raise ValueError('Cyclic block definition')
            for child in definition.GetObjects():
                for mesh, xform in self.walk(child, transform*obj.InstanceXform, stack+(key,)):
                    yield mesh, xform
        else:
            for mesh in self.meshes(obj):
                yield mesh, transform

    def run(self):
        entries = [obj for obj in objects(self.doc) if not obj.IsInstanceDefinitionGeometry]
        self.total = len(entries)
        self.file = open(self.path, 'wb')
        try:
            self.file.write(b'CJIN0001'+struct.pack('<III', 0, len(self.origins), len(self.vectors)))
            for obj in entries:
                for mesh, transform in self.walk(obj, G.Transform.Identity):
                    mesh.Faces.ConvertQuadsToTriangles()
                    values = []
                    for face in mesh.Faces:
                        for index in (face.A, face.B, face.C):
                            point = mesh.Vertices.Point3dAt(index)
                            point.Transform(transform)
                            values.extend(((point.X-self.anchor.X)*self.scale, (point.Y-self.anchor.Y)*self.scale, (point.Z-self.anchor.Z)*self.scale))
                        self.triangles += 1
                        if self.triangles > 10000000:
                            raise ValueError('Worker limit: ten million triangles')
                        if len(values) >= 9216:
                            self.file.write(struct.pack('<%dd' % len(values), *values))
                            values = []
                            yield self.processed, self.total
                    if values:
                        self.file.write(struct.pack('<%dd' % len(values), *values))
                self.processed += 1
                yield self.processed, self.total
            for point in self.origins:
                self.file.write(struct.pack('<3d', (point.X-self.anchor.X)*self.scale, (point.Y-self.anchor.Y)*self.scale, (point.Z-self.anchor.Z)*self.scale))
            for vector in self.vectors:
                self.file.write(struct.pack('<3d', *vector))
            self.file.seek(8)
            self.file.write(struct.pack('<I', self.triangles))
        finally:
            self.close()

    def close(self):
        if self.file and not self.file.closed:
            self.file.close()
        for meshes in self.cache.values():
            for mesh in meshes:
                mesh.Dispose()
        self.cache.clear()


def draw_results(doc, entries, vectors, distances, mode='summary', radius_mm=100):
    if mode not in ('summary', 'lines'):
        raise ValueError('Unsupported display mode')
    source_ids = set(str(entry[0]) for entry in entries)
    old_objects = [obj for obj in objects(doc) if obj.Attributes.GetUserString(ROLE) == 'result' and obj.Attributes.GetUserString(SOURCE) in source_ids]
    for obj in old_objects:
        item = doc.Layers[obj.Attributes.LayerIndex]
        locked = obj.IsLocked or obj.IsReference
        while item:
            locked = locked or item.IsLocked
            if item.ParentLayerId == System.Guid.Empty:
                break
            item = doc.Layers.FindId(item.ParentLayerId)
        if locked:
            raise ValueError('Unlock previous CJ results before recalculating')
    old = [obj.Id for obj in old_objects]
    record = doc.BeginUndoRecord(u'CJ: результаты инсоляции')
    created = []
    mm = Rhino.RhinoMath.UnitScale(Rhino.UnitSystem.Millimeters, doc.ModelUnitSystem)
    def added(guid):
        if guid == System.Guid.Empty:
            raise ValueError('Cannot create result geometry')
        created.append(guid)
    try:
        sets = {}
        for passed in (True, False):
            prefix = u'Инсоляция::' + (u'Проходят' if passed else u'Не проходят') + '::'
            sets[passed] = {key: layer(doc, prefix+name, color) for key, name, color in (
                ('green', u'Зелёные лучи', Color.FromArgb(28,181,104)), ('red', u'Красные лучи', Color.FromArgb(228,68,68)),
                ('markers', u'Сферы', Color.FromArgb(28,181,104) if passed else Color.FromArgb(228,68,68)), ('labels', u'Подписи', Color.DimGray))}
        for (source, origin), row in zip(entries, distances):
            result = engine_io.assess(row)
            tags = sets[result['passed']]
            if radius_mm > 0:
                mesh = G.Mesh.CreateFromSphere(G.Sphere(origin, radius_mm*mm), 12, 8)
                try:
                    attr = attributes(tags['markers'], 'result', source)
                    attr.SetUserString('CJ.Insolation.Passed', str(result['passed']))
                    added(doc.Objects.AddMesh(mesh, attr))
                finally:
                    mesh.Dispose()
            text = u'Суммарно: %d мин; непрерывно: %d мин' % (result['total'], result['longest'])
            added(doc.Objects.AddTextDot(text, origin+G.Vector3d(0,0,200*mm), attributes(tags['labels'], 'result', source)))
            if mode == 'lines':
                for direction, distance in zip(vectors, row):
                    length = 1000000*mm if distance is None else distance
                    end = origin+G.Vector3d(*direction)*length
                    added(doc.Objects.AddLine(origin, end, attributes(tags['green' if distance is None else 'red'], 'result', source)))
        # All new geometry exists before old results are removed.
        for guid in old:
            doc.Objects.Delete(guid, True)
        return created
    except Exception:
        for guid in created:
            doc.Objects.Delete(guid, True)
        raise
    finally:
        doc.EndUndoRecord(record)
        doc.Views.Redraw()


class Job(object):
    def __init__(self, doc, entries, mode='summary', radius_mm=100, mesh_tolerance_mm=1.0):
        if not entries:
            raise ValueError('No calculation points')
        self.worker = worker_path()
        self.doc, self.entries, self.mode, self.radius = doc, entries, mode, radius_mm
        self.vectors = engine_io.directions(os.path.join(ROOT, 'sun_vectors.json'))
        self.signature = scene_signature(doc)
        self.directory = tempfile.mkdtemp(prefix='cj-rhino-')
        try:
            self.export = Exporter(doc, [p for _,p in entries], self.vectors, os.path.join(self.directory, 'input.bin'), mesh_tolerance_mm)
        except Exception:
            shutil.rmtree(self.directory)
            raise
        self.iterator = self.export.run()
        self.process = None
        self.phase, self.fraction = 'export', 0
        self.started = time.time()
        self.distances = None

    def tick(self, draw=True):
        if self.phase == 'export':
            deadline = time.time()+0.06
            while time.time() < deadline:
                try:
                    done, total = next(self.iterator)
                    self.fraction = int(100*done/max(1,total))
                except StopIteration:
                    engine_io.approved_worker(self.worker)  # Check the actual launch path again.
                    info = System.Diagnostics.ProcessStartInfo()
                    info.FileName = self.worker
                    info.Arguments = '"%s" "%s"' % (os.path.join(self.directory,'input.bin'),os.path.join(self.directory,'output.bin'))
                    info.UseShellExecute, info.CreateNoWindow = False, True
                    info.RedirectStandardError = True
                    self.process = System.Diagnostics.Process.Start(info)
                    self.phase = 'cpp'
                    self.export_seconds = time.time()-self.started
                    break
        elif self.phase == 'cpp' and self.process.HasExited:
            if self.process.ExitCode != 0:
                raise ValueError(self.process.StandardError.ReadToEnd())
            self.distances = engine_io.read_output(os.path.join(self.directory,'output.bin'), len(self.entries), len(self.vectors), 1/self.export.scale)
            if draw:
                if scene_signature(self.doc) != self.signature:
                    raise ValueError('Visible geometry changed; recalculate')
                for guid, original in self.entries:
                    obj = self.doc.Objects.FindId(guid)
                    if not obj or not isinstance(obj.Geometry, G.Point) or obj.Geometry.Location.DistanceTo(original) > self.doc.ModelAbsoluteTolerance:
                        raise ValueError('Calculation points changed; recalculate')
                draw_results(self.doc, self.entries, self.vectors, self.distances, self.mode, self.radius)
            self.phase = 'done'
            self.seconds = time.time()-self.started
            self.close()
        return self.phase

    def close(self):
        if self.process:
            if not self.process.HasExited:
                self.process.Kill()
                self.process.WaitForExit()
            self.process.Dispose()
            self.process = None
        self.iterator.close()
        self.export.close()
        if os.path.isdir(self.directory):
            shutil.rmtree(self.directory)
