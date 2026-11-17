// PolylidarOBB.h
#pragma once

#include <vector>
#include <tuple>
#include <limits>
#include <cmath>
#include <iostream>

// Open3D
#include <open3d/geometry/PointCloud.h>
#include <open3d/geometry/TriangleMesh.h>

// Polylidar3D
#include "Polylidar/Polylidar.hpp"              // Polylidar3D, MeshHelper :contentReference[oaicite:0]{index=0}

// CGAL
#include <CGAL/Simple_cartesian.h>
#include <CGAL/convex_hull_2.h>                 // convex_hull_2 :contentReference[oaicite:2]{index=2}
#include <CGAL/min_quadrilateral_2.h>           // min_rectangle_2 :contentReference[oaicite:3]{index=3}

// Eigen
#include <Eigen/Dense>

using K  = CGAL::Simple_cartesian<double>;
using P2 = K::Point_2;

using namespace Polylidar;
namespace o3d = open3d;
using TriMesh = MeshHelper::HalfEdgeTriangulation;

#ifndef DEBUG
#define DEBUG 1
#endif
#define DLOG(x) do { if (DEBUG) std::cerr << x << std::endl; } while(0)

class PolylidarOBB {
public:
    explicit PolylidarOBB(const open3d::geometry::PointCloud& cloud) {
        DLOG("[OBB] From Open3D cloud, N=" << cloud.points_.size());
        buildFromMesh(cloud);
    }
    explicit PolylidarOBB(const std::vector<Eigen::Vector3d>& pts) {
        DLOG("[OBB] From raw points, N=" << pts.size());
        open3d::geometry::PointCloud temp;
        temp.points_ = pts;
        buildFromMesh(temp);
    }

    double angle()  const { return angle_deg_; }
    Eigen::Vector3d center() const { return {cx_, cy_, cz_}; }
    Eigen::Vector3d extent() const { return {ext_x_, ext_y_, ext_z_}; }

private:
    // OBB results
    double cx_{0}, cy_{0}, cz_{0};
    double ext_x_{0}, ext_y_{0}, ext_z_{0};
    double angle_deg_{0};

    void buildFromMesh(const open3d::geometry::PointCloud& cloud) {
        // --- 1) Build organized mesh if needed, or directly mesh raw points as a pseudo-grid
        // Here we treat cloud as unorganized: build half-edge via Delaunay in 2D projection?
        // But for simplicity, we use CreateTriMeshCopy on its convex hull mesh (user must supply a mesh)
        // For Groove.ply you should load a TriangleMesh instead; this demo uses PointCloud->MeshHelper.

        // Convert to Polylidar triangle mesh via naive Delaunay on XY:
        // (In practice, load a real mesh: open3d::io::ReadTriangleMesh)
        using Mesh = Polylidar::MeshHelper::HalfEdgeTriangulation;
        std::vector<Eigen::Vector3d> pts(cloud.points_.begin(), cloud.points_.end());


	const std::string SPARSE_MESH = "./fixtures/meshes/sparse_basement.ply";
	std::shared_ptr<o3d::geometry::TriangleMesh> sparse_mesh_o3d;
	sparse_mesh_o3d = o3d::io::CreateMeshFromFile(SPARSE_MESH);

	auto triangles_ptr = reinterpret_cast<int*>(sparse_mesh_o3d->triangles_.data());
	auto num_triangles = sparse_mesh_o3d->triangles_.size();
	auto vertices_ptr = reinterpret_cast<double*>(sparse_mesh_o3d->vertices_.data());
	auto num_vertices = sparse_mesh_o3d->vertices_.size();
	Matrix<int> triangles(triangles_ptr, num_triangles, 3);
	Matrix<double> vertices(vertices_ptr, num_vertices, 3);

	TriMesh sparse_mesh = MeshHelper::CreateTriMeshCopy(vertices, triangles, true);
	
	// MeshHelper::BilateralFilterNormals(sparse_mesh, 1, 0.1, 0.1);
	// alpha, lmax, min_tri, min_hole_vert, z_thresh, norm__thresh, norm_thresh_min, _task_threads
	Polylidar3D pl3d(0.0, 0.1, 1000, 6, 0.03, 0.95, 0.90);
	auto planes_and_polygons = pl3d.ExtractPlanesAndPolygonsOptimized(sparse_mesh, {{0.0, 0.0, 1.0}});

        // TODO: replace with real mesh loader for Groove.ply 
        // Mesh mesh = customLoadMesh("Groove.ply");
        // For demo, we skip mesh building and log error:
        DLOG("[OBB] ERROR: buildFromMesh() requires a TriangleMesh input, not PointCloud.");
        return;
    }

};
