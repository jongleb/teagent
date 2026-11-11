import os
import sys
import json

import requests
from yaml import safe_load

from app.utils import slug
from . import models


def run(path):
    with open(path) as handle:
        config = safe_load(handle)
    return requests.get(config["url"]).json()
