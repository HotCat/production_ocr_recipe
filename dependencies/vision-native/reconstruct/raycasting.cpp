#include <glm/glm.hpp>
#include <glm/gtc/matrix_transform.hpp>
#include <vector>
#include <limits>

struct Point {
    glm::vec3 position;
};

void extractFrustumPlanes(const glm::mat4& viewProjectionMatrix, glm::vec4 planes[6]) {
    planes[0] = glm::vec4(
        viewProjectionMatrix[0][3] + viewProjectionMatrix[0][0],
        viewProjectionMatrix[1][3] + viewProjectionMatrix[1][0],
        viewProjectionMatrix[2][3] + viewProjectionMatrix[2][0],
        viewProjectionMatrix[3][3] + viewProjectionMatrix[3][0]);

    planes[1] = glm::vec4(
        viewProjectionMatrix[0][3] - viewProjectionMatrix[0][0],
        viewProjectionMatrix[1][3] - viewProjectionMatrix[1][0],
        viewProjectionMatrix[2][3] - viewProjectionMatrix[2][0],
        viewProjectionMatrix[3][3] - viewProjectionMatrix[3][0]);

    planes[2] = glm::vec4(
        viewProjectionMatrix[0][3] + viewProjectionMatrix[0][1],
        viewProjectionMatrix[1][3] + viewProjectionMatrix[1][1],
        viewProjectionMatrix[2][3] + viewProjectionMatrix[2][1],
        viewProjectionMatrix[3][3] + viewProjectionMatrix[3][1]);

    planes[3] = glm::vec4(
        viewProjectionMatrix[0][3] - viewProjectionMatrix[0][1],
        viewProjectionMatrix[1][3] - viewProjectionMatrix[1][1],
        viewProjectionMatrix[2][3] - viewProjectionMatrix[2][1],
        viewProjectionMatrix[3][3] - viewProjectionMatrix[3][1]);

    planes[4] = glm::vec4(
        viewProjectionMatrix[0][3] + viewProjectionMatrix[0][2],
        viewProjectionMatrix[1][3] + viewProjectionMatrix[1][2],
        viewProjectionMatrix[2][3] + viewProjectionMatrix[2][2],
        viewProjectionMatrix[3][3] + viewProjectionMatrix[3][2]);

    planes[5] = glm::vec4(
        viewProjectionMatrix[0][3] - viewProjectionMatrix[0][2],
        viewProjectionMatrix[1][3] - viewProjectionMatrix[1][2],
        viewProjectionMatrix[2][3] - viewProjectionMatrix[2][2],
        viewProjectionMatrix[3][3] - viewProjectionMatrix[3][2]);

    for (int i = 0; i < 6; i++) {
        float length = glm::length(glm::vec3(planes[i]));
        planes[i] /= length;
    }
}

bool isPointInFrustum(const glm::vec4 planes[6], const glm::vec3& point) {
    for (int i = 0; i < 6; i++) {
        if (glm::dot(glm::vec3(planes[i]), point) + planes[i].w < 0) {
            return false;  // Point is outside this plane
        }
    }
    return true;
}

bool intersectRayWithPlane(const glm::vec3& rayOrigin, const glm::vec3& rayDirection,
                           float a, float b, float c, float d,
                           glm::vec3& outIntersection) {
    glm::vec3 planeNormal(a, b, c);
    float denom = glm::dot(planeNormal, rayDirection);

    if (glm::abs(denom) > std::numeric_limits<float>::epsilon()) { // Ensure the ray is not parallel to the plane
        float t = -(glm::dot(planeNormal, rayOrigin) + d) / denom;

        if (t >= 0) { // Intersection is in the positive ray direction
            outIntersection = rayOrigin + t * rayDirection;
            return true;
        }
    }

    return false; // No intersection or intersection is behind the ray origin
}

bool intersectRayWithPointCloud(const glm::vec3& rayOrigin, const glm::vec3& rayDirection,
                                const glm::mat4& viewProjectionMatrix,
                                const glm::mat4& modelMatrix,
                                const std::vector<Point>& pointCloud, glm::vec3& outIntersection,
                                float a, float b, float c, float d) {
    float minDistance = std::numeric_limits<float>::max();
    bool intersected = false;

    glm::vec4 frustumPlanes[6];
    extractFrustumPlanes(viewProjectionMatrix, frustumPlanes);

    for (const auto& point : pointCloud) {
        // Transform point to world coordinates
        glm::vec3 worldPoint = glm::vec3(modelMatrix * glm::vec4(point.position, 1.0f));

        if (!isPointInFrustum(frustumPlanes, worldPoint)) continue;  // Skip points outside the frustum

        glm::vec3 diff = worldPoint - rayOrigin;
        float t = glm::dot(diff, rayDirection);

        if (t < 0) continue;  // Ignore points behind the ray

        glm::vec3 closestPoint = rayOrigin + t * rayDirection;
        float distance = glm::length(closestPoint - worldPoint);

        if (distance < minDistance) {
            glm::vec3 intersectionPoint;
            if (intersectRayWithPlane(rayOrigin, rayDirection, a, b, c, d, intersectionPoint)) {
                minDistance = distance;
                outIntersection = intersectionPoint;
                intersected = true;
            }
        }
    }

    return intersected;
}
