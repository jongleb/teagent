import { log } from "../log.js";

export function nightly(user, code, count) {
  log("info", "nightly run");
  log("warn", `skipped ${count} jobs`);
  return true;
}
