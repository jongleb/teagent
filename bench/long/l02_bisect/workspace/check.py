import json, sys
from decimal import Decimal, ROUND_HALF_EVEN, ROUND_FLOOR, ROUND_HALF_UP

config = json.load(open(sys.argv[1] + "/config.json"))
cart = [("tea", 3, "4.15"), ("cups", 2, "12.95"), ("honey", 1, "7.35"), ("biscuits", 4, "2.1")]
modes = {"half_even": ROUND_HALF_EVEN, "half_up": ROUND_HALF_UP, "floor": ROUND_FLOOR}
total = Decimal(0)
for name, quantity, price in cart:
    line = Decimal(price) * quantity * (1 - Decimal(str(config["discounts"].get(name, 0))))
    total += line * (1 + Decimal(str(config["tax"])))
total = total.quantize(Decimal(10) ** -config["decimals"], rounding=modes[config["rounding"]])
expected = Decimal("56.80")
if total != expected:
    print("FAIL: total %s, expected %s" % (total, expected))
    sys.exit(1)
print("ok: total %s" % total)
