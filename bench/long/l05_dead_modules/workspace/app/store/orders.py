from app.store import db


def all_orders():
    return db.connect()
