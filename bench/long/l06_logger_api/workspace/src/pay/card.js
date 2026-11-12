import { log } from "../log.js";

export function card(user, code, count) {
  log("info", "charging card");
  log("error", `card declined: ${code}`);
  return true;
}
