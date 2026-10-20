# -*- coding: utf-8 -*-
"""Asynchronous, read-only check of the visible meshes in the active document."""
import os
import json
import time
import Rhino
import System
import Eto.Forms as F
import cj_insolation as cj

timer = None
job = None


def start():
    global timer, job, before, reference, origins, started
    doc = Rhino.RhinoDoc.ActiveDoc
    before = (doc.Objects.Count, doc.Layers.Count, doc.Modified)
    candidates = [obj for obj in cj.objects(doc) if cj.visible(doc,obj) and isinstance(obj.Geometry,cj.G.Mesh) and not obj.Attributes.GetUserString(cj.ROLE)]
    if len(candidates) != 1:
        raise ValueError('This read-only fixture expects one visible mesh')
    reference = candidates[0].Geometry
    box = reference.GetBoundingBox(True)
    mm = Rhino.RhinoMath.UnitScale(Rhino.UnitSystem.Millimeters,doc.ModelUnitSystem)
    origins = [box.Center+cj.G.Vector3d(0,0,1000*mm),box.Center-cj.G.Vector3d(0,0,1000*mm),box.Max+cj.G.Vector3d(10000*mm,0,1000*mm)]
    job = cj.Job(doc,[(System.Guid.NewGuid(),point) for point in origins])
    started = time.time()
    timer = F.UITimer(Interval=0.03)
    timer.Elapsed += tick
    timer.Start()
    return 'scheduled'


def tick(sender, args):
    global job
    path = os.path.join(os.path.dirname(__file__),'..','reports','rhino_model_check.json')
    try:
        if Rhino.RhinoDoc.ActiveDoc.RuntimeSerialNumber != job.doc.RuntimeSerialNumber:
            raise ValueError('Active document changed')
        if time.time()-started > 90:
            raise ValueError('Read-only test timed out')
        if job.tick(draw=False) != 'done':
            return
        timer.Stop()
        mismatch = 0
        maximum = 0
        for origin,row in zip(origins,job.distances):
            for direction,actual in zip(job.vectors,row):
                expected = cj.G.Intersect.Intersection.MeshRay(reference,cj.G.Ray3d(origin,cj.G.Vector3d(*direction)))
                if (expected<0) != (actual is None):
                    mismatch += 1
                elif actual is not None:
                    maximum = max(maximum,abs(actual-expected))
        error_mm = maximum*Rhino.RhinoMath.UnitScale(job.doc.ModelUnitSystem,Rhino.UnitSystem.Millimeters)
        preserved = before == (job.doc.Objects.Count,job.doc.Layers.Count,job.doc.Modified)
        report = {'passed':mismatch==0 and error_mm<0.01 and preserved,'rays':len(origins)*len(job.vectors),'mismatches':mismatch,
                  'max_error_mm':error_mm,'triangles':job.export.triangles,'export_seconds':job.export_seconds,'total_seconds':job.seconds,
                  'active_document_unchanged':preserved,'scope':'Visible planar mesh only; virtual points; no results added'}
        with open(path,'w') as target:
            json.dump(report,target,indent=2)
    except Exception as error:
        timer.Stop()
        if job:
            job.close()
        with open(path,'w') as target:
            json.dump({'passed':False,'error':str(error)},target,indent=2)
