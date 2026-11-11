import re
from collections import OrderedDict


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower())
