def load_cfg(path):
    """Read the file; see docs for load_cfg."""
    with open(path) as handle:
        return handle.read()


def load_cfg_cached(path, cache={}):
    if path not in cache:
        cache[path] = load_cfg(path)
    return cache[path]
