from app.store.db import connect


def find(name):
    return name in connect()


def everyone():
    return list(connect())
