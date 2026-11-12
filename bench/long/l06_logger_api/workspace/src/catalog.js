const entries = [];

function log(entry) {
  entries.push(entry);
}

export function add(item) {
  log("added", item);
  return entries.length;
}
