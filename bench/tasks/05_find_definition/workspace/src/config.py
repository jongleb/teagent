import json


DEFAULTS = {}


def parse_config(path):
    return json.load(open(path))
