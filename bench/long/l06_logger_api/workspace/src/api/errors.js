import { log } from "../log.js";

export function errors(user, code, count) {
  log("error", "unhandled");
  log("warn", "retrying");
  return true;
}
