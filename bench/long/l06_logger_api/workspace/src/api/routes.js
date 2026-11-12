import { log } from "../log.js";
import { dialog } from "../ui/dialog.js";

export function start(port) {
  log("info", "routes ready");
  dialog("info", "server up");
}
