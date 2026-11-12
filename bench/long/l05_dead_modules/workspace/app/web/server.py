from app.web.routes import ROUTES
from . import middleware


def start(port):
    handler = middleware.wrap(ROUTES)
    print("listening on", port, len(handler))
