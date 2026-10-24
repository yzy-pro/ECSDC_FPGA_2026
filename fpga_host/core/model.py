"""Small URDF/STL loader and forward kinematics, without ROS/OpenGL."""
from dataclasses import dataclass
from pathlib import Path
import struct
import xml.etree.ElementTree as ET
import numpy as np


def rotation(axis, angle):
    axis = np.asarray(axis, dtype=float)
    length = np.linalg.norm(axis)
    if not length:
        return np.eye(4)
    x, y, z = axis / length
    c, s = np.cos(angle), np.sin(angle)
    cross = np.array([[0, -z, y], [z, 0, -x], [-y, x, 0]])
    matrix = np.eye(4)
    matrix[:3, :3] = c * np.eye(3) + (1-c) * np.outer([x, y, z], [x, y, z]) + s * cross
    return matrix


def origin(element):
    matrix = np.eye(4)
    if element is None:
        return matrix
    xyz = [float(v) for v in element.get("xyz", "0 0 0").split()]
    r, p, y = [float(v) for v in element.get("rpy", "0 0 0").split()]
    matrix = rotation([0, 0, 1], y) @ rotation([0, 1, 0], p) @ rotation([1, 0, 0], r)
    matrix[:3, 3] = xyz
    return matrix


def load_stl(path: Path, max_triangles=1200):
    data = path.read_bytes()
    count = struct.unpack_from("<I", data, 80)[0] if len(data) >= 84 else 0
    if len(data) == 84 + count * 50:
        dtype = np.dtype([("normal", "<f4", (3,)), ("vertices", "<f4", (3, 3)), ("attr", "<u2")])
        vertices = np.frombuffer(data, dtype=dtype, count=count, offset=84)["vertices"].astype(float)
    else:
        points = []
        for line in data.decode("ascii").splitlines():
            tokens = line.split()
            if tokens and tokens[0] == "vertex":
                points.append([float(v) for v in tokens[1:4]])
        vertices = np.asarray(points, dtype=float).reshape(-1, 3, 3)
    if not len(vertices) or not np.isfinite(vertices).all():
        raise ValueError(f"无效 STL: {path}")
    if len(vertices) <= max_triangles:
        return vertices.copy()
    # Vertex clustering retains connected surfaces, unlike dropping triangles.
    # Simplification affects only the viewport; source STL stays untouched.
    flat = vertices.reshape(-1, 3)
    low = flat.min(axis=0)
    extent = max(np.ptp(flat, axis=0).max(), 1e-9)
    for resolution in (64, 48, 32, 24, 16, 12, 8, 6, 4, 2):
        keys = np.floor((flat-low) / (extent/resolution)).astype(np.int32)
        cells, inverse = np.unique(keys, axis=0, return_inverse=True)
        counts = np.bincount(inverse)
        centers = np.column_stack([np.bincount(inverse, weights=flat[:, i])/counts for i in range(3)])
        faces = inverse.reshape(-1, 3)
        faces = faces[(faces[:, 0] != faces[:, 1]) & (faces[:, 1] != faces[:, 2]) & (faces[:, 0] != faces[:, 2])]
        _, unique = np.unique(np.sort(faces, axis=1), axis=0, return_index=True)
        simplified = centers[faces[unique]]
        if len(simplified) <= max_triangles:
            return simplified
    return simplified


@dataclass
class Mesh:
    link: str
    triangles: np.ndarray
    transform: np.ndarray
    color: tuple


@dataclass
class Joint:
    name: str
    parent: str
    child: str
    transform: np.ndarray
    axis: list
    movable: bool


class RobotModel:
    def __init__(self, path: Path):
        try:
            root = ET.parse(path).getroot()
        except ET.ParseError as exc:
            raise ValueError(f"URDF XML 格式错误: {exc}") from exc
        self.meshes = []
        self.joints = []
        links = {link.attrib["name"] for link in root.findall("link")}
        for link in root.findall("link"):
            for visual in link.findall("visual"):
                mesh = visual.find("geometry/mesh")
                if mesh is None:
                    continue
                filename = mesh.attrib["filename"]
                if filename.startswith("package://"):
                    relative = filename[len("package://"):].split("/", 1)[1]
                    mesh_path = path.parent.parent / relative
                else:
                    mesh_path = path.parent / filename
                color = visual.find("material/color")
                rgba = tuple(float(v) for v in color.get("rgba", "0.4 0.7 0.8 1").split()) if color is not None else (.4, .7, .8, 1)
                scale = np.array([float(v) for v in mesh.get("scale", "1 1 1").split()])
                self.meshes.append(Mesh(link.attrib["name"], load_stl(mesh_path) * scale, origin(visual.find("origin")), rgba))
        for joint in root.findall("joint"):
            axis = joint.find("axis")
            self.joints.append(Joint(joint.attrib["name"], joint.find("parent").attrib["link"],
                joint.find("child").attrib["link"], origin(joint.find("origin")),
                [float(v) for v in axis.get("xyz", "1 0 0").split()] if axis is not None else [1, 0, 0],
                joint.get("type") in ("revolute", "continuous")))
        roots = links - {joint.child for joint in self.joints}
        if len(roots) != 1 or not self.meshes:
            raise ValueError("URDF 需要一个根节点和可显示的网格")
        self.root = roots.pop()
        self.transforms({})  # Validate tree now rather than during painting.

    def transforms(self, angles):
        result = {self.root: np.eye(4)}
        remaining = list(self.joints)
        while remaining:
            ready = [j for j in remaining if j.parent in result]
            if not ready:
                raise ValueError("URDF 关节树存在循环或断链")
            for joint in ready:
                result[joint.child] = result[joint.parent] @ joint.transform @ rotation(joint.axis, angles.get(joint.name, 0) if joint.movable else 0)
            names = {j.name for j in ready}
            remaining = [j for j in remaining if j.name not in names]
        return result

    def geometry(self, angles):
        transforms = self.transforms(angles)
        for mesh in self.meshes:
            matrix = transforms[mesh.link] @ mesh.transform
            yield mesh.triangles @ matrix[:3, :3].T + matrix[:3, 3], mesh.color
