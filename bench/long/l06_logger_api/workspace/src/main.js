import { log } from "./log.js";
import { start } from "./api/routes.js";

const port = 8080;
  log("info", "starting");
  log("info", `port ${port}`);
start(port);
