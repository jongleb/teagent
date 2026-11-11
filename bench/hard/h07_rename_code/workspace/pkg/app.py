from pkg.config import load_cfg, load_cfg_cached

# load_cfg reads it every time
def start(path):
    print("calling load_cfg")
    return load_cfg(path) + load_cfg_cached(path)
