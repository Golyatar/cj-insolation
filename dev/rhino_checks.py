# -*- coding: utf-8 -*-
"""Run inside Rhino; headless fixtures never alter the active document."""
import os
import json
import time
import tempfile
import Rhino
import System
from System.Drawing import Color
import cj_insolation as cj
import engine_io


def run():
    current = Rhino.RhinoDoc.ActiveDoc
    before = (current.Objects.Count, current.Layers.Count, current.Modified)
    checks = []
    comparisons = 0
    max_error_mm = 0.0
    for units in (Rhino.UnitSystem.Millimeters, Rhino.UnitSystem.Meters, Rhino.UnitSystem.Inches):
        doc = Rhino.RhinoDoc.CreateHeadless(None)
        job = None
        try:
            doc.ModelUnitSystem = units
            scale = Rhino.RhinoMath.UnitScale(Rhino.UnitSystem.Millimeters,units)
            doc.ModelAbsoluteTolerance = 0.001*scale
            mesh = cj.G.Mesh()
            for x,y in ((-20000,-20000),(20000,-20000),(20000,20000),(-20000,20000)):
                mesh.Vertices.Add(x*scale,y*scale,0)
            mesh.Faces.AddFace(0,1,2,3)
            attrs = cj.D.ObjectAttributes()
            definition = doc.InstanceDefinitions.Add('CJ test roof','',cj.G.Point3d.Origin,[mesh],[attrs])
            inner = doc.Objects.AddInstanceObject(definition,cj.G.Transform.Identity)
            inner_obj = doc.Objects.FindId(inner)
            nested = doc.InstanceDefinitions.Add('CJ nested roof','',cj.G.Point3d.Origin,[inner_obj.Geometry],[attrs])
            doc.Objects.Delete(inner,True)
            transform = cj.G.Transform.Translation(700000*scale,300000*scale,1000*scale)*cj.G.Transform.Rotation(0.3,cj.G.Vector3d.ZAxis,cj.G.Point3d.Origin)*cj.G.Transform.Scale(cj.G.Plane.WorldXY,-1.5,1.2,1)
            doc.Objects.AddInstanceObject(nested,transform)
            origin = cj.G.Point3d(700000*scale,300000*scale,0)
            open_point = origin+cj.G.Vector3d(100000*scale,0,0)
            # Neither hidden layer ancestors nor hidden objects may cast shadows.
            index = cj.layer(doc,'CJ hidden::child',Color.Gray)
            parent = doc.Layers.FindId(doc.Layers[index].ParentLayerId)
            parent.IsVisible = False
            parent.CommitChanges()
            hidden_mesh = mesh.DuplicateMesh()
            hidden_mesh.Transform(cj.G.Transform.Translation(800000*scale,300000*scale,500*scale))
            attr = cj.D.ObjectAttributes()
            attr.LayerIndex = index
            doc.Objects.AddMesh(hidden_mesh,attr)
            attr2 = cj.D.ObjectAttributes()
            attr2.Mode = cj.D.ObjectMode.Hidden
            doc.Objects.AddMesh(hidden_mesh,attr2)
            doc.Objects.AddMesh(hidden_mesh,cj.attributes(0,'result','fixture'))
            ids = cj.add_points(doc,[origin,open_point])
            job = cj.Job(doc,list(zip(ids,[origin,open_point])))
            deadline = time.time()+30
            while job.tick(draw=False) != 'done':
                if time.time()>deadline:
                    raise ValueError('Test timed out')
                time.sleep(0.005)
            checks.append({'name':'nested_blocks_hidden_exclusions_'+str(units),'passed':job.export.triangles==2})
            flags = [engine_io.assess(row)['passed'] for row in job.distances]
            checks.append({'name':'known_shaded_and_open_points_'+str(units),'passed':flags==[False,True]})
            reference_mesh = mesh.DuplicateMesh()
            reference_mesh.Transform(transform)
            mismatches = 0
            for point,row in zip((origin,open_point),job.distances):
                for vector,actual in zip(job.vectors,row):
                    ray = cj.G.Ray3d(point,cj.G.Vector3d(*vector))
                    expected = cj.G.Intersect.Intersection.MeshRay(reference_mesh,ray)
                    comparisons += 1
                    if (expected < 0) != (actual is None):
                        mismatches += 1
                    elif actual is not None:
                        max_error_mm = max(max_error_mm,abs(expected-actual)/scale)
            checks.append({'name':'rhino_meshray_'+str(units),'passed':mismatches==0,'mismatches':mismatches})
            made = cj.draw_results(doc,list(zip(ids,[origin,open_point])),job.vectors,job.distances)
            counts = [len([obj for obj in cj.objects(doc) if obj.Attributes.GetUserString(cj.SOURCE)==str(guid)]) for guid in ids]
            checks.append({'name':'summary_spheres_and_labels_'+str(units),'passed':counts==[2,2]})
            cj.draw_results(doc,[(ids[0],origin)],job.vectors,[[None]*510])
            checks.append({'name':'partial_recalc_preserves_other_point_'+str(units),'passed':len([obj for obj in cj.objects(doc) if obj.Attributes.GetUserString(cj.SOURCE)==str(ids[1])])==2 and all(doc.Objects.FindId(guid) is not None for guid in ids)})
            result_obj = next(obj for obj in cj.objects(doc) if obj.Attributes.GetUserString(cj.SOURCE)==str(ids[0]))
            doc.Objects.Lock(result_obj.Id,True)
            refused = False
            try:
                cj.draw_results(doc,[(ids[0],origin)],job.vectors,[[None]*510])
            except ValueError:
                refused = True
            doc.Objects.Unlock(result_obj.Id,True)
            checks.append({'name':'locked_results_preserved_'+str(units),'passed':refused and doc.Objects.FindId(result_obj.Id) is not None})
            signature = cj.scene_signature(doc)
            extra = doc.Objects.AddMesh(mesh)
            checks.append({'name':'scene_change_detected_'+str(units),'passed':signature!=cj.scene_signature(doc)})
            doc.Objects.Delete(extra,True)
            # Cancellation disposes a suspended export and removes only its temp dir.
            cancelled = cj.Job(doc,list(zip(ids,[origin,open_point])))
            next(cancelled.iterator)
            folder = cancelled.directory
            cancelled.close()
            checks.append({'name':'cancel_removes_partial_export_'+str(units),'passed':not os.path.exists(folder)})
            if units == Rhino.UnitSystem.Millimeters:
                pipeline = cj.Job(doc,[(ids[0],origin)],mode='lines')
                try:
                    deadline = time.time()+20
                    while pipeline.tick() != 'done':
                        if time.time()>deadline:
                            raise ValueError('Full pipeline timed out')
                        time.sleep(0.005)
                    results_for_point = [obj for obj in cj.objects(doc) if obj.Attributes.GetUserString(cj.SOURCE)==str(ids[0])]
                    checks.append({'name':'full_job_draws_510_lines_sphere_and_label','passed':len(results_for_point)==512})
                finally:
                    pipeline.close()
                guarded = cj.Job(doc,[(ids[0],origin)])
                try:
                    extra = doc.Objects.AddMesh(mesh)
                    rejected = False
                    deadline = time.time()+20
                    while time.time()<deadline:
                        try:
                            if guarded.tick() == 'done':
                                break
                        except ValueError as error:
                            rejected = 'Visible geometry changed' in str(error)
                            break
                        time.sleep(0.005)
                    checks.append({'name':'changed_scene_does_not_replace_results','passed':rejected and len([obj for obj in cj.objects(doc) if obj.Attributes.GetUserString(cj.SOURCE)==str(ids[0])])==512})
                    doc.Objects.Delete(extra,True)
                finally:
                    guarded.close()
            mesh.Dispose()
            hidden_mesh.Dispose()
            reference_mesh.Dispose()
        finally:
            if job:
                job.close()
            doc.Dispose()
    # Exercise trimmed Brep/NURBS meshing separately from the known planar mesh.
    doc = Rhino.RhinoDoc.CreateHeadless(None)
    try:
        doc.ModelUnitSystem = Rhino.UnitSystem.Millimeters
        doc.Objects.AddBrep(cj.G.Sphere(cj.G.Point3d(0,0,1000),200).ToBrep())
        folder = tempfile.mkdtemp(prefix='cj-rhino-brep-')
        export = cj.Exporter(doc,[cj.G.Point3d.Origin],[(0,0,1)],os.path.join(folder,'input.bin'))
        try:
            meshing_started = time.time()
            for _ in export.run():
                pass
            checks.append({'name':'nurbs_brep_meshing','passed':export.triangles>20,'seconds':time.time()-meshing_started,'triangles':export.triangles,'tolerance_mm':1.0})
        finally:
            export.close()
            cj.shutil.rmtree(folder)
    finally:
        doc.Dispose()
    checks.append({'name':'active_document_unchanged','passed':before==(current.Objects.Count,current.Layers.Count,current.Modified) and Rhino.RhinoDoc.ActiveDoc.RuntimeSerialNumber==current.RuntimeSerialNumber})
    checks.append({'name':'distance_precision','passed':max_error_mm<0.01})
    report = {'passed':all(item['passed'] for item in checks),'comparisons':comparisons,'max_error_mm':max_error_mm,'checks':checks}
    path = os.path.join(os.path.dirname(__file__),'..','reports','rhino_check.json')
    with open(path,'w') as target:
        json.dump(report,target,indent=2)
    return report


def run_async():
    import Eto.Forms as F
    global _timer
    _timer = F.UITimer(Interval=0.1)
    def execute(sender,args):
        _timer.Stop()
        try:
            run()
        except Exception as error:
            import traceback
            path = os.path.join(os.path.dirname(__file__),'..','reports','rhino_check.json')
            with open(path,'w') as target:
                json.dump({'passed':False,'error':str(error),'traceback':traceback.format_exc()},target,indent=2)
    _timer.Elapsed += execute
    _timer.Start()
    return 'scheduled'
