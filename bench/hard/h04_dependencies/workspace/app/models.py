from dataclasses import dataclass


@dataclass
class Item:
    name: str


def table(rows):
    import numpy as np
    return np.array(rows)
