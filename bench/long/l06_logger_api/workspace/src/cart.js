import { log } from "./log.js";

export function cart(user, code, count) {
  log("info", "cart created");
  log("warn", `empty cart for ${user}`);
  log("error", "cart overflow");
  return true;
}
