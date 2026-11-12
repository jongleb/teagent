from app.store.users import find


def check(view):
    return view if find("ada") else None
