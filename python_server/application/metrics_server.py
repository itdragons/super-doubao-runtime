import sys
from pydantic import BaseModel
from fastapi import (
    APIRouter,
)
import sys
import importlib.metadata as metadata
from collections import defaultdict
import difflib

try:
    import pkg_resources
except ImportError:
    pkg_resources = None


def get_loaded_pip_packages(only_site_packages=False, fuzzy_cutoff=0.8):
    # 收集 sys.modules 顶层模块
    loaded_tops = {name.split(".")[0] for name in sys.modules if name}

    if only_site_packages:
        filtered = []
        for top in loaded_tops:
            mod = sys.modules.get(top)
            if mod is None:
                continue
            file = getattr(mod, "__file__", "")
            if file and (
                "site-packages" in file.lower()
                or "dist-packages" in file.lower()
                or ".egg" in file.lower()
                or ".dist-info" in file.lower()
            ):
                filtered.append(top)
        loaded_tops = set(filtered)

    # packages_distributions
    try:
        pkg_map = metadata.packages_distributions()
    except Exception:
        pkg_map = {}

    # 构建 top -> distribution(s) 映射
    top2dists = defaultdict(list)
    for dist in metadata.distributions():
        dist_name = dist.metadata.get("Name") or getattr(dist, "name", None)
        dist_version = getattr(dist, "version", None)
        try:
            tops_text = dist.read_text("top_level.txt")
        except Exception:
            tops_text = None
        if tops_text:
            for line in tops_text.splitlines():
                t = line.strip()
                if t:
                    top2dists[t].append((dist_name, dist_version))

    # pkg_resources 的已安装集合
    installed_by_key = {}
    if pkg_resources:
        for dist in pkg_resources.working_set:
            installed_by_key[dist.key] = (dist.project_name, dist.version)

    result = {}

    for top in loaded_tops:
        found = False

        # A: packages_distributions
        if top in pkg_map:
            for dname in pkg_map[top]:
                try:
                    ver = metadata.version(dname)
                    result[dname] = ver
                    found = True
                    break
                except Exception:
                    pass
            if found:
                continue

        # B: top2dists
        if top in top2dists:
            for (dname, ver) in top2dists[top]:
                if dname:
                    if ver:
                        result[dname] = ver
                        found = True
                        break
                    else:
                        try:
                            v2 = metadata.version(dname)
                            result[dname] = v2
                            found = True
                            break
                        except Exception:
                            pass
            if found:
                continue

        # C: pkg_resources normalized key
        if pkg_resources:
            cand_keys = [
                top.lower(),
                top.lower().replace("_", "-"),
                top.lower().replace("-", "_"),
                top.lstrip("_").lower(),
            ]
            for k in cand_keys:
                if k in installed_by_key:
                    proj, ver = installed_by_key[k]
                    result[proj] = ver
                    found = True
                    break
            if found:
                continue

        # D: metadata.version(top)
        try:
            v = metadata.version(top)
            result[top] = v
            continue
        except Exception:
            pass

        # E: fuzzy match
        if pkg_resources and installed_by_key:
            close = difflib.get_close_matches(
                top.lower(), list(installed_by_key.keys()), n=1, cutoff=fuzzy_cutoff
            )
            if close:
                proj, ver = installed_by_key[close[0]]
                result[proj] = ver
                continue

        close2 = difflib.get_close_matches(
            top, list(top2dists.keys()), n=1, cutoff=fuzzy_cutoff
        )
        if close2:
            for (dname, ver) in top2dists[close2[0]]:
                if dname:
                    if ver:
                        result[dname] = ver
                        break
                    else:
                        try:
                            v2 = metadata.version(dname)
                            result[dname] = v2
                            break
                        except Exception:
                            pass

    return result


metrics_prefix = "/metrics"

metrics_server_router = APIRouter(prefix=metrics_prefix)

class GetLoadedModuleRequest(BaseModel):
    pass

@metrics_server_router.post("/loaded_modules")
async def getModules(request: GetLoadedModuleRequest):
    return get_loaded_pip_packages()