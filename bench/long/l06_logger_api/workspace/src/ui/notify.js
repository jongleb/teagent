import { log } from "../log.js";
import { dialog } from "./dialog.js";

export function notify(text) {
  dialog("warn", text);
  log("info", "notify");
}
