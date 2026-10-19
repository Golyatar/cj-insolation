# frozen_string_literal: true
module CJ
  module WindowGeometry
    extend self
    def plan_intersection(inner_left, inner_right, outer_left, outer_right)
      a, b = inner_left, outer_right
      c, d = inner_right, outer_left
      ux, uy = b.x-a.x, b.y-a.y
      vx, vy = d.x-c.x, d.y-c.y
      det = ux*vy-uy*vx
      raise 'Граничные линии параллельны или вырождены.' if det.abs < 1e-10
      t = ((c.x-a.x)*vy-(c.y-a.y)*vx)/det
      Geom::Point3d.new(a.x+t*ux, a.y+t*uy, a.z)
    end

    def height_point(plan, left, right, upper)
      n = (right-left).cross(upper-left)
      raise 'Плоскость затенения вырождена или параллельна Z.' if n.length < 1e-10 || n.z.abs < n.length*1e-8
      z = left.z - (n.x*(plan.x-left.x) + n.y*(plan.y-left.y))/n.z
      Geom::Point3d.new(plan.x, plan.y, z)
    end

  end
end
