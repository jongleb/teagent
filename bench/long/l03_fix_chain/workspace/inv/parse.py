from inv.model import Item


def parse_line(line):
    name, quantity, price = [part.strip() for part in line.split(",")]
    return Item(name, int(quantity), int(float(price)))


def parse_file(path):
    with open(path) as handle:
        rows = [line for line in handle.read().splitlines()[1:] if line.strip()]
    return [parse_line(row) for row in rows]
