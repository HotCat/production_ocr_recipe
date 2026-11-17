#pragma once

#include <open3d/geometry/PointCloud.h>
#include <CGAL/Simple_cartesian.h>
#include <CGAL/Alpha_shape_2.h>
#include <CGAL/Alpha_shape_vertex_base_2.h>
#include <CGAL/Alpha_shape_face_base_2.h>
#include <CGAL/Delaunay_triangulation_2.h>
#include <CGAL/Triangulation_data_structure_2.h>
#include <CGAL/Polygon_2.h>
#include <CGAL/Polygon_2_algorithms.h>

#include <Eigen/Dense>
#include <vector>
#include <list>
#include <map>
#include <cmath>
#include <limits>
#include <algorithm>

using Kernel      = CGAL::Simple_cartesian<double>;
using Point2      = Kernel::Point_2;
using Vb          = CGAL::Alpha_shape_vertex_base_2<Kernel>;
using Fb          = CGAL::Alpha_shape_face_base_2<Kernel>;
using Tds         = CGAL::Triangulation_data_structure_2<Vb, Fb>;
using Dt          = CGAL::Delaunay_triangulation_2<Kernel, Tds>;
using Alpha_shape = CGAL::Alpha_shape_2<Dt>;
using Polygon2    = CGAL::Polygon_2<Kernel>;
using Segment2    = Kernel::Segment_2;

class CircleFitting {
public:
    explicit CircleFitting(const open3d::geometry::PointCloud& pcd) {
        z_center_ = 0.0; z_extent_ = 0.0;
        center_ = {0.0, 0.0, 0.0};
        radius_ = 0.0;

        if (pcd.points_.empty()) return;

        double zmin = std::numeric_limits<double>::infinity();
        double zmax = -std::numeric_limits<double>::infinity();

        pts2d_.clear();
        for (const auto& p : pcd.points_) {
            pts2d_.emplace_back(p(0), p(1));
            zmin = std::min(zmin, p(2));
            zmax = std::max(zmax, p(2));
        }

        z_extent_ = zmax - zmin;
        z_center_ = 0.5 * (zmin + zmax);

        if (pts2d_.size() < 3) return;

        Alpha_shape A(pts2d_.begin(), pts2d_.end());
        Alpha_shape::Type_of_alpha alpha = A.find_alpha_solid();
        if (alpha == 0) {
            auto it = A.find_optimal_alpha(1);
            if (it != A.alpha_end() && *it > 0) alpha = *it;
        }
        if (alpha == 0) return;
        A.set_alpha(alpha);

        extract_all_cycles(A);
        select_largest_hole_cycle();
        if (!best_cycle_.empty()) {
            fit_circle_chernov();
        }
    }

    Eigen::Vector3d center() const { return center_; }
    double radius() const { return radius_; }

    bool is_valid() const { return radius_ > 0; }

private:
    std::vector<Point2> pts2d_;
    std::vector<std::vector<Point2>> all_cycles_;
    std::vector<Point2> best_cycle_;

    double z_center_, z_extent_;
    Eigen::Vector3d center_;
    double radius_;

    void extract_all_cycles(const Alpha_shape& A) {
        std::vector<Segment2> regular_segments;
        for (auto it = A.alpha_shape_edges_begin(); it != A.alpha_shape_edges_end(); ++it) {
            if (A.classify(*it) == Alpha_shape::REGULAR) {
                regular_segments.push_back(A.segment(*it));
            }
        }

        std::map<Point2, std::list<Point2>> adj_list;
        for (const auto& seg : regular_segments) {
            adj_list[seg.source()].push_back(seg.target());
            adj_list[seg.target()].push_back(seg.source());
        }

        for (const auto& seg_init : regular_segments) {
            Point2 start = seg_init.source();
            if (adj_list[start].empty()) continue;

            std::vector<Point2> cycle;
            Point2 curr = start;

            do {
                cycle.push_back(curr);
                auto& neighbors = adj_list[curr];
                if (neighbors.empty()) {
                    cycle.clear(); break;
                }
                Point2 next = neighbors.front();
                neighbors.pop_front();
                adj_list[next].remove(curr);
                curr = next;
            } while (curr != start && !cycle.empty());

            if (!cycle.empty() && curr == start && cycle.size() >= 3)
                all_cycles_.push_back(cycle);
        }
    }

    void select_largest_hole_cycle() {
        double min_area = 0.0;
        for (const auto& cycle : all_cycles_) {
            if (cycle.size() < 3) continue;
            Polygon2 poly(cycle.begin(), cycle.end());
            double area = CGAL::to_double(poly.area());
            if (area < min_area) {
                min_area = area;
                best_cycle_ = cycle;
            }
        }
    }

    void fit_circle_chernov() {
        int n = static_cast<int>(best_cycle_.size());
        if (n < 3) return;

        std::vector<double> X(n), Y(n);
        double meanX = 0, meanY = 0;
        for (int i = 0; i < n; ++i) {
            X[i] = CGAL::to_double(best_cycle_[i].x());
            Y[i] = CGAL::to_double(best_cycle_[i].y());
            meanX += X[i];
            meanY += Y[i];
        }
        meanX /= n; meanY /= n;

        double r0 = 0;
        for (int i = 0; i < n; ++i)
            r0 += std::hypot(X[i] - meanX, Y[i] - meanY);
        r0 /= n;

        // Algebraic circle fit (Kåsa-style)
        Eigen::MatrixXd A(n, 3);
        Eigen::VectorXd b(n);
        for (int i = 0; i < n; ++i) {
            A(i, 0) = X[i];
            A(i, 1) = Y[i];
            A(i, 2) = 1.0;
            b(i) = -(X[i]*X[i] + Y[i]*Y[i]);
        }

        Eigen::Vector3d sol = A.colPivHouseholderQr().solve(b);
        double D = sol(0), E = sol(1), F = sol(2);
        double cx = -0.5 * D;
        double cy = -0.5 * E;
        double rad2 = cx*cx + cy*cy - F;
        if (rad2 <= 0) return;

        center_ = Eigen::Vector3d(cx, cy, z_center_);
        radius_ = std::sqrt(rad2);
    }
};


