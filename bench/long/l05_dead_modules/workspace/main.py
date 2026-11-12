from app.web import server
from app import settings


if __name__ == "__main__":
    server.start(settings.PORT)
