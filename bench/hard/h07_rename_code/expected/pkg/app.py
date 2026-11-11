from pkg.config import load_config, load_cfg_cached

# load_cfg reads it every time
def start(path):
    print("calling load_cfg")
    return load_config(path) + load_cfg_cached(path)
