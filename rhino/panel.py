# -*- coding: utf-8 -*-
import Rhino
import rhinoscriptsyntax as rs
import scriptcontext as sc
import Eto.Forms as F
import Eto.Drawing as E
import cj_insolation as cj
import time

KEY = 'CJ.Insolation.RhinoPanel'


class Panel(F.Form):
    def __init__(self):
        self.Title = u'CJ — Инсоляция · Rhino · прототип'
        self.ClientSize = E.Size(460, 390)
        self.Padding = E.Padding(16)
        self.Resizable = False
        self.job = None
        self.doc = Rhino.RhinoDoc.ActiveDoc
        self.doc_serial = self.doc.RuntimeSerialNumber
        self.status = F.Label(Text=u'Расставьте точки или выберите ранее сохранённые.')
        self.status.Wrap = F.WrapMode.Word
        self.progress = F.ProgressBar(MinValue=0, MaxValue=100, Value=0)
        self.mode = F.DropDown()
        self.mode.Items.Add(u'Итоги и сферы')
        self.mode.Items.Add(u'Линии, итоги и сферы')
        self.mode.SelectedIndex = 0
        self.radius = F.NumericStepper(MinValue=0, MaxValue=10000, Value=100, DecimalPlaces=0)
        self.tolerance = F.NumericStepper(MinValue=0.1, MaxValue=100, Value=1, DecimalPlaces=1)
        self.add = F.Button(Text=u'Расставить точки')
        self.select = F.Button(Text=u'Выделить точки')
        self.calculate = F.Button(Text=u'Пересчитать точки')
        self.cancel = F.Button(Text=u'Отменить расчёт', Enabled=False)
        self.add.Click += self.on_add
        self.select.Click += self.on_select
        self.calculate.Click += self.on_calculate
        self.cancel.Click += self.on_cancel
        layout = F.DynamicLayout(Spacing=E.Size(8,8))
        layout.AddRow(F.Label(Text=u'510 направлений · исходная методика SketchUp'))
        layout.AddRow(F.Label(Text=u'Оси модели: те же, что в SketchUp. Скрытое исключается.'))
        layout.AddRow(self.add, self.select)
        layout.AddRow(F.Label(Text=u'Вид результата'), self.mode)
        layout.AddRow(F.Label(Text=u'Радиус сферы, мм'), self.radius)
        layout.AddRow(F.Label(Text=u'Допуск сетки поверхностей, мм'), self.tolerance)
        layout.AddRow(self.calculate)
        layout.AddRow(self.progress)
        layout.AddRow(self.status)
        layout.AddRow(self.cancel)
        layout.AddRow(F.Label(Text=u'Выделенные точки → пересчёт выбранных. Иначе — всех видимых.'))
        self.Content = layout
        self.timer = F.UITimer(Interval=0.03)
        self.timer.Elapsed += self.on_tick
        self.Closed += self.on_closed

    def valid_doc(self):
        active = Rhino.RhinoDoc.ActiveDoc
        if not active or active.RuntimeSerialNumber != self.doc_serial:
            raise ValueError(u'Панель относится к другой модели. Откройте её заново.')

    def error(self, error):
        self.status.Text = u'Ошибка: '+unicode(error)
        Rhino.RhinoApp.WriteLine(self.status.Text)

    def on_add(self, sender, args):
        try:
            self.valid_doc()
            self.Visible = False
            points = rs.GetPoints(False, False, u'Первая расчётная точка', u'Следующая точка; Enter — закончить')
            if points:
                cj.add_points(self.doc, points)
                self.status.Text = u'Сохранено точек: %d. Можно перемещать обычным Move.' % len(points)
        except Exception as error:
            self.error(error)
        finally:
            self.Visible = True

    def on_select(self, sender, args):
        try:
            self.valid_doc()
            self.doc.Objects.UnselectAll()
            points = cj.saved_points(self.doc)
            for obj in points:
                obj.Select(True)
            self.doc.Views.Redraw()
            self.status.Text = u'Выделено точек: %d. Move — перемещение.' % len(points)
        except Exception as error:
            self.error(error)

    def on_calculate(self, sender, args):
        try:
            self.valid_doc()
            points = cj.saved_points(self.doc, True) or cj.saved_points(self.doc)
            entries = [(obj.Id, cj.G.Point3d(obj.Geometry.Location)) for obj in points]
            self.job = cj.Job(self.doc, entries, 'lines' if self.mode.SelectedIndex == 1 else 'summary', float(self.radius.Value), float(self.tolerance.Value))
            self.busy(True)
            self.status.Text = u'Подготовка видимой геометрии…'
            self.timer.Start()
        except Exception as error:
            self.error(error)

    def busy(self, value):
        for control in (self.add, self.select, self.calculate, self.mode, self.radius, self.tolerance):
            control.Enabled = not value
        self.cancel.Enabled = value
        if not value:
            self.progress.Indeterminate = False

    def on_tick(self, sender, args):
        try:
            self.valid_doc()
            phase = self.job.tick()
            elapsed = int(time.time()-self.job.started)
            if phase == 'export':
                self.progress.Indeterminate = False
                self.progress.Value = self.job.fraction
                self.status.Text = u'Подготовка: %d%% · %d треугольников · %d с' % (self.job.fraction,self.job.export.triangles,elapsed)
            elif phase == 'cpp':
                self.progress.Indeterminate = True
                self.status.Text = u'C++ расчёт · %d точек · %d с' % (len(self.job.entries),elapsed)
            elif phase == 'done':
                self.timer.Stop()
                self.busy(False)
                self.progress.Value = 100
                self.status.Text = u'Готово: %d точек · %.2f с' % (len(self.job.entries),self.job.seconds)
                self.job = None
        except Exception as error:
            self.on_cancel(None, None)
            self.error(error)

    def on_cancel(self, sender, args):
        self.timer.Stop()
        if self.job:
            self.job.close()
            self.job = None
        self.busy(False)
        self.status.Text = u'Расчёт отменён. Прежние результаты сохранены.'

    def on_closed(self, sender, args):
        self.on_cancel(None,None)
        if sc.sticky.get(KEY) is self:
            del sc.sticky[KEY]


def show():
    old = sc.sticky.get(KEY)
    if old:
        old.Close()
    panel = Panel()
    sc.sticky[KEY] = panel
    panel.Owner = Rhino.UI.RhinoEtoApp.MainWindow
    panel.Show()
    return panel
