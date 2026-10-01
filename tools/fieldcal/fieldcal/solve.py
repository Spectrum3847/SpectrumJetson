"""The field-calibration solve: tag poses, camera mounts and robot spots, all at once.

Unknowns (flat floor, the default):

* each still stretch ("spot"): the robot's x, y and heading on the field (it sits level on the
  carpet);
* the reference camera (the one with the most observations): its height, roll and pitch on the
  robot. The robot frame's origin is on the floor below it, with x along its heading, until a
  reference spot or a CAD value anchors the real robot frame (see anchor_*);
* every other camera: its full pose relative to that frame;
* every tag that was seen: its full pose on the field.

Residuals: each observed tag corner's reprojection error, in pixels (divided by --pixel-sigma), and
a weak pull of each tag towards the official layout. The pull fixes where the whole map sits on the
field (a map that slid as a whole would fit the images equally well). Well-seen tags move freely;
barely-seen ones stay near the layout.
"""

from __future__ import annotations

from collections import Counter, defaultdict
from dataclasses import dataclass, field

import cv2
import numpy as np
from scipy.optimize import least_squares
from scipy.sparse import lil_matrix
from scipy.spatial.transform import Rotation

from . import geometry as g
from .camera import Camera
from .segments import Observation
from .tags import corner_model


@dataclass
class Options:
    tag_size: float = 0.1651
    pixel_sigma: float = 0.5
    prior_translation_m: float = 0.05
    prior_rotation_deg: float = 2.0
    outlier_px: float = 4.0  # an observation whose RMS error is above this is dropped and re-solved
    # The pull towards the layout is robust past this: a tag that really moved 5 cm pulls no harder
    # than one that moved 1 cm, so the map sits where most tags agree with the layout instead of
    # sliding towards the misplaced ones.
    prior_robust_m: float = 0.01
    prior_robust_deg: float = 0.5


@dataclass
class Result:
    ref_camera: str
    segments: dict[int, np.ndarray]  # spot -> T_field_rig (planar)
    cameras: dict[str, np.ndarray]  # camera -> T_rig_cam (WPILib camera axes)
    tags: dict[int, np.ndarray]  # tag -> T_field_tag
    tag_sigma: dict[int, tuple[float, float]]  # tag -> (position sigma m, angle sigma deg), on the field
    tag_rel_sigma: dict[int, float]  # tag -> position sigma m relative to the rest of the map
    camera_sigma: dict[str, np.ndarray]  # camera -> sigmas of (x, y, z, roll, pitch, yaw) in m / deg
    used: list[Observation]
    dropped: list[tuple[Observation, float]]
    rms_by_camera: dict[str, float]
    rms_by_segment: dict[int, float]
    rms_by_tag: dict[int, float]
    obs_by_tag: Counter = field(default_factory=Counter)
    obs_rms: list[float] = field(default_factory=list)  # per observation in ``used``, px
    alignment: dict = field(default_factory=dict)  # how the map was lined up with the layout
    converged: bool = True  # False: the final solve stopped at its evaluation limit


def _pnp(cam: Camera, obs: list[Observation], layout: dict[int, np.ndarray], model: np.ndarray):
    """Camera pose on the field (T_field_camCV) from the layout, using every known tag it saw."""
    known = [o for o in obs if o.tag in layout]
    if len(known) < 2:
        return None
    obj = np.vstack([(layout[o.tag] @ np.c_[model, np.ones(4)].T).T[:, :3] for o in known])
    img = np.vstack([o.corners for o in known])
    ok, rvec, tvec = cv2.solvePnP(obj, img, cam.K, cam.dist8(), flags=cv2.SOLVEPNP_SQPNP)
    if not ok:
        return None
    rvec, tvec = cv2.solvePnPRefineLM(obj, img, cam.K, cam.dist8(), rvec, tvec)
    proj, _ = cv2.projectPoints(obj, rvec, tvec, cam.K, cam.dist8())
    err = float(np.sqrt(np.mean(np.sum((proj.reshape(-1, 2) - img) ** 2, axis=1))))
    if err > 8.0:
        return None
    return g.inv(g.from_rvec(rvec.ravel(), tvec.ravel()))


def _ippe_rigs(cam: Camera, o: Observation, T_field_tag: np.ndarray, T_rig_cam: np.ndarray, model) -> list[np.ndarray]:
    """Both of IPPE's answers for one camera seeing one tag, as the spot's planar pose. One tag seen
    alone is ambiguous (it can look tilted either way); the fit over the spot's other views decides."""
    obj = (T_field_tag @ np.c_[model, np.ones(4)].T).T[:, :3]
    n, rvecs, tvecs, _ = cv2.solvePnPGeneric(obj, o.corners, cam.K, cam.dist8(), flags=cv2.SOLVEPNP_IPPE)
    return [_planarize(g.cv_to_nwu(g.inv(g.from_rvec(rv.ravel(), tv.ravel()))) @ g.inv(T_rig_cam))
            for rv, tv in zip(rvecs, tvecs)]


def _planarize(T: np.ndarray) -> np.ndarray:
    _, _, yaw = g.to_rpy(T[:3, :3])
    return g.planar(T[0, 3], T[1, 3], yaw)


def _view_rms(cam: Camera, o: Observation, T_field_camcv: np.ndarray, T_field_tag: np.ndarray, model) -> float:
    uv = cam.project((g.inv(T_field_camcv) @ T_field_tag @ np.c_[model, np.ones(4)].T).T[:, :3])
    return float(np.sqrt(np.mean(np.sum(np.nan_to_num(uv - o.corners, nan=200.0) ** 2, axis=1))))


def _fit_spot(cams, views, rig_cam, tags, model, T0):
    """Refine a spot's (x, y, heading) against every view of a known tag from a camera with a known
    mount. Returns (T_field_rig, median per-view RMS px)."""
    views = [o for o in views if o.tag in tags and o.camera in rig_cam]
    cam_cv = {c: g.nwu_to_cv(rig_cam[c]) for c in {o.camera for o in views}}
    pts = {o.tag: (tags[o.tag] @ np.c_[model, np.ones(4)].T) for o in views}

    def res(a):
        T = g.planar(*a)
        out = []
        for o in views:
            uv = cams[o.camera].project((g.inv(T @ cam_cv[o.camera]) @ pts[o.tag]).T[:, :3])
            out.append(np.nan_to_num(uv - o.corners, nan=200.0).ravel())
        return np.concatenate(out)

    a0 = [T0[0, 3], T0[1, 3], g.to_rpy(T0[:3, :3])[2]]
    sol = least_squares(res, a0, loss="soft_l1", f_scale=5.0, max_nfev=100)
    r = res(sol.x).reshape(-1, 4, 2)
    return g.planar(*sol.x), float(np.median(np.sqrt(np.mean(np.sum(r**2, axis=2), axis=1))))


def _robust_mean(Ts: list[np.ndarray], tol_m: float = 0.10, tol_deg: float = 5.0) -> np.ndarray:
    """Mean of the poses that agree with the most central one (a wrong PnP answer is dropped)."""
    if len(Ts) <= 2:
        return g.mean_pose(Ts)
    d = np.array([[np.linalg.norm(A[:3, 3] - B[:3, 3]) / tol_m + np.degrees(g.angle_between(A[:3, :3], B[:3, :3])) / tol_deg
                   for B in Ts] for A in Ts])
    centre = int(np.argmin(np.median(d, axis=1)))
    return g.mean_pose([T for T, dd in zip(Ts, d[centre]) if dd < 2.0])


def _group(obs: list[Observation]):
    by_sc: dict[tuple[int, str], list[Observation]] = defaultdict(list)
    by_s: dict[int, list[Observation]] = defaultdict(list)
    for o in obs:
        by_sc[(o.segment, o.camera)].append(o)
        by_s[o.segment].append(o)
    return by_sc, by_s


def _init_spots(cams, obs, tags, rig_cam, segs, model, max_px) -> int:
    """Poses for the spots not in ``segs`` yet, from the cameras whose mounts are known: every
    camera's multi-tag PnP and both IPPE answers of every single tag are tried as starting points,
    each refined against all the spot's views; the best is kept if its median view fits within
    ``max_px``. Returns how many were added."""
    by_sc, by_s = _group(obs)
    added = 0
    for s in sorted(by_s):
        if s in segs:
            continue
        cands = []
        for (ss, c), os_ in by_sc.items():
            if ss == s and c in rig_cam:
                T = _pnp(cams[c], os_, tags, model)
                if T is not None:
                    cands.append(_planarize(g.cv_to_nwu(T) @ g.inv(rig_cam[c])))
        for o in by_s[s]:
            if o.tag in tags and o.camera in rig_cam:
                cands += _ippe_rigs(cams[o.camera], o, tags[o.tag], rig_cam[o.camera], model)
        best = min((_fit_spot(cams, by_s[s], rig_cam, tags, model, T0) for T0 in cands), key=lambda r: r[1], default=None)
        if best is not None and best[1] < max_px:
            segs[s] = best[0]
            added += 1
    return added


def _init_cameras(cams, obs, tags, rig_cam, segs, model, max_px) -> int:
    """Mounts for cameras that never had a multi-tag view at a known spot: from single-tag views
    (both IPPE answers), keeping the one that fits all the camera's views best."""
    added = 0
    for c in cams:
        if c in rig_cam:
            continue
        views = [o for o in obs if o.camera == c and o.segment in segs and o.tag in tags]
        cands = []
        for o in views:
            obj = (tags[o.tag] @ np.c_[model, np.ones(4)].T).T[:, :3]
            _, rvecs, tvecs, _ = cv2.solvePnPGeneric(obj, o.corners, cams[c].K, cams[c].dist8(), flags=cv2.SOLVEPNP_IPPE)
            cands += [g.inv(segs[o.segment]) @ g.cv_to_nwu(g.inv(g.from_rvec(rv.ravel(), tv.ravel()))) for rv, tv in zip(rvecs, tvecs)]
        best, best_e = None, np.inf
        for T in cands:
            e = float(np.median([_view_rms(cams[c], o, g.nwu_to_cv(segs[o.segment] @ T), tags[o.tag], model) for o in views]))
            if e < best_e:
                best, best_e = T, e
        if best is not None and best_e < max_px:
            rig_cam[c] = best
            added += 1
    return added


def initialize(cams: dict[str, Camera], obs: list[Observation], layout: dict[int, np.ndarray], opt: Options,
               max_init_px: float = 10.0):
    """A starting point from the official layout: the reference camera, then spots and cameras in
    turn. Spots that don't fit well enough against the official layout (a tag that moved, seen up
    close) are left for later rounds, when the tags have been solved."""
    model = corner_model(opt.tag_size)
    by_sc, _ = _group(obs)
    field_cam = {}  # (segment, camera) -> T_field_camNWU, from two or more layout tags
    for (s, c), os_ in by_sc.items():
        T = _pnp(cams[c], os_, layout, model)
        if T is not None:
            field_cam[(s, c)] = g.cv_to_nwu(T)
    if not field_cam:
        raise RuntimeError("No spot where a camera saw two or more tags from the layout: nothing to start from.")
    counts = Counter(c for (_, c) in field_cam)
    ref = counts.most_common(1)[0][0]

    # The floor under the reference camera: its height, roll and pitch, from every spot it saw.
    ref_poses = [T for (s, c), T in field_cam.items() if c == ref]
    rp = np.array([g.to_rpy(T[:3, :3])[:2] for T in ref_poses])
    h = float(np.median([T[2, 3] for T in ref_poses]))
    roll, pitch = float(np.median(rp[:, 0])), float(np.median(rp[:, 1]))
    rig_cam = {ref: g.make(g.rpy(roll, pitch, 0.0), [0, 0, h])}

    segs: dict[int, np.ndarray] = {}
    for _ in range(4):  # alternate: spots from known cameras, then cameras from known spots
        n = _init_spots(cams, obs, layout, rig_cam, segs, model, max_init_px)
        for c in cams:
            if c == ref:
                continue
            est = [g.inv(segs[s]) @ T for (s, cc), T in field_cam.items() if cc == c and s in segs]
            if est:
                rig_cam[c] = _robust_mean(est)
        n += _init_cameras(cams, obs, layout, rig_cam, segs, model, max_init_px)
        if n == 0:
            break
    return ref, segs, rig_cam


def _pseudo_huber(v: np.ndarray, c: float) -> np.ndarray:
    """Scales a residual vector so its squared length is the pseudo-Huber cost: quadratic below c,
    growing linearly above it."""
    n2 = float(v @ v)
    if n2 < 1e-18:
        return v
    return v * np.sqrt(2 * c * c * (np.sqrt(1 + n2 / (c * c)) - 1) / n2)


def _pseudo_huber_rows(V: np.ndarray, c: float) -> np.ndarray:
    n2 = np.sum(V * V, axis=1, keepdims=True)
    with np.errstate(divide="ignore", invalid="ignore"):
        k = np.sqrt(2 * c * c * (np.sqrt(1 + n2 / (c * c)) - 1) / n2)
    return V * np.where(n2 < 1e-18, 1.0, k)


class _Problem:
    def __init__(self, cams, obs, layout, opt, ref, segs, rig_cam, tags0=None):
        self.cams, self.layout, self.opt, self.ref = cams, layout, opt, ref
        self.obs = [o for o in obs if o.segment in segs and o.camera in rig_cam]
        self.seg_ids = sorted({o.segment for o in self.obs})
        self.cam_ids = [ref] + sorted(c for c in rig_cam if c != ref and any(o.camera == c for o in self.obs))
        self.tag_ids = sorted({o.tag for o in self.obs})
        self.model = np.c_[corner_model(opt.tag_size), np.ones(4)]
        # Parameter layout
        self.si = {s: 3 * i for i, s in enumerate(self.seg_ids)}
        off = 3 * len(self.seg_ids)
        self.ref_off = off
        off += 3
        self.ci = {}
        for c in self.cam_ids[1:]:
            self.ci[c] = off
            off += 6
        self.ti = {}
        for t in self.tag_ids:
            self.ti[t] = off
            off += 6
        self.n = off
        x0 = np.zeros(off)
        for s in self.seg_ids:
            T = segs[s]
            x0[self.si[s] : self.si[s] + 3] = [T[0, 3], T[1, 3], g.to_rpy(T[:3, :3])[2]]
        T = rig_cam[ref]
        r, p, _ = g.to_rpy(T[:3, :3])
        x0[self.ref_off : self.ref_off + 3] = [T[2, 3], r, p]
        for c in self.cam_ids[1:]:
            rv, t = g.to_rvec(rig_cam[c])
            x0[self.ci[c] : self.ci[c] + 6] = np.r_[rv, t]
        for t in self.tag_ids:
            T = (tags0 or {}).get(t, layout.get(t))
            if T is None:  # a tag that isn't in the layout: start from its first sighting
                T = self._tag_from_sighting(t, segs, rig_cam)
            rv, tt = g.to_rvec(T)
            x0[self.ti[t] : self.ti[t] + 6] = np.r_[rv, tt]
        self.x0 = x0
        # Index arrays for the vectorised residuals.
        self.o_seg = np.array([self.seg_ids.index(o.segment) for o in self.obs])
        self.o_cam = np.array([self.cam_ids.index(o.camera) for o in self.obs])
        self.o_tag = np.array([self.tag_ids.index(o.tag) for o in self.obs])
        self.corners = np.array([o.corners for o in self.obs]).reshape(-1, 4, 2)
        self.cam_rows = {c: np.flatnonzero(self.o_cam == i) for i, c in enumerate(self.cam_ids)}
        self.prior_tags = [i for i, t in enumerate(self.tag_ids) if t in layout]
        self.prior_T = np.array([layout[self.tag_ids[i]] for i in self.prior_tags]).reshape(-1, 4, 4)
        self.sigma_t = opt.prior_translation_m
        self.sigma_r = np.radians(opt.prior_rotation_deg)
        self.robust_t = opt.prior_robust_m
        self.robust_r = np.radians(opt.prior_robust_deg)

    def _tag_from_sighting(self, t, segs, rig_cam):
        o = next(o for o in self.obs if o.tag == t)
        cam = self.cams[o.camera]
        _, rv, tv = cv2.solvePnP(self.model[:, :3], o.corners, cam.K, cam.dist8(), flags=cv2.SOLVEPNP_IPPE)
        T_camcv_tag = g.from_rvec(rv.ravel(), tv.ravel())
        return segs[o.segment] @ g.nwu_to_cv(rig_cam[o.camera]) @ T_camcv_tag

    # --- unpacking
    def seg_T(self, x, s):
        a = x[self.si[s] : self.si[s] + 3]
        return g.planar(a[0], a[1], a[2])

    def cam_T(self, x, c):  # T_rig_camNWU
        if c == self.ref:
            z, r, p = x[self.ref_off : self.ref_off + 3]
            return g.make(g.rpy(r, p, 0.0), [0, 0, z])
        a = x[self.ci[c] : self.ci[c] + 6]
        return g.from_rvec(a[:3], a[3:])

    def tag_T(self, x, t):
        a = x[self.ti[t] : self.ti[t] + 6]
        return g.from_rvec(a[:3], a[3:])

    # --- residuals
    def _stacks(self, x):
        segs = x[: 3 * len(self.seg_ids)].reshape(-1, 3)
        S = np.zeros((len(segs), 4, 4))
        c, sn = np.cos(segs[:, 2]), np.sin(segs[:, 2])
        S[:, 0, 0], S[:, 0, 1], S[:, 1, 0], S[:, 1, 1] = c, -sn, sn, c
        S[:, 2, 2] = S[:, 3, 3] = 1
        S[:, 0, 3], S[:, 1, 3] = segs[:, 0], segs[:, 1]
        C = np.array([g.nwu_to_cv(self.cam_T(x, cc)) for cc in self.cam_ids])
        a = x[self.ti[self.tag_ids[0]] :].reshape(-1, 6) if self.tag_ids else np.zeros((0, 6))
        Tg = np.zeros((len(a), 4, 4))
        Tg[:, :3, :3] = Rotation.from_rotvec(a[:, :3]).as_matrix() if len(a) else np.zeros((0, 3, 3))
        Tg[:, :3, 3] = a[:, 3:]
        Tg[:, 3, 3] = 1
        return S, C, Tg

    def residuals(self, x):
        S, C, Tg = self._stacks(x)
        F = S[self.o_seg] @ C[self.o_cam]  # T_field_camCV per observation
        R, t = F[:, :3, :3], F[:, :3, 3]
        W = Tg[self.o_tag] @ self.model.T  # tag corners in the field, (N, 4, 4)
        P = np.einsum("nji,njk->nik", R, W[:, :3, :] - t[:, :, None])  # R^T (w - t): camera frame
        P = P.transpose(0, 2, 1)  # (N, 4 corners, 3)
        uv = np.empty((len(self.obs), 4, 2))
        for c, rows in self.cam_rows.items():
            uv[rows] = self.cams[c].project(P[rows].reshape(-1, 3)).reshape(-1, 4, 2)
        r = np.nan_to_num((uv - self.corners) / self.opt.pixel_sigma, nan=1e3).ravel()
        if not self.prior_tags:
            return r
        T = Tg[self.prior_tags]
        dt = T[:, :3, 3] - self.prior_T[:, :3, 3]
        dr = Rotation.from_matrix(np.transpose(self.prior_T[:, :3, :3], (0, 2, 1)) @ T[:, :3, :3]).as_rotvec()
        pri = np.empty((len(T), 6))
        pri[:, :3] = _pseudo_huber_rows(dt, self.robust_t) / self.sigma_t
        pri[:, 3:] = _pseudo_huber_rows(dr, self.robust_r) / self.sigma_r
        return np.concatenate([r, pri.ravel()])

    def sparsity(self):
        m = 8 * len(self.obs) + 6 * sum(1 for t in self.tag_ids if t in self.layout)
        S = lil_matrix((m, self.n), dtype=int)
        for i, o in enumerate(self.obs):
            rows = slice(8 * i, 8 * i + 8)
            S[rows, self.si[o.segment] : self.si[o.segment] + 3] = 1
            if o.camera == self.ref:
                S[rows, self.ref_off : self.ref_off + 3] = 1
            else:
                S[rows, self.ci[o.camera] : self.ci[o.camera] + 6] = 1
            S[rows, self.ti[o.tag] : self.ti[o.tag] + 6] = 1
        k = 8 * len(self.obs)
        for t in self.tag_ids:
            if t in self.layout:
                S[k : k + 6, self.ti[t] : self.ti[t] + 6] = 1
                k += 6
        return S


def _obs_rms_px(p: _Problem, x) -> np.ndarray:
    r = p.residuals(x)[: 8 * len(p.obs)].reshape(-1, 4, 2) * p.opt.pixel_sigma
    return np.sqrt(np.mean(np.sum(r**2, axis=2), axis=1))  # RMS corner distance in pixels


def solve(cams: dict[str, Camera], obs: list[Observation], layout: dict[int, np.ndarray], opt: Options | None = None,
          verbose: bool = False) -> Result:
    opt = opt or Options()
    model = corner_model(opt.tag_size)
    ref, segs, rig_cam = initialize(cams, obs, layout, opt)
    tags: dict[int, np.ndarray] = {}
    dropped: list[tuple[Observation, float]] = []
    dropped_ids: set[int] = set()
    # Stages: solve what's initialized; then seed the spots and cameras that didn't fit the official
    # layout from the solved tags, and solve again, until nothing more joins.
    for stage in range(5):
        for _ in range(4):  # outlier rounds
            work = [o for o in obs if id(o) not in dropped_ids]
            p = _Problem(cams, work, layout, opt, ref, segs, rig_cam, tags)
            sol = least_squares(p.residuals, p.x0, jac_sparsity=p.sparsity(), loss="soft_l1", f_scale=3.0,
                                x_scale="jac", method="trf", max_nfev=200, verbose=2 if verbose else 0)
            rms = _obs_rms_px(p, sol.x)
            bad = [(o, float(e)) for o, e in zip(p.obs, rms) if e > opt.outlier_px]
            # Keep the solved values as the start of the next round.
            segs.update({s_: p.seg_T(sol.x, s_) for s_ in p.seg_ids})
            rig_cam.update({c: p.cam_T(sol.x, c) for c in p.cam_ids})
            tags = {t: p.tag_T(sol.x, t) for t in p.tag_ids}
            if not bad:
                break
            dropped += bad
            dropped_ids |= {id(o) for o, _ in bad}
        known = {**layout, **tags}
        work = [o for o in obs if id(o) not in dropped_ids]
        # A spot or camera joins when it fits the solved tags about as well as a good view should.
        n = _init_spots(cams, work, known, rig_cam, segs, model, 3 * opt.outlier_px)
        n += _init_cameras(cams, work, known, rig_cam, segs, model, 3 * opt.outlier_px)
        if verbose:
            print(f"stage {stage}: {len(p.seg_ids)} spots, {len(p.cam_ids)} cameras, {len(p.tag_ids)} tags; {n} more to add")
        if n == 0:
            break
        # Everything dropped gets another chance against the better tags; real outliers drop again.
        dropped, dropped_ids = [], set()

    x = sol.x
    rms = _obs_rms_px(p, x)
    # Uncertainty: covariance of the parameters, scaled by the fit's own residual level.
    J = sol.jac.toarray() if hasattr(sol.jac, "toarray") else np.asarray(sol.jac)
    dof = max(1, J.shape[0] - J.shape[1])
    s2 = float(np.sum(sol.fun**2) / dof)
    try:
        cov = np.linalg.pinv(J.T @ J) * s2
    except np.linalg.LinAlgError:
        cov = np.full((p.n, p.n), np.nan)
    tag_sigma, tag_rel_sigma = {}, {}
    pos_idx = [np.arange(p.ti[t] + 3, p.ti[t] + 6) for t in p.tag_ids]
    all_pos = np.concatenate(pos_idx)
    N = len(p.tag_ids)
    for t, idx in zip(p.tag_ids, pos_idx):
        i = p.ti[t]
        tag_sigma[t] = (float(np.sqrt(np.trace(cov[np.ix_(idx, idx)]))),
                        float(np.degrees(np.sqrt(np.trace(cov[i : i + 3, i : i + 3])))))
        # Relative to the map: most of the absolute uncertainty is where the whole map sits, which
        # every tag shares. Var(p_t - mean of all tags' p).
        a = np.zeros((3, p.n))
        a[:, idx] = np.eye(3)
        for j in range(N):
            a[:, all_pos[3 * j : 3 * j + 3]] -= np.eye(3) / N
        tag_rel_sigma[t] = float(np.sqrt(max(0.0, np.trace(a @ cov @ a.T))))
    cam_sigma = {}
    for c in p.cam_ids:
        if c == ref:
            i = p.ref_off
            d = np.sqrt(np.abs(np.diag(cov[i : i + 3, i : i + 3])))
            cam_sigma[c] = np.array([0, 0, d[0], np.degrees(d[1]), np.degrees(d[2]), 0])
        else:
            i = p.ci[c]
            d = np.sqrt(np.abs(np.diag(cov[i : i + 6, i : i + 6])))
            cam_sigma[c] = np.array([d[3], d[4], d[5], *np.degrees(d[:3])])
    by_cam, by_seg, by_tag = defaultdict(list), defaultdict(list), defaultdict(list)
    for o, e in zip(p.obs, rms):
        by_cam[o.camera].append(e)
        by_seg[o.segment].append(e)
        by_tag[o.tag].append(e)
    q = lambda d: {k: float(np.sqrt(np.mean(np.square(v)))) for k, v in d.items()}
    result = Result(
        ref_camera=ref,
        segments={s: p.seg_T(x, s) for s in p.seg_ids},
        cameras={c: p.cam_T(x, c) for c in p.cam_ids},
        tags={t: p.tag_T(x, t) for t in p.tag_ids},
        tag_sigma=tag_sigma,
        tag_rel_sigma=tag_rel_sigma,
        camera_sigma=cam_sigma,
        used=p.obs,
        dropped=dropped,
        rms_by_camera=q(by_cam),
        rms_by_segment=q(by_seg),
        rms_by_tag=q(by_tag),
        obs_by_tag=Counter(o.tag for o in p.obs),
        obs_rms=[float(e) for e in rms],
        # least_squares status 0: it stopped at max_nfev, still improving. (Negative: bad input.)
        converged=sol.status > 0,
    )
    G, info = align_to_layout(result.tags, layout, result.obs_by_tag)
    _apply_alignment(result, G)
    result.alignment = info
    return result


# --- lining the map up with the layout


def _fit_xyz_yaw(P: np.ndarray, Q: np.ndarray, w: np.ndarray) -> np.ndarray:
    """The weighted best G (x, y, z shift and yaw) with G @ P ~ Q, for point sets N x 3."""
    w = w / w.sum()
    cp, cq = w @ P, w @ Q
    H = ((P - cp)[:, :2] * w[:, None]).T @ (Q - cq)[:, :2]
    yaw = np.arctan2(H[0, 1] - H[1, 0], H[0, 0] + H[1, 1])
    R = g.rpy(0, 0, yaw)
    return g.make(R, cq - R @ cp)


def align_to_layout(tags: dict[int, np.ndarray], layout: dict[int, np.ndarray], seen: Counter, min_obs: int = 2,
                    inlier_m: float = 0.02):
    """Where the whole map sits: the shift and turn (x, y, z, yaw) that lines the solved tags up
    with the official layout, so tags that really moved (a misplaced field element) don't drag the
    others. The answer that the most tags agree with (within ``inlier_m``) wins: every pair of
    tags proposes one, then it's refined on the tags that agree. Returns (G, info); apply G to the
    field frame."""
    ids = [t for t in tags if t in layout and seen[t] >= min_obs]
    if len(ids) < 3:
        return np.eye(4), {"tagsUsed": ids, "tagsIgnored": [], "shiftCm": 0.0, "yawDeg": 0.0,
                           "note": "fewer than 3 well-seen layout tags: not realigned"}
    P = np.array([tags[t][:3, 3] for t in ids])
    Q = np.array([layout[t][:3, 3] for t in ids])

    def resid(G):
        return np.linalg.norm((G[:3, :3] @ P.T).T + G[:3, 3] - Q, axis=1)

    best, best_key = np.eye(4), (-1, 0.0)
    for i in range(len(ids)):
        for j in range(i + 1, len(ids)):
            if np.linalg.norm(Q[i, :2] - Q[j, :2]) < 0.3:
                continue
            w = np.zeros(len(ids))
            w[[i, j]] = 1
            G = _fit_xyz_yaw(P, Q, w)
            r = resid(G)
            key = (int(np.sum(r < inlier_m)), -float(np.sum(np.minimum(r, inlier_m))))
            if key > best_key:
                best, best_key = G, key
    if best_key[0] < 0:  # all tags close together: plain fit
        best = _fit_xyz_yaw(P, Q, np.ones(len(ids)))
    G = best
    for _ in range(10):  # refine on the tags that agree
        inl = resid(G) < inlier_m
        if inl.sum() < 2:
            break
        G_new = _fit_xyz_yaw(P, Q, inl.astype(float))
        if np.allclose(G_new, G, atol=1e-9):
            break
        G = G_new
    inl = resid(G) < inlier_m
    return G, {"tagsUsed": [t for t, k in zip(ids, inl) if k], "tagsIgnored": [t for t, k in zip(ids, inl) if not k],
               "shiftCm": float(np.linalg.norm(G[:3, 3]) * 100),
               "yawDeg": float(np.degrees(np.arctan2(G[1, 0], G[0, 0])))}


def _apply_alignment(res: Result, G: np.ndarray) -> None:
    """Moves the whole solution by G (x, y, z, yaw). Spots stay on the floor; a height change goes
    into the cameras, which rise with the tags."""
    Gp = G.copy()
    Gp[2, 3] = 0.0
    Tz = g.make(np.eye(3), [0, 0, G[2, 3]])
    res.tags = {t: G @ T for t, T in res.tags.items()}
    res.segments = {s: Gp @ T for s, T in res.segments.items()}
    res.cameras = {c: Tz @ T for c, T in res.cameras.items()}


# --- anchoring the real robot frame


def anchor_reference_spot(res: Result, spot: int, x: float, y: float, yaw_deg: float) -> np.ndarray:
    """T_robot_rig from a spot where the robot's pose on the field is known (pushed into a corner,
    or against a marked spot on the wall)."""
    return g.inv(g.planar(x, y, np.radians(yaw_deg))) @ res.segments[spot]


def anchor_cad(res: Result, cad: dict[str, np.ndarray]) -> np.ndarray:
    """T_robot_rig from the CAD mounts (T_robot_cam) of every camera that has one. Heading: the
    median of each camera's CAD yaw minus its solved yaw (cameras point much more precisely than
    their positions, a few mm apart, can turn the rig; the median ignores one bad CAD yaw).
    Position: the mean of the camera positions. Height, roll and pitch still come from the solve."""
    names = [c for c in res.cameras if c in cad]
    if not names:
        raise ValueError("None of the CAD cameras are in the solve.")
    d = [g.to_rpy(cad[c][:3, :3])[2] - g.to_rpy(res.cameras[c][:3, :3])[2] for c in names]
    d = np.angle(np.exp(1j * np.array(d)))  # wrap to +-pi
    ref = d[0]
    yaw = ref + float(np.median(np.angle(np.exp(1j * (d - ref)))))
    R = g.rpy(0, 0, yaw)[:2, :2]
    A = np.array([res.cameras[c][:2, 3] for c in names])  # rig frame
    B = np.array([cad[c][:2, 3] for c in names])  # robot frame
    t = np.mean(B - A @ R.T, axis=0)
    return g.planar(t[0], t[1], yaw)


def anchor_camera(res: Result, camera: str, x: float, y: float, yaw_deg: float) -> np.ndarray:
    """T_robot_rig from one camera's x, y and yaw on the robot (CAD). Height, roll and pitch still
    come from the solve."""
    T = res.cameras[camera]
    _, _, yaw_rig = g.to_rpy(T[:3, :3])
    dyaw = np.radians(yaw_deg) - yaw_rig
    Rz = g.rpy(0, 0, dyaw)
    xy = Rz[:2, :2] @ T[:2, 3]
    return g.make(Rz, [x - xy[0], y - xy[1], 0.0])
