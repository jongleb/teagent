import json, os, sys

here = os.path.dirname(os.path.abspath(__file__))
path = os.path.join(here, "db.json")


def apply(db, step):
    tables = db["tables"]
    kind = step["op"]
    if kind == "create_table":
        if step["table"] in tables:
            raise ValueError("table %s exists" % step["table"])
        tables[step["table"]] = {"columns": list(step["columns"]), "rows": []}
        return
    table = tables.get(step["table"])
    if table is None:
        raise ValueError("no table %s" % step["table"])
    if kind == "add_column":
        if step["column"] in table["columns"]:
            raise ValueError("column %s exists" % step["column"])
        table["columns"].append(step["column"])
        for row in table["rows"]:
            row[step["column"]] = step["default"]
    elif kind == "rename_column":
        if step["from"] not in table["columns"]:
            raise ValueError("no column %s in %s" % (step["from"], step["table"]))
        table["columns"] = [step["to"] if c == step["from"] else c for c in table["columns"]]
        for row in table["rows"]:
            row[step["to"]] = row.pop(step["from"])
    elif kind == "drop_column":
        if step["column"] not in table["columns"]:
            raise ValueError("no column %s in %s" % (step["column"], step["table"]))
        table["columns"].remove(step["column"])
        for row in table["rows"]:
            del row[step["column"]]
    elif kind == "insert":
        for row in step["rows"]:
            if sorted(row) != sorted(table["columns"]):
                raise ValueError("row %s does not match the columns %s" % (row, table["columns"]))
            table["rows"].append(row)
    else:
        raise ValueError("unknown op %s" % kind)


if sys.argv[1:] != ["migrate"]:
    print("usage: python3 db.py migrate")
    sys.exit(2)
db = json.load(open(path))
pending = sorted(n for n in os.listdir(os.path.join(here, "migrations")) if n.endswith(".json") and n[:-5] not in db["applied"])
if not pending:
    print("up to date")
    sys.exit(0)
name = pending[0]
migration = json.load(open(os.path.join(here, "migrations", name)))
try:
    for step in migration["steps"]:
        apply(db, step)
except (KeyError, ValueError) as error:
    print("migration %s failed: %s" % (name, error))
    sys.exit(1)
db["applied"].append(name[:-5])
json.dump(db, open(path, "w"), indent=2)
open(path, "a").write("\n")
print("applied %s: %s" % (name, migration["description"]))
