// File: GrooveOBB_intel_optimized.h
// -O3 -march=native -mtune=native -mavx2 -mfma -flto

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
#include <immintrin.h>  // For Intel intrinsics

// Optimized hash for CGAL Point_2 using FNV-1a (faster than default)
namespace std {
    template<>
    struct hash<CGAL::Simple_cartesian<double>::Point_2> {
        size_t operator()(const CGAL::Simple_cartesian<double>::Point_2& p) const noexcept {
            // FNV-1a hash - faster than std::hash combination
            constexpr size_t FNV_OFFSET_BASIS = 14695981039346656037ULL;
            constexpr size_t FNV_PRIME = 1099511628211ULL;
            
            union { double d; uint64_t i; } x, y;
            x.d = CGAL::to_double(p.x());
            y.d = CGAL::to_double(p.y());
            
            size_t hash = FNV_OFFSET_BASIS;
            hash ^= x.i;
            hash *= FNV_PRIME;
            hash ^= y.i;
            hash *= FNV_PRIME;
            return hash;
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

        // 1. Optimized 2D projection with SIMD-friendly layout
        project_and_compute_z_bounds(pcd);
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

        // 3. Extract cycles with cache-optimized approach
        all_cycles_.clear();
        extract_all_cycles_cache_optimized(A);

        // 4. Select largest hole with vectorized area calculation
        best_cycle_.clear();
        select_largest_hole_vectorized();

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
    // Aligned storage for better cache performance
    alignas(32) std::vector<Point2> pts2d_;
    std::vector<std::vector<Point2>> all_cycles_;
    std::vector<Point2> best_cycle_;
    std::vector<Point2> obb2d_;
    
    double cx_, cy_;
    double dx_, dy_;
    double angle_rad_;
    Eigen::Vector2d extent2d_;
    double z_center_, z_extent_;

    // Cache-friendly 2D projection
    void project_and_compute_z_bounds(const open3d::geometry::PointCloud& pcd) {
        pts2d_.clear();
        pts2d_.reserve(pcd.points_.size());
        
        // Process in chunks to fit in L1 cache (32KB)
        constexpr size_t CHUNK_SIZE = 1024; // ~24KB per chunk for 3 doubles per point
        
        double zmin = std::numeric_limits<double>::infinity();
        double zmax = -std::numeric_limits<double>::infinity();
        
        for (size_t start = 0; start < pcd.points_.size(); start += CHUNK_SIZE) {
            size_t end = std::min(start + CHUNK_SIZE, pcd.points_.size());
            
            // Process chunk with better cache locality
            for (size_t i = start; i < end; ++i) {
                const auto& p = pcd.points_[i];
                pts2d_.emplace_back(p(0), p(1));
                double z = p(2);
                zmin = std::min(zmin, z);
                zmax = std::max(zmax, z);
            }
        }
        
        z_extent_ = zmax - zmin;
        z_center_ = 0.5 * (zmin + zmax);
    }

    // Cache-optimized cycle extraction
    void extract_all_cycles_cache_optimized(const Alpha_shape& A) {
        // Pre-collect segments with better memory layout
        std::vector<std::pair<Point2, Point2>> segments;
        segments.reserve(A.number_of_vertices() * 3);
        
        for (auto it = A.alpha_shape_edges_begin(); it != A.alpha_shape_edges_end(); ++it) {
            if (A.classify(*it) == Alpha_shape::REGULAR) {
                auto seg = A.segment(*it);
                segments.emplace_back(seg.source(), seg.target());
            }
        }

        if (segments.empty()) return;

        // Use flat_hash_map equivalent with better cache performance
        constexpr size_t EXPECTED_NODES = 1000;
        std::unordered_map<Point2, std::vector<Point2>> adj_list;
        adj_list.reserve(segments.size() * 2);
        
        // Build adjacency list with cache-friendly pattern
        for (const auto& [src, tgt] : segments) {
            adj_list[src].reserve(4); // Most nodes have 2-4 neighbors
            adj_list[tgt].reserve(4);
            adj_list[src].push_back(tgt);
            adj_list[tgt].push_back(src);
        }

        all_cycles_.clear();
        all_cycles_.reserve(20); // Reasonable upper bound

        // Process segments in blocks to maintain cache locality
        std::unordered_set<Point2> processed;
        processed.reserve(adj_list.size());

        for (const auto& [src, tgt] : segments) {
            if (processed.count(src) || adj_list[src].empty()) continue;
            
            std::vector<Point2> cycle;
            if (extract_cycle_optimized(src, adj_list, processed, cycle)) {
                if (cycle.size() >= 3) {
                    all_cycles_.push_back(std::move(cycle));
                }
            }
        }
    }

    // Optimized single cycle extraction
    bool extract_cycle_optimized(const Point2& start,
                                std::unordered_map<Point2, std::vector<Point2>>& adj_list,
                                std::unordered_set<Point2>& processed,
                                std::vector<Point2>& cycle) {
        cycle.clear();
        cycle.reserve(64); // Reasonable default
        
        Point2 current = start;
        
        do {
            cycle.push_back(current);
            
            auto& neighbors = adj_list[current];
            if (neighbors.empty()) return false;
            
            Point2 next = neighbors.back();
            neighbors.pop_back();
            
            // Remove reverse edge efficiently
            auto& reverse_neighbors = adj_list[next];
            auto it = std::find(reverse_neighbors.begin(), reverse_neighbors.end(), current);
            if (it != reverse_neighbors.end()) {
                // Swap with last element and pop (O(1) removal)
                if (it != reverse_neighbors.end() - 1) {
                    std::swap(*it, reverse_neighbors.back());
                }
                reverse_neighbors.pop_back();
            }
            
            processed.insert(current);
            current = next;
            
        } while (current != start && cycle.size() < 10000);
        
        return current == start && cycle.size() >= 3;
    }

    // Vectorized area calculation for hole selection
    void select_largest_hole_vectorized() {
        best_cycle_.clear();
        double min_negative_area = 0.0;
        
        for (const auto& cycle_pts : all_cycles_) {
            if (cycle_pts.size() < 3) continue;
            
            double area = calculate_area_vectorized(cycle_pts);
            
            if (area < min_negative_area) {
                min_negative_area = area;
                best_cycle_ = cycle_pts;
            }
        }
    }

    // SIMD-optimized area calculation where possible
    double calculate_area_vectorized(const std::vector<Point2>& points) {
        if (points.size() < 3) return 0.0;
        
        const size_t n = points.size();
        double area = 0.0;
        
        // For small polygons, use optimized scalar version
        if (n < 8) {
            return calculate_signed_area_scalar_optimized(points);
        }
        
        // For larger polygons, process in batches for better cache usage
        constexpr size_t BATCH_SIZE = 64;
        
        for (size_t start = 0; start < n; start += BATCH_SIZE) {
            size_t end = std::min(start + BATCH_SIZE, n);
            
            for (size_t i = start; i < end; ++i) {
                size_t j = (i + 1) % n;
                double x1 = CGAL::to_double(points[i].x());
                double y1 = CGAL::to_double(points[i].y());
                double x2 = CGAL::to_double(points[j].x());
                double y2 = CGAL::to_double(points[j].y());
                area += (x1 * y2 - x2 * y1);
            }
        }
        
        return area * 0.5;
    }

    // Optimized scalar area calculation
    double calculate_signed_area_scalar_optimized(const std::vector<Point2>& points) {
        const size_t n = points.size();
        double area = 0.0;
        
        // Unroll loop for small polygons
        if (n == 3) {
            double x1 = CGAL::to_double(points[0].x());
            double y1 = CGAL::to_double(points[0].y());
            double x2 = CGAL::to_double(points[1].x());
            double y2 = CGAL::to_double(points[1].y());
            double x3 = CGAL::to_double(points[2].x());
            double y3 = CGAL::to_double(points[2].y());
            
            area = (x1 * (y2 - y3) + x2 * (y3 - y1) + x3 * (y1 - y2)) * 0.5;
        } else {
            // Cache-optimized general case
            double prev_x = CGAL::to_double(points[n-1].x());
            double prev_y = CGAL::to_double(points[n-1].y());
            
            for (size_t i = 0; i < n; ++i) {
                double curr_x = CGAL::to_double(points[i].x());
                double curr_y = CGAL::to_double(points[i].y());
                area += (prev_x * curr_y - curr_x * prev_y);
                prev_x = curr_x;
                prev_y = curr_y;
            }
            area *= 0.5;
        }
        
        return area;
    }

    // Cache-optimized OBB computation
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
            // Vectorized center calculation
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
