import { log } from "../log.js";

export function session(user, code, count) {
  log("info", "session opened");
  log("info", "session closed");
  log("warn", "session expired");
  return true;
}
