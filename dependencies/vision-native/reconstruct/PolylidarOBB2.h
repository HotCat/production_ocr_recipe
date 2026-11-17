// PolylidarOBB.h
#pragma once

#include <vector>
#include <tuple>
#include <limits>
#include <cmath>
#include <iostream>                    // for debug prints

// Open3D
#include <open3d/geometry/PointCloud.h>

// Polylidar3D
#include "Polylidar/Polylidar.hpp"

// CGAL
#include <CGAL/Simple_cartesian.h>
#include <CGAL/convex_hull_2.h>
#include <CGAL/min_quadrilateral_2.h>

// Eigen
#include <Eigen/Dense>

using K  = CGAL::Simple_cartesian<double>;
using P2 = K::Point_2;

#ifndef DEBUG
#define DEBUG 1
#endif

#define DLOG(x) do { if (DEBUG) std::cerr << x << std::endl; } while(0)

class PolylidarOBB {
public:
    explicit PolylidarOBB(const open3d::geometry::PointCloud& cloud) {
        DLOG("[OBB] Constructor from Open3D cloud, size=" << cloud.points_.size());
        std::vector<Eigen::Vector3d> pts(cloud.points_.begin(), cloud.points_.end());
        compute_(pts);
    }

    explicit PolylidarOBB(const std::vector<Eigen::Vector3d>& pts3d) {
        DLOG("[OBB] Constructor from vector<Eigen::Vector3d>, size=" << pts3d.size());
        compute_(pts3d);
    }

    double angle()  const { return angle_deg_; }
    Eigen::Vector3d center() const { return {cx_, cy_, cz_}; }
    Eigen::Vector3d extent() const { return {ext_x_, ext_y_, ext_z_}; }

private:
    double cx_{0}, cy_{0}, cz_{0};
    double ext_x_{0}, ext_y_{0}, ext_z_{0};
    double angle_deg_{0};

    void compute_(const std::vector<Eigen::Vector3d>& pts3d) {
        DLOG("[OBB] compute_() start");

        // 1) Flatten
        DLOG("[OBB] Flattening points");
        std::vector<double> data; data.reserve(pts3d.size()*3);
        for (size_t i = 0; i < pts3d.size(); ++i) {
            auto& p = pts3d[i];
            data.push_back(p.x());
            data.push_back(p.y());
            data.push_back(p.z());
        }
        DLOG("[OBB] Flattened to data.size()=" << data.size());

        // 2) Polylidar extraction
        DLOG("[OBB] Calling Polylidar3D::ExtractPlanesAndPolygons");
        Polylidar::Matrix<double> mat(data.data(), pts3d.size(), 3);
        /* Polylidar::Polylidar3D pl(0.0, 0.05, 50, 10); */


	Polylidar::Polylidar3D pl(
		/* alpha:          */ 0.0,           // unused for 3D extraction
		/* lmax:           */ 0.01,          // max edge length ≈ 3×avg_nn_dist (~0.003m)
		/* min_triangles:  */ 100,           // allow small plane patches
		/* min_hole_vertices: */ 20,         // holes must have ≥20 verts
		/* z_thresh:       */ 0.02,          // allow ≤2cm deviation from plane
		/* norm_thresh:    */ 0.2,           // accept normals within ±≈78°
		/* norm_thresh_min:*/ 0.05,          // minimum normal‐weight
		/* threads:        */ 4
		);



        Polylidar::MeshHelper::HalfEdgeTriangulation he_mesh;
        Polylidar::Planes   planes;
        Polylidar::Polygons polygons;
        std::tie(he_mesh, planes, polygons) = pl.ExtractPlanesAndPolygons(mat);
        DLOG("[OBB] Extracted " << planes.size() << " planes, " 
             << polygons.size() << " polygon groups");

        // 3) Largest hole
        DLOG("[OBB] Searching largest hole");
        double best_area = -1.0;
        std::vector<size_t> best_hole;
        for (size_t pi = 0; pi < polygons.size(); ++pi) {
            DLOG("  [OBB] Polygon group " << pi << ", shell size=" 
                 << polygons[pi].shell.size() << ", holes=" 
                 << polygons[pi].holes.size());
            for (size_t hi = 0; hi < polygons[pi].holes.size(); ++hi) {
                auto& hole = polygons[pi].holes[hi];
                DLOG("    [OBB] Hole " << hi << " size=" << hole.size());
                double area2d = 0.0;
                size_t n = hole.size();
                for (size_t i = 0; i < n; ++i) {
                    double Ax = he_mesh.vertices(hole[i],     0);
                    double Ay = he_mesh.vertices(hole[i],     1);
                    double Bx = he_mesh.vertices(hole[(i+1)%n], 0);
                    double By = he_mesh.vertices(hole[(i+1)%n], 1);
                    area2d += Ax*By - Bx*Ay;
                }
                area2d = std::abs(area2d)*0.5;
                DLOG("      [OBB] Computed hole area=" << area2d);
                if (area2d > best_area) {
                    best_area = area2d;
                    best_hole = hole;
                    DLOG("      [OBB] New best hole: area=" << best_area);
                }
            }
        }
        if (best_hole.empty()) {
            DLOG("[OBB] WARNING: no hole found! Using outer shell instead.");
            best_hole = polygons.empty()
                        ? std::vector<size_t>()
                        : polygons[0].shell;
        }
        DLOG("[OBB] Selected hole vertex count=" << best_hole.size());

        // 4) Project to 2D
        DLOG("[OBB] Projecting hole to 2D points");
        std::vector<P2> hole2d; hole2d.reserve(best_hole.size());
        for (size_t idx : best_hole) {
            double x = he_mesh.vertices(idx, 0);
            double y = he_mesh.vertices(idx, 1);
            hole2d.emplace_back(x,y);
        }
        DLOG("[OBB] hole2d.size()=" << hole2d.size());

        // 5) Convex hull + OBB
        DLOG("[OBB] Running CGAL::convex_hull_2");
        std::vector<P2> hull; hull.reserve(hole2d.size());
        CGAL::convex_hull_2(hole2d.begin(), hole2d.end(),
                           std::back_inserter(hull));
        DLOG("[OBB] Hull size=" << hull.size());

        DLOG("[OBB] Running CGAL::min_rectangle_2");
        std::vector<P2> rect; rect.reserve(4);
        CGAL::min_rectangle_2(hull.begin(), hull.end(),
                              std::back_inserter(rect));
        DLOG("[OBB] Rect corners=" << rect.size());
        for (size_t i = 0; i < rect.size(); ++i)
            DLOG("  corner["<<i<<"]="<<rect[i]);

        // 6) Compute centers & extents
        DLOG("[OBB] Computing centers & extents");
        double sx=0, sy=0, zmin=1e9, zmax=-1e9;
        for (auto& p : pts3d) {
            zmin = std::min(zmin, p.z());
            zmax = std::max(zmax, p.z());
        }
        for (auto& q : rect) { sx+=q.x(); sy+=q.y(); }
        cx_ = sx/rect.size(); cy_ = sy/rect.size();
        cz_ = 0.5*(zmin+zmax);
        ext_z_ = zmax - zmin;
        DLOG("[OBB] Center2D=("<<cx_<<","<<cy_<<"), cz="<<cz_<<", ext_z="<<ext_z_);

        // 7) Final angle & planar extents
        double dx = rect[1].x()-rect[0].x();
        double dy = rect[1].y()-rect[0].y();
        angle_deg_ = std::atan2(dy, dx)*180.0/M_PI;
        ext_x_     = std::hypot(dx, dy);
        ext_y_     = std::hypot(rect[2].x()-rect[1].x(),
                                rect[2].y()-rect[1].y());
        DLOG("[OBB] angle="<<angle_deg_<<"°, ext_xy=("<<ext_x_<<","<<ext_y_<<")");

        DLOG("[OBB] compute_() done");
    }
};
