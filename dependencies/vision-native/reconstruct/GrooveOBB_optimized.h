// File: GrooveOBB_optimized.h

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
#include <CGAL/convex_hull_2.h>
#include <CGAL/min_quadrilateral_2.h>
#include <CGAL/Exact_predicates_inexact_constructions_kernel.h>

#include <Eigen/Dense>
#include <vector>
#include <limits>
#include <cmath>
#include <unordered_map>
#include <unordered_set>
#include <algorithm>

// Custom hash for CGAL Point_2
namespace std {
    template<>
    struct hash<CGAL::Simple_cartesian<double>::Point_2> {
        size_t operator()(const CGAL::Simple_cartesian<double>::Point_2& p) const {
            auto h1 = std::hash<double>{}(CGAL::to_double(p.x()));
            auto h2 = std::hash<double>{}(CGAL::to_double(p.y()));
            return h1 ^ (h2 << 1);
        }
    };
}

// CGAL kernel and types
using Kernel        = CGAL::Simple_cartesian<double>;
using Point2        = Kernel::Point_2;
using Vb            = CGAL::Alpha_shape_vertex_base_2<Kernel>;
using Fb            = CGAL::Alpha_shape_face_base_2<Kernel>;
using Tds           = CGAL::Triangulation_data_structure_2<Vb, Fb>;
using Dt            = CGAL::Delaunay_triangulation_2<Kernel, Tds>;
using Alpha_shape   = CGAL::Alpha_shape_2<Dt>;
using Polygon2      = CGAL::Polygon_2<Kernel>;
using Segment2      = Kernel::Segment_2;
using FT            = Kernel::FT;

class GrooveOBB {
public:
    explicit GrooveOBB(const open3d::geometry::PointCloud& pcd) {
        // Initialize members
        z_center_ = 0.0; z_extent_ = 0.0;
        cx_ = 0.0; cy_ = 0.0;
        dx_ = 0.0; dy_ = 0.0;
        angle_rad_ = 0.0;
        extent2d_ = {0.0, 0.0};

        if (pcd.points_.empty()) return;

        // 1. Project to 2D and record Z extents - optimized with reserve
        pts2d_.clear();
        pts2d_.reserve(pcd.points_.size());
        
        double zmin =  std::numeric_limits<double>::infinity();
        double zmax = -std::numeric_limits<double>::infinity();

        for (const auto& p : pcd.points_) {
            pts2d_.emplace_back(p(0), p(1));
            zmin = std::min(zmin, p(2));
            zmax = std::max(zmax, p(2));
        }
        z_extent_ = zmax - zmin;
        z_center_ = 0.5 * (zmin + zmax);

        if (pts2d_.size() < 3) return;

        // 2. Build Alpha-shape
        Alpha_shape A(pts2d_.begin(), pts2d_.end());
        
        FT alpha = A.find_alpha_solid();
        if (alpha == FT(0)) {
            auto it = A.find_optimal_alpha(1);
            if (it != A.alpha_end() && *it > FT(0)) {
                alpha = *it;
            }
        }
        if (alpha > FT(0)) {
            A.set_alpha(alpha);
        }

        // 3. Extract all boundary cycles - optimized but preserving correctness
        all_cycles_.clear();
        extract_all_cycles_optimized(A);

        // 4. Select the largest hole - optimized
        best_cycle_.clear();
        select_largest_hole_cycle_optimized();

        // 5. Compute OBB
        obb2d_.clear();
        if (!best_cycle_.empty()) {
            compute_hole_obb_optimized();

            if (obb2d_.size() == 4) {
                angle_rad_ = std::atan2(dy_, dx_);
                double length = std::hypot(dx_, dy_);
                double dx_w = CGAL::to_double(obb2d_[2].x() - obb2d_[1].x());
                double dy_w = CGAL::to_double(obb2d_[2].y() - obb2d_[1].y());
                double width = std::hypot(dx_w, dy_w);
                extent2d_ = { length, width };
            }
        }
    }

    double angle() const { return angle_rad_; }
    Eigen::Vector3d center() const { return { cx_, cy_, z_center_ }; }
    Eigen::Vector3d extent() const { return { extent2d_.x(), extent2d_.y(), z_extent_ }; }
    bool is_valid() const {
        return !best_cycle_.empty() && obb2d_.size() == 4 && extent2d_.x() > 0 && extent2d_.y() > 0;
    }

private:
    std::vector<Point2> pts2d_;
    std::vector<std::vector<Point2>> all_cycles_;
    std::vector<Point2> best_cycle_;
    std::vector<Point2> obb2d_;
    
    double cx_, cy_;
    double dx_, dy_;
    double angle_rad_;
    Eigen::Vector2d extent2d_;
    double z_center_, z_extent_;

    // Optimized cycle extraction preserving the edge consumption logic
    void extract_all_cycles_optimized(const Alpha_shape& A) {
        // Pre-collect regular segments with reservation
        std::vector<Segment2> regular_segments;
        regular_segments.reserve(A.number_of_vertices() * 3); // Better estimate
        
        for (auto it = A.alpha_shape_edges_begin(); it != A.alpha_shape_edges_end(); ++it) {
            if (A.classify(*it) == Alpha_shape::REGULAR) {
                regular_segments.push_back(A.segment(*it));
            }
        }

        if (regular_segments.empty()) return;

        // Use unordered_map but with deque for efficient front removal
        std::unordered_map<Point2, std::deque<Point2>> adj_list;
        adj_list.reserve(regular_segments.size() * 2);
        
        for (const auto& seg : regular_segments) {
            adj_list[seg.source()].push_back(seg.target());
            adj_list[seg.target()].push_back(seg.source());
        }

        all_cycles_.clear();
        all_cycles_.reserve(std::min(size_t(50), adj_list.size() / 10)); // Reasonable estimate

        // Preserve the original logic but with optimized data structures
        for (const auto& seg_init : regular_segments) {
            Point2 start_node = seg_init.source();
            
            auto map_it = adj_list.find(start_node);
            if (map_it == adj_list.end() || map_it->second.empty()) {
                continue;
            }

            std::vector<Point2> current_cycle_pts;
            current_cycle_pts.reserve(100); // Reasonable default size
            Point2 current_pt = start_node;
            
            do {
                current_cycle_pts.push_back(current_pt);
                
                auto adj_it = adj_list.find(current_pt);
                if (adj_it == adj_list.end() || adj_it->second.empty()) {
                    current_cycle_pts.clear();
                    break;
                }
                
                Point2 next_pt = adj_it->second.front();
                
                // Consume the edge efficiently
                adj_it->second.pop_front();
                
                // Remove reverse edge efficiently
                auto reverse_it = adj_list.find(next_pt);
                if (reverse_it != adj_list.end()) {
                    auto& reverse_list = reverse_it->second;
                    // Use erase with find instead of remove for deque
                    auto pos = std::find(reverse_list.begin(), reverse_list.end(), current_pt);
                    if (pos != reverse_list.end()) {
                        reverse_list.erase(pos);
                    }
                }

                current_pt = next_pt;

            } while (current_pt != start_node && !current_cycle_pts.empty());

            if (!current_cycle_pts.empty() && current_pt == start_node && current_cycle_pts.size() >= 3) {
                all_cycles_.push_back(std::move(current_cycle_pts));
            }
        }
    }

    // Optimized hole selection with fast area calculation
    void select_largest_hole_cycle_optimized() {
        best_cycle_.clear();
        double min_negative_area = 0.0;
        
        // Pre-calculate areas to avoid repeated computation
        for (const auto& cycle_pts : all_cycles_) {
            if (cycle_pts.size() < 3) continue;

            // Use fast signed area calculation
            double area = calculate_signed_area_fast(cycle_pts);
            
            if (area < min_negative_area) {
                min_negative_area = area;
                best_cycle_ = cycle_pts;
            }
        }
    }

    // Fast signed area calculation using shoelace formula
    double calculate_signed_area_fast(const std::vector<Point2>& points) {
        if (points.size() < 3) return 0.0;
        
        double area = 0.0;
        const size_t n = points.size();
        
        // Cache the first point conversion
        double prev_x = CGAL::to_double(points[n-1].x());
        double prev_y = CGAL::to_double(points[n-1].y());
        
        for (size_t i = 0; i < n; ++i) {
            double curr_x = CGAL::to_double(points[i].x());
            double curr_y = CGAL::to_double(points[i].y());
            area += (prev_x * curr_y - curr_x * prev_y);
            prev_x = curr_x;
            prev_y = curr_y;
        }
        
        return area * 0.5;
    }

    // Optimized OBB computation
    void compute_hole_obb_optimized() {
        obb2d_.clear();
        obb2d_.reserve(4);
        cx_ = 0.0; cy_ = 0.0; 
        dx_ = 0.0; dy_ = 0.0;

        if (best_cycle_.size() < 3) return;

        std::vector<Point2> hull_pts;
        hull_pts.reserve(best_cycle_.size());
        CGAL::convex_hull_2(best_cycle_.begin(), best_cycle_.end(), std::back_inserter(hull_pts));

        if (hull_pts.size() < 3) return;
        
        CGAL::min_rectangle_2(hull_pts.begin(), hull_pts.end(), std::back_inserter(obb2d_));

        if (obb2d_.size() == 4) {
            // Optimized center calculation
            double sum_x = 0.0, sum_y = 0.0;
            for (const auto& p : obb2d_) {
                sum_x += CGAL::to_double(p.x());
                sum_y += CGAL::to_double(p.y());
            }
            cx_ = sum_x * 0.25;
            cy_ = sum_y * 0.25;

            dx_ = CGAL::to_double(obb2d_[1].x() - obb2d_[0].x());
            dy_ = CGAL::to_double(obb2d_[1].y() - obb2d_[0].y());
        } else {
            obb2d_.clear();
        }
    }
};
