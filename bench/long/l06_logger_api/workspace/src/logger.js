function at(level) {
  return (message) => console.log(`[${level}] ${message}`);
}

export const logger = { info: at("info"), warn: at("warn"), error: at("error") };
