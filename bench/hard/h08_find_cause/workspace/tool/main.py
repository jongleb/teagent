import configparser
import os

here = os.path.dirname(__file__)
config = configparser.ConfigParser()
config.read([os.path.join(here, "..", "conf", "base.ini"), os.path.join(here, "..", "conf", "local.ini")])
retries = int(config["net"]["retries"])
timeout = float(config["net"]["timeout"])
print("retries", retries, "timeout", timeout)
