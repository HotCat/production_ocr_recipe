// File: GrooveOBB.h

#pragma once

#include <open3d/geometry/PointCloud.h>
#include <CGAL/Simple_cartesian.h>
#include <CGAL/Alpha_shape_2.h>
#include <CGAL/Alpha_shape_vertex_base_2.h> // Included for completeness, used by Tds if specified
#include <CGAL/Alpha_shape_face_base_2.h>   // Included for completeness, used by Tds if specified
#include <CGAL/Delaunay_triangulation_2.h>
#include <CGAL/Triangulation_data_structure_2.h>
#include <CGAL/Polygon_2.h>
#include <CGAL/Polygon_2_algorithms.h> // For polygon area
#include <CGAL/convex_hull_2.h>
#include <CGAL/min_quadrilateral_2.h>   // For min_rectangle_2
#include <CGAL/Exact_predicates_inexact_constructions_kernel.h>
#include <CGAL/linear_least_squares_fitting_2.h>

#include <Eigen/Dense>
#include <vector>
#include <limits>
#include <cmath>
#include <list> // For adjacency list in contour extraction
#include <map>  // For adjacency list
#include <algorithm> // For std::min_element, std::sort etc.

// CGAL kernel and types
using Kernel        = CGAL::Simple_cartesian<double>;
/* using Kernel = CGAL::Exact_predicates_inexact_constructions_kernel; */
using Point2        = Kernel::Point_2;
// Using default Triangulation_data_structure with Delaunay_triangulation_2
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
    /// Construct from an Open3D planar point cloud (aligned to XY).
    explicit GrooveOBB(const open3d::geometry::PointCloud& pcd) {
        // Initialize members to a default state
        z_center_ = 0.0; z_extent_ = 0.0;
        cx_ = 0.0; cy_ = 0.0;
        dx_ = 0.0; dy_ = 0.0;
        angle_rad_ = 0.0;
        extent2d_ = {0.0, 0.0};

        // 1. Project to 2D and record Z extents
        pts2d_.clear();
        double zmin =  std::numeric_limits<double>::infinity();
        double zmax = -std::numeric_limits<double>::infinity();

        if (pcd.points_.empty()) {
            // std::cerr << "GrooveOBB Warning: Input point cloud is empty." << std::endl;
            return; // OBB remains in default invalid state
        }

        for (const auto& p : pcd.points_) {
            pts2d_.emplace_back(p(0), p(1));
            zmin = std::min(zmin, p(2));
            zmax = std::max(zmax, p(2));
        }
        z_extent_ = zmax - zmin;
        z_center_ = 0.5 * (zmin + zmax);

        if (pts2d_.size() < 3) {
            // std::cerr << "GrooveOBB Warning: Less than 3 points after projection, cannot form alpha shape." << std::endl;
            return; // OBB remains in default invalid state
        }

        // 2. Build Alpha-shape
        Alpha_shape A(pts2d_.begin(), pts2d_.end());

	// --- alpha selection ---
	Alpha_shape::Type_of_alpha alpha = A.find_alpha_solid();
	if(alpha == FT(0)) {
	  auto it = A.find_optimal_alpha(1);
	  if(it != A.alpha_end() && *it > FT(0))
	    alpha = *it;
	}
	
	if(alpha > FT(0)) {
	  A.set_alpha(alpha);
	}


        /* // Choose and set alpha: Try to find an alpha that forms a solid shape. */
        /* Alpha_shape::Alpha_iterator alpha_it = A.find_alpha_solid(); */
        /* if (alpha_it == A.alpha_end() || *alpha_it == 0) { */
        /*     // Fallback: try optimal alpha for 1 component. */
        /*     // This might merge distinct components or close small holes needed for groove detection. */
        /*     // std::cout << "GrooveOBB Info: Could not find a solid alpha. Trying optimal for 1 component." << std::endl; */
        /*     alpha_it = A.find_optimal_alpha(1); // */
        /*     if (alpha_it == A.alpha_end() || *alpha_it == 0) { */
        /*         // std::cerr << "GrooveOBB Error: Could not find any suitable alpha value." << std::endl; */
        /*         return; // OBB remains invalid */
        /*     } */
        /* } */
        /* A.set_alpha(*alpha_it); */
        /* // std::cout << "GrooveOBB Info: Using alpha = " << *alpha_it << std::endl; */

        // 3. Extract all boundary cycles (outer and inner)
        all_cycles_.clear();
        extract_all_cycles(A);

        // 4. Select the largest hole (cycle with most negative area)
        best_cycle_.clear();
        select_largest_hole_cycle();

        // 5. Compute convex hull + minimal rectangle on the selected hole polygon
        obb2d_.clear();
        if (!best_cycle_.empty()) {
            compute_hole_obb(); // Populates obb2d_, cx_, cy_, dx_, dy_

            // 6. Combine results: angle and extents
            if (obb2d_.size() == 4) { // Check if OBB computation was successful
                angle_rad_ = std::atan2(dy_, dx_);
                
                // Length is hypot(dx, dy)
                double length = std::hypot(dx_, dy_);
                
                /* // Width is the length of the perpendicular side of the OBB */
                /* // For obb2d_[0,1,2,3], if 0-1 is length vector (dx,dy), then 1-2 is width vector */
                /* Point2 vec_width_pt = Point2(obb2d_[2].x() - obb2d_[1].x(), obb2d_[2].y() - obb2d_[1].y()); */
                /* double width = std::sqrt(CGAL::to_double(vec_width_pt.squared_length())); */
		double dx_w = CGAL::to_double(obb2d_[2].x() - obb2d_[1].x());
		double dy_w = CGAL::to_double(obb2d_[2].y() - obb2d_[1].y());
		double width = std::hypot(dx_w, dy_w);
                
                extent2d_ = { length, width };
            } else {
                 // OBB computation failed to produce 4 points
                // std::cerr << "GrooveOBB Warning: OBB computation for hole failed." << std::endl;
            }
        } else {
            // std::cout << "GrooveOBB Info: No suitable hole found to compute OBB." << std::endl;
        }

    }

    /// Returns rotation angle (radians) about Z
    double angle() const { return angle_rad_; }

    /// Returns 3D center (x,y,z)
    Eigen::Vector3d center() const {
        return { cx_, cy_, z_center_ };
    }

    /// Returns 3D extents (width, height, depth) corresponding to OBB length, OBB width, and original Z extent
    Eigen::Vector3d extent() const {
        return { extent2d_.x(), extent2d_.y(), z_extent_ };
    }
    
    /// Checks if a valid OBB for a groove was found
    bool is_valid() const {
        return !best_cycle_.empty() && obb2d_.size() == 4 && extent2d_.x() > 0 && extent2d_.y() > 0;
    }

private:
    // 2D points and intermediate storage
    std::vector<Point2> pts2d_;
    std::vector<std::vector<Point2>> all_cycles_; // Stores all extracted cycles
    std::vector<Point2> best_cycle_;              // Points of the largest hole cycle
    std::vector<Point2> obb2d_;                   // Points of the 2D OBB of the hole (typically 4 points)
    
    // OBB properties
    double cx_, cy_;          // Center of the 2D OBB
    double dx_, dy_;          // Vector defining one edge of the OBB (from obb2d_[0] to obb2d_[1])
    double angle_rad_;        // Rotation angle of the OBB
    Eigen::Vector2d extent2d_;// Length and Width of the 2D OBB
    
    // Z properties
    double z_center_, z_extent_;

    // Extracts all REGULAR boundary edges and builds ordered cycles from them.
    void extract_all_cycles(const Alpha_shape& A) {
        std::vector<Segment2> regular_segments;
        // Iterate over classified edges of the alpha shape
        for (auto it = A.alpha_shape_edges_begin(); it != A.alpha_shape_edges_end(); ++it) {
            // An edge is part of the alpha-shape boundary if it's REGULAR for the current alpha value
            if (A.classify(*it) == Alpha_shape::REGULAR) {
                regular_segments.push_back(A.segment(*it));
            }
        }

        if (regular_segments.empty()) {
            // std::cout << "GrooveOBB Debug: No regular segments found for contour extraction." << std::endl;
            return;
        }

        std::map<Point2, std::list<Point2>> adj_list;
        for (const auto& seg : regular_segments) {
            adj_list[seg.source()].push_back(seg.target());
            adj_list[seg.target()].push_back(seg.source());
        }

        all_cycles_.clear();
        // To ensure each point is considered as a starting point only if it has unprocessed edges
        std::map<Point2, bool> visited_starts; 

        for (const auto& seg_init : regular_segments) { // Iterate to find starting points for cycles
            Point2 start_node = seg_init.source();
            
            // Check if this node still has unprocessed edges in adj_list
            auto map_it = adj_list.find(start_node);
            if (map_it == adj_list.end() || map_it->second.empty()) {
                continue; // No outgoing edges left from this node
            }

            // If already started a cycle from this node (and consumed its edges) effectively, skip.
            // This check is implicitly handled by adj_list becoming empty for processed nodes.

            std::vector<Point2> current_cycle_pts;
            Point2 current_pt = start_node;
            
            do {
                current_cycle_pts.push_back(current_pt);
                
                auto& neighbors = adj_list.at(current_pt); 
                if (neighbors.empty()) { 
                    // This indicates a break in the cycle or an open polyline,
                    // which shouldn't happen for REGULAR boundaries of a closed alpha shape.
                    // std::cerr << "GrooveOBB Debug: Dead end in contour extraction at point " << current_pt << std::endl;
                    current_cycle_pts.clear(); // Invalidate this attempt
                    break;
                }
                Point2 next_pt = neighbors.front();
                
                // Consume the edge
                neighbors.pop_front(); 
                adj_list.at(next_pt).remove(current_pt); // Remove the reverse edge

                current_pt = next_pt;

            } while (current_pt != start_node && !current_cycle_pts.empty());

            if (!current_cycle_pts.empty() && current_pt == start_node && current_cycle_pts.size() >= 3) {
                all_cycles_.push_back(current_cycle_pts);
            } else if (!current_cycle_pts.empty()) {
                // std::cout << "GrooveOBB Debug: Discarded an open or too small path. Size: " << current_cycle_pts.size() << std::endl;
            }
        }
    }
    
    // Selects the cycle with the largest negative area (largest hole).
    void select_largest_hole_cycle() {
        best_cycle_.clear();
        double min_negative_area = 0.0; // Initialize to 0; any actual hole will have area < 0.

        for (const auto& cycle_pts : all_cycles_) {
            if (cycle_pts.size() < 3) continue;

            Polygon2 poly(cycle_pts.begin(), cycle_pts.end());
            // CGAL::Polygon_2::area() is exact. Convert to double for comparisons if needed,
            // though direct comparison of FT (Kernel::FT) is also possible.
            double area = CGAL::to_double(poly.area());

            if (area < min_negative_area) { // Looking for largest hole (most negative area)
                min_negative_area = area;
                best_cycle_ = cycle_pts;
            }
        }
        // if (!best_cycle_.empty()) {
        //    std::cout << "GrooveOBB Info: Selected largest hole with area " << min_negative_area << std::endl;
        // } else {
        //    std::cout << "GrooveOBB Info: No hole contours (negative area) found." << std::endl;
        // }
    }

    // Compute convex hull and rotating-calipers OBB for the best_cycle_
    void compute_hole_obb() {
        obb2d_.clear(); // Reset
        // Reset OBB properties that are derived in this function
        cx_ = 0.0; cy_ = 0.0; 
        dx_ = 0.0; dy_ = 0.0;

        if (best_cycle_.size() < 3) {
            // std::cerr << "GrooveOBB Warning: Not enough points in best_cycle_ for convex hull." << std::endl;
            return;
        }

        std::vector<Point2> hull_pts;
        CGAL::convex_hull_2(best_cycle_.begin(), best_cycle_.end(), std::back_inserter(hull_pts));

        if (hull_pts.size() < 3) {
            // std::cerr << "GrooveOBB Warning: Convex hull of hole has less than 3 points." << std::endl;
            return; 
        }
        
        // CGAL::min_rectangle_2 stores the 4 CCW vertices of the rectangle
        CGAL::min_rectangle_2(hull_pts.begin(), hull_pts.end(), std::back_inserter(obb2d_));

        if (obb2d_.size() == 4) {
            // Calculate center (average of OBB vertices)
            for (const auto& p : obb2d_) {
                cx_ += CGAL::to_double(p.x());
                cy_ += CGAL::to_double(p.y());
            }
            cx_ /= 4.0;
            cy_ /= 4.0;

            // Define dx_, dy_ from the first edge of the OBB (obb2d_[0] to obb2d_[1])
            // This edge is conventionally taken as defining the OBB's primary orientation and length.
            dx_ = CGAL::to_double(obb2d_[1].x() - obb2d_[0].x());
            dy_ = CGAL::to_double(obb2d_[1].y() - obb2d_[0].y());
        } else {
            // std::cerr << "GrooveOBB Warning: min_rectangle_2 did not return 4 points for the OBB." << std::endl;
            obb2d_.clear(); // Invalidate OBB points if not 4
        }
    }
};
