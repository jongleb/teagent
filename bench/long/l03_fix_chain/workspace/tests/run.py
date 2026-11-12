import os, sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from inv.parse import parse_line, parse_file
from inv.model import Item, Inventory
from inv.fmt import money
from inv.report import report

here = os.path.dirname(os.path.abspath(__file__))


def test_parse_line():
    item = parse_line("tea, 3, 4.25")
    assert (item.name, item.quantity, item.price) == ("tea", 3, 4.25), vars(item)


def test_item_total():
    assert Item("tea", 3, 4.25).total() == 12.75, Item("tea", 3, 4.25).total()


def test_inventory_merges():
    inventory = Inventory()
    inventory.add(Item("tea", 3, 4.25))
    inventory.add(Item("tea", 2, 4.25))
    assert inventory.items["tea"].quantity == 5, inventory.items["tea"].quantity


def test_money():
    assert money(7.5) == "7.50", money(7.5)


def test_report():
    inventory = Inventory()
    for item in parse_file(os.path.join(here, "data.csv")):
        inventory.add(item)
    names = [line.split()[0] for line in report(inventory).splitlines()[:-1]]
    assert names == ["cups", "honey", "tea"], names
    assert report(inventory).splitlines()[-1] == "total 54.00", report(inventory).splitlines()[-1]


for test in [test_parse_line, test_item_total, test_inventory_merges, test_money, test_report]:
    try:
        test()
    except AssertionError as error:
        print("FAIL", test.__name__, error)
        sys.exit(1)
    print("ok", test.__name__)
print("all passed")
