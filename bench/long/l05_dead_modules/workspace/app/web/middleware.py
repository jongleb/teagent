from .auth import check


def wrap(routes):
    return {path: check(view) for path, view in routes.items()}
