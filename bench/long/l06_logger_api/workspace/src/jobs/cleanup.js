import { log } from "../log.js";

export function cleanup(user, code, count) {
  log("info", "cleanup");
  log("error", "cleanup failed");
  return true;
}
